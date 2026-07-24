#Requires -Version 5.1
<#
.SYNOPSIS
  Single Windows entrypoint for Taskfile-driven automation.

.DESCRIPTION
  Taskfile must only invoke this script with -Task <name> and required params.
  Avoids fragile multi-line PowerShell embedded in YAML.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/tasks.ps1 `
    -Task preflight `
    -RootDir . `
    -GoModFile ./go.mod `
    -TerraformVersionFile ./tooling/.terraform-version `
    -ToolVersionsFile ./tooling/.tool-versions `
    -ToolsDir ./scripts/tools
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'preflight',
        'init',
        'fmt-go',
        'validate-terraform',
        'lint-tflint',
        'validate-go',
        'lint-go',
        'docs-generate',
        'docs-check',
        'test-terraform',
        'test-go',
        'test-smoke',
        'test-cross-platform'
    )]
    [string]$Task,

    [string]$RootDir,
    [string]$ModulesDir,
    [string]$GoModFile,
    [string]$TerraformVersionFile,
    [string]$ToolVersionsFile,
    [string]$ToolsDir,
    [string]$ConfigPath,
    [string]$TerraformDocsConfig,
    [string]$Timeout = '30m'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "$Label not found at $Path"
        exit 1
    }
}

function Assert-RequiredParam {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Error "Missing required parameter: -$Name"
        exit 1
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    & $Command
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Get-TerraformModuleDirs {
    param(
        [Parameter(Mandatory = $true)][string]$ModulesDir
    )
    Assert-PathExists -Path $ModulesDir -Label 'modules directory'

    $moduleDirs = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $ModulesDir -Recurse -Filter 'main.tf' -File | ForEach-Object {
        if ($_.FullName -notmatch '[\\/]\.terraform[\\/]') {
            [void]$moduleDirs.Add($_.Directory.FullName)
        }
    }

    return @($moduleDirs | Select-Object -Unique | Sort-Object)
}

function Test-HasGoFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir
    )
    $count = @(
        Get-ChildItem -LiteralPath $RootDir -Recurse -Filter '*.go' -File |
            Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' }
    ).Count
    return $count -gt 0
}

# -----------------------------------------------------------------------------
# Tasks
# -----------------------------------------------------------------------------
function Invoke-Preflight {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir
    Assert-RequiredParam -Name 'GoModFile' -Value $GoModFile
    Assert-RequiredParam -Name 'TerraformVersionFile' -Value $TerraformVersionFile
    Assert-RequiredParam -Name 'ToolVersionsFile' -Value $ToolVersionsFile
    Assert-RequiredParam -Name 'ToolsDir' -Value $ToolsDir

    Assert-PathExists -Path $GoModFile -Label 'go.mod'
    Assert-PathExists -Path $TerraformVersionFile -Label '.terraform-version'
    Assert-PathExists -Path $ToolVersionsFile -Label '.tool-versions'

    $verifyToolchain = Join-Path $ToolsDir 'verify-toolchain.py'
    Assert-PathExists -Path $verifyToolchain -Label 'verify-toolchain.py'
    Invoke-Native {
        python $verifyToolchain `
            --root $RootDir `
            --tool-versions-file $ToolVersionsFile `
            --terraform-version-file $TerraformVersionFile `
            --go-mod-file $GoModFile
    }

    $tfVersion = Get-Content -LiteralPath $TerraformVersionFile | Select-Object -First 1
    Write-Host ("Terraform version source-of-truth: " + $tfVersion)

    $goDirective = Select-String -Path $GoModFile -Pattern '^go\s+[0-9]+\.[0-9]+'
    if (-not $goDirective) {
        Write-Error "go directive not found in $GoModFile"
        exit 1
    }
    $goDirective | ForEach-Object { $_.Line } | Write-Host

    $toolLines = @(
        Select-String -Path $ToolVersionsFile -Pattern '^(terraform|tflint|tfsec|golangci-lint)\s+'
    )
    if ($toolLines.Count -eq 0) {
        Write-Error "Required tool versions not found in $ToolVersionsFile"
        exit 1
    }
    $toolLines | ForEach-Object { $_.Line } | Write-Host

    $verifyEnv = Join-Path $ToolsDir 'verify-env.py'
    Assert-PathExists -Path $verifyEnv -Label 'verify-env.py'
    Invoke-Native {
        python $verifyEnv --root $RootDir --strict
    }

    Write-Host 'Preflight checks passed.'
}

