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

## ADR-009 - Python is standard-library only; exact-pin policy (B6)
**Context:** B6 requires dependencies to be documented and locked to exact versions, separated into runtime vs test. The Python scripts import only the standard library, so there is nothing third-party to pin, but the *statement* of that was missing (see issue #10).
**Decision:** ship a `requirements.txt` at the root that declares the runtime as stdlib-only on a tested CPython 3.11 baseline, distinguishes runtime from test/dev, and records the policy: any future third-party package is pinned with `==` (exact), never a range. Runtime baselines are also stated in `README.md` / `01_docs/ARCHITECTURE.md`.
**Consequence:** the B6 gap is closed with an explicit, reproducible declaration; the file also documents where to pin if a dependency is ever added.

## ADR-010 - Accept the ADR-007 .git-in-synced-folder risk; origin is authoritative (issue #11)
**Context:** ADR-007 keeps `.git` inside the cloud-synced project folder, re-introducing the object-database corruption risk ADR-006 avoided. The project owner wants the self-contained/portable layout, so restoring ADR-006 is not desired.
**Decision:** accept the residual risk with `origin` (GitHub) as the authoritative copy: local `.git` corruption is recovered by re-cloning from origin. Mitigations: keep `gc.auto 0` (ADR-007), and run `03_src/ps/Test-RepoHealth.ps1` (git fsck) periodically and before any large git operation to catch corruption early. The recovery path is documented in `00_admin/HANDOVER.md`.
**Consequence:** the portable layout is kept; corruption is detectable and recoverable without work loss, as long as the working tree is committed and pushed to origin regularly. Superset option (separate git-dir, ADR-006) remains available via `Initialize-Repo.ps1` if the risk posture changes.

## ADR-011 - Junction-safe, noise-aware enumeration; physical root is the identity (issues #13, #4)
**Context:** the read phases used `EnumerateFiles(..., AllDirectories)`, which traverses THROUGH junctions/symlinks. In the common "root reached via a junction" topology this can double-count, cross to another volume, or (on retire) delete through a reparse point. Provider-internal temp/staging directories were also counted as user data, destabilizing hashes and structure diffs.
**Decision:** a single shared walk (`Invoke-CsmWalk`) never descends through a reparse point or a provider-noise directory; both are classified and reported, not counted. Junctions are skip-and-classified (the safe default, not resolve-and-dedupe); preflight reports reparse points at/above/under each root and flags any child junction so the operator knows its subtree was excluded. Every artifact is stamped with the resolved physical root (`physical_source_root`/`physical_target_root`) so cross-phase identity compares like with like.
**Consequence:** counts are stable whether or not a junction shims the root; combined with the v0.3.0 `/XJ /XJD /XJF` on the retire `/MOVE`, the reparse hazard is closed. Trade-off: a subtree that legitimately lives behind a junction is excluded from the baseline - surfaced in preflight so it is a conscious operator choice, not a silent loss.
