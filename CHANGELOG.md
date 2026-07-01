# CHANGELOG

Format: datum - ändring - rollback.

## 2026-07-01 - Initialt projekt
Skapade `cloud-sync-mover`: playbook, docs, PowerShell/Python-verktygslåda och tester, destillerat ur en Google Drive- och en OneDrive-flytt. Avidentifierat (endast molntjänster + klientversioner är specifika).

- **Nya filer:** `README.md`, `LICENSE`, `.gitignore`, `config.example`, `00_admin/*`, `01_docs/*`, `03_src/ps/*`, `03_src/py/read_sync_state.py`, `04_tests/validation/Test-Toolkit.ps1`.
- **Struktur:** bantad från full B9 (se `00_admin/DECISIONS.md` ADR-000).
- **Verifiering:** smoke-tester gröna; alla `.ps1` ASCII-only + parse-rena; PII-scan ren på spårad yta.
- **Rollback:** ta bort projektmappen; inga externa system berördes, ingen data flyttades. `_sources/` är `.gitignore`:ad och committas aldrig.