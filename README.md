<div align="center">

# AI CLI Auto Manager

**English** · [한국어](README.ko.md)

**Finds the AI coding CLIs installed on your machine every week, updates them safely every night,<br>
and clears the old sessions, temp files and caches they leave behind.**

[![ci](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml/badge.svg)](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-launchd-000000?logo=apple&logoColor=white)](#scheduling)
[![Windows](https://img.shields.io/badge/Windows-Task_Scheduler-0078D4?logo=windows11&logoColor=white)](#scheduling)
[![Linux](https://img.shields.io/badge/Linux-cron-FCC624?logo=linux&logoColor=black)](#scheduling)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](LICENSE)

</div>

---

After a few months with AI coding CLIs, three things get blurry: what you have installed, whether it is current, and how much disk it eats.
It is also common to have the same CLI installed twice (a desktop app copy and an npm copy), so updates land on one copy while the terminal keeps running the other, older one.
This tool schedules three jobs that take care of all of that. Clone the repository, run one command to schedule it, and nothing else needs installing.

| Job | Runs (default) | What it does |
| --- | --- | --- |
| Inventory | weekly (Mon 12:00) | Lists the installed AI CLIs with version, latest version, install method, and whether the daily update actually reaches the copy on PATH. Compares MCP servers and skills across the CLIs. Notifies you when a CLI appears or disappears |
| Update | daily (05:00) | Updates every installed CLI. npm-installed CLIs only get releases at least 3 days old, after red-flag and signature checks. One failure does not stop the rest. Also reports MCP servers, browsers and agent CLIs left running after their session ended |
| Clean | weekly (Mon 12:30) | Deletes conversation history unused for 30 days and expired temp files and caches, and removes git worktrees and branches whose work is already merged. Never follows links and never deletes memory, credential, settings files or unpushed work |

Every run checks that the other two jobs are still registered, and shows a desktop notification when a job is gone or a run fails.

## Quick start

### Windows

```powershell
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\bin\aicm.ps1 inventory           # installed AI CLIs (changes nothing)
.\bin\aicm.ps1 status              # schedules, last runs, disk use and what can be freed
.\bin\aicm.ps1 clean -DryRun       # preview what would be removed
.\bin\aicm.ps1 schedule install    # update daily 05:00, inventory Mon 12:00, clean Mon 12:30
```

### macOS · Linux

```bash
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager

./bin/aicm inventory
./bin/aicm status
./bin/aicm clean --dry-run
./bin/aicm schedule install
```

## Commands

| Command | What it does |
| --- | --- |
| `aicm inventory` | Lists the installed AI CLIs. `--offline` (`-Offline`) skips the latest-version lookups |
| `aicm update` | Updates installed AI CLIs. `--dry-run`, `--targets codex,claude`, `--install-missing`, `--min-release-age-days N` |
| `aicm clean` | Removes stale leftovers. `--dry-run`, `--rules codex-sessions,os-temp` |
| `aicm worktrees` | Worktrees and branches agent sessions left behind. Report only unless `--apply` (`-Apply`); `--days 14` |
| `aicm config` | MCP servers and skills compared across the installed CLIs |
| `aicm processes` | Agent processes left running after their session ended. `--kill` (`-Kill`) ends them |
| `aicm status` | Schedules, last run results, the last inventory, disk use per rule and what can be freed |
| `aicm doctor` | Exits 1 with a list of problems when a schedule is missing or a run is overdue or failed |
| `aicm schedule install` | Registers the update, inventory and clean jobs; running it again replaces them |
| `aicm schedule remove` | Removes the jobs |
| `aicm uninstall` | Removes the jobs and the installed copy; `--purge` (`-Purge`) also removes logs, state and archives |
| `aicm version` | Prints the version |

On Windows use `.\bin\aicm.ps1 <command>` with PowerShell-style options such as `-DryRun`, `-Targets`, `-Rules`.

## Inventory

The CLIs to look for are listed in the catalog [`rules/ai-clis.conf`](rules/ai-clis.conf): Claude Code, Codex, OpenCode, Grok Build, Kimi Code, Antigravity, Gemini CLI, Qwen Code, GitHub Copilot CLI, Amp, Augment Auggie, Crush, Continue, Cursor Agent, Goose, Factory Droid, Aider and OpenCode Desktop (Windows).

```text
CLI                  via         version        latest         state     daily update
Claude Code          npm         2.1.288        2.1.291        held      yes
OpenAI Codex         standalone  0.157.1        0.160.1        behind    no: the update refreshes the npm copy, not the one on PATH
                     npm copy 0.160.1 is also installed, but PATH runs C:\...\OpenAI\Codex\bin\codex.exe
Grok Build           standalone  1.0.46         1.0.46         current   yes
Cursor Agent         standalone  2026.09.18                    installed yes
```

`held` means a newer release exists but is still inside the 3-day waiting period. `no` in the `daily update` column means the daily update does not reach that CLI, with the reason. When the copy the terminal runs differs from the copy the update refreshes (Codex above), the inventory says so and notifies you once with a concrete fix.
Results go to `~/.ai-cli-auto-manager/inventory.md` (a readable table) and `state/inventory.json`. Global npm packages that are not in the catalog are listed below the table.

To add a CLI, write a row in the same format to `~/.ai-cli-auto-manager/ai-clis.local.conf`. A row with an existing `id` replaces the built-in one.

```text
# id      | command | name      | npm            | brew | winget | self_update | note
my-agent  | myagent | My Agent  | @me/my-agent   |      |        |             |
```

## Update

The default target is `all`: every catalog CLI installed on this machine. CLIs that are not installed are skipped.

| Target | How it is updated |
| --- | --- |
| Claude Code, Codex, OpenCode, Grok Build, Kimi Code, Antigravity | Dedicated paths (Homebrew, npm, the CLI's own updater, the xAI and Codex install scripts), chosen by the copy on PATH |
| Other catalog CLIs | The way the copy on PATH was installed: npm, Homebrew, winget, or the CLI's own updater from the catalog |

Pick targets with `--targets codex,claude` (`-Targets`); `gpt` is the same target as `codex`.
New CLIs are installed only with `--install-missing` (`-InstallMissing`) and the id named explicitly; `all` never installs anything new.

### Safe updates for npm-installed CLIs

Official AI tools have shipped malicious releases. The Amazon Q extension 1.84.0 (July 2025) was published officially with a prompt telling the agent to wipe files, and Cline CLI 2.3.0 (February 2026) was published with a stolen token and quietly installed another program. Both were pulled within hours to two days. So npm-installed CLIs go through four steps:

1. **Waiting period**: only the newest release that is at least 3 days old is installed, and its dependencies are resolved as of that date too (`npm install --before`), so a fresh malicious dependency cannot slip in through a version range. Unpublished and deprecated releases are never picked; a prerelease (`2.0.0-beta.3`) counts as older than its release.
2. **Red flags**: compared with the installed release, a candidate that lost its provenance attestation, or adds or changes an install-time script (`preinstall`, `install`, `postinstall`), is not installed and you are notified. Cline 2.3.0 fails both checks.
3. **Staged signature check**: the candidate is installed into a temporary folder without running any scripts (`--ignore-scripts`) and checked with `npm audit signatures` (that command does not work on global installs, hence the staging).
4. Only then is that version installed globally. A CLI already at that version is not reinstalled.

Registries that publish no signing keys (a private Verdaccio, for example) cannot be checked in step 3; that is reported once as "signatures not checkable" and does not block the update.

| Environment variable | Meaning |
| --- | --- |
| `AICM_MIN_RELEASE_AGE_DAYS` | Waiting period in days (default 3, `0` = newest). Also `-MinReleaseAgeDays` on Windows and `--min-release-age-days` on macOS/Linux |
| `AICM_VERIFY_SIGNATURES` | `0` skips the staged signature check |
| `AICM_ALLOW` | Releases you reviewed and want to accept despite red flags, e.g. `AICM_ALLOW=cline@3.1.0` |
| `AICM_INSTALL_TIMEOUT_SECONDS` | Time limit for one `npm install -g` or Homebrew step (default 1800) |

Security fixes also arrive as updates, so a long waiting period has a cost. Three days avoids the incidents so far while still picking up fixes quickly.

### Unattended runs that keep working

- **A CLI that is running is not overwritten.** On Windows a running program's files cannot be replaced (npm fails with `EBUSY`), and agent sessions often run all day. Such an update is recorded as *deferred*, not failed, and the scheduled job retries every 3 hours for 15 hours; a later run on a day that already succeeded exits immediately. If a CLI stays deferred for 5 days you get one reminder to close its sessions for a moment.
- **Nothing hangs forever.** Installs have a time limit, and a timeout ends the whole process tree, not only the launcher. If a run still holds the lock after 3 hours, the next run tells you (once) instead of exiting quietly behind it.
- **No registry, no failure.** When the npm registry cannot be reached the run is recorded as pending and retried; it is not reported as a failed update.
- **Leftovers of interrupted installs are removed, carefully.** npm leaves staging folders (`node_modules/.<name>-XXXXXXXX`, hundreds of MB) behind when an install fails half way; those older than a day are removed after each update, but only while the package itself is installed, because such a folder can be npm's only backup. A managed CLI that disappears is reinstalled at the same version from that backup, or reported once.
- **"Done today" means done.** A retry ends immediately only when a run on the same local calendar day succeeded for the same CLIs; a manual `--targets claude` run does not stop the full scheduled run. Retries with nothing to do write no log. The logs that cron and launchd append to are trimmed.
- **Vendor install scripts run only when needed.** The install scripts behind Grok Build and `codex update` (Codex from the official installer) run only when a newer release (past the waiting period) exists, not every day.
- **A Homebrew Codex upgrade does not break running app-servers.** `brew upgrade` deletes the old cask folder, but a long-running `codex app-server` (Paseo keeps one) still starts its terminal host from there, so its terminal tools fail. Right after the Codex step, servers that still map a replaced Codex are found; the Paseo daemon is restarted (`paseo restart`), and any server still stale after that is stopped. Servers already on the current Codex and the ChatGPT app's own copy are left alone. `AICM_CODEX_RECYCLE=0` turns this off.
- **A Homebrew Codex starts its terminal host.** The cask build is quarantined, so the first exec of `codex-code-mode-host` waits on Gatekeeper's "downloaded from the Internet" prompt. On an unattended or remote Mac nobody answers it, the host never starts, and every shell and edit tool call fails with `timed out negotiating with the code-mode host`. Each run clears the quarantine from the Codex cask folder, but only after `codesign --check-notarization` confirms a notarized build signed by OpenAI (team `2DC432GLL2`). Retries that end early after a complete run still do this check. `AICM_CODEX_UNQUARANTINE=0` turns this off.
- **One notification per problem.** A problem is notified when it first appears and then at most once a week while it lasts.

### Post-update hook

A daemon that is already running may keep the old CLI binaries loaded. Put a hook file in place and it runs after an update that changed at least one CLI version; a failing hook only produces a warning.

| OS | Hook file |
| --- | --- |
| Windows | `%USERPROFILE%\.ai-cli-auto-manager\hooks\post-update.ps1` |
| macOS · Linux | `~/.ai-cli-auto-manager/hooks/post-update.sh` (must be executable) |

```powershell
# Example: make the Paseo daemon pick up the updated CLIs
paseo reload
```

## Clean

The built-in rules live in one file, [`rules/clean-rules.conf`](rules/clean-rules.conf), shared by Windows and macOS/Linux. Ages count from the last time a file was used, not when it was created, so a long conversation you are still continuing is never removed. Most rules look at each entry of their folder as a whole (a session folder, say): it goes only when nothing inside it changed for the rule's days, so a session or a plugin checkout that is still in use is never thinned out file by file.

| Rule | What | Age | Default |
| --- | --- | --- | --- |
| `codex-sessions` | Codex conversations, deleted with Codex's own `codex delete` (files are never removed directly) | 30 days | on |
| `gemini-tmp`, `qwen-tmp`, `grok-sessions`, `copilot-sessions` | Conversations and checkpoints of those CLIs | 30 days | on |
| `claude-transcripts` | Claude Code transcripts. Off because Claude Code deletes them itself (`cleanupPeriodDays`, default 30); turn it on to archive them before that | archive 22 days, delete +60 | off |
| `codex-images` | Images Codex generated (archived, then deleted, when turned on) | archive 30 days, delete +60 | off |
| `codex-tmp` | Codex scratch files | 7 days | on |
| `codex-trace-db` | Codex trace log DB (`logs_*.sqlite`; it has no off switch and keeps growing) | 30 days or over 200 MB | on |
| `claude-file-history`, `claude-debug` | Claude Code rewind backups, debug logs | 30, 14 days | on |
| `claude-temp` | Claude Code per-session temp files (Windows `%TEMP%\claude`); Claude clears most of them itself within a day | 1 day | on |
| `grok-downloads`, `kimi-logs` | Installer downloads, logs | 14, 30 days | on |
| `npm-cache`, `pip-cache` | Package download caches (refetched on demand) | 60, 30 days | on |
| `uv-cache` | `uv cache prune`, uv's own cleanup | - | on |
| `os-temp` | Windows user temp folder (a folder goes only when nothing in it changed) | 7 days | on |
| `playwright-browsers` | Old Playwright browser builds (keeps the newest 2 per browser) | - | off |

**Never delete Codex session files directly.** Codex stores every conversation both in files and in its own database; deleting only the file leaves an entry that can no longer be opened (versions 1.x to 2.1 did this). This tool therefore only uses Codex's commands. Sessions whose file is already gone are removed from the database with `codex delete` on the same schedule. That step reads Codex's database read-only and needs Python (Windows) or sqlite3 (macOS); without them, or when the database layout is not the expected one, it is skipped. A session counts as "file gone" only when no file with its id exists anywhere, so a moved home folder does not make live sessions look orphaned. Codex's folder follows `CODEX_HOME` (the `{codex}` path in the rules).

### Archive before deleting (optional)

An `archive` rule does not delete expired files right away: it moves them, keeping their folder structure, to `~/.ai-cli-auto-manager/archive/<rule>/<date>/`, and deletes archive folders older than `limit` days. Old archive folders keep being deleted even after the rule is turned off, so no remnants stay behind. To restore, move the files back. For Codex, a `limit` above 0 switches to `codex archive` followed by `codex delete` `limit` days later; restore with `codex unarchive <id>`.

Archiving only moves files, so it frees no space by itself; space comes back when the archive is deleted. For CLIs that delete their own history (Claude Code `cleanupPeriodDays`, Gemini CLI `sessionRetention`, Qwen Code `cleanupPeriodDays`), the setting is read and archiving happens a week earlier, so the CLI never deletes first.

### Never removed

- Files newer than the rule's age, folders with anything newer inside, and files another program has locked (skipped and logged as "in use").
- Anything behind a symlink or junction. Links are never followed, so their targets are safe.
- Memory, credential, key and settings files such as `MEMORY.md`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `auth.json`, `.credentials.json`, `settings.json`, `config.toml`, `.npmrc`, `.netrc`, any `*.env`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, and everything inside a folder named `memory` (any letter case).
- Anything outside the home folder and the temp folder. A rule pointing elsewhere, at the home folder itself or at a folder above it, is refused with a notification. The temp folder counts only when it really is one: if `TEMP`/`TMPDIR` points at a drive root, `/`, or a folder that contains your home folder, temp rules are refused.
- Anything at all when the clock looks wrong. If the system clock is earlier than the last cleanup, or more than 400 days past it (a dead CMOS battery, a restored VM snapshot), every file would look old, so nothing is deleted and you are notified. If the date really is right, run once with `AICM_CLOCK_CHECK=0`.

### Changing rules

Write rows in the same format to `~/.ai-cli-auto-manager/clean-rules.local.conf` (Windows: `%USERPROFILE%\.ai-cli-auto-manager\clean-rules.local.conf`). A row with an existing `id` replaces that rule; a new `id` adds one.

```text
# id                | os      | kind        | path                          | pattern   | days | limit | default | note
playwright-browsers | windows | keep-latest | {localappdata}/ms-playwright  | *         |      | 2     | on      | clean old builds
codex-sessions      | all     | codex       | {codex}                       | rollout-* | 30   | 60    | on      | archive at 30 days, delete at 90
claude-transcripts  | all     | archive     | ~/.claude/projects            | *.jsonl   | 30   | 60    | on      | archive Claude transcripts too
os-temp             | windows | age         | {temp}                        | *         | 7    |       | off     | turn off
my-notebook-cache   | all     | age         | ~/.cache/my-tool              | *.tmp     | 14   |       | on      | add your own
```

There are seven kinds. `age` treats each entry directly in the folder (a session folder, a file) as one unit and deletes it once nothing inside it changed for `days`, so a folder still in use is never thinned out. `age-files` deletes single files older than `days` anywhere below the folder (for caches whose entries stand alone). `codex` deletes through Codex's commands (`limit` 0) or archives first. `archive` moves files to the archive and deletes them `limit` days later. `cap` deletes files directly in the folder when older than `days` or larger than `limit` MB. `keep-latest` keeps the newest `limit` versioned folders (`name-1234`) per name. `command` runs a tool's own cleanup command.

## Running many sessions (Paseo, Orca, ...)

Tools that run several agent sessions at once leave three kinds of leftovers. These checks need Node.js (already there for npm-installed CLIs) and are skipped without it.

**Worktrees and branches** (weekly with Clean, or `aicm worktrees`). Repositories are found under the folders listed in `~/.ai-cli-auto-manager/repos.conf` (one per line), or under common code folders in your home directory (`Desktop`, `dev`, `code`, `src`, `projects`, `repos`, `Documents/GitHub`, `Documents/Codex`, ...). A linked worktree is removed only when all of these hold:

- no uncommitted or untracked changes, not locked, and untouched for 14 days;
- no ignored files except rebuildable build output (`node_modules`, `dist`, `.venv`, `target`, ...): `git worktree remove` deletes ignored files too, so a worktree holding a `.env` or a local database is kept and reported;
- its work is safely upstream: merged into the default branch, or a pull request of origin's own GitHub repository was merged into the default branch with exactly this commit (needs `gh`; this covers squash merges), or every commit is on a remote right after a successful `git fetch --all --prune`;
- no other program is working in it (the folder can be renamed).

Links inside ignored folders (for example a `node_modules` junction to a shared copy) are unlinked first, so `git worktree remove` can never delete what they point to. `--force` is never used. Every removed worktree or branch keeps its commit under `refs/aicm-deleted/<date>/<branch>` for 90 days; bring one back with `git branch <name> refs/aicm-deleted/<date>/<name>`. Worktrees whose folder is gone are pruned, and local branches with the same proof that are not checked out anywhere are deleted. The main worktree, its current branch and `main`/`master`/`develop` are never touched. A worktree with uncommitted changes untouched for 30 days is reported once as forgotten work.

**Configuration across CLIs** (weekly with Inventory, or `aicm config`). Lists the user-level MCP servers of each installed CLI (Claude Code, Codex, Gemini CLI, Qwen Code, OpenCode, Cursor, Copilot CLI) and the skill folders (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, ...): servers set up in some CLIs only, skills some CLIs cannot see, and skills with the same name but different content in two folders (which copy wins depends on folder order). Report only; the last case is notified once.

**Processes left behind** (daily with Update, or `aicm processes`). Finds MCP servers, automation browsers (Chrome DevTools MCP, Playwright) and agent CLIs that have run for 2 hours or more after their parent session is gone. Daemons that run detached on purpose (Paseo, Codex app-server, sandboxes, language servers) and this tool's own processes are ignored; add more with `AICM_PROCESS_IGNORE` (a regular expression). Report only; set `AICM_KILL_ORPHANS=1` or run `aicm processes --kill` to end them with their children.

| Environment variable | Meaning |
| --- | --- |
| `AICM_WORKTREES=0` | Skip worktree and branch cleanup in the Clean job |
| `AICM_PROCESSES=0` | Skip the process check in the Update job |
| `AICM_CODEX_RECYCLE=0` | Do not restart Codex app-servers left on a replaced Homebrew Codex |
| `AICM_CODEX_UNQUARANTINE=0` | Do not clear the quarantine from the notarized OpenAI Codex cask build |
| `AICM_KILL_ORPHANS=1` | End left-behind processes instead of only reporting them |
| `AICM_ORPHAN_MIN_AGE_HOURS` | Minimum age before a process counts (default 2) |

## Scheduling

`aicm schedule install` registers the jobs for your OS. Times can be changed.

| OS | Where | Change times |
| --- | --- | --- |
| Windows | Task Scheduler folder `\AI CLI Auto Manager\`: `Update`, `Inventory`, `Clean` | `-UpdateAt 05:00 -InventoryDay Monday -InventoryAt 12:00 -CleanDay Monday -CleanAt 12:30` |
| macOS | `~/Library/LaunchAgents/io.github.wilgon456.ai-cli-auto-manager.{update,inventory,clean}.plist` | `--update-at 05:00 --inventory-day mon --inventory-at 12:00 --clean-day mon --clean-at 12:30` |
| Linux | user crontab (only lines tagged `# aicm:update`, `# aicm:inventory`, `# aicm:clean` are touched) | same as macOS |

`schedule install` copies the tool to `~/.ai-cli-auto-manager/app` and the jobs run that copy, so moving or deleting your git clone cannot stop them. When the clone gets a newer version (`git pull`), the next daily update refreshes the copy and then re-registers the jobs from it with the days and times you installed them with (`schedule refresh` does the same by hand; jobs that already match are left alone). An older version in the clone (an old tag checked out) never replaces the copy. The new copy is checked file by file before it is swapped in; if anything fails, the old copy stays.

On Windows the jobs start through a small launcher (`windows/run-hidden.vbs`), so no PowerShell window flashes on screen. `schedule install` first tests that launcher; where Windows Script Host is turned off it starts PowerShell directly with a hidden window instead (it may flash briefly).

On macOS and Linux the jobs get the `PATH` of the shell you ran `schedule install` in (plus the folders of `node`, `npm`, `brew` and `codex`), so CLIs installed with nvm, fnm, volta, mise, `~/.npm-global` or Homebrew are found. If you later move Node.js, run `schedule install` again; `doctor` tells you when the jobs no longer find `node` or `npm`.

On Windows a run missed while the PC was off starts at the next boot; on macOS a run missed during sleep starts on wake. cron (Linux) skips missed runs, so there the weekly jobs start every day at their time and run only when this week's run has not happened yet.
Leave out jobs you do not want with `--no-update`, `--no-inventory`, `--no-clean` (`-NoUpdate`, `-NoInventory`, `-NoClean`). On Windows, `-KeepOtherJobs` leaves the jobs you did not ask for as they are instead of removing them.

Scheduled jobs can disappear or stop working silently. The jobs installed are recorded at install time, and every run checks that the others still exist, are not disabled, still point at existing files, did not fail on their last run, and have completed recently (update within 3 days, inventory and clean within 9). It also checks that Windows Script Host is on (Windows) and that a cron daemon runs (Linux; WSL starts none by default). It shows a desktop notification when something is wrong. Every notification is also written to `logs/notifications.log`, and `status` and `doctor` show the latest ones, so a notification that never reached the screen is not lost. State files are written atomically, so a crash never leaves a half-written file behind. Set `AICM_NOTIFY=0` to turn desktop notifications off.

## Logs and state

| File | Contents |
| --- | --- |
| `~/.ai-cli-auto-manager/logs/update-*.log`, `latest.log` | Update runs |
| `~/.ai-cli-auto-manager/logs/inventory-*.log` | Inventory runs |
| `~/.ai-cli-auto-manager/logs/clean-*.log` | Clean runs (files and bytes per rule) |
| `~/.ai-cli-auto-manager/inventory.md` | The last inventory as a readable table |
| `~/.ai-cli-auto-manager/state/last-update.json`, `inventory.json`, `last-clean.json` | Last run results (read by `status` and `doctor`) |
| `~/.ai-cli-auto-manager/state/schedule.json` | Installed jobs, their days and times, and the `PATH` the jobs get |
| `~/.ai-cli-auto-manager/logs/notifications.log` | Every notification (last 500) |
| `~/.ai-cli-auto-manager/archive/` | Files moved by archive rules (per rule and date) |

Logs are kept for 30 days; change that with `LOG_RETENTION_DAYS` (or `-LogRetentionDays` on Windows). Set `AICM_HOME` to move everything elsewhere.

`uninstall --purge` (`-Purge`) removes only what the tool wrote (`app`, `logs`, `state`, `archive`, `inventory.md`) and keeps your own files there (`hooks/`, `*.local.conf`, `repos.conf`); the folder goes only when nothing is left in it. A folder without the `.aicm-home` marker is purged only when it is the default `~/.ai-cli-auto-manager`.

## Moving from 1.x (ai_cli_auto_update)

- The repository was renamed from `ai_cli_auto_update_public` to `ai_cli_auto_manager`; GitHub redirects the old URL.
- `bin/update_ai_clis.sh` and `bin/update_ai_clis.ps1` are still there, so existing automation keeps working.
- On Windows, `aicm.ps1 schedule install` replaces the old `AI CLI Auto Update` task (keep it with `-KeepLegacyTask`). `windows\install_scheduled_task.ps1` still works and registers only the update job, as before; Inventory and Clean jobs that are already registered stay as they are.
- Logs moved from `~/.ai-cli-auto-update` to `~/.ai-cli-auto-manager`. The old folder is left alone; delete it when you no longer need it.
- If you installed the old macOS template (`com.example.ai-cli-auto-update`), `aicm schedule install` prints the commands to remove it.

## Development and tests

All tests run in a throwaway home folder and never touch your real home folder or real scheduled tasks. Inventory, update and clean tests use fake CLIs, a fake npm and a fake codex, so no real CLI is run or updated. The Node tests build throwaway git repositories and use injected process lists; nothing is ever killed.

```bash
shellcheck -x bin/aicm bin/*.sh lib/*.sh tests/*.sh
bash tests/clean_test.sh
bash tests/aicm_test.sh
bash tests/inventory_test.sh
node --test tests/node/*.test.js
```

```powershell
.\tests\clean_test.ps1
.\tests\aicm_test.ps1
.\tests\inventory_test.ps1
```

CI runs the same tests on Ubuntu, macOS (with the bash 3.2 that ships with it), Windows PowerShell 5.1 and PowerShell 7.

## Limitations

- Built for personal machines and small teams; for organization-wide rollout, add your own change management.
- There is no automatic rollback to a previous version.
- The waiting period and the signature and red-flag checks apply to npm-installed CLIs only. CLIs updated through Homebrew, winget, their own updater (`claude update` and similar) or the xAI install script rely on that channel.
- Grok Build is in beta and may require an account or subscription.

## Official docs

- [Kimi Code CLI](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html)
- [OpenAI Codex CLI](https://help.openai.com/en/articles/11096431)
- [OpenCode](https://github.com/anomalyco/opencode#installation)
- [Claude Code](https://code.claude.com/docs/en/installation)
- [Grok Build](https://docs.x.ai/build/overview)

## License

MIT License. See [LICENSE](LICENSE).
