# PLAYBOOK — moving a cloud-synced data folder between disks

Generalized, PII-free distillation of two real-world moves (Google Drive, OneDrive Personal). Code and identifiers in English; principles in English. Reference for service-specific details: `PROVIDER-NOTES.md`.

## 0. Core principles (non-negotiable)

1. **The cloud is ground truth and is never touched.** No mass deletion, no "Download all files", no structural change in the cloud during the move.
2. **Use the client's own move function — never junction/symlink.** A sync engine tracks folder identity via NTFS file-id; a junction or a robocopy-moved root can be interpreted as "content deleted" → the cloud gets trashed. The client's "Change location"/"Choose location" moves the data folder and preserves the sync identity.
3. **Preserve Files-On-Demand (FoD).** Do not materialize placeholders to "fix" the move. Never expand the set of locally mirrored files. Verification must be status-aware.
4. **The source is the rollback baseline until proven expendable.** Deletion/move of the source is time-gated (A3) and requires explicit approval (A1).
5. **Dry-run is the default.** Every destructive step is opt-in (`-Execute`).

## 1. Decision tree — which method?

```
Does the client support a built-in "change the data folder location"?
├── YES -> Use it (Method A). This is the only supported path for OneDrive,
│         and the equivalent "change folder" setting exists in Google Drive.
└── NO  -> Escalate. Do NOT move via junction/symlink/robocopy of an active
          sync root. Consider pausing the service, moving, and reconfiguring
          via the client's settings — never at the filesystem level behind the client's back.
```

A junction as a *compatibility layer for old paths* (so that scripts pointing at the old location keep working) is OK — but it is created AFTER the client has moved the data folder and the old folder has been emptied, never as the move mechanism itself.

## 2. Risk classification

This is a **risk-elevated, irreversible file operation** (B12.2): large data volumes, external service, potential data loss. Full PART A applies. Requires: dry-run, clear logging, explicit approval before every destructive step, and a documented rollback path.

## 3. The phase model

The pattern: **inventory (read) → baseline → preflight → move (the client) → verify structure → verify content (hydration-aware) → cloud ground truth → gate deletion of the source.** Long-running steps are started detached (background job) so that a command-bridge timeout does not interrupt midway.

### Phase 0 — Inventory (read-only pass)
Enumerate the entire source with `[System.IO.Directory]::EnumerateFiles(...)` and classify each file **on attributes alone** — never read content:

| Status | Attribute | Meaning |
|---|---|---|
| online-only | `RECALL` = 0x400000 set | 0-byte placeholder, cloud only |
| always-keep | `PINNED` = 0x80000 set | pinned "always keep on this device" |
| local-available | neither | materialized but not pinned |

Write a CSV (RelPath, SizeBytes, LastWriteUtc, AttrHex, Status) + a pinlist (all non-online-only). **Drift check (appendix):** for each scheduled job that *should* write regularly, compare the job's `LastRunTime` against its data files' `LastWriteTime`. A gap > a couple of days = a pre-existing silent failure that must be fixed BEFORE the move, otherwise error classes get mixed up in the post-verification.

### Phase 1 — MD5 baseline of local files
Compute MD5 for **only** local-available + always-keep (the ones that actually exist locally). Use `[System.Security.Cryptography.MD5]` (.NET) — NOT `Get-FileHash` (see failure mechanism 4). Write a CSV (RelPath, MD5, Size). This is the ground truth for the post-verification.

### Phase 2 — Preflight
Gate on: (a) the sync is "Up to date" (no pending changes), (b) free space on the target is sufficient for the local files (not the whole cloud — FoD is preserved), (c) writability probe on the target (write+delete a test file, A4), (d) disk type on the target (warn for SMR — see failure mechanism 6), (e) secure a cloud baseline via the provider's API (driveId + used quota as ground truth). Never bind to a drive letter that can drift.

### Phase 3 — Unlink
Unlink the account in the client (the cloud untouched, the local files remain). Review any custom scripts for destructive ops against the old path before reconfiguration.

### Phase 4 — Relink + Choose location
Relink the account and point the data folder at the target. **All files are initially placeholders** — do NO MD5 here (status-aware: there is no content to hash yet). Let the client rebuild the tree.

### Phase 5 — Structure verification
Build a `HashSet` of the target's relative paths and diff against the phase-0 ground truth. Expect "missing" to be dominated by non-synced junk files (Thumbs.db, `~$` Office temp, desktop.ini, `.tmp`) — classify and count them; real missing files should be ~0.

### Phase 6 — Hydration-aware post-verification
Re-pin always-keep (`attrib +P`, see failure mechanism 5), wait out the hydration, then run a full MD5 verify against the phase-1 baseline. **Do not run the verification while files are hydrating** — a spot check must show 0 online-only first, otherwise you get false errors (failure mechanism 3). It's good to schedule a re-check every hour or two until the hydration settles down.

### Phase 6b — Known folders (if applicable)
If desktop/documents/pictures are redirected into the sync folder (Known Folder Move): re-point them to the new location via `SHSetKnownFolderPath` (shell32) and verify with `GetFolderPath`.

### Phase 7 — Monitored operation
Run the service monitored. Investigate any error counter (see section 7 — usually throttling, not a data problem).

### Phase 8/9 — Time-gated deletion/move of the source
Only after N days of stable sync (config `min_stable_days`) + explicit `-Execute`: **move** (not delete) the old data folder and the cache to a backup location, then empty it. Optionally create a compatibility junction for old paths. Delete the backup much later.

## 4. Failure mechanisms and traps

