#requires -Version 5.1
<#
.SYNOPSIS
    Runs the Windows cross-platform gates for platform-iac-modules.

.DESCRIPTION
    Validates the pinned toolchain and repository contracts, then runs the
    catalog-driven smoke wrapper and repository-wide static analysis. The
    smoke wrapper is the Windows entry point for run-smoke-tests.py, the
    source-of-truth implementation.

    Exit codes:
      0 - all gates passed
      1 - one or more gates failed
      2 - invalid arguments, unsupported host, or missing prerequisites

.PARAMETER Help
    Display this help text.

.PARAMETER Modules
    Optional comma-separated module names or modules/<name> paths to pass to
    the smoke-test wrapper.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File tests/cross-platform/test-windows.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File tests/cross-platform/test-windows.ps1 -Modules kms,s3
#>
[CmdletBinding()]
param(
    [switch]$Help,
    [string]$Modules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$ScriptDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..'))

function Get-Setting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

$ToolingDir = Get-Setting 'TOOLING_DIR' (Join-Path $RepoRoot 'tooling')
$ModulesDir = Get-Setting 'MODULES_DIR' (Join-Path $RepoRoot 'modules')
$OutputDir = Get-Setting 'OUTPUT_DIR' (Join-Path $ScriptDir 'output')
$TerraformVersionFile = Get-Setting 'TERRAFORM_VERSION_FILE' (Join-Path $ToolingDir '.terraform-version')
$ToolVersionsFile = Get-Setting 'TOOL_VERSIONS_FILE' (Join-Path $ToolingDir '.tool-versions')
$TflintConfig = Get-Setting 'TFLINT_CONFIG' (Join-Path $ToolingDir '.tflint.hcl')
$CheckovConfig = Get-Setting 'CHECKOV_CONFIG' (Join-Path $ToolingDir '.checkov.yml')
$TrivyIgnore = Get-Setting 'TRIVY_IGNORE' (Join-Path $ToolingDir '.trivyignore')
$YamllintConfig = Get-Setting 'YAMLLINT_CONFIG' (Join-Path $ToolingDir '.yamllint.yml')
$VerifyToolchain = Get-Setting 'VERIFY_TOOLCHAIN_SCRIPT' (Join-Path $RepoRoot 'scripts\tools\verify-toolchain.py')
$VerifyEnv = Get-Setting 'VERIFY_ENV_SCRIPT' (Join-Path $RepoRoot 'scripts\tools\verify-env.py')
$ValidateOutputs = Get-Setting 'VALIDATE_OUTPUTS_SCRIPT' (Join-Path $RepoRoot 'scripts\tools\validate-outputs.py')
$SmokeWrapper = Get-Setting 'SMOKE_WRAPPER' (Join-Path $RepoRoot 'tests\smoke\run-smoke-tests.ps1')
$GoModFile = Join-Path $RepoRoot 'go.mod'

$TerraformName = Get-Setting 'TERRAFORM_BIN' 'terraform'
$TflintName = Get-Setting 'TFLINT_BIN' 'tflint'
$CheckovName = Get-Setting 'CHECKOV_BIN' 'checkov'
$TrivyName = Get-Setting 'TRIVY_BIN' 'trivy'
$PythonOverride = Get-Setting 'PYTHON_BIN' ''
$PowerShellName = if ($PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

$Pass = 0
$Fail = 0
$Skip = 0
$Results = [System.Collections.Generic.List[object]]::new()
$CurrentStep = 'initialization'
$ModuleFilter = @()
$TranscriptStarted = $false
$PythonCommand = $null
$PythonPrefixArgs = @()

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Message
    )

    $color = @{ INFO = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    $prefix = "[$Level]"
    if ([string]::IsNullOrEmpty($env:NO_COLOR) -and -not [Console]::IsOutputRedirected) {
        Write-Host $prefix -ForegroundColor $color -NoNewline
        Write-Host " $Message"
    }
    else {
        Write-Host "$prefix $Message"
    }
}

function Add-Result {
    param(
        [string]$Scope,
        [string]$Gate,
        [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )

    if ($Status -eq 'PASS') {
        $script:Pass++
    }
    elseif ($Status -eq 'FAIL') {
        $script:Fail++
    }
    else {
        $script:Skip++
    }

    [void]$script:Results.Add([pscustomobject]@{
        Scope  = $Scope
        Gate   = $Gate
        Status = $Status
        Detail = $Detail
    })

    $line = '{0,-5} {1}: {2}' -f $Status, $Scope, $Gate
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $line += " ($Detail)"
    }

    if ($Status -eq 'FAIL') {
        Write-Log ERROR $line
    }
    elseif ($Status -eq 'SKIP') {
        Write-Log WARN $line
    }
    else {
        Write-Host $line
    }
}

function Get-ToolCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw "Missing $Label ($Name). Install the pinned tool or run scripts/tools/install-tools-windows.go."
    }
    return $command.Source
}

