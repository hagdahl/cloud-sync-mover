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

# Build target set of relative paths - junction-safe (#13) + noise-aware (#4), same as inventory.
$tgt = $tgt.TrimEnd('\')
$noise = Get-CsmNoisePatterns $cfg
$tskip = New-Object System.Collections.Generic.List[object]
$cmp = [System.StringComparer]::OrdinalIgnoreCase
$set = [System.Collections.Generic.HashSet[string]]::new($cmp)
$tCount = 0
Invoke-CsmWalk -Root $tgt -NoisePatterns $noise -Skipped $tskip | ForEach-Object {
    [void]$set.Add($_.FullName.Substring($tgt.Length + 1)); $tCount++
}
$tAccessErrors = @($tskip | Where-Object { $_.kind -like '*access-error' }).Count

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
# Fail closed (#7): a real (non-junk) missing file, or an unreadable target directory, fails the structure check.
$cats = @(); if ($real -gt 0) { $cats += 'missing-files' }; if ($tAccessErrors -gt 0) { $cats += 'target-access' }
$sum = New-CsmMeta -Config $cfg -Phase 'structure' -Success (($real -eq 0) -and ($tAccessErrors -eq 0)) -Errors ($real + $tAccessErrors) -ErrorCategories $cats
$sum['target_files']        = $tCount
$sum['inventory_total']     = $total
$sum['present']             = $present
$sum['missing']             = $missing
$sum['missing_junk']        = $junk
$sum['missing_real']        = $real
$sum['extra_approx']        = ($tCount - $present)
$sum['target_is_junction']  = (Test-CsmReparsePoint $tgt)
$sum['target_reparse_skipped'] = @($tskip | Where-Object { $_.kind -eq 'reparse' }).Count
$sum['target_noise_skipped']   = @($tskip | Where-Object { $_.kind -eq 'noise' }).Count
$sum['target_access_errors']   = $tAccessErrors
$sum['report']              = $report
Write-CsmAtomic $done ($sum | ConvertTo-Json)
Write-Host "Structure: present=$present missing=$missing (junk=$junk real=$real) extra~$($tCount-$present) -> $report"