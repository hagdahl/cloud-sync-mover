# HANDOVER — cloud-sync-mover

Self-bearing handover (B3). Ska räcka för att en ny person eller agent ska förstå och driva projektet utan extern kontext.

## Vad projektet är
Principer, logik och en körbar verktygslåda för att flytta den lokala datamappen för en molnsynkad tjänst (OneDrive, Google Drive) mellan diskar på Windows — säkert, FoD-bevarande, med bevisbar verifiering. Destillerat ur två skarpa flyttar (Google Drive, OneDrive Personal), avidentifierat och publicerbart.

## Status
- Playbook + docs: klara (`01_docs/`).
- Verktygslåda: `03_src/ps/` (PowerShell, ASCII, dry-run default) + `03_src/py/read_sync_state.py`.
- Osrubbade underlag: `_sources/` (gitignored, publiceras aldrig).
- Struktur bantad från full B9 (se DECISIONS ADR-000).

## Hur man fortsätter / använder
1. Läs `README.md` → `01_docs/PLAYBOOK.md` → `01_docs/USER_GUIDE.md`.
2. Kopiera `config.example` → `config.local`, fyll i sökvägar.
3. Kör faserna (inventering → baslinje → preflight → klientens flytt → strukturverify → hydrerings-verify → tidsgrindad radering).

## Nyckelprinciper (varför det ser ut som det gör)
- Klientens egen flytt, **aldrig junction** (inode-fällan).
- FoD bevaras, materialisera aldrig allt.
- Dry-run default; radering av källan tidsgrindad + `-Execute`.
- Molnet är facit och rörs aldrig.
- Synkfelräknare = oftast throttling, inte dataproblem — verifiera mot synkmotorns tillstånd.

## Var kunskapen kommer ifrån
`_sources/` innehåller de två lessons-learned-filerna, OneDrive-flyttens handover, 740-synkfel-rapporten och verifieringsprompten. Dessa är osrubbade original; den publicerbara destilleringen är `01_docs/PLAYBOOK.md`.

## Kvarstående / möjliga tillägg
- Fler providers (Dropbox, iCloud) i `PROVIDER-NOTES.md` när testade.
- Automatisera Metod A där providern exponerar CLI (idag manuellt/guidat — klienten måste äga flytten).