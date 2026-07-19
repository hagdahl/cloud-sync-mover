# Test-Toolkit.ps1 - smoke tests (A4): helper correctness + ASCII lint + parse check of all .ps1
$ErrorActionPreference = 'Stop'
$ps = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "03_src\ps"
. (Join-Path $ps "_common.ps1")
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:fail++ } }

# 1) attribute -> status classification
Check "status online-only" ((Get-CsmFileStatus 0x400000) -eq 'online-only')
Check "status always-keep"  ((Get-CsmFileStatus 0x80000)  -eq 'always-keep')
Check "status local"        ((Get-CsmFileStatus 0x20)      -eq 'local-available')

# 2) config parse + ENV override
$tmp = [System.IO.Path]::GetTempFileName()
Set-Content $tmp "[paths]`nsource_root = X:\a`nwork_dir = X:\w`n[provider]`nname = onedrive-personal"
$cfg = Get-CsmConfig -Path $tmp
Check "config section/key" ((Get-CsmValue $cfg 'paths' 'source_root') -eq 'X:\a')
$env:CSM_PROVIDER_NAME = 'google-drive'
$cfg2 = Get-CsmConfig -Path $tmp
Check "env override" ((Get-CsmValue $cfg2 'provider' 'name') -eq 'google-drive')
Remove-Item Env:\CSM_PROVIDER_NAME
Remove-Item $tmp

# 3) atomic write
$aw = Join-Path ([System.IO.Path]::GetTempPath()) "csm_aw.json"
Write-CsmAtomic $aw '{"ok":1}'
Check "atomic write" ((Get-Content $aw -Raw).Trim() -eq '{"ok":1}')
Remove-Item $aw

# 4) ASCII lint of all .ps1
$bad = @()
Get-ChildItem $ps -Filter *.ps1 | ForEach-Object {
    if ([regex]::IsMatch([System.IO.File]::ReadAllText($_.FullName), '[^\x00-\x7F]')) { $bad += $_.Name }
}
Check "ps1 ASCII-only" ($bad.Count -eq 0)
if ($bad.Count) { Write-Host ("  non-ASCII in: " + ($bad -join ', ')) }

# 5) parse check of all .ps1
$parseFail = @()
Get-ChildItem $ps -Filter *.ps1 | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { $parseFail += $_.Name }
}
Check "ps1 parse clean" ($parseFail.Count -eq 0)
if ($parseFail.Count) { Write-Host ("  parse errors in: " + ($parseFail -join ', ')) }

# 6) provider/mode validation (#6)
$tmp2 = [System.IO.Path]::GetTempFileName()
Set-Content $tmp2 "[provider]`nname = google-drive`n[google_drive]`nmode = mirror"
Check "gdrive mode valid"          ((Resolve-CsmProviderMode (Get-CsmConfig -Path $tmp2)) -eq 'mirror')
Set-Content $tmp2 "[provider]`nname = google-drive`n[google_drive]`nmode = bogus"
$threw = $false; try { Resolve-CsmProviderMode (Get-CsmConfig -Path $tmp2) | Out-Null } catch { $threw = $true }
Check "gdrive mode invalid throws" $threw
Set-Content $tmp2 "[provider]`nname = onedrive-personal"
Check "onedrive mode n/a"          ((Resolve-CsmProviderMode (Get-CsmConfig -Path $tmp2)) -eq 'n/a')
Remove-Item $tmp2

# 7) sync-health gate (#1)
$tmp3 = [System.IO.Path]::GetTempFileName()
Set-Content $tmp3 "[move]`nassume_up_to_date = false"
$c7 = Get-CsmConfig -Path $tmp3
Check "sync-health needs confirm"  ((Resolve-CsmSyncHealth $c7).status -eq 'NEEDS_CONFIRMATION')
Check "sync-health flag confirms"  ((Resolve-CsmSyncHealth $c7 -Confirmed).status -eq 'CONFIRMED')
Set-Content $tmp3 "[move]`nassume_up_to_date = true"
Check "sync-health config confirms" ((Resolve-CsmSyncHealth (Get-CsmConfig -Path $tmp3)).status -eq 'CONFIRMED')
Remove-Item $tmp3

# 8) artifact success + age helpers (#7)
$okMeta  = [pscustomobject]@{ success = $true;  finishedUtc = (Get-Date).ToUniversalTime().ToString('s') }
$badMeta = [pscustomobject]@{ success = $false; finishedUtc = (Get-Date).ToUniversalTime().ToString('s') }
Check "artifact success true"  (Test-CsmArtifactSuccess $okMeta)
Check "artifact success false" (-not (Test-CsmArtifactSuccess $badMeta))
Check "artifact success null"  (-not (Test-CsmArtifactSuccess $null))
$oldMeta = [pscustomobject]@{ success = $true; finishedUtc = (Get-Date).ToUniversalTime().AddDays(-10).ToString('s') }
$age = Get-CsmArtifactAgeDays $oldMeta (Get-Date).ToUniversalTime()
Check "artifact age ~10d" ($age -ge 9 -and $age -le 11)

