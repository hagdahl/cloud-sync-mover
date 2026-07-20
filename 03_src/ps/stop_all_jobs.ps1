# stop_all_jobs.ps1 - emergency stop (A7): halt toolkit jobs/watchdogs and pause the sync client.
# One sweep stops: (1) any csm_* background PS jobs in this session; (2) any long-running toolkit
# watchdog that published a csm_*.pid file in work_dir (e.g. Watch-TargetGrowth, which runs in the
# foreground and so is unreachable by Get-Job from another session); (3) the sync client itself.
param([string]$Config)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_common.ps1"
$prov = 'unknown'; $cfg = $null
if ($Config) { $cfg = Get-CsmConfig -Path $Config; $prov = Get-CsmValue $cfg 'provider' 'name' 'unknown' }

Write-Host "Stopping toolkit background jobs (csm_*)..."
Get-Job -EA SilentlyContinue | Where-Object { $_.Name -like 'csm_*' } | ForEach-Object { Stop-Job $_ -EA SilentlyContinue; Remove-Job $_ -Force -EA SilentlyContinue }

# Stop any foreground toolkit watchdog via its published PID file (csm_*.pid in work_dir). The
# $procId -ne $PID guard prevents self-termination when Watch-TargetGrowth -AutoStop dot-invokes this
# script in its own process; that watchdog's own finally-block then removes its pidfile.
if ($cfg) {
    $wd = $null; try { $wd = Get-CsmWorkDir -Config $cfg } catch { }
    if ($wd -and (Test-Path -LiteralPath $wd)) {
        foreach ($pf in @(Get-ChildItem -LiteralPath $wd -Filter 'csm_*.pid' -File -EA SilentlyContinue)) {
            $procId = 0; try { $procId = [int]((Get-Content -LiteralPath $pf.FullName -Raw).Trim()) } catch { }
            if ($procId -gt 0 -and $procId -ne $PID) {
                if (Get-Process -Id $procId -EA SilentlyContinue) {
                    Write-Host ("Stopping toolkit watchdog pid {0} ({1})..." -f $procId, $pf.Name)
                    Stop-Process -Id $procId -Force -EA SilentlyContinue
                }
                Remove-Item -LiteralPath $pf.FullName -Force -EA SilentlyContinue
            }
        }
    }
}

if ($prov -like 'onedrive*') {
    $od = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\OneDrive.exe"
    if (Test-Path $od) { Write-Host "OneDrive /shutdown"; & $od /shutdown } else { Get-Process OneDrive -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
} elseif ($prov -eq 'google-drive') {
    Get-Process GoogleDriveFS -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
} else {
    Write-Host "Provider unknown; stop the sync client manually."
}
Write-Host "Stopped. Sync churn halted."
