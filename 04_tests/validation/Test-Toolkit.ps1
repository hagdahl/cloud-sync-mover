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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL SMOKE TESTS PASSED" } else { Write-Host "$($script:fail) TEST(S) FAILED"; exit 1 }