# _common.ps1 - shared helpers for cloud-sync-mover toolkit (ASCII-only, B8)
# Dot-source: . "$PSScriptRoot\_common.ps1"

$script:CSM_RECALL = 0x400000   # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (online-only)
$script:CSM_PINNED = 0x80000    # FILE_ATTRIBUTE_PINNED (always-keep)

function Get-CsmConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
    $cfg = @{}; $section = ''
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); $cfg[$section] = @{}; continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $t.Substring(0, $idx).Trim()
        $v = $t.Substring($idx + 1).Trim()
        if ($section -ne '') { $cfg[$section][$k] = $v }
    }
    # ENV overrides: CSM_<SECTION>_<KEY>  (uppercased)
    foreach ($s in @($cfg.Keys)) {
        foreach ($k in @($cfg[$s].Keys)) {
            $envName = ("CSM_{0}_{1}" -f $s, $k).ToUpper()
            $ev = [Environment]::GetEnvironmentVariable($envName)
            if ($ev) { $cfg[$s][$k] = $ev }
        }
    }
    return $cfg
}

function Get-CsmValue {
    param($Config, [string]$Section, [string]$Key, $Default = $null)
    if ($Config.ContainsKey($Section) -and $Config[$Section].ContainsKey($Key) -and $Config[$Section][$Key] -ne '') {
        return $Config[$Section][$Key]
    }
    return $Default
}

function New-CsmStamp { Get-Date -Format "yyyy-MM-dd_HHmmss" }

function Get-CsmWorkDir {
    param($Config)
    $wd = Get-CsmValue $Config 'paths' 'work_dir'
    if (-not $wd) { throw "work_dir not set in [paths]" }
    if (-not (Test-Path -LiteralPath $wd)) { New-Item -ItemType Directory -Force -Path $wd | Out-Null }
    return $wd
}

function Get-CsmFileStatus {
    param([int]$Attr)
    if ($Attr -band $script:CSM_RECALL) { return 'online-only' }
    elseif ($Attr -band $script:CSM_PINNED) { return 'always-keep' }
    else { return 'local-available' }
}

function Write-CsmLog {
    param([string]$Message, [string]$LogFile)
    $line = "{0}`t{1}" -f (Get-Date -Format s), $Message
    Write-Host $line
    # The line is already on the host (stdout) above, so a log-file write failure loses no data - but
    # per B8 it must not be SILENT: surface the cause on the host instead of swallowing it.
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 }
        catch { Write-Host ("{0}`tWARN: log-file write failed ({1}): {2}" -f (Get-Date -Format s), $LogFile, $_.Exception.Message) }
    }
}

function Write-CsmAtomic {
    # Atomic write (A6): temp + rename. UTF-8 no BOM.
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-CsmWriteDenialCause {
    # B8 (true error classification): map a write failure to a CONCRETE cause instead of a bare
    # "not writable". Pure classifier over the caught exception + the directory's own attributes, so
    # it is unit-testable. Returns one of: 'not-found', 'reparse-or-placeholder', 'process-lock',
    # 'permission-or-cfa' (ACL or Defender Controlled-Folder-Access - indistinguishable without an
    # admin event-log read, so reported together), 'unknown'. Never throws.
    param($Exception, [string]$Dir)
    try {
        if ($Dir -and -not (Test-Path -LiteralPath $Dir)) { return 'not-found' }
        # A reparse point / cloud placeholder at the target changes write semantics (junction, FoD).
        if ($Dir) {
            try {
                $attr = (New-Object System.IO.DirectoryInfo $Dir).Attributes
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'reparse-or-placeholder' }
            } catch { }
        }
        $type = if ($Exception -and $Exception.GetType) { $Exception.GetType().FullName } else { '' }
        $msg  = "$($Exception.Message)"
        if ($type -match 'DirectoryNotFound|FileNotFound') { return 'not-found' }
        if ($type -match 'UnauthorizedAccess' -or $msg -match 'denied|Access is denied|UnauthorizedAccess') { return 'permission-or-cfa' }
        if ($msg -match 'being used by another process|in use|sharing violation|locked') { return 'process-lock' }
        if ($msg -match 'cloud|placeholder|reparse|offline') { return 'reparse-or-placeholder' }
        return 'unknown'
    } catch { return 'unknown' }
}

function Test-CsmWritableDetail {
    # Writability preflight (A4) with B8 cause classification. Returns @{ writable=$bool; cause=$str }.
    # cause is 'ok' on success, else a Get-CsmWriteDenialCause label.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @{ writable = $false; cause = 'not-found' } }
    $probe = Join-Path $Dir (".csm_probe_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($probe, "probe")
        Remove-Item -LiteralPath $probe -Force
        return @{ writable = $true; cause = 'ok' }
    } catch {
        return @{ writable = $false; cause = (Get-CsmWriteDenialCause $_.Exception $Dir) }
    }
}

