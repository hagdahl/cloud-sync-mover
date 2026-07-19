# DATA-FORMATS — the tools' file schemas

All output is UTF-8, tab-separated (TSV with `.csv` names) or JSON. Written to `work_dir`.

## inventory_<ts>.csv  (phase 0)
Tab-separated. One row per file in the source.

| Column | Type | Example | Note |
|---|---|---|---|
| RelPath | string | `Docs\a.txt` | relative to source_root |
| SizeBytes | integer | `1024` | 0 for online-only placeholders |
| LastWriteUtc | ISO-8601 | `2026-07-01T14:00:00` | UTC |
| AttrHex | hex | `0x420` | raw file attributes |
| Status | enum | `online-only` \| `local-available` \| `always-keep` | attribute classification |

## pinlist_<ts>.txt  (phase 0)
One relative path per row — all files that are NOT online-only (i.e. present locally).

## md5_<ts>.csv  (phase 1)
Tab-separated. One row per local file.

| Column | Type | Note |
|---|---|---|
| RelPath | string | relative to source_root |
| MD5 | hex(32) | or `ERROR` on read failure |
| SizeBytes | integer | |

## structure_report_<ts>.txt  (phase 5)
Plain text. Sections: files in the phase-0 ground truth that are missing on the target, plus a summary line (present/missing/extra). "Missing" is expected to be dominated by non-synced junk (Thumbs.db, `~$` temp files, desktop.ini, `.tmp`).

## *_done.json  (completion markers, all phases)
Written last, atomically. Since v0.3.0 every completion marker carries a common header (`schema: csm.artifact/1`) so downstream gates can judge success and identity, not just presence:

