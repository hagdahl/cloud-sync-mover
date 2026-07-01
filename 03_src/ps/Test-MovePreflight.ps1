# Test-MovePreflight.ps1 - Phase 2: gates before the move (free space, writability, disk type, up-to-date reminder)
param([Parameter(Mandatory)][string]$Config)
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

# 5) Up-to-date reminder (cannot be auto-detected reliably; operator must confirm)
$checks['reminder'] = 'Confirm the sync client shows "Up to date" (no pending changes) before proceeding.'

$checks['PASS'] = $pass
Write-CsmAtomic $done ($checks | ConvertTo-Json)
$checks.GetEnumerator() | ForEach-Object { Write-CsmLog ("{0}: {1}" -f $_.Key, $_.Value) $log }
Write-Host ("PREFLIGHT: {0}" -f ($(if ($pass) { 'PASS' } else { 'FAIL - see ' + $done })))