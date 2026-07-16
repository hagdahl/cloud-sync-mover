# ARCHITECTURE

## Design goal
A provably safe move of a cloud-synced data folder between disks, with the least possible risk and full traceability. The tools are standalone PowerShell/Python scripts run in phases; no daemon, no cloud dependency beyond the provider's quota/metadata endpoint.

## Data flow

```
config.local ──► Invoke-CloudSyncMove.ps1  (orchestrator, dry-run default)
     │
     ├─ phase 0     Invoke-Inventory.ps1      ─► inventory_<ts>.csv (+ pinlist)   [read-only]
     ├─ phase 1     Invoke-Md5Baseline.ps1    ─► md5_<ts>.csv                     [.NET MD5]
     ├─ phase 2     Test-MovePreflight.ps1    ─► preflight_<ts>.json              [gates]
     │  (the client's move is performed manually/guided — Method A)
     ├─ phase 5     Compare-MoveStructure.ps1 ─► structure_report_<ts>.txt
     ├─ phase 6     Invoke-HydrationVerify.ps1 ─► verify_<ts>.json                [hydration-aware]
     └─ diagnostics Read-OneDriveSyncState.ps1 ─► read_sync_state.py ─► state_report.json
```

All artifacts are written to `work_dir` (local, fast disk — **not** the synced folder).

## Phase map ↔ script

| Phase | Script | Writes | Reads content? |
|---|---|---|---|
| 0 inventory | `Invoke-Inventory.ps1` | inventory CSV + pinlist | No (attributes only) |
| 1 baseline | `Invoke-Md5Baseline.ps1` | md5 CSV | Yes (local files only) |
| 2 preflight | `Test-MovePreflight.ps1` | preflight JSON | No |
| 5 structure | `Compare-MoveStructure.ps1` | structure report | No |
| 6 post-verify | `Invoke-HydrationVerify.ps1` | verify JSON | Yes (after hydration) |
| diagnose | `Invoke-CsmDiagnose.ps1` → `Read-OneDriveSyncState.ps1` / `Read-GoogleDriveState.ps1` | `diagnose_<ts>_done.json` (redacted health) | No (read-only signals) |
| probe | `Invoke-RoundTripProbe.ps1` | `probe_<ts>_done.json` | No (writes one non-identifying canary; `-Execute` only) |
| retire-source | `Invoke-CloudSyncMove.ps1 -Phase retire-source -Execute` | `retire_<ts>_manifest.json` + done | No (robocopy `/MOVE`) |
| emergency stop | `stop_all_jobs.ps1` / `start_all_jobs.ps1` | — | — |

## File classification: logic / data / hybrid (B1)

| File type | Class | Note |
|---|---|---|
| `03_src/ps/*.ps1`, `03_src/py/*.py`, `04_tests/**/*.ps1` | **logic** | executable behavior; the only files whose change alters what the toolkit *does* |
| `config.example` | **hybrid** | structure (section/key names, defaults) is logic; the values are data placeholders. The real values live in `config.local` (never committed) |
| `requirements.txt` | **hybrid** | an environment pin (B6): declarative data that constrains logic |
| `README.md`, `01_docs/*.md`, `00_admin/PRINCIPLES.md`, `00_admin/DISCLAIMER.md`, `00_admin/DEFINITION_OF_DONE.md` | **data** | knowledge/documentation; no runtime effect |
| `CHANGELOG.md`, `00_admin/DECISIONS.md`, `00_admin/HANDOVER.md`, `00_admin/LESSONS_LEARNED.md` | **data** | append-mostly project records |
| `inventory_*.csv`, `md5_*.csv`, `*_done.json`, `*_manifest.json`, `state_report_*.json`, `*.log` | **data (generated)** | tool output in `work_dir`; never hand-edited, `.gitignore`d |

## Edit status per directory (B1)

Which parts an agent or contributor may modify, so read-only source material and the object store are never hand-edited.

