# Invoke-HydrationVerify.ps1 - Phase 6: hydration-aware MD5 verify against baseline
# Verifies ONLY when a sample shows 0 online-only (avoids racing hydration). Safe to schedule (idempotent).
param([Parameter(Mandatory)][string]$Config, [string]$Md5Csv, [int]$SampleSize = 500)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-CsmConfig -Path $Config
$tgt = Get-CsmValue $cfg 'paths' 'target_root'
$wd  = Get-CsmWorkDir -Config $cfg
if (-not $Md5Csv) {
    $latest = Get-ChildItem (Join-Path $wd "md5_*.csv") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $Md5Csv = $latest.FullName }
}
if (-not $Md5Csv) { throw "No md5 baseline; run Invoke-Md5Baseline.ps1 first" }

$stamp = New-CsmStamp
$log   = Join-Path $wd "verify_$stamp.log"
$done  = Join-Path $wd "verify_${stamp}_done.json"

# Load baseline
$items = New-Object System.Collections.Generic.List[object]
$sr = [System.IO.StreamReader]::new($Md5Csv); [void]$sr.ReadLine()
while (($l = $sr.ReadLine()) -ne $null) {
    $f = $l.Split("`t"); if ($f.Length -ge 2 -and $f[1] -ne 'ERROR') { $items.Add([pscustomobject]@{ rel = $f[0]; md5 = $f[1] }) }
}
$sr.Close()
if ($items.Count -eq 0) { throw "Baseline is empty" }

# Sample for online-only (hydration gate)
$step = [Math]::Max(1, [int]($items.Count / $SampleSize)); $online = 0; $checked = 0
for ($i = 0; $i -lt $items.Count; $i += $step) {
    $full = Join-Path $tgt $items[$i].rel
    if (Test-Path -LiteralPath $full) { $a = [int][System.IO.File]::GetAttributes($full); if ($a -band 0x400000) { $online++ }; $checked++ }
}
Write-CsmLog "Sample: $online/$checked online-only" $log
if ($online -gt 0) {
    # Fail closed (#7 / review F2): stamp a non-green artifact so the retire gate sees the LATEST
    # verify as "hydrating" and cannot pass on a stale earlier green verify.
    $hmeta = New-CsmMeta -Config $cfg -Phase 'verify' -Success $false -Errors 0 -ErrorCategories @('hydration-pending')
    $hmeta['phase_state']        = 'hydrating'
    $hmeta['sample_online_only'] = $online
    $hmeta['sample_checked']     = $checked
    Write-CsmAtomic $done ($hmeta | ConvertTo-Json)
    Write-CsmLog "Hydration in progress - re-run later." $log
    Write-Host "HYDRATING ($online/$checked online-only) - re-run later"
    return
}

# Full verify
Write-CsmLog "Hydration settled. Full MD5 verify of $($items.Count) files..." $log
$md5 = [System.Security.Cryptography.MD5]::Create()
$rep = Join-Path $wd "verify_${stamp}_mismatches.txt"
$mw  = [System.IO.StreamWriter]::new($rep, $false, (New-Object System.Text.UTF8Encoding($false)))
$match = 0; $mis = 0; $err = 0
foreach ($it in $items) {
    $full = Join-Path $tgt $it.rel
    try {
        $fs = [System.IO.File]::OpenRead($full)
        try { $hb = $md5.ComputeHash($fs) } finally { $fs.Dispose() }
        $h = [System.BitConverter]::ToString($hb).Replace("-", "")
        if ($h -eq $it.md5) { $match++ } else { $mis++; $mw.WriteLine("MISMATCH`t$($it.rel)") }
    } catch { $err++; $mw.WriteLine("ERR`t$($it.rel)`t$($_.Exception.Message)") }
}
$mw.Close()
# Fail closed (#7): any mismatch or read error means verification did not pass.
# (The hydration-pending path returns earlier and writes no done.json, so the retire gate sees no green verify.)
$cats = @(); if ($mis -gt 0) { $cats += 'md5-mismatch' }; if ($err -gt 0) { $cats += 'read-error' }
$sum = New-CsmMeta -Config $cfg -Phase 'verify' -Success (($mis -eq 0) -and ($err -eq 0)) -Errors ($mis + $err) -ErrorCategories $cats
$sum['files']        = $items.Count
$sum['md5_match']    = $match
$sum['md5_mismatch'] = $mis
$sum['read_errors']  = $err
$sum['mismatches']   = $rep
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-CsmLog "Full verify: match=$match mismatch=$mis err=$err" $log
Write-Host "VERIFY: match=$match mismatch=$mis err=$err (mismatches -> $rep)"