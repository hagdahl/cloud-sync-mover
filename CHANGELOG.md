# CHANGELOG

> Version 0.3.0

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
Reconciled the CHANGELOG against the git history: added back-registered entries for commits `b51138a` and `cbcb3f7` (B2), fixed three encoding/typo artifacts in older entries (dropped Swedish diacritics, and a broken `01_docs/PRINCIPLES.md` path reference), and added version marker `> Version 0.1.0`. Tagged as `v0.1.0` — Swedish baseline before English translation.
- Rollback: `git revert` this commit; delete the tag `v0.1.0` (`git tag -d v0.1.0`).
- Verification: every commit in the history now has a CHANGELOG entry (1:1); `.md` is UTF-8 without BOM.

## 2026-07-15 - English translation of all documentation
Translated all Markdown docs (README, 00_admin/*, 01_docs/*, DISCLAIMER, CHANGELOG) from Swedish to English. Code, identifiers and schema were already English. ADR-004 (Swedish docs) superseded by ADR-008 (English docs); language references in PRINCIPLES/README/ARCHITECTURE/HANDOVER updated. Version bumped to 0.2.0.
- Rollback: git revert; the Swedish baseline remains at tag v0.1.0.
- Verification: per-file invariant check (commands, paths, hex, thresholds, enums, log markers preserved) + adversarial semantic review vs the Swedish source; .md is UTF-8 without BOM.

## 2026-07-15 - v0.3.0: real gates and reproducibility
Hardened the safety gates and closed reproducibility gaps, from the open issue backlog. Scope chosen to be verifiable without live provider/Windows integration; the provider-integration-heavy issues (#3, #4, #5, #8, #9) are deferred to v0.4.0.
- **Phase success contract (#7):** every `*_done.json` now carries a common header (`schema csm.artifact/1`: provider, mode, source_root, target_root, finishedUtc, success, errors, errorCategories). Read phases set `success=false` on enumeration/hash/read errors instead of writing a bare completion marker.
- **retire-source prerequisite gate (#2):** the destructive phase now refuses unless the latest preflight/structure/verify artifacts are present, green, identity-consistent, recent, and stable for `min_stable_days` from a recorded `[move] move_completed_utc`. Emergency override via explicit, recorded `-Force`.
- **Sync-health preflight gate (#1):** the passive "up to date" reminder is now a real gate — preflight reports `NEEDS_CONFIRMATION` (FAIL) until confirmed via `-SyncConfirmed` or `[move] assume_up_to_date=true`.
- **Junction-safe retire + move exit code (#13 partial, #3 partial):** `retire-source` robocopy now passes `/XJ /XJD /XJF` (never traverses junctions during `/MOVE`) and treats exit `>=8` as failure, writing a `retire_*_done.json` with the exit code and gate/override state.
- **Provider/mode validation (#6 partial):** `Resolve-CsmProviderMode` validates and rejects invalid provider/mode combinations and stamps `mode` into artifacts.
- **Dependency pinning (#10):** added `requirements.txt` (stdlib-only declaration + exact-pin policy) and ADR-009.
- **`.git`-in-synced-folder mitigation (#11):** ADR-010 (accept risk, origin authoritative), new `03_src/ps/Test-RepoHealth.ps1` (`git fsck`), recovery path in HANDOVER.
- **CHANGELOG hygiene (#12):** reworded an awkward historical entry; added a UTF-8/BOM check for tracked `.md` to the test harness.
- **New config keys:** `[move] assume_up_to_date`, `move_completed_utc`, `retire_max_artifact_age_days` (all in `config.example`).
- Files: `03_src/ps/_common.ps1` (+helpers), `Invoke-CloudSyncMove.ps1`, `Test-MovePreflight.ps1`, `Invoke-Inventory.ps1`, `Invoke-Md5Baseline.ps1`, `Compare-MoveStructure.ps1`, `Invoke-HydrationVerify.ps1`, new `Test-RepoHealth.ps1`, `requirements.txt`, `config.example`, docs (DECISIONS ADR-009/010, DATA-FORMATS, HANDOVER, README, ARCHITECTURE, USER_GUIDE), `04_tests/validation/Test-Toolkit.ps1` (+11 unit tests).
- Rollback: `git revert` this commit / reset to tag `v0.2.0`. No behavior of existing green paths changed except the two new gates (which fail safe); no data operation altered beyond adding `/XJ` exclusions.
- Hardening from an adversarial code review of the gate: identity check now fails **closed** on any missing field; a "hydrating" verify re-run now writes a non-green artifact (so a stale earlier green cannot be reused); "latest artifact" is chosen by content timestamp (not file mtime); future-dated artifacts are rejected; `retire-source` asserts the source exists before robocopy; and `Test-RepoHealth.ps1` no longer throws on git's stderr notices.
- Verification: extended unit tests (provider/mode, sync-health, artifact success/age, retire gate with fixtures incl. identity fail-closed, BOM) — run `04_tests/validation/Test-Toolkit.ps1` on Windows; `.ps1` ASCII-only; orchestrator dry-run unchanged.
