# Automatic maintenance

Maintenance needs Node.js 22 or newer. It runs offline and defaults to **dry-run**. It does not
install schedules or apply cleanup just because the command is run.

```bash
./bin/aicm maintenance                        # preview; write action log and summary
./bin/aicm maintenance --apply                # act only on verified owned processes/files
./bin/aicm maintenance --apply --dry-run      # dry-run wins regardless of flag order
./bin/aicm maintenance --files-only --json
./bin/aicm maintenance --processes-only
./bin/aicm run -- claude --version            # contained, tagged CLI session
./bin/aicm schedule install                   # includes hourly dry-run maintenance
./bin/aicm schedule install --maintenance-apply
./bin/aicm schedule install --no-maintenance
```

```powershell
.\bin\aicm.ps1 maintenance                    # preview
.\bin\aicm.ps1 maintenance -Apply -Json
.\bin\aicm.ps1 maintenance -FilesOnly
.\bin\aicm.ps1 run -Cli claude -CliArguments @('--version')
.\bin\aicm.ps1 schedule install -MaintenanceApply
.\bin\aicm.ps1 schedule install -NoMaintenance
```

The existing update, inventory and clean jobs keep their schedules. The new job runs hourly at
minute 7: `\AI CLI Auto Manager\Maintenance` on Windows, the existing LaunchAgent prefix plus
`.maintenance` on macOS, or a crontab line tagged `# aicm:maintenance` on Linux. It runs the installed
copy, and refresh preserves the dry-run/apply choice. Refreshing an older installation leaves its
job selection unchanged; run `schedule install` to add Maintenance. `status` shows it and `doctor`
reports it when missing or without a completed run for a day. No new task is installed on the
machine used to develop this feature.

## Process lifetime and orphan safety

Update, inventory, clean and `run` establish a containment boundary before launching CLIs. Children
inherit `AI_CLI_MANAGER_SESSION`, an opaque random session ID. Command arguments and environment
blocks are never put into action logs.

On Unix a separate guardian launches the command in a new session/process group. It watches the
launcher IPC connection and the launcher's parent identity. Normal command exit, timeout, signals,
parent exit and launcher `SIGKILL` trigger group TERM, a one-second grace period, then KILL. Cleanup
also runs when the immediate CLI exits while a grandchild is still alive. The guardian stays outside
the command group. Node.js is required for these Unix entry points; an uncontained fallback is not
used when Node is missing. If the guardian itself is forcibly killed, the hourly scanner can recover
tagged leftovers; no userspace Unix guardian can run cleanup after its own `SIGKILL`.

On Windows each CLI command has its own Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
The manager creates the command suspended, assigns its Job before user code can run, captures the
process handle, and then resumes it. Its only Job handle is non-inheritable and owned by the manager.
Closing it on command completion, manager exit or crash ends all descendants, even if an intermediate
parent already exited. Failed assignment refuses an uncontained launch. Timeout cleanup first requests
tree termination, waits, then forces survivors. Explicit `run` sessions contain the launcher too.
Post-update hooks remain outside these command Jobs and clear the manager session marker, so deliberately restarted daemons such as Paseo
can continue running after the update finishes. The shared PowerShell command wrapper tags and
records individual launches.

The scanner automatically ends a tree/group **only with explicit apply** and verified manager ownership:

- Tagged processes whose parent died or whose recorded manager session ended qualify. It compares
  creation times as well as PIDs, and rechecks identity, tree and group membership before signaling.
- Untagged `node`, `python` or `bun` orphans are **alert-only**, even with apply, and only after at least
  six hours with a listening TCP port. Runtime names alone never authorize termination.
- System/service accounts, elevated or unverifiable processes, other users' processes, Paseo daemons,
  SSH/remote session trees, live manager sessions and running agent-session trees stay. A Unix group
  with an untagged, other-session or protected member is alert-only.
- Linux reads the marker from `/proc`; macOS reads it through `ps`. Windows uses private launch records
  matched by PID plus creation time and verified parent inheritance, since supported Windows process
  APIs do not expose other processes' environment blocks. An unidentifiable leftover stays.

`aicm processes --kill` / `-Kill` now uses this same ownership-aware apply path. The old
`AICM_KILL_ORPHANS=1` name-based automatic kill behavior is retired. `--min-age-hours` remains accepted
for compatibility but cannot lower the six-hour untagged alert threshold. A missing listening-port
inspection tool suppresses untagged alerts; it never authorizes a kill. The scanner never modifies
startup entries, registry settings or scheduled tasks.