# 9) retire-source prerequisite gate (#2) with fixture artifacts
$twd = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_gate_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $twd | Out-Null
$gp = Join-Path $twd "cfg.ini"
$mc = (Get-Date).ToUniversalTime().AddDays(-10).ToString('s')
Set-Content $gp "[paths]`nsource_root = X:\src`ntarget_root = Y:\dst`nwork_dir = $twd`n[provider]`nname = onedrive-personal`n[move]`nmin_stable_days = 5`nmove_completed_utc = $mc"
$gcfg = Get-CsmConfig -Path $gp
Check "retire gate blocks (no artifacts)" (-not (Assert-CsmRetireReady -Config $gcfg -WorkDir $twd).ok)
Write-CsmAtomic (Join-Path $twd "preflight_2026_done.json") ((New-CsmMeta -Config $gcfg -Phase 'preflight' -Success $true) | ConvertTo-Json)
Write-CsmAtomic (Join-Path $twd "structure_2026_done.json") ((New-CsmMeta -Config $gcfg -Phase 'structure' -Success $true) | ConvertTo-Json)
Write-CsmAtomic (Join-Path $twd "verify_2026_done.json")    ((New-CsmMeta -Config $gcfg -Phase 'verify'    -Success $true) | ConvertTo-Json)
Check "retire gate passes (green/fresh/stable)" ((Assert-CsmRetireReady -Config $gcfg -WorkDir $twd).ok)
Write-CsmAtomic (Join-Path $twd "verify_2026_done.json")    ((New-CsmMeta -Config $gcfg -Phase 'verify'    -Success $false) | ConvertTo-Json)
Check "retire gate blocks (non-green verify)" (-not (Assert-CsmRetireReady -Config $gcfg -WorkDir $twd).ok)
# identity fails closed (review F1): an artifact missing source_root must block, not silently match
Write-CsmAtomic (Join-Path $twd "verify_2026_done.json") ((New-CsmMeta -Config $gcfg -Phase 'verify' -Success $true) | ConvertTo-Json)
$noId = New-CsmMeta -Config $gcfg -Phase 'preflight' -Success $true; $noId.Remove('source_root') | Out-Null
Write-CsmAtomic (Join-Path $twd "preflight_2026_done.json") ($noId | ConvertTo-Json)
Check "retire gate blocks (missing identity)" (-not (Assert-CsmRetireReady -Config $gcfg -WorkDir $twd).ok)
Remove-Item -Recurse -Force $twd

# 10) tracked .md are UTF-8 without BOM (#12 / B8)
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bomMd = @()
Get-ChildItem $repo -Recurse -Filter *.md -File | Where-Object { $_.FullName -notmatch '[\\/]_sources[\\/]' } | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bomMd += $_.Name }
}
Check "md UTF-8 without BOM" ($bomMd.Count -eq 0)
if ($bomMd.Count) { Write-Host ("  BOM in: " + ($bomMd -join ', ')) }

