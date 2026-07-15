# cloud-sync-mover

> **Warning / disclaimer:** this performs risky file operations on cloud-synced data. Use entirely at **your own risk** — the author accepts no responsibility for damage to hardware, software, or data loss. Run dry-run first and keep a verified backup. See [DISCLAIMER.md](DISCLAIMER.md).

Principles, logic, and a runnable toolkit for **moving the local data folder of a cloud-synced service** (OneDrive, Google Drive) from one disk to another on Windows — without triggering cloud deletion, without mass-materializing placeholders, and with provable verification that nothing was lost.

The project is distilled from two real migrations (Google Drive and OneDrive Personal) and follows `cowork-project-instructions` (the conventions are summarized in `01_docs/PRINCIPLES.md` so the repo is self-contained). It is de-identified: no people, users, computers, or systems are named. The only things that are specific are **which cloud services** are supported and **which client/version numbers** it was tested against.

## What it is / is not

- **Is:** a playbook (decision tree, phases, failure mechanisms, checklists) + PowerShell/Python tools that perform inventory, MD5 baseline, preflight, structure verification, hydration-aware post-verification, and reading of the sync engine state.
- **Is not:** a one-click migrator. Every destructive step is opt-in, dry-run is the default, and deletion of the source is time-gated. Human-in-the-loop (A1) applies.

## Data classification (A2)

| Data category | Location | Sensitivity | Publishable |
|---|---|---|---|
| Code, playbook, docs (this repo) | repo root | None — generic knowledge | Yes (level 2/3) |
| `_sources/` (unscrubbed source material) | `_sources/` | May carry paths/IDs | **No** — `.gitignore`d, never published |
| Tool output (inventory CSV, MD5 CSV, state snapshot) | `work_dir` (local disk) | Contains personal paths | **No** — generated locally, `.gitignore`d |
| Config with actual paths | `config.local` | Environment-specific | **No** — `.gitignore`d; only `config.example` is checked in |

The tools **never read file content** during the inventory phase (attributes only), send **no data to cloud APIs** beyond the provider's own quota/metadata endpoint, and write all artifacts to a local `work_dir` outside the synced folder.

## Supported services and tested clients

| Service | Client | Tested version | Move method |
|---|---|---|---|
| OneDrive Personal | OneDrive for Windows | 26.106–26.108 | Method A (unlink → relink → Change location) |
| OneDrive for Business | OneDrive for Windows | 26.x | Method A |
| Google Drive | Google Drive for desktop | 2024–2025 generation | Change location in the client's settings (equivalent to Method A) |

Windows 10/11. PowerShell 5.1 + 7. Python 3.11+ (only for reading OneDrive's SQLite state).

## Quick start

1. Copy `config.example` → `config.local` and fill in `source_root`, `target_root`, `work_dir`.
2. Run the orchestrator in **dry-run** (default) to see the plan without changing anything:
   `powershell -File 03_src\ps\Invoke-CloudSyncMove.ps1 -Config .\config.local`
3. Follow the phases in `01_docs/USER_GUIDE.md`. Each phase has its own verification; deletion of the source happens only after the time gate + an explicit `-Execute`.

## The method in one sentence

Use **the cloud client's own move function** (never a junction/symlink), preserve Files-On-Demand placeholders (don't materialize everything), and prove zero data loss through inventory → MD5 baseline of local files → structure diff → hydration-aware post-verification → cloud ground truth via the provider's API, before the source is ever touched.

## Structure

```
00_admin/    HANDOVER, DECISIONS (ADR), GLOSSARY, LESSONS_LEARNED, DEFINITION_OF_DONE
01_docs/     PLAYBOOK, ARCHITECTURE, USER_GUIDE, PROVIDER-NOTES, VERIFY-PROMPT, DATA-FORMATS
03_src/ps/   PowerShell toolkit (ASCII-only, dry-run default)
03_src/py/   read_sync_state.py (reads OneDrive's SQLite state, read-only)
04_tests/validation/  smoke / dry-run tests
CHANGELOG.md, README.md, LICENSE, .gitignore, config.example
```

## License

MIT — see `LICENSE`.

## Author / Maintainer

David Hagdahl <david@hagdahl.se>
