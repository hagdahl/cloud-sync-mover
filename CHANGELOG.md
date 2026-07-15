# CHANGELOG

> Version 0.2.0

Format: date - change - rollback.

## 2026-07-01 - Initial project
Created `cloud-sync-mover`: playbook, docs, PowerShell/Python toolkit and tests, distilled from a Google Drive and a OneDrive move. De-identified (only cloud services + client versions are specific).

- **New files:** `README.md`, `LICENSE`, `.gitignore`, `config.example`, `00_admin/*`, `01_docs/*`, `03_src/ps/*`, `03_src/py/read_sync_state.py`, `04_tests/validation/Test-Toolkit.ps1`.
- **Structure:** trimmed down from full B9 (see `00_admin/DECISIONS.md` ADR-000).
- **Verification:** smoke tests green; all `.ps1` ASCII-only + parse-clean; PII scan clean on tracked surface.
- **Rollback:** delete the project folder; no external systems were touched, no data was moved. `_sources/` is `.gitignore`d and is never committed.

## 2026-07-01 - Log parsers added
Added diagnostic log parsers: `03_src/py/parse_odl.py` + `03_src/ps/Read-OneDriveLogs.ps1` (OneDrive ODL), and `03_src/ps/Read-GoogleDriveLogs.ps1` (Google Drive inode/deletion markers). Docs updated (ARCHITECTURE, USER_GUIDE, PLAYBOOK, PROVIDER-NOTES).
- Rollback: delete the three files + the appended sections. No data was touched.
- Verification: smoke tests (ASCII + parse) green; PII scan clean.

## 2026-07-01 - Lessons learned + provider notes distilled
Distilled the session diagnostics into `00_admin/LESSONS_LEARNED.md` and `01_docs/PROVIDER-NOTES.md` (de-identified). Back-registered entry for commit `b51138a`.
- Rollback: restore the two files to the previous version. No data was touched.
- Verification: PII scan clean on tracked surface.

## 2026-07-01 - Publication readiness
Made the repo self-contained (`01_docs/PRINCIPLES.md` explains the cited codes so no external standard is required) and added DISCLAIMER.md + warning banner (README/USER_GUIDE). Confirmed: zero references to local-only cowork-configurations.
- Rollback: delete PRINCIPLES.md/DISCLAIMER.md + revert the README/USER_GUIDE additions.

## 2026-07-01 - Publication identity + git dir choice
- Author/publisher: David Hagdahl (LICENSE, README) - own PII deliberately included per decision.
- .git moved into the project folder (normal directory) per decision; gc.auto 0 retained (departs from ADR-006, see ADR-007).

## 2026-07-01 - config.example covers Google Drive
Extended `config.example` with Google Drive support: mount/virtual-disk paths and `[google_drive] mode = streaming|mirror`. Back-registered entry for commit `cbcb3f7`.
- Rollback: restore `config.example` to the previous version. No data was touched.
- Verification: config reads as INI; no secrets added.

## 2026-07-15 - CHANGELOG reconciliation + baseline v0.1.0
Reconciled the CHANGELOG against the git history: added back-registered entries for commits `b51138a` and `cbcb3f7` (B2), fixed encoding artifacts (deletion markers, touched, green, `01_docs/PRINCIPLES.md`) and added version marker `> Version 0.1.0`. Tagged as `v0.1.0` — Swedish baseline before English translation.
- Rollback: `git revert` this commit; delete the tag `v0.1.0` (`git tag -d v0.1.0`).
- Verification: every commit in the history now has a CHANGELOG entry (1:1); `.md` is UTF-8 without BOM.

## 2026-07-15 - English translation of all documentation
Translated all Markdown docs (README, 00_admin/*, 01_docs/*, DISCLAIMER, CHANGELOG) from Swedish to English. Code, identifiers and schema were already English. ADR-004 (Swedish docs) superseded by ADR-008 (English docs); language references in PRINCIPLES/README/ARCHITECTURE/HANDOVER updated. Version bumped to 0.2.0.
- Rollback: git revert; the Swedish baseline remains at tag v0.1.0.
- Verification: per-file invariant check (commands, paths, hex, thresholds, enums, log markers preserved) + adversarial semantic review vs the Swedish source; .md is UTF-8 without BOM.