function Invoke-Init {
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir

    $moduleDirs = Get-TerraformModuleDirs -ModulesDir $ModulesDir
    if ($moduleDirs.Count -eq 0) {
        Write-Host "No Terraform modules found under $ModulesDir"
        return
    }

    foreach ($modulePath in $moduleDirs) {
        Write-Host "==> terraform init: $modulePath"
        Invoke-Native {
            terraform -chdir=$modulePath init -backend=false -upgrade
        }
    }
}

function Invoke-FmtGo {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir

    if (-not (Test-HasGoFiles -RootDir $RootDir)) {
        Write-Host 'No Go files detected. Skipping gofmt.'
        return
    }

    $files = @(
        Get-ChildItem -LiteralPath $RootDir -Recurse -Filter '*.go' -File |
            Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } |
            Select-Object -ExpandProperty FullName
    )

    Invoke-Native {
        gofmt -w @files
    }
}

function Invoke-ValidateTerraform {
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir

    $moduleDirs = Get-TerraformModuleDirs -ModulesDir $ModulesDir
    if ($moduleDirs.Count -eq 0) {
        Write-Host "No Terraform modules found under $ModulesDir"
        return
    }

    foreach ($modulePath in $moduleDirs) {
        Write-Host "==> terraform validate: $modulePath"
        Invoke-Native {
            terraform -chdir=$modulePath init -backend=false -upgrade
        }
        Invoke-Native {
            terraform -chdir=$modulePath validate
        }
    }
}

function Invoke-LintTflint {
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir
    Assert-RequiredParam -Name 'ConfigPath' -Value $ConfigPath

    Assert-PathExists -Path $ConfigPath -Label 'tflint config'
    $moduleDirs = Get-TerraformModuleDirs -ModulesDir $ModulesDir
    if ($moduleDirs.Count -eq 0) {
        Write-Host "No Terraform modules found under $ModulesDir"
        return
    }

    foreach ($modulePath in $moduleDirs) {
        Write-Host "==> tflint: $modulePath"
        Invoke-Native {
            tflint --init --config $ConfigPath --chdir $modulePath
        }
        Invoke-Native {
            tflint --config $ConfigPath --chdir $modulePath
        }
    }
}

function Invoke-ValidateGo {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir

    if (-not (Test-HasGoFiles -RootDir $RootDir)) {
        Write-Host 'No Go files detected. Skipping go vet.'
        return
    }

    Invoke-Native {
        go vet ./...
    }
}

function Invoke-LintGo {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir

    if (-not (Test-HasGoFiles -RootDir $RootDir)) {
        Write-Host 'No Go files detected. Skipping golangci-lint.'
        return
    }

    Invoke-Native {
        golangci-lint run ./...
    }
}

function Invoke-DocsGenerate {
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir
    Assert-RequiredParam -Name 'TerraformDocsConfig' -Value $TerraformDocsConfig

    Assert-PathExists -Path $TerraformDocsConfig -Label 'terraform-docs config'
    $moduleDirs = Get-TerraformModuleDirs -ModulesDir $ModulesDir
    if ($moduleDirs.Count -eq 0) {
        Write-Host "No Terraform modules found under $ModulesDir"
        return
    }

    foreach ($modulePath in $moduleDirs) {
        Write-Host "==> terraform-docs: $modulePath"
        Invoke-Native {
            terraform-docs markdown table `
                --config $TerraformDocsConfig `
                --output-file README.md `
                --output-mode inject `
                $modulePath
        }
    }
}