function Test-CsmWritable {
    # Writability preflight (A4): write+delete a probe file. Returns $true/$false.
    # Thin boolean wrapper over Test-CsmWritableDetail (kept for existing callers).
    param([string]$Dir)
    return (Test-CsmWritableDetail -Dir $Dir).writable
}

# ---------------------------------------------------------------------------
# v0.3.0 additions: provider-mode validation (#6), sync-health gate (#1),
# phase success contract (#7), retire-source prerequisite gate (#2).
# ---------------------------------------------------------------------------

function Resolve-CsmProviderMode {
    # #6: validate provider/mode. Returns 'streaming' | 'mirror' | 'n/a'. Throws on an invalid combo.
    param($Config)
    $prov = "$(Get-CsmValue $Config 'provider' 'name' 'unknown')".ToLower()
    if ($prov -eq 'google-drive') {
        $m = "$(Get-CsmValue $Config 'google_drive' 'mode' 'streaming')".ToLower()
        if ($m -ne 'streaming' -and $m -ne 'mirror') {
            throw "Invalid [google_drive] mode '$m' (expected 'streaming' or 'mirror')"
        }
        return $m
    }
    if ($prov -like 'onedrive-*') { return 'n/a' }
    if ($prov -eq 'unknown') { throw "provider.name not set (expected onedrive-personal | onedrive-business | google-drive)" }
    return 'n/a'
}

function Resolve-CsmSyncHealth {
    # #1: sync-health gate. CONFIRMED only via [move] assume_up_to_date=true or the -Confirmed switch.
    param($Config, [switch]$Confirmed)
    if ($Confirmed) { return @{ status = 'CONFIRMED'; source = 'flag' } }
    $a = "$(Get-CsmValue $Config 'move' 'assume_up_to_date' 'false')".ToLower()
    if ($a -eq 'true') { return @{ status = 'CONFIRMED'; source = 'config' } }
    return @{ status = 'NEEDS_CONFIRMATION'; source = 'none' }
}

function New-CsmMeta {
    # #7: common artifact header stamped into every *_done.json.
    # -Redacted (diagnose phase, #18 / ADR-012 / ADR-014): OMIT the local-path identity fields so the
    # artifact is PII-free BY CONSTRUCTION and safe to deliver off-box - it carries provider/mode +
    # counts + health only, with roots_redacted=$true standing in for the paths. Non-redacted callers
    # (preflight/structure/verify/retire) keep the paths; those artifacts stay local (ADR-013).
    param($Config, [string]$Phase, [bool]$Success, [int]$Errors = 0, [string[]]$ErrorCategories = @(), [switch]$Redacted)
    $mode = 'n/a'
    try { $mode = Resolve-CsmProviderMode $Config } catch { $mode = 'invalid' }
    $m = [ordered]@{
        schema   = 'csm.artifact/1'
        phase    = $Phase
        provider = (Get-CsmValue $Config 'provider' 'name' 'unknown')
        mode     = $mode
    }
    if ($Redacted) {
        $m['roots_redacted'] = $true
    } else {
        $m['source_root']          = (Get-CsmValue $Config 'paths' 'source_root')
        $m['target_root']          = (Get-CsmValue $Config 'paths' 'target_root')
        $m['physical_source_root'] = (Resolve-CsmPhysicalRoot (Get-CsmValue $Config 'paths' 'source_root'))
        $m['physical_target_root'] = (Resolve-CsmPhysicalRoot (Get-CsmValue $Config 'paths' 'target_root'))
    }
    $m['finishedUtc']     = (Get-Date).ToUniversalTime().ToString('s')
    $m['success']         = [bool]$Success
    $m['errors']          = [int]$Errors
    $m['errorCategories'] = @($ErrorCategories)
    return $m
}

