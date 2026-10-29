<div align="center">

![AI CLI Auto Manager](docs/readme-banner.svg)

# AI CLI Auto Manager

Inventory your AI coding CLIs, update conservatively and keep scheduled maintenance visible.

**English** · [한국어](README.ko.md)

![project: automation](https://img.shields.io/badge/project-automation-4ade80?style=flat-square) ![stack: Shell / PowerShell](https://img.shields.io/badge/stack-Shell%20%2F%20PowerShell-4ade80?style=flat-square) [![License](https://img.shields.io/badge/license-MIT-4ade80?style=flat-square)](LICENSE)

[Quick start](#quick-start) · [Commands](#commands) · [Scheduling](#scheduling)

[![CI](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml/badge.svg)](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml)

</div>

---

After a few months with AI coding CLIs, three things get blurry: what you have installed, whether it is current, and how much disk it eats.
It is also common to have the same CLI installed twice (a desktop app copy and an npm copy), so updates land on one copy while the terminal keeps running the other, older one.
This tool schedules inventory, updates, cleanup and an hourly maintenance preview. Clone the repository and run one command to schedule it. Node.js 22 or newer is required for process containment and maintenance.

| Job | Runs (default) | What it does |
| --- | --- | --- |
| Inventory | weekly (Mon 12:00) | Lists the installed AI CLIs with version, latest version, install method, and whether the daily update actually reaches the copy on PATH. Compares MCP servers and skills across the CLIs. Notifies you when a CLI appears or disappears |
| Update | daily (05:00) | Updates supported installed CLIs. npm-installed CLIs only get releases at least 3 days old, after red-flag and signature checks. One failure does not stop the rest. Also reports MCP servers, browsers and agent CLIs left running after their session ended |
| Maintenance | hourly (minute 7) | Previews owned orphan/cache cleanup, writes an action log and daily summary, and warns about CLI version floors. Explicit apply enables quarantine and tagged-only termination |
| Clean | weekly (Mon 12:30) | Deletes conversation history unused for 30 days and expired temp files and caches, and removes git worktrees and branches whose work is already merged. Never follows links and never deletes memory, credential, settings files or unpushed work |

Every run checks that the other jobs are still registered, and shows a desktop notification when a job is gone or a run fails.

## Quick start

Cleanup can permanently delete conversation history unused for 30 days. Preview
the rules and keep a backup before enabling it. The examples below start with
update and inventory schedules only; see [compatibility and first use](docs/compatibility.md)
for supported installation channels and how to enable cleanup after review.
These examples are for a first installation. Reinstalling a schedule can replace
existing managed jobs; review `aicm status` before changing them.

- `inventory` shows the active PATH copy and whether the daily update reaches it.
  Some installation channels need a manual update.
- `update --dry-run` previews the update without installing anything.
  `clean --dry-run` previews the cleanup rules and targets before files are changed.
- Only retained archives can be restored: use `archive list` and `restore ID`
  for indexed files, or `codex unarchive <id>` for an archived Codex session.
  Directly deleted items and expired archives cannot be restored by this tool.

### Windows

```powershell
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\bin\aicm.ps1 inventory           # report installed CLIs and update coverage
.\bin\aicm.ps1 update -DryRun      # preview update targets
.\bin\aicm.ps1 status              # schedules, last runs, disk use and what can be freed
.\bin\aicm.ps1 clean -DryRun       # preview what would be removed
.\bin\aicm.ps1 schedule install -NoClean -NoMaintenance  # update daily 05:00, inventory Mon 12:00
```

### macOS · Linux

```bash
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager

./bin/aicm inventory
./bin/aicm update --dry-run
./bin/aicm status
./bin/aicm clean --dry-run
./bin/aicm schedule install --no-clean --no-maintenance
```

## Automatic maintenance

`aicm maintenance` previews owned orphan-process and cache/temp cleanup. Add `--apply` to act;
files move to quarantine for seven days first. Untagged runtime orphans are alert-only. The hourly
Maintenance job defaults to dry-run; enable it with `aicm schedule install --maintenance-apply`.
`aicm run -- claude` starts a tagged session whose descendants are contained with its lifetime.
Node.js is required for Unix process containment.

See [automatic maintenance](docs/automatic-maintenance.md) for Windows commands, rules, recovery,
logs, version floors and the process safety policy. `processes --kill` now follows that policy;
`AICM_KILL_ORPHANS=1` no longer enables name-based termination.

## Commands

| Command | What it does |
| --- | --- |
| `aicm inventory` | Lists the installed AI CLIs. `--offline` (`-Offline`) skips the latest-version lookups |
| `aicm update` | Updates installed AI CLIs. `--dry-run`, `--targets codex,claude`, `--install-missing`, `--min-release-age-days N` |
| `aicm clean` | Removes stale leftovers. `--dry-run`, `--rules id,id`, `--category sessions,cache,logs,temp,other` or `all`, `--json`, `--explain` |
| `aicm archive list` | Indexed generic archives, newest first. `--json`, `--limit N`, `--offset N`. Legacy files say to restore by hand |
| `aicm archive gc` | Drops index records that can never be restored again (archive folder already purged, or restored 30+ days ago). `--dry-run`, `--json` |
| `aicm restore ID` | Puts one indexed file back. `--dry-run`, `--json`. Refuses when the original path exists |
| `aicm history` | Local update, clean, and restore notes (at most 100; no file contents). `--limit N`, `--json` |
| `aicm worktrees` | Worktrees and branches agent sessions left behind. Report only unless `--apply` (`-Apply`); `--days 14` |
| `aicm config` | MCP servers and skills compared across the installed CLIs |
| `aicm processes` | Ownership-aware orphan scan; `--kill` (`-Kill`) applies only to verified tagged orphans. Untagged runtimes are alert-only |
| `aicm maintenance` | Quarantine owned stale files and report orphan processes; dry-run unless `--apply` (`-Apply`) |
| `aicm run -- command` | Run a CLI in a tagged, contained session (Windows: `run -Cli command -CliArguments @(...)`) |
| `aicm optimize` | Opt-in cache maintenance through the package managers' own commands (`npm cache verify`, `uv cache prune`, `pnpm store prune`). Preview by default; only `--apply` (`-Apply`) runs them. `--tasks npm-verify,uv-prune,pnpm-prune`, `--dry-run`, `--json`. Needs Node.js |
| `aicm status` | Schedules, last run results, the last inventory, disk use per rule and what can be freed |
| `aicm doctor` | Exits 1 with a list of problems when a schedule is missing, a run is overdue or failed, the update policy is invalid (or needs a missing Node.js), or `AICM_HOME` is not usable. Also shows the installed copy, its source and versions. Changes nothing |
| `aicm schedule install` | Registers update, inventory, clean and hourly maintenance jobs; running it again replaces them |
| `aicm schedule remove` | Removes the jobs |
| `aicm uninstall` | Removes the jobs and the installed copy; `--purge` (`-Purge`) also removes the logs, state and archives the tool wrote. `--dry-run` (`-DryRun`) lists what would go and changes nothing |
| `aicm version` | Prints the version |

On Windows use `.\bin\aicm.ps1 <command>` with PowerShell-style options such as `-DryRun`, `-Targets`, `-Rules`.

## Inventory

The CLIs to look for are listed in the catalog [`rules/ai-clis.conf`](rules/ai-clis.conf): Claude Code, Codex, OpenCode, Grok Build, Kimi Code, Antigravity, Gemini CLI, Qwen Code, GitHub Copilot CLI, Amp, Augment Auggie, Crush, Continue, Cursor Agent, Goose, Factory Droid, Aider and OpenCode Desktop (Windows).

```text
CLI                  via         version        latest         state     daily update
Claude Code          npm         2.1.288        2.1.291        held      yes
OpenAI Codex         standalone  0.157.1        0.160.1        behind    no: update the PATH copy with its owning app or installer
                     npm copy 0.160.1 is also installed, but PATH runs C:\...\OpenAI\Codex\bin\codex.exe
Grok Build           standalone  1.0.46         1.0.46         current   yes
Cursor Agent         standalone  2026.09.18                    installed yes
```

`held` means a newer release exists but is still inside the 3-day waiting period. `no` in the `daily update` column means the daily update does not reach that CLI, with the reason. When an unsupported copy on PATH hides an npm installation (Codex above), the inventory shows the selected path and notifies you once with a concrete fix. Updates follow the installation selected by PATH.
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

The copy on PATH chooses the update channel. A second Homebrew or npm Codex installation is left
alone when it is hidden behind the active copy; npm duplicates are reported with a suggested fix.

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

- **Updates to running npm CLIs are deferred when detected.** On Windows, replacing a running program's files can fail with `EBUSY`. On macOS and Linux, replacing the package folder can cause a running session to load new files alongside old code. The updater checks for running npm CLIs and records a *deferred* update instead of a failure; the scheduled job retries every 3 hours for 15 hours, and a later run on a day that already succeeded exits immediately. After 5 days it sends a reminder to close the sessions. On macOS and Linux detection is best effort: a session can start after the final check or hide its identity, and a matching process name can defer a different installation. Homebrew, native and installer-script update routes remain unchanged.
- **Nothing hangs forever.** Installs have a time limit, and a timeout ends the whole process tree, not only the launcher. If a run still holds the lock after 3 hours, the next run tells you (once) instead of exiting quietly behind it.
- **No registry, no failure.** When the npm registry cannot be reached the run is recorded as pending and retried; it is not reported as a failed update.
- **Leftovers of interrupted installs are removed, carefully.** npm leaves staging folders (`node_modules/.<name>-XXXXXXXX`, hundreds of MB) behind when an install fails half way; those older than a day are removed after each update, but only while the package itself is installed, because such a folder can be npm's only backup. A managed CLI that disappears is reinstalled at the same version from that backup, or reported once.
- **"Done today" means done.** A retry ends immediately only when a run on the same local calendar day succeeded for the same CLIs; a manual `--targets claude` run does not stop the full scheduled run. Retries with nothing to do write no log. The logs that cron and launchd append to are trimmed.
- **Vendor install scripts run only when needed.** The install scripts behind Grok Build and `codex update` (Codex from the official installer) run only when a newer release (past the waiting period) exists, not every day.
- **A Homebrew Codex upgrade does not break running app-servers.** `brew upgrade` deletes the old cask folder, but a long-running `codex app-server` (Paseo keeps one) still starts its terminal host from there, so its terminal tools fail. Right after the Codex step, servers that still map a replaced Codex are found; the Paseo daemon is restarted (`paseo daemon restart`), and any server still stale after that is stopped. Only older versions under the same Homebrew cask root whose executable was removed qualify; npm, standalone, other cask roots, newer versions and application bundles are left alone. `AICM_CODEX_RECYCLE=0` turns this off.
- **A Homebrew Codex starts its terminal host.** The cask build is quarantined, so the first exec of `codex-code-mode-host` waits on Gatekeeper's "downloaded from the Internet" prompt. On an unattended or remote Mac nobody answers it, the host never starts, and every shell and edit tool call fails with `timed out negotiating with the code-mode host`. Each run clears the quarantine from the Codex cask folder, but only after `codesign --check-notarization` confirms a notarized build signed by OpenAI (team `2DC432GLL2`). Retries that end early after a complete run still do this check. `AICM_CODEX_UNQUARANTINE=0` turns this off.
- **One notification per problem.** A problem is notified when it first appears and then at most once a week while it lasts.

### Update verification

Each update records the PATH-selected command's path and version before and after, and a bounded exit status. A command that was present and is then missing, failed, empty, or timed out is a failure. An install reported as success with no command afterward is a failure. An unchanged version does not prove the latest release is installed. A command that failed before and works after is recorded as repaired. Post-update hooks run only after a healthy change. Local update history needs Node.js. There is no automatic rollback; version pins are optional per CLI (see below).

### Per-CLI update policy

Create `update-policy.json` in `$AICM_HOME` (default `~/.ai-cli-auto-manager` on macOS/Linux, `%USERPROFILE%\.ai-cli-auto-manager` on Windows). Set `AICM_HOME` before a run to keep the policy at a custom location (`$AICM_HOME/update-policy.json`). Node.js validates this file and also supplies the Unix process-containment launcher for real update runs. The file is strict: unknown fields or CLI ids, wrong types, malformed JSON, a directory or a dangling link in its place fail the run before any log, lock or state file is created.

```json
{
  "schemaVersion": 1,
  "tools": {
    "claude": { "exclude": true },
    "codex": { "pin": "0.42.0", "minReleaseAgeDays": 14 }
  }
}
```

- `gpt` is an alias for `codex`. Configure one or the other, never both: a policy that names both is rejected as an alias collision.
- `exclude` wins over an explicit `--targets` entry, `--install-missing`, interrupted-install recovery, and Codex cask quarantine/recycle. An excluded CLI is not probed, so a broken `--version` cannot fail the run.
- `pin` is an exact stable release and only supported for CLIs that this manager updates through npm (plus Amp's timestamp/hash releases). Ranges, tags, prereleases and URLs are refused. The pinned release must still be published, not deprecated, and at least the effective waiting period old. A pin never falls back to latest, and it never downgrades a newer installed copy. On a non-npm route the pin is held for manual action.
- `minReleaseAgeDays` (0-3650) overrides `AICM_MIN_RELEASE_AGE_DAYS` for that CLI. A positive age or a pin cannot be enforced for a native/Homebrew/installer copy, so that route is held; an explicit `0` lets the native route run normally.
- While any rule is configured, npm backup housekeeping is suspended, so a backup that is the only copy is not deleted. An interrupted npm install under a configured pin is held rather than reinstalled unchecked; the message names the manual `npm install -g` command and the backup and state entry are kept.
- The stored fingerprint covers the normalized rules and the global waiting period. A scheduled retry skips only when the same fingerprint, targets and local day match; changing or removing the policy reruns the same day.

### Post-update hook

A daemon that is already running may keep the old CLI binaries loaded. Put a hook file in place and it runs after an update that changed at least one CLI version; a failing hook only produces a warning.

| OS | Hook file |
| --- | --- |
| Windows | `%USERPROFILE%\.ai-cli-auto-manager\hooks\post-update.ps1` |
| macOS · Linux | `~/.ai-cli-auto-manager/hooks/post-update.sh` (must be executable) |

```powershell
# Example: make the Paseo daemon pick up the updated CLIs
paseo daemon restart
```

## Clean

Size/age-capped files, including Codex log databases, are checked together with their WAL/SHM/journal
before deletion. On macOS/Linux this needs `lsof`; if it is unavailable, fails, or finds an open file,
the entire group is kept. On Windows cleanup holds handles that exclude readers/writers until it
finishes deleting the group. An open sidecar alone is enough to keep the database.

Recursive browser/archive cleanup keeps the whole directory if it contains protected files,
links, or files that cannot be proven idle. Date rules (`age`, `age-files`) on every platform only
delete a SQLite family (`*.sqlite`, `*.sqliteN`, `*.db` with `-wal`, `-shm`, `-journal`) when all
existing members meet the age and pattern conditions; a newer member (for example a fresh WAL that
still holds committed data), a readonly, linked or unexpected sidecar keeps all members. On macOS
and Linux the family must also be proven idle with `lsof`; a missing or failing `lsof`, or an open
member, keeps it. A lone sidecar whose database is gone is a family of one. Other cache files are
still removed in one batch. An explicitly selected Windows `AICM_HOME` may be a junction for installed-copy
maintenance; user-data cleanup still refuses linked paths.

`--category` limits which rules run. Names are `sessions`, `cache`, `logs`, `temp`, `other` and `all` (the default when the flag is omitted). It intersects `--rules` and does not enable a disabled rule. `gemini-tmp` and `qwen-tmp` are sessions, not cache. `--explain` is read-only: one line per rule (age, limit, action, what is protected). `--json` is one document for that same selection, not a per-file listing. Generic archive moves and purges, and `aicm archive` / `restore` / `history`, need Node.js. Real Unix cleanup uses Node.js for session containment; read-only native previews remain available without it. A real clean records a short local history entry (at most 100, no file contents). Previews do not. `aicm restore` never overwrites an existing path. Legacy archive files are listed for a manual move. Codex-native sessions are not generic restore ids.

```sh
aicm clean --category cache --dry-run --json
aicm restore ID --dry-run
```

```powershell
.\bin\aicm.ps1 clean -Category cache,logs -Json -DryRun
# schedule install -CleanCategory 'cache,logs' or an array; both are normalized
```

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

There are eight kinds. `age` treats each entry directly in the folder (a session folder, a file) as one unit and deletes it once nothing inside it changed for `days`, so a folder still in use is never thinned out. `age-files` deletes single files older than `days` anywhere below the folder (for caches whose entries stand alone). `codex` deletes through Codex's commands (`limit` 0) or archives first. `archive` moves files to the archive and deletes them `limit` days later. `cap` deletes files directly in the folder when older than `days` or larger than `limit` MB (each file on its own). `budget` keeps a whole cache folder at or below `limit` MiB in total (see below). `keep-latest` keeps the newest `limit` versioned folders (`name-1234`) per name. `command` runs a tool's own cleanup command.

### Cache budgets (optional)

A `budget` rule caps the **total** logical size of one cache folder whose entries stand alone (the
npm `_cacache`, the pip cache). No built-in rule uses it; the defaults stay age-based. To use it,
replace a rule in `clean-rules.local.conf`, for example:

```text
# id      | os   | kind   | path            | pattern | days | limit | default | note
npm-cache | unix | budget | ~/.npm/_cacache | *       | 14   | 2048  | on      | keep the npm cache under 2 GiB
pip-cache | mac  | budget | ~/Library/Caches/pip | *  | 7    | 1024  | on      | keep the pip cache under 1 GiB
```

`days` (at least 1) is the minimum age of a file before it may go; `limit` (at least 1) is the budget
in MiB. A zero, missing or malformed value is refused before anything runs. What happens:

- The rule folder is scanned recursively (links are never entered or followed). **Every** ordinary
  file counts toward the total, also protected, recent, hard-linked, SQLite and open files.
- Only files that match `pattern`, are older than `days`, have a single link, are not protected and
  are not SQLite database files or sidecars (`*.sqlite*`, `*.db`, `-wal`, `-shm`, `-journal`) are
  candidates. They go oldest modification time first, ties by path, until the total is at or below the
  budget. This is *not* least-recently-used: access times are not tracked.
- Before each deletion the file is checked again (same type, size, time and identity; no link between
  it and the rule folder; the rule folder itself not moved or replaced by a link) and must not be open:
  `lsof` on macOS/Linux (missing or failing `lsof` deletes nothing), an exclusive FileGuard handle on
  Windows. This narrows but cannot close the race with a program that opens the file right afterwards.
- A scan that is not complete (an unreadable folder or file, or the bounds `AICM_BUDGET_MAX_FILES`
  200000, `AICM_BUDGET_MAX_DEPTH` 32, `AICM_BUDGET_SCAN_SECONDS` 300) deletes nothing for that rule and
  says so; the other rules still run.
- When busy or protected data keeps the cache above the budget, the run says by how much
  ("budget not reachable").

The JSON row of a budget rule adds `totalBytes` (scanned before the run), `budgetBytes`,
`remainingBytes` (what is left after a real run, counted again; a preview leaves it at the total),
`projectedRemainingBytes` (what the selection would leave; on Windows a preview opens no files, so it
assumes the candidates are not in use), `budgetUnmetBytes` and `scanStatus` (`complete`, `partial` or
`unavailable`). These are **logical file sizes**, not a measurement of freed disk space (hard links,
compression, sparse files and file-system blocks make them differ). Byte counts stay exact above 2 GiB.
A budget is per cache folder: several CLIs that share one npm cache share one budget. Deleted entries
are downloaded again when a tool needs them.

## Optimize (opt-in)

`aicm optimize` runs a fixed allowlist of the package managers' own maintenance commands. Nothing else
can be run through it: no arbitrary command, no `npm install`/`update`/`dlx`/`npx`.

| Task | Command | Effect |
| --- | --- | --- |
| `npm-verify` | `npm cache verify` | Checks the npm cache and garbage-collects entries nothing needs |
| `uv-prune` | `uv cache prune` | Removes unused entries from the uv cache (the supported way; never delete uv's cache by hand) |
| `pnpm-prune` | `pnpm store prune` | Removes packages no project references from the pnpm store |

```sh
aicm optimize                               # preview: looks the tools up on PATH, runs none, writes nothing
aicm optimize --tasks uv-prune --dry-run --json
aicm optimize --apply --tasks npm-verify,pnpm-prune
```

```powershell
.\bin\aicm.ps1 optimize -Json
.\bin\aicm.ps1 optimize -Apply -Tasks npm-verify,uv-prune
```

- The default and `--dry-run` are previews: each tool is only looked up on PATH (absolute PATH entries;
  the path found is recorded), never started, so no Corepack bootstrap or download happens. Unknown,
  duplicated or empty task names and `--apply` together with `--dry-run` are refused (exit 2) before
  anything is looked up or written. Tasks always run in the order of the table.
- `--apply` claims `AICM_HOME` like other real runs, refuses while an update, cleanup, archive or
  restore runs, and holds the shared maintenance lock (`state/maintenance.lock`) until its last command
  has ended, also when a command fails or the run is interrupted.
- A task is skipped while a process of that package manager runs, including a package manager that
  started this optimizer. This optimizer itself is excluded. An unreadable process table or an
  unreadable Node/Bun command line also holds the affected npm/pnpm tasks.
- Each command runs offline (Corepack network, project selection, project env-file, prompts and
  auto-pin disabled; npm/pnpm offline; uv offline). pnpm project-version bootstrap is disabled across
  the legacy and current setting names. Guard values override inherited settings regardless of
  capitalization. A Corepack shim whose package manager is not downloaded yet fails instead of
  downloading it. Each command has a time limit (`AICM_OPTIMIZE_TIMEOUT`, default
  900 seconds); on timeout its whole process group (Windows: process tree) is stopped.
- One failing task does not stop the others. A missing tool is `unavailable`, a failure, timeout or
  skip is never counted as success; the exit code is 0 only when every selected task succeeded.
- On Windows a `.cmd`/`.bat` shim (npm, pnpm) runs through `%SystemRoot%\System32\cmd.exe /d /v:off /s /c`
  with its quoted path and the fixed words above; a path containing `" % ! ^ & | < > ( )` is refused,
  and a `.ps1` shim is never run.
- These commands are not byte-precise transactions: the preview cannot say how much each will remove,
  and pruned packages are downloaded again later. There is no schedule for optimize; run it yourself.
- `--json` prints one document: `schemaVersion`, `mode` (`preview`/`apply`), `status`, one row per task
  (`id`, `command`, `executable`, `status`: `would-run`, `ok`, `failed`, `timeout`, `busy`, `skipped`,
  `refused` or `unavailable`, `reason`, `exitCode`, `durationMs`, last output) and `summary` counts.

## Running many sessions (Paseo, Orca, ...)

Tools that run several agent sessions at once leave three kinds of leftovers. These checks need Node.js (already there for npm-installed CLIs) and are skipped without it.

**Worktrees and branches** (weekly with Clean, or `aicm worktrees`). Repositories are found under the folders listed in `~/.ai-cli-auto-manager/repos.conf` (one per line), or under common code folders in your home directory (`Desktop`, `dev`, `code`, `src`, `projects`, `repos`, `Documents/GitHub`, `Documents/Codex`, ...). A linked worktree is removed only when all of these hold:

- no uncommitted or untracked changes, not locked, and untouched for 14 days;
- no ignored files except rebuildable build output (`node_modules`, `dist`, `.venv`, `target`, ...): `git worktree remove` deletes ignored files too, so a worktree holding a `.env` or a local database is kept and reported;
- its work is safely upstream: merged into the default branch, or a pull request of origin's own GitHub repository was merged into the default branch with exactly this commit (needs `gh`; this covers squash merges), or every commit is on a remote right after a successful `git fetch --all --prune`;
- no other program is working in it (the folder can be renamed).

Links inside ignored folders (for example a `node_modules` junction to a shared copy) are unlinked first, so `git worktree remove` can never delete what they point to. `--force` is never used. Every removed worktree or branch keeps its commit under `refs/aicm-deleted/<date>/<branch>` for 90 days; bring one back with `git branch <name> refs/aicm-deleted/<date>/<name>`. Worktrees whose folder is gone are pruned, and local branches with the same proof that are not checked out anywhere are deleted. The main worktree, its current branch and `main`/`master`/`develop` are never touched. A worktree with uncommitted changes untouched for 30 days is reported once as forgotten work.

**Configuration across CLIs** (weekly with Inventory, or `aicm config`). Lists the user-level MCP servers of each installed CLI (Claude Code, Codex, Gemini CLI, Qwen Code, OpenCode, Cursor, Copilot CLI) and the skill folders (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, ...): servers set up in some CLIs only, skills some CLIs cannot see, and skills with the same name but different content in two folders (which copy wins depends on folder order). Report only; the last case is notified once.

**Processes left behind** (daily with Update, hourly with Maintenance, or `aicm processes`).
The ownership-aware scanner reports tagged orphans and untagged node/python/bun orphans that are
at least six hours old and hold a listening port. Apply (`maintenance --apply`, or `processes --kill`)
can end only verified tagged orphans; untagged processes remain alert-only. Live sessions, Paseo,
SSH/remote trees, service accounts, elevated and unverifiable processes stay. See the
[maintenance safety policy](docs/automatic-maintenance.md).

| Environment variable | Meaning |
| --- | --- |
| `AICM_WORKTREES=0` | Skip worktree and branch cleanup in the Clean job |
| `AICM_PROCESSES=0` | Skip the process check in the Update job |
| `AICM_CODEX_RECYCLE=0` | Do not restart Codex app-servers left on a replaced Homebrew Codex |
| `AICM_DEFER_RUNNING=0` | macOS/Linux: update an npm-installed CLI even while it is running |
| `AICM_CODEX_UNQUARANTINE=0` | Do not clear the quarantine from the notarized OpenAI Codex cask build |
| `AICM_KILL_ORPHANS` | Retired; use explicit `maintenance --apply` for verified owned orphans |
| Untagged orphan threshold | At least 6 hours plus a listening TCP port; alert-only |

## Scheduling

`aicm schedule install` registers the jobs for your OS. Times can be changed.

| OS | Where | Change times |
| --- | --- | --- |
| Windows | Task Scheduler folder `\AI CLI Auto Manager\`: `Update`, `Inventory`, `Clean`, hourly `Maintenance` | `-UpdateAt 05:00 -InventoryDay Monday -InventoryAt 12:00 -CleanDay Monday -CleanAt 12:30` |
| macOS | `~/Library/LaunchAgents/io.github.wilgon456.ai-cli-auto-manager.{update,inventory,clean,maintenance}.plist` | `--update-at 05:00 --inventory-day mon --inventory-at 12:00 --clean-day mon --clean-at 12:30` |
| Linux | user crontab (only lines tagged `# aicm:update`, `# aicm:inventory`, `# aicm:clean`, `# aicm:maintenance` are touched) | same as macOS |

`schedule install` copies the tool to `~/.ai-cli-auto-manager/app` and the jobs run that copy, so moving or deleting your git clone cannot stop them. When the clone gets a newer version (`git pull`), the next daily update refreshes the copy; `schedule refresh` does this by hand. On Windows, refresh retains existing task arguments, triggers, principal and settings, and changes the launcher when needed. An older version in the clone (an old tag checked out) never replaces the copy. The new copy is checked file by file before it is swapped in; if anything fails, the old copy stays.

On Windows, scheduled jobs use a small GUI-subsystem launcher compiled from `windows/aicm-windowless.cs` with the built-in .NET Framework compiler. It starts PowerShell with `CREATE_NO_WINDOW` and returns the script's exit code. If the compiler is unavailable or launcher verification fails, task installation stops instead of falling back to a visible console. Before changing existing tasks, the manager saves their XML and the old installed copy. See [Windows migration and rollback](docs/windows-windowless-migration.md).

On macOS and Linux the jobs get the `PATH` of the shell you ran `schedule install` in (plus the folders of `node`, `npm`, `brew` and `codex`), so CLIs installed with nvm, fnm, volta, mise, `~/.npm-global` or Homebrew are found. If you later move Node.js, run `schedule install` again; `doctor` tells you when the jobs no longer find `node` or `npm`.

On Windows a run missed while the PC was off starts at the next boot; on macOS a run missed during sleep starts on wake. cron (Linux) skips missed runs, so there the weekly jobs start every day at their time and run only when this week's run has not happened yet.
Leave out jobs you do not want with `--no-update`, `--no-inventory`, `--no-clean`, `--no-maintenance` (`-NoUpdate`, `-NoInventory`, `-NoClean`, `-NoMaintenance`). On Windows, `-KeepOtherJobs` leaves the jobs you did not ask for as they are instead of removing them.

Scheduled jobs can disappear or stop working silently. The jobs installed are recorded at install time, and every run checks that the others still exist, are not disabled, still point at existing files, did not fail on their last run, and have completed recently (update within 3 days, inventory and clean within 9). On Windows it also flags legacy launchers; on Linux it checks that a cron daemon runs (WSL starts none by default). It shows a desktop notification when something is wrong. Every notification is also written to `logs/notifications.log`, and `status` and `doctor` show the latest ones, so a notification that never reached the screen is not lost. State files are written atomically, so a crash never leaves a half-written file behind. Set `AICM_NOTIFY=0` to turn desktop notifications off.

## Logs and state

| File | Contents |
| --- | --- |
| `~/.ai-cli-auto-manager/logs/update-*.log`, `latest.log` | Update runs |
| `~/.ai-cli-auto-manager/logs/inventory-*.log` | Inventory runs |
| `~/.ai-cli-auto-manager/logs/clean-*.log` | Clean runs (files and bytes per rule) |
| `~/.ai-cli-auto-manager/inventory.md` | The last inventory as a readable table |
| `~/.ai-cli-auto-manager/state/last-update.json`, `inventory.json`, `last-clean.json` | Last run results (read by `status` and `doctor`) |
| `~/.ai-cli-auto-manager/state/schedule.json` | Installed jobs, their days and times, and the `PATH` the jobs get |
| `~/.ai-cli-auto-manager/logs/maintenance-*.jsonl`, `maintenance-*.txt` | Maintenance decisions and short daily summaries |
| `~/.ai-cli-auto-manager/state/last-maintenance.json` | Last maintenance mode, result and decisions |
| `~/.ai-cli-auto-manager/quarantine/` | Recoverable maintenance files, retained for at least 7 days |
| `~/.ai-cli-auto-manager/logs/notifications.log` | Every notification (last 500) |
| `~/.ai-cli-auto-manager/archive/` | Files moved by archive rules (per rule and date) |

Logs are kept for 30 days; change that with `LOG_RETENTION_DAYS` (or `-LogRetentionDays` on Windows). Set `AICM_HOME` to move everything elsewhere.

### Which folder the tool owns

`AICM_HOME` is used only when it is new or empty, carries the `.aicm-home` marker the tool wrote, or
is an unmarked folder of an older version that holds an installed copy (`app` with `SOURCE` and
`VERSION`) and otherwise only what the tool writes (`logs`, `state`, `archive`, `inventory.md`) or
what you add (`hooks/`, `*.local.conf`, `repos.conf`, `update-policy.json`); such a folder is marked
on its first real run. Anything else, a folder name alone (`.ai-cli-auto-manager`), a reserved folder
alone (`archive/<rule>/<date>`), a marker with other content, or your home folder itself is refused:
every run, `schedule install` and `--purge` stop before writing or deleting anything there. Help, bad
arguments and previews never create the marker.

The marker does not whitelist content. Before the installed copy is replaced, removed or purged,
`app` (and `app.new`/`app.old`) must hold only what a copy holds; a copy records its own file list in
`app/.aicm-copy`, so a personal file anywhere in it (`app/personal.txt`, `app/lib/notes.txt`) stops
the sync or uninstall with a message instead of being deleted. `uninstall --purge` (`-Purge`) removes
only log and state files under the names the tool uses and archived files listed in the archive index
(same size); unindexed files, even in a dated archive folder, and anything linked are kept and listed.
Your own files (`hooks/`, `*.local.conf`, `repos.conf`) stay, and the folder goes only when nothing is
left in it. `uninstall --purge --dry-run` (`-Purge -DryRun`) shows all of this without removing jobs,
the copy or data, and without writing a marker, log or state. A Windows `AICM_HOME` you point at a
junction still works; links and junctions inside it are never followed.

`archive list` reads the index newest first, at most 10000 records per page (`--offset` for older
ones). Files under `archive/` are called legacy only when the whole index (up to 100000 records) and
the archive folder could be read; otherwise the JSON says `"legacy": {"complete": false}` and none are
guessed. A real clean that ran an archive rule also runs `archive gc` under the same maintenance lock,
so expired and long-restored records do not pile up; pending, still-restorable and unreadable records
and any other file are never removed.

## Moving from 1.x (ai_cli_auto_update)

- The repository was renamed from `ai_cli_auto_update_public` to `ai_cli_auto_manager`; GitHub redirects the old URL.
- `bin/update_ai_clis.sh` and `bin/update_ai_clis.ps1` are still there, so existing automation keeps working.
- On Windows, an old `AI CLI Auto Update` task is left in place for separate review. `windows\install_scheduled_task.ps1` still works and registers only the update job, as before; Inventory and Clean jobs that are already registered stay as they are.
- Logs moved from `~/.ai-cli-auto-update` to `~/.ai-cli-auto-manager`. The old folder is left alone; delete it when you no longer need it.
- If you installed the old macOS template (`com.example.ai-cli-auto-update`), `aicm schedule install` prints the commands to remove it.

## Development and tests

See [CONTRIBUTING.md](CONTRIBUTING.md) for compatibility rules and contribution
checks, and [SECURITY.md](SECURITY.md) for vulnerability reporting.

All tests run in a throwaway home folder and never touch your real home folder or real scheduled tasks. Inventory, update and clean tests use fake CLIs, a fake npm and a fake codex, so no real CLI is run or updated. The Node tests build throwaway repositories and inject orphan-process snapshots. Containment tests terminate only the fixture processes they create.

```bash
shellcheck -x bin/aicm bin/*.sh lib/*.sh tests/*.sh
bash tests/clean_test.sh
python3 tests/cleanup_safety_test.py
bash tests/cache_budget_test.sh
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

```powershell
.\tests\clean_test.ps1
.\tests\cache_budget_test.ps1
.\tests\aicm_test.ps1
.\tests\inventory_test.ps1
.\tests\maintenance_json_test.ps1
.\tests\update_policy_test.ps1
.\tests\home_ownership_test.ps1
.\tests\unicode_paths_test.ps1
```

Release maintainers: see [docs/release-checklist.md](docs/release-checklist.md).

CI runs the same tests on Ubuntu, macOS (with the bash 3.2 that ships with it), Windows PowerShell 5.1 and PowerShell 7.

## Follow-up

Categories, JSON, restore, local history, and update verification are in this iteration. Exact Windows and Linux runs of that work are still pending; configured CI is not a record that this checkout ran there.

Per-CLI pin, exclude, and waiting-period policies, cache budget rules and the opt-in `optimize`
command are in this iteration. Not in this release, left for later: flushing the OS DNS cache,
resetting the macOS QuickLook cache, and SQLite `VACUUM` of tool databases. An optional TUI may come later.

## Limitations

- Built for personal machines and small teams; for organization-wide rollout, add your own change management.
- There is no automatic rollback to a previous version.
- Budget and optimize report logical bytes and command results, not measured free disk space; pruned
  caches are downloaded again when needed.
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
