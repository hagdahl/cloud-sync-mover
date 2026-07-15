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
| diagnostics | `Read-OneDriveSyncState.ps1` + `read_sync_state.py` | state JSON | No (SQLite snapshot) |
| emergency stop | `stop_all_jobs.ps1` / `start_all_jobs.ps1` | — | — |

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

## Log diagnostics (complement to the state DB)

Beyond the sync engine's *state* (`read_sync_state.py`) there are two log parsers for the *event stream*:

| Script | Reads | Role |
|---|---|---|
| `Read-OneDriveLogs.ps1` + `parse_odl.py` | OneDrive's ODL logs (`.aodl` plain text / `.odlgz` gzip) | counts throttle/error signals + scenario names; shows *why* the error counter is high right now |
| `Read-GoogleDriveLogs.ps1` | Google Drive's `drive_fs.txt` (plain text) | early warning for the inode trap: `MIRROR_GDOC_DELETED`, `changed inode` |

Rule: the state DB is the ground truth for the state, the log explains the ongoing activity. Run the state reader first, the log parser for detail.