# 11) reparse + physical-root helpers (#13)
$nd = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_rp_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $nd | Out-Null
Check "reparse false on normal dir" (-not (Test-CsmReparsePoint $nd))
Check "physical root trims slash"   ((Resolve-CsmPhysicalRoot ($nd + '\')) -eq $nd)
Remove-Item -Recurse -Force $nd

# 12) provider-noise patterns (#4)
$tmpn = [System.IO.Path]::GetTempFileName()
Set-Content $tmpn "[provider]`nname = google-drive"
Check "noise gdrive incl driveupload"   ((Get-CsmNoisePatterns (Get-CsmConfig -Path $tmpn)) -contains '.tmp.driveupload')
Set-Content $tmpn "[provider]`nname = onedrive-personal"
Check "noise onedrive excl driveupload" (-not ((Get-CsmNoisePatterns (Get-CsmConfig -Path $tmpn)) -contains '.tmp.driveupload'))
Set-Content $tmpn "[provider]`nname = onedrive-personal`n[enumeration]`nnoise_dir_patterns = foo;bar"
Check "noise override respected" (((Get-CsmNoisePatterns (Get-CsmConfig -Path $tmpn)) -join ',') -eq 'foo,bar')
Remove-Item $tmpn

# 13) Invoke-CsmWalk skips junctions and noise dirs (#13/#4)
$wr = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_walk_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$wr\keep","$wr\.tmp.driveupload","$wr\real" | Out-Null
"a" | Out-File "$wr\top.txt"; "b" | Out-File "$wr\keep\k.txt"; "n" | Out-File "$wr\.tmp.driveupload\n.txt"; "r" | Out-File "$wr\real\r.txt"
cmd /c mklink /J "$wr\link" "$wr\real" | Out-Null
$sk = New-Object System.Collections.Generic.List[object]
$rels = @(Invoke-CsmWalk -Root $wr -NoisePatterns @('.tmp.driveupload') -Skipped $sk | ForEach-Object { $_.FullName.Substring($wr.Length + 1) })
Check "walk yields user files" (($rels -contains 'top.txt') -and ($rels -contains 'keep\k.txt') -and ($rels -contains 'real\r.txt'))
Check "walk skips noise dir"   (-not (($rels -join '|').Contains('.tmp.driveupload')))
Check "walk skips junction"    ((@($sk | Where-Object { $_.kind -eq 'reparse' }).Count -ge 1) -and (-not (($rels -join '|').Contains('link'))))
Remove-Item -Recurse -Force $wr

# 14) robocopy exit-code interpretation (#3)
Check "robocopy exit 1 success"  ((Get-CsmRobocopyExitInfo 1).success -and -not (Get-CsmRobocopyExitInfo 1).failed)
Check "robocopy exit 3 success"  ((Get-CsmRobocopyExitInfo 3).success)
Check "robocopy exit 8 failed"   ((-not (Get-CsmRobocopyExitInfo 8).success) -and (Get-CsmRobocopyExitInfo 8).failed)
Check "robocopy exit 16 fatal"   (((Get-CsmRobocopyExitInfo 16).bits -contains 'FATAL') -and (Get-CsmRobocopyExitInfo 16).failed)

# 15) liveness verdict classifier (#15) - pure logic
Check "liveness steady when not starting"   ((Get-CsmLivenessVerdict -InStartupPhase:$false) -eq 'steady')
Check "liveness initializing on progress"    ((Get-CsmLivenessVerdict -InStartupPhase:$true -WalChanged:$true) -eq 'initializing')
Check "liveness initializing on cpu"         ((Get-CsmLivenessVerdict -InStartupPhase:$true -CpuDeltaSec 0.2) -eq 'initializing')
Check "liveness hung when startup no progress" ((Get-CsmLivenessVerdict -InStartupPhase:$true) -eq 'hung')

# 16) diagnose health aggregation (#5) - pure logic; "no danger markers" => unknown, never healthy
Check "diag null => unknown"       ((Get-CsmDiagnoseHealth $null) -eq 'unknown')
Check "diag empty => unknown"      ((Get-CsmDiagnoseHealth @{}) -eq 'unknown')
Check "diag initializing wins"     ((Get-CsmDiagnoseHealth @{ initializing = $true; stalled = $true }) -eq 'initializing')
Check "diag stalled => blocked"    ((Get-CsmDiagnoseHealth @{ stalled = $true }) -eq 'blocked')
Check "diag poison => blocked"     ((Get-CsmDiagnoseHealth @{ poisonMarker = $true }) -eq 'blocked')
Check "diag errors+retry => blocked" ((Get-CsmDiagnoseHealth @{ errorsIncreasing = $true; retryLoop = $true }) -eq 'blocked')
Check "diag accessDenied => warning" ((Get-CsmDiagnoseHealth @{ accessDenied = $true }) -eq 'warning')
Check "diag danger marker => warning" ((Get-CsmDiagnoseHealth @{ knownDangerMarker = $true }) -eq 'warning')
Check "diag verified => healthy"   ((Get-CsmDiagnoseHealth @{ verifiedHealthy = $true }) -eq 'healthy')

# 17) Read-GoogleDriveState emits a redacted object over a synthetic cache (no real client needed)
$gdc = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_gd_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $gdc | Out-Null
$fs = [System.IO.File]::Create((Join-Path $gdc 'metadata.db-wal')); $fs.SetLength(600MB); $fs.Close()
'stuck' | Out-File (Join-Path $gdc 'upload.stale.tmp')
$gcfgp = Join-Path $gdc 'cfg.ini'
# process_name is pinned to a NON-EXISTENT process so the fixture is deterministic even on a machine
# where the real Google Drive client is running (otherwise its live CPU would leak in as 'progress').
Set-Content $gcfgp "[paths]`nwork_dir = $gdc`n[provider]`nname = google-drive`n[google_drive]`ncache_root = $gdc`nwal_warn_mb = 512`nstale_marker_patterns = *stale*`nprocess_name = CsmTestNoSuchProc_$([guid]::NewGuid().ToString('N'))`n[diagnose]`nsample_seconds = 1"
$gd = & (Join-Path $ps 'Read-GoogleDriveState.ps1') -Config $gcfgp -AsObject
Check "gdrive reader returns object" ($null -ne $gd -and $gd.provider -eq 'google-drive')
Check "gdrive reader sees large wal" ($gd.wal_large -eq $true -and $gd.wal_max_mb -ge 512)
Check "gdrive reader counts stale"   ($gd.stale_markers -ge 1)
Check "gdrive reader has signals"    ($gd.signals -is [hashtable])
# large + STALLED WAL (no growth between samples, no client process) is the HUNG case, and must
# aggregate to 'blocked' - regression guard for the "'hung' unreachable" fail-open (v0.5.0 review).
Check "gdrive stalled wal => hung"   ($gd.liveness -eq 'hung' -and $gd.signals['stalled'] -eq $true)
Check "gdrive hung => blocked"       ((Get-CsmDiagnoseHealth $gd.signals) -eq 'blocked')
Remove-Item -Recurse -Force $gdc

# 18) round-trip probe DRY-RUN writes nothing and reports readiness correctly (#9)
# Separate work_dirs per case: both dry-runs are sub-second, so a shared work_dir would collide on
# the second-resolution stamp/finishedUtc and let the "latest artifact" tie-break pick either one.
$pbase = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_probe_" + [guid]::NewGuid().ToString('N'))
$pwdN = Join-Path $pbase 'wd_notready'; $pwdR = Join-Path $pbase 'wd_ready'; $pdir = Join-Path $pbase 'synced\probe'
New-Item -ItemType Directory -Force $pwdN, $pwdR, $pdir | Out-Null
# not-ready: no confirm_command
$pcfgN = Join-Path $pbase 'notready.ini'
Set-Content $pcfgN "[paths]`nwork_dir = $pwdN`n[provider]`nname = google-drive`n[probe]`nprobe_dir = $pdir"
& (Join-Path $ps 'Invoke-RoundTripProbe.ps1') -Config $pcfgN | Out-Null
$pd1 = Get-CsmLatestArtifact $pwdN 'probe'
Check "probe dry-run not-ready" ($null -ne $pd1 -and $pd1.mode -eq 'dry-run' -and $pd1.config_ok -eq $false)
# ready: probe_dir writable + confirm_command set
$pcfgR = Join-Path $pbase 'ready.ini'
Set-Content $pcfgR "[paths]`nwork_dir = $pwdR`n[provider]`nname = google-drive`n[probe]`nprobe_dir = $pdir`nconfirm_command = cmd /c exit 0"
& (Join-Path $ps 'Invoke-RoundTripProbe.ps1') -Config $pcfgR | Out-Null
$pd2 = Get-CsmLatestArtifact $pwdR 'probe'
Check "probe dry-run ready" ($null -ne $pd2 -and $pd2.config_ok -eq $true)
Check "probe dry-run wrote no canary" (@(Get-ChildItem -LiteralPath $pdir -Filter '.csm_roundtrip_*' -Force -EA SilentlyContinue).Count -eq 0)
Remove-Item -Recurse -Force $pbase

# 19) encoding self-test (A4/B8): a known non-ASCII string survives write->read-back byte-identical,
#     and the artifact carries no BOM. This is the runtime half of the encoding contract (the static
#     half - .ps1 ASCII, .md/.py no-BOM - is checks 4/10/19b).
$encf = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_enc_" + [guid]::NewGuid().ToString('N') + ".txt")
$sample = [string][char]0x00E5 + [char]0x00E4 + [char]0x00F6 + " gra" + [char]0x00DF + "e"   # a-ring a-uml o-uml, sharp-s
Write-CsmAtomic $encf $sample
$readBack = [System.IO.File]::ReadAllText($encf, (New-Object System.Text.UTF8Encoding($false)))
Check "encoding round-trip identical" ($readBack -eq $sample)
$encBytes = [System.IO.File]::ReadAllBytes($encf)
Check "atomic write no BOM" (-not ($encBytes.Length -ge 3 -and $encBytes[0] -eq 0xEF -and $encBytes[1] -eq 0xBB -and $encBytes[2] -eq 0xBF))
Remove-Item -LiteralPath $encf -Force

# 19b) tracked .py are UTF-8 without BOM (B8)
$bomPy = @()
Get-ChildItem $ps -Recurse -Filter *.py -File -EA SilentlyContinue | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bomPy += $_.Name }
}
$pyDir = Join-Path (Split-Path $ps -Parent) 'py'
if (Test-Path $pyDir) { Get-ChildItem $pyDir -Recurse -Filter *.py -File -EA SilentlyContinue | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bomPy += $_.Name }
} }
Check "py UTF-8 without BOM" ($bomPy.Count -eq 0)

