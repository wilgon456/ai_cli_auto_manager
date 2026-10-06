<#
.SYNOPSIS
  AI CLI Auto Manager for Windows: keeps AI coding CLIs updated and their leftovers cleaned.
.DESCRIPTION
  aicm.ps1 update    [-DryRun] [-Targets codex,claude] [-InstallMissing]
  aicm.ps1 clean     [-DryRun] [-Rules id,id]
  aicm.ps1 status    disk use per cleanup rule, schedules, last runs
  aicm.ps1 doctor    exit 1 when a schedule is missing or a run is overdue or failed
  aicm.ps1 schedule  install | remove | show   [-UpdateAt 05:00] [-CleanDay Monday] [-CleanAt 12:30] [-NoClean] [-NoUpdate]
  aicm.ps1 version
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('update', 'clean', 'status', 'doctor', 'schedule', 'version', 'help')]
  [string]$Command = 'help',
  [Parameter(Position = 1)]
  [string]$Action = '',
  [Alias('Check')]
  [switch]$DryRun,
  [string[]]$Targets = @(),
  [switch]$InstallMissing,
  [string[]]$Rules = @(),
  [int]$LogRetentionDays = 30,
  [string]$UpdateAt = '05:00',
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
  [string]$CleanDay = 'Monday',
  [string]$CleanAt = '12:30',
  [switch]$NoUpdate,
  [switch]$NoClean,
  [switch]$KeepLegacyTask
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
  Write-Host '  aicm.ps1 clean     [-DryRun] [-Rules id,id]'
  Write-Host '  aicm.ps1 status'
  Write-Host '  aicm.ps1 doctor'
  Write-Host '  aicm.ps1 schedule  install|remove|show [-UpdateAt 05:00] [-CleanDay Monday] [-CleanAt 12:30] [-NoUpdate] [-NoClean]'
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

function New-TaskAction([string]$Script, [string[]]$Extra) {
  $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Script`"") + $Extra
  return (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' '))
}

function Install-Schedule {
  if ($NoUpdate -and $NoClean) { throw 'nothing to install: both -NoUpdate and -NoClean were given' }
  $jobs = New-Object System.Collections.Generic.List[string]
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  if (-not $NoUpdate) {
    $extra = @('-LogRetentionDays', "$LogRetentionDays")
    $targetText = ($Targets -join ',')
    if ($targetText) { $extra += @('-Targets', "`"$targetText`"") }
    if ($InstallMissing) { $extra += '-InstallMissing' }
    $action = New-TaskAction (Join-Path $binDir 'update_ai_clis.ps1') $extra
    $trigger = New-ScheduledTaskTrigger -Daily -At $UpdateAt
    Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Update' -Action $action -Trigger $trigger -Settings $settings -Description 'AI CLI Auto Manager: update installed AI coding CLIs' -Force | Out-Null
    $jobs.Add('Update')
    Write-Host "registered: $($script:AicmTaskPath)Update  daily at $UpdateAt"
  } elseif (Get-AicmTask 'Update') {
    Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Update' -Confirm:$false
    Write-Host "removed: $($script:AicmTaskPath)Update"
  }
  if (-not $NoClean) {
    $action = New-TaskAction (Join-Path $binDir 'clean_ai_leftovers.ps1') @('-LogRetentionDays', "$LogRetentionDays")
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $CleanDay -At $CleanAt
    Register-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Clean' -Action $action -Trigger $trigger -Settings $settings -Description 'AI CLI Auto Manager: remove stale AI CLI leftovers' -Force | Out-Null
    $jobs.Add('Clean')
    Write-Host "registered: $($script:AicmTaskPath)Clean   every $CleanDay at $CleanAt"
  } elseif (Get-AicmTask 'Clean') {
    Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName 'Clean' -Confirm:$false
    Write-Host "removed: $($script:AicmTaskPath)Clean"
  }
  if (-not $KeepLegacyTask -and -not $NoUpdate -and (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -Confirm:$false
    Write-Host "removed legacy task: \$legacyTaskName (replaced by $($script:AicmTaskPath)Update)"
  }
  Write-AicmState 'schedule' ([ordered]@{ installedAt = Get-AicmTimestamp; version = Get-AicmVersion; jobs = @($jobs) })
  Write-Host 'Each run checks that the other job still exists and shows a desktop notification if it is gone.'
}

function Remove-Schedule {
  foreach ($name in 'Update', 'Clean') {
    if (Get-AicmTask $name) {
      Unregister-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -Confirm:$false
      Write-Host "removed: $($script:AicmTaskPath)$name"
    }
  }
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') 'schedule.json'
  if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

function Show-Schedule {
  foreach ($name in 'Update', 'Clean') {
    $task = Get-AicmTask $name
    if (-not $task) { Write-Host ("{0,-7} not registered" -f $name); continue }
    $info = $task | Get-ScheduledTaskInfo
    $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
    $next = if ($info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
    Write-Host ("{0,-7} {1,-8} last run {2} (result {3})  next {4}" -f $name, $task.State, $last, $info.LastTaskResult, $next)
  }
  if (Get-ScheduledTask -TaskPath '\' -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
    Write-Host "legacy  '\$legacyTaskName' is still registered; 'aicm.ps1 schedule install' replaces it"
  }
}

function Get-DoctorProblems {
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($p in (Get-AicmScheduleProblems)) { $problems.Add($p) }
  $sched = Read-AicmState 'schedule'
  $jobs = if ($sched) { @($sched.jobs) } else { @() }
  $update = Read-AicmState 'last-update'
  $clean = Read-AicmState 'last-clean'
  if ($jobs -contains 'Update') {
    if ((Get-StateAgeDays $update) -gt 3) { $problems.Add('no update run in the last 3 days') }
    elseif ($update -and -not $update.ok) { $problems.Add('last update run failed: ' + (@($update.failures) -join ', ')) }
  }
  if ($jobs -contains 'Clean') {
    if ((Get-StateAgeDays $clean) -gt 9) { $problems.Add('no cleanup run in the last 9 days') }
    elseif ($clean -and -not $clean.ok) { $problems.Add('last cleanup run had errors: ' + (@($clean.errors) -join ', ')) }
  }
  if (-not $sched) { $problems.Add("no schedule installed; run: aicm.ps1 schedule install") }
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
  'update' {
    $splat = @{ LogRetentionDays = $LogRetentionDays }
    if ($DryRun) { $splat.DryRun = $true }
    if ($Targets.Count -gt 0) { $splat.Targets = $Targets }
    if ($InstallMissing) { $splat.InstallMissing = $true }
    Invoke-Child 'update_ai_clis.ps1' $splat
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
    Write-Host "update  $(Get-StateAgeText (Read-AicmState 'last-update'))"
    Write-Host "clean   $(Get-StateAgeText (Read-AicmState 'last-clean'))"
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
