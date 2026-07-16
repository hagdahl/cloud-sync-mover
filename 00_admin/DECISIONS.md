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

## ADR-012 - Provider diagnostics classify, and prove sync by round-trip (issues #5, #6, #4, #8, #9, #15)
**Context:** the remaining backlog is about knowing the provider is safe to retire *before* moving the source. Three hazards: a client mid-startup/scan looks identical to a hung client (a large, growing local cache WAL is the SAME shape as a stuck one, #15); "the client says Up to date" is a display, not proof that pending local edits actually left the machine (#9); and Google Drive *mirror* mode silently tolerates online-only placeholders that make the local set incomplete (#6). Verdicts must never fail OPEN (A4).
**Decision:** (1) a pure two-part split - read-only provider readers gather signals, and pure classifiers (`Get-CsmLivenessVerdict`, `Get-CsmDiagnoseHealth`) turn them into a verdict, so the judgment is unit-testable without a live account. (2) "No known danger marker" resolves to `unknown`, NEVER `healthy` - only a positive verified signal is healthy (fail-closed). (3) A large + GROWING cache during startup is `initializing` (healthy-transient), and preflight consumes a FRESH `initializing` as NEEDS_WAIT, not FAIL (#15/#1). (4) Round-trip proof (#9) is the only positive sync evidence: write one non-identifying canary into a dedicated `[probe] probe_dir`, and delegate remote observation to an operator-supplied `[probe] confirm_command` (the toolkit never contacts the provider); dry-run is the default, `-Execute` writes exactly one canary and cleans up only that file. (5) All diagnostic output is REDACTED (counts + health; no account ids, local paths, or filenames). Throttling is deliberately NOT a danger signal (the "counter lies during hydration" lesson, A4).
**Consequence:** the operator gets a machine-checkable, fail-closed pre-retire verdict and, via the probe, actual proof that local changes reach the cloud. Trade-off: provider paths/markers and the confirm_command are operator-configurable and best-effort by default - they must be tuned against real logs, and the live tuning + any `-Execute` round-trip against a real account is the operator step, never run by the toolkit against an account without consent.

## ADR-013 - Publishability level 2/3 (B1 classification)
**Context:** B1 requires the publishability level of the repo to be recorded as a decision, not just asserted inline. This project is a de-identified, generic toolkit + playbook distilled from two real migrations; the sensitive inputs (source material, real paths, tool output) are deliberately excluded from the tracked surface.
**Decision:** classify the repository as **publishability level 2/3** - publishable generic knowledge and code, with two hold-backs: (1) `_sources/` (unscrubbed source material) and `_backups/` are read-only and never published (`.gitignore`d, A2); (2) generated output (`inventory_*.csv`, `md5_*.csv`, `*_done.json`, state snapshots) is produced locally in `work_dir` and never committed. Only cloud-service names and tested client version numbers are specific; no people, users, computers, or systems are named. The A2 data-classification table (README) and the file/edit-status classification (ARCHITECTURE, B1) enumerate what is in vs out.
**Consequence:** the public surface is safe to publish as-is; the de-identification discipline is auditable (PII scan on the tracked surface is part of the Definition of Done). Any file that would carry paths/IDs stays behind the `.gitignore` boundary; promoting anything from `_sources/` to the tracked surface requires explicit de-identification first.
