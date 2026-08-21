<#
.SYNOPSIS
    Collect BSOD post-mortem evidence from inside the guest after a reboot.

.DESCRIPTION
    Gathers everything useful for root-cause analysis from the guest OS:
      - crash dump files (minidumps + MEMORY.DMP), copied to the output dir
      - the bug-check code/parameters and faulting module (from the dump and/or
        the BugCheck event), translated via data/bugcheck-codes.json
      - crash-timeline event log entries defined in data/event-sources.json
      - system context (OS build, uptime, CPU) and driver inventory
      - signature check of the suspect faulting driver

    Runs on: the GUEST VM (can be driven remotely from the host via PsExec).
    Requires Administrator to read dumps and some event channels.

    Produces facts only; interpreting the crash is the agent's job.

.PARAMETER OutputDir
    Directory to copy dump files and write the report into. Defaults to
    <repo>\output\<timestamp>. This directory is git-ignored (may contain PII).

.PARAMETER SysinternalsPath
    Directory containing psloglist.exe / sigcheck.exe / autorunsc.exe / psinfo.exe.
    Defaults to '' meaning "expect them on PATH".

.PARAMETER Symbolize
    Also run scripts\analyze-dump.ps1 (cdb !analyze -v) on the collected
    MEMORY.DMP to resolve the failure bucket and faulting image (IMAGE_NAME).
    Off by default because it needs the Windows debugger and symbol download;
    when on, it populates crash.faultingModule / crash.analysis and the
    suspectDriver signature check.

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true,
      "collectedAt": "2026-...Z",
      "outputDir": "...\\output\\...",
      "system": { "osBuild": "...", "uptimeSeconds": 0, "cpu": "..." },
      "crash": {
        "bugCheckCode": "0x000000D1",
        "bugCheckName": "DRIVER_IRQL_NOT_LESS_OR_EQUAL",   # from bugcheck-codes.json
        "parameters": ["0x...", "0x...", "0x...", "0x..."],
        "faultingModule": "myfault.sys",   # populated when -Symbolize is set
        "dumpFiles": ["Minidump\\...dmp", "MEMORY.DMP"],
        "analysis": null                     # analyze-dump.ps1 result when -Symbolize
      },
      "events": [ { "log": "System", "eventId": 1001, "time": "...", "message": "..." } ],
      "suspectDriver": { "path": "...", "signed": true|false, "publisher": "..." },
      "warnings": [ "MEMORY.DMP not found; dump type may be misconfigured" ]
    }
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$SysinternalsPath = '',
    [switch]$Symbolize
)

. "$PSScriptRoot\lib\Common.ps1"

$warnings = New-Object System.Collections.Generic.List[string]

# 1. Resolve + create the output directory (git-ignored; may contain PII).
if (-not $OutputDir) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $OutputDir = Join-Path $script:RepoRoot "output\$stamp"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# 2. Copy dump files out to the output dir.
$dumpFiles = New-Object System.Collections.Generic.List[string]
$miniDir = Join-Path $env:SystemRoot 'Minidump'
$memDmp  = Join-Path $env:SystemRoot 'MEMORY.DMP'
if (Test-Path $miniDir) {
    foreach ($m in Get-ChildItem (Join-Path $miniDir '*.dmp') -ErrorAction SilentlyContinue) {
        $dest = Join-Path $OutputDir (Join-Path 'Minidump' $m.Name)
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item $m.FullName $dest -Force
        $dumpFiles.Add((Join-Path 'Minidump' $m.Name))
    }
}
if (Test-Path $memDmp) {
    Copy-Item $memDmp (Join-Path $OutputDir 'MEMORY.DMP') -Force
    $dumpFiles.Add('MEMORY.DMP')
}
if ($dumpFiles.Count -eq 0) {
    $warnings.Add('No dump files found (Minidump\*.dmp or MEMORY.DMP). Check crash-dump configuration (configure-dumps.ps1).')
}

