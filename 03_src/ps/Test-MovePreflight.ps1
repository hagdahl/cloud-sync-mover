# Test-MovePreflight.ps1 - Phase 2: gates before the move (free space, writability, disk type, sync-health)
param([Parameter(Mandatory)][string]$Config, [switch]$SyncConfirmed)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-CsmConfig -Path $Config
$src = Get-CsmValue $cfg 'paths' 'source_root'
$tgt = Get-CsmValue $cfg 'paths' 'target_root'
$wd  = Get-CsmWorkDir -Config $cfg
if (-not $tgt) { throw "target_root not set" }
$stamp = New-CsmStamp
$log   = Join-Path $wd "preflight_$stamp.log"
$done  = Join-Path $wd "preflight_${stamp}_done.json"
$checks = [ordered]@{}; $pass = $true

# 0) Provider/mode validity (#6): reject an invalid provider/mode combination up front.
try { $checks['provider_mode'] = Resolve-CsmProviderMode $cfg }
catch { $checks['provider_mode'] = "INVALID: $($_.Exception.Message)"; $pass = $false }

# 1) Needed space = sum of LOCAL file bytes from latest inventory (FoD preserved -> not the whole cloud)
$inv = Get-ChildItem (Join-Path $wd "inventory_*.csv") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$needed = $null
if ($inv) {
    $sr = [System.IO.StreamReader]::new($inv.FullName); [void]$sr.ReadLine(); $sum = [long]0
    while (($l = $sr.ReadLine()) -ne $null) { $c = $l.Split("`t"); if ($c.Length -ge 5 -and $c[4] -ne 'online-only') { $sum += [long]$c[1] } }
    $sr.Close(); $needed = $sum
    $checks['needed_local_gb'] = [math]::Round($needed / 1GB, 2)
} else {
    $checks['needed_local_gb'] = 'UNKNOWN (run inventory first)'; $pass = $false
}

# 2) Target free space
$tgtRoot = [System.IO.Path]::GetPathRoot($tgt)
try {
    $di = New-Object System.IO.DriveInfo $tgtRoot
    $free = $di.AvailableFreeSpace
    $checks['target_free_gb'] = [math]::Round($free / 1GB, 2)
    if ($needed -ne $null -and $free -lt ($needed * 1.1)) { $checks['space_ok'] = $false; $pass = $false } else { $checks['space_ok'] = $true }
} catch { $checks['target_free_gb'] = "ERROR: $($_.Exception.Message)"; $pass = $false }

# 3) Writability probe on the target root
$probeDir = if (Test-Path -LiteralPath $tgt) { $tgt } else { $tgtRoot }
$checks['target_writable'] = Test-CsmWritable $probeDir
if (-not $checks['target_writable']) { $pass = $false }

# 4) Disk media type (SMR warning: SMR shows as HDD; look up the model manually)
try {
    $letter = $tgtRoot.TrimEnd(':\')
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    $disk = $part | Get-Disk -ErrorAction SilentlyContinue
    $pd   = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$disk.Number }
    $checks['target_media'] = if ($pd) { $pd.MediaType } else { 'Unknown' }
    $checks['target_model'] = if ($pd) { $pd.FriendlyName } else { 'Unknown' }
    if ($pd -and $pd.MediaType -eq 'HDD') { $checks['smr_warning'] = 'Target is an HDD - verify the model is NOT SMR before hosting an active sync folder here.' }
} catch { $checks['target_media'] = "ERROR: $($_.Exception.Message)" }

# 4b) Reparse-point / junction awareness (#13): report whether each root IS a reparse point, where
#     it physically resolves, any reparse ancestor, and any immediate child junction (whose subtree
#     the read phases deliberately skip - flag it so the operator knows a subtree was excluded).
$rp = [ordered]@{}
foreach ($pair in @(@('source', $src), @('target', $tgt))) {
    $label = $pair[0]; $p = $pair[1]
    if (-not $p) { continue }
    $rp["${label}_is_reparse"] = (Test-CsmReparsePoint $p)
    $rp["${label}_physical"]   = (Resolve-CsmPhysicalRoot $p)
    $anc = @()
    try { $d = (New-Object System.IO.DirectoryInfo $p).Parent
          while ($d) { if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $anc += $d.FullName }; $d = $d.Parent } } catch { }
    if ($anc.Count) { $rp["${label}_reparse_ancestors"] = ($anc -join '; ') }
    $child = @()
    try { foreach ($sd in [System.IO.Directory]::EnumerateDirectories($p)) { if (Test-CsmReparsePoint $sd) { $child += (Split-Path $sd -Leaf) } } } catch { }
    if ($child.Count) { $rp["${label}_child_junctions"] = ($child -join '; ') }
}
$checks['reparse'] = ($rp | ConvertTo-Json -Compress)
if ($rp['source_child_junctions'] -or $rp['target_child_junctions']) {
    $checks['reparse_note'] = 'Child junction(s) found under a root; their subtrees are EXCLUDED from inventory/verify (junction-safety). Confirm no needed data lives behind them.'
}

