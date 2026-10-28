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

Review the existing task definitions and wait until none are running. To keep every file in the
current installed app and its source checkout exactly as they are, run this from the new checkout
only when ready to change the managed task actions:

```powershell
.\windows\migrate-windowless-tasks.ps1
```

This builds the launcher, saves task XML and a copy of the current app, converts recognized managed
actions, and records the launcher type in the schedule state. It does not replace the app or its
`SOURCE` file. An older installed app still contains its old schedule-registration code; manually
running that older code could restore the old actions. Upgrade it separately after reviewing any local
changes if you want the new registration behavior there too.

Alternatively, to upgrade the installed app and migrate its tasks together, run:

```powershell
.\bin\aicm.ps1 schedule refresh
```

If the existing source checkout contains local changes, use a separate checkout for this migration
and add `-PreserveSource`. That copies the reviewed version into the app while retaining the original
`SOURCE` and schedule source path for future updates:

```powershell
.\bin\aicm.ps1 schedule refresh -PreserveSource
```

For an existing version 2.10.0 or older, run this refresh from the new checkout before allowing the
old daily updater to refresh the app if rollback to the old app version is required. The old updater
swaps the installed copy before it can call the new migration code; in that automatic path, the XML
backup is still made before task actions change, but the backup app may already be the newer version.

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

For a launcher-only migration where the installed app has not been upgraded, add `-ActionsOnly` to
restore the task actions and schedule state without replacing the app:

```powershell
.\windows\restore-schedule-backup.ps1 -BackupDir 'C:\path\printed\after\schedule backup' -ActionsOnly
```

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

For the stated legacy Paseo task, after separate review and approval, this example saves its XML and
changes only its action. Replace the backup path with a new file in an existing protected directory.
The script preserves all PowerShell arguments and refuses the change if the dry-run settings differ.

```powershell
$backupFile = 'C:\path\to\protected\new-paseo-task-backup.xml'
$task = Get-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup' -ErrorAction Stop
if (@($task.Actions).Count -ne 1 -or $task.State -in @('Running', 'Queued')) { throw 'Task must be idle with one action' }
$old = @($task.Actions)[0]
$text = [string]$old.Arguments
if ([string]$old.Execute -notmatch '(?i)(?:^|[\\/])wscript(?:\.exe)?$' -or
    $text -notmatch '(?i)^\s*(?:(?://B|//Nologo)\s+)*"[^"]+run-hidden\.vbs"\s+"?powershell(?:\.exe)?"?\s+(?<ps>.+)$') {
  throw 'Unrecognized legacy action'
}
$psArguments = $Matches.ps
if ($psArguments -notmatch '(?i)(?:^|\s)--dry-run(?:\s|$)' -or
    $psArguments -notmatch '(?i)(?:^|\s)--min-age-hours\s+168(?:\s|$)' -or
    $psArguments -notmatch '(?i)cleanup_paseo_sessions\.ps1') { throw 'Required dry-run arguments are missing' }
$managed = Get-ScheduledTask -TaskPath '\AI CLI Auto Manager\' -TaskName 'Update' -ErrorAction Stop
$launcher = [string]$managed.Actions[0].Execute
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf) -or
    [IO.Path]::GetFileName($launcher) -notmatch '^aicm-run-[0-9a-f]{24}\.exe$') { throw 'Verified manager launcher is unavailable' }
$xml = [string](Export-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup')
[xml]$oldDefinition = $xml
$oldSections = $oldDefinition.Task.Triggers.OuterXml + $oldDefinition.Task.Principals.OuterXml + $oldDefinition.Task.Settings.OuterXml
$stream = [IO.File]::Open($backupFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $bytes = [Text.Encoding]::UTF8.GetBytes($xml); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
if ([IO.File]::ReadAllText($backupFile) -cne $xml) { throw 'Backup verification failed' }
$actionArgs = @{ Execute = $launcher; Argument = $psArguments }
if ($old.WorkingDirectory) { $actionArgs.WorkingDirectory = [string]$old.WorkingDirectory }
Set-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup' -Action (New-ScheduledTaskAction @actionArgs) | Out-Null
$updated = Get-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup'
[xml]$newDefinition = Export-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup'
$newSections = $newDefinition.Task.Triggers.OuterXml + $newDefinition.Task.Principals.OuterXml + $newDefinition.Task.Settings.OuterXml
if ($newSections -cne $oldSections -or [string]$updated.Actions[0].Arguments -cne $psArguments) {
  throw 'The task differs from the backup; inspect it and use the rollback instructions below'
}
```

To restore that task's old action from its saved XML without changing its current schedule, account
or settings:

```powershell
[xml]$xml = [IO.File]::ReadAllText($backupFile)
$saved = @($xml.Task.Actions.Exec)
if ($saved.Count -ne 1) { throw 'Expected one saved executable action' }
$commandNode = $saved[0].SelectSingleNode("*[local-name()='Command']")
$argumentNode = $saved[0].SelectSingleNode("*[local-name()='Arguments']")
$directoryNode = $saved[0].SelectSingleNode("*[local-name()='WorkingDirectory']")
$restoreArgs = @{ Execute = [string]$commandNode.InnerText }
if ($argumentNode -and $argumentNode.InnerText) { $restoreArgs.Argument = [string]$argumentNode.InnerText }
if ($directoryNode -and $directoryNode.InnerText) { $restoreArgs.WorkingDirectory = [string]$directoryNode.InnerText }
Set-ScheduledTask -TaskPath '\' -TaskName 'Paseo-Session-Cleanup' -Action (New-ScheduledTaskAction @restoreArgs) | Out-Null
```

The repository's Windows CI exercises the launcher with throwaway scripts and tasks. A 100 ms
window sample on the actual desktop provides evidence for that execution, but cannot prove no
shorter-lived window appeared between samples or observe windows on another desktop/session.
After approval to start the actual tasks, run the observer from the interactive desktop session:

```powershell
.\windows\check-scheduled-windows.ps1 -OutputDir 'C:\path\to\new\audit-folder' -RunTasks -IncludeExternalPaseo
```

This starts Clean, Inventory and Update, and the separately managed Paseo task when requested.
Update and Clean are real operations; Paseo is refused unless its current arguments still include
`--dry-run --min-age-hours 168`. If a post-update hook exists, the observer refuses to start any
task; use `-SkipUpdate` to observe the others and review the hook's effects separately before
arranging a live Update. The report records each new matching window's owner and parent
chain, completion result, maximum sample interval, and remaining tasks using VBScript. A result
is inconclusive if the task process was not observed, the session differs, sampling falls behind, or
an observed window cannot be attributed. Existing unrelated VBScript tasks remain listed.
