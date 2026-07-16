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
    param($Config, [string]$Phase, [bool]$Success, [int]$Errors = 0, [string[]]$ErrorCategories = @())
    $mode = 'n/a'
    try { $mode = Resolve-CsmProviderMode $Config } catch { $mode = 'invalid' }
    return [ordered]@{
        schema          = 'csm.artifact/1'
        phase           = $Phase
        provider        = (Get-CsmValue $Config 'provider' 'name' 'unknown')
        mode            = $mode
        source_root     = (Get-CsmValue $Config 'paths' 'source_root')
        target_root     = (Get-CsmValue $Config 'paths' 'target_root')
        physical_source_root = (Resolve-CsmPhysicalRoot (Get-CsmValue $Config 'paths' 'source_root'))
        physical_target_root = (Resolve-CsmPhysicalRoot (Get-CsmValue $Config 'paths' 'target_root'))
        finishedUtc     = (Get-Date).ToUniversalTime().ToString('s')
        success         = [bool]$Success
        errors          = [int]$Errors
        errorCategories = @($ErrorCategories)
    }
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
    # retryLoop, accessDenied, knownDangerMarker, verifiedHealthy.
    param([hashtable]$Signals)
    if (-not $Signals) { return 'unknown' }
    if ($Signals['initializing']) { return 'initializing' }
    if ($Signals['poisonMarker'] -or $Signals['stalled'] -or ($Signals['errorsIncreasing'] -and $Signals['retryLoop'])) { return 'blocked' }
    if ($Signals['accessDenied'] -or $Signals['errorsIncreasing'] -or $Signals['retryLoop'] -or $Signals['knownDangerMarker']) { return 'warning' }
    if ($Signals['verifiedHealthy']) { return 'healthy' }
    return 'unknown'   # "no known danger markers" is NOT "verified healthy" (#5)
}