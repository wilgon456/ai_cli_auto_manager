# Changelog

## 2.10.1 - 2026-10-28

- Replace the Windows scheduled-task VBScript launcher with a GUI-subsystem executable compiled by
  the .NET Framework compiler. It starts PowerShell without a console window and returns the child
  exit code. Installation fails closed if the compiler or launcher is unavailable.
- Before migrating the manager's Windows tasks, save task XML and the installed app, then replace
  only the action while preserving arguments, triggers, principal and settings. The launcher stays
  outside the app so an update does not replace a running executable. Backups are retained for rollback.
- Third-party tasks are not migrated automatically. The Windows migration guide describes how to
  inspect them and retain any existing dry-run arguments.
- A separate checkout can install the reviewed copy with `schedule refresh -PreserveSource` while
  retaining the original update-source path. A running task blocks manual refresh. The old
  `AI CLI Auto Update` task is no longer removed automatically; review it separately.
- A standalone migration can change only managed task actions without replacing a customized
  installed app. Its backup can be restored with the `-ActionsOnly` option.
- Serialize manager schedule and app-copy changes for the same home, avoid new backups on an
  already-completed standalone migration, and report legacy task actions even if the stored state
  says the launcher is windowless.
- Verify launcher and backup hashes with .NET so migration also works when PowerShell does not
  auto-load the Windows utility module containing `Get-FileHash`.

## 2.10.0 - 2026-10-27

### Integration with v2.9.0
- Preserve contained CLI sessions and hourly report-only automatic maintenance from upstream.
- Share the maintenance lease across automatic maintenance, cleanup, archive, restore and optimize.
- Validate arguments and management-home ownership before containment writes session records; previews
  keep their no-write behavior. Actual contained Unix CLI commands require Node.js.

### Final compatibility review
- Legacy installed copies without a file roster accept only exact known file names as a fallback,
  never arbitrary script extensions or a SOURCE pointer back to the copy itself. User scripts remain
  untouched when sync refuses such a copy; Bash and PowerShell have matching regressions.
- Buffer npm candidate-name readers in install-owner detection and interrupted-install recovery,
  plus pending-state and scheduler-health output. Repeated fast process substitutions in captured
  Bash 3.2 updater runs reproduced AST/memory faults and CPU spins; the buffered variant passed 40
  isolated repetitions and 40 repetitions asserting the Homebrew route. The precise Bash runtime
  defect remains unconfirmed. Candidate producers return success after emitting legacy aliases,
  preserving Amp/OpenCode ordering; inventory tests repeat captured updates and assert brew routing.
- Budget depth probes and candidate enumeration now retain errors and time limits. Failed or partial
  candidate enumeration deletes nothing, including when the command emitted some candidates first.
  New independent boundary regressions cover these cases.

### Cache budgets and opt-in optimize (phase 2)
- **`budget` cleanup kind** (Bash and PowerShell). Keeps one independent-file cache folder at or below
  `limit` MiB of logical bytes; `days` (at least 1) is the minimum age, `limit` at least 1 (zero, empty
  or malformed values are refused). No default rule uses it and default schedules are unchanged; switch
  `npm-cache`/`pip-cache` in `clean-rules.local.conf` to use it. Every ordinary file counts toward the
  total (protected, recent, hard-linked, SQLite and open ones too); candidates match the pattern, are
  older than `days`, have one link and are neither protected nor SQLite files/sidecars. They go oldest
  modification time first (not LRU) until the total is within budget. Each one is checked again
  (identity, size, time, no link below the root, root not moved or linked) and must not be open:
  `lsof` on Unix (missing/failing means nothing is deleted), an exclusive single-link FileGuard handle on
  Windows. A read error, a `stat` failure or a scan bound (`AICM_BUDGET_MAX_FILES` 200000,
  `AICM_BUDGET_MAX_DEPTH` 32, `AICM_BUDGET_SCAN_SECONDS` 300) makes the scan `partial` and nothing is
  deleted by that rule; other rules still run. JSON rows add `totalBytes`, `budgetBytes`,
  `remainingBytes`, `projectedRemainingBytes`, `budgetUnmetBytes`, `scanStatus`. A budget is per cache
  folder, not per CLI. `cap` stays per file.
- **Byte sums above 2 GiB.** `aicm_sum_lines` printed with awk `%d`, which mawk clamps at 2147483647;
  it now prints exact whole numbers up to 2^53 (status totals, cleanup counts).
