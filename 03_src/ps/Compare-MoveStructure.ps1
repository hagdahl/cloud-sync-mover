# Compare-MoveStructure.ps1 - Phase 5: structure diff (inventory vs target), junk-classified
param([Parameter(Mandatory)][string]$Config, [string]$InventoryCsv)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-CsmConfig -Path $Config
$tgt = Get-CsmValue $cfg 'paths' 'target_root'
$wd  = Get-CsmWorkDir -Config $cfg
if (-not (Test-Path -LiteralPath $tgt)) { throw "target_root not found: $tgt" }
if (-not $InventoryCsv) {
    $latest = Get-ChildItem (Join-Path $wd "inventory_*.csv") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $InventoryCsv = $latest.FullName }
}
if (-not $InventoryCsv) { throw "No inventory CSV; run Invoke-Inventory.ps1 first" }

$stamp  = New-CsmStamp
$report = Join-Path $wd "structure_report_$stamp.txt"
$done   = Join-Path $wd "structure_${stamp}_done.json"

# Build target set of relative paths
$cmp = [System.StringComparer]::OrdinalIgnoreCase
$set = [System.Collections.Generic.HashSet[string]]::new($cmp)
$tCount = 0
foreach ($f in [System.IO.Directory]::EnumerateFiles($tgt, "*", [System.IO.SearchOption]::AllDirectories)) {
    [void]$set.Add($f.Substring($tgt.Length + 1)); $tCount++
}

# Diff inventory against target
$sr = [System.IO.StreamReader]::new($InventoryCsv); [void]$sr.ReadLine()
$mw = [System.IO.StreamWriter]::new($report, $false, (New-Object System.Text.UTF8Encoding($false)))
$mw.WriteLine("=== MISSING on target (in inventory, not on target) ===")
$present = 0; $missing = 0; $total = 0; $junk = 0
while (($line = $sr.ReadLine()) -ne $null) {
    $rel = $line.Split("`t")[0]; $total++
    if ($set.Contains($rel)) { $present++ }
    else {
        $missing++
        $name = Split-Path $rel -Leaf
        if ($name -eq 'Thumbs.db' -or $name -eq 'desktop.ini' -or $name -like '~$*' -or $name -like '*.tmp') { $junk++ }
        if ($missing -le 500) { $mw.WriteLine($rel) }
    }
}
$sr.Close(); $mw.Close()
$real = $missing - $junk
$sum = [ordered]@{
    finishedUtc     = (Get-Date).ToUniversalTime().ToString("s")
    target_files    = $tCount
    inventory_total = $total
    present         = $present
    missing         = $missing
    missing_junk    = $junk
    missing_real    = $real
    extra_approx    = ($tCount - $present)
    report          = $report
}
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-Host "Structure: present=$present missing=$missing (junk=$junk real=$real) extra~$($tCount-$present) -> $report"