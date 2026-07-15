# DEFINITION_OF_DONE (A5)

A move performed with this toolkit is done when:

1. **Phase 0 inventory** exists (inventory CSV + pinlist), and the drift check (schedule LastRun vs data LastWrite) is clean or resolved.
2. **MD5 baseline** exists for all local files (phase 1).
3. **Preflight** green: free space, writability, "Up to date" status, disk type (no SMR warning ignored), cloud baseline saved.
4. **Move performed via Method A** (the client's own function) — not a junction.
5. **Structure verification** shows actual missing files ~0 (only classified junk in "missing").
6. **Hydration-aware post-verify** green: spot check 0 online-only, full MD5 comparison against the baseline with 0 unexplained mismatches (device-dependent shortcuts whitelisted).
7. **Cloud ground truth** unchanged: quota/object diff against the phase 2 baseline = 0.
8. **CHANGELOG entry** written with rollback.
9. **Deleting the source has NOT been done** until `min_stable_days` days of stable sync + an explicit `-Execute`; the source is moved (not deleted) to backup first.
10. **Logging is sufficient** to troubleshoot after the fact (each phase has `*_done.json` + log).

A project DoD (for the repo itself): the mandatory artifacts exist (README, .gitignore, CHANGELOG, DECISIONS, HANDOVER, GLOSSARY, ARCHITECTURE, USER_GUIDE, config.example, LICENSE), the scripts are ASCII-verified, no PII in tracked content (see `04_tests/validation`).