- **`aicm optimize` / `aicm.ps1 optimize`.** Opt-in, preview by default (also `--dry-run`/`-DryRun`);
  `--apply`/`-Apply` runs only `npm cache verify`, `uv cache prune`, `pnpm store prune`
  (`--tasks npm-verify,uv-prune,pnpm-prune` / `-Tasks`), `--json`/`-Json` one document. Invalid task
  lists and `--apply` with `--dry-run` are refused before anything is written. The preview only looks
  tools up on PATH. Apply claims `AICM_HOME`, refuses during an update/cleanup/archive/restore, holds
  the maintenance lock until the last command has stopped (also on failure or interruption), skips a
  task while that package manager runs or when the process table cannot be read, runs offline (Corepack
  network/project selection/env-file off, npm/pnpm offline, pnpm bootstrap off, uv offline) with a time limit that stops the whole process group, and
  never counts a missing, failed, timed-out or skipped task as success. Windows `.cmd`/`.bat` shims go
  through `%SystemRoot%\System32\cmd.exe` with a quoted path; cmd.exe metacharacters in the path are
  refused. Needs Node.js (`lib/optimize.js`); update, inventory and ordinary cleanup still do not.
  Package-manager ancestors and unreadable Node/Bun command lines also hold affected tasks. Child
  guards override inherited environment keys case-insensitively; Windows process JSON uses UTF-8.
  SIGINT/SIGTERM stop owned children before releasing the lease. No schedule runs it.
- **Release tooling.** `scripts/build_release.py` builds reproducible `.tar.gz`/`.zip` source archives
  and `SHA256SUMS` from `MANIFEST.json` only; `scripts/check_manifest.py` now also reports new files that
  are not ignored and not in the manifest. New `docs/release-checklist.md`.
- Tests: `tests/cache_budget_test.sh`, `tests/cache_budget_test.ps1` (Windows PowerShell 5.1, PowerShell
  7, and the portable checks on PowerShell 7 for macOS/Linux), a real open file and live SQLite case in
  `tests/cleanup_safety_test.py`, `tests/node/optimize.test.js` with fake tools and process tables,
  dispatcher cases in `tests/aicm_test.sh`/`.ps1`, `tests/release_packaging_test.py`; CI runs them.
- Follow-up, not in this release: OS DNS cache flush, macOS QuickLook reset, SQLite `VACUUM`.

### Public release hardening (phase 1)
- **Management folder ownership.** An existing folder is used as `AICM_HOME` only when it is new or
  empty, carries a valid `.aicm-home` marker, or is an unmarked older install recognized by its
  installed copy (`app` with `SOURCE`/`VERSION`) with nothing but the tool's and the user's known
  entries. A folder name, a reserved folder alone (`archive/<rule>/<date>`), a marker with other content
  or the home/profile folder itself is never ownership. Help, bad arguments and previews never create
  the marker (`aicm update --help` used to mark an existing folder). `update`, `inventory`, `clean`,
  `worktrees`, `config`, `processes` and `schedule install` refuse a foreign folder before writing into it.
- **No blind whitelist.** The installed copy records its file list in `app/.aicm-copy`; a sync, uninstall
  or purge refuses (and keeps) an `app`, `app.new` or `app.old` that holds anything a copy does not
  (`app/personal.txt`, `app/lib/notes.txt`) or a link. Copies from older versions without the list are
  checked against their source checkout and the tool's file names.
- **Purge.** `uninstall --purge` removes only log and state files under the names the tool uses and
  archived files the archive index lists (same size). Unindexed and personal files in `logs/`, `state/`
  and `archive/` (also in a dated folder) and linked entries are kept and listed. Everything is checked
  before any job or file is removed. New `uninstall --purge --dry-run` / `-Purge -DryRun` changes
  nothing: no jobs, copy or data removed, no marker, log or state written. A Windows `AICM_HOME` chosen
  as a junction still works; links inside it are never followed.
- **SQLite families in date rules (macOS/Linux).** `age` and `age-files` now treat `*.sqlite`,
  `*.sqliteN` and `*.db` with `-wal`/`-shm`/`-journal` as one unit, like the cap rule and Windows did:
  every member must be eligible (age, pattern, protection), regular and proven idle with `lsof`. A fresh
  WAL, an open connection, a missing or failing `lsof`, or a linked/unexpected sidecar keeps the whole
  family. Other cache files are still removed in one batch. This was a gap in the date rules only; the
  cap rule (Codex trace databases) already grouped families.
