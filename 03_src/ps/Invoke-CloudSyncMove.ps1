# Invoke-CloudSyncMove.ps1 - orchestrator. Dry-run/plan by default. Destructive steps are opt-in and gated.
param(
    [Parameter(Mandatory)][string]$Config,
    [ValidateSet('plan','inventory','baseline','preflight','structure','verify','diagnose','retire-source')]
    [string]$Phase = 'plan',
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg     = Get-CsmConfig -Path $Config
$wd      = Get-CsmWorkDir -Config $cfg
$src     = Get-CsmValue $cfg 'paths' 'source_root'
$tgt     = Get-CsmValue $cfg 'paths' 'target_root'
$prov    = Get-CsmValue $cfg 'provider' 'name' 'unknown'
$minDays = [int](Get-CsmValue $cfg 'move' 'min_stable_days' 5)

switch ($Phase) {
    'plan' {
        Write-Host "=== cloud-sync-mover : plan (nothing is changed) ==="
        Write-Host "provider   : $prov"
        Write-Host "source_root: $src"
        Write-Host "target_root: $tgt"
        Write-Host "work_dir   : $wd"
        Write-Host ""
        Write-Host "Safe read-only phases (run now):"
        Write-Host "  -Phase inventory   read-only attribute inventory"
        Write-Host "  -Phase baseline    MD5 baseline of local files"
        Write-Host "  -Phase preflight   space / writability / disk-type gates"
        Write-Host "  (then perform the move via the CLIENT - Method A - see 01_docs/PROVIDER-NOTES.md)"
        Write-Host "  -Phase structure   structure diff inventory vs target"
        Write-Host "  -Phase verify      hydration-aware MD5 verify"
        Write-Host "  -Phase diagnose    read OneDrive sync-state (throttling vs hard errors)"
        Write-Host ""
        Write-Host "Destructive (gated): -Phase retire-source -Execute  (>= $minDays days stable sync first)"
    }
    'inventory' { & (Join-Path $PSScriptRoot 'Invoke-Inventory.ps1')     -Config $Config }
    'baseline'  { & (Join-Path $PSScriptRoot 'Invoke-Md5Baseline.ps1')   -Config $Config }
    'preflight' { & (Join-Path $PSScriptRoot 'Test-MovePreflight.ps1')   -Config $Config }
    'structure' { & (Join-Path $PSScriptRoot 'Compare-MoveStructure.ps1') -Config $Config }
    'verify'    { & (Join-Path $PSScriptRoot 'Invoke-HydrationVerify.ps1') -Config $Config }
    'diagnose'  { & (Join-Path $PSScriptRoot 'Read-OneDriveSyncState.ps1') -Config $Config }
    'retire-source' {
        $backup = Join-Path ([System.IO.Path]::GetPathRoot($tgt)) ("OldSyncSourceBackup_{0}" -f (New-CsmStamp))
        if (-not $Execute) {
            Write-Host "DRY-RUN retire-source:"
            Write-Host "  Would MOVE old source: $src"
            Write-Host "               to backup: $backup"
            Write-Host "  Precondition: >= $minDays days stable sync + green verify. Re-run with -Execute to perform."
            return
        }
        Write-Host "IRREVERSIBLE: about to MOVE (not delete) the old source to a backup folder."
        Write-Host "  source: $src"
        Write-Host "  backup: $backup"
        $ans = Read-Host "Confirm >= $minDays days stable sync + green verify. Type MOVE to proceed"
        if ($ans -ne 'MOVE') { Write-Host "Aborted."; return }
        robocopy $src $backup /E /MOVE /R:2 /W:1 | Out-Null
        Write-Host "Moved old source to $backup. Delete the backup only much later, after continued stability."
    }
}