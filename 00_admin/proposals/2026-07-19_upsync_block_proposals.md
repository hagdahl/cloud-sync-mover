# Proposals — Google Drive mirror upsync-block (2026-07-19)

**Source incident:** `00_admin/LESSONS_LEARNED.md` entry dated 2026-07-19. Pre-classification per `cowork-project-instructions` v0.62 QA point 9 given per proposal below. All items are interpretability/coverage gaps — none introduces a new PART A/PART B principle in the standard sense; they concretize existing principles inside this project's own toolkit and playbook.

---

## Proposal 1 — Scan the sync-mount root(s) for `.tmp.driveupload` (or provider-equivalent) as a first-class diagnostic signal

**Where it goes.** `03_src/ps/Read-GoogleDriveState.ps1` (currently reads only `%LOCALAPPDATA%\Google\DriveFS`) is extended, or a sibling reader is added, to also inspect the configured mirror roots on the sync-mount.

**Signal.** For each configured mirror root under `[paths] source_root` (and, if configured, `[google_drive] extra_mirror_roots`):

- presence of `.tmp.driveupload` (hidden dir at the root level),
- size (bytes and file count),
- age of the oldest / newest file inside,
- deletability probe (create + delete a small test file *inside*, without touching anything already there).

**Classification.** Emit as new keys on the diagnostic output object: `mount_stage_queues[]`. Health mapping:

- present but empty and deletable → info.
- present, non-empty, deletable → warning.
- present, non-empty, **and probe fails with PERMISSION_DENIED / access-denied** → **blocked** (this is the failure state).

**Why it's distinct from closed issue #4 and open issue #5.** #4 addressed *classification during inventory* (exclude from user-data baselines and warn on persistence). #5 addresses *provider-aware log-based upload-failure detection* on the client-cache side. Neither scans the sync-mount root itself; the observed 36 GB / 5 574-file stuck queue on a *mount root* is invisible to both.

**Pre-classification:** coverage gap — the diagnostic does not currently cover a specific location that field evidence shows is the primary failure locus for a distinct mirror-upsync-block class. Owning principle: A4 (verify), B8 (true error classification).

---

## Proposal 2 — Recognize the paired log signature `RemoveTempDirectoriesFromRoots PERMISSION_DENIED` + `INVALID_ARGUMENT: Item ID local-…` as the `blocked-mirror-upsync` state