- **Archive index at scale.** `archive list` reads the index newest first and pages it (`--limit`,
  `--offset`, JSON `index.nextOffset`). A file is called legacy only when every manifest (up to 100000)
  and the bounded archive walk were read; otherwise `legacy.complete` is `false` and nothing is guessed.
  Before, 10000 old records hid newer ones and their files were shown as legacy. New `archive gc`
  (`--dry-run`, `--json`; Windows `archive gc -DryRun -Json`) drops records whose dated archive folder
  retention already removed and records restored more than 30 days ago, oldest first, at most 10000 per
  run, under the maintenance lock or the cleanup's lease. A real clean that ran an archive rule runs it.
  Pending, still-restorable, malformed records and other files are never removed. Direct restore by id
  is unchanged.
- **Windows encoding.** SOURCE, VERSION, `.aicm-copy`, the marker and state JSON are read and written
  as UTF-8 without a BOM on PowerShell 5.1 and 7; Node.js/npm child output is decoded as UTF-8, other
  programs keep the PowerShell default. A Korean clone or npm prefix no longer looks "gone" or
  standalone on Windows PowerShell 5.1. If npm lists packages but its prefix cannot be a folder, the
  update stops with an error rather than update through a guessed owner.
- **doctor.** Fails on an invalid `update-policy.json` (wrong type, alias conflict, unknown id, bad JSON)
  or one that needs a missing Node.js, on a foreign `AICM_HOME`, and on jobs whose installed copy is
  gone; shows the installed copy, its source and both versions, and Node.js. It changes nothing. Windows
  task failures were already reported through `LastTaskResult`.
- Tests: `tests/home_ownership_test.ps1`, `tests/unicode_paths_test.ps1` (CI: Windows PowerShell 5.1 and
  PowerShell 7), `tests/node/archive-index.test.js`, live-SQLite cases in `tests/cleanup_safety_test.py`,
  ownership/doctor cases in `tests/aicm_test.sh`/`.ps1`. Fixtures that pre-populate a home before its
  first run now write the marker, as an existing install would have.

### Cleanup categories, JSON and local history
- `aicm clean --category sessions,cache,logs,temp,other` (or `all`). A subset does not enable disabled rules and does not purge unrelated archives. `--rules id,id` still enables only those ids. PowerShell: `-Category cache,logs` or `-Category 'cache,logs'`.
- `--explain` prints one line per selected rule (category, age, limit, action, protection, reason). It does not list files. `--json` prints one document with the same per-rule fields plus counts from that pass. Previews do not write state, logs or the home marker.
- A real clean stores `scopeCategories` and `scopeRules` on `last-clean.json`. A cache-only or rule-only run does not satisfy a weekly full clean or a different category. A last-clean file with no scope is treated as a full clean.
- Generic archive moves need Node.js and `lib/maintenance.js` (`archive-put`). Without Node the file stays and old generic archive folders are not purged. Codex's own archive/delete path is unchanged. Restore never overwrites an existing file.
- `aicm archive list [--json]`, `aicm restore ID [--dry-run] [--json]`, `aicm history [--limit N] [--json]`. Windows: `archive list -Json`, `restore ID -DryRun -Json`, `history -Limit N -Json`. Legacy files are listed for a manual move. Codex-native sessions are not generic restore ids. Local history keeps 100 entries for update, clean, and restore, and does not store file contents.
- Schedule: `--clean-category sessions,logs` / `-CleanCategory cache,logs`. Quoted strings and arrays are normalized. An empty `--category=` or a missing `--clean-category` value is rejected. Invalid schedule options do not create the home marker.

### Update verification
- Record the PATH-selected command path and version before and after, plus a bounded exit. A command that was present and is then missing, failed, empty, or timed out is a failure. A reported install success with no command is a failure. An unchanged version is not proof of the latest release. A previously failing command that works afterward is repaired. Hooks run only after a healthy change. Local update history needs Node.js. No automatic rollback; optional per-CLI pins are described below.

