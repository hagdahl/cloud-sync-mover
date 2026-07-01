# Invoke-Inventory.ps1 - Phase 0: read-only inventory (attribute classification, no content read)
param([Parameter(Mandatory)][string]$Config)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg  = Get-CsmConfig -Path $Config
$root = Get-CsmValue $cfg 'paths' 'source_root'
if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "source_root missing or not found: $root" }
$wd    = Get-CsmWorkDir -Config $cfg
$stamp = New-CsmStamp
$csv   = Join-Path $wd "inventory_$stamp.csv"
$pin   = Join-Path $wd "pinlist_$stamp.txt"
$done  = Join-Path $wd "inventory_${stamp}_done.json"
$log   = Join-Path $wd "inventory_$stamp.log"

Write-CsmLog "Inventory start: $root" $log
$enc = New-Object System.Text.UTF8Encoding($false)
$sw  = [System.IO.StreamWriter]::new($csv, $false, $enc)
$swp = [System.IO.StreamWriter]::new($pin, $false, $enc)
$sw.WriteLine("RelPath`tSizeBytes`tLastWriteUtc`tAttrHex`tStatus")
$c = @{ 'online-only' = 0; 'local-available' = 0; 'always-keep' = 0 }
$n = 0; $err = 0; $t0 = Get-Date
try {
    foreach ($p in [System.IO.Directory]::EnumerateFiles($root, "*", [System.IO.SearchOption]::AllDirectories)) {
        try {
            $fi  = New-Object System.IO.FileInfo $p
            $a   = [int]$fi.Attributes
            $st  = Get-CsmFileStatus $a
            $rel = $p.Substring($root.Length + 1)
            $sw.WriteLine(("{0}`t{1}`t{2}`t{3}`t{4}" -f $rel, $fi.Length, $fi.LastWriteTimeUtc.ToString("s"), ("0x{0:X}" -f $a), $st))
            if ($st -ne 'online-only') { $swp.WriteLine($rel) }
            $c[$st]++; $n++
            if ($n % 5000 -eq 0) { Write-CsmLog ("  processed $n files") $log }
        } catch { $err++ }
    }
} catch { Write-CsmLog "ENUM ERROR: $($_.Exception.Message)" $log }
$sw.Flush(); $sw.Close(); $swp.Flush(); $swp.Close()

$sum = [ordered]@{
    finishedUtc     = (Get-Date).ToUniversalTime().ToString("s")
    seconds         = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    files           = $n
    errors          = $err
    online_only     = $c['online-only']
    local_available = $c['local-available']
    always_keep     = $c['always-keep']
    csv             = $csv
    pinlist         = $pin
}
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-CsmLog ("Inventory done: {0} files ({1} online-only, {2} local, {3} always-keep), {4} errors" -f $n, $c['online-only'], $c['local-available'], $c['always-keep'], $err) $log
Write-Host "OK -> $csv"