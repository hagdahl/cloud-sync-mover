# Invoke-CloudSyncMove.ps1 - orchestrator. Dry-run/plan by default. Destructive steps are opt-in and gated.
param(
    [Parameter(Mandatory)][string]$Config,
    [ValidateSet('plan','inventory','baseline','preflight','structure','verify','diagnose','retire-source')]
    [string]$Phase = 'plan',
    [switch]$Execute,
    [switch]$SyncConfirmed,
    [switch]$Force
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
    'preflight' { & (Join-Path $PSScriptRoot 'Test-MovePreflight.ps1')   -Config $Config -SyncConfirmed:$SyncConfirmed }
    'structure' { & (Join-Path $PSScriptRoot 'Compare-MoveStructure.ps1') -Config $Config }
    'verify'    { & (Join-Path $PSScriptRoot 'Invoke-HydrationVerify.ps1') -Config $Config }
    'diagnose'  { & (Join-Path $PSScriptRoot 'Read-OneDriveSyncState.ps1') -Config $Config }
    'retire-source' {
        $backup = Join-Path ([System.IO.Path]::GetPathRoot($tgt)) ("OldSyncSourceBackup_{0}" -f (New-CsmStamp))

        # Prerequisite gate (#2): decide from phase evidence, not operator memory.
        $gate = Assert-CsmRetireReady -Config $cfg -WorkDir $wd
        Write-Host "=== retire-source prerequisite gate (#2) ==="
        if ($gate.ok) {
            Write-Host "  GATE: PASS - preflight/structure/verify present, green, consistent, and stable for >= $minDays days."
        } else {
            Write-Host "  GATE: BLOCKED - unmet prerequisites:"
            $gate.reasons | ForEach-Object { Write-Host ("    - {0}" -f $_) }
        }

        if (-not $Execute) {
            Write-Host ""
            Write-Host "DRY-RUN retire-source:"
            Write-Host "  Would MOVE old source: $src"
            Write-Host "               to backup: $backup   (robocopy /MOVE /XJ /XJD /XJF)"
            Write-Host "  Re-run with -Execute once the gate passes (or -Execute -Force to override; the override is recorded)."
            return
        }

        if (-not $gate.ok -and -not $Force) {
            Write-Host ""
            Write-Host "REFUSED: prerequisites not met. Resolve the items above, or re-run with -Force to override (recorded)."
            exit 2
        }
        if (-not $gate.ok -and $Force) {
            Write-Host ""
            Write-Host "WARNING: -Force overrides an UNMET retire gate. This bypasses safety evidence and is recorded in the artifact."
        }

        Write-Host ""
        Write-Host "IRREVERSIBLE: about to MOVE (not delete) the old source to a backup folder."
        Write-Host "  source: $src"
        Write-Host "  backup: $backup"
        $ans = Read-Host "Type MOVE to proceed"
        if ($ans -ne 'MOVE') { Write-Host "Aborted."; return }

        # Defense-in-depth (review F6): never hand robocopy /MOVE an empty or non-existent source.
        if (-not $src -or -not $tgt) { Write-Host "REFUSED: source_root/target_root not set."; exit 2 }
        if (-not (Test-Path -LiteralPath $src)) { Write-Host "REFUSED: source_root does not exist: $src"; exit 2 }

        # /XJ /XJD /XJF (#13): never traverse junctions/symlinks during /MOVE, so /MOVE cannot delete through a reparse point.
        robocopy $src $backup /E /MOVE /XJ /XJD /XJF /R:2 /W:1 | Out-Null
        $rc = $LASTEXITCODE   # robocopy: 0-7 = success bits, >= 8 = at least one failure (#3)
        $ok = ($rc -lt 8)
        $rstamp = New-CsmStamp
        $rdone  = Join-Path $wd "retire_${rstamp}_done.json"
        $meta = New-CsmMeta -Config $cfg -Phase 'retire-source' -Success $ok -Errors ($(if ($ok) { 0 } else { 1 })) -ErrorCategories $(if ($ok) { @() } else { @('robocopy') })
        $meta['backup']        = $backup
        $meta['robocopy_exit'] = $rc
        $meta['gate_passed']   = [bool]$gate.ok
        $meta['forced']        = [bool]($Force -and -not $gate.ok)
        Write-CsmAtomic $rdone ($meta | ConvertTo-Json)
        if ($ok) {
            Write-Host "Moved old source to $backup (robocopy exit $rc). Delete the backup only much later, after continued stability."
        } else {
            Write-Host "ROBOCOPY REPORTED FAILURE (exit $rc). Files may remain in the source. Do NOT delete anything; inspect the output and $rdone."
            exit 1
        }
    }
}