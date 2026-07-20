# Read-GoogleDriveLogs.ps1 - scan Google Drive for desktop logs for the inode-trap / deletion markers.
# drive_fs.txt is cleartext. These markers are the EARLY WARNING that a junction/move went wrong.
param([int]$TailLines = 20000)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"
$logdir = Join-Path $env:LOCALAPPDATA "Google\DriveFS\Logs"
if (-not (Test-Path -LiteralPath $logdir)) { throw "Google Drive logs not found: $logdir (provider must be Google Drive)" }
$log = Get-ChildItem (Join-Path $logdir "drive_fs*.txt") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) { throw "drive_fs.txt not found in $logdir" }

# marker -> meaning
$markers = [ordered]@{
    'MIRROR_GDOC_DELETED' = 'CLOUD DELETION - content was trashed in the cloud (the GDrive failure mode)'
    'changed inode'       = 'root identity changed - junction/move inode trap'
    'VerifyRoot'          = 'root verification event'
    'HandleFailedChange'  = 'self-heal failure (often Path not found)'
    'Path not found'      = 'reconcile path miss'
}
$lines = Get-Content -LiteralPath $log.FullName -Tail $TailLines
Write-Host ("Log: {0}  ({1})  tail={2} lines" -f $log.Name, $log.LastWriteTime, $TailLines)
$danger = $false
foreach ($k in $markers.Keys) {
    $c = ($lines | Select-String -SimpleMatch $k).Count
    if ($c -gt 0) {
        Write-Host ("  {0,-22} {1,6}  - {2}" -f $k, $c, $markers[$k])
        if ($k -eq 'MIRROR_GDOC_DELETED' -or $k -eq 'changed inode') { $danger = $true }
    }
}
if (-not $danger) {
    Write-Host "  No deletion/inode markers in the scanned tail - this is NOT proof of health (absence"
    Write-Host "  of a danger marker is not a positive signal, ADR-012). Confirm with Invoke-CsmDiagnose"
    Write-Host "  and Invoke-RoundTripProbe before trusting the mirror or retiring the source."
} else {
    Write-Host "  WARNING: deletion/inode markers present. If MIRROR_GDOC_DELETED is growing, STOP Drive"
    Write-Host "           NOW (stop_all_jobs.ps1) and follow the Google Drive recovery notes before restart."
}