# LESSONS_LEARNED

Append-only. Newest on top. Distilled and de-identified from two real migrations (Google Drive mirror, OneDrive Personal). Unscrubbed originals in `_sources/`.

## 2026-07 — OneDrive Personal C: -> E: (Method A)

- **The sync error counter lies during mass hydration.** "Over 740 sync errors" turned out to be transient throttling (HTTP 429/403 on hydration), not a data problem. The sync engine state was clean (0 conflicts, 0 error status). *Lesson:* verify against the engine's SQLite state, never against the UI counter. (A4)
- **Read the client's state DB read-only.** The DBs are WAL and open by the client. Take a snapshot copy (db+wal+shm) and read the copy, or `immutable=1&mode=ro`. Never live read-write. (A7)
- **`Get-FileHash` does not exist in a spawned `powershell.exe` 5.1** (no module autoload). Confirms B14. Use `[System.Security.Cryptography.MD5]`.
- **`.NET SetAttributes` cannot set the cloud's PINNED bit.** Use `attrib +P`.
- **MD5 verify races hydration.** Verify only when the spot check = 0 online-only.
- **The structure diff's "missing" is almost entirely junk** (Thumbs.db, `~$` temp, desktop.ini, `.tmp`) — classify them, don't confuse them with data loss.
- **Cloud ground truth via the provider API (quota diff = 0) is the strongest proof** that the move did not touch the cloud.

## 2026-06 — Google Drive mirror C: -> E: (the inode trap)

- **Junction + sync engine = disaster.** The client interpreted the junction-moved root as "the content was deleted" and trashed ~1900 objects in the cloud, then flattened the structure. *Lesson:* NEVER move an active sync folder via junction/robocopy; use the client's own "change location". (core principle)
- **Keep the client completely shut down until cloud and local are consistent.** Otherwise the client re-trashes in a loop.
- **Restore the cloud parent-first.** If you restore a child whose parent is still in the trash, it ends up orphaned in the root.
- **Take a pristine backup to an unmonitored location and never touch it** — it is the ground truth during restore.
- **An SMR disk is the wrong disk for active sync.** A synced folder on an SMR archive disk gave 100% disk activity and GUI lag. Put active sync on SSD/CMR; keep SMR for sequential archives.
- **The client's local logs are gold** (`drive_fs.txt`): they show inode changes and deletions.

## Cross-cutting principles
- The cloud is the ground truth — never touch it during a move.
- Preserve FoD — never materialize everything.
- The source is the rollback baseline until sync has been proven stable for several days.
- Long-running file operations are started detached so a bridge timeout does not interrupt mid-run.

### Operational/diagnostic patterns (2026-07, distilled)

- **Detached long jobs + marker files, not streamed output.** Large enumerations/hashings over a synced surface time out in an interactive bridge and are buffered in blocks when output goes to a file. Pattern (used by the toolkit scripts): run detached, write `*_progress.txt` continuously and `*_done.json` last (atomically), and poll the marker file instead of waiting for streamed output.
- **Targeted search, not a recursive enum of the whole root.** A full `EnumerateFiles` over the synced root can be enormous (millions of online-only placeholders) and time out when you are only looking for one file or one account. Search targeted against known subfolders.
- **Free disk space as a progress/threshold measure.** On a slow disk (SMR), counting is sluggish; the delta in the target's used space is a robust, cheap progress and threshold measure (the basis of `Watch-TargetGrowth.ps1`).
- **The state DB snapshot is large — clean up.** A snapshot can be several GB (DB + large WAL). Write to local disk and delete afterward, otherwise the diagnostics eat up the very disk you are trying to free.
