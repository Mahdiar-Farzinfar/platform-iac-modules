#!/usr/bin/env pwsh
<#
.SYNOPSIS
Thin PowerShell wrapper for bootstrap SoT (setup.py)

.DESCRIPTION
Delegates all bootstrap logic to scripts/bootstrap/setup.py.
This file must stay thin and contain no business logic.

Responsibilities:
- Announce the host environment (OS/arch/wrapper) so setup.py can adapt
- Read the pinned Python version from tooling/.tool-versions
- Ensure a suitable Python interpreter exists (install it if missing)
- Pass-through CLI args (unchanged contract)
- Stable exit-code propagation
- Strict mode + robust error handling

Environment self-identification is exported via a stable contract
(BOOTSTRAP_WRAPPER_*) so setup.py can read it WITHOUT changing the argv
pass-through interface. This mirrors the Bash wrapper (setup.sh).

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap\setup.ps1 --plan

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap\setup.ps1 --apply --non-interactive --strict --json
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WrapperName = 'bootstrap:setup.ps1'
$script:WrapperKind = 'powershell'

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine("[$script:WrapperName][ERROR] $Message")
}

function Write-Info {
    param([string]$Message)
    Write-Host "[$script:WrapperName] $Message"
}

# --- Environment self-identification -----------------------------------------
# Detects host OS/arch and exports a normalized, stable contract for setup.py:
#   BOOTSTRAP_WRAPPER_KIND   -> "powershell"
#   BOOTSTRAP_WRAPPER_OS     -> normalized family: windows|linux|macos|bsd|unknown
#   BOOTSTRAP_WRAPPER_OS_RAW -> OS description (RuntimeInformation / OSVersion)
#   BOOTSTRAP_WRAPPER_ARCH   -> normalized: x86_64|arm64|x86|<raw>
#   BOOTSTRAP_WRAPPER_DISTRO -> linux distro id (from /etc/os-release) or ""
#   BOOTSTRAP_WRAPPER_KERNEL -> kernel/OS version string
#   BOOTSTRAP_WRAPPER_WSL    -> "1" when running under WSL, else "0"
#
# Kept aligned with setup.sh so both wrappers hand setup.py an identical schema.
function Set-EnvironmentContract {
    $os     = 'unknown'
    $osRaw  = ''
    $arch   = 'unknown'
    $distro = ''
    $kernel = ''
    $isWsl  = '0'

    $rti = $null
    try { $rti = [System.Runtime.InteropServices.RuntimeInformation] } catch { }

    # OS family
    if ($rti) {
        try {
            $osRaw = [string]$rti::OSDescription
            if     ($rti::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $os = 'windows' }
            elseif ($rti::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux))   { $os = 'linux' }
            elseif ($rti::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX))     { $os = 'macos' }
            elseif ($rti::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Create('FREEBSD'))) { $os = 'bsd' }
        }
        catch { }
    }

    # Fallbacks for Windows PowerShell 5.1 (limited RuntimeInformation surface).
    if ($os -eq 'unknown') {
        if     ($IsWindows -or $env:OS -eq 'Windows_NT') { $os = 'windows' }
        elseif ($IsLinux)                                { $os = 'linux' }
        elseif ($IsMacOS)                                { $os = 'macos' }
    }
    if (-not $osRaw) {
        try { $osRaw = [string][System.Environment]::OSVersion.VersionString } catch { $osRaw = $os }
    }

    # Architecture (normalized to match setup.sh vocabulary).
    $rawArch = ''
    if ($rti) {
        try { $rawArch = [string]$rti::OSArchitecture } catch { }
    }
    if (-not $rawArch) { $rawArch = [string]$env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($rawArch) {
        '^(X64|AMD64|x86_64)$' { $arch = 'x86_64'; break }
        '^(Arm64|aarch64)$'    { $arch = 'arm64';  break }
        '^(X86|i[3-6]86)$'     { $arch = 'x86';    break }
        default                { $arch = if ($rawArch) { $rawArch } else { 'unknown' } }
    }

    # Kernel / OS version string.
    try { $kernel = [string][System.Environment]::OSVersion.Version } catch { $kernel = '' }

    # Linux distro identification + WSL detection (best-effort; non-fatal).
    if ($os -eq 'linux') {
        if (Test-Path -LiteralPath '/etc/os-release' -PathType Leaf) {
            $idLine = Get-Content -LiteralPath '/etc/os-release' -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^ID=' } | Select-Object -First 1
            if ($idLine) {
                $distro = ($idLine -replace '^ID=', '').Trim('"').Trim()
            }
        }
        if (Test-Path -LiteralPath '/proc/version' -PathType Leaf) {
            $procVersion = Get-Content -LiteralPath '/proc/version' -Raw -ErrorAction SilentlyContinue
            if ($procVersion -match '(?i)microsoft|wsl') { $isWsl = '1' }
        }
    }

    $env:BOOTSTRAP_WRAPPER_KIND   = $script:WrapperKind
    $env:BOOTSTRAP_WRAPPER_OS     = $os
    $env:BOOTSTRAP_WRAPPER_OS_RAW = $osRaw
    $env:BOOTSTRAP_WRAPPER_ARCH   = $arch
    $env:BOOTSTRAP_WRAPPER_DISTRO = $distro
    $env:BOOTSTRAP_WRAPPER_KERNEL = $kernel
    $env:BOOTSTRAP_WRAPPER_WSL    = $isWsl

    $distroDisplay = if ($distro) { $distro } else { 'n/a' }
    Write-Info "Host environment: os=$os arch=$arch distro=$distroDisplay wsl=$isWsl kernel=$kernel (wrapper=$script:WrapperKind)"
}

