# Invoke-CloudSyncMove.ps1 - orchestrator. Dry-run/plan by default. Destructive steps are opt-in and gated.
param(
    [Parameter(Mandatory)][string]$Config,
    [ValidateSet('plan','inventory','baseline','preflight','structure','verify','diagnose','probe','retire-source')]
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
        Write-Host "  -Phase diagnose    provider-aware sync health (OneDrive/Google Drive; throttling vs hard errors, #5)"
        Write-Host "  -Phase probe       round-trip proof the provider is actually syncing (dry-run; -Execute writes one canary, #9)"
        Write-Host ""
        Write-Host "Destructive (gated): -Phase retire-source -Execute  (>= $minDays days stable sync first)"
    }
    'inventory' { & (Join-Path $PSScriptRoot 'Invoke-Inventory.ps1')     -Config $Config }
    'baseline'  { & (Join-Path $PSScriptRoot 'Invoke-Md5Baseline.ps1')   -Config $Config }
    'preflight' { & (Join-Path $PSScriptRoot 'Test-MovePreflight.ps1')   -Config $Config -SyncConfirmed:$SyncConfirmed }
    'structure' { & (Join-Path $PSScriptRoot 'Compare-MoveStructure.ps1') -Config $Config }
    'verify'    { & (Join-Path $PSScriptRoot 'Invoke-HydrationVerify.ps1') -Config $Config }
    'diagnose'  { & (Join-Path $PSScriptRoot 'Invoke-CsmDiagnose.ps1')     -Config $Config }
    'probe'     { & (Join-Path $PSScriptRoot 'Invoke-RoundTripProbe.ps1') -Config $Config -Execute:$Execute }
    'retire-source' {
        # Stable backup path (no timestamp) so a re-run RESUMES into the same folder (#3).
        $backup = Join-Path ([System.IO.Path]::GetPathRoot($tgt)) "OldSyncSourceBackup"

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

        # /MOVE deletes each source file only after a successful copy, so a file robocopy fails to
        # copy is LEFT in the source (#3: unverified files stay in place). /XJ /XJD /XJF (#13): never
        # traverse junctions during /MOVE.
        $srcN = $src.TrimEnd('\'); $bkN = $backup.TrimEnd('\')
        $rstamp = New-CsmStamp
        $rlog   = Join-Path $wd "retire_$rstamp.log"
        $rdone  = Join-Path $wd "retire_${rstamp}_done.json"
        $rman   = Join-Path $wd "retire_${rstamp}_manifest.json"
        robocopy $srcN $bkN /E /MOVE /XJ /XJD /XJF /R:2 /W:1 /NP "/LOG:$rlog" | Out-Null
        $rc = $LASTEXITCODE
        $rcInfo = Get-CsmRobocopyExitInfo $rc

        # Post-move verification (#3): whatever remains in the source is unverified/failed; the backup holds the moved set.
        $noise = Get-CsmNoisePatterns $cfg
        $leftover = @(Invoke-CsmWalk -Root $srcN -NoisePatterns $noise | ForEach-Object { $_.FullName.Substring($srcN.Length + 1) })
        $bk = Get-CsmDirFileStats -Root $bkN -NoisePatterns $noise
        $verified = ($rcInfo.success -and ($leftover.Count -eq 0))

        $manifest = [ordered]@{
            schema             = 'csm.retire-manifest/1'
            source             = $srcN
            backup             = $bkN
            robocopy_exit      = $rc
            robocopy_bits      = $rcInfo.bits
            backup_files       = $bk.files
            backup_bytes       = $bk.bytes
            leftover_count     = $leftover.Count
            leftover_in_source = @($leftover | Select-Object -First 500)
            verified           = $verified
            log                = $rlog
        }
        Write-CsmAtomic $rman ($manifest | ConvertTo-Json -Depth 5)

        $cats = @(); if (-not $rcInfo.success) { $cats += 'robocopy' }; if ($leftover.Count -gt 0) { $cats += 'unverified-leftover' }
        $meta = New-CsmMeta -Config $cfg -Phase 'retire-source' -Success $verified -Errors ($leftover.Count + $(if ($rcInfo.success) { 0 } else { 1 })) -ErrorCategories $cats
        $meta['backup']         = $bkN
        $meta['robocopy_exit']  = $rc
        $meta['robocopy_bits']  = $rcInfo.bits
        $meta['gate_passed']    = [bool]$gate.ok
        $meta['forced']         = [bool]($Force -and -not $gate.ok)
        $meta['backup_files']   = $bk.files
        $meta['leftover_count'] = $leftover.Count
        $meta['manifest']       = $rman
        $meta['log']            = $rlog
        Write-CsmAtomic $rdone ($meta | ConvertTo-Json -Depth 5)

        if ($verified) {
            Write-Host "RETIRE OK: source moved to $bkN (robocopy exit $rc; $($bk.files) files in backup). Source is empty and verified. Manifest: $rman"
        } else {
            Write-Host "RETIRE INCOMPLETE (robocopy exit $rc; $($leftover.Count) file(s) left in source)."
            Write-Host "  Unverified/failed files were LEFT IN PLACE. Inspect $rlog and $rman."
            Write-Host "  Re-run -Phase retire-source -Execute to RESUME (copies the remainder into the same backup, skips what already moved)."
            exit 1
        }
    }
}