**Where it goes.** `03_src/ps/Read-GoogleDriveLogs.ps1` (or the enrichment fed into #5's structured JSON) gains a specific pattern group for Google Drive's mirror-upsync-block signature:

- count of `RemoveTempDirectoriesFromRoots ... PERMISSION_DENIED` per rolling minute (a threshold > N in the most recent minute → still-active loop, not historical noise — addresses issue #5 acceptance criterion "distinguish historical log entries from errors that are still increasing"),
- count of `INVALID_ARGUMENT: Item ID local-` per rolling minute,
- when both are non-zero and increasing → classify as `blocked`.

**Redaction.** Path stems in the `PERMISSION_DENIED` lines carry the sync-mount root; the diagnostic summary should surface **the pattern and counts**, not the paths (a per-issue #5 acceptance criterion). The full unredacted evidence stays in the local diagnostic artifact.

**Pre-classification:** interpretability gap in the toolkit — issue #5's acceptance criteria are generic; a concrete signature list, especially the paired signal, gives the classifier a stable, testable rule. Owning principle: A4, B8.

**Delivery:** contributed as a comment on the open issue #5 rather than a separate issue, per the pre-screening convention of not duplicating existing scope.

---

## Proposal 3 — Preflight gate: refuse to move (or force operator confirmation) when the source has a persistent `.tmp.driveupload` under a sync-mount root

**Where it goes.** `03_src/ps/Test-MovePreflight.ps1`. New gate `SOURCE_STAGE_QUEUE_STUCK`:

- if the diagnostic from Proposal 1 reports one or more `mount_stage_queues` classified `blocked`, preflight fails **NEEDS_CONFIRMATION** (same failure grade as `SYNC_HEALTH_UNCONFIRMED`).
- clear via one of: successful cleanup evidence (`mount_stage_queues[i].size = 0` on a subsequent read), `[move] assume_stage_queue_clean = true` in config, or `-ForceStageQueue` flag with recorded operator reason.

**Rationale.** A `.tmp.driveupload` inside the sync mount is carried by the client's own change-location function to the new disk (it is inside the mount tree) — the destination then inherits the exact same block. This is the same class as the existing FoD-mirror-completeness preflight in `[google_drive] mode = mirror` (issue #6 in project convention): an incomplete or poisoned source is not a valid move baseline.

**Pre-classification:** coverage gap in the preflight — the current gates cover mirror completeness, sync-health confirmation and freshness of preflight artifacts, but not this specific pre-existing block. Owning principle: A1 (human in the loop for irreversible action), A3 (rollback baseline discipline).

---

## Proposal 4 — Per-DB WAL thresholds instead of one global `wal_warn_mb`

**Where it goes.** `config.example` under `[google_drive]`:

```
# Per-DB warn thresholds (MB). Fallback: wal_warn_mb.
metadata_wal_warn_mb = 100
mirror_metadata_wal_warn_mb = 400
mirror_wal_warn_mb = 200
```

`Read-GoogleDriveState.ps1`: instead of taking the max WAL across the whole cache directory, walk the known DB WAL files and evaluate each against its own threshold; report the offending DB by short name in the redacted summary (`metadata` / `mirror_metadata` / `mirror`), never the path.

**Rationale.** The observed 275 MB WAL on the metadata store was *below* the current global 512 MB threshold and therefore silent, yet already ten to twenty times the healthy steady state for that specific store. A single global threshold is either too tight (false positives during a genuine `initializing` phase on the mirror store, which #15 exists to distinguish) or too loose (misses the metadata-store hang, as here). Per-DB thresholds separate the two.

**Pre-classification:** interpretability gap in issue #15's outcome — #15 correctly separates a large-and-growing WAL from a large-and-stalled WAL; it does not address that "large" is per-DB. Owning principle: A4.

**Delivery:** contributed as a comment on the open issue #15 (extension of its acceptance criteria), not as a separate issue.

---

## Proposal 5 — When the diagnostic runs against a suspected-broken client, deliver its own report past that client

**Where it goes.** New optional block in `config.example`:

```
[diagnose_delivery]
# Local artifact directory (always written).
local_dir = <work_dir>/diagnostics
# Optional: also upload the diagnostic report to a provider folder,
# bypassing the local sync client (folder id, not path).
provider_upload_enabled = false
provider = google-drive          ; or onedrive
folder_id = 
# Credentials source per B13/A2 (env-var name or keyring entry, never inline).
credentials_env = 
```

Behavior: after `Invoke-CsmDiagnose.ps1` writes the local report, if `provider_upload_enabled = true` and credentials are resolvable, use the provider's REST API (`files.create` on Drive, Graph on OneDrive) to upload the report into the configured folder ID, then log the returned URL to the local report. Approval per A1 is captured by `provider_upload_enabled` being a checked-in false-by-default setting; the operator explicitly opts in.

**Rationale.** In the observed incident, the report about the stuck upload queue could not have travelled via that same upload queue — direct provider-API upload landed it in seconds and made it readable from another device immediately. This is B3 (offsite delivery of critical artifacts) applied specifically to the diagnostic that runs when the client is suspected of being broken.

**Pre-classification:** coverage gap — the current toolkit assumes the sync client is healthy enough to distribute its own diagnostic. Owning principle: B3, B14 (execution-vs-target-environment: the sync client is part of the target environment; a diagnostic aimed at that client should not depend on it for delivery).

---

## Summary of routing

- **New GitHub issues to file:** Proposal 1, Proposal 3, Proposal 5 (each is distinct from any current or closed issue).
- **Comment on open issue #5:** Proposal 2 (log signature concretization).
- **Comment on open issue #15:** Proposal 4 (per-DB WAL thresholds).
- **Local file authoritative:** this proposals doc; `00_admin/LESSONS_LEARNED.md` entry dated 2026-07-19.
