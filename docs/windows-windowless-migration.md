# Windows scheduled-task migration

Microsoft has [deprecated VBScript](https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features).
The manager's tasks use a GUI-subsystem executable built from `windows/aicm-windowless.cs` with the
.NET Framework compiler. It starts Windows PowerShell with `CREATE_NO_WINDOW` and returns its exit
code. The launcher is stored outside the installed app, so an app update does not replace a running
executable. Installation refuses to change tasks if the compiler is unavailable or the launcher
does not pass its integrity check.

`windows/run-hidden.vbs` is retained only as a compatibility bridge: older installed updaters require
the file to exist before they will copy a new version. New scheduled actions never invoke it. Keep it
until old installations have been migrated; removing it immediately would prevent those installations
from refreshing themselves. It can also be needed when explicitly restoring an older task action.

## Manager tasks

Review the existing task definitions and wait until none are running. From the new source checkout,
run the following only when ready to change the installed tasks:

```powershell
.\bin\aicm.ps1 schedule refresh
```

Before changing a managed task, the command copies the old app and exports XML for the existing
Update, Inventory, Clean and Maintenance tasks into a unique folder under the current user's
`%LOCALAPPDATA%\AI CLI Auto Manager\w-<home hash>\backups\`. The command prints that
folder as `schedule backup: ...`. It refuses unexpected legacy task actions, links or an unowned app
copy. The action migration preserves the previous PowerShell arguments, working directory, triggers,
principal and settings. It neither starts the scheduled work nor creates an extra Maintenance task.

If a migration needs to be rolled back, wait for the tasks to be idle, then run from the new checkout:

```powershell
.\windows\restore-schedule-backup.ps1 -BackupDir 'C:\path\printed\after\schedule backup'
```

The restore verifies the backup hashes, takes another backup of the current state, restores the old
installed copy and task actions, and keeps the replaced copy next to the app. It changes the task
actions only: existing triggers, principal and settings stay in place. Restoring an old action can
reintroduce the old VBScript dependency; use this when rolling back intentionally. The backup contains
local paths and task definitions; protect it as user data.

## Tasks outside this repository

The manager does not install or modify `Paseo-Session-Cleanup` or other unrelated tasks. Audit
scheduled tasks without printing their arguments:

```powershell
Get-ScheduledTask | Where-Object {
  @($_.Actions | Where-Object {
    [string]$_.Execute -match '(?i)(?:^|[\\/])(?:wscript|cscript)(?:\.exe)?$' -or
    [string]$_.Execute -match '(?i)\.vbs$' -or
    [string]$_.Arguments -match '(?i)(?:^|[\\/\s"])(?:wscript|cscript)(?:\.exe)?(?:\s|"|$)' -or
    [string]$_.Arguments -match '(?i)\.vbs(?:\s|"|$)'
  }).Count -gt 0
} | Select-Object TaskPath, TaskName
```

An external task can be migrated separately by exporting its XML, extracting the existing PowerShell
arguments from its current action, and replacing only the action with the manager's compiled
windowless launcher. Verify the XML's triggers, principal, settings and original script arguments
before and after. For Paseo-Session-Cleanup, retain both `--dry-run` and `--min-age-hours 168`;
do not switch it to a real cleanup. Save the XML outside temporary directories so the old action
can be reconstructed with `Set-ScheduledTask -Action` if needed. Do not change a task whose action
or ownership cannot be established.

The repository's Windows CI exercises the launcher with throwaway scripts and tasks. A 100 ms
window sample on the actual desktop provides evidence for that execution, but cannot prove no
shorter-lived window appeared between samples or observe windows on another desktop/session.
After approval to start the actual tasks, run the observer from the interactive desktop session:

```powershell
.\windows\check-scheduled-windows.ps1 -OutputDir 'C:\path\to\new\audit-folder' -RunTasks -IncludeExternalPaseo
```

This starts Clean, Inventory and Update, and the separately managed Paseo task when requested.
Update and Clean are real operations; Paseo is refused unless its current arguments still include
`--dry-run --min-age-hours 168`. The report records each new matching window's owner and parent
chain, completion result, maximum sample interval, and remaining tasks using VBScript. A result
is inconclusive if the task process was not observed, the session differs, sampling falls behind, or
an observed window cannot be attributed. Existing unrelated VBScript tasks remain listed.
