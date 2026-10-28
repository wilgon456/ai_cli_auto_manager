<#
.SYNOPSIS
  AI CLI Auto Manager for Windows: keeps AI coding CLIs updated and their leftovers cleaned.
.DESCRIPTION
  aicm.ps1 update    [-DryRun] [-Targets codex,claude] [-InstallMissing]
  aicm.ps1 inventory [-Offline]   list installed AI CLIs, their versions and update coverage
  aicm.ps1 clean     [-DryRun] [-Rules id,id] [-Category list] [-Json] [-Explain]
  aicm.ps1 archive list [-Json] [-Limit N] [-Offset N]   newest first
  aicm.ps1 archive gc [-DryRun] [-Json]   drop index records of expired or long-restored archives
  aicm.ps1 restore ID [-DryRun] [-Json]
  aicm.ps1 history   [-Limit N] [-Json]
  aicm.ps1 worktrees [-Apply] [-Days 14]   worktrees and branches agents left behind (report unless -Apply)
  aicm.ps1 config    MCP servers and skills compared across the installed CLIs
  aicm.ps1 processes [-Kill]   agent processes left running after their session ended
  aicm.ps1 optimize  [-DryRun | -Apply] [-Tasks npm-verify,uv-prune,pnpm-prune] [-Json]
                     preview by default; -Apply runs npm cache verify, uv cache prune, pnpm store prune (needs Node.js)
  aicm.ps1 status    disk use per cleanup rule, schedules, last runs
  aicm.ps1 doctor    exit 1 when a schedule is missing, a run is overdue or failed, or a setting is invalid
  aicm.ps1 uninstall [-Purge] [-DryRun]
  aicm.ps1 schedule  install | remove | show | refresh   [-UpdateAt 05:00] [-InventoryDay Monday] [-InventoryAt 12:00]
                                               [-CleanDay Monday] [-CleanAt 12:30] [-CleanCategory list] [-NoUpdate] [-NoInventory] [-NoClean] [-NoMaintenance] [-MaintenanceApply]
  aicm.ps1 version
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('update', 'inventory', 'clean', 'archive', 'restore', 'history', 'worktrees', 'config', 'processes', 'optimize', 'maintenance', 'run', 'status', 'doctor', 'schedule', 'uninstall', 'version', 'help')]
  [string]$Command = 'help',
  [Parameter(Position = 1)]
  [string]$Action = '',
  [Alias('Check')]
  [switch]$DryRun,
  [string[]]$Targets = @(),
  [string[]]$Tasks = @(),
  [switch]$InstallMissing,
  [switch]$Offline,
  [string[]]$Rules = @(),
  [string[]]$Category = @(),
  [switch]$Json,
  [switch]$Explain,
  [int]$LogRetentionDays = 30,
  [string]$UpdateAt = '05:00',
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
  [string]$InventoryDay = 'Monday',
  [string]$InventoryAt = '12:00',
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
  [string]$CleanDay = 'Monday',
  [string]$CleanAt = '12:30',
  [string[]]$CleanCategory = @(),
  [int]$Limit = 20,
  [int]$Offset = 0,
  [string]$ArchiveId = '',
  [switch]$NoUpdate,
  [switch]$NoInventory,
  [switch]$NoClean,
  [switch]$NoMaintenance,
  [switch]$MaintenanceApply,
  [string]$Cli = '',
  [string[]]$CliArguments = @(),
  [string]$ConfigFile = '',
  [switch]$FilesOnly,
  [switch]$ProcessesOnly,
  [switch]$KeepLegacyTask,
  [switch]$KeepOtherJobs,
  [switch]$Apply,
  [int]$Days = 0,
  [switch]$Kill,
  [int]$MinAgeHours = 0,
  [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$binDir = $PSScriptRoot
. (Join-Path (Split-Path -Parent $binDir) 'lib\aicm-common.ps1')
. (Join-Path (Split-Path -Parent $binDir) 'lib\aicm-scheduler.ps1')

$legacyTaskName = 'AI CLI Auto Update'

function Show-Help {
  Write-Host "AI CLI Auto Manager $(Get-AicmVersion)"
  Write-Host ''
  Write-Host '  aicm.ps1 update    [-DryRun] [-Targets codex,claude] [-InstallMissing]'
  Write-Host '  aicm.ps1 inventory [-Offline]'
  Write-Host '  aicm.ps1 clean     [-DryRun] [-Rules id,id] [-Category list] [-Json] [-Explain]
  aicm.ps1 archive list [-Json] [-Limit N] [-Offset N]
  aicm.ps1 archive gc [-DryRun] [-Json]
  aicm.ps1 restore ID [-DryRun] [-Json]
  aicm.ps1 history   [-Limit N] [-Json]'
  Write-Host '  aicm.ps1 worktrees [-Apply] [-Days 14]'
  Write-Host '  aicm.ps1 config'
  Write-Host '  aicm.ps1 processes [-Kill]'
  Write-Host '  aicm.ps1 maintenance [-DryRun|-Apply] [-Json] [-ConfigFile path] [-FilesOnly|-ProcessesOnly]'
  Write-Host "  aicm.ps1 run -Cli claude -CliArguments @('--version')"
  Write-Host '  aicm.ps1 optimize  [-DryRun | -Apply] [-Tasks npm-verify,uv-prune,pnpm-prune] [-Json]   preview unless -Apply'
  Write-Host '  aicm.ps1 status'
  Write-Host '  aicm.ps1 doctor'
  Write-Host '  aicm.ps1 schedule  install|remove|show|refresh [-UpdateAt 05:00] [-InventoryDay Monday] [-InventoryAt 12:00]'
  Write-Host '                     [-CleanDay Monday] [-CleanAt 12:30] [-CleanCategory list] [-NoUpdate] [-NoInventory] [-NoClean] [-NoMaintenance] [-MaintenanceApply] [-KeepOtherJobs]'
  Write-Host '  aicm.ps1 uninstall [-Purge] [-DryRun]   -DryRun lists what would be removed and changes nothing'
  Write-Host '  aicm.ps1 version'
}

function Get-StateAgeText($State) {
  if (-not $State) { return 'never' }
  try {
    $when = [datetime]::Parse($State.finishedAt).ToLocalTime()
    $age = (Get-Date) - $when
    $ago = if ($age.TotalDays -ge 1) { '{0:N0}d ago' -f $age.TotalDays } else { '{0:N0}h ago' -f $age.TotalHours }
    $result = if ($State.ok) { 'ok' } else { 'FAILED' }
    return "$($when.ToString('yyyy-MM-dd HH:mm')) ($ago, $result)"
  } catch {
    return 'unreadable'
  }
}

function Get-StateAgeDays($State) {
  if (-not $State) { return [double]::PositiveInfinity }
  try { return ((Get-Date) - [datetime]::Parse($State.finishedAt).ToLocalTime()).TotalDays } catch { return [double]::PositiveInfinity }
}

# The GUI-subsystem launcher starts a console-free PowerShell and passes its exit code through.
function New-TaskAction([string]$App, [string]$Script, [string[]]$Extra, [string]$Launcher) {
  $ps = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $App "bin\$Script"))) + $Extra
  return (New-ScheduledTaskAction -Execute $Launcher -Argument ($ps -join ' '))
}

