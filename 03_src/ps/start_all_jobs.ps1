# start_all_jobs.ps1 - controlled restart of the sync client (A7).
param([string]$Config)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_common.ps1"
$prov = 'unknown'
if ($Config) { $cfg = Get-CsmConfig -Path $Config; $prov = Get-CsmValue $cfg 'provider' 'name' 'unknown' }

if ($prov -like 'onedrive*') {
    $od = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\OneDrive.exe"
    if (Test-Path $od) { Start-Process $od; Write-Host "OneDrive started." } else { Write-Host "OneDrive.exe not found; start manually." }
} elseif ($prov -eq 'google-drive') {
    Write-Host "Start Google Drive from the Start menu (no stable CLI launch path across versions)."
} else {
    Write-Host "Provider unknown; start the sync client manually."
}