| Path | Status | Rationale |
|---|---|---|
| `03_src/`, `04_tests/` | **editable** | the toolkit's logic and tests |
| `00_admin/`, `01_docs/`, and root docs (`README.md`, `LICENSE`, `.gitignore`, `CHANGELOG.md`, `config.example`, `requirements.txt`) | **editable** | project documentation and configuration surface |
| `_sources/` | **read-only** | unscrubbed source material (ADR-005); reference only, never edit, never publish (`.gitignore`d) |
| `_backups/` | **read-only** | local safety copies; never edited by hand (`.gitignore`d) |
| `02_data/`, `05_logs/`, and any configured `work_dir` | **tool-written** | generated artifacts; produced/rotated by the scripts, not hand-edited (`.gitignore`d) |
| `.git/` | **never touch** | object database; only via `git`. `.git` lives inside the synced folder (ADR-007/010) so a stray manual write risks corruption |

The **publishability level** of this repo (level 2/3 — publishable generic knowledge, with source material and generated output held back) is recorded as a decision in `00_admin/DECISIONS.md` **ADR-013**.

## Security model
- **Dry-run default** (A1): destructive steps require `-Execute`.
- **Time-gated deletion** (A3): the source is kept for `min_stable_days` days.
- **Read-only pass in phase 0** (B11 data minimization): the inventory never touches file content.
- **No cloud sharing** (A2): only the provider's own quota/metadata endpoint is called; no file content is sent.
- **Idempotency** (A6): every script can be re-run; atomic write (temp + `Move-Item -Force`); completion markers (`*_done.json`).

## Execution vs target environment (B14)
Long-running file operations are started detached (background job / separate session) so that a command-bridge timeout does not interrupt mid-run. Reads/writes against a synced surface go through host processes (PowerShell), not through a sandbox that cannot reach the sync client's write API.

## Encoding discipline (B8)
- `.ps1` — **ASCII-only** (PowerShell 5.1 reads UTF-8-without-BOM as CP1252). Verify with `Select-String '[^\x00-\x7F]'`.
- `.py` — UTF-8 without BOM; `sys.stdout.reconfigure(encoding="utf-8")` at the top.
- `.md` — UTF-8 without BOM (docs are English per ADR-008; keep them ASCII-clean where practical).
- Config is read as INI (no BOM-sensitive parser).
- **Runtime self-test (A4):** `04_tests/validation/Test-Toolkit.ps1` writes a known non-ASCII string via `Write-CsmAtomic` and asserts a byte-identical read-back and no BOM, in addition to the static per-extension checks (`.ps1` ASCII-only, `.md`/`.py` no-BOM). So the encoding contract is verified at runtime, not just linted.

## Environment (B6)
- **Runtime:** Windows 10/11; PowerShell 5.1 or 7.x; CPython 3.11, standard library only (no third-party packages). See `requirements.txt`.
- **Pinning policy (ADR-009):** if a third-party package is ever introduced it is pinned with `==` (exact), never a range. Test/dev needs nothing beyond the runtime.
- **Repo integrity (ADR-010):** `.git` lives in the synced folder (ADR-007); `origin` is authoritative and `03_src/ps/Test-RepoHealth.ps1` (`git fsck`) detects corruption early — recover by re-cloning.

## Log diagnostics (complement to the state DB)

Beyond the sync engine's *state* (`read_sync_state.py`) there are two log parsers for the *event stream*:

| Script | Reads | Role |
|---|---|---|
| `Read-OneDriveLogs.ps1` + `parse_odl.py` | OneDrive's ODL logs (`.aodl` plain text / `.odlgz` gzip) | counts throttle/error signals + scenario names; shows *why* the error counter is high right now |
| `Read-GoogleDriveLogs.ps1` | Google Drive's `drive_fs.txt` (plain text) | early warning for the inode trap: `MIRROR_GDOC_DELETED`, `changed inode` |

Rule: the state DB is the ground truth for the state, the log explains the ongoing activity. Run the state reader first, the log parser for detail.
