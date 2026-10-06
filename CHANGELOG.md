# Changelog

## 2.2.1 - 2026-10-06

### Fixed
- Deleting a Codex session also deletes the sub-agent sessions it spawned, so a later delete of
  one of those failed and was reported as "in use or failed". Such ids are re-checked against the
  database and counted as removed when they are gone.

## 2.2.0 - 2026-10-06

### Added
- Safer npm updates (`lib/npm-guard.js`, shared by both platforms):
  - only releases at least 3 days old are installed (`AICM_MIN_RELEASE_AGE_DAYS`,
    `-MinReleaseAgeDays`, `--min-release-age-days`; 0 = newest); the inventory shows newer
    releases in their waiting period as `held`;
  - a release is blocked when it loses the provenance attestation the installed release had, or
    adds or changes a preinstall/install/postinstall script (this catches the Cline CLI 2.3.0
    incident); `AICM_ALLOW=pkg@version` accepts a reviewed release;
  - the candidate is installed into a temporary folder with `--ignore-scripts` and checked with
    `npm audit signatures` before the global install (`AICM_VERIFY_SIGNATURES=0` skips it).
- Two-stage cleanup for conversation history: rule kind `archive` moves old session files to
  `~/.ai-cli-auto-manager/archive/<rule>/<date>/` and deletes archive folders after `limit` days.
- Rule kind `codex`: Codex sessions are archived with `codex archive` and deleted with
  `codex delete --force`, never by removing files. Sessions whose file is already gone are deleted
  on the same schedule (reads Codex's database read-only with Python or sqlite3 when available).
- Archive ages follow the CLIs' own retention settings (Claude Code `cleanupPeriodDays`, Gemini CLI
  `sessionRetention.maxAge`, Qwen Code `cleanupPeriodDays`): archiving happens a week before the
  CLI would delete the files itself.
- New rule `copilot-sessions`; `status` shows the archive size.

### Changed
- `claude-transcripts`, `gemini-tmp`, `qwen-tmp`, `grok-sessions`, `codex-images` archive instead
  of deleting; `codex-sessions` uses Codex's commands; `codex-archived` is gone (covered by `codex-sessions`).

### Fixed
- Deleting Codex rollout files directly (1.x, 2.0, 2.1) left sessions in Codex's database that
  could not be opened. 2.2 stops doing that and removes such entries once they are 90 days unused.

## 2.1.1 - 2026-10-06

### Fixed
- The update now follows the copy the terminal runs. When Claude Code or OpenCode on PATH is a
  standalone install, its own updater runs (`claude update`, `opencode upgrade`) even if a second
  npm copy exists; before, only the unused npm copy was updated.
- Duplicate installs that the daily update cannot reach (for example the Codex desktop app's copy
  on PATH with a newer npm copy behind it) are reported by the update run, listed in the inventory
  with a concrete fix, notified once when they appear, and reported by `doctor` until resolved.

## 2.1.0 - 2026-10-06

### Added
- Weekly **inventory** (`aicm inventory`, `bin/inventory_ai_clis.*`): finds every AI CLI in the new
  catalog `rules/ai-clis.conf` (18 CLIs, extendable with `~/.ai-cli-auto-manager/ai-clis.local.conf`)
  and reports version, latest published version, install method, and whether the daily update
  actually reaches the copy on PATH. Flags stale npm copies hidden behind another copy, lists
  other global npm packages, writes `inventory.md` and `state/inventory.json`, and notifies when
  a CLI appears or disappears.
- `schedule install` registers a third job, `Inventory` (weekly, Monday 12:00 by default);
  `--inventory-day/--inventory-at` (`-InventoryDay/-InventoryAt`) and `--no-inventory` (`-NoInventory`).
- The daily update now covers every installed catalog CLI, not just the six built-in ones:
  npm, Homebrew or winget, whichever installed the copy on PATH, or the CLI's own updater.
  New CLIs are installed only when named explicitly with `--install-missing`.
- Cleanup rule `qwen-tmp`.
- `status` shows the last inventory; `doctor` flags an overdue inventory and catalog errors.

### Changed
- Default update target is `all` (every installed catalog CLI).
- Grok Build is updated through npm when the copy on PATH is the npm one.
- Timed commands use `timeout`/`gtimeout`/`perl` before `python3`, because a fresh Mac's
  `/usr/bin/python3` opens an install dialog.

### Fixed
- Windows: `--version` and self-update calls failed for npm-installed CLIs (the `.ps1` shim was
  started directly) and timed calls lost their exit code.
- Windows PowerShell 5.1: writing state with an empty list failed ("Argument types do not match").

## 2.0.0 - 2026-10-06

Renamed from **AI CLI Auto Update** (`ai_cli_auto_update_public`) to **AI CLI Auto Manager** (`ai_cli_auto_manager`).

### Added
- `aicm` / `aicm.ps1`: one entry point for `update`, `clean`, `status`, `doctor`, `schedule`, `version`.
- Cleanup of stale AI CLI leftovers driven by one rules file shared by Windows and macOS/Linux
  (`rules/clean-rules.conf`), with per-machine overrides in `~/.ai-cli-auto-manager/clean-rules.local.conf`.
  Rule kinds: `age`, `cap`, `keep-latest`, `command`.
- Safety: never follows symlinks or junctions, refuses paths outside the home and temp folders,
  never removes memory/credential/settings files, skips files in use.
- `schedule install|remove|show` for Task Scheduler, launchd and cron (daily update, weekly cleanup).
- Each run checks that the other scheduled job still exists and shows a desktop notification
  when a job is missing or a run fails. `doctor` reports overdue or failed runs.
- Optional post-update hook (`hooks/post-update.ps1` / `hooks/post-update.sh`).
- Tests for both platforms against a throwaway home folder; CI on Ubuntu, macOS (bash 3.2),
  Windows PowerShell 5.1 and PowerShell 7.

### Changed
- npm-managed CLIs are not reinstalled when they are already current.
- Logs and state moved from `~/.ai-cli-auto-update` to `~/.ai-cli-auto-manager` (override with `AICM_HOME`).
- Windows tasks live in the `\AI CLI Auto Manager\` folder; `schedule install` replaces the old
  `AI CLI Auto Update` task unless `-KeepLegacyTask` is given.

### Kept for compatibility
- `bin/update_ai_clis.sh`, `bin/update_ai_clis.ps1` and `windows/install_scheduled_task.ps1`.

### Removed
- `launchd/com.example.ai-cli-auto-update.plist` (generated by `aicm schedule install` now).