function Test-Python3 {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$PrefixArgs = @()
    )

    try {
        & $Command @PrefixArgs -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Resolve-Python3 {
    if (-not [string]::IsNullOrWhiteSpace($PythonOverride)) {
        $command = Get-Command -Name $PythonOverride -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $command -or -not (Test-Python3 -Command $command.Source)) {
            throw "PYTHON_BIN must resolve to a Python 3 executable: $PythonOverride"
        }
        $script:PythonCommand = $command.Source
        $script:PythonPrefixArgs = @()
        return
    }

    $launcher = Get-Command -Name 'py' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $launcher -and (Test-Python3 -Command $launcher.Source -PrefixArgs @('-3'))) {
        $script:PythonCommand = $launcher.Source
        $script:PythonPrefixArgs = @('-3')
        return
    }

    foreach ($name in @('python3', 'python')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command -and (Test-Python3 -Command $command.Source)) {
            $script:PythonCommand = $command.Source
            $script:PythonPrefixArgs = @()
            return
        }
    }

    throw 'No Python 3 interpreter found on PATH (tried: PYTHON_BIN, py -3, python3, python).'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$CaptureOutput
    )

    $script:CurrentStep = "$Command $($Arguments -join ' ')"
    if ($CaptureOutput) {
        $output = @(& $Command @Arguments 2>&1)
    }
    else {
        & $Command @Arguments
    }

    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        throw "Native command failed with exit code ${nativeExitCode}: $Command $($Arguments -join ' ')"
    }

    if ($CaptureOutput) {
        return ($output -join [Environment]::NewLine)
    }
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    Invoke-Native -Command $script:PythonCommand -Arguments ($script:PythonPrefixArgs + $Arguments) -CaptureOutput:$CaptureOutput
}

function Get-Pin {
    param([Parameter(Mandatory = $true)][string]$Name)

    $pattern = '^\s*' + [regex]::Escape($Name) + '\s+(\S+)\s*$'
    $line = Get-Content -LiteralPath $ToolVersionsFile |
        Where-Object { $_ -match $pattern } |
        Select-Object -First 1
    if ($null -ne $line -and $line -match '^\s*\S+\s+(\S+)') {
        return $Matches[1]
    }
    return ''
}

function Get-Version {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    $text = Invoke-Native -Command $Command -Arguments $Arguments -CaptureOutput
    $match = [regex]::Match($text, '\d+\.\d+\.\d+')
    if (-not $match.Success) {
        throw "Could not parse version from $Command output: $text"
    }
    return $match.Value
}

function Test-Version {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $expectedValue = $Expected.Trim().TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($expectedValue)) {
        Add-Result 'toolchain' "$Label version pin" 'FAIL' 'no pin'
        return
    }

    try {
        $actual = Get-Version -Command $Command -Arguments $Arguments
    }
    catch {
        Add-Result 'toolchain' "$Label version probe" 'FAIL' $_.Exception.Message
        return
    }

    if ($actual -eq $expectedValue) {
        Add-Result 'toolchain' "$Label $actual" 'PASS'
    }
    else {
        Add-Result 'toolchain' "$Label version" 'FAIL' "found $actual, expected $expectedValue"
    }
}

function Invoke-Gate {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Gate,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Log INFO "$Scope :: $Gate"
    try {
        & $Action
        Add-Result $Scope $Gate 'PASS'
    }
    catch {
        Add-Result $Scope $Gate 'FAIL' $_.Exception.Message
    }
}

function ConvertTo-ModuleFilter {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim().TrimStart('.', '\', '/').TrimEnd('\', '/')
    if ($normalized -like 'modules/*') {
        $normalized = $normalized.Substring(8)
    }
    return $normalized
}

function Invoke-SmokeTests {
    $arguments = New-Object System.Collections.Generic.List[string]

    foreach ($item in $ModuleFilter) {
        $normalized = ConvertTo-ModuleFilter $item
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$arguments.Add('--module')
            [void]$arguments.Add($normalized)
        }
    }

    if ($ModuleFilter.Count -gt 0 -and $arguments.Count -eq 0) {
        throw '-Modules requires at least one non-empty module name.'
    }

    $smokeArguments = @($SmokeWrapper) + $arguments.ToArray()
    Invoke-Native -Command $script:PowerShellCommand -Arguments (
        @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $smokeArguments
    )
}

function Show-Summary {
    Write-Host "`nSummary`n-------"
    $script:Results | Format-Table -AutoSize Scope, Gate, Status, Detail | Out-Host
    Write-Host "PASS: $Pass  FAIL: $Fail  SKIP: $Skip"
}

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Host @"
Usage: $scriptName [-Help] [-Modules <FILTER>]

Run the Windows cross-platform gates for platform-iac-modules.
FILTER is a module name or modules/<name> path; multiple filters may be
comma-separated and are passed to the catalog-driven smoke wrapper.

The suite validates:
  - pinned Terraform, Python, TFLint, Checkov, and Trivy versions
  - validate-outputs.py, verify-toolchain.py, and verify-env.py --strict
  - the Windows smoke wrapper for run-smoke-tests.py
  - Checkov, Trivy, and yamllint repository gates

