# Tests for bin\aicm.ps1 (dispatcher, scheduled tasks, doctor) and the updater dry run on Windows.
# Uses a throwaway profile folder and a throwaway Task Scheduler folder; real tasks are never touched.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aicm-test-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$folderName = 'AICM Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$taskPath = "\$folderName\"
$script:fails = 0
. (Join-Path $PSScriptRoot 'test-env.ps1')
. (Join-Path $root 'lib\aicm-common.ps1')
$runtimePath = New-TestRuntimePath $work

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }

function Invoke-Script([string]$Script, [string[]]$Arguments) {
  return (Invoke-Child (@('-File', (Join-Path $root $Script)) + @($Arguments)))
}

# Runs $Code in a child PowerShell with the lib of $Dir dot-sourced (used to replace a cmdlet for one test).
function Invoke-Lib([string]$Dir, [string]$Code) {
  $text = "Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; . '$(Join-Path $Dir 'lib\aicm-common.ps1')'; $Code"
  return (Invoke-Child @('-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($text))))
}

function Invoke-Child([string[]]$PsArguments) {
  $exe = (Get-Process -Id $PID).Path
  $saved = @{}
  $names = 'HOME', 'CODEX_HOME', 'PATH', 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'AICM_TASK_PATH', 'AICM_PROCESSES', 'AICM_WORKTREES'
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = "$work\tmp"; $env:TMP = "$work\tmp"; $env:LOCALAPPDATA = "$fakeHome\AppData\Local"
    $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_WORKTREES = '0'; $env:AICM_TASK_PATH = $taskPath
    $env:HOME = $fakeHome; $env:CODEX_HOME = "$fakeHome\.codex"; $env:PATH = $runtimePath
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass @PsArguments 2>&1 | Out-String -Width 4096
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

function Invoke-Aicm([string[]]$Arguments) { return (Invoke-Script 'bin\aicm.ps1' $Arguments) }

function Write-FreshUpdateState {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  "{`"finishedAt`":`"$stamp`",`"version`":`"x`",`"ok`":true,`"failures`":[],`"logFile`":`"`"}" |
    Set-Content -LiteralPath "$aicmHome\state\last-update.json" -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Path $fakeHome, "$work\tmp", "$fakeHome\AppData\Local" -Force | Out-Null
  $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1).Trim()

  $r = Invoke-Aicm @('version')
  if ($r.Output -match [regex]::Escape("AI CLI Auto Manager $version")) { Pass 'version' } else { Fail "version: $($r.Output)" }
  $r = Invoke-Aicm @('help')
  if ($r.Output -match 'schedule') { Pass 'help' } else { Fail 'help' }
  $r = Invoke-Aicm @('bogus')
  if ($r.ExitCode -ne 0) { Pass 'unknown command rejected' } else { Fail 'unknown command accepted' }

  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match 'no schedule installed') { Pass 'doctor flags missing schedule' } else { Fail "doctor without schedule: $($r.Output)" }

  $accepted = @()
  foreach ($bad in '25:99', '24:00', '7:60', '5', 'ab:cd') {
    $r = Invoke-Aicm @('schedule', 'install', '-CleanAt', $bad, '-KeepLegacyTask')
    if ($r.ExitCode -eq 0) { $accepted += $bad }
  }
  if ($accepted.Count -eq 0 -and -not (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)) { Pass 'invalid times rejected before anything is registered' } else { Fail "invalid times accepted: $($accepted -join ', ')" }

  $r = Invoke-Aicm @('schedule', 'install', '-UpdateAt', '06:15', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-CleanDay', 'Sunday', '-CleanAt', '13:05', '-Targets', 'codex,claude', '-KeepLegacyTask')
  $update = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -ErrorAction SilentlyContinue
  $inventory = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -ErrorAction SilentlyContinue
  $clean = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Clean' -ErrorAction SilentlyContinue
  $maintenance = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Maintenance' -ErrorAction SilentlyContinue
  if ($maintenance -and $maintenance.Triggers[0].Repetition.Interval -eq 'PT1H' -and $maintenance.Actions[0].Arguments -match 'maintenance -DryRun') { Pass 'hourly maintenance defaults to dry-run' } else { Fail 'maintenance task' }
  if ($update -and $inventory -and $clean -and $maintenance) { Pass 'four tasks registered' } else { Fail "tasks missing: $($r.Output)" }
  if ($inventory -and $inventory.Triggers[0].DaysOfWeek -eq 8 -and ([datetime]$inventory.Triggers[0].StartBoundary).ToString('HH:mm') -eq '11:40' -and $inventory.Actions[0].Arguments -match 'inventory_ai_clis\.ps1') { Pass 'inventory trigger (Wednesday) and arguments' } else { Fail 'inventory task' }
  if ($update -and $update.Actions[0].Arguments -match '-Targets "codex,claude"' -and $update.Actions[0].Arguments -match 'update_ai_clis\.ps1') { Pass 'update task arguments' } else { Fail 'update task arguments' }
  if ($update -and ([datetime]$update.Triggers[0].StartBoundary).ToString('HH:mm') -eq '06:15') { Pass 'update time' } else { Fail 'update time' }
  if ($clean -and $clean.Triggers[0].DaysOfWeek -eq 1 -and ([datetime]$clean.Triggers[0].StartBoundary).ToString('HH:mm') -eq '13:05') { Pass 'clean day and time (Sunday)' } else { Fail 'clean trigger' }
  if ($clean -and $clean.Actions[0].Arguments -match 'clean_ai_leftovers\.ps1') { Pass 'clean task arguments' } else { Fail 'clean task arguments' }
  $appDir = Join-Path $aicmHome 'app'
  if ((Test-Path -LiteralPath "$appDir\bin\update_ai_clis.ps1") -and (Test-Path -LiteralPath "$appDir\SOURCE")) { Pass 'jobs run an installed copy, not the clone' } else { Fail 'installed copy' }
  $launcherFile = [string]$update.Actions[0].Execute
  if ($update -and $launcherFile -match 'aicm-run-[a-f0-9]{24}\.exe$' -and (Test-Path -LiteralPath $launcherFile) -and $update.Actions[0].Arguments -like "*$appDir\bin\update_ai_clis.ps1*") { Pass 'tasks start from the windowless launcher and installed copy' } else { Fail "task action: $($update.Actions[0].Execute) $($update.Actions[0].Arguments)" }
  if ($update -and $update.Actions[0].Arguments -match '-Scheduled' -and $update.Triggers[0].Repetition.Interval -eq 'PT3H') { Pass 'update task retries every 3 hours' } else { Fail 'update retry' }
  $schedFile = "$aicmHome\state\schedule.json"
  $o = (Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json).options
  if ($o.updateAt -eq '06:15' -and $o.inventoryDay -eq 'Wednesday' -and $o.inventoryAt -eq '11:40' -and $o.cleanDay -eq 'Sunday' -and $o.cleanAt -eq '13:05' -and $o.targets -eq 'codex,claude') { Pass 'schedule.json keeps the install options' } else { Fail "options: $($o | ConvertTo-Json -Compress)" }

  # A legacy action is migrated with its argument string, trigger, principal and settings intact.
  $legacyFile = Join-Path $appDir 'windows\run-hidden.vbs'
  "' isolated legacy fixture" | Set-Content -LiteralPath $legacyFile -Encoding ASCII
  Add-Content -LiteralPath (Join-Path $appDir '.aicm-copy') -Value 'windows/run-hidden.vbs' -Encoding UTF8
  $legacyArgs = ('//B //Nologo "{0}" powershell.exe {1}' -f (Join-Path $appDir 'windows\run-hidden.vbs'), $update.Actions[0].Arguments)
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $legacyArgs) | Out-Null
  $legacyState = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  $legacyState.launcher = 'wscript'
  $legacyState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $schedFile -Encoding UTF8
  [xml]$beforeXml = Export-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  $beforeParts = $beforeXml.Task.Triggers.OuterXml + $beforeXml.Task.Principals.OuterXml + $beforeXml.Task.Settings.OuterXml
  $appHashBefore = (Get-ChildItem -LiteralPath $appDir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
  }) -join ';'
  $migrationOnly = Invoke-Script 'windows\migrate-windowless-tasks.ps1' @()
  $appHashAfter = (Get-ChildItem -LiteralPath $appDir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
  }) -join ';'
  $newState = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  $onlyLines = @($migrationOnly.Output -split '\r?\n' | Where-Object { $_ -match '^schedule backup: ' } | Select-Object -First 1)
  $onlyBackup = if ($onlyLines.Count -eq 1) { $onlyLines[0] -replace '^schedule backup: ', '' } else { '' }
  if ($migrationOnly.ExitCode -eq 0 -and $appHashBefore -ceq $appHashAfter -and $newState.launcher -eq 'windowless' -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Execute -eq $launcherFile) { Pass 'launcher-only migration preserves every installed app file' } else { Fail "launcher-only migration: $($migrationOnly.Output)" }
  $backupsDir = Split-Path -Parent $onlyBackup
  $backupCount = @(Get-ChildItem -LiteralPath $backupsDir -Directory).Count
  $stateHash = (Get-FileHash -LiteralPath $schedFile -Algorithm SHA256).Hash
  $repeatProblem = ''
  foreach ($attempt in 1..5) {
    $repeatMigration = Invoke-Script 'windows\migrate-windowless-tasks.ps1' @()
    if ($repeatMigration.ExitCode -ne 0 -or $repeatMigration.Output -notmatch 'already use the verified windowless launcher' -or
        @(Get-ChildItem -LiteralPath $backupsDir -Directory).Count -ne $backupCount -or
        (Get-FileHash -LiteralPath $schedFile -Algorithm SHA256).Hash -cne $stateHash) {
      $repeatProblem = "attempt $attempt`: $($repeatMigration.Output)"; break
    }
  }
  if (-not $repeatProblem) { Pass 'five repeated launcher-only migrations make no backup or state changes' } else { Fail "repeated migration: $repeatProblem" }
  $savedScheduleHome = [Environment]::GetEnvironmentVariable('AICM_HOME')
  $heldScheduleLock = $null
  $worker = $null; $workerBlocked = $false
  try {
    $env:AICM_HOME = $aicmHome
    $heldScheduleLock = Enter-AicmScheduleLock 0
    $blocked = Invoke-Lib $root 'try { $m = Enter-AicmScheduleLock 200; Exit-AicmScheduleLock $m; exit 0 } catch { Write-Host $_.Exception.Message; exit 19 }'
    if ($blocked.ExitCode -eq 19 -and $blocked.Output -match 'another schedule operation is in progress') { Pass 'a second process cannot acquire the schedule mutation lock' } else { Fail "schedule lock: $($blocked.Output)" }
    $workerFile = Join-Path $work 'schedule-lock-worker.ps1'
    $readyFile = Join-Path $work 'schedule-lock-worker.ready'
    @'
param([string]$Ready, [string]$Migration)
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($Ready, 'ready')
& $Migration
'@ | Set-Content -LiteralPath $workerFile -Encoding ASCII
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Process -Id $PID).Path
    $start.Arguments = Join-AicmProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerFile, $readyFile, (Join-Path $root 'windows\migrate-windowless-tasks.ps1'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.EnvironmentVariables['USERPROFILE'] = $fakeHome
    $start.EnvironmentVariables['HOME'] = $fakeHome
    $start.EnvironmentVariables['AICM_HOME'] = $aicmHome
    $start.EnvironmentVariables['LOCALAPPDATA'] = "$fakeHome\AppData\Local"
    $start.EnvironmentVariables['AICM_TASK_PATH'] = $taskPath
    $start.EnvironmentVariables['TEMP'] = "$work\tmp"; $start.EnvironmentVariables['TMP'] = "$work\tmp"
    $worker = [Diagnostics.Process]::Start($start)
    $workerOut = $worker.StandardOutput.ReadToEndAsync(); $workerErr = $worker.StandardError.ReadToEndAsync()
    $readyDeadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $readyFile) -and -not $worker.HasExited -and (Get-Date) -lt $readyDeadline) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 1000
    $workerBlocked = (Test-Path -LiteralPath $readyFile) -and -not $worker.HasExited
  } finally {
    if ($heldScheduleLock) { Exit-AicmScheduleLock $heldScheduleLock }
    [Environment]::SetEnvironmentVariable('AICM_HOME', $savedScheduleHome)
  }
  try {
    if (-not $worker.WaitForExit(30000)) { $worker.Kill(); $worker.WaitForExit(); Fail 'concurrent migration did not finish after the lock was released' }
    elseif ($workerBlocked -and $worker.ExitCode -eq 0 -and $workerOut.GetAwaiter().GetResult() -match 'already use the verified windowless launcher') { Pass 'concurrent migration waits until the schedule lock is released' }
    else { Fail "concurrent migration: $($workerErr.GetAwaiter().GetResult())" }
  } finally { if ($worker) { $worker.Dispose() } }
  $originalInventoryAction = (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0]
  try {
    $driftArgs = ('//B //Nologo "{0}" powershell.exe {1}' -f $legacyFile, $originalInventoryAction.Arguments)
    Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $driftArgs) | Out-Null
    $drift = Invoke-Aicm @('doctor')
    if ($drift.Output -match "'Inventory' uses a legacy launcher despite windowless state") { Pass 'doctor detects a legacy action even if state says windowless' } else { Fail "launcher drift: $($drift.Output)" }
  } finally { Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action $originalInventoryAction | Out-Null }
  $scheduleBackup = Join-Path $onlyBackup 'schedule.json'
  $scheduleBytes = [IO.File]::ReadAllBytes($scheduleBackup)
  [IO.File]::AppendAllText($scheduleBackup, ' ')
  $refusedState = Invoke-Script 'windows\restore-schedule-backup.ps1' @('-BackupDir', $onlyBackup, '-ActionsOnly')
  if ($refusedState.ExitCode -ne 0 -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Execute -eq $launcherFile) { Pass 'launcher-only rollback refuses a modified schedule state backup before changing tasks' } else { Fail "tampered schedule backup: $($refusedState.Output)" }
  [IO.File]::WriteAllBytes($scheduleBackup, $scheduleBytes)
  $onlyRollback = Invoke-Script 'windows\restore-schedule-backup.ps1' @('-BackupDir', $onlyBackup, '-ActionsOnly')
  $restoredState = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  if ($onlyRollback.ExitCode -eq 0 -and $restoredState.launcher -eq 'wscript' -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Arguments -eq $legacyArgs) { Pass 'launcher-only rollback restores task action and state' } else { Fail "launcher-only rollback: $($onlyRollback.Output)" }
  $r = Invoke-Aicm @('schedule', 'refresh')
  $migrated = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  [xml]$afterXml = Export-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  $afterParts = $afterXml.Task.Triggers.OuterXml + $afterXml.Task.Principals.OuterXml + $afterXml.Task.Settings.OuterXml
  if ($r.ExitCode -eq 0 -and $migrated.Actions[0].Execute -eq $launcherFile -and $migrated.Actions[0].Arguments -eq $update.Actions[0].Arguments -and $beforeParts -ceq $afterParts -and $r.Output -match 'schedule backup: ') { Pass 'migration backs up and preserves arguments, trigger, principal and settings' } else { Fail "legacy migration: $($r.Output)" }
  $backupLine = @($r.Output -split '\r?\n' | Where-Object { $_ -match '^schedule backup: ' } | Select-Object -First 1)
  $backupPath = if ($backupLine.Count -eq 1) { $backupLine[0] -replace '^schedule backup: ', '' } else { '' }
  $backupXml = Join-Path $backupPath 'Update.xml'
  $backupBytes = [IO.File]::ReadAllBytes($backupXml)
  [IO.File]::AppendAllText($backupXml, ' ')
  $refused = Invoke-Script 'windows\restore-schedule-backup.ps1' @('-BackupDir', $backupPath)
  if ($refused.ExitCode -ne 0 -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Execute -eq $launcherFile) { Pass 'rollback refuses a modified task backup' } else { Fail "tampered backup: $($refused.Output)" }
  [IO.File]::WriteAllBytes($backupXml, $backupBytes)
  $rollback = Invoke-Script 'windows\restore-schedule-backup.ps1' @('-BackupDir', $backupPath)
  $restored = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  if ($rollback.ExitCode -eq 0 -and $restored.Actions[0].Execute -eq 'wscript.exe' -and $restored.Actions[0].Arguments -eq $legacyArgs -and (Test-Path -LiteralPath $legacyFile)) { Pass 'rollback restores the backed-up launcher action and installed copy' } else { Fail "rollback: $($rollback.Output)" }
  $r = Invoke-Aicm @('schedule', 'refresh')
  if ($r.ExitCode -eq 0 -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Execute -eq $launcherFile) { Pass 'a restored legacy task can be migrated again' } else { Fail "remigrate: $($r.Output)" }
  # The rollback deliberately preserves the newer app beside the old one. Remove only this fixture.
  Get-ChildItem -LiteralPath $aicmHome -Directory -Filter 'app.rollback-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
  $alternate = Join-Path $work 'alternate source'
  New-Item -ItemType Directory -Path $alternate -Force | Out-Null
  foreach ($dir in 'bin', 'lib', 'rules', 'windows') { Copy-Item -LiteralPath (Join-Path $root $dir) -Destination (Join-Path $alternate $dir) -Recurse -Force }
  foreach ($file in 'VERSION', 'LICENSE', 'README.md') { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $alternate $file) -Force }
  $sourceBefore = [IO.File]::ReadAllText((Join-Path $appDir 'SOURCE')).Trim()
  $r = Invoke-Child @('-File', (Join-Path $alternate 'bin\aicm.ps1'), 'schedule', 'refresh', '-PreserveSource')
  $sourceAfter = [IO.File]::ReadAllText((Join-Path $appDir 'SOURCE')).Trim()
  $stateSource = (Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json).source
  if ($r.ExitCode -eq 0 -and $sourceAfter -eq $sourceBefore -and $stateSource -eq $sourceBefore) { Pass 'an alternate checkout preserves the original update source' } else { Fail "preserve source: $($r.Output)" }
  $hold = Join-Path $work 'hold-task.ps1'
  'Start-Sleep -Seconds 90' | Set-Content -LiteralPath $hold -Encoding ASCII
  $savedAction = (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0]
  $holdArgs = '-NoProfile -NonInteractive -File "{0}"' -f $hold
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute $launcherFile -Argument $holdArgs) | Out-Null
  try {
    Start-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory'
    $deadline = (Get-Date).AddSeconds(30)
    do { Start-Sleep -Milliseconds 250; $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').State } while ($state -ne 'Running' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Running') { Fail 'fixture task did not start' }
    else {
      $r = Invoke-Aicm @('schedule', 'refresh')
      if ($r.ExitCode -ne 0 -and $r.Output -match 'Inventory is running or queued' -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0].Arguments -eq $holdArgs) { Pass 'refresh leaves a running task untouched' } else { Fail "running task: $($r.Output)" }
    }
  } finally {
    Stop-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -ErrorAction SilentlyContinue
    $stopping = (Get-Date).AddSeconds(20)
    while ((Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').State -eq 'Running' -and (Get-Date) -lt $stopping) { Start-Sleep -Milliseconds 250 }
    # Reset the fixture's LastTaskResult after intentionally stopping it, using a hidden no-op.
    $success = Join-Path $work 'exit-zero.ps1'
    'exit 0' | Set-Content -LiteralPath $success -Encoding ASCII
    $successArgs = '-NoProfile -NonInteractive -File "{0}"' -f $success
    Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute $launcherFile -Argument $successArgs) | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory'
    $resetDeadline = (Get-Date).AddSeconds(30)
    do {
      Start-Sleep -Milliseconds 250
      $resetInfo = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Inventory'
      $resetState = (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').State
    } while (($resetInfo.LastTaskResult -ne 0 -or $resetState -eq 'Running') -and (Get-Date) -lt $resetDeadline)
    if ($resetInfo.LastTaskResult -ne 0 -or $resetState -eq 'Running') { Fail 'fixture task status did not reset to success' }
    Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action $savedAction | Out-Null
  }

  # Installing the same schedule again changes no task; an unrecognized action fails closed.
  $installArgs = @('schedule', 'install', '-UpdateAt', '06:15', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-CleanDay', 'Sunday', '-CleanAt', '13:05', '-Targets', 'codex,claude', '-KeepLegacyTask')
  $r = Invoke-Aicm $installArgs
  if ($r.Output -match 'unchanged:' -and $r.Output -notmatch 'registered:') { Pass 'same install again leaves the tasks alone' } else { Fail "reinstall: $($r.Output)" }
  $wantArgs = $update.Actions[0].Arguments
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -Action (New-ScheduledTaskAction -Execute $launcherFile -Argument 'stale arguments') | Out-Null
  $r = Invoke-Aicm @('schedule', 'refresh')
  if ($r.ExitCode -ne 0 -and (Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Arguments -eq 'stale arguments') { Pass 'refresh refuses an unrecognized action without changing it' } else { Fail "refresh: $($r.Output)" }
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -Action (New-ScheduledTaskAction -Execute $launcherFile -Argument $wantArgs) | Out-Null
  $r = Invoke-Aicm @('schedule', 'refresh')
  if ($r.Output -match 'already match' -and $r.Output -notmatch 'registered:') { Pass 'refresh with nothing to change changes nothing' } else { Fail "second refresh: $($r.Output)" }
  $custom = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 47) -MultipleInstances Queue
  $inventoryArgs = [string](Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0].Arguments
  $legacyInventory = ('//B //Nologo "{0}" powershell.exe {1}' -f (Join-Path $appDir 'windows\run-hidden.vbs'), $inventoryArgs)
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Settings $custom -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $legacyInventory) | Out-Null
  Disable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  $r = Invoke-Aicm @('schedule', 'refresh')
  $i = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory'
  if ($i.State -eq 'Disabled' -and [System.Xml.XmlConvert]::ToTimeSpan($i.Settings.ExecutionTimeLimit).TotalMinutes -eq 47 -and $i.Settings.MultipleInstances -eq 1) { Pass 'refresh keeps disabled state and custom task settings when action changes' } else { Fail "refresh settings : state=$($i.State), limit=$($i.Settings.ExecutionTimeLimit), instances=$($i.Settings.MultipleInstances) $($r.Output)" }
  Enable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  # A schedule.json written by 2.5.1 has no options: refresh reads them back from the tasks.
  $s = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  $installedBefore = $s.installedAt
  $s.PSObject.Properties.Remove('options')
  $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $schedFile -Encoding UTF8
  $r = Invoke-Aicm @('schedule', 'refresh')
  $s = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  if ($r.Output -match 'already match' -and $s.options.updateAt -eq '06:15' -and $s.options.inventoryDay -eq 'Wednesday' -and $s.options.cleanDay -eq 'Sunday' -and $s.options.targets -eq 'codex,claude') { Pass 'refresh of an older schedule keeps its days and times' } else { Fail "old refresh: $($r.Output) $($s | ConvertTo-Json -Compress)" }
  if ($s.installedAt -eq $installedBefore) { Pass 'refresh keeps installedAt' } else { Fail 'installedAt changed' }

  $beforeTasks = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
  $r = Invoke-Aicm @('schedule', 'install', '-CleanCategory', 'sessions,nope', '-KeepLegacyTask')
  $afterBad = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
  if ($r.ExitCode -ne 0 -and ($beforeTasks -join ',') -eq ($afterBad -join ',')) { Pass 'bad clean category changes no tasks' } else { Fail "bad category mutated tasks: $($r.Output)" }
  $r = Invoke-Aicm @('schedule', 'install', '-UpdateAt', '06:15', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-CleanDay', 'Sunday', '-CleanAt', '13:05', '-Targets', 'codex,claude', '-CleanCategory', 'sessions,logs', '-KeepLegacyTask')
  $sched = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  $cleanTask = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Clean'
  if ($sched.options.cleanCategory -eq 'sessions,logs' -and $cleanTask.Actions[0].Arguments -match '-Category sessions,logs') { Pass 'schedule keeps clean category on the task' } else { Fail "category schedule: $($sched.options.cleanCategory) $($cleanTask.Actions[0].Arguments)" }
  $stale = $cleanTask.Actions[0].Arguments -replace '-Category sessions,logs', ''
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Clean' -Action (New-ScheduledTaskAction -Execute $cleanTask.Actions[0].Execute -Argument $stale) | Out-Null
  $null = Invoke-Aicm @('schedule', 'refresh')
  $cleanTask = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Clean'
  $sched = Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json
  if ($cleanTask.Actions[0].Arguments -notmatch '-Category sessions,logs' -and $sched.options.cleanCategory -eq 'sessions,logs') { Pass 'refresh preserves the task arguments even if stored options differ' } else { Fail "category refresh: $($cleanTask.Actions[0].Arguments)" }
  $null = Invoke-Aicm @('schedule', 'install', '-UpdateAt', '06:15', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-CleanDay', 'Sunday', '-CleanAt', '13:05', '-Targets', 'codex,claude', '-KeepLegacyTask')

  # The installed copy: never downgraded, swapped only when complete, the old copy kept on any failure.
  $appDir = Join-Path $aicmHome 'app'
  Set-Content -LiteralPath "$appDir\VERSION" -Value '99.0.0'
  $r = Invoke-Lib $appDir 'Update-AicmAppCopy'
  if ((Get-Content -LiteralPath "$appDir\VERSION" -TotalCount 1) -eq '99.0.0' -and $r.Output -match 'not newer') { Pass 'an older version in the clone does not downgrade the copy' } else { Fail "downgrade: $($r.Output)" }
  Set-Content -LiteralPath "$appDir\VERSION" -Value '0.0.1'
  $inventoryArgs = [string](Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0].Arguments
  $legacyInventory = ('//B //Nologo "{0}" powershell.exe {1}' -f (Join-Path $appDir 'windows\run-hidden.vbs'), $inventoryArgs)
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $legacyInventory) | Out-Null
  $r = Invoke-Lib $appDir 'Update-AicmAppCopy'
  if ((Get-Content -LiteralPath "$appDir\VERSION" -TotalCount 1) -eq $version -and $r.Output -match 'updated 0\.0\.1 -> ') { Pass 'a newer version in the clone refreshes the copy' } else { Fail "upgrade: $($r.Output)" }
  if ((Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0].Arguments -match 'inventory_ai_clis\.ps1') { Pass 'after the copy is refreshed the tasks are re-registered' } else { Fail "re-register after update: $($r.Output)" }
  # The old copy is recognized by the content of a file every copy has: any file a copy never has
  # (app\MARKER, app\bin\MARKER) now makes the sync refuse to touch the copy at all (tested in
  # home_ownership_test.ps1), so it would no longer exercise the rollback paths.
  Set-Content -LiteralPath "$appDir\LICENSE" -Value 'old copy marker'
  $r = Invoke-Lib $root 'function Copy-Item { throw "disk full" }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and ((Get-Content -LiteralPath "$appDir\LICENSE" -Raw) -match 'old copy marker') -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'a failed copy keeps the old copy' } else { Fail "failed copy: $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Lib $root 'function Copy-Item { param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force, $ErrorAction) Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force; if ($Destination -like "*\lib") { Remove-Item -LiteralPath (Join-Path $Destination "aicm-common.ps1") } }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and $r.Output -match 'incomplete' -and ((Get-Content -LiteralPath "$appDir\LICENSE" -Raw) -match 'old copy marker') -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'an incomplete copy is not swapped in' } else { Fail "incomplete copy: $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Lib $root 'function Move-Item { param([string]$LiteralPath, [string]$Destination, $ErrorAction) if ($LiteralPath -like "*.new") { throw "locked by a scanner" }; Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination }; function Start-Sleep { }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and ((Get-Content -LiteralPath "$appDir\LICENSE" -Raw) -match 'old copy marker') -and -not (Test-Path -LiteralPath "$appDir.old") -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'a failed swap puts the old copy back' } else { Fail "failed swap: $($r.ExitCode) $($r.Output)" }
  Rename-Item -LiteralPath $appDir -NewName 'app.old'
  $r = Invoke-Lib $root 'Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath "$appDir\bin\update_ai_clis.ps1") -and -not ((Get-Content -LiteralPath "$appDir\LICENSE" -Raw) -match 'old copy marker') -and -not (Test-Path -LiteralPath "$appDir.old")) { Pass 'a copy left half-swapped is completed by the next sync' } else { Fail "recovery: $($r.ExitCode) $($r.Output)" }

  # Explicit AICM_HOME aliases are management roots; stale app.old must not brick the next sync.
  $managed = Join-Path $work 'managed-target'
  $alias = Join-Path $work 'managed-alias'
  New-Item -ItemType Directory -Path $managed | Out-Null
  New-Item -ItemType Junction -Path $alias -Target $managed | Out-Null
  try {
    $r = Invoke-Lib $root "`$env:AICM_HOME = '$alias\.manager'; foreach (`$attempt in 1,2,3,4) { Sync-AicmAppCopy (Get-AicmRoot) }"
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath "$managed\.manager\app\bin\aicm.ps1") -and -not (Test-Path -LiteralPath "$managed\.manager\app.old")) { Pass 'repeated app-copy sync through a selected home junction completes and removes stale copies' } else { Fail "home junction sync: $($r.Output)" }
    Set-Content -LiteralPath "$managed\.manager\app\LICENSE" -Value 'old copy marker'
    $r = Invoke-Lib $root "`$env:AICM_HOME = '$alias\.manager'; function Copy-Item { throw 'disk full' }; Sync-AicmAppCopy (Get-AicmRoot)"
    if ($r.ExitCode -ne 0 -and ((Get-Content -LiteralPath "$managed\.manager\app\LICENSE" -Raw) -match 'old copy marker') -and -not (Test-Path -LiteralPath "$managed\.manager\app.new")) { Pass 'failed app-copy sync under a home junction keeps the previous copy' } else { Fail "home junction rollback: $($r.Output)" }
  } finally { [IO.Directory]::Delete($alias, $false) }

  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match 'no update run') { Pass 'doctor flags missing update run' } else { Fail "doctor before runs: $($r.Output)" }

  $null = Invoke-Aicm @('clean')
  if (Test-Path -LiteralPath "$aicmHome\state\last-clean.json") { Pass 'clean writes state' } else { Fail 'clean state' }

  $r = Invoke-Aicm @('update', '-DryRun', '-Targets', 'none')
  if ($r.ExitCode -eq 0) { Pass 'update dry run exits 0' } else { Fail "update dry run exit $($r.ExitCode): $($r.Output)" }
  if (-not (Test-Path -LiteralPath "$aicmHome\state\last-update.json")) { Pass 'dry run writes no update state' } else { Fail 'dry run wrote state' }
  if (Test-Path -LiteralPath "$aicmHome\logs\latest.log") { Pass 'update log in new home' } else { Fail 'update log location' }

  Write-FreshUpdateState
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match 'no inventory run') { Pass 'doctor flags missing inventory run' } else { Fail "doctor without inventory: $($r.Output)" }
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  "{`"finishedAt`":`"$stamp`",`"version`":`"x`",`"ok`":true,`"clis`":[]}" | Set-Content -LiteralPath "$aicmHome\state\inventory.json" -Encoding UTF8
  @{ finishedAt = (Get-Date).ToUniversalTime().ToString('o'); ok = $true } | ConvertTo-Json | Set-Content -LiteralPath "$aicmHome\state\last-maintenance.json" -Encoding UTF8
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 0) { Pass 'doctor healthy after runs' } else { Fail "doctor after runs: $($r.Output)" }
  if ($r.Output -match [regex]::Escape("info: installed copy $aicmHome\app version $version")) { Pass 'doctor shows the installed copy and its version' } else { Fail "doctor info: $($r.Output)" }
  # Healthy tasks and recent runs, but an update policy the updater would refuse: not healthy.
  $policyFile = Join-Path $aicmHome 'update-policy.json'
  foreach ($bad in '{"schemaVersion":1,"tools":{"codex":{"exclude":"yes"}}}', '{"schemaVersion":1,"tools":{"gpt":{"exclude":true},"codex":{"exclude":false}}}', 'not json') {
    [System.IO.File]::WriteAllText($policyFile, $bad)
    $before = (Get-ChildItem -LiteralPath $aicmHome -Recurse -Force | Where-Object { $_.Name -notlike '*.log' } | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
    $r = Invoke-Aicm @('doctor')
    $after = (Get-ChildItem -LiteralPath $aicmHome -Recurse -Force | Where-Object { $_.Name -notlike '*.log' } | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
    if ($r.ExitCode -eq 1 -and $r.Output -match 'problem: update policy: .*refuses to run until it is fixed' -and $r.Output -notmatch 'healthy:' -and $after -eq $before) { Pass "doctor fails on an invalid policy and changes nothing: $bad" } else { Fail "doctor with policy $bad : $($r.ExitCode) $($r.Output)" }
  }
  [System.IO.File]::WriteAllText($policyFile, '{"schemaVersion":1,"tools":{"codex":{"exclude":true}}}')
  $savedRuntime = $runtimePath
  $runtimePath = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
  try { $r = Invoke-Aicm @('doctor') } finally { $runtimePath = $savedRuntime }
  if ($r.ExitCode -eq 1 -and $r.Output -match 'Node\.js is required to read it') { Pass 'doctor fails when the policy needs a missing Node.js' } else { Fail "doctor without node: $($r.Output)" }
  Remove-Item -LiteralPath $policyFile -Force

  # A registered task that cannot work: turned off, its script gone, or its last run failed.
  Disable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Inventory' is disabled") { Pass 'doctor notices a disabled task' } else { Fail "disabled task: $($r.Output)" }
  Enable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  Move-Item -LiteralPath $launcherFile -Destination "$launcherFile.away"
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Update' starts .*aicm-run-.*\.exe, which does not exist") { Pass 'doctor notices a missing launcher' } else { Fail "missing file: $($r.Output)" }
  Move-Item -LiteralPath "$launcherFile.away" -Destination $launcherFile
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 5') | Out-Null
  Start-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory'
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Inventory').LastTaskResult -ne 5) { Start-Sleep -Milliseconds 250 }
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Inventory' failed on its last run \(result 0x5\)") { Pass 'doctor notices a task whose last run failed' } else { Fail "failed run: $($r.Output)" }
  $null = Invoke-Aicm @('schedule', 'refresh')

  # Someone deletes the cleanup task: doctor and the next update run must notice.
  Unregister-ScheduledTask -TaskPath $taskPath -TaskName 'Clean' -Confirm:$false
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Clean' is missing") { Pass 'doctor notices a deleted task' } else { Fail "deleted task: $($r.Output)" }
  $r = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'none')
  if ($r.Output -match "notify: .*'Clean' is missing") { Pass 'update run notifies about the deleted task' } else { Fail "update did not notify: $($r.Output)" }
  $nlog = "$aicmHome\logs\notifications.log"
  if ((Test-Path -LiteralPath $nlog) -and ((Get-Content -LiteralPath $nlog -Raw) -match "(?m)^\d{4}-\d{2}-\d{2} [\d:]{8} AI CLI Auto Manager - .*'Clean' is missing")) { Pass 'notifications are kept in notifications.log' } else { Fail 'notification log' }
  $r = Invoke-Aicm @('doctor')
  if ($r.Output -match 'recent notifications' -and $r.Output -match "'Clean' is missing") { Pass 'doctor shows the recent notifications' } else { Fail "doctor notifications: $($r.Output)" }
  $keepLog = Get-Content -LiteralPath $nlog
  Set-Content -LiteralPath $nlog -Value (1..650 | ForEach-Object { "old $_" })
  $null = Invoke-Lib $root "Send-AicmNotification 'T' 'new one'"
  $lines = @(Get-Content -LiteralPath $nlog)
  if ($lines.Count -eq 500 -and $lines[-1] -match 'T - new one') { Pass 'notifications.log keeps the last 500 lines' } else { Fail "log trim: $($lines.Count)" }
  Set-Content -LiteralPath $nlog -Value $keepLog

  # A registered job that has not completed for too long is caught by the others.
  $sched = Get-Content -LiteralPath "$aicmHome\state\schedule.json" -Raw | ConvertFrom-Json
  $sched.installedAt = (Get-Date).ToUniversalTime().AddDays(-20).ToString('o')
  $sched | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$aicmHome\state\schedule.json" -Encoding UTF8
  Remove-Item -LiteralPath "$aicmHome\state\inventory.json" -ErrorAction SilentlyContinue
  $r = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'none')
  if ($r.Output -match "'Inventory' has not completed for over 9 days") { Pass 'a job that stopped completing is reported by another job' } else { Fail "stale job: $($r.Output)" }
  $null = Invoke-Aicm @('schedule', 'remove')
  if (-not (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)) { Pass 'schedule remove' } else { Fail 'schedule remove' }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    $r = Invoke-Aicm @('config')
    if ($r.Output -match 'MCP servers per CLI') { Pass 'aicm config runs the node module' } else { Fail "aicm config: $($r.Output)" }
    $r = Invoke-Aicm @('processes', '-Json')
    $report = $r.Output | ConvertFrom-Json
    if ($r.ExitCode -eq 0 -and $report.ok -and $report.dryRun) { Pass 'aicm processes uses safe maintenance' } else { Fail "aicm processes: $($r.Output)" }
  }
  $null = Invoke-Aicm @('schedule', 'install', '-KeepLegacyTask')
  $null = Invoke-Aicm @('uninstall')
  if (-not (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $aicmHome 'app')) -and (Test-Path -LiteralPath (Join-Path $aicmHome 'state'))) { Pass 'uninstall removes tasks and the copy, keeps state' } else { Fail 'uninstall' }
  if (Test-Path -LiteralPath "$aicmHome\.aicm-home") { Pass 'the home folder is marked as ours' } else { Fail 'no .aicm-home marker' }
  New-Item -ItemType Directory -Path "$aicmHome\hooks" -Force | Out-Null
  Set-Content -LiteralPath "$aicmHome\hooks\post-update.ps1" -Value 'Write-Host hi'
  Set-Content -LiteralPath "$aicmHome\ai-clis.local.conf" -Value '# mine'
  $null = Invoke-Aicm @('uninstall', '-Purge')
  if ((Test-Path -LiteralPath "$aicmHome\hooks\post-update.ps1") -and (Test-Path -LiteralPath "$aicmHome\ai-clis.local.conf") -and -not (Test-Path -LiteralPath "$aicmHome\state") -and -not (Test-Path -LiteralPath "$aicmHome\logs")) { Pass 'uninstall -Purge keeps hooks and local rules' } else { Fail "purge with user files: $(@(Get-ChildItem -LiteralPath $aicmHome -Force -ErrorAction SilentlyContinue).Name -join ' ')" }
  Remove-Item -LiteralPath "$aicmHome\hooks", "$aicmHome\ai-clis.local.conf" -Recurse -Force
  $null = Invoke-Aicm @('uninstall', '-Purge')
  if (-not (Test-Path -LiteralPath $aicmHome)) { Pass 'uninstall -Purge removes everything' } else { Fail 'purge' }
  # AICM_HOME pointed at a folder that is not ours: refused, nothing deleted.
  $notOurs = Join-Path $work 'dotconfig'
  New-Item -ItemType Directory -Path "$notOurs\state", "$notOurs\app" -Force | Out-Null
  Set-Content -LiteralPath "$notOurs\state\other-app.json" -Value 'keep'
  Set-Content -LiteralPath "$notOurs\app\x" -Value 'keep'
  $savedHome = $aicmHome
  $aicmHome = $notOurs
  try { $r = Invoke-Aicm @('uninstall', '-Purge') } finally { $aicmHome = $savedHome }
  if ($r.ExitCode -ne 0 -and (Test-Path -LiteralPath "$notOurs\state\other-app.json") -and (Test-Path -LiteralPath "$notOurs\app\x")) { Pass 'uninstall -Purge refuses a folder without the marker' } else { Fail "unmarked purge: $($r.ExitCode) $($r.Output)" }

  # An existing project used as AICM_HOME: help, previews and refused commands never mark or change it.
  $proj = Join-Path $work 'project'
  New-Item -ItemType Directory -Path "$proj\src", "$proj\app", "$proj\logs" -Force | Out-Null
  Set-Content -LiteralPath "$proj\src\main.c" -Value 'int main(void) { return 0; }'
  Set-Content -LiteralPath "$proj\app\personal.txt" -Value 'mine'
  Set-Content -LiteralPath "$proj\app\SOURCE" -Value 'mine'
  Set-Content -LiteralPath "$proj\logs\build.log" -Value 'mine'
  $projBefore = (Get-ChildItem -LiteralPath $proj -Recurse -Force | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
  $savedHome = $aicmHome
  $aicmHome = $proj
  try {
    foreach ($a in @(@('help'), @('update', '-DryRun', '-Targets', 'none'), @('clean', '-DryRun'), @('clean', '-Json', '-DryRun'),
      @('uninstall', '-Purge', '-DryRun'), @('schedule', 'install', '-CleanAt', '99:99', '-KeepLegacyTask'), @('schedule', 'install', '-KeepLegacyTask'),
      @('update', '-Targets', 'none'), @('clean'), @('uninstall', '-Purge'))) { $null = Invoke-Aicm $a }
  } finally { $aicmHome = $savedHome }
  $projAfter = (Get-ChildItem -LiteralPath $proj -Recurse -Force | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
  if (-not (Test-Path -LiteralPath "$proj\.aicm-home") -and $projAfter -eq $projBefore) { Pass 'help, previews and refused commands leave an existing project untouched' } else { Fail "project changed: $projAfter" }
  if (-not (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)) { Pass 'no task is registered for a foreign home' } else { Fail 'task registered for a foreign home' }

  # uninstall -Purge -DryRun lists what would go and changes nothing, tasks included.
  New-Item -ItemType Directory -Path $aicmHome -Force | Out-Null
  $null = Invoke-Aicm @('schedule', 'install', '-KeepLegacyTask')
  New-Item -ItemType Directory -Path "$aicmHome\logs" -Force | Out-Null
  Set-Content -LiteralPath "$aicmHome\logs\personal.txt" -Value 'mine'
  $homeBefore = (Get-ChildItem -LiteralPath $aicmHome -Recurse -Force | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
  $r = Invoke-Aicm @('uninstall', '-Purge', '-DryRun')
  $homeAfter = (Get-ChildItem -LiteralPath $aicmHome -Recurse -Force | Sort-Object FullName | ForEach-Object { if ($_ -is [IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } else { "directory|$($_.FullName)" } }) -join ';'
  $tasks = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)
  if ($r.ExitCode -eq 0 -and $homeAfter -eq $homeBefore -and $tasks.Count -eq 4 -and $r.Output -match 'would remove: ' -and $r.Output -match 'would remove installed copy' -and $r.Output -match 'logs\\personal\.txt') { Pass 'uninstall -Purge -DryRun lists everything and changes nothing' } else { Fail "purge dry run: $($r.ExitCode) tasks=$($tasks.Count) $($r.Output)" }
  Set-Content -LiteralPath "$aicmHome\app\personal.txt" -Value 'mine'
  $r = Invoke-Aicm @('uninstall')
  if ($r.ExitCode -ne 0 -and (Test-Path -LiteralPath "$aicmHome\app\personal.txt") -and @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue).Count -eq 4) { Pass 'uninstall refuses a copy holding personal files before changing anything' } else { Fail "uninstall with personal app file: $($r.Output)" }
  Remove-Item -LiteralPath "$aicmHome\app\personal.txt"
  $r = Invoke-Aicm @('uninstall', '-Purge')
  if ((Test-Path -LiteralPath "$aicmHome\logs\personal.txt") -and -not (Test-Path -LiteralPath "$aicmHome\app") -and -not (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)) { Pass 'uninstall -Purge keeps a personal log file' } else { Fail "purge personal log: $($r.Output)" }
  New-Item -ItemType Directory -Path $aicmHome -Force | Out-Null

  $r = Invoke-Aicm @('status')
  if ($r.Output -match '== disk use by cleanup rule ==' -and $r.Output -match 'codex-sessions') { Pass 'status shows rules' } else { Fail "status output: $($r.Output)" }

  # Skip the legacy installer if a real root task exists; these tests never modify it.
  if (Get-ScheduledTask -TaskPath '\' -TaskName 'AI CLI Auto Update' -ErrorAction SilentlyContinue) {
    Write-Host 'skip - legacy installer (a real legacy task exists on this machine)'
  } else {
    $r = Invoke-Script 'windows\install_scheduled_task.ps1' @('-At', '04:30')
    $legacy = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -ErrorAction SilentlyContinue
    $others = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -ne 'Update' })
    if ($legacy -and $others.Count -eq 0) { Pass 'legacy installer registers update only' } else { Fail "legacy installer: $($r.Output)" }
    # With all three jobs installed, the legacy installer only changes Update.
    $null = Invoke-Aicm @('schedule', 'install', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-KeepLegacyTask')
    $r = Invoke-Script 'windows\install_scheduled_task.ps1' @('-At', '04:45')
    $u = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -ErrorAction SilentlyContinue
    $i = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -ErrorAction SilentlyContinue
    $c = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Clean' -ErrorAction SilentlyContinue
    $s = Get-Content -LiteralPath "$aicmHome\state\schedule.json" -Raw | ConvertFrom-Json
    if ($u -and $i -and $c -and ([datetime]$u.Triggers[0].StartBoundary).ToString('HH:mm') -eq '04:45' -and $i.Triggers[0].DaysOfWeek -eq 8 -and ([datetime]$i.Triggers[0].StartBoundary).ToString('HH:mm') -eq '11:40' -and @($s.jobs).Count -eq 4 -and $s.options.inventoryDay -eq 'Wednesday' -and $s.options.updateAt -eq '04:45') {
      Pass 'legacy installer keeps Inventory and Clean as they were'
    } else { Fail "legacy installer with all jobs: $($r.Output)" }
  }

  # optimize: fake npm/uv/pnpm .cmd shims (tests\fixtures\optimize-fake.js) in a folder with a space,
  # so the cmd.exe launch path runs for real. No real package manager is reached.
  $optBin = Join-Path $work 'opt bin'
  New-Item -ItemType Directory -Path $optBin -Force | Out-Null
  $nodeExe = (Get-Command node -CommandType Application | Select-Object -First 1).Source
  $fakeJs = Join-Path $root 'tests\fixtures\optimize-fake.js'
  foreach ($t in 'npm', 'uv', 'pnpm') { ('@"{0}" "{1}" {2} %*' -f $nodeExe, $fakeJs, $t) | Set-Content -LiteralPath (Join-Path $optBin "$t.cmd") -Encoding ASCII }
  $optCalls = Join-Path $work 'opt-calls.jsonl'
  $env:FAKE_OPTIMIZE_CALLS = $optCalls
  $procList = Join-Path $work 'procs.json'
  '[{"pid":4,"ppid":0,"name":"System","cmd":""}]' | Set-Content -LiteralPath $procList -Encoding ASCII
  $env:AICM_PROCESS_LIST = $procList
  $savedRuntime = $runtimePath
  $runtimePath = "$optBin;$savedRuntime"
  $optHome = Join-Path $fakeHome 'opt-home'
  $savedAicmHome = $aicmHome
  $aicmHome = $optHome
  try {
    $r = Invoke-Aicm @('help')
    if ($r.Output -match 'aicm.ps1 optimize') { Pass 'help lists optimize' } else { Fail "help: $($r.Output)" }
    $r = Invoke-Aicm @('optimize', '-Json')
    $d = $r.Output | ConvertFrom-Json
    if ($r.ExitCode -eq 0 -and $d.mode -eq 'preview' -and @($d.tasks | Where-Object { $_.status -eq 'would-run' }).Count -eq 3 -and -not (Test-Path -LiteralPath $optCalls) -and -not (Test-Path -LiteralPath $optHome)) {
      Pass 'optimize previews by default: no tool runs, no AICM_HOME is created'
    } else { Fail "optimize preview: $($r.Output)" }
    foreach ($bad in @(@('optimize', '-Tasks', 'bogus', '-Apply'), @('optimize', '-Apply', '-DryRun'))) {
      $r = Invoke-Aicm $bad
      if ($r.ExitCode -eq 2 -and -not (Test-Path -LiteralPath $optCalls) -and -not (Test-Path -LiteralPath $optHome)) { Pass "optimize $($bad[1..($bad.Count - 1)] -join ' ') is refused with no side effects" } else { Fail "optimize bad args: $($r.ExitCode) $($r.Output)" }
    }
    $r = Invoke-Aicm @('optimize', '-Apply', '-Json')
    $calls = @(if (Test-Path -LiteralPath $optCalls) { Get-Content -LiteralPath $optCalls | ForEach-Object { $_ | ConvertFrom-Json } })
    $seen = ($calls | ForEach-Object { (@($_.name) + @($_.args)) -join ' ' }) -join ';'
    if ($r.ExitCode -eq 0 -and $seen -eq 'npm cache verify;uv cache prune;pnpm store prune' -and @($calls | Where-Object { $_.env.npm_config_offline -ne 'true' -or $_.env.COREPACK_ENABLE_NETWORK -ne '0' }).Count -eq 0) {
      Pass 'optimize -Apply runs exactly the three allowlisted commands through cmd.exe, offline'
    } else { Fail "optimize apply: $seen $($r.Output)" }
    if (-not (Test-Path -LiteralPath (Join-Path $optHome 'state\maintenance.lock'))) { Pass 'optimize releases the maintenance lock' } else { Fail 'maintenance lock left behind' }
    Remove-Item -LiteralPath $optCalls -Force
    $env:AICM_PROCESS_LIST = Join-Path $work 'missing-procs.json'
    $r = Invoke-Aicm @('optimize', '-Apply', '-Json')
    $d = $r.Output | ConvertFrom-Json
    if ($r.ExitCode -eq 1 -and @($d.tasks | Where-Object { $_.status -eq 'skipped' }).Count -eq 3 -and -not (Test-Path -LiteralPath $optCalls)) { Pass 'an unreadable process table skips every optimize task' } else { Fail "process table: $($r.Output)" }
  } finally {
    $runtimePath = $savedRuntime
    $aicmHome = $savedAicmHome
    Remove-Item Env:\FAKE_OPTIMIZE_CALLS, Env:\AICM_PROCESS_LIST -ErrorAction SilentlyContinue
  }
} finally {
  Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
  try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $svc.GetFolder('\').DeleteFolder($folderName, 0)
  } catch { }
  Remove-TestWorkspace $work
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
