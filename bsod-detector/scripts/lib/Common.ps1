# Common.ps1 — shared helpers for BSOD-detector scripts.
# Requires: PowerShell 5.1+ (Windows). Dot-source this from each script:
#   . "$PSScriptRoot\lib\Common.ps1"
#
# Provides:
#   - $DataDir / $RepoRoot path resolution
#   - Get-BsodData      : load a data/*.json source-of-truth file
#   - Write-JsonResult  : emit a single JSON object to stdout (the script contract)
#   - Fail              : write an error result to stdout and exit non-zero
#
# Convention: every script prints exactly ONE JSON object to stdout. Diagnostic
# chatter goes to the *information*/*error* streams (Write-Host / Write-Error),
# never to stdout, so downstream consumers can parse stdout as pure JSON.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts/lib/Common.ps1 -> repo root is two levels up.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:DataDir  = Join-Path $script:RepoRoot 'data'

function Get-BsodData {
    <#
    .SYNOPSIS Load a source-of-truth JSON file from data/.
    .PARAMETER Name File name under data/, e.g. 'bugcheck-codes.json'.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:DataDir $Name
    if (-not (Test-Path $path)) { throw "Data file not found: $path" }
    Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Write-JsonResult {
    <#
    .SYNOPSIS Emit the script's single JSON result object to stdout.
    .PARAMETER Object The object to serialize.
    #>
    param([Parameter(Mandatory)]$Object)
    $Object | ConvertTo-Json -Depth 12
}

function Fail {
    <#
    .SYNOPSIS Emit a structured error result to stdout and exit non-zero.
    #>
    param([Parameter(Mandatory)][string]$Message, [int]$ExitCode = 1)
    Write-JsonResult ([ordered]@{
        ok      = $false
        error   = $Message
        script  = (Split-Path -Leaf $MyInvocation.ScriptName)
    })
    exit $ExitCode
}

function Test-IsAdministrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
