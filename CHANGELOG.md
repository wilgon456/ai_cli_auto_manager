# Changelog

## 2.8.1 - 2026-10-10

### Fixed: the Codex quarantine clear rejected every new build
- 2.8.0 ran `codesign -R "=notarized and ..."` without `--check-notarization`. The cask binaries
  carry no stapled ticket, so codesign only looked in the local ticket store. A build Gatekeeper had
  never assessed is not in it yet, so every new Codex version was reported as `not a notarized OpenAI
  build` and left quarantined. This happened on every run from the 0.162.0 upgrade on. The check now
  passes `--check-notarization`, which looks the ticket up online.
- Scheduled retries that end early after a complete run now clear the quarantine too, so a Codex
  cask upgraded by hand later that day is fixed within 3 hours instead of waiting for the next
  day's run. The check prints nothing when there is nothing to clear.
- Corrected root cause: the host hang is the Gatekeeper first-open prompt, not a stalled network
  check. syspolicyd logs `GK eval - was allowed: 1, show prompt: 1` and waits for a click. On a
  Mac that is unattended or used remotely, nobody clicks, and Codex gives up after 30s.

## 2.8.0 - 2026-10-09

### Fixed: Codex lost its terminal and edit tools after every Homebrew upgrade
- Homebrew puts `com.apple.quarantine` on the cask build. On the first exec of
  `codex-code-mode-host`, Gatekeeper checks notarization online. When that request stalls, the exec
  hangs. Codex gives up after 30s with `timed out negotiating with the code-mode host`, and the kernel
  logs `ASP: Security policy would not allow process`. Nothing gets cached, so every shell and
  apply_patch call on that version failed, even on a freshly restarted app-server. The 2.7.0 recycle
  could not fix this.
- Each run now clears the attribute from the Codex cask's version folder. It does this only after
  `codesign` confirms the binary and its host are notarized and signed with OpenAI's Developer ID
  (team `2DC432GLL2`). Anything else is left quarantined and the step fails. The step runs before the
  app-server recycle. A running server picks up the fix on its next tool call because it starts a new
  host each time. `AICM_CODEX_UNQUARANTINE=0` turns it off.

## 2.7.0 - 2026-10-07

### Added
- After a Homebrew Codex upgrade, `codex app-server` processes that still map the replaced binary are
  recycled. `brew upgrade` deletes the old cask folder, and such a server (Paseo keeps one) keeps
  spawning `codex-code-mode-host` from there, so its terminal tools fail until it restarts. The Paseo
  daemon is restarted first; servers still stale after that (reparented to launchd/init) are stopped
  with TERM. Servers on the current Codex and the ChatGPT app's bundled copy are left alone.
  `AICM_CODEX_RECYCLE=0` turns it off. Ported from the retired `ai_cli_auto_update` scripts.

## 2.6.2 - 2026-10-07

### Fixed: two CLIs the daily update did not reach
- OpenCode 2.x is published as `@opencode/cli` (`opencode-ai` is the 1.x line). An npm install of
  2.x fell through to `opencode upgrade`, which cannot tell how it was installed and failed every day.
  The update now keeps `@opencode/cli` current through npm, and `--install-missing` installs it.
- Codex installed with the official installer (`~/.codex/packages/standalone`) was taken for the
  desktop app's copy and skipped. It is now updated with `codex update` (macOS and Linux) and the
  inventory reports it as covered; a copy elsewhere is still left to the desktop app. `codex update`
  reruns the official install script, so it is gated like the Grok installer: it runs only when a
  newer release is past the waiting period and the installer would not fetch a newer, younger one.

## 2.6.1 - 2026-10-07

### Fixed
- The scheduled update on macOS and Linux put `/usr/local/bin` and `/opt/homebrew/bin` in front of the
  PATH captured at install, so it updated a stale copy instead of the one the user runs (a Claude Code
  in Homebrew's npm prefix instead of the nvm one, failing on permissions; an old brew `grok` instead
  of `~/.grok/bin/grok`). The captured PATH now comes first and the system folders only widen it.

## 2.6.0 - 2026-10-07

A round of fixes from three critical reviews (update path, cleanup and inventory, scheduling and
health checks). Several of them could have deleted user data or silently stopped the jobs.

### Fixed: cleanup could delete what it should not
- Worktree cleanup kept no eye on ignored files: `git worktree remove` deletes them although
  `git status` calls the tree clean, so a `.env` or a local database went with it. A worktree with
  ignored files other than build output is now kept. Proofs need a successful fetch of every remote,
  a merged PR counts only for origin's own repository and when it was merged into the default branch,
  a folder in use is kept (rename test), and every removed commit stays under
  `refs/aicm-deleted/<date>/` for 90 days.
- A TEMP/TMPDIR pointing at a drive root, `/`, the home folder or a folder above it made the temp rule
  sweep the home folder. The temp folder now counts only when it really is one; paths compare by their
  long names.
- Age rules deleted old files one by one inside folders still in use (an open session, a plugin
  checkout). Each entry in a rule's folder is now one unit and goes only when nothing in it changed.
  New kind `age-files` keeps per-file deletion for content-addressed caches (npm, pip).