# --- Required version from tooling/.tool-versions ----------------------------
function Read-RequiredPythonVersion {
    param([string]$ToolVersionsFile)

    if (-not (Test-Path -LiteralPath $ToolVersionsFile -PathType Leaf)) {
        Write-Err "Tool versions file not found: '$ToolVersionsFile'."
        exit 99
    }

    $line = Get-Content -LiteralPath $ToolVersionsFile |
        Where-Object { $_ -match '^\s*python\s+\S+' } |
        Select-Object -First 1

    if (-not $line) {
        Write-Err "No 'python <version>' entry found in: '$ToolVersionsFile'."
        exit 99
    }

    $version = ($line -split '\s+' | Where-Object { $_ })[1]
    if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
        Write-Err "Invalid python version pin '$version' in: '$ToolVersionsFile'."
        exit 99
    }

    return $version
}

# --- Version helpers ----------------------------------------------------------
function Get-InterpreterVersion {
    # Returns dotted version string, or $null when the candidate is unusable.
    param([string[]]$Command)
    try {
        $out = & $Command[0] @($Command[1..($Command.Length - 1)] + @(
            '-c', 'import sys; print(".".join(map(str, sys.version_info[:3])))'
        )) 2>$null
        if ($LASTEXITCODE -eq 0 -and $out -match '^\d+\.\d+\.\d+$') {
            return [string]$out
        }
    }
    catch { }
    return $null
}

function Test-VersionSatisfies {
    # True when $Actual >= $Required (numeric, dotted).
    param([string]$Actual, [string]$Required)
    return ([version]$Actual -ge [version]$Required)
}

# --- Interpreter discovery ----------------------------------------------------
function Resolve-PythonCommand {
    param([string]$RequiredVersion)

    # Priority on Windows:
    # 1) py launcher (recommended)
    # 2) python3
    # 3) python
    $candidates = @()
    if (Get-Command py -ErrorAction SilentlyContinue)      { $candidates += ,@('py', '-3') }
    if (Get-Command python3 -ErrorAction SilentlyContinue) { $candidates += ,@('python3') }
    if (Get-Command python -ErrorAction SilentlyContinue)  { $candidates += ,@('python') }

    foreach ($candidate in $candidates) {
        $ver = Get-InterpreterVersion -Command $candidate
        if ($ver -and (Test-VersionSatisfies -Actual $ver -Required $RequiredVersion)) {
            return $candidate
        }
        if ($ver) {
            Write-Info "Skipping '$($candidate -join ' ')' (v$ver); requires >= $RequiredVersion"
        }
    }
    return $null
}