# HH:MM or H:MM with hour 0-23 and minute 0-59.
function Test-TimeText([string]$Text) { return ($Text -match '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') }

$script:JobNames = @('Update', 'Inventory', 'Clean', 'Maintenance')
$script:DayBits = [ordered]@{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }

function Get-DefaultScheduleOptions {
  return [ordered]@{ updateAt = '05:00'; inventoryDay = 'Monday'; inventoryAt = '12:00'; cleanDay = 'Monday'; cleanAt = '12:30'; cleanCategory = ''; targets = ''; installMissing = $false; logRetentionDays = 30; maintenanceApply = $false }
}

# The options given on the command line.
function Get-ParamScheduleOptions {
  return [ordered]@{
    updateAt = $UpdateAt; inventoryDay = $InventoryDay; inventoryAt = $InventoryAt; cleanDay = $CleanDay; cleanAt = $CleanAt
    cleanCategory = ((@($CleanCategory) | ForEach-Object { "$_" }) -join ',')
    targets = ($Targets -join ','); installMissing = [bool]$InstallMissing; logRetentionDays = $LogRetentionDays; maintenanceApply = [bool]$MaintenanceApply
  }
}

# The options the schedule was installed with: stored in schedule.json, or (schedules installed by
# 2.5.1 and older) read back from the registered tasks.
function Get-InstalledScheduleOptions($Sched) {
  $o = Get-DefaultScheduleOptions
  if ($Sched -and $Sched.PSObject.Properties['options'] -and $Sched.options) {
    foreach ($k in @($o.Keys)) { if ($Sched.options.PSObject.Properties[$k]) { $o[$k] = $Sched.options.$k } }
    $o.installMissing = [bool]$o.installMissing
    $o.logRetentionDays = [int]$o.logRetentionDays
    return $o
  }
  $at = { param($Task) try { ([datetime]$Task.Triggers[0].StartBoundary).ToString('HH:mm') } catch { $null } }
  $day = {
    param($Task)
    $bits = 0
    if ($Task.Triggers[0].PSObject.Properties['DaysOfWeek']) { $bits = [int]$Task.Triggers[0].DaysOfWeek }
    foreach ($k in $script:DayBits.Keys) { if ($bits -band $script:DayBits[$k]) { return $k } }
    return $null
  }
  $u = Get-AicmTask 'Update'
  if ($u) {
    $t = & $at $u; if ($t) { $o.updateAt = $t }
    $a = [string]$u.Actions[0].Arguments
    if ($a -match '-Targets "([^"]*)"') { $o.targets = $Matches[1] }
    if ($a -match '-LogRetentionDays (\d+)') { $o.logRetentionDays = [int]$Matches[1] }
    $o.installMissing = ($a -match '-InstallMissing')
  }
  foreach ($pair in @(@('Inventory', 'inventory'), @('Clean', 'clean'))) {
    $task = Get-AicmTask $pair[0]
    if (-not $task) { continue }
    $t = & $at $task; if ($t) { $o["$($pair[1])At"] = $t }
    $d = & $day $task; if ($d) { $o["$($pair[1])Day"] = $d }
    if ($pair[0] -eq 'Clean') {
      $a = [string]$task.Actions[0].Arguments
      if ($a -match '-Category\s+"([^"]+)"') { $o.cleanCategory = $Matches[1] }
      elseif ($a -match '-Category\s+(\S+)') { $o.cleanCategory = $Matches[1] }
    }
  }
  return $o
}

