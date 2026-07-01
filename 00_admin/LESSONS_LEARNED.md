# LESSONS_LEARNED

Append-only. Nyast överst. Destillerat och avidentifierat ur två skarpa flyttar (Google Drive-spegel, OneDrive Personal). Osrubbade original i `_sources/`.

## 2026-07 — OneDrive Personal C: -> E: (Metod A)

- **Synkfelräknaren ljuger under masshydrering.** "Över 740 synkfel" visade sig vara transient throttling (HTTP 429/403 på hydrering), inte dataproblem. Synkmotorns tillstånd var rent (0 konflikter, 0 fel-status). *Lärdom:* verifiera mot motorns SQLite-tillstånd, aldrig mot UI-räknaren. (A4)
- **Läs klientens state-DB read-only.** DB:erna är WAL och öppna av klienten. Snapshot-kopia (db+wal+shm) och läs kopian, eller `immutable=1&mode=ro`. Aldrig live read-write. (A7)
- **`Get-FileHash` finns inte i en spawnad `powershell.exe` 5.1** (ingen modul-autoload). Bekräftar B14. Använd `[System.Security.Cryptography.MD5]`. 
- **`.NET SetAttributes` kan inte sätta molnets PINNED-bit.** Använd `attrib +P`.
- **MD5-verify racar hydrering.** Verifiera först när stickprov = 0 online-only.
- **Strukturdiffens "missing" är nästan bara skräp** (Thumbs.db, `~$`-temp, desktop.ini, `.tmp`) — klassa dem, förväxla inte med dataförlust.
- **Moln-facit via provider-API (kvot-diff = 0) är det starkaste beviset** att flytten inte rörde molnet.

## 2026-06 — Google Drive-spegel C: -> E: (inode-fällan)

- **Junction + synkmotor = katastrof.** Klienten tolkade den junction-flyttade roten som "innehållet raderat" och trashade ~1900 objekt i molnet, plattade sedan ut strukturen. *Lärdom:* flytta ALDRIG en aktiv synkmapp via junction/robocopy; använd klientens egen "byt plats". (kärnprincip)
- **Håll klienten helt avstängd tills moln och lokalt är konsekventa.** Klienten re-trashar i loop annars.
- **Återställ molnet parent-first.** Återställer man ett barn vars förälder ligger kvar i papperskorgen hamnar det föräldralöst i roten.
- **Ta en pristine-backup till en oövervakad plats och rör den aldrig** — den är facit vid återställning.
- **SMR-disk är fel disk för aktiv synk.** En synkad mapp på en SMR-arkivdisk gav 100 % diskaktivitet och GUI-lagg. Lägg aktiv synk på SSD/CMR; håll SMR för sekventiella arkiv.
- **Klientens lokala loggar är guld** (`drive_fs.txt`): visar inode-ändring och raderingar.

## Tvärgående principer
- Molnet är facit — rör det aldrig under en flytt.
- Bevara FoD — materialisera aldrig allt.
- Källan är rollback-baslinjen tills synken bevisats stabil i flera dygn.
- Långkörande filoperationer startas frånkopplat så en brygg-timeout inte avbryter mitt i.

### Operativa/diagnostik-mönster (2026-07, destillerade)

- **Frikopplade långjobb + marker-filer, inte strömmad utdata.** Stora enumereringar/hashningar över en synkad yta timar ut i en interaktiv brygga och buffras blockvis när utdata går till fil. Mönster (som toolkit-scripten använder): kör frikopplat, skriv `*_progress.txt` löpande och `*_done.json` sist (atomiskt), och polla marker-filen i stället för att vänta på strömmad output.
- **Riktad sökning, inte rekursiv enum av hela roten.** En full `EnumerateFiles` över den synkade roten kan vara enorm (miljontals online-only-platshållare) och timeout:a när man bara letar efter en fil eller ett konto. Sök riktat mot kända undermappar.
- **Fri diskyta som framstegs-/tröskelmått.** Under långsam disk (SMR) är antal-räkning trögt; delta i målets upptagna utrymme är ett robust, billigt framstegs- och tröskelmått (grunden för `Watch-TargetGrowth.ps1`).
- **State-DB-snapshot är stor - städa.** En snapshot kan vara flera GB (DB + stor WAL). Skriv till lokal disk och radera efteråt, annars äter diagnosen upp den disk du försöker frigöra.
