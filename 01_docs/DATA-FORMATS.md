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
`{ finishedUtc, <phase-specific counters> }` — written last, atomically. Presence = the phase is complete and verified.

## state_report.json  (diagnostics)
`{ accounts: [ { name, files, conflicts, fileStatus_dist, throttle_events, recent_error_codes } ] }` — from the sync engine's SQLite state (read-only snapshot).
