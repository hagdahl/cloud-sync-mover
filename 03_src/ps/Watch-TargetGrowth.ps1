# Watch-TargetGrowth.ps1 - Phase 4 safety watchdog. During the client's rebuild on the target,
# monitor used space; if growth exceeds the metadata budget (= unexpected hydration), alarm / auto-stop.
param(
    [Parameter(Mandatory)][string]$Config,
    [double]$BudgetGB = 5,
    [int]$IntervalSeconds = 30,
    [int]$MaxMinutes = 120,
    [switch]$AutoStop
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"
$cfg = Get-CsmConfig -Path $Config
$tgt = Get-CsmValue $cfg 'paths' 'target_root'
$wd  = Get-CsmWorkDir -Config $cfg
$tgtRoot = [System.IO.Path]::GetPathRoot($tgt)
$log = Join-Path $wd ("watch_{0}.log" -f (New-CsmStamp))

function Get-Used { $di = New-Object System.IO.DriveInfo $tgtRoot; return ($di.TotalSize - $di.AvailableFreeSpace) }

$base = Get-Used
Write-CsmLog ("Watch start on {0}. baseline_used={1} GB budget={2} GB" -f $tgtRoot, [math]::Round($base / 1GB, 2), $BudgetGB) $log
$deadline = (Get-Date).AddMinutes($MaxMinutes)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSeconds
    $grow = (Get-Used) - $base
    $gGB  = [math]::Round($grow / 1GB, 2)
    Write-CsmLog ("growth={0} GB" -f $gGB) $log
    if ($grow -gt ($BudgetGB * 1GB)) {
        Write-CsmLog ("ALARM: growth {0} GB exceeds budget {1} GB (unexpected hydration)." -f $gGB, $BudgetGB) $log
        Write-Host ("ALARM: target grew {0} GB (> {1} GB budget). Likely bulk hydration - investigate." -f $gGB, $BudgetGB)
        if ($AutoStop) { & (Join-Path $PSScriptRoot 'stop_all_jobs.ps1') -Config $Config; Write-CsmLog "Auto-stopped sync client." $log }
        return
    }
}
Write-CsmLog ("Watch ended (no budget breach within {0} min)." -f $MaxMinutes) $log
Write-Host "Watch ended - no budget breach."