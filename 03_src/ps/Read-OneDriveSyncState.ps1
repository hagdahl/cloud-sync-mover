# Read-OneDriveSyncState.ps1 - snapshot OneDrive state DBs (read-only) and summarize via Python.
# Diagnoses "N sync errors": distinguishes transient throttling from real hard errors.
param([Parameter(Mandatory)][string]$Config, [switch]$KeepSnapshot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-CsmConfig -Path $Config
$wd  = Get-CsmWorkDir -Config $cfg
$settings = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\settings"
if (-not (Test-Path -LiteralPath $settings)) { throw "OneDrive settings not found: $settings (provider must be OneDrive)" }

$snap = Join-Path $wd "state_snapshot"
if (Test-Path -LiteralPath $snap) { Remove-Item -LiteralPath $snap -Recurse -Force }
New-Item -ItemType Directory -Force -Path $snap | Out-Null

# Copy DB + WAL + SHM together (safe: read side only; never open live read-write).
$accts = Get-ChildItem -LiteralPath $settings -Directory | Where-Object { Test-Path (Join-Path $_.FullName "SyncEngineDatabase.db") }
foreach ($ad in $accts) {
    $dst = Join-Path $snap $ad.Name
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($b in @("SyncEngineDatabase.db", "OCSI.db")) {
        foreach ($suf in @("", "-wal", "-shm")) {
            $f = Join-Path $ad.FullName ($b + $suf)
            if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $dst ($b + $suf)) -Force -EA SilentlyContinue }
        }
    }
}

$py = (Get-Command python -EA SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -EA SilentlyContinue).Source }
if (-not $py) { throw "Python not found (needed to read SQLite state)" }

$report = Join-Path $wd ("state_report_{0}.json" -f (New-CsmStamp))
& $py (Join-Path $PSScriptRoot "..\py\read_sync_state.py") $snap | Tee-Object -FilePath $report
if (-not $KeepSnapshot) { Remove-Item -LiteralPath $snap -Recurse -Force -EA SilentlyContinue }
Write-Host "State report -> $report"