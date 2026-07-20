# Invoke-CsmDiagnose.ps1 - #5: provider-aware diagnostic dispatch + aggregated health outcome.
# Routes by provider.name, gathers signals from the provider's read-only readers, and classifies via
# Get-CsmDiagnoseHealth. Output is REDACTED (counts + health only; no account ids, local paths, or
# filenames). "No known danger markers" resolves to 'unknown', never 'healthy' (#5).
param([Parameter(Mandatory)][string]$Config)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg   = Get-CsmConfig -Path $Config
$wd    = Get-CsmWorkDir -Config $cfg
$prov  = "$(Get-CsmValue $cfg 'provider' 'name' 'unknown')".ToLower()
$stamp = New-CsmStamp
$done  = Join-Path $wd "diagnose_${stamp}_done.json"

$signals = @{}; $summary = [ordered]@{}

if ($prov -eq 'google-drive') {
    $gd = & (Join-Path $PSScriptRoot 'Read-GoogleDriveState.ps1') -Config $Config -AsObject
    $signals = $gd.signals
    $summary['liveness']      = $gd.liveness
    $summary['wal_max_mb']    = $gd.wal_max_mb
    $summary['wal_large']     = $gd.wal_large
    $summary['stale_markers'] = $gd.stale_markers
    $summary['stage_queues_blocked'] = $gd.stage_queues_blocked   # #16
    $summary['stage_queues_warning'] = $gd.stage_queues_warning   # #16
    $summary['mount_stage_queues']   = $gd.mount_stage_queues     # #16: ordinals + counts only
}
elseif ($prov -like 'onedrive-*') {
    # OneDrive: snapshot the state DBs (read-only) and derive signals from the report. Throttling is
    # deliberately NOT treated as a danger signal (the "counter lies during hydration" lesson, A4).
    # FAIL-CLOSED: 'healthy' requires POSITIVE evidence THIS run - the reader ran, it produced a
    # report FRESHER than any pre-existing one, that report PARSED, and it holds >=1 real account.
    # A locked DB (reader throws -> stale report reused), a corrupt report (parse throws -> 0 conflicts),
    # or an empty/zero-account report must NOT read as verified-healthy (it resolves to 'unknown').
    $preTime = [datetime]::MinValue
    $pre = Get-ChildItem (Join-Path $wd 'state_report_*.json') -EA SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($pre) { $preTime = $pre.LastWriteTimeUtc }
    $readerOk = $false
    try { & (Join-Path $PSScriptRoot 'Read-OneDriveSyncState.ps1') -Config $Config | Out-Null; $readerOk = $true } catch { $readerOk = $false }
    $rep = Get-ChildItem (Join-Path $wd 'state_report_*.json') -EA SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $fresh = ($null -ne $rep -and $rep.LastWriteTimeUtc -gt $preTime)
    $parsedOk = $false; $conflicts = 0; $accessDenied = $false; $accounts = 0; $anyUnknown = $false
    if ($rep) {
        try {
            $j = Get-Content -LiteralPath $rep.FullName -Raw | ConvertFrom-Json
            foreach ($a in @($j.accounts)) {
                $accounts++
                $conflicts += [int]$a.conflicts
                # Fail closed: a per-account 'unknown' verdict (unreadable DB / schema drift, per
                # read_sync_state.py) means this account's state could not be confirmed -> not healthy.
                if ("$($a.verdict)" -eq 'unknown') { $anyUnknown = $true }
            }
            $parsedOk = $true
        } catch { $parsedOk = $false }
    }
    # A4 (verify field names against the real schema): the prior code looped over $a.recent_error_codes,
    # a field read_sync_state.py never emits, so 'accessDenied' was always dead. It is NOT rewired onto
    # the reader's op_result_codes 403, because a 403 there is indistinguishable from throttling, which
    # A4 deliberately does not treat as danger. The danger markers are conflicts and unknown verdicts.
    $signals['accessDenied']      = $accessDenied
    $signals['knownDangerMarker'] = ($conflicts -gt 0)
    $signals['verifiedHealthy']   = ($readerOk -and $fresh -and $parsedOk -and $accounts -gt 0 -and $conflicts -eq 0 -and -not $accessDenied -and -not $anyUnknown)
    $summary['accounts']         = $accounts
    $summary['conflicts']        = $conflicts
    $summary['report_fresh']     = $fresh
    $summary['parsed']           = $parsedOk
    $summary['unknown_accounts'] = $anyUnknown
}
else {
    $summary['note'] = "no diagnostic implementation for provider '$prov'"
}

$health = Get-CsmDiagnoseHealth $signals
# -Redacted: the diagnose artifact carries NO local paths (source_root/target_root/physical_*), so it
# is PII-free by construction and safe to deliver off-box (#18/ADR-012/ADR-014). Other phases keep the
# path identity because their artifacts stay local (ADR-013).
$meta = New-CsmMeta -Config $cfg -Phase 'diagnose' -Success ($health -eq 'healthy') -Errors 0 -ErrorCategories @() -Redacted
$meta['health']  = $health
$meta['summary'] = $summary
Write-CsmAtomic $done ($meta | ConvertTo-Json -Depth 6)

# #18 (ADR-014): optional delivery of the artifact PAST the (possibly broken) sync client via
# the provider REST API. Opt-in + config-gated (default off, A1); credentials only as the NAME
# of an env var (A2/B13); soft-fail - a delivery error never fails the diagnostic but is always
# surfaced (B8). The uploaded bytes are the artifact exactly as just written; the local file is
# then re-written with the delivery outcome appended and remains the authoritative copy.
$plan = Resolve-CsmDeliveryPlan $cfg
if ($plan.enabled) {
    $delivered = $false; $dUrl = $null; $dErr = $null
    if (-not $plan.ready) { $dErr = $plan.reason }
    else {
        # A7: bounded retry-with-backoff on transient failures; give up immediately on auth errors.
        # Attempt count and backoff base come from config (B13: retry parameters belong in config).
        $maxAtt    = [int](Get-CsmValue $cfg 'diagnose_delivery' 'max_attempts' 3)
        $baseDelay = [double](Get-CsmValue $cfg 'diagnose_delivery' 'retry_base_seconds' 2)
        $dr = Invoke-CsmUploadWithRetry -Plan $plan -FilePath $done -MaxAttempts $maxAtt -BaseDelaySec $baseDelay
        $delivered = $dr.ok; $dErr = $dr.error
        if ($dr.ok) { $dUrl = $dr.result.url }
        $meta['delivery_attempts'] = $dr.attempts
    }
    $meta['delivered_via_api']       = $delivered
    $meta['delivered_via_api_url']   = $dUrl
    $meta['delivered_via_api_error'] = $dErr
    Write-CsmAtomic $done ($meta | ConvertTo-Json -Depth 6)
    if ($plan.write_receipt) {
        $receipt = [ordered]@{ schema = 'csm.delivery-receipt/1'; artifact = (Split-Path $done -Leaf); provider = $plan.provider; delivered_via_api = $delivered; delivered_via_api_url = $dUrl; delivered_via_api_error = $dErr; finishedUtc = (Get-Date).ToUniversalTime().ToString('s') }
        Write-CsmAtomic (Join-Path $wd "diagnose_${stamp}_delivery.json") ($receipt | ConvertTo-Json)
    }
    if ($delivered) { Write-Host "DELIVERY: uploaded past the sync client -> $dUrl" }
    else { Write-Host "DELIVERY: NOT uploaded ($dErr) - the local artifact remains authoritative: $done" }
}
Write-Host "DIAGNOSE: health=$health (provider=$prov) -> $done"