# 20) write-denial cause classifier (B8 true error classification) - pure logic + a real junction
$wd20 = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_deny_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $wd20 | Out-Null
Check "deny not-found"   ((Get-CsmWriteDenialCause $null (Join-Path $wd20 'no_such_child')) -eq 'not-found')
Check "deny permission"  ((Get-CsmWriteDenialCause (New-Object System.UnauthorizedAccessException 'Access is denied') $wd20) -eq 'permission-or-cfa')
Check "deny process-lock" ((Get-CsmWriteDenialCause (New-Object System.IO.IOException 'The process cannot access the file because it is being used by another process') $wd20) -eq 'process-lock')
$jnk = Join-Path $wd20 'realdir'; New-Item -ItemType Directory -Force $jnk | Out-Null
$lnk = Join-Path $wd20 'link'; cmd /c mklink /J "$lnk" "$jnk" | Out-Null
Check "deny reparse wins" ((Get-CsmWriteDenialCause (New-Object System.UnauthorizedAccessException 'denied') $lnk) -eq 'reparse-or-placeholder')
Check "writable detail ok" ((Test-CsmWritableDetail $wd20).writable -and (Test-CsmWritableDetail $wd20).cause -eq 'ok')
Remove-Item -Recurse -Force $wd20

# 21) stage-queue classifier (#16) - pure logic
Check "stq absent => none"             ((Get-CsmStageQueueClass -Present:$false) -eq 'none')
Check "stq empty ok => info"           ((Get-CsmStageQueueClass -Present:$true -FileCount 0 -DeleteProbe 'ok') -eq 'info')
Check "stq nonempty ok => warning"     ((Get-CsmStageQueueClass -Present:$true -FileCount 3 -DeleteProbe 'ok' -ExistingDeleteProbe 'ok') -eq 'warning')
Check "stq probe denied => blocked"    ((Get-CsmStageQueueClass -Present:$true -FileCount 3 -DeleteProbe 'denied') -eq 'blocked')
Check "stq existing denied => blocked" ((Get-CsmStageQueueClass -Present:$true -FileCount 3 -DeleteProbe 'ok' -ExistingDeleteProbe 'denied') -eq 'blocked')
Check "stq locked stays warning"       ((Get-CsmStageQueueClass -Present:$true -FileCount 3 -DeleteProbe 'ok' -ExistingDeleteProbe 'locked') -eq 'warning')
Check "stq empty denied => warning"    ((Get-CsmStageQueueClass -Present:$true -FileCount 0 -DeleteProbe 'denied') -eq 'warning')

