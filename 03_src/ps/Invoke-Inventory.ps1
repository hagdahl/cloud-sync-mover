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
$root = $root.TrimEnd('\')
$noise = Get-CsmNoisePatterns $cfg
$skipped = New-Object System.Collections.Generic.List[object]
$n = 0; $err = 0; $enumOk = $true; $t0 = Get-Date
try {
    # Junction-safe (#13) + noise-aware (#4): never traverse THROUGH a reparse point or a
    # provider-internal temp/staging dir; those are recorded in $skipped, not counted as user data.
    Invoke-CsmWalk -Root $root -NoisePatterns $noise -Skipped $skipped | ForEach-Object {
        $fi = $_
        try {
            $a   = [int]$fi.Attributes
            $st  = Get-CsmFileStatus $a
            $rel = $fi.FullName.Substring($root.Length + 1)
            $sw.WriteLine(("{0}`t{1}`t{2}`t{3}`t{4}" -f $rel, $fi.Length, $fi.LastWriteTimeUtc.ToString("s"), ("0x{0:X}" -f $a), $st))
            if ($st -ne 'online-only') { $swp.WriteLine($rel) }
            $c[$st]++; $n++
            if ($n % 5000 -eq 0) { Write-CsmLog ("  processed $n files") $log }
        } catch { $err++ }
    }
} catch { $enumOk = $false; Write-CsmLog "ENUM ERROR: $($_.Exception.Message)" $log }
$sw.Flush(); $sw.Close(); $swp.Flush(); $swp.Close()

$reparseSkipped = @($skipped | Where-Object { $_.kind -eq 'reparse' }).Count
$noiseSkipped   = @($skipped | Where-Object { $_.kind -eq 'noise' }).Count
$accessErrors   = @($skipped | Where-Object { $_.kind -like '*access-error' }).Count

# Fail closed (#7): enumeration failure, a per-file error, or a walk access-error (an unreadable
# directory could hide user data) means this baseline is not authoritative.
$cats = @()
if (-not $enumOk)        { $cats += 'enumeration' }
if ($err -gt 0)          { $cats += 'file-access' }
if ($accessErrors -gt 0) { $cats += 'walk-access' }
$success = ($enumOk -and $err -eq 0 -and $accessErrors -eq 0)
$sum = New-CsmMeta -Config $cfg -Phase 'inventory' -Success $success -Errors ($err + $accessErrors) -ErrorCategories $cats
$sum['seconds']          = [math]::Round(((Get-Date) - $t0).TotalSeconds)
$sum['files']            = $n
$sum['online_only']      = $c['online-only']
$sum['local_available']  = $c['local-available']
$sum['always_keep']      = $c['always-keep']
$sum['root_is_junction'] = (Test-CsmReparsePoint $root)
$sum['reparse_skipped']  = $reparseSkipped
$sum['noise_skipped']    = $noiseSkipped
$sum['access_errors']    = $accessErrors
$sum['skipped']          = @($skipped | Select-Object -First 200)
$sum['csv']              = $csv
$sum['pinlist']          = $pin
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-CsmLog ("Inventory done: {0} files ({1} online-only, {2} local, {3} always-keep); skipped {4} junction dir(s), {5} noise dir(s); {6} access error(s)" -f $n, $c['online-only'], $c['local-available'], $c['always-keep'], $reparseSkipped, $noiseSkipped, $accessErrors) $log
Write-Host "OK -> $csv"