# USER_GUIDE — running a move step by step

> **Warning:** risky file operations - use at your own risk, have a verified backup, run a dry-run first. See `DISCLAIMER.md`.

> Read `01_docs/PLAYBOOK.md` first. This is the operational checklist. Every destructive step requires `-Execute`; without that flag everything is a dry-run.

## Preparation
1. Copy `config.example` → `config.local`. Fill in:
   - `source_root` = current sync folder (e.g. `C:\Users\<user>\OneDrive`)
   - `target_root` = new location (fast, roomy, **not an SMR** disk)
   - `work_dir` = local working folder for artifacts (NOT in the sync folder)
   - `provider.name` = `onedrive-personal` | `onedrive-business` | `google-drive`
2. Make sure the client shows **"Up to date"** (no pending changes). Once confirmed, set `[move] assume_up_to_date = true` (or pass `-SyncConfirmed` to preflight) — the preflight sync-health gate requires it.
3. After you perform the client move (step 4 below), record `[move] move_completed_utc` (ISO 8601 UTC, e.g. `2026-07-20T10:00:00Z`). The retire-source stability gate needs it to count `min_stable_days`.

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
   `powershell -File 03_src\ps\Test-MovePreflight.ps1 -Config .\config.local -SyncConfirmed`
   All gates must be green: free space, writability, disk type, provider/mode validity, and **sync-health** — which reports `NEEDS_CONFIRMATION` (a FAIL) until you pass `-SyncConfirmed` or set `[move] assume_up_to_date = true`. Preflight also consumes a recent `diagnose` result (step 7): a fresh `initializing` provider reports **NEEDS_WAIT** (wait for the client to finish its startup/scan, don't treat it as a hard failure); a fresh `blocked` fails; Google Drive **mirror** mode is blocked if the local content is incomplete (any online-only file); and a large or inaccessible provider staging dir is flagged (a possibly-stuck upload queue).
   Since #17 preflight additionally runs the **`SOURCE_STAGE_QUEUE_STUCK` gate**: it re-scans every configured mirror root for a stuck staging queue (see step 7) and grades `NEEDS_CONFIRMATION` when any root reads `blocked` — a stuck `.tmp.driveupload` is *inside* the mount tree, so a move would carry it (and the blocked upsync) to the destination. Clear paths, in order of preference: **(1)** clean the queue (recipe below) and re-run — the fresh scan then passes on its own evidence; **(2)** set `[move] assume_stage_queue_clean = true` as a deliberate recorded acceptance; **(3)** pass `-ForceStageQueue` **together with** `-StageQueueReason "<why>"` — the flag alone is refused, and both the override and the reason are recorded in the preflight artifact (same discipline as retire-source `-Force`).

4. **The move (manual, Method A):** follow `PROVIDER-NOTES.md` for your client — unlink, relink, Change location → `target_root`. The tool does NOT move it for you (the client must own the move).

5. **Phase 5 — structure verification:**
   `powershell -File 03_src\ps\Compare-MoveStructure.ps1 -Config .\config.local`
   "missing" should be dominated by junk (Thumbs.db/`~$`/desktop.ini/`.tmp`), truly missing ~0.

6. **Phase 6 — hydration-aware post-verify:**
   `powershell -File 03_src\ps\Invoke-HydrationVerify.ps1 -Config .\config.local`
   Re-run until the spot check = 0 online-only, then a full MD5 comparison. Can be scheduled every 2h.

7. **Diagnose — provider health (safe):**
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase diagnose`
   Provider-aware (OneDrive **and** Google Drive). Emits a single redacted health verdict — `healthy` / `initializing` / `warning` / `blocked` / `unknown` — into `diagnose_<ts>_done.json`. "No known danger marker" is `unknown`, never `healthy`. A large + *growing* Google Drive cache during startup is `initializing` (healthy), not a hang. Throttling is not treated as a danger. Preflight reads this result (see step 3).
   Since #16 the Google Drive path also scans **each configured mirror root** (`source_root` + `[google_drive] extra_mirror_roots`) for a stuck staging queue (`.tmp.driveupload`): non-empty **and** undeletable → the verdict is `blocked` even when the cache looks quiet. See "Stuck staging queue" below for the cleanup recipe.

8. **Probe — prove the sync actually round-trips (opt-in write):**
   Dry-run first (writes nothing, just checks readiness):
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase probe`
   "Up to date" is a *display*, not proof that pending local edits leave the machine. Set `[probe] probe_dir` (a dedicated folder inside the synced tree) and `[probe] confirm_command` (a command *you* supply that returns exit 0 once the canary is visible on the other side — provider web or a second device; the token arrives via `%CSM_PROBE_TOKEN%`). Then run with `-Execute` to write ONE non-identifying canary and wait for the round-trip:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase probe -Execute`
   Only that canary is written, and it is cleaned up afterward. A failed round-trip means local changes are NOT reliably reaching the provider — do not retire the source.

9. **Phase 8/9 — gate out the source (destructive, time-gated):**
   First run it **without** `-Execute` to see the prerequisite gate:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase retire-source`
   The gate refuses unless the latest **preflight**, **structure**, and **verify** artifacts are all present, green (`success:true`), refer to the same source/target/provider, are recent (`retire_max_artifact_age_days`), and `min_stable_days` have elapsed since `move_completed_utc`. When the gate reads PASS:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase retire-source -Execute`
   It moves (does not delete) the old source to backup, then empties it. Delete the backup much later. An unmet gate can be overridden only with an explicit, recorded `-Force` — avoid it unless you understand the risk.

## Emergency stop (A7)
```
powershell -File 03_src\ps\stop_all_jobs.ps1     # pauses/stops the sync client + toolkit jobs
powershell -File 03_src\ps\start_all_jobs.ps1    # restarts in a controlled manner
```

## If something looks wrong
- Empty target destination but "verify" green → FoD placeholders (PLAYBOOK error mech. 2). Run the hydration-aware verify.
- MD5 errors en masse → hydration probably in progress (error mech. 3), wait.
- The client shows hundreds of "sync errors" → run the state diagnosis; almost always throttling (PLAYBOOK 7).

## Stuck staging queue (`SOURCE_STAGE_QUEUE_STUCK`) — cleanup recipe

Diagnose (#16) or preflight (#17) reports a mirror root's staging queue as `blocked` when it is non-empty **and** a deletability probe is denied. The classic cause is `.tmp.driveupload` content carried over from an older deployment/disk whose ACL or owner denies delete — the client then loops `RemoveTempDirectoriesFromRoots ... PERMISSION_DENIED` and **all** mirror upsync stalls, silently. Cleanup (operator step, elevated prompt):

1. **Quit the sync client completely** (tray icon → Quit) and verify the process is gone.
2. Take ownership and grant yourself full control over the queue:
   `takeown /F "<mirror-root>\.tmp.driveupload" /R /D Y`
   `icacls "<mirror-root>\.tmp.driveupload" /grant "%USERNAME%:(OI)(CI)F" /T`
3. Delete it: `rd /S /Q "<mirror-root>\.tmp.driveupload"`
4. Restart the client and let it settle (it recreates a fresh staging dir when needed).
5. Re-run diagnose and confirm the root's `mount_stage_queues` entry now reads `present = false` (or `size_bytes = 0`) — that evidence is what clears the preflight gate.

Do **not** rename or delete `%LOCALAPPDATA%\Google\DriveFS\` for this — that is the last resort and loses the local upsync queue. Repeat for every root the scan flags (each top-level mirror root can carry its own queue, including ReadOnly-attributed backup roots).

## Delivering the diagnostic when the client is broken (#18)

The diagnose report normally reaches other devices via the sync client — but when the client *is* the suspected-broken part (the exact situation diagnose exists for), the report about the broken upload queue would sit in that same queue. `[diagnose_delivery]` gives the phase an opt-in path that bypasses the client entirely and uploads the redacted artifact via the provider's REST API:

1. In the provider's web UI, create a dedicated **"diagnostics inbox"** folder and copy its **folder ID** from the URL.
2. Obtain an OAuth access token with file-create scope — for Google Drive, `drive.file` is sufficient and least-privilege (it can only see files it created itself).
3. Put the token in an environment variable (e.g. `CSM_DIAG_TOKEN`) — **never** in the config file.
4. In `config.local`:
   ```
   [diagnose_delivery]
   provider_upload_enabled = true
   provider = google-drive
   folder_id = <the folder id>
   credentials_env = CSM_DIAG_TOKEN
   ```
5. Run diagnose as usual. The local artifact in `work_dir` is always written first and remains the authoritative copy; on success the run prints `DELIVERY: uploaded past the sync client -> <url>` and the artifact + a local receipt record the URL. On any failure (missing/expired token, 4xx, network) the delivery **soft-fails**: the outcome is classified and recorded, the diagnostic itself still completes.

Only the redacted diagnose artifact is ever uploaded (counts + health + root ordinals — no paths, filenames, or account ids). Inventory CSVs, hash baselines, and log excerpts stay local. See `00_admin/DECISIONS.md` ADR-014.

## 7b. Log diagnosis (deeper)

- **OneDrive ODL logs (throttling details):**
  `powershell -File 03_src\ps\Read-OneDriveLogs.ps1 -Config .\config.local`
  Counts 429/403/throttle terms + `Download`/`ActiveHydration` scenarios from `.aodl`/`.odlgz`.
- **Google Drive inode/deletion warning (run BEFORE/during a Drive move):**
  `powershell -File 03_src\ps\Read-GoogleDriveLogs.ps1`
  Finds `MIRROR_GDOC_DELETED` / `changed inode` in `drive_fs.txt`. If `MIRROR_GDOC_DELETED` grows → stop Drive immediately (`stop_all_jobs.ps1`) and follow the recovery notes.