- A clock far off (earlier than the last run, or 400+ days past it) deletes nothing.
- More protected names: `.npmrc`, `.netrc`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`...; `memory`
  folders in any letter case, never pruned.
- Codex: `{codex}` follows `CODEX_HOME`; the newest state DB is chosen by number; unknown layouts and
  non-numeric dates are left alone; a thread counts as orphaned only when no file with its id exists.
- `uninstall --purge` removes only what this tool wrote, and only in a folder it marked as its own.
- The left-behind process check no longer flags macOS app bundles, programs whose arguments merely
  mention an agent name, sessions under WSL's per-session init, or processes of unknown age.

### Fixed: the daily update
- Windows: an npm warning on stderr no longer breaks the release check (stdout and stderr are kept apart).
- A timeout ends the whole process tree, not just the launcher. `npm install -g` and brew have time
  limits; a run holding the lock for 3+ hours is reported instead of blocking every later run quietly.
- The waiting period also covers dependencies (`npm install --before=<date>`); unpublished and
  deprecated versions are never picked; prereleases sort below their release.
- Registries without signing keys are reported once as "signatures not checkable", not as failures.
- "Already updated today" uses the local date on both platforms and only counts a run that covered
  the same CLIs; no-op retries write no log.
- npm's rollback backup is never deleted while the package itself is missing; a managed CLI that
  disappears is reinstalled from it or reported.
- Logs written by cron and launchd are trimmed.

### Fixed: scheduling and health checks
- cron and launchd jobs get the PATH recorded at install (nvm, volta, Homebrew on Apple Silicon...).
- Windows tasks fall back to `powershell -WindowStyle Hidden` when Windows Script Host is disabled;
  the doctor reports it.
- The installed copy is never downgraded, is swapped atomically with rollback, and the jobs are
  re-registered after an update when their definition changed (`aicm schedule refresh`).
- Health checks also see disabled tasks, missing scripts, failed last results and a stopped cron daemon.
- On cron, weekly jobs catch up after the machine slept through their time.
- Linux notifications reach the desktop from cron; every notification is also logged
  (`logs/notifications.log`, shown in `status` and `doctor`).
- The legacy Windows installer no longer removes the Inventory and Clean tasks.
- Times outside 00:00-23:59 are rejected; notification texts no longer change between runs.

## 2.5.1 - 2026-10-07

### Fixed
- The post-update hook runs only when a CLI version actually changed. With retries during the day it
  would otherwise reload daemons such as Paseo several times a day for nothing.

## 2.5.0 - 2026-10-07

Hardening for months of unattended use, from a review of real logs: the previous updater on the first
test machine had ended with a failure on 59 of 59 days.

### Fixed
- Windows: a CLI that is running is no longer overwritten. The update is deferred (not failed) when a
  process runs from the package folder or npm reports EBUSY/EPERM; a reminder comes after 5 days.
- npm errors on stderr no longer abort the Windows updater before they are handled.
- The registry being unreachable is recorded as pending, not as a failed update.
- Worktree cleanup only trusts "every commit is on a remote" right after a successful `git fetch --prune`;
  a branch deleted on the remote (closed PR) but still in a stale `origin/*` ref is kept.
- Per-user lock folders on macOS/Linux (a shared /tmp lock owned by another user blocked runs).

### Added
- The update job retries every 3 hours for 15 hours (Task Scheduler repetition, launchd/cron hours);
  a run after a complete success the same day exits immediately (`-Scheduled` / `--scheduled`).
- npm staging leftovers (`node_modules/.<name>-XXXXXXXX`) older than a day are removed after updates.
- Jobs run an installed copy in `~/.ai-cli-auto-manager/app`; the daily update refreshes it when the
  source clone has a newer VERSION. Windows tasks start through `windows/run-hidden.vbs` (no window).
- Jobs also report a scheduled job that has not completed for too long (update 3 days, others 9).
- `aicm uninstall [--purge]`.

### Changed
- Notifications: a problem is announced when it appears, then at most once a week while it lasts.
- State files are written atomically (temp file and rename) by all implementations.
- Grok Build's vendor install script runs only when a newer release past the waiting period exists.

## 2.4.0 - 2026-10-07

For machines that run many agent sessions at once (Paseo, Orca, ...). The new checks are Node.js
modules shared by Windows and macOS/Linux and are skipped when Node.js is missing.

### Added
- Worktree and branch hygiene (`lib/worktrees.js`, `aicm worktrees`, weekly with Clean): prunes
  worktrees whose folder is gone; removes a linked worktree only when it is clean, unlocked, untouched
  for 14 days and its work is upstream (merged, its GitHub PR merged with exactly this commit, or all
  commits on a remote); unlinks links inside first; never uses `--force`; deletes local branches with
  the same proof. Reports worktrees with uncommitted work untouched for 30 days.
- Configuration drift report (`lib/config-drift.js`, `aicm config`, weekly with Inventory): MCP servers
  per installed CLI, skills some CLIs cannot see, same-named skills with different content.
- Left-behind process check (`lib/processes.js`, `aicm processes`, daily with Update): MCP servers,
  automation browsers and agent CLIs running 2+ hours after their session ended; `--kill` /
  `AICM_KILL_ORPHANS=1` ends them with their children.
- Node tests (`tests/node`) on all CI platforms.

## 2.3.1 - 2026-10-06

### Fixed
- A `codex` rule with `limit` 0 is shown as a deletion (`del`, "would remove"/"removed", with the
  sessions to delete counted) instead of as an archive.

## 2.3.0 - 2026-10-06

### Changed
- Conversation history unused for 30 days is deleted instead of archived by default:
  `codex-sessions` deletes with `codex delete --force` after 30 days (`limit` 0 = no archive stage),
  `gemini-tmp`, `qwen-tmp`, `grok-sessions`, `copilot-sessions` are plain 30-day `age` rules.
- `claude-transcripts` is off by default: Claude Code deletes its own transcripts (`cleanupPeriodDays`).
  Turning it on archives them a week before that.
- `claude-temp` age is 1 day.
- The README is in English; the Korean README moved to `README.ko.md`.

### Added
- `codex` rules accept `limit` 0 (delete directly after `days`).
- Archive folders older than the rule's `limit` are purged even when the archive rule is off,
  so remnants never stay behind.

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
