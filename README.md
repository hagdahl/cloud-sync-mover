# cloud-sync-mover

> **Varning / ansvarsfriskrivning:** detta utför riskfyllda filoperationer på molnsynkade data. Använd helt på **egen risk** - skaparen tar inget ansvar för skada på hårdvara, mjukvara eller dataförlust. Kör dry-run först och ha en verifierad backup. Se [DISCLAIMER.md](DISCLAIMER.md).

Principer, logik och en körbar verktygslåda för att **flytta den lokala datamappen för en molnsynkad tjänst** (OneDrive, Google Drive) från en disk till en annan på Windows — utan att trigga molnradering, utan att massmaterialisera platshållare, och med bevisbar verifiering att inget gått förlorat.

Projektet är destillerat ur två skarpa flyttar (Google Drive och OneDrive Personal) och följer `cowork-projektinstruktioner` (konventionerna sammanfattas i `01_docs/PRINCIPLES.md` så repot är självbärande). Det är avidentifierat: inga personer, användare, datorer eller system nämns. Det enda som är specifikt är **vilka molntjänster** som stöds och **vilka klient-/versionsnummer** det är testat mot.

## Vad det är / inte är

- **Är:** en playbook (beslutsträd, faser, felmekanismer, checklists) + PowerShell/Python-verktyg som utför inventering, MD5-baslinje, preflight, strukturverifiering, hydrerings-medveten efterverifiering och läsning av synkmotorns tillstånd.
- **Är inte:** en one-click-migrator. Varje destruktivt steg är opt-in, dry-run är default, och radering av källan är tidsgrindad. Människa-i-loopen (A1) gäller.

## Dataklassificering (A2)

| Datakategori | Var | Känslighet | Publicerbar |
|---|---|---|---|
| Kod, playbook, docs (detta repo) | repo-rot | Ingen PU — generisk kunskap | Ja (nivå 2/3) |
| `_sources/` (osrubbade originalunderlag) | `_sources/` | Kan bära sökvägar/IDs | **Nej** — `.gitignore`:ad, publiceras aldrig |
| Verktygens utdata (inventory-CSV, MD5-CSV, state-snapshot) | `work_dir` (lokal disk) | Innehåller personliga sökvägar | **Nej** — genereras lokalt, `.gitignore`:ad |
| Config med faktiska sökvägar | `config.local` | Miljöspecifik | **Nej** — `.gitignore`:ad; endast `config.example` checkas in |

Verktygen läser **aldrig filinnehåll** i inventeringsfasen (endast attribut), skickar **ingen data till moln-API:er** utöver providerns egen kvot-/metadata-endpoint, och skriver alla artefakter till en lokal `work_dir` utanför den synkade mappen.

## Stödda tjänster och testade klienter

| Tjänst | Klient | Testad version | Flyttmetod |
|---|---|---|---|
| OneDrive Personal | OneDrive för Windows | 26.106–26.108 | Metod A (avlänka → länka om → Välj plats) |
| OneDrive for Business | OneDrive för Windows | 26.x | Metod A |
| Google Drive | Google Drive för desktop | 2024–2025-generationen | Byt plats i klientens inställningar (motsvarande Metod A) |

Windows 10/11. PowerShell 5.1 + 7. Python 3.11+ (endast för läsning av OneDrives SQLite-tillstånd).

## Snabbstart

1. Kopiera `config.example` → `config.local` och fyll i `source_root`, `target_root`, `work_dir`.
2. Kör orkestreraren i **dry-run** (default) för att se planen utan att ändra något:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local`
3. Följ faserna i `01_docs/USER_GUIDE.md`. Varje fas har egen verifiering; radering av källan sker först efter tidsgrind + uttryckligt `-Execute`.

## Metoden i en mening

Använd **molnklientens egen flyttfunktion** (aldrig en junction/symlink), bevara Files-On-Demand-platshållare (materialisera inte allt), och bevisa noll dataförlust genom inventering → MD5-baslinje av lokala filer → strukturdiff → hydrerings-medveten efterverifiering → moln-facit via providerns API, innan källan någonsin rörs.

## Struktur

```
00_admin/    HANDOVER, DECISIONS (ADR), GLOSSARY, LESSONS_LEARNED, DEFINITION_OF_DONE
01_docs/     PLAYBOOK, ARCHITECTURE, USER_GUIDE, PROVIDER-NOTES, VERIFY-PROMPT, DATA-FORMATS
03_src/ps/   PowerShell-verktygslåda (ASCII-only, dry-run default)
03_src/py/   read_sync_state.py (läser OneDrives SQLite-tillstånd, read-only)
04_tests/validation/  smoke-/dry-run-tester
CHANGELOG.md, README.md, LICENSE, .gitignore, config.example
```

## Licens

MIT — se `LICENSE`.