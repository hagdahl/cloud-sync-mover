# PROVIDER-NOTES — service-specific details

The only thing specific to this project is which services and client versions it has been tested against. No environments, people, or systems are mentioned.

## OneDrive (Personal and Business)

- **Move method:** Method A — Settings → Account → **Unlink this PC**, then re-run the sign-in and choose **Change location** → point to the target disk. This is the only path supported by Microsoft. Junction/symlink is not supported. The cache cannot be moved — it is rebuilt in the new location (via Reset if needed).
- **Tested client versions:** 26.106.0603.0003 and 26.108.0607.0002 (Windows).
- **Files-On-Demand attributes:** online-only = `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x400000); pinned "always keep" = `FILE_ATTRIBUTE_PINNED` (0x80000). Pin with `attrib +P` (not `.NET SetAttributes`).
- **State/diagnostics:** `%LOCALAPPDATA%\Microsoft\OneDrive\settings\<account>\` — SQLite. Key files: `SyncEngineDatabase.db` (tables `od_ClientFile_Records.fileStatus`, `od_ServiceOperationHistory.resultCode/scenarioName`, `od_ThrottleHistory`), `OCSI.db` (`ocsi_property_records.conflictJson`). Accounts: `Personal`, `Business1`, ...
- **Logs:** `%LOCALAPPDATA%\Microsoft\OneDrive\logs\<account>\` — `.aodl` (plain text, magic `EBFGONED`), `.odlgz` (gzip).
- **Known Folder Move:** if Desktop/Documents/Pictures are redirected into OneDrive, re-point via `SHSetKnownFolderPath` (shell32) after the move.
- **Cloud ground truth:** Microsoft Graph, `Connect-MgGraph -Scopes Files.Read`, `Invoke-MgGraphRequest` against `/me/drive` (quota). Graph exposes no sync logs.

## Google Drive for desktop

- **Move method:** change the folder's location in the client's **settings** (equivalent to Method A). Streaming mode (File Stream) keeps nothing locally; mirror mode (Mirror) mirrors locally.
- **Tested generation:** the 2024–2025 client.
- **Critical lesson (the inode trap):** NEVER move a mirror folder via junction or robocopy and start the client against it — the client interprets the changed root identity as "the content was deleted" and puts objects in the cloud trash, and can flatten the folder structure. Keep the client completely shut down until cloud and local are consistent; restore in the cloud parent-first if anything was trashed.
- **Disk choice:** an actively synced Drive mirror on an SMR disk gives 100% disk activity — avoid.
- **Logs:** `%LOCALAPPDATA%\Google\DriveFS\Logs\drive_fs.txt` (plain text) — search `MIRROR_GDOC_DELETED` (deletion), `changed inode` (identity change).
- **State/diagnostics (v0.5.0):** the local cache lives under `%LOCALAPPDATA%\Google\DriveFS\` (override with `[google_drive] cache_root`). `Read-GoogleDriveState.ps1` (invoked by `-Phase diagnose`) samples it **read-only** — the SQLite `*-wal` sizes, the `GoogleDriveFS` process CPU, and the log tick — twice, `[diagnose] sample_seconds` apart. The key lesson (#15): **a large *and growing* WAL during startup/scan is HEALTHY (`initializing`), not a hang.** The same large WAL that is *not* moving is the hung case. Tune `[google_drive] wal_warn_mb` and `stale_marker_patterns` against your own client's logs — the defaults are best-effort. The reader never opens the provider DBs read-write and emits only redacted counts.
- **Mirror mode + completeness (#6):** in `mirror` mode every file is supposed to be local; preflight blocks the move if the latest inventory shows any online-only file (the local set is incomplete).
- **Mount-side staging queue (#16):** each top-level mirror root can carry its own hidden `.tmp.driveupload` staging dir, and one *stuck* queue (non-empty + undeletable) jams `RemoveTempDirectoriesFromRoots` and thereby **all** mirror upsync — new writes in *other* roots never receive a cloud ID while every cache-side signal stays quiet. The classic cause is files carried over from older deployments/disks whose ACL/owner denies delete (new files still create+delete fine, which is why the scan also samples DELETE-access on the *oldest existing* files, non-destructively). `Read-GoogleDriveState.ps1` scans `[paths] source_root` plus `[google_drive] extra_mirror_roots` for `[google_drive] stage_dir_name` (default `.tmp.driveupload`); a `blocked` queue drives the diagnose verdict to `blocked`. Remediation is the operator's call: shut the client down, `takeown` + `icacls` on the queue, delete it, restart, re-run diagnose until the queue reads absent/empty.

## General
Any provider with Files-On-Demand + a built-in "change location" function fits the pattern. If the client has no such function: escalate, never move behind the client's back.

## Log locations and parsers

| Service | Log location | Parser in this project |
|---|---|---|
| OneDrive | `%LOCALAPPDATA%\Microsoft\OneDrive\logs\<account>\*.aodl/.odlgz` | `Read-OneDriveLogs.ps1` + `parse_odl.py` |
| Google Drive | `%LOCALAPPDATA%\Google\DriveFS\Logs\drive_fs.txt` | `Read-GoogleDriveLogs.ps1` |

## OneDrive - diagnostics notes

- **The error counter is not persisted.** The client's "N sync errors" is fetched live by the UI via an internal localhost call (`ActivityCenter/getErrors`) and is **not** saved as a table. It is therefore not possible to "dump N error rows" from disk - read the sync engine state (`Read-OneDriveSyncState.ps1`) or scroll the Activity Center panel.
- **Errors may sit on another account.** A dormant work/school account (`settings\Business1\`) can contribute to the counter even if the personal one is clean. `Read-OneDriveSyncState.ps1` / `read_sync_state.py` therefore enumerates all `settings\<account>` folders, not just Personal.