OUTPUT_DIR defaults to tests/cross-platform/output and receives
test-windows.log.

Exit codes:
  0  all gates passed
  1  one or more gates failed
  2  invalid arguments, unsupported host, or missing prerequisites
"@
}

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    if ($PSBoundParameters.ContainsKey('Modules')) {
        if ([string]::IsNullOrWhiteSpace($Modules)) {
            throw 'The -Modules parameter requires a non-empty value.'
        }
        $ModuleFilter = @($Modules -split ',')
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "This suite must run on Windows; detected $([Environment]::OSVersion.Platform)."
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $logFile = Join-Path $OutputDir 'test-windows.log'
    Start-Transcript -LiteralPath $logFile -Append | Out-Null
    $TranscriptStarted = $true

    Set-Location -LiteralPath $RepoRoot
    $env:TF_IN_AUTOMATION = Get-Setting 'TF_IN_AUTOMATION' 'true'
    $env:TF_INPUT = Get-Setting 'TF_INPUT' 'false'
    $env:CHECKPOINT_DISABLE = Get-Setting 'CHECKPOINT_DISABLE' '1'
    $env:PYTHONUTF8 = Get-Setting 'PYTHONUTF8' '1'
    $env:PYTHONIOENCODING = Get-Setting 'PYTHONIOENCODING' 'utf-8'

    $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $cpu = if ($env:NUMBER_OF_PROCESSORS) { $env:NUMBER_OF_PROCESSORS } else { 'unknown' }
    Write-Log INFO "Repository: $RepoRoot ($os, $arch, $cpu CPUs)"

    if (-not (Test-Path -LiteralPath $ModulesDir -PathType Container)) {
        throw "Modules directory not found: $ModulesDir"
    }

    $requiredFiles = @(
        $GoModFile,
        $ToolVersionsFile,
        $TerraformVersionFile,
        $TflintConfig,
        $CheckovConfig,
        $TrivyIgnore,
        $YamllintConfig,
        $VerifyToolchain,
        $VerifyEnv,
        $ValidateOutputs,
        $SmokeWrapper
    )
    foreach ($path in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file not found: $path"
        }
    }

    Resolve-Python3
    $script:TerraformCommand = Get-ToolCommand $TerraformName 'Terraform'
    $script:TflintCommand = Get-ToolCommand $TflintName 'TFLint'
    $script:CheckovCommand = Get-ToolCommand $CheckovName 'Checkov'
    $script:TrivyCommand = Get-ToolCommand $TrivyName 'Trivy'
    $script:PowerShellCommand = Get-ToolCommand $PowerShellName 'PowerShell'

    Test-Version 'Terraform' $script:TerraformCommand @('version') (Get-Content -LiteralPath $TerraformVersionFile -Raw)
    Test-Version 'Python' $script:PythonCommand ($script:PythonPrefixArgs + @('--version')) (Get-Pin 'python')
    Test-Version 'TFLint' $script:TflintCommand @('--version') (Get-Pin 'tflint')
    Test-Version 'Checkov' $script:CheckovCommand @('--version') (Get-Pin 'checkov')
    Test-Version 'Trivy' $script:TrivyCommand @('--version') (Get-Pin 'trivy')

    Invoke-Gate 'environment' 'validate-outputs.py' {
        Invoke-Python @(
            $ValidateOutputs,
            '--root', $RepoRoot,
            '--go-mod-file', $GoModFile,
            '--terraform-version-file', $TerraformVersionFile,
            '--tool-versions-file', $ToolVersionsFile
        )
    }
    Invoke-Gate 'environment' 'verify-toolchain.py' {
        Invoke-Python @(
            $VerifyToolchain,
            '--root', $RepoRoot,
            '--tool-versions-file', $ToolVersionsFile,
            '--terraform-version-file', $TerraformVersionFile,
            '--go-mod-file', $GoModFile
        )
    }
    Invoke-Gate 'environment' 'verify-env.py --strict' {
        Invoke-Python @($VerifyEnv, '--root', $RepoRoot, '--strict')
    }
    Invoke-Gate 'smoke' 'catalog-driven smoke tests' {
        Invoke-SmokeTests
    }
    Invoke-Gate 'repository' 'Checkov' {
        Invoke-Native -Command $script:CheckovCommand -Arguments @('-d', $RepoRoot, '--config-file', $CheckovConfig)
    }
    Invoke-Gate 'repository' 'Trivy' {
        Invoke-Native -Command $script:TrivyCommand -Arguments @(
            'config', $RepoRoot, '--exit-code', '1', '--ignorefile', $TrivyIgnore,
            '--severity', 'MEDIUM,HIGH,CRITICAL'
        )
    }
    Invoke-Gate 'repository' 'yamllint' {
        Invoke-Python @('-m', 'yamllint', '-c', $YamllintConfig, $RepoRoot)
    }

    Show-Summary
    if ($Fail -gt 0) {
        exit 1
    }
    exit 0
}
catch {
    Write-Log ERROR "Failed step: $CurrentStep"
    Write-Log ERROR $_.Exception.Message
    exit 2
}
finally {
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}
