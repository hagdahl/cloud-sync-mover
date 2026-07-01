# stop_all_jobs.ps1 - emergency stop (A7): halt toolkit jobs and pause the sync client.
param([string]$Config)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_common.ps1"
$prov = 'unknown'
if ($Config) { $cfg = Get-CsmConfig -Path $Config; $prov = Get-CsmValue $cfg 'provider' 'name' 'unknown' }

Write-Host "Stopping toolkit background jobs (csm_*)..."
Get-Job -EA SilentlyContinue | Where-Object { $_.Name -like 'csm_*' } | ForEach-Object { Stop-Job $_ -EA SilentlyContinue; Remove-Job $_ -Force -EA SilentlyContinue }

if ($prov -like 'onedrive*') {
    $od = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\OneDrive.exe"
    if (Test-Path $od) { Write-Host "OneDrive /shutdown"; & $od /shutdown } else { Get-Process OneDrive -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
} elseif ($prov -eq 'google-drive') {
    Get-Process GoogleDriveFS -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
} else {
    Write-Host "Provider unknown; stop the sync client manually."
}
Write-Host "Stopped. Sync churn halted."