function Invoke-DocsCheck {
    git diff --quiet -- modules docs README.md
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Documentation is not up-to-date. Run: task docs'
        git --no-pager diff -- modules docs README.md
        exit 1
    }

    Write-Host 'Documentation is up-to-date.'
}

function Invoke-TestTerraform {
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir

    $moduleDirs = Get-TerraformModuleDirs -ModulesDir $ModulesDir
    if ($moduleDirs.Count -eq 0) {
        Write-Host "No Terraform modules found under $ModulesDir"
        return
    }

    foreach ($modulePath in $moduleDirs) {
        $testFile = Join-Path $modulePath 'tests/tftest.hcl'
        if (-not (Test-Path -LiteralPath $testFile)) {
            continue
        }

        Write-Host "==> terraform test: $modulePath"
        Invoke-Native {
            terraform -chdir=$modulePath test
        }
    }
}

function Invoke-TestGo {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir
    Assert-RequiredParam -Name 'ModulesDir' -Value $ModulesDir
    Assert-RequiredParam -Name 'Timeout' -Value $Timeout

    $files = @(
        Get-ChildItem -LiteralPath $ModulesDir -Recurse -Filter 'integration-test.go' -File -ErrorAction SilentlyContinue
    )
    if ($files.Count -eq 0) {
        Write-Host 'No integration-test.go files found. Skipping go test.'
        return
    }

    $rootResolved = (Resolve-Path -LiteralPath $RootDir).Path.TrimEnd('\', '/')
    $dirs = @(
        $files |
            ForEach-Object { Split-Path -Parent $_.DirectoryName } |
            Sort-Object -Unique
    )

    Write-Host '==> running go test for module integration tests'

    foreach ($d in $dirs) {
        $full = (Resolve-Path -LiteralPath $d).Path
        $rel = $full
        if ($full.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $full.Substring($rootResolved.Length).TrimStart('\', '/')
        }
        $pkg = './' + ($rel -replace '\\', '/')

        Write-Host ("==> go test: " + $pkg)
        Invoke-Native {
            go test $pkg -count=1 -timeout $Timeout -v
        }
    }
}

function Invoke-TestSmoke {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir

    $script = Join-Path $RootDir 'tests/smoke/run-smoke-tests.py'
    Assert-PathExists -Path $script -Label 'smoke test script'

    if (Get-Command python -ErrorAction SilentlyContinue) {
        Invoke-Native { python $script }
        return
    }

    if (Get-Command py -ErrorAction SilentlyContinue) {
        Invoke-Native { py $script }
        return
    }

    Write-Error 'Python launcher not found (python/py).'
    exit 1
}

function Invoke-TestCrossPlatform {
    Assert-RequiredParam -Name 'RootDir' -Value $RootDir

    # Resolve with Join-Path to avoid mixed separators from YAML/Taskfile.
    $script = Join-Path (Join-Path (Join-Path $RootDir 'tests') 'cross-platform') 'test-windows.ps1'
    Assert-PathExists -Path $script -Label 'Windows cross-platform test script'

    $resolved = (Resolve-Path -LiteralPath $script).Path
    Write-Host "==> running Windows cross-platform suite: $resolved"

    # Keep exit codes for Taskfile/CI.
    Invoke-Native {
        & $resolved
    }
}

# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
switch ($Task) {
    'preflight'           { Invoke-Preflight }
    'init'                { Invoke-Init }
    'fmt-go'              { Invoke-FmtGo }
    'validate-terraform'  { Invoke-ValidateTerraform }
    'lint-tflint'         { Invoke-LintTflint }
    'validate-go'         { Invoke-ValidateGo }
    'lint-go'             { Invoke-LintGo }
    'docs-generate'       { Invoke-DocsGenerate }
    'docs-check'          { Invoke-DocsCheck }
    'test-terraform'      { Invoke-TestTerraform }
    'test-go'             { Invoke-TestGo }
    'test-smoke'          { Invoke-TestSmoke }
    'test-cross-platform' { Invoke-TestCrossPlatform }
    default {
        Write-Error "Unknown task: $Task"
        exit 1
    }
}
