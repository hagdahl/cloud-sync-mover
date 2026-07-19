# CHANGELOG

> Version 0.5.1

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

## 2026-07-16 - v0.4.0: junction-safe and noise-aware enumeration
Closes the highest-remaining safety gap. The read phases now share one junction-safe, provider-noise-aware file walk. Scope chosen to be verifiable on real Windows (junctions + robocopy) without a live cloud account; the remaining backlog (#3, #5, #6 behavior, #8, #9) is deferred to v0.5.0.
- **Junction / reparse safety (#13):** new `Invoke-CsmWalk` never traverses THROUGH a reparse point, so a junction under the root can no longer double-count, cross volumes, or (with the v0.3.0 `/XJ` on retire) be deleted through. Inventory and structure now use it; `Test-CsmReparsePoint` + `Resolve-CsmPhysicalRoot` added; preflight detects and reports reparse points at/above/under each root and flags any child junction whose subtree is therefore excluded; every artifact is stamped with `physical_source_root`/`physical_target_root` so the retire gate compares like with like.
- **Provider-internal temp/staging classification (#4):** `Get-CsmNoisePatterns` (provider-aware, config-overridable via `[enumeration] noise_dir_patterns`) classifies OS noise + Google Drive `.tmp.drivedownload`/`.tmp.driveupload` staging dirs out of the user-data baseline; inventory/structure record `reparse_skipped`, `noise_skipped`, and `access_errors`, and fail closed on an unreadable directory (an access error could hide user data).
- Fixed the pre-existing trailing-backslash `source_root` off-by-one in relative-path computation (roots are normalized with `TrimEnd('\')`).
- New config: `[enumeration] noise_dir_patterns` (in `config.example`).
- Files: `03_src/ps/_common.ps1` (+4 helpers, physical roots in `New-CsmMeta`), `Invoke-Inventory.ps1`, `Compare-MoveStructure.ps1`, `Test-MovePreflight.ps1`, `config.example`, docs (DECISIONS ADR-011, DATA-FORMATS, PROVIDER-NOTES, USER_GUIDE), `04_tests/validation/Test-Toolkit.ps1` (+8 unit tests incl. a real junction).
- Rollback: `git revert` this commit / reset to tag `v0.3.0`. Enumeration now excludes reparse/noise subtrees by design; if a needed subtree lived behind a junction, preflight reports it so the operator can act.
- Verification: all unit tests pass on Windows PowerShell 5.1 and PowerShell 7, including a real `mklink /J` junction that the walk correctly skips; `.ps1` ASCII-only; orchestrator dry-run unchanged. Deferred #3/#5/#6/#8/#9 need live OneDrive/Google Drive fixtures.
## 2026-07-16 - v0.5.0: resumable retire + provider diagnostics + round-trip proof
Closes the remaining pre-retire backlog. Two themes: make the destructive step resumable and self-verifying (#3), and let the operator KNOW the provider is safe to retire before moving the source (#5, #6, #4, #8, #9, #15).
- **Resumable, verified retire-source (#3):** the retire `/MOVE` now targets a stable, timestamp-free backup folder (`OldSyncSourceBackup`) so a re-run RESUMES instead of forking a new copy; robocopy's exit code is interpreted by bit-flags (`Get-CsmRobocopyExitInfo`), and the move is verified after the fact - leftover source files (robocopy leaves any file it failed to copy in place) are walked and counted, the backup is stat-counted, and success requires exit<8 AND zero leftovers. An incomplete run leaves the remainder in the source and tells the operator to re-run to resume. A machine-readable `retire_*_manifest.json` records it.
- **Provider-aware diagnosis (#5):** new `Invoke-CsmDiagnose.ps1` routes by provider - Google Drive via `Read-GoogleDriveState.ps1`, OneDrive via the existing state reader - and aggregates signals through the pure `Get-CsmDiagnoseHealth` classifier into one health verdict (`healthy`/`initializing`/`warning`/`blocked`/`unknown`). "No known danger marker" is `unknown`, never `healthy` (fail-closed). Output is redacted (counts + health only). Throttling is deliberately not a danger signal.
- **Startup vs hung (#15/#8):** `Read-GoogleDriveState.ps1` samples the Google Drive cache read-only (twice, N seconds apart): process CPU delta, max WAL size + growth, log tick, and stale-upload markers. A large + GROWING WAL during startup is classified `initializing` (healthy-transient) by `Get-CsmLivenessVerdict`, not `blocked`. Preflight consumes a FRESH `initializing` as **NEEDS_WAIT** (a new verdict), not a bare FAIL; a fresh `blocked` fails; `warning` is advisory; stale verdicts are ignored.
- **Mirror-mode completeness (#6):** preflight now blocks Google Drive *mirror* mode when the latest inventory has any online-only file or is not green (a mirror is supposed to hold every file locally).
- **Provider staging health (#4):** preflight probes top-level provider staging/noise dirs (isolated write test + size), flagging any that are large or inaccessible - a persistently large staging area can mean a stuck upload queue.
- **Round-trip proof (#9):** new `Invoke-RoundTripProbe.ps1` proves the provider is ACTUALLY syncing, not just displaying "Up to date". Dry-run by default; `-Execute` writes exactly one non-identifying canary into a dedicated `[probe] probe_dir` and delegates remote observation to an operator-supplied `[probe] confirm_command` (token via `CSM_PROBE_TOKEN`/`{token}`). Bounded cleanup removes only that canary. The toolkit never contacts the provider itself, and never runs `-Execute` against a real account on the operator's behalf.
- **Orchestrator:** `diagnose` now runs the provider-aware dispatcher; new `probe` phase (dry-run; `-Execute` opt-in).
- New config: `[google_drive] cache_root/wal_warn_mb/stale_marker_patterns/process_name`, `[diagnose] sample_seconds/max_age_minutes`, `[enumeration] staging_warn_gb`, `[probe] probe_dir/confirm_command/timeout_seconds/poll_seconds`.
- Files: `03_src/ps/_common.ps1` (+`Get-CsmLivenessVerdict`, `Get-CsmDiagnoseHealth`), new `Invoke-CsmDiagnose.ps1`, `Read-GoogleDriveState.ps1`, `Invoke-RoundTripProbe.ps1`, `Invoke-CloudSyncMove.ps1` (diagnose route + probe phase), `Test-MovePreflight.ps1` (mirror/staging/diagnose checks), `config.example`, docs (DECISIONS ADR-012, PROVIDER-NOTES, USER_GUIDE, PLAYBOOK, DATA-FORMATS), `04_tests/validation/Test-Toolkit.ps1` (+ liveness/health/gdrive-reader/probe unit tests).
- Rollback: `git revert` this commit / reset to tag `v0.4.0`. No behavior change to the read-only phases' outputs; the retire backup path changed name (timestamp-free) - a prior timestamped backup from an earlier version is not auto-detected, so finish any in-flight retire on the old version first.
- Verification: all unit tests pass on Windows PowerShell 5.1 and PowerShell 7 (incl. classifiers, a synthetic Google Drive cache fixture, and the probe dry-run writing no canary); `.ps1` ASCII-only + parse-clean. Live OneDrive/Google Drive verification of #5/#8/#9/#15 (real cache logs, an actual round-trip, real conflict/error codes) is the operator step - the logic is implemented and fixture-tested; the provider paths/markers and confirm_command are best-effort defaults to be tuned against real logs.
## 2026-07-16 20:40 UTC - v0.5.1: align to cowork-project-instructions v0.61
Compliance pass against the standard's current version (v0.61). No PART A violations were found; this closes the PART B partials an audit surfaced (mostly documentation-classification and encoding/error-handling detail). No change to any move/verify behavior.
- **B1 architecture classifications:** `01_docs/ARCHITECTURE.md` now carries a per-file-type logic/data/hybrid table and an **edit-status per-directory** table (editable / read-only / tool-written / never-touch — the rule added to the standard in its v0.54), and the publishability level (2/3) is recorded as **ADR-013** in `00_admin/DECISIONS.md` rather than only asserted inline. The phase map + encoding section were refreshed to include the v0.5.0 scripts (diagnose dispatcher, Google Drive reader, round-trip probe).
- **B8 true error classification:** the writability preflight no longer returns a bare `false` on denial - `Get-CsmWriteDenialCause` + `Test-CsmWritableDetail` classify it as `permission-or-cfa` (ACL / Defender Controlled-Folder-Access), `reparse-or-placeholder`, `process-lock`, or `not-found`, and preflight surfaces the cause + a hint (`target_writable_cause` / `target_writable_hint`).
- **B8 no silent failure:** the empty `catch {}` in `Write-CsmLog` now surfaces a log-write failure on the host (the line was already emitted, so no data is lost) instead of swallowing it.
- **A4 encoding self-test:** `Test-Toolkit.ps1` adds a runtime write->read-back of a known non-ASCII string via `Write-CsmAtomic` (asserts byte-identical + no BOM), plus a `.py` UTF-8-without-BOM check and unit tests for the denial classifier.
- **B13 override order:** documented in `README.md` (CLI > ENV > config.local > config.example > code default), not only in `config.example`.
- **B2:** CHANGELOG entries now carry date **and time**.
- Files: `01_docs/ARCHITECTURE.md`, `00_admin/DECISIONS.md` (ADR-013), `03_src/ps/_common.ps1`, `03_src/ps/Test-MovePreflight.ps1`, `04_tests/validation/Test-Toolkit.ps1`, `README.md`, `CHANGELOG.md`.
- Rollback: `git revert` this commit / reset to tag `v0.5.0`. Behavior of existing green paths is unchanged; the only functional addition is a richer (still fail-closed) preflight writability message.
- Verification: full smoke suite green on Windows PowerShell 5.1 and 7 (adds encoding round-trip + denial-classifier tests incl. a real junction); `.ps1` ASCII-only + parse-clean; `.md`/`.py` no-BOM. The two audit items about tagging and `gc.auto 0` were confirmed already satisfied on the authoritative working copy (tag `v0.5.0` on origin; `gc.auto 0` set) - no change needed.

## 2026-07-19 22:58 UTC - Field incident distilled: mirror upsync blocked by a locked staging queue
Knowledge artifacts only - no code or behavior change. Distilled a live 2026-07-19 incident (Google Drive mirror: a ~36 GB, ~5 574-file undeletable `.tmp.driveupload` on one mount root silently blocked ALL mirror upsync for days) into a new dated section in `00_admin/LESSONS_LEARNED.md`, and filed five improvement proposals in new `00_admin/proposals/2026-07-19_upsync_block_proposals.md` (pre-classified per the standard's QA point 9; routed as issues #16/#17/#18 plus comments on open #5/#15).
- Also repairs a header damaged by the incident-day file write: the `## 2026-07 - OneDrive Personal` section heading had lost its `## 2` prefix when the new section was inserted above it.
- Rollback: `git revert` this commit; both files are additive knowledge records, no tool behavior involved.
- Verification: PII check of both files (de-identified; only generic placeholders like `E:\<top-level-mirror-root>`); `.md` UTF-8 without BOM; heading structure restored (one `##` per dated entry).
