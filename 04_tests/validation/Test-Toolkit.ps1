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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL SMOKE TESTS PASSED" } else { Write-Host "$($script:fail) TEST(S) FAILED"; exit 1 }