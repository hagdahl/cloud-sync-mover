# Test-RepoHealth.ps1 - ADR-010 mitigation for the ADR-007 risk (.git inside the synced folder).
# origin is the authoritative copy; local .git can be corrupted by the sync client scanning it.
# This helper runs `git fsck` so corruption is caught early - re-clone from origin to recover.
param([switch]$Full)
$ErrorActionPreference = 'Stop'
$proj = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not (Get-Command git -EA SilentlyContinue)) { throw "git not found on PATH" }
if (-not (Test-Path (Join-Path $proj ".git"))) { Write-Host "No .git in $proj (separate git-dir per ADR-006?) - nothing to check."; return }

Write-Host "Checking git object integrity: $proj"
$fsckArgs = @('fsck', '--no-progress'); if ($Full) { $fsckArgs += '--full' }
# git fsck writes "dangling ..." notices to stderr even on healthy repos (exit 0). Relax the
# stop-preference around the call so the exit code - not a stderr line - drives the verdict.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $out = & git -C "$proj" @fsckArgs 2>&1 } finally { $ErrorActionPreference = $prevEap }
$rc = $LASTEXITCODE
$out | ForEach-Object { Write-Host "  $_" }

if ($rc -eq 0) {
    Write-Host "REPO HEALTH: OK (git fsck clean)."
} else {
    Write-Host "REPO HEALTH: PROBLEM (git fsck exit $rc)."
    Write-Host "Recovery (ADR-010): origin is authoritative. Re-clone into a fresh folder:"
    Write-Host "  git clone <origin-url> <fresh-folder>"
    Write-Host "Then restore the gitignored local files (config.local, _sources/, work_dir) from your own copies."
    exit 1
}