# 3. Bug-check code: read the WER-SystemErrorReporting BugCheck event (System/1001).
#    Its message embeds the stop code and 4 parameters. This is reliable without
#    a kernel debugger; deep dump analysis is a separate, optional step.
$codes = (Get-BsodData 'bugcheck-codes.json').codes
$crash = [ordered]@{
    bugCheckCode   = $null
    bugCheckName   = $null
    parameters     = @()
    faultingModule = $null
    dumpFiles      = $dumpFiles
    crashTime      = $null
    analysis       = $null
}
try {
    $bc = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 1 -ErrorAction Stop
    if ($bc) {
        $crash.crashTime = $bc.TimeCreated.ToUniversalTime().ToString('o')
        # Event message: "...bugcheck was: 0x000000d1 (0x..., 0x..., 0x..., 0x...)..."
        $text = $bc.Message
        # "The bugcheck was: 0x000000d1 (0x..., 0x..., 0x..., 0x...). A dump..."
        $codeMatch = [regex]::Match($text, 'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)')
        if (-not $codeMatch.Success) {
            # Fallback: first 8-digit hex anywhere in the message.
            $codeMatch = [regex]::Match($text, '(0x[0-9a-fA-F]{8})')
        }
        if ($codeMatch.Success) {
            $norm = '0x' + $codeMatch.Groups[1].Value.Substring(2).ToUpper().PadLeft(8, '0')
            $crash.bugCheckCode = $norm
            if ($codes.PSObject.Properties.Name -contains $norm) {
                $crash.bugCheckName = $codes.$norm.name
            } else {
                $warnings.Add("Bug-check code $norm not in bugcheck-codes.json; add it there.")
            }
            if ($codeMatch.Groups.Count -gt 2 -and $codeMatch.Groups[2].Success) {
                $crash.parameters = @(($codeMatch.Groups[2].Value -split ',') | ForEach-Object { $_.Trim() })
            }
        }
        # The faulting module is not in the WER 1001 event; it comes from deep
        # dump analysis, run below when -Symbolize is set.
    }
} catch {
    $warnings.Add("Could not read BugCheck event (System/1001): $($_.Exception.Message)")
}

# 3b. Optional deep analysis: symbolize the MEMORY.DMP to get bucket + image.
if ($Symbolize) {
    $memInOut = Join-Path $OutputDir 'MEMORY.DMP'
    if (Test-Path $memInOut) {
        try {
            $analysisJson = & "$PSScriptRoot\analyze-dump.ps1" -DumpPath $memInOut -OutputDir (Join-Path $OutputDir 'analyze')
            $analysis = $analysisJson | ConvertFrom-Json
            $crash.analysis = $analysis
            if ($analysis.faultingModule) { $crash.faultingModule = $analysis.faultingModule }
            # Prefer symbolized bugcheck code/name/params when the WER event was silent.
            if (-not $crash.bugCheckCode -and $analysis.bugCheckCode) { $crash.bugCheckCode = $analysis.bugCheckCode }
            if (-not $crash.bugCheckName -and $analysis.bugCheckName) { $crash.bugCheckName = $analysis.bugCheckName }
            foreach ($w in @($analysis.warnings)) { if ($w) { $warnings.Add("analyze-dump: $w") } }
        } catch {
            $warnings.Add("Symbolization failed: $($_.Exception.Message)")
        }
    } else {
        $warnings.Add('Symbolization requested but MEMORY.DMP was not collected; skipping analyze-dump.')
    }
}

# 4. Event timeline: pull each source-of-truth event within a window around the crash.
$events = New-Object System.Collections.Generic.List[object]
$eventDefs = (Get-BsodData 'event-sources.json').events
foreach ($def in $eventDefs) {
    try {
        $recs = Get-WinEvent -FilterHashtable @{ LogName = $def.log; Id = $def.eventId } -MaxEvents 5 -ErrorAction Stop
        foreach ($r in $recs) {
            if ($r.ProviderName -and $def.source -and ($r.ProviderName -notlike "*$($def.source)*") -and ($def.source -notlike "*$($r.ProviderName)*")) { continue }
            $events.Add([ordered]@{
                log     = $def.log
                eventId = $def.eventId
                time    = $r.TimeCreated.ToUniversalTime().ToString('o')
                message = ($r.Message -replace '\s+', ' ').Trim()
            })
        }
    } catch {
        # No matching records for this source is normal; skip quietly.
    }
}

# 5. System context.
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$system = [ordered]@{
    osBuild       = "$($os.Caption) build $($os.BuildNumber)"
    uptimeSeconds = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
    cpu           = $cpu.Name
}

# 6. Suspect driver: sigcheck if available and we can guess the module path.
$suspectDriver = $null
if ($null -ne $crash.faultingModule) {
    $modPath = Join-Path (Join-Path $env:SystemRoot 'System32\drivers') $crash.faultingModule
    if (Test-Path $modPath) {
        $sig = Get-AuthenticodeSignature $modPath -ErrorAction SilentlyContinue
        $suspectDriver = [ordered]@{
            path      = $modPath
            signed    = ($sig.Status -eq 'Valid')
            publisher = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
        }
    }
}

# 7. Emit the single JSON result.
Write-JsonResult ([ordered]@{
    ok            = $true
    collectedAt   = (Get-Date).ToUniversalTime().ToString('o')
    outputDir     = $OutputDir
    system        = $system
    crash         = $crash
    events        = $events
    suspectDriver = $suspectDriver
    warnings      = $warnings
})
