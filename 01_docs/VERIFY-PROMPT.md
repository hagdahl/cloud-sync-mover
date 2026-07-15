# VERIFY-PROMPT — verify that a project/job works after a move

> Reusable prompt to paste in (point it at the right project folder) after project files/dependencies have been moved to a new disk or a new path. Goal: prove that the project still starts and runs BEFORE it is next run for real. Run it as a review (dry-run) — change nothing without approval.

## Path history (a common assumption clash)
Data often moves between locations over time (streamed cloud drive → local mirror → another disk, reached via junction). Old absolute paths live on in scripts/config and must be found and corrected. Flag in particular hardcoded paths that point to a previous location.

## Do this (report PASS/FAIL per item)

1. **Paths point correctly.** Verify that the project folder + key files exist. Search `*.py, *.ps1, *.json, *.env*, config*` for hardcoded absolute paths; flag each one that points to a previous disk/location. Replace with a relative path or central config.
2. **Python venv (the most common failure source).** Check `.venv\pyvenv.cfg` (`home = ...`) and `.venv\Scripts\`. Smoke test: `python.exe -c "import sys; print(sys.prefix)"`. Fails → recreate the venv + `pip install -r requirements.txt`.
3. **Node dependencies.** node_modules is usually path-independent, but symlinks/.bin can break. Smoke-test the project's test/lint. Error → `npm ci`.
4. **Config & secrets.** `.env`/`config.local` exist and point correctly. No paths to a previous location.
5. **Scheduled jobs.** List the tasks tied to the project; check that the Action/working directory points correctly. A path move breaks ALL tasks — repoint them all. Verify with a manual trigger (`Start-ScheduledTask`), not by waiting for the next window.
6. **Services/MCP.** If the project exposes a server/endpoint: verify that it starts and responds.
7. **Sync health.** If the files live in a sync folder: confirm that the structure in the cloud is intact and that the client's logs do not show growing deletions.
8. **Functional smoke test.** Run the smallest "hello world"/unit test. Report the outcome.

## Report format
Table: `Step | Status (PASS/FAIL/WARN) | Detail/action`. End with "Ready to run: YES/NO" + an action list.

## Common actions on FAIL
- old path → central config or relative path.
- venv broken → recreate.
- node_modules broken → `npm ci`.
- task points wrong → update the Action, verify with a manual trigger.
- sync trashes/flattens → shut the client down immediately, restore the cloud parent-first.
