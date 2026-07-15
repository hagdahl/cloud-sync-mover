# PRINCIPLES - the conventions the project follows (self-contained summary)

This project follows the conventions in the `cowork-project-instructions` standard. For the repo to be **self-contained** - to work without access to that standard - the codes cited in the project are summarized here in plain text. The codes are only reference labels; the principles below are what applies.

| Code | Principle (short) |
|---|---|
| A1 | Human-in-the-loop: dry-run as default, explicit approval before destructive/irreversible steps. |
| A2 | Secrets and personal data are kept out of version-controlled content; `.gitignore` from the start; the public surface is PII-free. |
| A3 | Version control + rollback: Git from the start, CHANGELOG with rollback, the source is the baseline until proven dispensable. |
| A4 | Self-verification: nothing is reported as done without having been verified (run, count, compare, test). |
| A5 | Definition of Done: explicit completion criterion per task. |
| A6 | Idempotence: scripts can be re-run without duplicates/corrupt state; atomic write (temp + rename). |
| A7 | Least privilege + emergency stop: minimal permissions, all automation can be stopped in one sweep. |
| B3 | Self-bearing handover. |
| B8 | Error handling/logging + encoding discipline (ASCII `.ps1`, UTF-8 without BOM for `.py`/`.md`). |
| B9 | Fixed project structure and naming convention, adapted to the project type. |
| B11 | Compute choice/data minimization: simplest local tools first; no unnecessary cloud sharing. |
| B12.2 | Risk-elevated local script jobs (deletion/move/permissions) require dry-run + logging + approval. |
| B13 | Centralized configuration (`config.example` -> `config.local`, clear override order). |
| B14 | Execution environment versus target environment: run where the operation belongs; decouple long-running jobs. |

**About `cowork-configurations`:** that file is the standard's environment-specific, local-only instance (absolute paths, versions, identifying data). It is **never** published, and this project does not reference it and does not need it. Everything a recipient needs is in this repo.