# Action and trigger of one job, built from the options.
function Get-JobSpec([string]$Name, $Opt, [string]$App, [string]$Launcher) {
  $retention = @('-LogRetentionDays', "$($Opt.logRetentionDays)")
  switch ($Name) {
    'Update' {
      $extra = $retention
      if ($Opt.targets) { $extra += @('-Targets', "`"$($Opt.targets)`"") }
      if ($Opt.installMissing) { $extra += '-InstallMissing' }
      $extra += '-Scheduled'
      $trigger = New-ScheduledTaskTrigger -Daily -At $Opt.updateAt
      # Retry every 3 hours for 15 hours: a CLI that was running at 05:00 is updated once it is closed.
      # A run after a complete success the same day exits right away.
      $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $Opt.updateAt -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Hours 15)).Repetition
      return @{ Action = (New-TaskAction $App 'update_ai_clis.ps1' $extra $Launcher); Trigger = $trigger
        Description = 'AI CLI Auto Manager: update installed AI coding CLIs'; Text = "daily at $($Opt.updateAt) (retried every 3 hours until it succeeds)" }
    }
    'Inventory' {
      return @{ Action = (New-TaskAction $App 'inventory_ai_clis.ps1' $retention $Launcher); Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Opt.inventoryDay -At $Opt.inventoryAt)
        Description = 'AI CLI Auto Manager: list installed AI coding CLIs'; Text = "every $($Opt.inventoryDay) at $($Opt.inventoryAt)" }
    }
    'Maintenance' {
      $mode = if ($Opt.maintenanceApply) { '-Apply' } else { '-DryRun' }
      $trigger = New-ScheduledTaskTrigger -Daily -At '00:07'
      $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:07' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
      return @{ Action = (New-TaskAction $App 'aicm.ps1' @('maintenance', $mode) $Launcher); Trigger = $trigger
        Description = 'AI CLI Auto Manager: owned orphan and cache maintenance'; Text = 'hourly (dry-run unless explicitly enabled)' }
    }
    'Clean' {
      $extra = @() + $retention
      if ($Opt.cleanCategory) { $extra += @('-Category', "$($Opt.cleanCategory)") }
      return @{ Action = (New-TaskAction $App 'clean_ai_leftovers.ps1' $extra $Launcher); Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Opt.cleanDay -At $Opt.cleanAt)
        Description = 'AI CLI Auto Manager: remove stale AI CLI leftovers'; Text = "every $($Opt.cleanDay) at $($Opt.cleanAt)" }
    }
  }
}

# What decides whether a registered task already matches: program, arguments, trigger kind, time, days, repetition.
function Get-TaskSignature($Action, $Trigger) {
  $at = ''
  try { $at = ([datetime]$Trigger.StartBoundary).ToString('HH:mm') } catch { }
  $days = ''
  if ($Trigger.PSObject.Properties['DaysOfWeek']) { $days = [string]$Trigger.DaysOfWeek }
  $rep = ''
  if ($Trigger.PSObject.Properties['Repetition'] -and $Trigger.Repetition -and $Trigger.Repetition.Interval) { $rep = "$($Trigger.Repetition.Interval)/$($Trigger.Repetition.Duration)" }
  return "$($Action.Execute)|$($Action.Arguments)|$($Trigger.CimClass.CimClassName)|$at|$days|$rep"
}

# The clone the installed copy came from (when this runs from the installed copy itself).
function Get-ScheduleSource([string]$App) {
  $sourceFile = Join-Path $App 'SOURCE'
  if ((Test-AicmSamePath (Get-AicmRoot) $App) -and (Test-Path -LiteralPath $sourceFile)) { return (Read-AicmUtf8FirstLine $sourceFile) }
  return (Get-AicmRoot)
}

# Registers $Want with the options $Opt; tasks that already match are left alone, so running it again
# changes nothing. Jobs not in $Want are removed, or kept as they are with -KeepOthers.
# -Refresh: called after the installed copy was updated; keeps installedAt and does not touch the legacy task.
function Install-Schedule($Opt, [string[]]$Want, [switch]$KeepOthers, [switch]$Refresh) {
  if (@($Want).Count -eq 0) { throw 'nothing to install: all four jobs were excluded' }
  if ($Opt.cleanCategory) {
    try { $Opt.cleanCategory = (@(ConvertTo-AicmCategoryList ([string]$Opt.cleanCategory)) -join ',') }
    catch { throw $_.Exception.Message }
  }
  foreach ($k in 'updateAt', 'inventoryAt', 'cleanAt') {
    if (-not (Test-TimeText $Opt[$k])) { throw "invalid time '$($Opt[$k])' for $k`: use HH:MM with hour 0-23 and minute 0-59, like 05:00" }
  }
  # Options are valid. Only then claim the home (a folder this tool did not create is refused untouched).
  Confirm-AicmHome
  $prev = Read-AicmState 'schedule'
  $jobs = New-Object System.Collections.Generic.List[string]
  $existingNames = @($script:JobNames | Where-Object { Get-AicmTask $_ })
  # Compile and record the old definitions/copy before changing either tasks or app.
  $launcher = Initialize-AicmWindowlessLauncher (Get-AicmRoot)
  $backup = New-AicmScheduleBackup $existingNames $script:AicmTaskPath
  $migrated = @()
  if ($backup) {
    Write-Host "schedule backup: $backup"
    $migrated = @(Convert-AicmLegacyTasks $existingNames $script:AicmTaskPath $launcher $backup)
  }
  try { $app = Sync-AicmAppCopy (Get-AicmRoot) }
  catch {
    if ($backup) { try { Restore-AicmTaskActions $backup } catch { Write-Warning "Could not restore all task actions; use backup $backup" } }
    throw
  }
  if (-not $Refresh) { Write-Host "installed copy: $app (version $(Get-AicmVersion))" }
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  $changed = ($migrated.Count -gt 0)
  foreach ($name in $script:JobNames) {
    $existing = Get-AicmTask $name
    if ($Want -contains $name) {
      $spec = Get-JobSpec $name $Opt $app $launcher
      $same = $existing -and (Get-TaskSignature $existing.Actions[0] $existing.Triggers[0]) -eq (Get-TaskSignature $spec.Action $spec.Trigger)
      # A freshly migrated action retains its original arguments; every refresh retains the trigger.
      if ($existing -and $Refresh) {
        $same = ($migrated -contains $name) -or
          ($existing.Actions[0].Execute -eq $spec.Action.Execute -and $existing.Actions[0].Arguments -eq $spec.Action.Arguments)
      }
      if ($same) {
        if (-not $Refresh) { Write-Host ("unchanged:  {0}{1,-10} {2}" -f $script:AicmTaskPath, $name, $spec.Text) }
      } else {
        if ($existing) {
          # Existing principal and settings stay. Refresh never replaces the trigger.
          if ($Refresh) {
            Set-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Action $spec.Action -ErrorAction Stop | Out-Null
          } else {
            Set-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Action $spec.Action -Trigger $spec.Trigger -ErrorAction Stop | Out-Null
          }
        } else {
          Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Action $spec.Action -Trigger $spec.Trigger -Settings $settings -Description $spec.Description -Force | Out-Null
        }
        Write-Host ("registered: {0}{1,-10} {2}" -f $script:AicmTaskPath, $name, $spec.Text)
        $changed = $true
      }
      $jobs.Add($name)
    } elseif ($KeepOthers -or $Refresh) {
      if ($existing) { $jobs.Add($name) }
    } elseif ($existing) {
      Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Confirm:$false
      Write-Host "removed: $($script:AicmTaskPath)$name"
      $changed = $true
    }
  }
  if (-not $Refresh -and -not $KeepLegacyTask -and (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
    Write-Host "kept legacy task: \$legacyTaskName; review it separately before removing it"
  }
  $installedAt = Get-AicmTimestamp
  if ($Refresh -and $prev -and $prev.PSObject.Properties['installedAt']) { $installedAt = [string]$prev.installedAt }
  Write-AicmState 'schedule' ([ordered]@{
    installedAt = $installedAt; version = Get-AicmVersion; app = $app; source = (Get-ScheduleSource $app)
    jobs = $jobs.ToArray(); launcher = 'windowless'; options = $Opt
  })
  if ($Refresh) {
    if (-not $changed) { Write-Host 'scheduled tasks already match the installed copy' }
  } else {
    Write-Host 'Each run checks that the other jobs still exist and shows a desktop notification if one is gone.'
  }
}

# Jobs asked for on the command line.
function Get-WantedJobs {
  $want = @()
  if (-not $NoUpdate) { $want += 'Update' }
  if (-not $NoInventory) { $want += 'Inventory' }
  if (-not $NoClean) { $want += 'Clean' }
  if (-not $NoMaintenance) { $want += 'Maintenance' }
  return $want
}

function Invoke-ScheduleInstall {
  $opt = Get-ParamScheduleOptions
  if ($KeepOtherJobs) {
    # Jobs that are not being installed keep the days and times they were installed with.
    $base = Get-InstalledScheduleOptions (Read-AicmState 'schedule')
    if ($NoInventory) { $opt.inventoryDay = $base.inventoryDay; $opt.inventoryAt = $base.inventoryAt }
    if ($NoClean) { $opt.cleanDay = $base.cleanDay; $opt.cleanAt = $base.cleanAt; $opt.cleanCategory = $base.cleanCategory }
    if ($NoMaintenance) { $opt.maintenanceApply = $base.maintenanceApply }
    if ($NoUpdate) { foreach ($k in 'updateAt', 'targets', 'installMissing', 'logRetentionDays') { $opt[$k] = $base[$k] } }
  }
  Install-Schedule $opt @(Get-WantedJobs) -KeepOthers:$KeepOtherJobs
}

# Re-registers the installed jobs with their stored options (run by the update after it refreshed
# the installed copy). Changes nothing when the tasks already match.
function Invoke-ScheduleRefresh {
  $sched = Read-AicmState 'schedule'
  if (-not $sched) { Write-Host 'no schedule installed; nothing to refresh'; return }
  $want = @(@($sched.jobs) | Where-Object { $script:JobNames -contains $_ })
  if ($want.Count -eq 0) { Write-Host 'no scheduled jobs recorded; nothing to refresh'; return }
  Install-Schedule (Get-InstalledScheduleOptions $sched) $want -Refresh
}

function Remove-Schedule {
  foreach ($name in 'Update', 'Inventory', 'Clean', 'Maintenance') {
    if (Get-AicmTask $name) {
      Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Confirm:$false
      Write-Host "removed: $($script:AicmTaskPath)$name"
    }
  }
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') 'schedule.json'
  if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

# The tasks `aicm.ps1 uninstall` would remove (for -DryRun).
function Show-SchedulePreview {
  foreach ($name in 'Update', 'Inventory', 'Clean') {
    if (Get-AicmTask $name) { Write-Host "would remove: $($script:AicmTaskPath)$name" }
  }
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') 'schedule.json'
  if (Test-Path -LiteralPath $file) { Write-Host "would remove $file" }
}

# Removes the scheduled jobs and the installed copy. Logs, state and archives stay unless -Purge.
# Everything is checked before anything is changed; -DryRun only lists what would go.
function Invoke-Uninstall {
  $app = Get-AicmAppDir
  $homeDir = Get-AicmHome
  $removeApp = $false
  $busy = Get-AicmBusyOperation
  if ($busy) {
    if ($DryRun) { Write-Host "note: $busy; uninstall would refuse to run now" }
    else { throw "refusing to uninstall while $busy; nothing was changed; run it again when that has finished" }
  }
  $appItem = Get-Item -LiteralPath $app -Force -ErrorAction SilentlyContinue
  # Only a folder that holds an installed copy (it has the SOURCE file) is removed, and only when it holds
  # nothing a copy never has.
  if ($appItem -and ((Test-AicmLink $appItem) -or (Test-Path -LiteralPath (Join-Path $app 'SOURCE'))) -and -not (Test-AicmSamePath (Get-AicmRoot) $app)) {
    if (-not (Test-AicmAppCopyOwned $app)) {
      throw "refusing to remove ${app}: $($script:AicmHomeProblem); move your files out of it and run again (nothing was changed)"
    }
    $removeApp = $true
  }
  if ($Purge -and (Test-Path -LiteralPath $homeDir) -and (Get-AicmHomeStatus) -eq 'foreign') {
    throw "refusing to purge ${homeDir}: $($script:AicmHomeProblem); nothing was changed. 'aicm.ps1 uninstall' without -Purge removes only the tasks and the installed copy"
  }
  if ($DryRun) {
    Show-SchedulePreview
    if ($removeApp) { Write-Host "would remove installed copy: $app" }
    if ($Purge) { Invoke-AicmPurge $homeDir -DryRun }
    else { Write-Host "would keep $homeDir (logs, state, archive, local rules); add -Purge to remove it too"; Write-Host 'dry run: nothing was changed' }
    return
  }
  Remove-Schedule
  if (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
    Write-Host "note: the legacy task '\$legacyTaskName' is still registered; remove it with: Unregister-ScheduledTask -TaskName '$legacyTaskName'"
  }
  if ($removeApp) {
    Remove-AicmTree ([System.IO.DirectoryInfo]::new($app)) $homeDir
    Write-Host "removed installed copy: $app"
  }
  if ($Purge) {
    Invoke-AicmPurge $homeDir
  } else {
    Write-Host "kept $homeDir (logs, state, archive, local rules); add -Purge to remove it too"
  }
}

function Show-Schedule {
  foreach ($name in 'Update', 'Inventory', 'Clean', 'Maintenance') {
    $task = Get-AicmTask $name
    if (-not $task) { Write-Host ("{0,-10} not registered" -f $name); continue }
    $info = $task | Get-ScheduledTaskInfo
    $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
    $next = if ($info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
    Write-Host ("{0,-10} {1,-8} last run {2} (result {3})  next {4}" -f $name, $task.State, $last, $info.LastTaskResult, $next)
  }
  if (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
    Write-Host "legacy  '\$legacyTaskName' is still registered; 'aicm.ps1 schedule install' replaces it"
  }
}

function Get-DoctorProblems {
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($p in (Get-AicmScheduleProblems -NoStale)) { $problems.Add($p) }
  $sched = Read-AicmState 'schedule'
  $jobs = if ($sched) { @($sched.jobs) } else { @() }
  $update = Read-AicmState 'last-update'
  $clean = Read-AicmState 'last-clean'
  $inventory = Read-AicmState 'inventory'
  if ($jobs -contains 'Maintenance' -and (Get-StateAgeDays (Read-AicmState 'last-maintenance')) -gt 1) { $problems.Add('no maintenance run in the last day') }
  if ($jobs -contains 'Inventory' -and (Get-StateAgeDays $inventory) -gt 9) { $problems.Add('no inventory run in the last 9 days') }
  if ($inventory -and $inventory.PSObject.Properties['shadowProblems']) {
    foreach ($s in @($inventory.shadowProblems)) { if ($s) { $problems.Add([string]$s) } }
  }
  if ($jobs -contains 'Update') {
    if ((Get-StateAgeDays $update) -gt 3) { $problems.Add('no update run in the last 3 days') }
    elseif ($update -and -not $update.ok) { $problems.Add('last update run failed: ' + (@($update.failures) -join ', ')) }
  }
  if ($jobs -contains 'Clean') {
    if ((Get-StateAgeDays $clean) -gt 9) { $problems.Add('no cleanup run in the last 9 days') }
    elseif ($clean -and -not $clean.ok) { $problems.Add('last cleanup run had errors: ' + (@($clean.errors) -join ', ')) }
  }
  if (-not $sched) { $problems.Add("no schedule installed; run: aicm.ps1 schedule install") }
  try { [void]@(Read-AicmCatalog) } catch { $problems.Add("catalog error: $($_.Exception.Message)") }
  try { [void]@(Read-AicmRules (Join-Path (Get-AicmRoot) 'rules\clean-rules.conf') (Join-Path (Get-AicmHome) 'clean-rules.local.conf')) }
  catch { $problems.Add("rules file error: $($_.Exception.Message)") }
  # Settings the scheduled runs need, checked the way the runs check them (read only): the home folder,
  # the optional update policy (the updater refuses to start while it is invalid, or while it exists and
  # Node.js is missing) and the installed copy the tasks start. Task results are checked above
  # (Get-AicmTaskProblems reads LastTaskResult).
  if ((Get-AicmHomeStatus) -eq 'foreign') { $problems.Add("AICM_HOME is not usable, so every run refuses to start: $($script:AicmHomeProblem)") }
  try { Initialize-AicmUpdatePolicy (Get-AicmMinReleaseAgeDays) }
  catch { $problems.Add("$($_.Exception.Message); the daily update refuses to run until it is fixed (file: $(Join-Path (Get-AicmHome) 'update-policy.json'))") }
  if ($sched -and @($sched.jobs).Count -gt 0 -and $sched.PSObject.Properties['app'] -and $sched.app -and -not (Test-Path -LiteralPath (Join-Path ([string]$sched.app) 'bin\aicm.ps1'))) {
    $problems.Add("the scheduled tasks start $($sched.app), which is missing or incomplete; run: aicm.ps1 schedule install")
  }
  return $problems
}

# What the tasks run and where it came from; also notes optional prerequisites that are missing.
function Get-DoctorInfo {
  $app = Get-AicmAppDir
  $version = Read-AicmUtf8FirstLine (Join-Path $app 'VERSION')
  if ($version) {
    $source = Read-AicmUtf8FirstLine (Join-Path $app 'SOURCE')
    $sourceVersion = if ($source) { Read-AicmUtf8FirstLine (Join-Path $source 'VERSION') } else { '' }
    if (-not $sourceVersion) { $sourceVersion = 'missing' }
    $shownSource = if ($source) { $source } else { 'unknown' }
    "info: installed copy $app version $version; source $shownSource (version $sourceVersion)"
  } else {
    "info: no installed copy in $app; this command runs from $(Get-AicmRoot) (version $(Get-AicmVersion))"
  }
  $node = Resolve-AicmExecutable 'node'
  if ($node) { "info: Node.js $node" }
  else { 'info: Node.js not found; archive rules, restore, history, an update policy and the worktree/config/process checks need it' }
  $policy = Join-Path (Get-AicmHome) 'update-policy.json'
  if (Test-Path -LiteralPath $policy) { "info: update policy $policy" }
}

# The last $Count notifications (they may never have shown on screen).
function Get-RecentNotifications([int]$Count) {
  $log = Join-Path (Join-Path (Get-AicmHome) 'logs') 'notifications.log'
  if (-not (Test-Path -LiteralPath $log)) { return @() }
  return @(Get-Content -LiteralPath $log -Encoding UTF8 -Tail $Count)
}

function Invoke-Child([string]$Script, [hashtable]$Splat) {
  & (Join-Path $binDir $Script) @Splat
  exit $LASTEXITCODE
}

# The dispatcher never marks AICM_HOME. update, inventory and clean claim it themselves after their
# arguments are valid and only for a real run, so help, a bad flag or a preview leaves it untouched.
if ($Command -eq 'clean' -and $Category.Count -gt 0) {
  try { [void](ConvertTo-AicmCategoryList (($Category | ForEach-Object { "$_" }) -join ',')) }
  catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
}
if ($Command -eq 'schedule' -and $Action -eq 'install' -and $PSBoundParameters.ContainsKey('CleanCategory')) {
  $cc = (@($CleanCategory) | ForEach-Object { "$_" }) -join ','
  if (-not "$cc".Trim()) { [Console]::Error.WriteLine('-CleanCategory needs a value'); exit 2 }
  try { [void](ConvertTo-AicmCategoryList $cc) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
}

# worktrees, config and processes record their results in state\: claim the home first.
if ($Command -in @('worktrees', 'config', 'processes')) {
  try { Confirm-AicmHome } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}

switch ($Command) {
  'help' { Show-Help }
  'version' { Write-Host "AI CLI Auto Manager $(Get-AicmVersion)" }
  'uninstall' { Invoke-Uninstall }
  'update' {
    $splat = @{ LogRetentionDays = $LogRetentionDays }
    if ($DryRun) { $splat.DryRun = $true }
    if ($Targets.Count -gt 0) { $splat.Targets = $Targets }
    if ($InstallMissing) { $splat.InstallMissing = $true }
    Invoke-Child 'update_ai_clis.ps1' $splat
  }
  'inventory' {
    $splat = @{ LogRetentionDays = $LogRetentionDays }
    if ($Offline) { $splat.Offline = $true }
    Invoke-Child 'inventory_ai_clis.ps1' $splat
  }
  'worktrees' {
    $nodeArgs = @()
    if ($Apply) { $nodeArgs += '--apply' }
    if ($Days -gt 0) { $nodeArgs += @('--days', "$Days") }
    $null = Invoke-AicmNodeModule 'worktrees' $nodeArgs
  }
  'config' { $null = Invoke-AicmNodeModule 'config-drift' @() }
  'run' {
    if (-not $Cli) { throw 'run needs -Cli command [-CliArguments args]' }
    Confirm-AicmHome
    Initialize-AicmProcessContainment -WholeProcess
    & $Cli @CliArguments
    exit $LASTEXITCODE
  }
  'maintenance' {
    Confirm-AicmHome
    Initialize-AicmProcessContainment -OwnSession
    $nodeArgs = @()
    if ($Apply -and -not $DryRun) { $nodeArgs += '--apply' } else { $nodeArgs += '--dry-run' }
    if ($Json) { $nodeArgs += '--json' }
    if ($ConfigFile) { $nodeArgs += @('--config', $ConfigFile) }
    if ($FilesOnly) { $nodeArgs += '--files-only' }
    if ($ProcessesOnly) { $nodeArgs += '--processes-only' }
    $node = Resolve-AicmExecutable 'node'
    if (-not $node) { throw 'maintenance needs Node.js' }
    if ($Json) {
      & $node (Join-Path (Get-AicmRoot) 'lib\auto-maintenance.js') @nodeArgs
      exit $LASTEXITCODE
    }
    $output = @(& $node (Join-Path (Get-AicmRoot) 'lib\auto-maintenance.js') @nodeArgs)
    $code = $LASTEXITCODE
    foreach ($line in $output) {
      Write-Host $line
      if ($line -like 'attention: *') { Send-AicmNotification 'AI CLI Auto Manager' $line.Substring(11) }
    }
    exit $code
  }
  'processes' {
    $nodeArgs = @()
    if ($Kill) { $nodeArgs += '--kill' }
    if ($DryRun) { $nodeArgs += '--dry-run' }
    if ($Json) { $nodeArgs += '--json' }
    if ($MinAgeHours -gt 0) { $nodeArgs += @('--min-age-hours', "$MinAgeHours") }
    $null = Invoke-AicmNodeModule 'processes' $nodeArgs
  }
  'optimize' {
    # Arguments are checked before anything else; a preview runs no tool and writes nothing. -Apply
    # claims the home and refuses while an update, cleanup, archive or restore runs (lib\optimize.js
    # then holds the maintenance lock itself).
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('aicm optimize needs Node.js'); exit 1 }
    $optJs = Join-Path (Get-AicmRoot) 'lib\optimize.js'
    if (-not (Test-Path -LiteralPath $optJs)) { [Console]::Error.WriteLine('aicm optimize: lib\optimize.js is missing from this copy'); exit 1 }
    $optArgs = @()
    if ($Apply) { $optArgs += '--apply' }
    if ($DryRun) { $optArgs += '--dry-run' }
    if ($PSBoundParameters.ContainsKey('Tasks')) { $optArgs += @('--tasks', ((@($Tasks) | ForEach-Object { "$_" }) -join ',')) }
    if ($Json) { $optArgs += '--json' }
    & node $optJs '--check' @optArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($Apply) {
      $refusal = ''
      try { Confirm-AicmHome } catch { $refusal = "AICM_HOME: $($_.Exception.Message)" }
      if (-not $refusal) { $refusal = Get-AicmBusyOperation }
      if ($refusal) { & node $optJs '--refuse' $refusal @optArgs; exit 1 }
    }
    & node $optJs @optArgs
    exit $LASTEXITCODE
  }
  'archive' {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('aicm archive needs Node.js'); exit 1 }
    $sub = if ($Action) { $Action } else { 'list' }
    $nodeArgs = @((Join-Path (Get-AicmRoot) 'lib\maintenance-cli.js'), 'archive', $sub)
    if ($Json) { $nodeArgs += '--json' }
    if ($DryRun) { $nodeArgs += '--dry-run' }
    if ($PSBoundParameters.ContainsKey('Limit')) { $nodeArgs += @('--limit', "$Limit") }
    if ($PSBoundParameters.ContainsKey('Offset')) { $nodeArgs += @('--offset', "$Offset") }
    & node @nodeArgs
    exit $LASTEXITCODE
  }
  'restore' {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('aicm restore needs Node.js'); exit 1 }
    $id = if ($ArchiveId) { $ArchiveId } else { $Action }
    $nodeArgs = @((Join-Path (Get-AicmRoot) 'lib\maintenance-cli.js'), 'restore', $id)
    if ($DryRun) { $nodeArgs += '--dry-run' }
    if ($Json) { $nodeArgs += '--json' }
    & node @nodeArgs
    exit $LASTEXITCODE
  }
  'history' {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('aicm history needs Node.js'); exit 1 }
    $nodeArgs = @((Join-Path (Get-AicmRoot) 'lib\maintenance-cli.js'), 'history', '--limit', "$Limit")
    if ($Json) { $nodeArgs += '--json' }
    & node @nodeArgs
    exit $LASTEXITCODE
  }
  'clean' {
    $splat = @{ LogRetentionDays = $LogRetentionDays }
    if ($DryRun) { $splat.DryRun = $true }
    if ($Rules.Count -gt 0) { $splat.Rules = $Rules }
    if ($Category.Count -gt 0) { $splat.Category = $Category }
    if ($Json) { $splat.Json = $true }
    if ($Explain) { $splat.Explain = $true }
    Invoke-Child 'clean_ai_leftovers.ps1' $splat
  }
  'status' {
    Write-Host "AI CLI Auto Manager $(Get-AicmVersion)   home: $(Get-AicmHome)"
    Write-Host ''
    Write-Host '== schedules =='
    Show-Schedule
    Write-Host ''
    Write-Host '== last runs =='
    Write-Host "update     $(Get-StateAgeText (Read-AicmState 'last-update'))"
    Write-Host "inventory  $(Get-StateAgeText (Read-AicmState 'inventory'))"
    Write-Host "clean      $(Get-StateAgeText (Read-AicmState 'last-clean'))"
    $maintenance = Read-AicmState 'last-maintenance'
    Write-Host "maintenance $(Get-StateAgeText $maintenance)"
    if ($maintenance -and $maintenance.PSObject.Properties['summary']) { Write-Host $maintenance.summary }
    $archiveRoot = Get-AicmArchiveRoot
    if (Test-Path -LiteralPath $archiveRoot) {
      $archiveBytes = 0L
      foreach ($f in (Get-AicmFiles $archiveRoot)) { $archiveBytes += $f.Length }
      Write-Host "archive    $(Format-AicmSize $archiveBytes) in $archiveRoot (move files back to restore)"
    }
    $inv = Read-AicmState 'inventory'
    if ($inv) {
      Write-Host ''
      Write-Host "== installed AI CLIs (from the last inventory, full report: $(Join-Path (Get-AicmHome) 'inventory.md')) =="
      foreach ($c in @($inv.clis)) { Write-Host ("{0,-20} {1,-11} {2,-14} {3,-9} {4}" -f $c.name, $c.method, $c.version, $c.state, $c.autoUpdate) }
    }
    Write-Host ''
    Write-Host '== recent notifications =='
    $recent = @(Get-RecentNotifications 5)
    if ($recent.Count -gt 0) { foreach ($l in $recent) { Write-Host $l } } else { Write-Host 'none' }
    Write-Host ''
    Write-Host '== disk use by cleanup rule =='
    & (Join-Path $binDir 'clean_ai_leftovers.ps1') -Report
  }
  'doctor' {
    $problems = @(Get-DoctorProblems)
    foreach ($line in @(Get-DoctorInfo)) { Write-Host $line }
    if ($problems.Count -eq 0) { Write-Host 'healthy: schedules registered, recent runs succeeded, settings valid' }
    foreach ($p in $problems) { Write-Host "problem: $p" }
    $recent = @(Get-RecentNotifications 3)
    if ($recent.Count -gt 0) {
      Write-Host "recent notifications ($(Join-Path (Join-Path (Get-AicmHome) 'logs') 'notifications.log')):"
      foreach ($l in $recent) { Write-Host "  $l" }
    }
    if ($problems.Count -eq 0) { exit 0 }
    exit 1
  }
  'schedule' {
    switch ($Action) {
      'install' { Invoke-ScheduleInstall }
      'refresh' { Invoke-ScheduleRefresh }
      'remove' { Remove-Schedule }
      { $_ -in @('show', '') } { Show-Schedule }
      default { throw "unknown schedule action '$Action' (use install, remove, show or refresh)" }
    }
  }
}
