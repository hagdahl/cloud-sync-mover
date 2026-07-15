# USER_GUIDE — running a move step by step

> **Warning:** risky file operations - use at your own risk, have a verified backup, run a dry-run first. See `DISCLAIMER.md`.

> Read `01_docs/PLAYBOOK.md` first. This is the operational checklist. Every destructive step requires `-Execute`; without that flag everything is a dry-run.

## Preparation
1. Copy `config.example` → `config.local`. Fill in:
   - `source_root` = current sync folder (e.g. `C:\Users\<user>\OneDrive`)
   - `target_root` = new location (fast, roomy, **not an SMR** disk)
   - `work_dir` = local working folder for artifacts (NOT in the sync folder)
   - `provider.name` = `onedrive-personal` | `onedrive-business` | `google-drive`
2. Make sure the client shows **"Uppdaterad"/"Up to date"** (no pending changes).

## Run the phases

Orchestrator (shows the plan, runs the read-only passes, stops before destructive steps):
```
powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local
```

Or phase by phase:

1. **Phase 0 — inventory (safe):**
   `powershell -File 03_src\ps\Invoke-Inventory.ps1 -Config .\config.local`
   Check `inventory_<ts>.csv` + drift warnings.

2. **Phase 1 — MD5 baseline (safe, can take time):**
   `powershell -File 03_src\ps\Invoke-Md5Baseline.ps1 -Config .\config.local`
   Started as a background job for large sets.

3. **Phase 2 — preflight (safe):**
   `powershell -File 03_src\ps\Test-MovePreflight.ps1 -Config .\config.local`
   All gates must be green (free space, writability, up-to-date, disk type).

4. **The move (manual, Method A):** follow `PROVIDER-NOTES.md` for your client — unlink, relink, Change location → `target_root`. The tool does NOT move it for you (the client must own the move).

5. **Phase 5 — structure verification:**
   `powershell -File 03_src\ps\Compare-MoveStructure.ps1 -Config .\config.local`
   "missing" should be dominated by junk (Thumbs.db/`~$`/desktop.ini/`.tmp`), truly missing ~0.

6. **Phase 6 — hydration-aware post-verify:**
   `powershell -File 03_src\ps\Invoke-HydrationVerify.ps1 -Config .\config.local`
   Re-run until the spot check = 0 online-only, then a full MD5 comparison. Can be scheduled every 2h.

7. **Diagnosis on error counters (OneDrive):**
   `powershell -File 03_src\ps\Read-OneDriveSyncState.ps1 -Config .\config.local`
   Distinguishes throttling from real errors (see PLAYBOOK 7).

8. **Phase 8/9 — gate out the source (destructive, time-gated):**
   Only after `min_stable_days` days of stable sync:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase retire-source -Execute`
   Moves (does not delete) the old source to backup, then empties it. Delete the backup much later.

## Emergency stop (A7)
```
powershell -File 03_src\ps\stop_all_jobs.ps1     # pauses/stops the sync client + toolkit jobs
powershell -File 03_src\ps\start_all_jobs.ps1    # restarts in a controlled manner
```

## If something looks wrong
- Empty target destination but "verify" green → FoD placeholders (PLAYBOOK error mech. 2). Run the hydration-aware verify.
- MD5 errors en masse → hydration probably in progress (error mech. 3), wait.
- The client shows hundreds of "sync errors" → run the state diagnosis; almost always throttling (PLAYBOOK 7).

## 7b. Log diagnosis (deeper)

- **OneDrive ODL logs (throttling details):**
  `powershell -File 03_src\ps\Read-OneDriveLogs.ps1 -Config .\config.local`
  Counts 429/403/throttle terms + `Download`/`ActiveHydration` scenarios from `.aodl`/`.odlgz`.
- **Google Drive inode/deletion warning (run BEFORE/during a Drive move):**
  `powershell -File 03_src\ps\Read-GoogleDriveLogs.ps1`
  Finds `MIRROR_GDOC_DELETED` / `changed inode` in `drive_fs.txt`. If `MIRROR_GDOC_DELETED` grows → stop Drive immediately (`stop_all_jobs.ps1`) and follow the recovery notes.