# 22) mount stage-queue scan (#16) over fixtures: absent / empty / non-empty deletable /
#     locked-deletable (deny ACL on an EXISTING file) / ReadOnly-attributed root. The deny
#     fixtures use the Everyone SID (*S-1-1-0) so they are locale-independent; every deny is
#     removed again before cleanup.
$sq = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_sq_" + [guid]::NewGuid().ToString('N'))
$rAbsent = Join-Path $sq 'r0'; $rEmpty = Join-Path $sq 'r1'; $rWarn = Join-Path $sq 'r2'; $rBlock = Join-Path $sq 'r3'
New-Item -ItemType Directory -Force $rAbsent, $rEmpty, $rWarn, $rBlock | Out-Null
New-Item -ItemType Directory -Force (Join-Path $rEmpty '.tmp.driveupload'), (Join-Path $rWarn '.tmp.driveupload'), (Join-Path $rBlock '.tmp.driveupload') | Out-Null
'w' | Out-File (Join-Path $rWarn '.tmp.driveupload\w1.bin')
$lockFile = Join-Path $rBlock '.tmp.driveupload\old.bin'
'b' | Out-File $lockFile
attrib +r "$rBlock" 2>$null   # a ReadOnly-attributed root must still scan (field case)
icacls "$lockFile" /deny "*S-1-1-0:(DE)" | Out-Null
$blkDir22 = Join-Path $rBlock '.tmp.driveupload'
icacls "$blkDir22" /deny "*S-1-1-0:(DC)" | Out-Null   # parent FILE_DELETE_CHILD would otherwise override the file deny
$sqr = @(Get-CsmMountStageQueues -Roots @($rAbsent, $rEmpty, $rWarn, $rBlock) -StageDirName '.tmp.driveupload')
Check "sq scan 4 entries"       ($sqr.Count -eq 4)
Check "sq absent none"          ($sqr[0].class -eq 'none' -and $sqr[0].present -eq $false)
Check "sq empty info"           ($sqr[1].class -eq 'info' -and $sqr[1].delete_probe -eq 'ok')
Check "sq nonempty warning"     ($sqr[2].class -eq 'warning' -and $sqr[2].file_count -eq 1 -and $sqr[2].oldest_utc)
Check "sq deny-ACL blocked"     ($sqr[3].class -eq 'blocked' -and $sqr[3].existing_delete_probe -eq 'denied')
Check "sq redacted (no paths)"  (-not (($sqr | ConvertTo-Json -Compress).Contains($sq)))
Check "sq delete-access denied" ((Test-CsmDeleteAccess $lockFile) -eq 'denied')
$w1 = Join-Path $rWarn '.tmp.driveupload\w1.bin'
$fs22 = [System.IO.File]::Open($w1, 'Open', 'Read', 'None')
Check "sq delete-access locked" ((Test-CsmDeleteAccess $w1) -eq 'locked')
$fs22.Close()
Check "sq delete-access ok"     ((Test-CsmDeleteAccess $w1) -eq 'ok')
icacls "$blkDir22" /remove:d "*S-1-1-0" | Out-Null
icacls "$lockFile" /remove:d "*S-1-1-0" | Out-Null
attrib -r "$rBlock" 2>$null
Remove-Item -Recurse -Force $sq

