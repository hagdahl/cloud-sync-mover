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
    if ($LogFile) { try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {} }
}

function Write-CsmAtomic {
    # Atomic write (A6): temp + rename. UTF-8 no BOM.
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-CsmWritable {
    # Writability preflight (A4): write+delete a probe file. Returns $true/$false.
    param([string]$Dir)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { return $false }
        $probe = Join-Path $Dir (".csm_probe_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($probe, "probe")
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}