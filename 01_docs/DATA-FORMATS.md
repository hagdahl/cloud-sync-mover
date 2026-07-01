# DATA-FORMATS — verktygens filscheman

Alla utdata är UTF-8, tab-separerade (TSV med `.csv`-namn) eller JSON. Skrivs till `work_dir`.

## inventory_<ts>.csv  (fas 0)
Tab-separerad. En rad per fil i källan.

| Kolumn | Typ | Exempel | Not |
|---|---|---|---|
| RelPath | sträng | `Docs\a.txt` | relativ mot source_root |
| SizeBytes | heltal | `1024` | 0 för online-only platshållare |
| LastWriteUtc | ISO-8601 | `2026-07-01T14:00:00` | UTC |
| AttrHex | hex | `0x420` | råa filattribut |
| Status | enum | `online-only` \| `local-available` \| `always-keep` | attribut-klassning |

## pinlist_<ts>.txt  (fas 0)
En relativ sökväg per rad — alla filer som INTE är online-only (dvs finns lokalt).

## md5_<ts>.csv  (fas 1)
Tab-separerad. En rad per lokal fil.

| Kolumn | Typ | Not |
|---|---|---|
| RelPath | sträng | relativ mot source_root |
| MD5 | hex(32) | eller `ERROR` vid läsfel |
| SizeBytes | heltal | |

## structure_report_<ts>.txt  (fas 5)
Klartext. Sektioner: filer i fas-0-facit som saknas på målet, plus en sammanfattningsrad (present/missing/extra). "Missing" förväntas domineras av icke-synkat skräp (Thumbs.db, `~$`-temp, desktop.ini, `.tmp`).

## *_done.json  (klar-markörer, alla faser)
`{ finishedUtc, <fas-specifika räknare> }` — skrivs sist, atomiskt. Närvaro = fasen är klar och verifierad.

## state_report.json  (diagnos)
`{ accounts: [ { name, files, conflicts, fileStatus_dist, throttle_events, recent_error_codes } ] }` — från synkmotorns SQLite-tillstånd (read-only snapshot).