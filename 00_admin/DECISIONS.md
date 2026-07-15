# DECISIONS (ADR log)

Short ADR per decision. Format: context → decision → consequence.

## ADR-000 — Slimmed-down project structure (deviation from full B9)
**Context:** B9 says the standard structure should be adapted to the project type; this is a toolkit/knowledge project, not a data pipeline.
**Decision:** keep `00_admin`, `01_docs`, `03_src` (ps+py), `04_tests/validation`, `_sources`. Omit `02_data/` and `04_tests/fixtures`; CSV schemas live in `01_docs/DATA-FORMATS.md`. The tools' output is written to an external `work_dir`, not in the repo.
**Consequence:** a leaner repo without empty folders. The deviation is documented here per B9.

## ADR-001 — Method A (the client's move), never a junction
**Context:** a sync engine tracks folder identity via the NTFS file-id; a junction/robocopy-moved root can be interpreted as "the content deleted" → cloud deletion (proven in the Google Drive move).
**Decision:** always move via the client's own "change location" function; junctions only as a compatibility layer afterwards.
**Consequence:** no inode trap; the only supported path for OneDrive.

## ADR-002 — Files-On-Demand is preserved
**Context:** the source disk may lack space for a full local mirror; mass hydration is expensive and risky.
**Decision:** never materialize placeholders to "solve" the move; never expand the set of locally mirrored files; verification is status-aware.
**Consequence:** the move works even when the cloud is much larger than the target disk.

## ADR-003 — Dry-run default + time-gated deletion
**Context:** risk-elevated irreversible operation (B12.2, A3).
**Decision:** all destructive steps require `-Execute`; the source is retained `min_stable_days` days and moved (not deleted) to backup before purging.
**Consequence:** the rollback baseline is preserved until the sync is proven stable.

## ADR-004 — Swedish docs, English code [SUPERSEDED by ADR-008]
Superseded by ADR-008: documentation is now written in English.
**Context:** B9 requires English identifiers; the ecosystem's documentation is Swedish.
**Decision:** prose/docs in Swedish (native UTF-8), all code/identifiers/schema in English, `.ps1` ASCII-only.
**Consequence:** publishable without post-translation; no encoding traps in code.

## ADR-005 — `_sources/` untouched but never published
**Context:** the original source materials carry paths/IDs; the public surface must be PII-free.
**Decision:** `_sources/` is `.gitignore`d; the distillation in `01_docs/` is the publishable surface.
**Consequence:** the knowledge is preserved locally, PII never leaks to the repo.

## ADR-006 — Git with a separate git-dir outside the sync surface
**Context:** a `.git` inside a synced cloud folder collides with the sync client's scanning → a corrupt object database (proven in an earlier project).
**Decision:** initialize Git with a separate git-dir outside the sync surface, `gc.auto 0`, first commit with named files (never `git add .`).
**Consequence:** the working copy syncs, the Git objects do not; no history loss. See `Initialize-Repo.ps1`.

## ADR-007 - Git-dir in the project folder (departs from ADR-006) + named author
**Context:** the project owner wants a self-contained/portable repo with .git in the project folder, and their own publishing identity.
**Decision:** move .git back into the cloud-synced project folder; keep gc.auto 0 as mitigation. Author: David Hagdahl (deliberately included own PII in LICENSE/README per explicit decision).
**Consequence:** a self-contained/portable repo, but again carries the risk of sync-client corruption of .git (ADR-006's reasoning). Mitigation: gc.auto 0 + pause sync during large git operations.

## ADR-008 - English documentation (supersedes ADR-004)
**Context:** the repo is public; a single English surface across docs and code widens reach and removes the SV/EN split. B9 already requires English for code/identifiers/schema and permits user-facing docs in another language, so this is a deliberate reach choice, not a compliance fix.
**Decision:** all documentation is written in English; code, identifiers and schema remain English (unchanged). The Swedish baseline is preserved at tag v0.1.0.
**Consequence:** single-language public surface; ADR-004's Swedish-docs decision no longer applies. .md stays UTF-8 without BOM; .ps1 stays ASCII-only.