## Declarative file cleanup and recovery

The pipe-delimited format follows the repository's existing rule conventions. Built-in rows are in
[`rules/maintenance.conf`](../rules/maintenance.conf). Local rows in
`~/.ai-cli-auto-manager/maintenance.local.conf` override by ID. Use `--config path` / `-ConfigFile path`
for another base file; the local overrides are still loaded.

```text
# id | path | max-age-days | excludes (comma-separated globs)
manager-temp | {aicm}/tmp | 2 | *.lock,keep/**
manager-cache | {aicm}/cache | 2 | *.lock,keep/**
my-cli-scratch | ~/.cache/my-cli/scratch | 14 | *.lock,active/**
```

The default roots contain only scratch/cache you place under the manager home. General OS temp,
shared npm/pip caches, conversations and user projects are not included. Existing `aicm clean` rules
and their archive/delete behavior remain separate; use `maintenance` for this quarantine policy.

A local root must be strictly below the user's home or a safe temp directory. A home/drive root,
manager state/log/app/hook/archive/quarantine directory, symlink/junction or linked ancestor is
refused. Ages must be at least two days. A file qualifies only when its last access, modification
and birth times are all old enough. Excludes match a basename or a relative path; `*`, `?` and `**`
are supported. Directories are traversed without following links and stay in place.

Memory, credentials, settings, private keys, environment files, SQLite databases/sidecars, hardlinked
files, readonly files and excluded entries stay. On Unix `lsof` must prove files are idle; unavailable
or inconclusive inspection keeps them. On Windows native exclusive handles reject even an open reader
that allowed delete sharing. Files on another volume stay; there is no copy-and-delete fallback.
A backward clock or a jump over 400 days withholds file changes until the clock is corrected or an
explicit `AICM_CLOCK_CHECK=0` run accepts it. The last accepted clock is retained across refused runs.

Apply moves each eligible file into:

```text
~/.ai-cli-auto-manager/quarantine/<random-id>/payload
~/.ai-cli-auto-manager/quarantine/<random-id>/manifest.json
```

The manifest records the original absolute path, size and quarantine time **before** the rename.
Restore by checking that original destination is safe and unoccupied, then moving `payload` back to
that path. Moving files into quarantine does not free disk space. After seven complete days in
quarantine, a later apply run purges an idle payload and its own metadata. Dry-run previews that purge.
Malformed, linked, unexpectedly populated or locked quarantine entries stay. Uninstall deliberately
keeps quarantine so it cannot bypass the seven-day recovery window.

## Action logs, summary and version floor

Every run and decision has a timestamp, mode, action and reason in
`logs/maintenance-YYYY-MM-DD.jsonl` (UTC dates). A small `maintenance-YYYY-MM-DD.txt` summary accumulates
that day's action counts, and `state/last-maintenance.json` records the last result. Files are private
where the OS supports Unix modes. Errors fail the command; failures to inspect processes cannot turn
into permission to terminate them. A lock excludes concurrent runs. A stale `state/maintenance.lock`
can be removed after verifying its recorded PID is no longer running.

The last inventory supplies installed CLI versions without launching an extra CLI hourly. Claude Code
below **2.1.283** produces a warning with an update command; maintenance never updates software itself.
An absent/unknown inventory version cannot be checked. Refresh inventory with `aicm inventory --offline`
first. Override floors in `~/.ai-cli-auto-manager/version-floors.json`, e.g.:

```json
{ "claude": "2.1.283", "codex": "0.157.1" }
```

## Validation

```bash
node --test tests/node/*.test.js
bash tests/aicm_test.sh
bash tests/clean_test.sh
bash tests/inventory_test.sh
python3 tests/cleanup_safety_test.py
bash tests/codex_host_test.sh
shellcheck -x bin/aicm bin/*.sh lib/*.sh tests/*.sh
```

```powershell
.\tests\auto_maintenance_test.ps1
.\tests\aicm_test.ps1
.\tests\clean_test.ps1
.\tests\inventory_test.ps1
```

All native termination tests create their own fixture processes and record their PIDs. Orphan scans
use injected adapters for tests; no test scans and kills the host's processes. The separate automatic
maintenance CI workflow runs these additions on Linux/macOS/Windows and tests Job Objects and native
locked-file moves on both Windows PowerShell 5.1 and PowerShell 7.

Implementation references: [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
[setsid](https://www.man7.org/linux/man-pages/man2/setsid.2.html),
[Node.js detached children](https://nodejs.org/api/child_process.html#optionsdetached).
