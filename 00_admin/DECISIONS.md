# DECISIONS (ADR-logg)

Kort ADR per beslut. Format: kontext → beslut → konsekvens.

## ADR-000 — Bantad projektstruktur (avsteg från full B9)
**Kontext:** B9 säger att standardstrukturen ska anpassas efter projekttyp; detta är ett verktygslåde-/kunskapsprojekt, inte en datapipeline.
**Beslut:** behåll `00_admin`, `01_docs`, `03_src` (ps+py), `04_tests/validation`, `_sources`. Utelämna `02_data/` och `04_tests/fixtures`; CSV-scheman ligger i `01_docs/DATA-FORMATS.md`. Verktygens utdata skrivs till en extern `work_dir`, inte i repo.
**Konsekvens:** slankare repo utan tomma mappar. Avsteget dokumenterat här enligt B9.

## ADR-001 — Metod A (klientens flytt), aldrig junction
**Kontext:** en synkmotor spårar mappidentitet via NTFS file-id; en junction/robocopy-flyttad rot kan tolkas som "innehållet raderat" → molnradering (bevisat i Google Drive-flytten).
**Beslut:** flytta alltid via klientens egen "byt plats"-funktion; junction endast som kompatibilitetslager efteråt.
**Konsekvens:** ingen inode-fälla; enda stödda vägen för OneDrive.

## ADR-002 — Files-On-Demand bevaras
**Kontext:** källdisken kan sakna plats för full lokal spegling; masshydrering är dyr och riskabel.
**Beslut:** materialisera aldrig platshållare för att "lösa" flytten; utöka aldrig mängden lokalt speglade filer; verifiering är status-medveten.
**Konsekvens:** flytten fungerar även när molnet är mycket större än måldisken.

## ADR-003 — Dry-run default + tidsgrindad radering
**Kontext:** riskhöjd irreversibel operation (B12.2, A3).
**Beslut:** alla destruktiva steg kräver `-Execute`; källan behålls `min_stable_days` dygn och flyttas (inte raderas) till backup före tömning.
**Konsekvens:** rollback-baslinje bevaras tills synken bevisats stabil.

## ADR-004 — Svenska docs, engelsk kod
**Kontext:** B9 kräver engelska identifierare; ekosystemets dokumentation är svensk.
**Beslut:** prosa/docs på svenska (native UTF-8), all kod/identifierare/schema på engelska, `.ps1` ASCII-only.
**Konsekvens:** publicerbart utan efter-översättning; inga encoding-fällor i kod.

## ADR-005 — `_sources/` osrubbat men aldrig publicerat
**Kontext:** originalunderlagen bär sökvägar/IDs; den publika ytan måste vara PII-fri.
**Beslut:** `_sources/` är `.gitignore`:ad; destilleringen i `01_docs/` är den publicerbara ytan.
**Konsekvens:** kunskapen bevaras lokalt, PII läcker aldrig till repo.

## ADR-006 — Git med separat git-dir utanför synkytan
**Kontext:** `.git` i en synkad molnmapp kolliderar med synkklientens skanning → korrupt objektdatabas (bevisat i ett tidigare projekt).
**Beslut:** initiera Git med separat git-dir utanför synkytan, `gc.auto 0`, first commit med namngivna filer (aldrig `git add .`).
**Konsekvens:** arbetskopian synkas, Git-objekten inte; ingen historikförlust. Se `Initialize-Repo.ps1`.