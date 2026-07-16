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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL SMOKE TESTS PASSED" } else { Write-Host "$($script:fail) TEST(S) FAILED"; exit 1 }