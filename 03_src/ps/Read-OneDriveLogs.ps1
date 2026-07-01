# Read-OneDriveLogs.ps1 - parse OneDrive ODL logs (throttle/error signals) via parse_odl.py.
# Complements Read-OneDriveSyncState.ps1: the DB is the authoritative state, the logs show the
# live event stream (why the client's error counter is high right now).
param([Parameter(Mandatory)][string]$Config, [int]$MaxFiles = 20)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"
$cfg  = Get-CsmConfig -Path $Config
$wd   = Get-CsmWorkDir -Config $cfg
$logs = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\logs"
if (-not (Test-Path -LiteralPath $logs)) { throw "OneDrive logs not found: $logs (provider must be OneDrive)" }
$py = (Get-Command python -EA SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -EA SilentlyContinue).Source }
if (-not $py) { throw "Python not found (needed to parse ODL)" }
$report = Join-Path $wd ("odl_report_{0}.json" -f (New-CsmStamp))
& $py (Join-Path $PSScriptRoot "..\py\parse_odl.py") $logs $MaxFiles | Tee-Object -FilePath $report
Write-Host "ODL report -> $report"