# --- Installation (pinned version via version managers, best-effort fallback) -
function Install-Python {
    param([string]$RequiredVersion)

    # 1) mise: installs the exact pinned version
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        Write-Info "Installing Python $RequiredVersion via mise..."
        & mise install "python@$RequiredVersion"
        if ($LASTEXITCODE -ne 0) { return $null }
        $prefix = (& mise where "python@$RequiredVersion").Trim()
        foreach ($rel in @('python.exe', 'bin\python3', 'bin/python3')) {
            $bin = Join-Path $prefix $rel
            if (Test-Path -LiteralPath $bin -PathType Leaf) { return ,@($bin) }
        }
        return $null
    }

    # 2) pyenv-win: installs the exact pinned version
    if (Get-Command pyenv -ErrorAction SilentlyContinue) {
        Write-Info "Installing Python $RequiredVersion via pyenv..."
        & pyenv install --skip-existing $RequiredVersion
        if ($LASTEXITCODE -ne 0) { return $null }
        $root = (& pyenv root).Trim()
        $bin = Join-Path (Join-Path (Join-Path $root 'versions') $RequiredVersion) 'python.exe'
        if (Test-Path -LiteralPath $bin -PathType Leaf) { return ,@($bin) }
        return $null
    }

    # Fallback: system package managers (major.minor only; exact pin not guaranteed)
    $majorMinor = ($RequiredVersion -split '\.')[0..1] -join '.'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "Installing Python $majorMinor via winget (best-effort; exact pin not guaranteed)..."
        & winget install --id "Python.Python.$majorMinor" -e --silent `
            --accept-package-agreements --accept-source-agreements
    }
    elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Installing Python $RequiredVersion via Chocolatey (best-effort)..."
        & choco install python --version=$RequiredVersion -y
    }
    elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Info "Installing Python via Scoop (best-effort; exact pin not guaranteed)..."
        & scoop install python
    }
    else {
        Write-Err "No supported installer found (mise/pyenv/winget/choco/scoop)."
        Write-Err "Install Python $RequiredVersion manually, then re-run this script."
        return $null
    }

    # Refresh PATH from machine/user scope so the new interpreter is discoverable
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = @($machinePath, $userPath | Where-Object { $_ }) -join ';'

    return Resolve-PythonCommand -RequiredVersion $RequiredVersion
}

try {
    # Announce the host environment BEFORE any delegation, so setup.py inherits
    # the BOOTSTRAP_WRAPPER_* contract and can adapt across operating systems.
    Set-EnvironmentContract

    # Resolve wrapper directory robustly (works when invoked via Task/powershell -File)
    $scriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
    $rootDir          = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
    $pyScript         = Join-Path $scriptDir 'setup.py'
    $toolVersionsFile = Join-Path (Join-Path $rootDir 'tooling') '.tool-versions'

    if (-not (Test-Path -LiteralPath $pyScript -PathType Leaf)) {
        Write-Err "setup.py not found at '$pyScript'."
        exit 99
    }

    $requiredVersion = Read-RequiredPythonVersion -ToolVersionsFile $toolVersionsFile
    Write-Info "Required Python version (from tooling/.tool-versions): $requiredVersion"

    $pythonCmd = Resolve-PythonCommand -RequiredVersion $requiredVersion
    if ($null -eq $pythonCmd) {
        Write-Info "No suitable Python found in PATH; attempting installation..."
        $pythonCmd = Install-Python -RequiredVersion $requiredVersion
        if ($null -eq $pythonCmd) {
            Write-Err "Python installation failed."
            exit 2
        }
    }

    # Post-resolution safety check: interpreter must run and satisfy the pin
    $resolvedVersion = Get-InterpreterVersion -Command $pythonCmd
    if (-not $resolvedVersion) {
        Write-Err "Unable to determine Python version from: '$($pythonCmd -join ' ')'."
        exit 2
    }
    if (-not (Test-VersionSatisfies -Actual $resolvedVersion -Required $requiredVersion)) {
        Write-Err "Resolved Python v$resolvedVersion does not satisfy required v$requiredVersion."
        exit 2
    }

    Write-Info "Using Python: $($pythonCmd -join ' ') (v$resolvedVersion)"

    if (-not $RemainingArgs -or $RemainingArgs.Count -eq 0) {
        Write-Err "pass --plan or --apply"
        exit 2
    }

    # Build argv safely as a flat array to avoid quoting issues.
    # Layout: <interpreter> [interpreter-flags...] <setup.py> [user-args...]
    $argv = @()
    $argv += $pythonCmd            # e.g. ('py','-3') or ('python3')
    $argv += @($pyScript)
    $argv += $RemainingArgs

    $exe      = $argv[0]
    $exeArgs  = @($argv[1..($argv.Length - 1)])

    # Execute from repo root for deterministic relative-path behavior.
    $code = $null
    Push-Location $rootDir
    try {
        # Single invocation; splat the remaining arguments to preserve the
        # argv pass-through contract exactly (no re-quoting, no duplication).
        & $exe @exeArgs
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($null -eq $code) { $code = 99 }
    exit $code
}
catch {
    Write-Err ("bootstrap wrapper unexpected error: " + $_.Exception.Message)
    exit 99
}