| Field | Type | Note |
|---|---|---|
| schema | string | `csm.artifact/1` |
| phase | string | `inventory` \| `baseline` \| `preflight` \| `structure` \| `verify` \| `diagnose` \| `probe` \| `retire-source` |
| provider | string | provider.name at run time |
| mode | string | `streaming` \| `mirror` \| `n/a` (Google Drive mode; #6) |
| source_root / target_root | string | roots this artifact refers to (identity check for the retire gate) |
| physical_source_root / physical_target_root | string | resolved physical root, so junction- vs physical-path phases compare like with like (#13) |
| finishedUtc | ISO-8601 | UTC completion time |
| success | bool | phase-specific green/complete verdict (#7) — false on enumeration/hash/read errors or unmet criteria |
| errors | integer | error count |
| errorCategories | string[] | e.g. `enumeration`, `hash-read`, `missing-files`, `md5-mismatch`, `read-error`, `robocopy` |

Phase-specific counters follow the header (e.g. inventory: `files`, `online_only`, and since v0.4.0 `root_is_junction`, `reparse_skipped`, `noise_skipped`, `access_errors`, `skipped[]`; structure: `missing_real`, `target_reparse_skipped`, `target_access_errors`; verify: `md5_match`, `md5_mismatch`; preflight keeps the legacy `PASS` plus a `reparse` summary, since v0.5.0 `mirror_content`, `staging`/`staging_note`, and `diagnose_health`/`diagnose_age_min`/`diagnose_note`, and since #17 `stage_queue_gate` `{gate, state, roots_blocked, roots_warning}` + `mount_stage_queues[]` (redacted, see the diagnose section) + on override `stage_queue_forced`/`stage_queue_force_reason` or `stage_queue_assumed_clean`). The retire-source gate requires the latest `preflight`, `structure`, and `verify` markers to be present, `success:true`, mutually consistent in identity, recent, and stable (see PLAYBOOK / USER_GUIDE).

## diagnose_<ts>_done.json  (phase diagnose, #5 — v0.5.0)
Common header (`success` = `health == 'healthy'`) plus a redacted verdict — counts + health only, no account ids / local paths / filenames:

| Field | Type | Note |
|---|---|---|
| health | string | `healthy` \| `initializing` \| `warning` \| `blocked` \| `unknown` (fail-closed: "no danger marker" is `unknown`, never `healthy`) |
| summary | object | provider-specific redacted counts — Google Drive: `liveness`, `wal_max_mb`, `wal_large`, `stale_markers`, and since #16 `stage_queues_blocked` / `stage_queues_warning` / `mount_stage_queues[]`; OneDrive: `accounts`, `conflicts` |

`mount_stage_queues[]` (#16) — one entry per configured mirror root (ordinal 0 = `source_root`, 1..N = `extra_mirror_roots` in config order; **no paths anywhere**):

| Field | Type | Note |
|---|---|---|
| root_ordinal | integer | position in the configured root list — the redaction-safe identity |
| root_present / present | bool | root exists / staging dir exists at its top level |
| size_bytes / file_count / subdir_count | numbers | single-level enumeration of the staging dir (never recursed, content never read) |
| oldest_utc / newest_utc | ISO-8601 | LastWrite range of the queue's files (carried-over decades-old files are the field signature) |
| delete_probe | string | fresh-file create+delete probe: `ok` \| `denied` \| `missing` \| `error:<cause>` |
| existing_delete_probe | string | non-destructive DELETE-access open on up to 3 oldest files: `ok` \| `denied` \| `locked` \| `unavailable` \| `error:<n>` \| `n/a` |
| class | string | `none` \| `info` \| `warning` \| `blocked` (non-empty + a denied probe) |

Since #18, when `[diagnose_delivery] provider_upload_enabled = true`, the artifact additionally records the delivery outcome (appended after the upload attempt — the uploaded copy is the artifact as first written, without these fields):

| Field | Type | Note |
|---|---|---|
| delivered_via_api | bool | true only on a confirmed provider-API upload |
| delivered_via_api_url | string \| null | redaction-safe URL (file-id based), never a local path |
| delivered_via_api_error | string \| null | classified soft-failure — config reason (`missing-folder-id`, `missing-credentials-env`, `credentials-unresolvable`, `provider-not-implemented`) or transport class (`http-401-unauthorized`, `http-403-forbidden`, `http-404-not-found`, `http-NNN`, `network`, `error:<type>`) |

## diagnose_<ts>_delivery.json  (#18 — optional local receipt)
`schema: csm.delivery-receipt/1` — `artifact` (leaf name), `provider`, `delivered_via_api`, `delivered_via_api_url`, `delivered_via_api_error`, `finishedUtc`. Written when `[diagnose_delivery] write_receipt = true`.

## probe_<ts>_done.json  (phase probe, #9 — v0.5.0)
Round-trip proof. `mode` is `dry-run` or `execute`.

| Field | Type | Note |
|---|---|---|
| mode | string | `dry-run` (nothing written) \| `execute` (one canary written + cleaned up) |
| config_ok | bool | probe_dir writable + confirm_command set |
| outcome | string | (execute) `confirmed` \| `timeout` \| `unknown` |
| confirm_exit | integer | (execute) last exit code from the operator's confirm_command |
| elapsed_seconds / canary_removed | int / bool | (execute) round-trip time; whether the single canary was cleaned up |

The canary is a single file `.csm_roundtrip_<token>.txt` whose only content is a random, non-identifying token.

## retire_<ts>_manifest.json  (phase retire-source, #3 — v0.5.0)
`schema: csm.retire-manifest/1`. Records the resumable `/MOVE`: `source`, `backup`, `robocopy_exit`, `robocopy_bits`, `backup_files`, `backup_bytes`, `leftover_count`, `leftover_in_source[]` (files robocopy could not copy, left in place), `verified` (exit<8 AND zero leftovers), `log`.

## state_report.json  (diagnostics)
`{ accounts: [ { name, files, conflicts, fileStatus_dist, throttle_events, recent_error_codes } ] }` — from the sync engine's SQLite state (read-only snapshot).