# 4c) Provider-mode consistency (#6): Google Drive 'mirror' mode expects COMPLETE local content, so
#     any online-only file (or a non-green inventory) means the local set is incomplete -> block.
$modeNow = try { Resolve-CsmProviderMode $cfg } catch { 'invalid' }
if ($modeNow -eq 'mirror') {
    $inv = Get-CsmLatestArtifact $wd 'inventory'
    if (-not $inv) { $checks['mirror_content'] = 'UNKNOWN (run inventory first)'; $pass = $false }
    elseif ([int]$inv.online_only -gt 0) { $checks['mirror_content'] = "FAIL: mirror mode but $($inv.online_only) online-only file(s) - local content incomplete"; $pass = $false }
    elseif (-not (Test-CsmArtifactSuccess $inv)) { $checks['mirror_content'] = 'FAIL: latest inventory not green (access errors)'; $pass = $false }
    else { $checks['mirror_content'] = 'OK (complete local content)' }
} else {
    $checks['mirror_content'] = 'n/a'
}

# 4d) Provider-internal staging health (#4): top-level isolated probe + size/accessibility flags.
$noise = Get-CsmNoisePatterns $cfg
$stg = New-Object System.Collections.Generic.List[object]
$warnGb = [double](Get-CsmValue $cfg 'enumeration' 'staging_warn_gb' 1)
if ($src -and (Test-Path -LiteralPath $src)) {
    try {
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($src.TrimEnd('\'))) {
            $name = Split-Path $sd -Leaf
            $isNoise = $false; foreach ($pat in $noise) { if ($name -like $pat) { $isNoise = $true; break } }
            if (-not $isNoise) { continue }
            $writable = Test-CsmWritable $sd   # isolated write+delete probe (no existing file touched)
            $bytes = -1; try { $bytes = [long]((Get-ChildItem -LiteralPath $sd -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum) } catch { }
            $flag = 'ok'
            if (-not $writable) { $flag = 'inaccessible' } elseif ($bytes -ge ($warnGb * 1GB)) { $flag = 'large' }
            $stg.Add([pscustomobject]@{ name = $name; gb = $(if ($bytes -ge 0) { [math]::Round($bytes / 1GB, 3) } else { -1 }); writable = $writable; flag = $flag })
        }
    } catch { }
}
if ($stg.Count) {
    $checks['staging'] = ($stg | ConvertTo-Json -Compress)
    if (@($stg | Where-Object { $_.flag -ne 'ok' }).Count) {
        $checks['staging_note'] = 'A provider staging dir is large or inaccessible - a persistently large/stuck staging area can signal a blocked upload queue. Investigate before retiring the source.'
    }
}

# 4e) Recent provider diagnosis (#5/#15/#1): a fresh 'initializing' verdict means the client is mid
#     startup/scan - the right answer is WAIT, not a hard fail. A fresh 'blocked' verdict is a real
#     danger and fails. 'warning' is advisory (recorded, does not block). Staleness is honored: an old
#     diagnose is ignored (transient states expire).
$needsWait = $false
$diag = Get-CsmLatestArtifact $wd 'diagnose'
if ($diag) {
    $maxAgeMin = [double](Get-CsmValue $cfg 'diagnose' 'max_age_minutes' 30)
    $ageDays = Get-CsmArtifactAgeDays $diag (Get-Date).ToUniversalTime()   # zone-correct parse (AssumeUniversal)
    $ageMin = if ($null -ne $ageDays) { $ageDays * 1440.0 } else { $null }
    $dh = "$($diag.health)"
    if ($null -ne $ageMin -and $ageMin -ge 0 -and $ageMin -le $maxAgeMin) {
        $checks['diagnose_health'] = $dh
        $checks['diagnose_age_min'] = [math]::Round($ageMin, 1)
        if ($dh -eq 'initializing') { $checks['diagnose_note'] = 'Provider is initializing (startup/scan in progress) - WAIT for it to reach steady/healthy before moving.'; $needsWait = $true; $pass = $false }
        elseif ($dh -eq 'blocked')  { $checks['diagnose_note'] = 'Provider diagnosis is BLOCKED (stalled / poison marker / retry loop) - resolve before moving.'; $pass = $false }
        elseif ($dh -eq 'warning')  { $checks['diagnose_note'] = 'Provider diagnosis raised a WARNING (access-denied or rising errors) - advisory; investigate.' }
    } else {
        $checks['diagnose_health'] = "STALE (ignored; age too old or unknown)"
    }
}

# 5) Sync-health gate (#1): a real gate, not a passive reminder.
#    CONFIRMED only via -SyncConfirmed or [move] assume_up_to_date=true; otherwise NEEDS_CONFIRMATION -> FAIL.
$sh = Resolve-CsmSyncHealth $cfg -Confirmed:$SyncConfirmed
$checks['sync_health']        = $sh.status
$checks['sync_health_source'] = $sh.source
$checks['sync_health_hint']   = 'Confirm the sync client shows "Up to date" (no pending changes), then pass -SyncConfirmed or set [move] assume_up_to_date=true.'
if ($sh.status -ne 'CONFIRMED') { $pass = $false }

# Assemble the artifact: common meta header (#7) + the individual checks.
$meta = New-CsmMeta -Config $cfg -Phase 'preflight' -Success $pass
foreach ($k in $checks.Keys) { $meta[$k] = $checks[$k] }
$meta['PASS'] = $pass   # legacy readability field
Write-CsmAtomic $done ($meta | ConvertTo-Json)
$meta.GetEnumerator() | ForEach-Object { Write-CsmLog ("{0}: {1}" -f $_.Key, $_.Value) $log }
$verdict = if ($pass) { 'PASS' } elseif ($needsWait) { 'NEEDS_WAIT' } elseif ($sh.status -ne 'CONFIRMED') { 'NEEDS_CONFIRMATION' } else { 'FAIL' }
Write-Host ("PREFLIGHT: {0}{1}" -f $verdict, ($(if ($pass) { '' } else { ' - see ' + $done })))