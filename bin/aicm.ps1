<#
.SYNOPSIS
  AI CLI Auto Manager for Windows: keeps AI coding CLIs updated and their leftovers cleaned.
.DESCRIPTION
  aicm.ps1 update    [-DryRun] [-Targets codex,claude] [-InstallMissing]
  aicm.ps1 inventory [-Offline]   list installed AI CLIs, their versions and update coverage
  aicm.ps1 clean     [-DryRun] [-Rules id,id]
  aicm.ps1 worktrees [-Apply] [-Days 14]   worktrees and branches agents left behind (report unless -Apply)
  aicm.ps1 config    MCP servers and skills compared across the installed CLIs
  aicm.ps1 processes [-Kill] [-MinAgeHours 2]   agent processes left running after their session ended
  aicm.ps1 status    disk use per cleanup rule, schedules, last runs
  aicm.ps1 doctor    exit 1 when a schedule is missing or a run is overdue or failed
  aicm.ps1 schedule  install | remove | show   [-UpdateAt 05:00] [-InventoryDay Monday] [-InventoryAt 12:00]
                                               [-CleanDay Monday] [-CleanAt 12:30] [-NoUpdate] [-NoInventory] [-NoClean]
  aicm.ps1 version
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('update', 'inventory', 'clean', 'worktrees', 'config', 'processes', 'status', 'doctor', 'schedule', 'uninstall', 'version', 'help')]
  [string]$Command = 'help',
  [Parameter(Position = 1)]
  [string]$Action = '',
  [Alias('Check')]
  [switch]$DryRun,
  [string[]]$Targets = @(),
  [switch]$InstallMissing,
  [switch]$Offline,
  [string[]]$Rules = @(),
  [int]$LogRetentionDays = 30,
  [string]$UpdateAt = '05:00',
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
  [string]$InventoryDay = 'Monday',
  [string]$InventoryAt = '12:00',
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
  [string]$CleanDay = 'Monday',
  [string]$CleanAt = '12:30',
  [switch]$NoUpdate,
  [switch]$NoInventory,
  [switch]$NoClean,
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

$legacyTaskName = 'AI CLI Auto Update'

function Show-Help {
  Write-Host "AI CLI Auto Manager $(Get-AicmVersion)"
  Write-Host ''
  Write-Host '  aicm.ps1 update    [-DryRun] [-Targets codex,claude] [-InstallMissing]'
  Write-Host '  aicm.ps1 inventory [-Offline]'
  Write-Host '  aicm.ps1 clean     [-DryRun] [-Rules id,id]'
  Write-Host '  aicm.ps1 worktrees [-Apply] [-Days 14]'
  Write-Host '  aicm.ps1 config'
  Write-Host '  aicm.ps1 processes [-Kill] [-MinAgeHours 2]'
  Write-Host '  aicm.ps1 status'
  Write-Host '  aicm.ps1 doctor'
  Write-Host '  aicm.ps1 schedule  install|remove|show [-UpdateAt 05:00] [-InventoryDay Monday] [-InventoryAt 12:00]'
  Write-Host '                     [-CleanDay Monday] [-CleanAt 12:30] [-NoUpdate] [-NoInventory] [-NoClean]'
  Write-Host '  aicm.ps1 uninstall [-Purge]'
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

# Tasks run the installed copy through windows\run-hidden.vbs, so no PowerShell window flashes on screen.
function New-TaskAction([string]$App, [string]$Script, [string[]]$Extra) {
  $vbs = Join-Path $App 'windows\run-hidden.vbs'
  $argList = @("`"$vbs`"", 'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $App "bin\$Script")`"") + $Extra
  return (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ($argList -join ' '))
}

# HH:MM or H:MM with hour 0-23 and minute 0-59.
function Test-TimeText([string]$Text) { return ($Text -match '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') }

$script:JobNames = @('Update', 'Inventory', 'Clean')
$script:DayBits = [ordered]@{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }

function Get-DefaultScheduleOptions {
  return [ordered]@{ updateAt = '05:00'; inventoryDay = 'Monday'; inventoryAt = '12:00'; cleanDay = 'Monday'; cleanAt = '12:30'; targets = ''; installMissing = $false; logRetentionDays = 30 }
}

# The options given on the command line.
function Get-ParamScheduleOptions {
  return [ordered]@{
    updateAt = $UpdateAt; inventoryDay = $InventoryDay; inventoryAt = $InventoryAt; cleanDay = $CleanDay; cleanAt = $CleanAt
    targets = ($Targets -join ','); installMissing = [bool]$InstallMissing; logRetentionDays = $LogRetentionDays
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
  }
  return $o
}

# Action and trigger of one job, built from the options.
function Get-JobSpec([string]$Name, $Opt, [string]$App) {
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
      return @{ Action = (New-TaskAction $App 'update_ai_clis.ps1' $extra); Trigger = $trigger
        Description = 'AI CLI Auto Manager: update installed AI coding CLIs'; Text = "daily at $($Opt.updateAt) (retried every 3 hours until it succeeds)" }
    }
    'Inventory' {
      return @{ Action = (New-TaskAction $App 'inventory_ai_clis.ps1' $retention); Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Opt.inventoryDay -At $Opt.inventoryAt)
        Description = 'AI CLI Auto Manager: list installed AI coding CLIs'; Text = "every $($Opt.inventoryDay) at $($Opt.inventoryAt)" }
    }
    'Clean' {
      return @{ Action = (New-TaskAction $App 'clean_ai_leftovers.ps1' $retention); Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Opt.cleanDay -At $Opt.cleanAt)
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
  if ((Test-AicmSamePath (Get-AicmRoot) $App) -and (Test-Path -LiteralPath $sourceFile)) { return (Get-Content -LiteralPath $sourceFile -TotalCount 1).Trim() }
  return (Get-AicmRoot)
}

