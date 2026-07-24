#!/usr/bin/env pwsh
<#
.SYNOPSIS
Thin PowerShell wrapper for bootstrap SoT (setup.py)

.DESCRIPTION
Delegates all bootstrap logic to scripts/bootstrap/setup.py.
This file must stay thin and contain no business logic.

Supports:
- Pass-through CLI args
- Auto Python launcher resolution (py/python3/python)
- Stable exit-code propagation
- Strict mode + robust error handling

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

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Resolve-PythonCommand {
    # Priority on Windows:
    # 1) py launcher (recommended)
    # 2) python3
    # 3) python
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return @('py', '-3')
    }
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        return @('python3')
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return @('python')
    }
    return $null
}

try {
    # Resolve wrapper directory robustly (works when invoked via Task/powershell -File)
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $pyScript  = Join-Path $scriptDir 'setup.py'

    if (-not (Test-Path -LiteralPath $pyScript -PathType Leaf)) {
        Write-Err "bootstrap wrapper error: setup.py not found at '$pyScript'."
        exit 99
    }

    $pythonCmd = Resolve-PythonCommand
    if ($null -eq $pythonCmd) {
        Write-Err "bootstrap wrapper error: Python not found in PATH (expected py/python3/python)."
        exit 2
    }

    # Build argv safely as array to avoid quoting issues
    $argv = @()
    $argv += $pythonCmd
    $argv += @($pyScript)
    if (-not $RemainingArgs -or $RemainingArgs.Count -eq 0) {
        Write-Err "bootstrap wrapper error: pass --plan or --apply"
        exit 2
    }
    if ($RemainingArgs) {
        $argv += $RemainingArgs
    }

    & $argv[0] $argv[1..($argv.Length - 1)]
    $code = $LASTEXITCODE

    if ($null -eq $code) { $code = 99 }
    exit $code
}
catch {
    Write-Err ("bootstrap wrapper unexpected error: " + $_.Exception.Message)
    exit 99
}
