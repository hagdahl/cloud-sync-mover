# PLAYBOOK — flytta en molnsynkad datamapp mellan diskar

Generaliserad, PII-fri destillering av två skarpa flyttar (Google Drive, OneDrive Personal). Kod och identifierare på engelska; principer på svenska. Referens till tjänstespecifika detaljer: `PROVIDER-NOTES.md`.

## 0. Grundprinciper (icke förhandlingsbara)

1. **Molnet är facit och rörs aldrig.** Ingen massradering, ingen "Ladda ner alla filer", ingen strukturändring i molnet under flytten.
2. **Använd klientens egen flyttfunktion — aldrig junction/symlink.** En synkmotor spårar mappidentitet via NTFS file-id; en junction eller robocopy-flyttad rot kan tolkas som "innehållet raderat" → molnet trashas. Klientens "Byt plats"/"Välj plats" flyttar datamappen och behåller synk-identiteten.
3. **Bevara Files-On-Demand (FoD).** Materialisera inte platshållare för att "lösa" flytten. Utöka aldrig mängden lokalt speglade filer. Verifiering ska vara status-medveten.
4. **Källan är rollback-baslinjen tills den bevisats umbärlig.** Radering/flytt av källan tidsgrindas (A3) och kräver uttryckligt godkännande (A1).
5. **Dry-run är default.** Varje destruktivt steg är opt-in (`-Execute`).

## 1. Beslutsträd — vilken metod?

```
Stödjer klienten en inbyggd "byt plats för datamappen"?
├── JA  -> Använd den (Metod A). Detta är enda stödda vägen för OneDrive,
│         och motsvarande "byt mapp"-inställning finns i Google Drive.
└── NEJ -> Eskalera. Flytta INTE via junction/symlink/robocopy av en aktiv
          synkrot. Överväg att pausa tjänsten, flytta, och konfigurera om
          via klientens inställningar — aldrig på filsystemnivå bakom klientens rygg.
```

Junction som *kompatibilitetslager för gamla sökvägar* (så att script som pekar på den gamla platsen fortsätter fungera) är OK — men skapas EFTER att klienten flyttat datamappen och den gamla mappen tömts, aldrig som själva flyttmekanismen.

## 2. Riskklassning

Detta är en **riskhöjd, irreversibel filoperation** (B12.2): stora datamängder, extern tjänst, potentiell dataförlust. Full DEL A gäller. Kräver: dry-run, tydlig loggning, uttryckligt godkännande före varje destruktivt steg, och en dokumenterad rollback-väg.

## 3. Fasmodellen

Mönstret: **inventera (läs) → baslinje → preflight → flytta (klienten) → verifiera struktur → verifiera innehåll (hydrerings-medvetet) → moln-facit → grinda radering av källan.** Långkörande steg startas frånkopplat (background job) så att en kommandobrygga-timeout inte avbryter mitt i.

### Fas 0 — Inventering (ren läsning)
Enumerera hela källan med `[System.IO.Directory]::EnumerateFiles(...)` och klassa varje fil **enbart på attribut** — läs aldrig innehåll:

| Status | Attribut | Betyder |
|---|---|---|
| online-only | `RECALL` = 0x400000 satt | 0-byte platshållare, bara i molnet |
| always-keep | `PINNED` = 0x80000 satt | pinnad "behåll alltid på enheten" |
| local-available | ingetdera | materialiserad men inte pinnad |

Skriv CSV (RelPath, SizeBytes, LastWriteUtc, AttrHex, Status) + en pinlist (alla icke-online-only). **Drift-check (bilaga):** för varje schemalagt jobb som *ska* skriva regelbundet, jämför jobbets `LastRunTime` mot dess datafilers `LastWriteTime`. Gap > ett par dagar = pre-existerande tyst fel som ska åtgärdas FÖRE flytten, annars blandas felklasser i efterverifieringen.

