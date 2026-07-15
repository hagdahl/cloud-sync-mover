# HANDOVER — cloud-sync-mover

Self-contained handover (B3). Should be enough for a new person or agent to understand and drive the project without external context.

## What the project is
Principles, logic, and a runnable toolkit for moving the local data folder of a cloud-synced service (OneDrive, Google Drive) between disks on Windows — safely, FoD-preserving, with provable verification. Distilled from two real moves (Google Drive, OneDrive Personal), de-identified and publishable.

## Status
- Playbook + docs: done (`01_docs/`).
- Toolkit: `03_src/ps/` (PowerShell, ASCII, dry-run default) + `03_src/py/read_sync_state.py`.
- Un-scrubbed sources: `_sources/` (gitignored, never published).
- Structure trimmed down from the full B9 (see DECISIONS ADR-000).

## How to continue / use
1. Read `README.md` → `01_docs/PLAYBOOK.md` → `01_docs/USER_GUIDE.md`.
2. Copy `config.example` → `config.local`, fill in the paths.
3. Run the phases (inventory → baseline → preflight → the client's move → structure verify → hydration verify → time-gated deletion).

## Key principles (why it looks the way it does)
- The client's own move, **never a junction** (the inode trap).
- FoD is preserved, never materialize everything.
- Dry-run default; deletion of the source is time-gated + `-Execute`.
- The cloud is ground truth and is never touched.
- Sync error counter = usually throttling, not a data problem — verify against the sync engine's state.

## Where the knowledge comes from
`_sources/` contains the two lessons-learned files, the OneDrive move's handover, the 740-sync-error report, and the verification prompt. These are un-scrubbed originals; the publishable distillation is `01_docs/PLAYBOOK.md`.

## Remaining / possible additions
- More providers (Dropbox, iCloud) in `PROVIDER-NOTES.md` once tested.
- Automate Method A where the provider exposes a CLI (today manual/guided — the client must own the move).