# Registers $Want with the options $Opt; tasks that already match are left alone, so running it again
# changes nothing. Jobs not in $Want are removed, or kept as they are with -KeepOthers.
# -Refresh: called after the installed copy was updated; keeps installedAt and does not touch the legacy task.
function Install-Schedule($Opt, [string[]]$Want, [switch]$KeepOthers, [switch]$Refresh) {
  if (@($Want).Count -eq 0) { throw 'nothing to install: -NoUpdate, -NoInventory and -NoClean were all given' }
  foreach ($k in 'updateAt', 'inventoryAt', 'cleanAt') {
    if (-not (Test-TimeText $Opt[$k])) { throw "invalid time '$($Opt[$k])' for $k`: use HH:MM with hour 0-23 and minute 0-59, like 05:00" }
  }
  $prev = Read-AicmState 'schedule'
  $jobs = New-Object System.Collections.Generic.List[string]
  $app = Sync-AicmAppCopy (Get-AicmRoot)
  if (-not $Refresh) { Write-Host "installed copy: $app (version $(Get-AicmVersion))" }
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  $changed = $false
  foreach ($name in $script:JobNames) {
    $existing = Get-AicmTask $name
    if ($Want -contains $name) {
      $spec = Get-JobSpec $name $Opt $app
      $same = $existing -and (Get-TaskSignature $existing.Actions[0] $existing.Triggers[0]) -eq (Get-TaskSignature $spec.Action $spec.Trigger)
      # A plain install also turns a disabled task back on; a refresh leaves that choice alone.
      if ($same -and ($Refresh -or $existing.State -ne 'Disabled')) {
        if (-not $Refresh) { Write-Host ("unchanged:  {0}{1,-10} {2}" -f $script:AicmTaskPath, $name, $spec.Text) }
      } else {
        Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Action $spec.Action -Trigger $spec.Trigger -Settings $settings -Description $spec.Description -Force | Out-Null
        Write-Host ("registered: {0}{1,-10} {2}" -f $script:AicmTaskPath, $name, $spec.Text)
        $changed = $true
      }
      $jobs.Add($name)
    } elseif ($KeepOthers) {
      if ($existing) { $jobs.Add($name) }
    } elseif ($existing) {
      Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Confirm:$false
      Write-Host "removed: $($script:AicmTaskPath)$name"
      $changed = $true
    }
  }
  if (-not $Refresh -and -not $KeepLegacyTask -and $Want -contains 'Update' -and (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -Confirm:$false
    Write-Host "removed legacy task: \$legacyTaskName (replaced by $($script:AicmTaskPath)Update)"
  }
  $installedAt = Get-AicmTimestamp
  if ($Refresh -and $prev -and $prev.PSObject.Properties['installedAt']) { $installedAt = [string]$prev.installedAt }
  Write-AicmState 'schedule' ([ordered]@{
    installedAt = $installedAt; version = Get-AicmVersion; app = $app; source = (Get-ScheduleSource $app)
    jobs = $jobs.ToArray(); options = $Opt
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
  return $want
}

function Invoke-ScheduleInstall {
  $opt = Get-ParamScheduleOptions
  if ($KeepOtherJobs) {
    # Jobs that are not being installed keep the days and times they were installed with.
    $base = Get-InstalledScheduleOptions (Read-AicmState 'schedule')
    if ($NoInventory) { $opt.inventoryDay = $base.inventoryDay; $opt.inventoryAt = $base.inventoryAt }
    if ($NoClean) { $opt.cleanDay = $base.cleanDay; $opt.cleanAt = $base.cleanAt }
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
  foreach ($name in 'Update', 'Inventory', 'Clean') {
    if (Get-AicmTask $name) {
      Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Confirm:$false
      Write-Host "removed: $($script:AicmTaskPath)$name"
    }
  }
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') 'schedule.json'
  if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

# Removes the scheduled jobs and the installed copy. Logs, state and archives stay unless -Purge.
function Invoke-Uninstall {
  Remove-Schedule
  if (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
    Write-Host "note: the legacy task '\$legacyTaskName' is still registered; remove it with: Unregister-ScheduledTask -TaskName '$legacyTaskName'"
  }
  $app = Get-AicmAppDir
  if ((Test-Path -LiteralPath $app) -and -not (Test-AicmSamePath (Get-AicmRoot) $app)) {
    Remove-AicmTree ([System.IO.DirectoryInfo]::new($app))
    Write-Host "removed installed copy: $app"
  }
  $homeDir = Get-AicmHome
  if ($Purge) {
    if ((Split-Path -Leaf $homeDir) -ne '.ai-cli-auto-manager' -and -not $env:AICM_HOME) { throw "refusing to purge $homeDir" }
    if (Test-Path -LiteralPath $homeDir) { Remove-AicmTree ([System.IO.DirectoryInfo]::new($homeDir)); Write-Host "removed $homeDir (logs, state, archive)" }
  } else {
    Write-Host "kept $homeDir (logs, state, archive, local rules); add -Purge to remove it too"
  }
}

function Show-Schedule {
  foreach ($name in 'Update', 'Inventory', 'Clean') {
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
  return $problems
}

function Invoke-Child([string]$Script, [hashtable]$Splat) {
  & (Join-Path $binDir $Script) @Splat
  exit $LASTEXITCODE
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
  'processes' {
    $nodeArgs = @()
    if ($Kill) { $nodeArgs += '--kill' }
    if ($MinAgeHours -gt 0) { $nodeArgs += @('--min-age-hours', "$MinAgeHours") }
    $null = Invoke-AicmNodeModule 'processes' $nodeArgs
  }
  'clean' {
    $splat = @{ LogRetentionDays = $LogRetentionDays }
    if ($DryRun) { $splat.DryRun = $true }
    if ($Rules.Count -gt 0) { $splat.Rules = $Rules }
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
    Write-Host '== disk use by cleanup rule =='
    & (Join-Path $binDir 'clean_ai_leftovers.ps1') -Report
  }
  'doctor' {
    $problems = @(Get-DoctorProblems)
    if ($problems.Count -eq 0) { Write-Host 'healthy: schedules registered, recent runs succeeded'; exit 0 }
    foreach ($p in $problems) { Write-Host "problem: $p" }
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
