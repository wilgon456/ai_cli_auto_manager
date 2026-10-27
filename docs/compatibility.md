# Compatibility and first use

AI CLI Auto Manager maintains the copy of a CLI that your shell selects. An entry
in the inventory does not mean that every installation method can be updated.
Read the `daily update` column: unsupported channels are reported for manual
maintenance.

## Runtime and scheduling

| Environment | Runtime | Scheduler | Configured CI |
| --- | --- | --- | --- |
| macOS | Bash 3.2 or later | Per-user launchd agents | Configured: CI and local Intel Mac fixture tests |
| Linux | Bash with GNU utilities | User cron with a running cron daemon | Configured: Ubuntu CI fixture tests |
| Windows | Windows PowerShell 5.1 or PowerShell 7 | Windows Task Scheduler | Configured: Windows CI fixture tests (PowerShell fixtures and the Node adapter) |
| WSL | The Linux path above | cron must be installed and running | Configured: WSL-specific process fixtures; no full WSL installation test |

The table lists configured coverage. It is not a record that this checkout ran the changed maintenance or update-verification code on Windows or Linux.

The manager does not install Node.js or a package manager for you. Use Node.js
22.19 or later for the current catalog's npm-based CLIs; individual vendors may
raise their requirements. Node.js also enables worktree, process, MCP, and skill
checks. Those checks are skipped without it. Native CLI installations can still
use their supported update paths without npm.

On Unix, capped-file and recursive archive/browser cleanup needs `lsof` to prove
files idle. If it is missing or the check fails, those files are kept. Other age
rules have their own checks. SQLite orphan-session inspection needs `sqlite3` or
Python on Unix, and Python on Windows; an unknown schema is left alone.

Cache `budget` rules (opt-in, local rules only) need `lsof` on Unix as well: without it, or when it
fails, nothing is deleted by a budget. On Windows they use the same FileGuard handles as the other
rules. Their scan is bounded to the rule folder (200000 files, depth 32, 300 seconds by default); an
incomplete scan deletes nothing. Sizes are logical bytes and stay exact above 2 GiB.

`aicm optimize` (opt-in) needs Node.js; update, inventory and ordinary cleanup do not. It runs only
`npm cache verify`, `uv cache prune` and `pnpm store prune`, each when that tool is on PATH, offline,
with a time limit, and never while that package manager runs or when the process table cannot be
read (`ps` on Unix, explicit UTF-8 `Get-CimInstance Win32_Process` JSON on Windows). Package-manager
ancestors count as busy; unreadable Node/Bun command lines hold npm/pnpm tasks. Corepack project
selection and env-files and pnpm project-version bootstrap are disabled as well as network access. On Windows `.cmd`/`.bat` shims run
through `%SystemRoot%\System32\cmd.exe` with a quoted path; a path with cmd.exe metacharacters is
refused. Native runs of budget deletion and optimize on Windows and Linux are configured in CI but
were not run for this checkout.

A real cleanup takes the maintenance lease through Node.js (`lib/maintenance.js`).
Without Node, ordinary age and command cleanup still runs, and no lease is recorded. With Node, a real cleanup uses the shared maintenance lock. Generic
archive move and purge, restore, and history need Node. Those operations accept a management
directory only when it sits below the home directory or an approved temp directory,
and only when the directory and its components are real directories and files.
A link anywhere on that path is refused.

The Windows exception that allows a junction at the installed app copy, used by
schedule install and the app copy, does not extend to the maintenance lock, archive,
history, or other management data. This checkout does not claim a native Windows
or Linux run of those operations. Configured Windows CI covers PowerShell fixtures and the Node
adapter, not a full native maintenance pass.

## Installation channels

| CLI | Automated channels | Important limits |
| --- | --- | --- |
| Codex | npm; Homebrew and official standalone installer on Unix | Windows standalone/app-owned copies are left to their installer or app |
| Claude Code | npm, active Homebrew install on Unix, native self-update | OS package-manager installs may require that package manager |
| OpenCode | npm V1/V2, Homebrew `opencode`, native `upgrade` | V1 and V2 share the `opencode` name; a major-version migration is a separate user choice |
| Grok Build | npm or official installer | Vendor-installer updates do not receive npm signature/provenance checks |
| Kimi Code | npm | Standalone and legacy Python installations are not maintained by this manager |
| GitHub Copilot CLI | npm, Homebrew `copilot-cli`, WinGet `GitHub.Copilot` | Other installation methods need manual maintenance |
| Amp | npm `@ampcode/cli` and legacy `@sourcegraph/amp` | Standalone installs need their vendor's update mechanism |
| Other catalog entries | The channel explicitly recorded in the catalog | pip/pipx/uv, Scoop, Chocolatey, pnpm, Bun and OS packages are not generic update channels |

