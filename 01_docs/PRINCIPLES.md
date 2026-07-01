# PRINCIPLES - konventionerna projektet följer (självbärande sammanfattning)

Detta projekt följer konventionerna i standarden `cowork-projektinstruktioner`. För att repot ska vara **självbärande** - fungera utan tillgång till den standarden - sammanfattas de koder som citeras i projektet här i klartext. Koderna är bara referens-etiketter; principerna nedan är det som gäller.

| Kod | Princip (kort) |
|---|---|
| A1 | Människa-i-loopen: dry-run som default, uttryckligt godkännande före destruktiva/irreversibla steg. |
| A2 | Hemligheter och personuppgifter hålls utanför versionshanterat innehåll; `.gitignore` från start; den publika ytan är PII-fri. |
| A3 | Versionshantering + rollback: Git från start, CHANGELOG med rollback, källan är baslinje tills den bevisats umbärlig. |
| A4 | Självverifiering: inget rapporteras klart utan att ha verifierats (kör, räkna, jämför, testa). |
| A5 | Definition of Done: explicit klar-kriterium per uppgift. |
| A6 | Idempotens: script kan köras om utan dubbletter/korrupt state; atomic write (temp + rename). |
| A7 | Least privilege + nödstopp: minsta behörighet, all automation kan stoppas i ett svep. |
| B3 | Self-bearing handover. |
| B8 | Felhantering/loggning + encoding-disciplin (ASCII `.ps1`, UTF-8 utan BOM för `.py`/`.md`). |
| B9 | Fast projektstruktur och namnkonvention, anpassad efter projekttyp. |
| B11 | Beräkningsval/dataminimering: enklaste lokala verktyg först; ingen onödig molndelning. |
| B12.2 | Riskhöjda lokala scriptjobb (radering/flytt/behörighet) kräver dry-run + loggning + godkännande. |
| B13 | Centraliserad konfiguration (`config.example` -> `config.local`, tydlig override-ordning). |
| B14 | Exekveringsmiljö kontra målmiljö: kör där operationen hör hemma; frikoppla långjobb. |

**Om `cowork-configurations`:** den filen är standardens miljöspecifika, lokal-only instans (absoluta sökvägar, versioner, identifierande data). Den publiceras **aldrig**, och detta projekt refererar den inte och behöver den inte. Allt en mottagare behöver finns i detta repo.