### Per-CLI update policy
- Optional `update-policy.json` (`schemaVersion: 1`) in the management home: `tools.<id>.{exclude,pin,minReleaseAgeDays}`. Validation is strict and runs before any log, lock or state file; a directory, dangling link or truncated reader output fails closed. Node.js is required only when the file exists.
- Exclusion wins over explicit targets, install-missing, interrupted-install recovery, and Codex cask quarantine/recycle, including the same-day fast path. Excluded CLIs are not probed, so a broken `--version` cannot fail the run.
- Pins are exact stable npm releases only (plus Amp's timestamp/hash train), must be published, not deprecated and past the effective waiting period, never fall back to latest, and never downgrade. Pins and positive per-tool ages hold non-npm routes; an explicit `0` permits them. Interrupted recovery under a pin is held for manual install with the backup and known state kept.
- Per-tool ages override the global waiting period. Dry runs print effective rules and hold reasons. The stored fingerprint covers the normalized policy and global age, so a changed or removed policy reruns the same day. Post-update hooks fire only for rows that actually updated.
- npm backup housekeeping is suspended while any rule is configured.

### Follow-up
- Cache capacity limits that keep busy and protected data landed as `budget` rules (phase 2 above). Optional TUI later.
- Design references only; no code was copied: [topgrade](https://github.com/topgrade-rs/topgrade), [agent-session-cleaner](https://github.com/haowang02/agent-session-cleaner), [codex-clean](https://github.com/Merlin-Arthur05/codex-clean), [ClaudeCode-Project-Cleaner](https://github.com/cherlix/ClaudeCode-Project-Cleaner), [bleachbit](https://github.com/bleachbit/bleachbit).

### Compatibility and cleanup fixes
- Recognize Amp's current npm package while preserving legacy installation ownership.
- Accept Amp's timestamp/hash release train only for its two known npm package names,
  retaining release-age checks and excluding unrelated prereleases.
- Keep the selected OpenCode major version when V1 and V2 npm packages coexist.
- Read OpenCode V1 and V2 MCP configuration, including JSONC files.
- Add Copilot's official Homebrew and WinGet channels to the shared catalog.
- Select CLI update channels from resolved ownership when Homebrew and npm share a prefix.
- Reject linked archive ancestors and destinations before moving or purging user data.

### Public distribution preparation
- Start the README examples with update/inventory schedules only; explain permanent
  history deletion before enabling the cleanup schedule.
- Document supported installation channels, runtime requirements, testing limits,
  contribution checks, and vulnerability reporting.
- Verify the release manifest in CI so missing files and stale checksums fail validation.

## 2.8.2 - 2026-10-11

### Fixed: cleanup boundaries and running files
- Cleanup refuses symlinks and junctions anywhere below the trusted home/temp root, including
  parent folders of a rule path. A plain rule folder behind a link can no longer delete outside files.
- Size/age-capped files and their SQLite WAL/SHM/journal are checked together before deletion.
  macOS/Linux use `lsof` and keep the group if the check is missing, fails, or finds an open file.
  Windows acquires exclusive read/delete handles and marks all members for deletion together; any open member keeps
  the whole group, including when another application allows delete sharing.

- Recursive browser/archive cleanup now checks the entire tree before deleting files and keeps
  protected, linked or busy units intact. Installed-copy removal uses a separate management path.
- Windows age rules delete eligible SQLite families together and preserve the family when any
  member is readonly, fresh, excluded by the pattern, or an unexpected directory/link.
  Capped cleanup also preserves unexpected sidecars on macOS/Linux.
- Windows deletion opens reparse points themselves and holds ancestor directories against rename
  during file deletion. Readonly members are rejected before any deletion mark.
- Repeated installed-copy synchronization works under an explicitly selected AICM_HOME junction;
  aliases below that root remain blocked. PowerShell 7 now runs schedule regressions in CI.

- Windows task refresh preserves custom settings, principals and disabled state. Hidden npm recovery is skipped when PATH uses another installation.

### Fixed: Paseo 0.11 compatibility
- Codex recycling uses `paseo daemon restart` on current Paseo, and detects the legacy restart command for older installations.

### Fixed: update the installation the user runs
- An inactive Homebrew installation no longer takes priority over the Codex, OpenCode or Claude
  copy on PATH. An inactive npm Codex copy is reported rather than silently updated on both platforms.
- Codex server recycling only targets an older version under the same Homebrew cask root whose
  executable has been removed by an upgrade.
  Other cask roots, npm, standalone, application bundles, newer versions and unknown versions stay.
- Unix tests always shadow Homebrew; cleanup tests shadow uv. Inventory tests cover duplicate
  installations and an active Homebrew install without reaching real package managers. Added
  live SQLite/WAL and symlink ancestor regressions, plus Windows junction and open-WAL cases.

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