Homebrew and npm may share a prefix such as `/usr/local`. The resolved executable
must determine its owner, rather than the prefix alone. Inactive installations
must not be updated merely because they are present.

## Per-CLI update policy

An optional `update-policy.json` in the management home
(`~/.ai-cli-auto-manager` on macOS/Linux, `%USERPROFILE%\.ai-cli-auto-manager`
on Windows) can exclude a CLI, pin an exact npm release, or set a per-CLI waiting
period. Schema version 1 uses `tools.<catalog-id>`. Validation is strict and runs
before logs, locks or state. Node.js is required only when the file exists;
without it, native update paths behave as before.

`exclude` wins over explicit targets, `--install-missing`, interrupted-install
recovery, and Codex cask work. Pins are exact stable npm releases only (plus Amp's
timestamp/hash train): they must be published, not deprecated and past the
effective waiting period, never fall back to latest, and never downgrade. Pins and
positive per-tool ages hold native/Homebrew/installer routes; an explicit `0`
permits them. If an interrupted npm install belongs to a pinned CLI, recovery is
held and the backup and known state are kept for a manual `npm install -g`.
While any rule exists, npm backup housekeeping is suspended. The same-day retry
fingerprint includes the rules and the global waiting period.

This checkout does not claim that the policy code was run natively on Windows or
Linux here; configured CI covers fake-CLI fixtures on both, and the shared Node
module has platform-independent unit tests.

Configuration comparison reads user-level MCP settings, not every project's
effective settings. OpenCode V1 and V2 MCP schemas and JSON/JSONC are supported.
Managed settings, environment overrides, and vendor-specific merging can still
make an agent's effective configuration differ from the report.

## Non-ASCII paths on Windows

Windows PowerShell 5.1 reads BOM-less files and redirected child output with the
system ANSI code page. The manager therefore fixes the encoding per source:
files it writes and reads itself (`app\SOURCE`, `VERSION`, `app\.aicm-copy`, the
`.aicm-home` marker, state JSON) are UTF-8 without a BOM on both PowerShell
versions, and the output of Node.js and npm (which always write UTF-8 when
redirected) is decoded as UTF-8. Output of other programs (winget, the CLIs'
own `--version`, cmd, python) keeps the PowerShell default, because their
encoding depends on the program and the console. If npm lists global packages
but reports a prefix that cannot be a real folder, the owner of each CLI cannot
be told apart: `inventory` shows the owner as unknown and the daily update stops
with an error instead of updating through a guessed route.

`tests/unicode_paths_test.ps1` checks a Korean profile, `AICM_HOME`, clone and npm
prefix (its source stays ASCII; the text is built from code points). CI runs it
in Windows PowerShell 5.1 and PowerShell 7 on `windows-latest`. A local run in
PowerShell 7 on macOS/Linux only covers the portable parts and is not evidence for
Windows PowerShell 5.1.

## Start without deleting history

1. Keep a backup of conversation history you want to retain. Cleanup deletion has
   no automatic undo, and the npm waiting period is not a rollback mechanism.
2. Run `inventory`, `status`, and `clean --dry-run` (`clean -DryRun` on Windows).
   A dry run writes local reports/logs but does not perform cleanup.
3. Install only the update and inventory schedules first:

   ```sh
   ./bin/aicm schedule install --no-clean
   ```

   ```powershell
   .\bin\aicm.ps1 schedule install -NoClean
   ```

4. Review the cleanup rules and retention periods. The default Codex rule
   permanently deletes conversations unused for 30 days through Codex's own
   command. Once you accept that policy, run `schedule install` without
   `--no-clean`/`-NoClean` to enable all three schedules.
5. Use `doctor` to confirm the jobs exist and can find the required runtimes. To
   stop maintenance while keeping logs and local data, use `schedule remove`.

## What a passing test run means

CI tests use fake CLIs and package managers in disposable homes. They verify
channel selection, refusal cases, state handling, and scheduler command creation.
They do not install every current vendor binary or prove that every Linux
distribution, CPU, enterprise policy, or vendor installer works.

Before publishing a release, exact-release-commit checks remain required on Windows PowerShell
5.1, PowerShell 7, Ubuntu, and macOS. Configured CI does not replace them. Test real installation/update behavior on
disposable machines, then record versions and results in the release notes.
Verify the release file list with `python3 scripts/check_manifest.py`. The
manifest is an integrity check, not a cryptographic publisher signature. The full
release procedure is in [release-checklist.md](release-checklist.md).
