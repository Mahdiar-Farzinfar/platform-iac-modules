#requires -Version 5.1
<#
.SYNOPSIS
    Thin PowerShell wrapper for tests/smoke/run-smoke-tests.py (the SoT).

.DESCRIPTION
    Responsibilities are intentionally minimal:
      1. Resolve a verified Python 3 interpreter (SMOKE_PYTHON override, then
         the Windows launcher `py -3`, then python3/python on PATH).
      2. Forward all arguments, unchanged, to run-smoke-tests.py.
      3. Propagate its exit code verbatim (0 ok, 1 checks failed,
         2 internal error, 130 interrupted).

    All flags and behavior are documented in: run-smoke-tests.py --help

.EXAMPLE
    ./run-smoke-tests.ps1
    ./run-smoke-tests.ps1 --module kms --skip-lint
    ./run-smoke-tests.ps1 --verbose
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sot = Join-Path -Path $PSScriptRoot -ChildPath 'run-smoke-tests.py'
if (-not (Test-Path -LiteralPath $sot -PathType Leaf)) {
    [Console]::Error.WriteLine("error: source-of-truth script not found: $sot")
    exit 2
}

function Resolve-Python3 {
    if ($env:SMOKE_PYTHON) {
        $cmd = Get-Command -Name $env:SMOKE_PYTHON -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) {
            $candidate = @($cmd.Source)
            if (Test-Python3 -CommandSpec $candidate) { return $candidate }
        }
        [Console]::Error.WriteLine("error: SMOKE_PYTHON must resolve to a Python 3 executable: $($env:SMOKE_PYTHON)")
        return $null
    }

    # Windows Python launcher: pin major version 3 explicitly.
    $launcher = Get-Command -Name 'py' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($launcher) {
        $candidate = @($launcher.Source, '-3')
        if (Test-Python3 -CommandSpec $candidate) { return $candidate }
    }

    foreach ($name in @('python3', 'python')) {
        $cmd = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $cmd) { continue }
        $candidate = @($cmd.Source)
        if (Test-Python3 -CommandSpec $candidate) { return $candidate }
    }

    [Console]::Error.WriteLine('error: no Python 3 interpreter found on PATH (tried: py -3, python3, python). Install Python 3 or set SMOKE_PYTHON.')
    return $null
}

function Test-Python3 {
    param([Parameter(Mandatory = $true)][string[]]$CommandSpec)

    $executable = $CommandSpec[0]
    $arguments = @()
    if ($CommandSpec.Count -gt 1) {
        $arguments = @($CommandSpec | Select-Object -Skip 1)
    }

    try {
        & $executable @arguments -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

$python = @(Resolve-Python3)
if (-not $python) { exit 2 }

$pythonArguments = @()
if ($python.Count -gt 1) {
    $pythonArguments = @($python | Select-Object -Skip 1)
}

& $python[0] @pythonArguments $sot @RemainingArgs
exit $LASTEXITCODE
