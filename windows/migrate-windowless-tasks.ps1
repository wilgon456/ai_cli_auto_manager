<# Migrate only the manager's task actions; do not replace or update the installed app. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\aicm-common.ps1')
. (Join-Path $root 'lib\aicm-scheduler.ps1')
$lock = Enter-AicmScheduleLock
try {
if ((Get-AicmHomeStatus) -eq 'foreign') { throw (Get-AicmHomeRefusal) }
$state = Read-AicmState 'schedule'
if (-not $state -or -not $state.PSObject.Properties['jobs']) { throw 'schedule state is missing or invalid; no tasks were changed' }
$names = @(@('Update', 'Inventory', 'Clean', 'Maintenance') | Where-Object {
  Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $_ -ErrorAction SilentlyContinue
})
if ($names.Count -eq 0) { throw 'no managed tasks found' }
Assert-AicmManagedTasksIdle $names $script:AicmTaskPath $false
$launcher = Initialize-AicmWindowlessLauncher $root
$scripts = @{ Update = 'update_ai_clis.ps1'; Inventory = 'inventory_ai_clis.ps1'; Clean = 'clean_ai_leftovers.ps1'; Maintenance = 'aicm.ps1' }
$needsChange = $false
foreach ($name in $names) {
  $task = Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -ErrorAction Stop
  [void](Get-AicmOldTaskArguments $task $scripts[$name] (Get-AicmAppDir))
  if ([string]$task.Actions[0].Execute -cne $launcher) { $needsChange = $true }
}
if (-not $needsChange -and $state.PSObject.Properties['launcher'] -and $state.launcher -eq 'windowless') {
  Write-Host 'managed tasks already use the verified windowless launcher; no backup or state change was needed'
  return
}
$backup = New-AicmScheduleBackup $names $script:AicmTaskPath
Write-Host "schedule backup: $backup"
Assert-AicmManagedTasksIdle $names $script:AicmTaskPath $false
try {
  $changed = @(Convert-AicmLegacyTasks $names $script:AicmTaskPath $launcher $backup)
  if ($state.PSObject.Properties['launcher']) { $state.launcher = 'windowless' }
  else { $state | Add-Member -NotePropertyName 'launcher' -NotePropertyValue 'windowless' }
  Write-AicmState 'schedule' $state
  Write-Host "updated task actions: $($changed.Count); the installed app and source checkout were not replaced"
} catch {
  try { Restore-AicmTaskActions $backup } catch { Write-Warning "Could not restore all task actions; use backup $backup" }
  throw
}
} finally { Exit-AicmScheduleLock $lock }
