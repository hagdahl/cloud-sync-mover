# Invoke-RoundTripProbe.ps1 - #9: prove the provider is ACTUALLY syncing, not just displaying
# "Up to date". Writes ONE tiny, non-identifying canary into a dedicated probe folder, then asks an
# operator-supplied confirm command whether that canary became visible on the OTHER side (web/second
# device). A real round-trip is the only positive proof that pending local changes will actually leave
# this machine before the source is retired.
#
# SAFETY (non-negotiable):
#   * Dry-run is the DEFAULT. Nothing is written unless -Execute is passed.
#   * The canary is a single file named .csm_roundtrip_<token>.txt whose only content is a random,
#     non-identifying token. No account ids, no user data, no filenames from the real tree.
#   * It is written ONLY into [probe] probe_dir - a folder the operator dedicates to this test - never
#     into the live source/target tree.
#   * Cleanup is bounded: only the exact canary file this run created is removed.
#   * Round-trip confirmation is delegated to [probe] confirm_command, which the OPERATOR supplies and
#     which runs in THEIR environment (rclone against the provider web, a check on a second device,
#     etc.). The token is exposed to that command via the CSM_PROBE_TOKEN env var (and an optional
#     {token} placeholder). This script never contacts the provider itself.
param(
    [Parameter(Mandatory)][string]$Config,
    [switch]$Execute,
    [int]$TimeoutSeconds = 0,
    [int]$PollSeconds = 0
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$cfg   = Get-CsmConfig -Path $Config
$wd    = Get-CsmWorkDir -Config $cfg
$dir   = Get-CsmValue $cfg 'probe' 'probe_dir'
$conf  = Get-CsmValue $cfg 'probe' 'confirm_command'
if (-not $TimeoutSeconds) { $TimeoutSeconds = [int](Get-CsmValue $cfg 'probe' 'timeout_seconds' 300) }
if (-not $PollSeconds)    { $PollSeconds    = [int](Get-CsmValue $cfg 'probe' 'poll_seconds' 15) }
if ($PollSeconds -lt 1) { $PollSeconds = 1 }

$stamp = New-CsmStamp
$done  = Join-Path $wd "probe_${stamp}_done.json"
$log   = Join-Path $wd "probe_$stamp.log"

# Configuration readiness (reported the same way in dry-run and execute).
$ready = [ordered]@{}
$ready['probe_dir']        = $dir
$ready['probe_dir_set']    = [bool]$dir
$ready['probe_dir_exists'] = ($dir -and (Test-Path -LiteralPath $dir))
$ready['probe_dir_writable'] = ($ready['probe_dir_exists'] -and (Test-CsmWritable $dir))
$ready['confirm_command_set'] = [bool]$conf
$ready['timeout_seconds']  = $TimeoutSeconds
$ready['poll_seconds']     = $PollSeconds
$configOk = ($ready['probe_dir_set'] -and $ready['probe_dir_writable'] -and $ready['confirm_command_set'])

if (-not $Execute) {
    Write-Host "=== round-trip probe (#9) : DRY-RUN (nothing written) ==="
    Write-Host "  probe_dir            : $dir"
    Write-Host "  probe_dir writable   : $($ready['probe_dir_writable'])"
    Write-Host "  confirm_command set  : $($ready['confirm_command_set'])"
    Write-Host "  timeout / poll (s)   : $TimeoutSeconds / $PollSeconds"
    Write-Host ""
    if ($configOk) {
        Write-Host "  READY. Re-run with -Execute to write ONE canary into probe_dir and wait for the"
        Write-Host "  confirm_command to observe it on the other side (round-trip). The confirm_command"
        Write-Host "  receives the token via the CSM_PROBE_TOKEN env var (and {token} if present)."
    } else {
        Write-Host "  NOT READY. Set the following in the config before -Execute:"
        if (-not $ready['probe_dir_set'])       { Write-Host "    - [probe] probe_dir = <a dedicated folder inside the synced tree>" }
        elseif (-not $ready['probe_dir_exists']) { Write-Host "    - [probe] probe_dir does not exist: $dir" }
        elseif (-not $ready['probe_dir_writable']) { Write-Host "    - [probe] probe_dir is not writable: $dir" }
        if (-not $ready['confirm_command_set']) { Write-Host "    - [probe] confirm_command = <command that returns exit 0 once the canary is visible remotely>" }
    }
    $meta = New-CsmMeta -Config $cfg -Phase 'probe' -Success $false
    $meta['mode']     = 'dry-run'
    $meta['config_ok'] = $configOk
    foreach ($k in $ready.Keys) { $meta[$k] = $ready[$k] }
    Write-CsmAtomic $done ($meta | ConvertTo-Json -Depth 5)
    Write-Host ""
    Write-Host "PROBE: DRY-RUN ($(if ($configOk) { 'ready' } else { 'not-ready' })) -> $done"
    return
}

# --- Execute path -----------------------------------------------------------------------------------
if (-not $configOk) {
    Write-Host "REFUSED: probe not configured. Run without -Execute to see what is missing."
    exit 2
}

$token   = [guid]::NewGuid().ToString('N')
$canary  = Join-Path $dir ".csm_roundtrip_$token.txt"
$startUtc = (Get-Date).ToUniversalTime()
$outcome = 'unknown'; $confirmExit = $null; $elapsed = 0
$removed = $false

Write-CsmLog "probe start token=$token dir=$dir timeout=$TimeoutSeconds poll=$PollSeconds" $log
try {
    # 1) Write the single canary. Content is the token only - non-identifying.
    [System.IO.File]::WriteAllText($canary, "cloud-sync-mover round-trip canary`n$token`n")
    Write-CsmLog "canary written: $canary" $log

    # 2) Poll the operator-supplied confirm_command until it observes the canary or we time out.
    #    The command sees CSM_PROBE_TOKEN (and an optional {token} placeholder). It runs in the
    #    operator's environment; this script neither parses nor trusts its stdout, only its exit code.
    $deadline = $startUtc.AddSeconds($TimeoutSeconds)
    $cmd = $conf.Replace('{token}', $token)
    $env:CSM_PROBE_TOKEN = $token
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        try {
            & cmd.exe /c $cmd 2>&1 | ForEach-Object { Write-CsmLog "confirm> $_" $log }
            $confirmExit = $LASTEXITCODE
        } catch {
            $confirmExit = -1; Write-CsmLog "confirm threw: $($_.Exception.Message)" $log
        }
        if ($confirmExit -eq 0) { $outcome = 'confirmed'; break }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($outcome -ne 'confirmed') { $outcome = 'timeout' }
    $elapsed = [int](((Get-Date).ToUniversalTime()) - $startUtc).TotalSeconds
}
finally {
    Remove-Item Env:\CSM_PROBE_TOKEN -ErrorAction SilentlyContinue
    # 3) Bounded cleanup: remove ONLY the exact canary this run created.
    try {
        if (Test-Path -LiteralPath $canary) { Remove-Item -LiteralPath $canary -Force; $removed = $true }
    } catch { Write-CsmLog "cleanup failed: $($_.Exception.Message)" $log }
}

$success = ($outcome -eq 'confirmed')
$meta = New-CsmMeta -Config $cfg -Phase 'probe' -Success $success -Errors $(if ($success) { 0 } else { 1 }) -ErrorCategories @($(if ($success) { } else { 'round-trip' }))
$meta['mode']          = 'execute'
$meta['outcome']       = $outcome
$meta['confirm_exit']  = $confirmExit
$meta['elapsed_seconds'] = $elapsed
$meta['canary_removed'] = $removed
$meta['config_ok']     = $true
$meta['log']           = $log
Write-CsmAtomic $done ($meta | ConvertTo-Json -Depth 5)

if ($success) {
    Write-Host "PROBE OK: round-trip confirmed in ${elapsed}s (canary synced and observed remotely). -> $done"
} else {
    Write-Host "PROBE $($outcome.ToUpper()): the canary was NOT observed on the other side within ${TimeoutSeconds}s."
    Write-Host "  This means locally-written changes are NOT reliably reaching the provider - do NOT retire the source."
    Write-Host "  See $log and $done."
    exit 1
}