# 23) Read-GoogleDriveState (#16): a blocked mount queue must surface in the signals and
#     aggregate to 'blocked' even when the cache itself looks quiet (small WAL, no stale
#     markers) - the exact shape of the 2026-07-19 field incident.
$g23 = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_g23_" + [guid]::NewGuid().ToString('N'))
$c23 = Join-Path $g23 'cache'; $s23 = Join-Path $g23 'mount\root0'
New-Item -ItemType Directory -Force $c23, (Join-Path $s23 '.tmp.driveupload') | Out-Null
$b23 = Join-Path $s23 '.tmp.driveupload\stuck.bin'
'x' | Out-File $b23
icacls "$b23" /deny "*S-1-1-0:(DE)" | Out-Null
$d23 = Join-Path $s23 '.tmp.driveupload'
icacls "$d23" /deny "*S-1-1-0:(DC)" | Out-Null
$p23 = Join-Path $g23 'cfg.ini'
Set-Content $p23 "[paths]`nsource_root = $s23`nwork_dir = $g23`n[provider]`nname = google-drive`n[google_drive]`ncache_root = $c23`nprocess_name = CsmTestNoSuchProc_$([guid]::NewGuid().ToString('N'))`n[diagnose]`nsample_seconds = 1"
$g23o = & (Join-Path $ps 'Read-GoogleDriveState.ps1') -Config $p23 -AsObject
Check "gd mount queue scanned"     (@($g23o.mount_stage_queues).Count -eq 1)
Check "gd stage blocked signal"    ($g23o.signals['stageQueueBlocked'] -eq $true -and $g23o.stage_queues_blocked -eq 1)
Check "gd stage => blocked health" ((Get-CsmDiagnoseHealth $g23o.signals) -eq 'blocked')
icacls "$d23" /remove:d "*S-1-1-0" | Out-Null
icacls "$b23" /remove:d "*S-1-1-0" | Out-Null
Remove-Item -Recurse -Force $g23

