<# Restore managed task actions and the installed copy from a verified migration backup.
   Example: .\windows\restore-schedule-backup.ps1 -BackupDir 'C:\...\backups\...'
   Run only while the managed tasks are idle. The current copy is retained beside app. #>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$BackupDir, [switch]$ActionsOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\aicm-common.ps1')
. (Join-Path $root 'lib\aicm-scheduler.ps1')

$area = Get-AicmWindowlessArea
$backupBase = Join-Path $area 'backups'
$backup = [IO.Path]::GetFullPath($BackupDir).TrimEnd('\', '/')
if (-not (Test-AicmUnder $backup $backupBase) -or (Test-AicmPathHasLink $backup)) { throw 'backup must be a real folder under this installation backup directory' }
$metadataPath = Join-Path $backup 'backup.json'
if (-not (Test-AicmRealFile (Get-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue))) { throw 'backup metadata is missing or linked' }
$meta = (Read-AicmUtf8Text $metadataPath) | ConvertFrom-Json
if ($meta.format -ne 1 -or -not (Test-AicmSamePath ([string]$meta.aicmHome) (Get-AicmHome))) { throw 'backup belongs to a different management home' }
if ([string]$meta.taskPath -ne $script:AicmTaskPath) { throw 'backup belongs to a different task folder' }
$names = @($meta.names)
if ($names.Count -eq 0 -or -not $meta.hasApp) { throw 'backup does not contain tasks and an installed copy' }
if (-not $meta.PSObject.Properties['schedulePresent'] -or -not $meta.PSObject.Properties['scheduleHash']) { throw 'backup does not contain schedule state verification metadata' }
$savedSchedule = Join-Path $backup 'schedule.json'
$savedScheduleItem = Get-Item -LiteralPath $savedSchedule -Force -ErrorAction SilentlyContinue
if ($meta.schedulePresent) {
  if (-not (Test-AicmRealFile $savedScheduleItem) -or
      (Get-FileHash -LiteralPath $savedSchedule -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$meta.scheduleHash) { throw 'schedule state backup failed verification' }
} elseif ($savedScheduleItem) { throw 'backup contains an unexpected schedule state file' }
foreach ($name in $names) {
  if (@('Update', 'Inventory', 'Clean', 'Maintenance') -notcontains [string]$name) { throw 'backup contains an unrecognized task' }
  $xmlFile = Join-Path $backup "$name.xml"
  if (-not (Test-AicmRealFile (Get-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue)) -or
      (Get-FileHash -LiteralPath $xmlFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$meta.xmlHashes.$name) { throw "task backup failed verification: $name" }
  $task = Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $name -ErrorAction Stop
  if ($task.State -in @('Running', 'Queued')) { throw "task $name is running or queued; wait for it to finish" }
}
$oldApp = Join-Path $backup 'app'
if (-not (Test-AicmRealDir (Get-Item -LiteralPath $oldApp -Force -ErrorAction SilentlyContinue)) -or (Test-AicmPathHasLink $oldApp)) { throw 'backup copy is missing or linked' }
if (-not (Test-AicmAppCopyOwned $oldApp)) { throw "backup copy contains an unexpected file or link: $($script:AicmHomeProblem)" }
$oldFiles = @(Get-ChildItem -LiteralPath $oldApp -Recurse -File -Force)
$savedNames = @($meta.appHashes.PSObject.Properties.Name)
if ($oldFiles.Count -ne $savedNames.Count) { throw 'backup copy has missing or extra files' }
foreach ($file in $oldFiles) {
  if (-not (Test-AicmRealFile $file) -or (Test-AicmPathHasLink $file.FullName)) { throw 'backup copy contains a link' }
  $relative = $file.FullName.Substring($oldApp.TrimEnd('\', '/').Length + 1)
  if ($savedNames -notcontains $relative -or
      (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$meta.appHashes.$relative) { throw "backup copy failed verification: $relative" }
}
$app = Get-AicmAppDir
if (-not (Test-AicmAppCopyOwned $app)) { throw "current installed copy is not safe to replace: $($script:AicmHomeProblem)" }
$recovery = New-AicmScheduleBackup $names $script:AicmTaskPath
Write-Host "Current task XML and installed copy backed up to: $recovery"
if ($ActionsOnly) {
  Restore-AicmTaskActions $backup
  if ($meta.schedulePresent) {
    $stateDir = Join-Path (Get-AicmHome) 'state'
    if (-not (Test-AicmRealDir (Get-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue))) { throw 'current schedule state folder is linked or missing' }
    $schedule = Join-Path $stateDir 'schedule.json'
    $currentSchedule = Get-Item -LiteralPath $schedule -Force -ErrorAction SilentlyContinue
    if ($currentSchedule -and -not (Test-AicmRealFile $currentSchedule)) { throw 'current schedule state is linked; it was not replaced' }
    Copy-Item -LiteralPath $savedSchedule -Destination $schedule -Force -ErrorAction Stop
  }
  Write-Host 'Restored the task actions and schedule state without replacing the installed copy.'
  exit 0
}
$stage = "$app.restore-$([guid]::NewGuid().ToString('N'))"
$savedCurrent = "$app.rollback-$([guid]::NewGuid().ToString('N'))"
if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $savedCurrent)) { throw 'rollback staging path already exists' }
Copy-Item -LiteralPath $oldApp -Destination $stage -Recurse -ErrorAction Stop
try {
  Move-AicmDirectory $app $savedCurrent
  try { Move-AicmDirectory $stage $app }
  catch { Move-AicmDirectory $savedCurrent $app; throw }
  try { Restore-AicmTaskActions $backup }
  catch {
    Write-Warning "Task restore was incomplete. Current actions and copy are backed up at $recovery; current copy is also at $savedCurrent."
    throw
  }
  if ($meta.schedulePresent) {
    $schedule = Join-Path (Join-Path (Get-AicmHome) 'state') 'schedule.json'
    $currentSchedule = Get-Item -LiteralPath $schedule -Force -ErrorAction SilentlyContinue
    if ($currentSchedule -and -not (Test-AicmRealFile $currentSchedule)) { throw 'current schedule state is linked; it was not replaced' }
    Copy-Item -LiteralPath $savedSchedule -Destination $schedule -Force -ErrorAction Stop
  }
  Write-Host "Restored task actions and the installed copy. Previous current copy retained at: $savedCurrent"
} finally {
  if (Test-Path -LiteralPath $stage) { Write-Warning "Staged copy retained for review: $stage" }
}