### Fas 1 — MD5-baslinje av lokala filer
Beräkna MD5 för **enbart** local-available + always-keep (de som faktiskt finns lokalt). Använd `[System.Security.Cryptography.MD5]` (.NET) — INTE `Get-FileHash` (se felmekanism 4). Skriv CSV (RelPath, MD5, Size). Detta är facit för efterverifieringen.

### Fas 2 — Preflight
Grinda på: (a) synken är "Uppdaterad"/"Up to date" (inga väntande ändringar), (b) fri plats på målet räcker för de lokala filerna (inte hela molnet — FoD bevaras), (c) skrivbarhets-probe på målet (skriv+radera testfil, A4), (d) disktyp på målet (varna för SMR — se felmekanism 6), (e) säkra en moln-baslinje via providerns API (driveId + använd kvot som facit). Bind aldrig till en enhetsbokstav som kan driva.

### Fas 3 — Avlänka
Avlänka kontot i klienten (molnet orört, lokala filer ligger kvar). Granska eventuella egna script för destruktiva ops mot den gamla sökvägen innan omkonfiguration.

### Fas 4 — Länka om + Välj plats
Länka om kontot och peka datamappen på målet. **Alla filer är initialt platshållare** — gör INGEN MD5 här (status-medveten: det finns inget innehåll att hasha ännu). Låt klienten bygga upp trädet.

### Fas 5 — Strukturverifiering
Bygg ett `HashSet` av målets relativa sökvägar och diffa mot fas-0-facit. Förvänta att "missing" domineras av icke-synkade skräpfiler (Thumbs.db, `~$`-Office-temp, desktop.ini, `.tmp`) — klassa och räkna dem, verkliga saknade filer ska vara ~0.

### Fas 6 — Hydrerings-medveten efterverifiering
Återpinna always-keep (`attrib +P`, se felmekanism 5), vänta in hydreringen, kör sedan full MD5-verify mot fas-1-baslinjen. **Kör inte verifieringen medan filer hydreras** — ett stickprov måste visa 0 online-only först, annars blir det falska fel (felmekanism 3). Schemalägg gärna en åter-kontroll var/varannan timme tills hydreringen lugnat sig.

### Fas 6b — Kända mappar (om tillämpligt)
Om skrivbord/dokument/bilder är omdirigerade in i synkmappen (Known Folder Move): peka om dem till den nya platsen via `SHSetKnownFolderPath` (shell32) och verifiera med `GetFolderPath`.

### Fas 7 — Övervakad drift
Kör tjänsten övervakat. Utred eventuell felräknare (se avsnitt 7 — oftast throttling, inte dataproblem).

### Fas 8/9 — Tidsgrindad radering/flytt av källan
Först efter N dygns stabil synk (config `min_stable_days`) + uttryckligt `-Execute`: **flytta** (inte radera) den gamla datamappen och cachen till en backup-plats, töm sedan. Skapa ev. kompatibilitets-junction för gamla sökvägar. Radera backupen långt senare.

## 4. Felmekanismer och fällor

1. **Sync-motor + junction = inode-/identitetsfälla.** Aldrig junction som flyttmetod för en aktiv synkmapp.
2. **FoD-platshållarfälla.** Online-only-filer är 0-byte; en naiv kopiering/jämförelse ger falskt grönt "verify" och naiv kopiering kan trigga masshydrering som spränger måldisken. Flyttmetoden får inte materialisera platshållare; verifiering ska vara status-medveten.
3. **Hydrerings-race vid MD5.** Verifiera först när ett stickprov visar 0 online-only.
4. **`Get-FileHash` saknas i spawnad process.** `Start-Process powershell.exe` (5.1) autoladdar inte moduler → `Get-FileHash` "not recognized". Använd `[System.Security.Cryptography.MD5]` (.NET).
5. **`SetAttributes` kan inte sätta klientens PINNED-bit.** `.NET File.SetAttributes` misslyckas för moln-PINNED (0x80000). Använd `& attrib.exe +P <fil>` för att pinna (starta hydrering).
6. **SMR-disk churnar under synk.** SMR-arkivdiskar (vissa stora billiga SATA-modeller) är usla på många små slumpvisa skrivningar. En aktivt synkad mapp på SMR ger 100 % diskaktivitet och GUI-lagg. Undvik SMR som mål för en aktiv synkmapp; sänk annars nedladdningshastigheten och styr synk till idle-tid.
7. **Live WAL-databaser får aldrig öppnas read-write.** Se avsnitt 7.