# 24) preflight SOURCE_STAGE_QUEUE_STUCK gate (#17): blocked queue under the source root =>
#     NEEDS_CONFIRMATION; cleared via config assume, or -ForceStageQueue WITH a reason (the
#     flag alone must NOT clear it - trap case). Separate work_dirs per run (stamp collision).
$p24 = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_p24_" + [guid]::NewGuid().ToString('N'))
$s24 = Join-Path $p24 'src'; $t24 = Join-Path $p24 'tgt'
New-Item -ItemType Directory -Force (Join-Path $s24 '.tmp.driveupload'), $t24 | Out-Null
$b24 = Join-Path $s24 '.tmp.driveupload\old.bin'
'x' | Out-File $b24
icacls "$b24" /deny "*S-1-1-0:(DE)" | Out-Null
$d24 = Join-Path $s24 '.tmp.driveupload'
icacls "$d24" /deny "*S-1-1-0:(DC)" | Out-Null
function New-P24Cfg([string]$wd, [string]$extraMove) {
    New-Item -ItemType Directory -Force $wd | Out-Null
    $f = Join-Path $wd 'cfg.ini'
    Set-Content $f "[paths]`nsource_root = $s24`ntarget_root = $t24`nwork_dir = $wd`n[provider]`nname = google-drive`n[google_drive]`nmode = streaming`n[move]`n$extraMove"
    return $f
}
$wdA = Join-Path $p24 'wdA'; $cfgA = New-P24Cfg $wdA ''
& (Join-Path $ps 'Test-MovePreflight.ps1') -Config $cfgA | Out-Null
$artA = Get-CsmLatestArtifact $wdA 'preflight'
$gateA = $artA.stage_queue_gate | ConvertFrom-Json
Check "preflight gate blocks"        ($gateA.gate -eq 'SOURCE_STAGE_QUEUE_STUCK' -and $gateA.state -eq 'NEEDS_CONFIRMATION' -and $gateA.roots_blocked -eq 1)
$wdB = Join-Path $p24 'wdB'; $cfgB = New-P24Cfg $wdB 'assume_stage_queue_clean = true'
& (Join-Path $ps 'Test-MovePreflight.ps1') -Config $cfgB | Out-Null
$artB = Get-CsmLatestArtifact $wdB 'preflight'
Check "preflight gate config-cleared" ((($artB.stage_queue_gate | ConvertFrom-Json).state) -eq 'PASS' -and $artB.stage_queue_assumed_clean -eq $true)
$wdC = Join-Path $p24 'wdC'; $cfgC = New-P24Cfg $wdC ''
& (Join-Path $ps 'Test-MovePreflight.ps1') -Config $cfgC -ForceStageQueue -StageQueueReason 'fixture override' | Out-Null
$artC = Get-CsmLatestArtifact $wdC 'preflight'
Check "preflight gate forced+reason"  ((($artC.stage_queue_gate | ConvertFrom-Json).state) -eq 'PASS' -and $artC.stage_queue_forced -eq $true -and $artC.stage_queue_force_reason -eq 'fixture override')
$wdD = Join-Path $p24 'wdD'; $cfgD = New-P24Cfg $wdD ''
& (Join-Path $ps 'Test-MovePreflight.ps1') -Config $cfgD -ForceStageQueue | Out-Null
$artD = Get-CsmLatestArtifact $wdD 'preflight'
Check "preflight flag alone refused"  ((($artD.stage_queue_gate | ConvertFrom-Json).state) -eq 'NEEDS_CONFIRMATION')
icacls "$d24" /remove:d "*S-1-1-0" | Out-Null
icacls "$b24" /remove:d "*S-1-1-0" | Out-Null
Remove-Item -Recurse -Force $p24

# 25) delivery plan resolution (#18) - pure logic; the plan never carries a token value
$t25 = [System.IO.Path]::GetTempFileName()
Set-Content $t25 "[provider]`nname = google-drive"
Check "dlv disabled by default"    (((Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)).enabled) -eq $false)
Set-Content $t25 "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = onedrive"
Check "dlv provider not impl"      (((Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)).reason) -eq 'provider-not-implemented')
Set-Content $t25 "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive"
Check "dlv missing folder id"      (((Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)).reason) -eq 'missing-folder-id')
Set-Content $t25 "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive`nfolder_id = F1"
Check "dlv missing creds env"      (((Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)).reason) -eq 'missing-credentials-env')
Set-Content $t25 "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive`nfolder_id = F1`ncredentials_env = CSM_T25_NOSUCHVAR"
Check "dlv creds unresolvable"     (((Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)).reason) -eq 'credentials-unresolvable')
$env:CSM_T25_TOK = 'dummy-token-value'
Set-Content $t25 "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive`nfolder_id = F1`ncredentials_env = CSM_T25_TOK"
$plan25 = Resolve-CsmDeliveryPlan (Get-CsmConfig -Path $t25)
Check "dlv ready when resolvable"  ($plan25.ready -eq $true -and $plan25.reason -eq 'ok')
Check "dlv plan carries no token"  (-not (($plan25 | ConvertTo-Json -Compress).Contains('dummy-token-value')))
Remove-Item Env:\CSM_T25_TOK
Remove-Item $t25
Check "dlv error class 401"        ((Get-CsmDeliveryErrorClass ([System.Exception]::new('The remote server returned an error: (401) Unauthorized.'))) -eq 'http-401-unauthorized')
Check "dlv error class network"    ((Get-CsmDeliveryErrorClass ([System.Exception]::new('Unable to connect to the remote server'))) -eq 'network')

