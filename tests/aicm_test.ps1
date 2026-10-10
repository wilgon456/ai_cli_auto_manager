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
$wshKey = 'HKCU:\Software\AICM Test WSH ' + [guid]::NewGuid().ToString('N')
$script:fails = 0
. (Join-Path $PSScriptRoot 'test-env.ps1')
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
    $output = & $exe -NoProfile -ExecutionPolicy Bypass @PsArguments 2>&1 | Out-String
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
  if ($update -and $inventory -and $clean) { Pass 'three tasks registered' } else { Fail "tasks missing: $($r.Output)" }
  if ($inventory -and $inventory.Triggers[0].DaysOfWeek -eq 8 -and ([datetime]$inventory.Triggers[0].StartBoundary).ToString('HH:mm') -eq '11:40' -and $inventory.Actions[0].Arguments -match 'inventory_ai_clis\.ps1') { Pass 'inventory trigger (Wednesday) and arguments' } else { Fail 'inventory task' }
  if ($update -and $update.Actions[0].Arguments -match '-Targets "codex,claude"' -and $update.Actions[0].Arguments -match 'update_ai_clis\.ps1') { Pass 'update task arguments' } else { Fail 'update task arguments' }
  if ($update -and ([datetime]$update.Triggers[0].StartBoundary).ToString('HH:mm') -eq '06:15') { Pass 'update time' } else { Fail 'update time' }
  if ($clean -and $clean.Triggers[0].DaysOfWeek -eq 1 -and ([datetime]$clean.Triggers[0].StartBoundary).ToString('HH:mm') -eq '13:05') { Pass 'clean day and time (Sunday)' } else { Fail 'clean trigger' }
  if ($clean -and $clean.Actions[0].Arguments -match 'clean_ai_leftovers\.ps1') { Pass 'clean task arguments' } else { Fail 'clean task arguments' }
  $appDir = Join-Path $aicmHome 'app'
  if ((Test-Path -LiteralPath "$appDir\bin\update_ai_clis.ps1") -and (Test-Path -LiteralPath "$appDir\SOURCE")) { Pass 'jobs run an installed copy, not the clone' } else { Fail 'installed copy' }
  if ($update -and $update.Actions[0].Execute -eq 'wscript.exe' -and $update.Actions[0].Arguments -like "*$appDir\windows\run-hidden.vbs*" -and $update.Actions[0].Arguments -like "*$appDir\bin\update_ai_clis.ps1*") { Pass 'tasks start hidden from the installed copy' } else { Fail "task action: $($update.Actions[0].Execute) $($update.Actions[0].Arguments)" }
  if ($update -and $update.Actions[0].Arguments -match '-Scheduled' -and $update.Triggers[0].Repetition.Interval -eq 'PT3H') { Pass 'update task retries every 3 hours' } else { Fail 'update retry' }
  $schedFile = "$aicmHome\state\schedule.json"
  $o = (Get-Content -LiteralPath $schedFile -Raw | ConvertFrom-Json).options
  if ($o.updateAt -eq '06:15' -and $o.inventoryDay -eq 'Wednesday' -and $o.inventoryAt -eq '11:40' -and $o.cleanDay -eq 'Sunday' -and $o.cleanAt -eq '13:05' -and $o.targets -eq 'codex,claude') { Pass 'schedule.json keeps the install options' } else { Fail "options: $($o | ConvertTo-Json -Compress)" }

  # Installing the same schedule again changes nothing; refresh re-registers stale tasks from the stored options.
  $installArgs = @('schedule', 'install', '-UpdateAt', '06:15', '-InventoryDay', 'Wednesday', '-InventoryAt', '11:40', '-CleanDay', 'Sunday', '-CleanAt', '13:05', '-Targets', 'codex,claude', '-KeepLegacyTask')
  $r = Invoke-Aicm $installArgs
  if ($r.Output -match 'unchanged:' -and $r.Output -notmatch 'registered:') { Pass 'same install again leaves the tasks alone' } else { Fail "reinstall: $($r.Output)" }
  $wantArgs = $update.Actions[0].Arguments
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Update' -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument 'stale arguments') | Out-Null
  $r = Invoke-Aicm @('schedule', 'refresh')
  if ((Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').Actions[0].Arguments -eq $wantArgs) { Pass 'refresh puts a stale task back with the stored options' } else { Fail "refresh: $($r.Output)" }
  $r = Invoke-Aicm @('schedule', 'refresh')
  if ($r.Output -match 'already match' -and $r.Output -notmatch 'registered:') { Pass 'refresh with nothing to change changes nothing' } else { Fail "second refresh: $($r.Output)" }
  $custom = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 47) -MultipleInstances Queue
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Settings $custom -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument 'stale arguments') | Out-Null
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

  # The installed copy: never downgraded, swapped only when complete, the old copy kept on any failure.
  $appDir = Join-Path $aicmHome 'app'
  Set-Content -LiteralPath "$appDir\VERSION" -Value '99.0.0'
  $r = Invoke-Lib $appDir 'Update-AicmAppCopy'
  if ((Get-Content -LiteralPath "$appDir\VERSION" -TotalCount 1) -eq '99.0.0' -and $r.Output -match 'not newer') { Pass 'an older version in the clone does not downgrade the copy' } else { Fail "downgrade: $($r.Output)" }
  Set-Content -LiteralPath "$appDir\VERSION" -Value '0.0.1'
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument 'stale arguments') | Out-Null
  $r = Invoke-Lib $appDir 'Update-AicmAppCopy'
  if ((Get-Content -LiteralPath "$appDir\VERSION" -TotalCount 1) -eq $version -and $r.Output -match 'updated 0\.0\.1 -> ') { Pass 'a newer version in the clone refreshes the copy' } else { Fail "upgrade: $($r.Output)" }
  if ((Get-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory').Actions[0].Arguments -match 'inventory_ai_clis\.ps1') { Pass 'after the copy is refreshed the tasks are re-registered' } else { Fail "re-register after update: $($r.Output)" }
  Set-Content -LiteralPath "$appDir\MARKER" -Value 'old'
  $r = Invoke-Lib $root 'function Copy-Item { throw "disk full" }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and (Test-Path -LiteralPath "$appDir\MARKER") -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'a failed copy keeps the old copy' } else { Fail "failed copy: $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Lib $root 'function Copy-Item { param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force, $ErrorAction) Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force; if ($Destination -like "*\lib") { Remove-Item -LiteralPath (Join-Path $Destination "aicm-common.ps1") } }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and $r.Output -match 'incomplete' -and (Test-Path -LiteralPath "$appDir\MARKER") -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'an incomplete copy is not swapped in' } else { Fail "incomplete copy: $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Lib $root 'function Move-Item { param([string]$LiteralPath, [string]$Destination, $ErrorAction) if ($LiteralPath -like "*.new") { throw "locked by a scanner" }; Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination }; function Start-Sleep { }; Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -ne 0 -and (Test-Path -LiteralPath "$appDir\MARKER") -and -not (Test-Path -LiteralPath "$appDir.old") -and -not (Test-Path -LiteralPath "$appDir.new")) { Pass 'a failed swap puts the old copy back' } else { Fail "failed swap: $($r.ExitCode) $($r.Output)" }
  Rename-Item -LiteralPath $appDir -NewName 'app.old'
  $r = Invoke-Lib $root 'Sync-AicmAppCopy (Get-AicmRoot)'
  if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath "$appDir\bin\update_ai_clis.ps1") -and -not (Test-Path -LiteralPath "$appDir\MARKER") -and -not (Test-Path -LiteralPath "$appDir.old")) { Pass 'a copy left half-swapped is completed by the next sync' } else { Fail "recovery: $($r.ExitCode) $($r.Output)" }

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
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 0) { Pass 'doctor healthy after runs' } else { Fail "doctor after runs: $($r.Output)" }

  # A registered task that cannot work: turned off, its script gone, or its last run failed.
  Disable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Inventory' is disabled") { Pass 'doctor notices a disabled task' } else { Fail "disabled task: $($r.Output)" }
  Enable-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' | Out-Null
  $vbsFile = "$aicmHome\app\windows\run-hidden.vbs"
  Rename-Item -LiteralPath $vbsFile -NewName 'run-hidden.vbs.away'
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Update' starts .*run-hidden\.vbs, which does not exist") { Pass 'doctor notices a task whose file is gone' } else { Fail "missing file: $($r.Output)" }
  Rename-Item -LiteralPath "$vbsFile.away" -NewName 'run-hidden.vbs'
  Set-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory' -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 5') | Out-Null
  Start-ScheduledTask -TaskPath $taskPath -TaskName 'Inventory'
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Inventory').LastTaskResult -ne 5) { Start-Sleep -Milliseconds 250 }
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Inventory' failed on its last run \(result 0x5\)") { Pass 'doctor notices a task whose last run failed' } else { Fail "failed run: $($r.Output)" }
  $null = Invoke-Aicm @('schedule', 'refresh')

  # Windows Script Host turned off: the doctor says so, and install falls back to PowerShell.
  New-Item -Path $wshKey -Force | Out-Null
  New-ItemProperty -Path $wshKey -Name 'Enabled' -Value '0' -PropertyType String -Force | Out-Null
  $env:AICM_WSH_KEYS = $wshKey
  try {
    $r = Invoke-Aicm @('doctor')
    if ($r.ExitCode -eq 1 -and $r.Output -match 'Windows Script Host is turned off') { Pass 'doctor notices Windows Script Host turned off' } else { Fail "wsh off: $($r.Output)" }
  } finally { Remove-Item Env:\AICM_WSH_KEYS }
  $env:AICM_WSCRIPT_EXE = Join-Path $work 'no-such-wscript.exe'
  try { $r = Invoke-Aicm $installArgs } finally { Remove-Item Env:\AICM_WSCRIPT_EXE }
  $u = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  $s = Get-Content -LiteralPath "$aicmHome\state\schedule.json" -Raw | ConvertFrom-Json
  if ($u.Actions[0].Execute -eq 'powershell.exe' -and $u.Actions[0].Arguments -match '^-WindowStyle Hidden .*-File ".*\\bin\\update_ai_clis\.ps1"' -and $s.launcher -eq 'powershell') { Pass 'install falls back to PowerShell when wscript cannot run' } else { Fail "fallback: $($u.Actions[0].Execute) $($u.Actions[0].Arguments) / $($r.Output)" }
  $r = Invoke-Aicm $installArgs
  $u = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  if ($u.Actions[0].Execute -eq 'wscript.exe' -and $u.Actions[0].Arguments -like '//B //Nologo *') { Pass 'install goes back to wscript (batch mode) when it works' } else { Fail "wscript again: $($u.Actions[0].Arguments)" }

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
    $r = Invoke-Aicm @('processes')
    if ($r.Output -match 'left-behind agent processes') { Pass 'aicm processes runs the node module' } else { Fail "aicm processes: $($r.Output)" }
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
  New-Item -ItemType Directory -Path $aicmHome -Force | Out-Null

  $r = Invoke-Aicm @('status')
  if ($r.Output -match '== disk use by cleanup rule ==' -and $r.Output -match 'codex-sessions') { Pass 'status shows rules' } else { Fail "status output: $($r.Output)" }

  # The legacy installer removes a real '\AI CLI Auto Update' task, so only run it where none exists.
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
    if ($u -and $i -and $c -and ([datetime]$u.Triggers[0].StartBoundary).ToString('HH:mm') -eq '04:45' -and $i.Triggers[0].DaysOfWeek -eq 8 -and ([datetime]$i.Triggers[0].StartBoundary).ToString('HH:mm') -eq '11:40' -and @($s.jobs).Count -eq 3 -and $s.options.inventoryDay -eq 'Wednesday' -and $s.options.updateAt -eq '04:45') {
      Pass 'legacy installer keeps Inventory and Clean as they were'
    } else { Fail "legacy installer with all jobs: $($r.Output)" }
  }
} finally {
  Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
  try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $svc.GetFolder('\').DeleteFolder($folderName, 0)
  } catch { }
  Remove-Item -LiteralPath $wshKey -Recurse -Force -ErrorAction SilentlyContinue
  Remove-TestWorkspace $work
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
