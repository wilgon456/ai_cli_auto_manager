# Contributing

Bug reports and small, focused pull requests are welcome. For security or deletion
boundary bugs, follow [SECURITY.md](SECURITY.md).

## Before changing a CLI integration

Confirm package names, executable aliases, and update commands against the
vendor's official documentation. Distinguish the CLI on PATH from inactive copies,
and distinguish npm, Homebrew, WinGet, and standalone installs. A package rename
must not silently move an existing user to another installation or major version.

The shared catalog is `rules/ai-clis.conf`. Built-in updaters also have dedicated
Shell and PowerShell paths. Keep both platforms consistent when changing behavior.

## Compatibility and safety

- Keep Unix scripts compatible with the Bash 3.2 bundled with macOS.
- Keep Windows scripts compatible with Windows PowerShell 5.1 and PowerShell 7.
  Write `.ps1` source as ASCII because Windows PowerShell 5.1 reads BOM-less files
  using the system ANSI code page.
- Reproduce bugs in a temporary home using fake CLIs and package managers. Tests
  must never update the contributor's real CLIs, touch real schedules, or kill
  real processes.
- Test both supported behavior and refusal cases: linked ancestors, unexpected
  SQLite sidecars, open files, protected data, and inactive package copies.
- Keep error messages actionable and make unsupported update channels visible.
- Byte counts must stay exact above 2 GiB: never sum sizes with awk `printf "%d"` (a 32-bit
  conversion in some awks); use `aicm_sum_lines`. Do not allocate multi-GiB files in tests; use sparse
  files where the file system supports them, and only on macOS/Linux.
- `aicm optimize` runs only its fixed allowlist. A new task needs an official, supported command, a
  busy-process name list, a fake-tool test of its exact arguments, and must never download (keep the
  Corepack/npm/uv offline guards). Never add a shell string, `eval` or `shell: true`.
- Node.js stays optional for update, inventory and ordinary cleanup; a new feature that needs it
  (like optimize) must say so in `--help`, the READMEs and docs/compatibility.md.

## Checks

On macOS or Linux:

```sh
shellcheck -x bin/aicm bin/*.sh lib/*.sh tests/*.sh
bash tests/clean_test.sh
python3 tests/cleanup_safety_test.py
bash tests/cache_budget_test.sh
pwsh -NoProfile -File tests/cache_budget_test.ps1   # portable engine checks, if pwsh is installed
bash tests/aicm_test.sh
bash tests/inventory_test.sh
python3 tests/npm_recovery_safety_test.py
bash tests/codex_host_test.sh
bash tests/maintenance_integration_test.sh
bash tests/update_verify_test.sh
bash tests/update_policy_test.sh
node --test tests/node/*.test.js
python3 scripts/check_manifest.py
python3 tests/release_packaging_test.py
```

On Windows, run `tests/clean_test.ps1`, `tests/cache_budget_test.ps1`, `tests/aicm_test.ps1`,
`tests/inventory_test.ps1`, `tests/update_policy_test.ps1`, `tests/home_ownership_test.ps1` and
`tests/unicode_paths_test.ps1` in Windows PowerShell 5.1 and PowerShell 7. Run `powershell -NoProfile -File tests/maintenance_json_test.ps1` and `pwsh -NoProfile -File tests/maintenance_json_test.ps1` there too. Run the Node
tests there too. Expand the Node glob with `Get-ChildItem tests\node\*.test.js`; do not pass a quoted glob through as a literal path. CI defines the currently configured platform matrix.

Update the changelog for behavior changes and the SHA-256 entries in
`MANIFEST.json` for changed or added release files. Run the manifest check after
the final edit (it also lists new files that are not ignored yet). Do not include local logs,
credentials, `docs/social/` or unrelated files. Releases follow
[docs/release-checklist.md](docs/release-checklist.md).

Describe the failure being fixed, the resulting behavior, tests run, and platforms
you could not exercise. Passing fixture tests is not the same as testing every
vendor's current installer on a real machine.