# 26) delivery soft-fail (#18): disabled => no delivery fields, no receipt; enabled + dead
#     endpoint => classified 'network' soft failure, diagnostic itself still completes.
function New-T26Cfg([string]$base, [string]$extra) {
    $wd = Join-Path $base ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $wd | Out-Null
    $cache = Join-Path $wd 'cache'; New-Item -ItemType Directory -Force $cache | Out-Null
    $f = Join-Path $wd 'cfg.ini'
    Set-Content $f "[paths]`nwork_dir = $wd`n[provider]`nname = google-drive`n[google_drive]`ncache_root = $cache`nprocess_name = CsmTestNoSuchProc_$([guid]::NewGuid().ToString('N'))`n[diagnose]`nsample_seconds = 1`n$extra"
    return @{ wd = $wd; cfg = $f }
}
$t26base = Join-Path ([System.IO.Path]::GetTempPath()) ("csm_t26_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $t26base | Out-Null
$c26a = New-T26Cfg $t26base ''
& (Join-Path $ps 'Invoke-CsmDiagnose.ps1') -Config $c26a.cfg | Out-Null
$a26a = Get-CsmLatestArtifact $c26a.wd 'diagnose'
Check "dlv off: no delivery fields" (-not (@($a26a.PSObject.Properties.Name) -contains 'delivered_via_api'))
Check "dlv off: no receipt"         (@(Get-ChildItem (Join-Path $c26a.wd 'diagnose_*_delivery.json') -EA SilentlyContinue).Count -eq 0)
$env:CSM_T26_TOK = 'dummy'
$c26b = New-T26Cfg $t26base "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive`nfolder_id = F1`ncredentials_env = CSM_T26_TOK`nendpoint_base = http://127.0.0.1:1"
& (Join-Path $ps 'Invoke-CsmDiagnose.ps1') -Config $c26b.cfg | Out-Null
$a26b = Get-CsmLatestArtifact $c26b.wd 'diagnose'
Check "dlv soft-fail classified"    ($a26b.delivered_via_api -eq $false -and $a26b.delivered_via_api_error -eq 'network')
Check "dlv soft-fail not fatal"     ($null -ne $a26b.health)
Check "dlv soft-fail receipt"       (@(Get-ChildItem (Join-Path $c26b.wd 'diagnose_*_delivery.json') -EA SilentlyContinue).Count -eq 1)
Remove-Item Env:\CSM_T26_TOK

# 27) delivery happy path (#18) against a local TCP mock of the provider endpoint (no real
#     cloud is touched; proves the multipart upload + URL capture end to end).
$port27 = Get-Random -Minimum 20000 -Maximum 45000
$job27 = Start-Job -ScriptBlock {
    param($port)
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $l.Start()
    Write-Output "READY"
    $c = $l.AcceptTcpClient()
    $st = $c.GetStream()
    $buf = New-Object byte[] 65536
    $got = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    $contentLen = -1; $bodyStart = -1
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($c.Available -gt 0) {
            $n = $st.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$got.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $n))
            $s = $got.ToString()
            if ($bodyStart -lt 0) {
                $ix = $s.IndexOf("`r`n`r`n")
                if ($ix -ge 0) {
                    $bodyStart = $ix + 4
                    if ($s -match '(?im)^Content-Length:\s*(\d+)') { $contentLen = [int]$Matches[1] }
                }
            }
            if ($bodyStart -ge 0 -and $contentLen -ge 0 -and ($got.Length - $bodyStart) -ge $contentLen) { break }
        } else { Start-Sleep -Milliseconds 50 }
    }
    $json = '{"id":"mock123","name":"x.json","webViewLink":"https://drive.google.com/file/d/mock123/view"}'
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($json.Length)`r`nConnection: close`r`n`r`n$json"
    $rb = [System.Text.Encoding]::UTF8.GetBytes($resp)
    $st.Write($rb, 0, $rb.Length); $st.Flush()
    Start-Sleep -Milliseconds 300
    $c.Close(); $l.Stop()
} -ArgumentList $port27
$ready27 = $false
for ($w = 0; $w -lt 50 -and -not $ready27; $w++) {
    if (@(Receive-Job $job27 -Keep) -contains 'READY') { $ready27 = $true } else { Start-Sleep -Milliseconds 100 }
}
Check "dlv mock listener ready" $ready27
$env:CSM_T27_TOK = 'dummy'
$c27 = New-T26Cfg $t26base "[diagnose_delivery]`nprovider_upload_enabled = true`nprovider = google-drive`nfolder_id = FMOCK`ncredentials_env = CSM_T27_TOK`nendpoint_base = http://127.0.0.1:$port27"
& (Join-Path $ps 'Invoke-CsmDiagnose.ps1') -Config $c27.cfg | Out-Null
$a27 = Get-CsmLatestArtifact $c27.wd 'diagnose'
Check "dlv happy delivered"    ($a27.delivered_via_api -eq $true)
Check "dlv happy url captured" ("$($a27.delivered_via_api_url)".Contains('mock123'))
Remove-Item Env:\CSM_T27_TOK
Wait-Job $job27 -Timeout 10 | Out-Null; Remove-Job $job27 -Force -EA SilentlyContinue
Remove-Item -Recurse -Force $t26base

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL SMOKE TESTS PASSED" } else { Write-Host "$($script:fail) TEST(S) FAILED"; exit 1 }