function Get-CsmLatestArtifact {
    # The <Prefix>_*_done.json with the newest CONTENT finishedUtc (not file mtime, which a
    # restore/copy can bump). Returns the parsed object, or $null when none exist OR the newest
    # one fails to parse (fail closed - a corrupt newest artifact must not fall back to an older green one).
    param([string]$WorkDir, [string]$Prefix)
    $files = Get-ChildItem (Join-Path $WorkDir ("{0}_*_done.json" -f $Prefix)) -EA SilentlyContinue
    if (-not $files) { return $null }
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $bestObj = $null; $bestKey = $null; $bestParseOk = $true
    foreach ($file in $files) {
        $obj = $null; $parseOk = $true
        try { $obj = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { $parseOk = $false }
        $key = $file.LastWriteTimeUtc
        if ($obj -and (@($obj.PSObject.Properties.Name) -contains 'finishedUtc') -and $obj.finishedUtc) {
            try { $key = [datetime]::Parse([string]$obj.finishedUtc, [System.Globalization.CultureInfo]::InvariantCulture, $styles) } catch { }
        }
        if ($null -eq $bestKey -or $key -gt $bestKey) { $bestKey = $key; $bestObj = $obj; $bestParseOk = $parseOk }
    }
    if (-not $bestParseOk) { return $null }
    return $bestObj
}

function Test-CsmArtifactSuccess {
    # True only when the artifact explicitly reports success (or legacy PASS=true).
    param($Meta)
    if (-not $Meta) { return $false }
    $names = @($Meta.PSObject.Properties.Name)
    if ($names -contains 'success') { return [bool]$Meta.success }
    if ($names -contains 'PASS')    { return [bool]$Meta.PASS }
    return $false
}

function Get-CsmArtifactAgeDays {
    # Age in days of an artifact's finishedUtc vs $Now, or $null when unparseable.
    param($Meta, [datetime]$Now)
    if (-not $Meta) { return $null }
    if (-not (@($Meta.PSObject.Properties.Name) -contains 'finishedUtc') -or -not $Meta.finishedUtc) { return $null }
    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $d = [datetime]::Parse([string]$Meta.finishedUtc, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return ($Now - $d).TotalDays
    } catch { return $null }
}

function Assert-CsmRetireReady {
    # #2: enforce retire-source prerequisites from phase evidence.
    # Returns @{ ok = [bool]; reasons = @() }. Pure/deterministic (no destructive action).
    param($Config, [string]$WorkDir, [datetime]$Now = (Get-Date).ToUniversalTime())
    $reasons = @()
    $minDays = [int](Get-CsmValue $Config 'move' 'min_stable_days' 5)
    $maxAge  = [double](Get-CsmValue $Config 'move' 'retire_max_artifact_age_days' 7)
    $src  = Get-CsmValue $Config 'paths' 'source_root'
    $tgt  = Get-CsmValue $Config 'paths' 'target_root'
    $prov = Get-CsmValue $Config 'provider' 'name' 'unknown'

    $arts = @{
        preflight = (Get-CsmLatestArtifact $WorkDir 'preflight')
        structure = (Get-CsmLatestArtifact $WorkDir 'structure')
        verify    = (Get-CsmLatestArtifact $WorkDir 'verify')
    }
    foreach ($name in @('preflight','structure','verify')) {
        if (-not $arts[$name]) { $reasons += ("missing {0} artifact (run -Phase {0} first)" -f $name) }
    }
    if ($reasons.Count) { return @{ ok = $false; reasons = $reasons } }

    if (-not $src) { $reasons += "config [paths] source_root is empty" }
    if (-not $tgt) { $reasons += "config [paths] target_root is empty" }
    foreach ($name in @('preflight','structure','verify')) {
        $m = $arts[$name]
        if (-not (Test-CsmArtifactSuccess $m)) { $reasons += ("latest {0} is not green" -f $name) }
        # Identity fails CLOSED: a missing/empty identity field is not treated as a match.
        if (-not $m.source_root -or -not $m.target_root -or -not $m.provider) {
            $reasons += ("{0} artifact is missing identity (source_root/target_root/provider) - rerun the phase" -f $name)
        } else {
            if ($src -and $m.source_root -ne $src)  { $reasons += ("{0} source_root does not match config" -f $name) }
            if ($tgt -and $m.target_root -ne $tgt)  { $reasons += ("{0} target_root does not match config" -f $name) }
            if ($m.provider -ne $prov)              { $reasons += ("{0} provider does not match config" -f $name) }
        }
        $age = Get-CsmArtifactAgeDays $m $Now
        if ($null -eq $age)       { $reasons += ("{0} artifact has no usable timestamp" -f $name) }
        elseif ($age -lt 0)       { $reasons += ("{0} artifact is future-dated (clock skew?)" -f $name) }
        elseif ($age -gt $maxAge) { $reasons += ("{0} artifact is stale ({1} d > {2} d)" -f $name, [math]::Round($age, 1), $maxAge) }
    }

    # Stability gate: require a recorded client-move completion and min_stable_days elapsed.
    $mc = Get-CsmValue $Config 'move' 'move_completed_utc'
    if (-not $mc) {
        $reasons += ("[move] move_completed_utc not set - record the client-move completion (ISO 8601 UTC) to arm the {0}-day stability gate" -f $minDays)
    } else {
        try {
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            $mcDate = [datetime]::Parse([string]$mc, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
            $elapsed = ($Now - $mcDate).TotalDays
            if ($elapsed -lt $minDays) { $reasons += ("stability interval not met ({0} d elapsed < {1} d)" -f [math]::Round($elapsed, 1), $minDays) }
        } catch { $reasons += "move_completed_utc is not a valid ISO 8601 timestamp" }
    }

    return @{ ok = ($reasons.Count -eq 0); reasons = $reasons }
}

# ---------------------------------------------------------------------------
# v0.4.0 additions: junction/reparse-safe + provider-noise-aware enumeration
# (#13, #4). The read phases must NOT traverse THROUGH junctions (a junction can
# point at another volume -> double-count or cross-volume), and should classify
# provider-internal temp/staging dirs out of the user-data baseline.
# ---------------------------------------------------------------------------

function Test-CsmReparsePoint {
    # True if $Path is a reparse point (junction / symlink / mount point).
    param([string]$Path)
    try { return ((([System.IO.File]::GetAttributes($Path)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) }
    catch { return $false }
}

function Resolve-CsmPhysicalRoot {
    # Best-effort canonical/physical form of a root, for consistent cross-phase identity and
    # junction detection. On PS7 a junction root resolves to its link target; on PS5.1 it falls
    # back to the normalized full path (LinkTarget is unavailable there). Trailing slash trimmed.
    param([string]$Path)
    if (-not $Path) { return '' }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    try {
        $di = New-Object System.IO.DirectoryInfo $full
        if ($di.Exists -and (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            $lt = $null
            try { $lt = $di.LinkTarget } catch { }   # .NET 6+/PS7 only
            if ($lt) { try { $full = [System.IO.Path]::GetFullPath($lt) } catch { } }
        }
    } catch { }
    return $full.TrimEnd('\')
}

function Get-CsmNoisePatterns {
    # #4: directory-name wildcard patterns for provider-internal temp/staging + OS noise to skip
    # and classify out of the user-data baseline. Override via [enumeration] noise_dir_patterns = a;b;c.
    param($Config)
    $override = Get-CsmValue $Config 'enumeration' 'noise_dir_patterns'
    if ($override) { return @($override -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $os = @('$Recycle.Bin', 'System Volume Information', 'Found.???')
    $prov = "$(Get-CsmValue $Config 'provider' 'name' 'unknown')".ToLower()
    if ($prov -eq 'google-drive') {
        return $os + @('.tmp.drivedownload', '.tmp.driveupload', '.drivedownload', '.driveupload')
    }
    return $os
}

function Invoke-CsmWalk {
    # Junction-safe, noise-aware recursive file walk. STREAMS System.IO.FileInfo for each user-data
    # file (pipeline-friendly, memory-light for huge trees). It never descends THROUGH a reparse-point
    # directory or a provider-noise directory; those (and access errors) are recorded into $Skipped.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$NoisePatterns = @(),
        [System.Collections.Generic.List[object]]$Skipped = $null
    )
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($sd in [System.IO.Directory]::EnumerateDirectories($dir)) {
                $name = [System.IO.Path]::GetFileName($sd)
                if (Test-CsmReparsePoint $sd) {
                    if ($null -ne $Skipped) { $Skipped.Add([pscustomobject]@{ path = $sd; kind = 'reparse' }) }
                    continue
                }
                $noise = $false
                foreach ($pat in $NoisePatterns) { if ($name -like $pat) { $noise = $true; break } }
                if ($noise) {
                    $sz = -1; try { $sz = [long]((Get-ChildItem -LiteralPath $sd -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum) } catch { }
                    if ($null -ne $Skipped) { $Skipped.Add([pscustomobject]@{ path = $sd; kind = 'noise'; name = $name; bytes = $sz }) }
                    continue
                }
                $stack.Push($sd)
            }
        } catch {
            if ($null -ne $Skipped) { $Skipped.Add([pscustomobject]@{ path = $dir; kind = 'dir-access-error'; note = $_.Exception.Message }) }
        }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) { [System.IO.FileInfo]::new($f) }
        } catch {
            if ($null -ne $Skipped) { $Skipped.Add([pscustomobject]@{ path = $dir; kind = 'file-access-error'; note = $_.Exception.Message }) }
        }
    }
}

function Get-CsmRobocopyExitInfo {
    # Interpret a robocopy exit code (bit flags). 0-7 = success (bits below); >=8 = at least one failure.
    param([int]$Code)
    $bits = @()
    if ($Code -band 1)  { $bits += 'copied' }
    if ($Code -band 2)  { $bits += 'extra' }
    if ($Code -band 4)  { $bits += 'mismatch' }
    if ($Code -band 8)  { $bits += 'FAILED' }
    if ($Code -band 16) { $bits += 'FATAL' }
    return @{ code = $Code; bits = $bits; success = ($Code -lt 8); failed = ((($Code -band 8) -ne 0) -or (($Code -band 16) -ne 0)) }
}

function Get-CsmDirFileStats {
    # Junction-safe file count + total bytes under a root (for post-move verification, #3).
    param([string]$Root, [string[]]$NoisePatterns = @())
    $n = 0; $bytes = [long]0
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return @{ files = 0; bytes = 0 } }
    Invoke-CsmWalk -Root $Root.TrimEnd('\') -NoisePatterns $NoisePatterns | ForEach-Object { $n++; $bytes += $_.Length }
    return @{ files = $n; bytes = $bytes }
}

# ---------------------------------------------------------------------------
# v0.5.0 additions: provider diagnostics classifiers (#5, #15). These are PURE
# logic so they are unit-testable without a live provider; the diagnostic scripts
# gather the real signals (logs, WAL sizes, process CPU) and feed them in here.
# ---------------------------------------------------------------------------

function Get-CsmLivenessVerdict {
    # #15: classify startup/scan liveness from two samples taken N seconds apart.
    # Returns 'initializing' (in a startup/scan phase AND making progress), 'hung' (in a startup
    # phase but NO forward progress), or 'steady' (not in a startup phase).
    param([double]$CpuDeltaSec = 0, [bool]$WalChanged = $false, [bool]$LogTicked = $false, [bool]$IoProgressed = $false, [bool]$InStartupPhase = $false)
    $progress = ($CpuDeltaSec -gt 0.05) -or $WalChanged -or $LogTicked -or $IoProgressed
    if ($InStartupPhase) { if ($progress) { return 'initializing' } else { return 'hung' } }
    return 'steady'
}

function Get-CsmDiagnoseHealth {
    # #5: aggregate provider signals into a single health outcome. Pure logic.
    # $Signals keys (all optional bools): initializing, poisonMarker, stalled, errorsIncreasing,
    # retryLoop, accessDenied, knownDangerMarker, verifiedHealthy, and (#16) stageQueueBlocked,
    # stageQueueWarning. stageQueueBlocked is checked BEFORE initializing: an ACL-poisoned
    # staging queue on the mount does not resolve by waiting out a startup scan.
    param([hashtable]$Signals)
    if (-not $Signals) { return 'unknown' }
    if ($Signals['stageQueueBlocked']) { return 'blocked' }
    if ($Signals['initializing']) { return 'initializing' }
    if ($Signals['poisonMarker'] -or $Signals['stalled'] -or ($Signals['errorsIncreasing'] -and $Signals['retryLoop'])) { return 'blocked' }
    if ($Signals['accessDenied'] -or $Signals['errorsIncreasing'] -or $Signals['retryLoop'] -or $Signals['knownDangerMarker'] -or $Signals['stageQueueWarning']) { return 'warning' }
    if ($Signals['verifiedHealthy']) { return 'healthy' }
    return 'unknown'   # "no known danger markers" is NOT "verified healthy" (#5)
}

# ---------------------------------------------------------------------------
# v0.6.0-wip additions: sync-mount staging-queue scan (#16). The client cache
# says nothing about a stuck staging dir ON THE MOUNT ITSELF - the field case
# (2026-07-19 lesson) where an undeletable .tmp.driveupload on one mirror root
# blocked ALL mirror upsync while every cache-side signal stayed quiet.
# ---------------------------------------------------------------------------

function Get-CsmStageDirName {
    # #16: name of the provider's staging-queue dir AT THE ROOT of each mirror root.
    # google-drive: .tmp.driveupload (override: [google_drive] stage_dir_name).
    # Other providers have no known in-mount staging queue -> $null (scan skipped);
    # add a per-provider key here when one is identified.
    param($Config)
    $prov = "$(Get-CsmValue $Config 'provider' 'name' 'unknown')".ToLower()
    if ($prov -eq 'google-drive') {
        return (Get-CsmValue $Config 'google_drive' 'stage_dir_name' '.tmp.driveupload')
    }
    return $null
}

function Get-CsmMirrorRoots {
    # #16: ordered mirror roots to scan. Ordinal 0 = [paths] source_root; ordinals 1..N =
    # [google_drive] extra_mirror_roots (';'-separated, config order). A backup root that
    # lives under the sync mount belongs in extra_mirror_roots too. The ordinal IS the
    # redaction: summaries identify roots by position, never by path.
    param($Config)
    $roots = New-Object System.Collections.Generic.List[string]
    $src = Get-CsmValue $Config 'paths' 'source_root'
    if ($src) { [void]$roots.Add("$src".TrimEnd('\')) }
    $extra = Get-CsmValue $Config 'google_drive' 'extra_mirror_roots'
    if ($extra) {
        foreach ($r in ("$extra" -split ';')) { $t = $r.Trim(); if ($t) { [void]$roots.Add($t.TrimEnd('\')) } }
    }
    return $roots.ToArray()   # ToArray, not @(): see Get-CsmMountStageQueues
}

function Test-CsmDeleteAccess {
    # #16: NON-destructive deletability check of an EXISTING file: open it with DELETE
    # desired access (no read, no write, no change), close the handle. 'ok' = the ACL grants
    # delete; 'denied' = ACCESS_DENIED (the field signature: files carried over from older
    # deployments whose ACL/owner denies delete, while NEW files still create+delete fine);
    # 'locked' = sharing violation (an open handle without FILE_SHARE_DELETE - can be a
    # legitimately active upload); 'error:<n>' = other Win32 error; 'unavailable' = the
    # native probe cannot run here (non-Windows / compile failure). Never throws.
    param([string]$Path)
    if (-not ('CsmNative.Probe' -as [type])) {
        try {
            Add-Type -ErrorAction Stop -TypeDefinition 'using System; using System.Runtime.InteropServices; namespace CsmNative { public static class Probe { [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template); [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool CloseHandle(IntPtr h); } }'
        } catch { return 'unavailable' }
    }
    try {
        $h = [CsmNative.Probe]::CreateFileW("\\?\$Path", [uint32]0x00010000, [uint32]7, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($h.ToInt64() -ne -1) { [void][CsmNative.Probe]::CloseHandle($h); return 'ok' }
        if ($err -eq 5)  { return 'denied' }
        if ($err -eq 32) { return 'locked' }
        return "error:$err"
    } catch { return 'unavailable' }
}

function Get-CsmStageQueueClass {
    # #16: pure classifier for one scanned staging-queue entry.
    #   'none'    - staging dir absent (or root missing)
    #   'info'    - present, empty, deletable
    #   'warning' - present + non-empty + deletable, OR empty but probe-denied, OR existing
    #               files only 'locked' (an active upload may legitimately hold its files)
    #   'blocked' - present + non-empty + a deletability probe says DENIED (either the fresh
    #               create/delete probe or the existing-file DELETE-access sample)
    param([bool]$Present, [long]$FileCount = 0, [string]$DeleteProbe = 'missing', [string]$ExistingDeleteProbe = 'n/a')
    if (-not $Present) { return 'none' }
    $denied = ($DeleteProbe -eq 'denied') -or ($ExistingDeleteProbe -eq 'denied')
    if ($FileCount -gt 0) { if ($denied) { return 'blocked' } else { return 'warning' } }
    if ($denied) { return 'warning' }
    return 'info'
}

function Get-CsmMountStageQueues {
    # #16: scan each mirror root for the staging-queue dir DIRECTLY under it. Single-level
    # enumeration only (never recurses into the queue), never reads file content. REDACTED
    # by construction: entries carry ordinals, counts and probe outcomes - no paths, no names.
    # Probes: (a) create+delete of a fresh uniquely-named file (never touches pre-existing
    # files); (b) DELETE-access handle-open on up to $SampleExisting of the OLDEST existing
    # files - non-destructive, and the only probe that catches the field case (carried-over
    # files deny delete while new files create/delete fine, so (a) alone would read 'ok').
    param([string[]]$Roots, [string]$StageDirName, [int]$SampleExisting = 3)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        $root = $Roots[$i]
        $e = [ordered]@{
            root_ordinal = $i; root_present = $false; present = $false
            size_bytes = [long]0; file_count = 0; subdir_count = 0
            oldest_utc = $null; newest_utc = $null; enum_error = $false
            delete_probe = 'missing'; existing_delete_probe = 'n/a'; class = 'none'
        }
        if ($root -and (Test-Path -LiteralPath $root)) {
            $e.root_present = $true
            $sd = Join-Path $root $StageDirName
            if (Test-Path -LiteralPath $sd) {
                $e.present = $true
                $files = New-Object System.Collections.Generic.List[object]
                try { foreach ($f in [System.IO.Directory]::EnumerateFiles($sd)) { $files.Add([System.IO.FileInfo]::new($f)) } }
                catch { $e.enum_error = $true }
                try { $e.subdir_count = @([System.IO.Directory]::EnumerateDirectories($sd)).Count } catch { }
                $e.file_count = $files.Count
                foreach ($fi in $files) { $e.size_bytes += [long]$fi.Length }
                $sorted = @()
                if ($files.Count) {
                    $sorted = @($files | Sort-Object LastWriteTimeUtc)
                    $e.oldest_utc = $sorted[0].LastWriteTimeUtc.ToString('s')
                    $e.newest_utc = $sorted[$sorted.Count - 1].LastWriteTimeUtc.ToString('s')
                }
                # (a) fresh-file create+delete probe (never touches pre-existing files).
                $probe = Join-Path $sd (".csm_stageprobe_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
                try {
                    [System.IO.File]::WriteAllText($probe, "probe")
                    Remove-Item -LiteralPath $probe -Force
                    $e.delete_probe = 'ok'
                } catch {
                    $cause = Get-CsmWriteDenialCause $_.Exception $sd
                    if ($cause -eq 'permission-or-cfa') { $e.delete_probe = 'denied' } else { $e.delete_probe = "error:$cause" }
                    # best-effort cleanup if the file was created but could not be deleted
                    try { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -EA SilentlyContinue } } catch { }
                }
                # (b) existing-file DELETE-access sample, oldest first (non-destructive).
                if ($sorted.Count -gt 0 -and $SampleExisting -gt 0) {
                    $verdicts = @()
                    foreach ($fi in @($sorted | Select-Object -First $SampleExisting)) { $verdicts += (Test-CsmDeleteAccess $fi.FullName) }
                    if     ($verdicts -contains 'denied') { $e.existing_delete_probe = 'denied' }
                    elseif ($verdicts -contains 'locked') { $e.existing_delete_probe = 'locked' }
                    elseif (@($verdicts | Where-Object { $_ -like 'error:*' }).Count -gt 0) { $e.existing_delete_probe = [string]@($verdicts | Where-Object { $_ -like 'error:*' })[0] }
                    elseif ($verdicts -contains 'unavailable') { $e.existing_delete_probe = 'unavailable' }
                    else { $e.existing_delete_probe = 'ok' }
                }
            }
        }
        $e.class = Get-CsmStageQueueClass -Present $e.present -FileCount $e.file_count -DeleteProbe $e.delete_probe -ExistingDeleteProbe $e.existing_delete_probe
        $out.Add([pscustomobject]$e)
    }
    # ToArray, not @($out): @() on a List[object] holding PSCustomObjects throws
    # 'Argument types do not match' on both PS 5.1 and 7.
    return $out.ToArray()
}
# ---------------------------------------------------------------------------
# v0.6.0-wip additions: diagnose-artifact delivery past a broken sync client
# (#18, ADR-014). Opt-in and config-gated; credentials only as the NAME of an
# env var (A2/B13); soft-fail with a classified outcome (B8).
# ---------------------------------------------------------------------------

function Resolve-CsmDeliveryPlan {
    # #18: pure resolution of [diagnose_delivery] into an actionable plan. NEVER returns a
    # token value - only whether one is resolvable and from which env var name.
    param($Config)
    $enabled = ("$(Get-CsmValue $Config 'diagnose_delivery' 'provider_upload_enabled' 'false')".ToLower() -eq 'true')
    $plan = [ordered]@{ enabled = $enabled; provider = ''; folder_id = ''; credentials_env = ''; endpoint_base = ''; write_receipt = $true; ready = $false; reason = 'disabled' }
    if (-not $enabled) { return $plan }
    $plan.provider        = "$(Get-CsmValue $Config 'diagnose_delivery' 'provider' 'google-drive')".ToLower()
    $plan.folder_id       = "$(Get-CsmValue $Config 'diagnose_delivery' 'folder_id' '')"
    $plan.credentials_env = "$(Get-CsmValue $Config 'diagnose_delivery' 'credentials_env' '')"
    $plan.endpoint_base   = "$(Get-CsmValue $Config 'diagnose_delivery' 'endpoint_base' 'https://www.googleapis.com')".TrimEnd('/')
    $plan.write_receipt   = ("$(Get-CsmValue $Config 'diagnose_delivery' 'write_receipt' 'true')".ToLower() -ne 'false')
    if ($plan.provider -ne 'google-drive') { $plan.reason = 'provider-not-implemented'; return $plan }
    if (-not $plan.folder_id)       { $plan.reason = 'missing-folder-id'; return $plan }
    if (-not $plan.credentials_env) { $plan.reason = 'missing-credentials-env'; return $plan }
    $tok = [Environment]::GetEnvironmentVariable($plan.credentials_env)
    if (-not $tok) { $plan.reason = 'credentials-unresolvable'; return $plan }
    $plan.ready = $true; $plan.reason = 'ok'
    return $plan
}

function Get-CsmDeliveryErrorClass {
    # #18/B8: classify an upload failure into a short, PII-free label. Never throws.
    param($Exception)
    if (-not $Exception) { return 'error:unknown' }
    $status = $null
    try { if ($Exception.PSObject.Properties['Response'] -and $Exception.Response) { $status = [int]$Exception.Response.StatusCode } } catch { }
    if (-not $status) { try { if ($Exception.PSObject.Properties['StatusCode'] -and $Exception.StatusCode) { $status = [int]$Exception.StatusCode } } catch { } }
    if (-not $status) { $m0 = "$($Exception.Message)"; if ($m0 -match '\b(40[0-9]|4[1-9][0-9]|50[0-9])\b') { $status = [int]$Matches[1] } }
    if ($status) {
        if ($status -eq 401) { return 'http-401-unauthorized' }
        if ($status -eq 403) { return 'http-403-forbidden' }
        if ($status -eq 404) { return 'http-404-not-found' }
        return "http-$status"
    }
    # Type-based detection first: exception MESSAGES are locale-dependent, type names are not.
    $cur = $Exception; $depth = 0
    while ($cur -and $depth -lt 5) {
        if ($cur.GetType().Name -match 'Socket|HttpRequest|WebException|Timeout') { return 'network' }
        $cur = $cur.InnerException; $depth++
    }
    $msg = "$($Exception.Message)"
    if ($msg -match 'unable to connect|connection|refused|resolve|timed out|timeout|SSL|TLS|proxy|No such host') { return 'network' }
    return ("error:" + $Exception.GetType().Name)
}

function Send-CsmProviderUpload {
    # #18: one-way, one-shot upload of a LOCAL diagnostic artifact past the sync client, via
    # the provider REST API. google-drive: multipart files.create into the configured folder
    # ID. The token is read from the env var NAMED in the plan (A2/B13) and never persisted.
    # The uploaded bytes are exactly the file as written locally (byte-identical).
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$FilePath)
    if (-not $Plan.ready) { throw "delivery plan not ready: $($Plan.reason)" }
    $tok = [Environment]::GetEnvironmentVariable($Plan.credentials_env)
    if (-not $tok) { throw "credentials env var '$($Plan.credentials_env)' is empty" }
    $name = [System.IO.Path]::GetFileName($FilePath)
    $contentBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $metaJson = (@{ name = $name; parents = @($Plan.folder_id) } | ConvertTo-Json -Compress)
    $b = "csm-" + [guid]::NewGuid().ToString('N')
    $nl = "`r`n"
    $head = "--$b$nl" + "Content-Type: application/json; charset=UTF-8$nl$nl" + $metaJson + $nl + "--$b$nl" + "Content-Type: application/json$nl$nl"
    $tail = "$nl--$b--$nl"
    $ms = New-Object System.IO.MemoryStream
    $hb = [System.Text.Encoding]::UTF8.GetBytes($head); $ms.Write($hb, 0, $hb.Length)
    $ms.Write($contentBytes, 0, $contentBytes.Length)
    $tb = [System.Text.Encoding]::UTF8.GetBytes($tail); $ms.Write($tb, 0, $tb.Length)
    $body = $ms.ToArray(); $ms.Dispose()
    $uri = "$($Plan.endpoint_base)/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -ContentType "multipart/related; boundary=$b" -Body $body -TimeoutSec 60
    $url = $null
    if ($resp -and $resp.PSObject.Properties['webViewLink'] -and $resp.webViewLink) { $url = "$($resp.webViewLink)" }
    elseif ($resp -and $resp.PSObject.Properties['id'] -and $resp.id) { $url = "https://drive.google.com/file/d/$($resp.id)/view" }
    return @{ id = "$($resp.id)"; url = $url }
}

function Invoke-CsmUploadWithRetry {
    # #18 / A7: bounded retry-with-backoff around the one-shot delivery. Retries only TRANSIENT
    # failures (network / http-5xx); gives up IMMEDIATELY on auth/permission/not-found (401/403/404) -
    # A7 requires backoff for transient errors but forbids retrying forever on auth. The overall call
    # is still soft-fail (the caller records the outcome and never fails the diagnostic on delivery).
    # Returns @{ ok=[bool]; result=<upload result or $null>; error=<class or $null>; attempts=[int] }.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$FilePath,
        [int]$MaxAttempts = 3,
        [double]$BaseDelaySec = 2
    )
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($BaseDelaySec -lt 0) { $BaseDelaySec = 0 }
    $attempt = 0; $lastErr = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $r = Send-CsmProviderUpload -Plan $Plan -FilePath $FilePath
            return @{ ok = $true; result = $r; error = $null; attempts = $attempt }
        } catch {
            $lastErr = Get-CsmDeliveryErrorClass $_.Exception
            if ($lastErr -match '^http-40[134]') { break }          # auth/permission/not-found: terminal (A7)
            if ($attempt -ge $MaxAttempts) { break }
            Start-Sleep -Seconds ([math]::Round($BaseDelaySec * [math]::Pow(2, $attempt - 1), 2))
        }
    }
    return @{ ok = $false; result = $null; error = $lastErr; attempts = $attempt }
}
