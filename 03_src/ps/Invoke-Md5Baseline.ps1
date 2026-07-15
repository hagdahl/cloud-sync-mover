# Invoke-Md5Baseline.ps1 - Phase 1: MD5 baseline of LOCAL files only (.NET MD5, not Get-FileHash)
param([Parameter(Mandatory)][string]$Config, [string]$InventoryCsv)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg  = Get-CsmConfig -Path $Config
$root = Get-CsmValue $cfg 'paths' 'source_root'
$wd   = Get-CsmWorkDir -Config $cfg
if (-not $InventoryCsv) {
    $latest = Get-ChildItem (Join-Path $wd "inventory_*.csv") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $InventoryCsv = $latest.FullName }
}
if (-not $InventoryCsv -or -not (Test-Path -LiteralPath $InventoryCsv)) { throw "No inventory CSV; run Invoke-Inventory.ps1 first" }

$stamp = New-CsmStamp
$out   = Join-Path $wd "md5_$stamp.csv"
$done  = Join-Path $wd "md5_${stamp}_done.json"
$log   = Join-Path $wd "md5_$stamp.log"
Write-CsmLog "MD5 baseline start from $InventoryCsv" $log

$md5 = [System.Security.Cryptography.MD5]::Create()
$sr  = [System.IO.StreamReader]::new($InventoryCsv); [void]$sr.ReadLine()
$sw  = [System.IO.StreamWriter]::new($out, $false, (New-Object System.Text.UTF8Encoding($false)))
$sw.WriteLine("RelPath`tMD5`tSizeBytes")
$n = 0; $ok = 0; $err = 0; $t0 = Get-Date
while (($line = $sr.ReadLine()) -ne $null) {
    $f = $line.Split("`t")
    if ($f.Length -ge 5 -and $f[4] -ne 'online-only') {
        $n++; $full = Join-Path $root $f[0]
        try {
            $fs = [System.IO.File]::OpenRead($full)
            try { $hb = $md5.ComputeHash($fs) } finally { $fs.Dispose() }
            $h = [System.BitConverter]::ToString($hb).Replace("-", "")
            $sw.WriteLine("$($f[0])`t$h`t$($f[1])"); $ok++
        } catch {
            $err++; $sw.WriteLine("$($f[0])`tERROR`t$($f[1])")
        }
        if ($n % 2000 -eq 0) { Write-CsmLog "  hashed $n ($ok ok, $err err)" $log }
    }
}
$sr.Close(); $sw.Flush(); $sw.Close()
# Fail closed (#7): any hash/read error means the baseline is incomplete.
$cats = @(); if ($err -gt 0) { $cats += 'hash-read' }
$sum = New-CsmMeta -Config $cfg -Phase 'baseline' -Success ($err -eq 0) -Errors $err -ErrorCategories $cats
$sum['local_files'] = $n
$sum['hashed']      = $ok
$sum['out']         = $out
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-CsmLog "MD5 baseline done: $n local files, $ok hashed, $err errors" $log
Write-Host "OK -> $out"