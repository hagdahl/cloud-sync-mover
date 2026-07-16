# Read-GoogleDriveState.ps1 - #8 + #15: read-only Google Drive mirror-state + startup-liveness signals.
# Read-only: file stats only, never opens the provider DBs read-write, never mutates. Emits a redacted
# signals object (no account ids / local paths / filenames in the summary). Provider-specific paths and
# marker globs are CONFIGURABLE - defaults are best-effort and should be tuned against real logs.
param([Parameter(Mandatory)][string]$Config, [int]$SampleSeconds = 0, [switch]$AsObject)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-CsmConfig -Path $Config
$cacheRoot   = Get-CsmValue $cfg 'google_drive' 'cache_root' (Join-Path $env:LOCALAPPDATA 'Google\DriveFS')
$walWarnMb   = [double](Get-CsmValue $cfg 'google_drive' 'wal_warn_mb' 512)
$staleGlobs  = @((Get-CsmValue $cfg 'google_drive' 'stale_marker_patterns' '*stale*;*.pending;*.crdownload') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$procName    = Get-CsmValue $cfg 'google_drive' 'process_name' 'GoogleDriveFS'
if (-not $SampleSeconds) { $SampleSeconds = [int](Get-CsmValue $cfg 'diagnose' 'sample_seconds' 5) }

function Measure-GdSample {
    param([string]$Root, [string]$Proc)
    $cpu = 0.0; try { $cpu = [double](((Get-Process -Name $Proc -EA SilentlyContinue) | Measure-Object CPU -Sum).Sum) } catch { }
    $walMax = 0.0; $logTick = $null
    if (Test-Path -LiteralPath $Root) {
        try { $walMax = [double](((Get-ChildItem -LiteralPath $Root -Recurse -File -Force -EA SilentlyContinue -Include '*-wal','*.db-wal') | Measure-Object Length -Maximum).Maximum / 1MB) } catch { }
        try { $logTick = (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -EA SilentlyContinue -Include '*.txt','structured_log*' | Measure-Object LastWriteTimeUtc -Maximum).Maximum } catch { }
    }
    return @{ cpu = $cpu; walMax = $walMax; logTick = $logTick }
}

$s1 = Measure-GdSample $cacheRoot $procName
Start-Sleep -Seconds $SampleSeconds
$s2 = Measure-GdSample $cacheRoot $procName

$cpuDelta   = [math]::Round($s2.cpu - $s1.cpu, 3)
$walChanged = ([math]::Abs($s2.walMax - $s1.walMax) -gt 0.01)
$logTicked  = ($s1.logTick -ne $null -and $s2.logTick -ne $null -and $s2.logTick -gt $s1.logTick)
$largeWal   = ($s2.walMax -ge $walWarnMb)

# Stale-upload markers (presence + age). Configurable globs; count only.
$stale = 0; $staleOldestMin = $null
if (Test-Path -LiteralPath $cacheRoot) {
    foreach ($g in $staleGlobs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Force -EA SilentlyContinue -Filter $g)) {
            $stale++; $ageMin = ((Get-Date) - $f.LastWriteTime).TotalMinutes
            if ($null -eq $staleOldestMin -or $ageMin -gt $staleOldestMin) { $staleOldestMin = [math]::Round($ageMin, 1) }
        }
    }
}

# #15: a large WAL means the cache is doing (or stuck mid-) heavy work - that is the "startup/scan"
# phase. The classifier then splits it by PROGRESS: a large + GROWING WAL is HEALTHY (initializing),
# while a large + STALLED WAL (no wal growth, no cpu, no log tick) is 'hung'. Defining $inStartup to
# also require progress would make 'hung' unreachable (a stalled client would look 'steady'), so the
# heavy-work indicator here is progress-independent - progress is judged inside the classifier.
$inStartup = $largeWal
$liveness  = Get-CsmLivenessVerdict -CpuDeltaSec $cpuDelta -WalChanged $walChanged -LogTicked $logTicked -InStartupPhase $inStartup

$signals = @{
    initializing      = ($liveness -eq 'initializing')
    stalled           = (($liveness -eq 'hung'))
    knownDangerMarker = ($stale -gt 0 -and (-not $inStartup))   # persistent stale markers, but not during a healthy index
    verifiedHealthy   = $false
}
$out = [ordered]@{
    provider       = 'google-drive'
    cache_present  = (Test-Path -LiteralPath $cacheRoot)
    wal_max_mb     = [math]::Round($s2.walMax, 1)
    wal_large      = $largeWal
    wal_changed    = $walChanged
    cpu_delta_sec  = $cpuDelta
    log_ticked     = $logTicked
    stale_markers  = $stale
    stale_oldest_min = $staleOldestMin
    liveness       = $liveness
    signals        = $signals
    sample_seconds = $SampleSeconds
}
if ($AsObject) { return $out }
Write-Host ($out | ConvertTo-Json -Compress)