## 5. Verifieringsmetoder (bevisa noll dataförlust)

- **Attribut-klassning** (fas 0) — ren läsning, ingen innehållsåtkomst.
- **MD5 före/efter** på lokala filer — fånga mismatch. Enhetsberoende genvägar (t.ex. Personal Vault-`.lnk`) regenereras per maskin → förväntad "mismatch", vitlista.
- **Strukturdiff** — relativ-sökväg-set källa mot mål.
- **Moln-facit via providerns API** — jämför kvot/objekt-ID före/efter; diff = 0 bevisar att molnet är orört.

## 6. Rollback-fönster (A3)

Källan är en **full rollback-baslinje** så länge destinationen bara tar emot en passiv kopia. I samma sekund som destinationen tar över produktion (klienten synkar aktivt, nya skrivningar sker mot målet) divergerar källa och mål. Rollback till källan förlorar då nya skrivningar. Därför: håll källan tills synken bevisats stabil i flera dygn, och grinda dess radering på tid + godkännande. Vid behov: databack-steg (kopiera nyaste data från målet tillbaka) eller dokumenterad accept av dataloss i en ADR.

## 7. Synkfel-diagnos — throttling vs riktiga fel

En hög felräknare i klienten under/efter en flytt är oftast **transient throttling** från masshydrering, inte dataproblem. Verifiera mot motorns TILLSTÅND, inte mot UI:t:

- **Tillståndskälla (bäst):** klientens SQLite-databaser i `settings\<konto>\`. Läs `SyncEngineDatabase.db` (per-fil-status, operationshistorik) och motsvarande "sync issues"-DB. **Läs aldrig live read-write** (WAL-läge, öppen av klienten): ta snapshot-kopia (db + `-wal` + `-shm`) och läs kopian, eller öppna live med `immutable=1&mode=ro`.
- **Rent tillstånd ser ut så här:** 0 konflikter, per-fil-status endast "synkad"-värden, 0 mappfel, 0 "unrealized". Då finns inga hårda fel.
- **Throttling ser ut så här:** operationshistorikens `resultCode` innehåller 429 (Too Many Requests) / 403 (Forbidden) på `Download`/`ActiveHydration`-scenarier, + en throttle-historik-tabell med `ThrottledRequest_*`-rader, daterade till hydreringslasten. Slutsats: räknaren faller mot noll när hydreringen är klar. Åtgärd: vänta, ev. sänk nedladdningshastigheten.
- **Loggar:** nyare klientloggar kan vara klartext (t.ex. OneDrives `.aodl`, magic `EBFGONED`); providerns moln-API exponerar normalt inga per-klient-synkloggar.

Detaljerad, återanvändbar diagnostik: `03_src/py/read_sync_state.py` + `03_src/ps/Read-OneDriveSyncState.ps1`.

## 8. Anti-mönster (gör inte)

- Flytta via junction/symlink/robocopy av en aktiv synkrot.
- "Ladda ner alla filer" för att göra flytten "säkrare" (spränger disk, ändrar inget i molnet men river FoD).
- MD5-verifiera medan hydrering pågår.
- Radera källan direkt efter flytt (behåll som baslinje i N dygn).
- Öppna klientens live-databaser read-write.
- Lägg en aktiv synkmapp på en SMR-disk.