1. **Sync engine + junction = inode/identity trap.** Never a junction as the move method for an active sync folder.
2. **FoD placeholder trap.** Online-only files are 0-byte; a naive copy/comparison gives a false green "verify", and a naive copy can trigger mass hydration that blows up the target disk. The move method must not materialize placeholders; verification must be status-aware.
3. **Hydration race at MD5.** Verify only once a spot check shows 0 online-only.
4. **`Get-FileHash` missing in a spawned process.** `Start-Process powershell.exe` (5.1) does not auto-load modules → `Get-FileHash` "not recognized". Use `[System.Security.Cryptography.MD5]` (.NET).
5. **`SetAttributes` cannot set the client's PINNED bit.** `.NET File.SetAttributes` fails for cloud-PINNED (0x80000). Use `& attrib.exe +P <file>` to pin (start hydration).
6. **SMR disk churns during sync.** SMR archive disks (some large cheap SATA models) are terrible at many small random writes. An actively synced folder on SMR gives 100% disk activity and GUI lag. Avoid SMR as a target for an active sync folder; otherwise lower the download speed and steer sync to idle time.
7. **Live WAL databases must never be opened read-write.** See section 7.

## 5. Verification methods (prove zero data loss)

- **Attribute classification** (phase 0) — read-only pass, no content access.
- **MD5 before/after** on local files — catch mismatches. Device-dependent shortcuts (e.g. Personal Vault `.lnk`) are regenerated per machine → expected "mismatch", whitelist them.
- **Structure diff** — relative-path set source vs target.
- **Cloud ground truth via the provider's API** — compare quota/object-ID before/after; diff = 0 proves the cloud is untouched.

## 6. Rollback window (A3)

The source is a **full rollback baseline** as long as the destination only receives a passive copy. The instant the destination takes over production (the client syncs actively, new writes go to the target), source and target diverge. A rollback to the source then loses the new writes. Therefore: keep the source until the sync has been proven stable for several days, and gate its deletion on time + approval. If needed: a data-back step (copy the newest data from the target back) or a documented acceptance of data loss in an ADR.

## 7. Sync-error diagnosis — throttling vs real errors

A high error counter in the client during/after a move is usually **transient throttling** from mass hydration, not a data problem. Verify against the engine's STATE, not against the UI:

- **State source (best):** the client's SQLite databases in `settings\<account>\`. Read `SyncEngineDatabase.db` (per-file status, operation history) and the corresponding "sync issues" DB. **Never read live read-write** (WAL mode, open by the client): take a snapshot copy (db + `-wal` + `-shm`) and read the copy, or open live with `immutable=1&mode=ro`.
- **Clean state looks like this:** 0 conflicts, per-file status only "synced" values, 0 folder errors, 0 "unrealized". Then there are no hard errors.
- **Throttling looks like this:** the operation history's `resultCode` contains 429 (Too Many Requests) / 403 (Forbidden) on `Download`/`ActiveHydration` scenarios, + a throttle-history table with `ThrottledRequest_*` rows, dated to the hydration load. Conclusion: the counter falls toward zero once the hydration is done. Action: wait, optionally lower the download speed.
- **Logs:** newer client logs may be cleartext (e.g. OneDrive's `.aodl`, magic `EBFGONED`); the provider's cloud API normally exposes no per-client sync logs.

Detailed, reusable diagnostics: `03_src/py/read_sync_state.py` + `03_src/ps/Read-OneDriveSyncState.ps1`. Since v0.5.0 `-Phase diagnose` wraps these behind a provider-aware dispatcher (`Invoke-CsmDiagnose.ps1`, OneDrive **and** Google Drive) that returns one redacted, fail-closed health verdict (`healthy`/`initializing`/`warning`/`blocked`/`unknown`); preflight consumes a fresh `initializing` as NEEDS_WAIT rather than a hard failure.

## 7b. Prove the sync round-trips before retiring (#9)

"Up to date" is a display, not proof that pending local changes actually left the machine. Before the destructive retire, run `-Phase probe` (dry-run) to check readiness, then `-Phase probe -Execute` to write ONE non-identifying canary into `[probe] probe_dir` and wait for `[probe] confirm_command` (a command *you* supply) to observe it on the other side. A confirmed round-trip is the only positive evidence that a locally-written change reaches the cloud; a timeout says it does not — do not retire. The toolkit never contacts the provider itself and never runs `-Execute` on your behalf.

## 8. Anti-patterns (do not)

- Move via junction/symlink/robocopy of an active sync root.
- "Download all files" to make the move "safer" (blows up the disk, changes nothing in the cloud but tears down FoD).
- MD5-verify while hydration is in progress.
- Delete the source right after the move (keep it as a baseline for N days).
- Open the client's live databases read-write.
- Place an active sync folder on an SMR disk.

## 9. Log parsers (diagnostic complement)

State reading (section 7) is enough for most diagnoses, but the log stream gives details and early warnings:

- **OneDrive:** `Read-OneDriveLogs.ps1` + `parse_odl.py` read the ODL logs. `.aodl` is cleartext (magic `EBFGONED`), `.odlgz` is gzip. Full de-obfuscation of file paths requires the vendor's string map and is rarely worth the trouble — scenario names + HTTP codes (429/403) are enough to confirm throttling.
- **Google Drive:** `Read-GoogleDriveLogs.ps1` scans `drive_fs.txt` for `MIRROR_GDOC_DELETED` (cloud deletion) and `changed inode` (identity change). This is the only early warning for the inode trap — run it before and during a Drive move.