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

function Install-Schedule {
  if ($NoUpdate -and $NoInventory -and $NoClean) { throw 'nothing to install: -NoUpdate, -NoInventory and -NoClean were all given' }
  $jobs = New-Object System.Collections.Generic.List[string]
  $app = Sync-AicmAppCopy (Get-AicmRoot)
  Write-Host "installed copy: $app (version $(Get-AicmVersion))"
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  if (-not $NoUpdate) {
    $extra = @('-LogRetentionDays', "$LogRetentionDays")
    $targetText = ($Targets -join ',')
    if ($targetText) { $extra += @('-Targets', "`"$targetText`"") }
    if ($InstallMissing) { $extra += '-InstallMissing' }
    $extra += '-Scheduled'
    $action = New-TaskAction $app 'update_ai_clis.ps1' $extra
    $trigger = New-ScheduledTaskTrigger -Daily -At $UpdateAt
    # Retry every 3 hours for 15 hours: a CLI that was running at 05:00 is updated once it is closed.
    # A run after a complete success the same day exits right away.
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $UpdateAt -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Hours 15)).Repetition
    Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Update' -Action $action -Trigger $trigger -Settings $settings -Description 'AI CLI Auto Manager: update installed AI coding CLIs' -Force | Out-Null
    $jobs.Add('Update')
    Write-Host "registered: $($script:AicmTaskPath)Update     daily at $UpdateAt (retried every 3 hours until it succeeds)"
  } elseif (Get-AicmTask 'Update') {
    Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Update' -Confirm:$false
    Write-Host "removed: $($script:AicmTaskPath)Update"
  }
  if (-not $NoInventory) {
    $action = New-TaskAction $app 'inventory_ai_clis.ps1' @('-LogRetentionDays', "$LogRetentionDays")
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $InventoryDay -At $InventoryAt
    Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Inventory' -Action $action -Trigger $trigger -Settings $settings -Description 'AI CLI Auto Manager: list installed AI coding CLIs' -Force | Out-Null
    $jobs.Add('Inventory')
    Write-Host "registered: $($script:AicmTaskPath)Inventory  every $InventoryDay at $InventoryAt"
  } elseif (Get-AicmTask 'Inventory') {
    Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Inventory' -Confirm:$false
    Write-Host "removed: $($script:AicmTaskPath)Inventory"
  }
  if (-not $NoClean) {
    $action = New-TaskAction $app 'clean_ai_leftovers.ps1' @('-LogRetentionDays', "$LogRetentionDays")
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $CleanDay -At $CleanAt
    Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Clean' -Action $action -Trigger $trigger -Settings $settings -Description 'AI CLI Auto Manager: remove stale AI CLI leftovers' -Force | Out-Null
    $jobs.Add('Clean')
    Write-Host "registered: $($script:AicmTaskPath)Clean      every $CleanDay at $CleanAt"
  } elseif (Get-AicmTask 'Clean') {
    Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Clean' -Confirm:$false
    Write-Host "removed: $($script:AicmTaskPath)Clean"
  }
  if (-not $KeepLegacyTask -and -not $NoUpdate -and (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -Confirm:$false
    Write-Host "removed legacy task: \$legacyTaskName (replaced by $($script:AicmTaskPath)Update)"
  }
  Write-AicmState 'schedule' ([ordered]@{ installedAt = Get-AicmTimestamp; version = Get-AicmVersion; app = $app; source = (Get-AicmRoot); jobs = $jobs.ToArray() })
  Write-Host 'Each run checks that the other jobs still exist and shows a desktop notification if one is gone.'
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
      'install' { Install-Schedule }
      'remove' { Remove-Schedule }
      { $_ -in @('show', '') } { Show-Schedule }
      default { throw "unknown schedule action '$Action' (use install, remove or show)" }
    }
  }
}
