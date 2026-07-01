# USER_GUIDE — köra en flytt steg för steg

> **Varning:** riskfyllda filoperationer - använd på egen risk, ha verifierad backup, kör dry-run först. Se `DISCLAIMER.md`.

> Läs `01_docs/PLAYBOOK.md` först. Detta är den operativa checklistan. Varje destruktivt steg kräver `-Execute`; utan den flaggan är allt dry-run.

## Förberedelse
1. Kopiera `config.example` → `config.local`. Fyll i:
   - `source_root` = nuvarande synkmapp (t.ex. `C:\Users\<user>\OneDrive`)
   - `target_root` = ny plats (snabb, rymlig, **ej SMR**-disk)
   - `work_dir` = lokal arbetsmapp för artefakter (INTE i synkmappen)
   - `provider.name` = `onedrive-personal` | `onedrive-business` | `google-drive`
2. Se till att klienten visar **"Uppdaterad"/"Up to date"** (inga väntande ändringar).

## Kör faserna

Orkestrerare (visar plan, kör läs-faser, stannar före destruktiva steg):
```
powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local
```

Eller fas för fas:

1. **Fas 0 — inventering (ofarlig):**
   `powershell -File 03_src\ps\Invoke-Inventory.ps1 -Config .\config.local`
   Kontrollera `inventory_<ts>.csv` + drift-varningar.

2. **Fas 1 — MD5-baslinje (ofarlig, kan ta tid):**
   `powershell -File 03_src\ps\Invoke-Md5Baseline.ps1 -Config .\config.local`
   Startas som background job för stora set.

3. **Fas 2 — preflight (ofarlig):**
   `powershell -File 03_src\ps\Test-MovePreflight.ps1 -Config .\config.local`
   Alla grindar måste vara gröna (fri plats, skrivbarhet, up-to-date, disktyp).

4. **Flytten (manuell, Metod A):** följ `PROVIDER-NOTES.md` för din klient — avlänka, länka om, Välj plats → `target_root`. Verktyget flyttar INTE åt dig (klienten måste äga flytten).

5. **Fas 5 — strukturverifiering:**
   `powershell -File 03_src\ps\Compare-MoveStructure.ps1 -Config .\config.local`
   "missing" ska domineras av skräp (Thumbs.db/`~$`/desktop.ini/`.tmp`), verkliga saknade ~0.

6. **Fas 6 — hydrerings-medveten efterverify:**
   `powershell -File 03_src\ps\Invoke-HydrationVerify.ps1 -Config .\config.local`
   Kör om tills stickprov = 0 online-only, sedan full MD5-jämförelse. Kan schemaläggas var 2h.

7. **Diagnos vid felräknare (OneDrive):**
   `powershell -File 03_src\ps\Read-OneDriveSyncState.ps1 -Config .\config.local`
   Skiljer throttling från riktiga fel (se PLAYBOOK 7).

8. **Fas 8/9 — grinda bort källan (destruktivt, tidsgrindat):**
   Först efter `min_stable_days` dygn stabil synk:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local -Phase retire-source -Execute`
   Flyttar (inte raderar) gamla källan till backup, tömmer sedan. Radera backupen långt senare.

## Nödstopp (A7)
```
powershell -File 03_src\ps\stop_all_jobs.ps1     # pausar/stoppar synkklient + toolkit-jobb
powershell -File 03_src\ps\start_all_jobs.ps1    # återstartar kontrollerat
```

## Om något ser fel ut
- Tom måldestination men "verify" grönt → FoD-platshållare (PLAYBOOK felmek. 2). Kör hydrerings-medveten verify.
- MD5-fel i mängd → troligen hydrering pågår (felmek. 3), vänta.
- Klienten visar hundratals "synkfel" → kör state-diagnosen; nästan alltid throttling (PLAYBOOK 7).

## 7b. Loggdiagnos (djupare)

- **OneDrive ODL-loggar (throttling-detaljer):**
  `powershell -File 03_src\ps\Read-OneDriveLogs.ps1 -Config .\config.local`
  Räknar 429/403/throttle-termer + `Download`/`ActiveHydration`-scenarier ur `.aodl`/`.odlgz`.
- **Google Drive inode-/raderingsvarning (kör FÖRE/under en Drive-flytt):**
  `powershell -File 03_src\ps\Read-GoogleDriveLogs.ps1`
  Hittar `MIRROR_GDOC_DELETED` / `changed inode` i `drive_fs.txt`. Växer `MIRROR_GDOC_DELETED` → stoppa Drive omedelbart (`stop_all_jobs.ps1`) och följ återställningsnoterna.
