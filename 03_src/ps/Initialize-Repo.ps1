# Initialize-Repo.ps1 - git init with a SEPARATE git-dir outside the synced folder (ADR-006).
# Avoids the sync-client-vs-git-objects corruption class. First commit uses named files (never 'git add .').
param([string]$GitDataRoot = (Join-Path $env:LOCALAPPDATA "git-data"))
$ErrorActionPreference = 'Stop'
$proj = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$name = Split-Path $proj -Leaf
$gitdir = Join-Path $GitDataRoot "$name.git"
if (-not (Get-Command git -EA SilentlyContinue)) { throw "git not found on PATH" }
if (Test-Path (Join-Path $proj ".git")) { Write-Host ".git already present in $proj - nothing to do."; return }
New-Item -ItemType Directory -Force -Path $GitDataRoot | Out-Null
Write-Host "git init (separate git-dir):"
Write-Host "  worktree: $proj"
Write-Host "  git-dir : $gitdir"
git init --separate-git-dir "$gitdir" "$proj" | Out-Null
git -C "$proj" config gc.auto 0
git -C "$proj" config core.autocrlf false
git -C "$proj" config core.symlinks false
git -C "$proj" config core.longpaths true
# First commit: named paths only (A2 - never blind 'git add .'). _sources is gitignored regardless.
git -C "$proj" add README.md LICENSE .gitignore config.example CHANGELOG.md 00_admin 01_docs 03_src 04_tests
git -C "$proj" commit -m "Initial commit: cloud-sync-mover playbook and toolkit" | Out-Null
Write-Host "Done. _sources/ is gitignored and NOT committed (unscrubbed material)."