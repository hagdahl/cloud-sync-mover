# ARCHITECTURE

## Designmål
Bevisbart säker flytt av en molnsynkad datamapp mellan diskar, med minsta möjliga risk och full spårbarhet. Verktygen är fristående PowerShell/Python-script som körs i faser; ingen daemon, inget molnberoende utöver providerns kvot-/metadata-endpoint.

## Dataflöde

```
config.local ──► Invoke-CloudSyncMove.ps1 (orkestrerare, dry-run default)
                   │
   fas 0  ─────────┼─► Invoke-Inventory.ps1      ─► inventory_<ts>.csv (+ pinlist)   [ren läsning]
   fas 1  ─────────┼─► Invoke-Md5Baseline.ps1    ─► md5_<ts>.csv                     [.NET MD5]
   fas 2  ─────────┼─► Test-MovePreflight.ps1    ─► preflight_<ts>.json              [grindar]
   (klientens flytt utförs manuellt/guidat — Metod A)
   fas 5  ─────────┼─► Compare-MoveStructure.ps1 ─► structure_report_<ts>.txt
   fas 6  ─────────┼─► Invoke-HydrationVerify.ps1 ─► verify_<ts>.json                [hydrerings-medveten]
   diagnos ────────┴─► Read-OneDriveSyncState.ps1 ─► read_sync_state.py ─► state_report.json
```

Alla artefakter skrivs till `work_dir` (lokal, snabb disk — **inte** den synkade mappen).

## Faskarta ↔ script

| Fas | Script | Skriver | Läser innehåll? |
|---|---|---|---|
| 0 inventering | `Invoke-Inventory.ps1` | inventory-CSV + pinlist | Nej (endast attribut) |
| 1 baslinje | `Invoke-Md5Baseline.ps1` | md5-CSV | Ja (endast lokala filer) |
| 2 preflight | `Test-MovePreflight.ps1` | preflight-JSON | Nej |
| 5 struktur | `Compare-MoveStructure.ps1` | strukturrapport | Nej |
| 6 efterverify | `Invoke-HydrationVerify.ps1` | verify-JSON | Ja (efter hydrering) |
| diagnos | `Read-OneDriveSyncState.ps1` + `read_sync_state.py` | state-JSON | Nej (SQLite-snapshot) |
| nödstopp | `stop_all_jobs.ps1` / `start_all_jobs.ps1` | — | — |

## Säkerhetsmodell
- **Dry-run default** (A1): destruktiva steg kräver `-Execute`.
- **Radering tidsgrindad** (A3): källan behålls `min_stable_days` dygn.
- **Ren läsning i fas 0** (B11 dataminimering): inventeringen rör aldrig filinnehåll.
- **Ingen molndelning** (A2): endast providerns egen kvot-/metadata-endpoint anropas; inget filinnehåll skickas.
- **Idempotens** (A6): varje script kan köras om; atomic write (temp + `Move-Item -Force`); klar-markörer (`*_done.json`).

## Exekverings- vs målmiljö (B14)
Långkörande filoperationer startas frånkopplat (background job / separat session) så att en kommandobrygga-timeout inte avbryter mitt i. Läs/skriv mot en synkad yta sker via host-processer (PowerShell), inte via en sandbox som inte når synkklientens skriv-API.

## Encoding-disciplin (B8)
- `.ps1` — **ASCII-only** (PowerShell 5.1 läser UTF-8-utan-BOM som CP1252). Verifiera med `Select-String '[^\x00-\x7F]'`.
- `.py` — UTF-8 utan BOM; `sys.stdout.reconfigure(encoding="utf-8")` överst.
- `.md` — UTF-8 utan BOM, native å/ä/ö.
- Config läses som INI (ingen BOM-känslig parser).