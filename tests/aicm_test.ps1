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

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }

function Invoke-Script([string]$Script, [string[]]$Arguments) {
  $exe = (Get-Process -Id $PID).Path
  $saved = @{}
  $names = 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'AICM_TASK_PATH'
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = "$work\tmp"; $env:TMP = "$work\tmp"; $env:LOCALAPPDATA = "$fakeHome\AppData\Local"
    $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_WORKTREES = '0'; $env:AICM_TASK_PATH = $taskPath
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments 2>&1 | Out-String
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

  # Someone deletes the cleanup task: doctor and the next update run must notice.
  Unregister-ScheduledTask -TaskPath $taskPath -TaskName 'Clean' -Confirm:$false
  $r = Invoke-Aicm @('doctor')
  if ($r.ExitCode -eq 1 -and $r.Output -match "'Clean' is missing") { Pass 'doctor notices a deleted task' } else { Fail "deleted task: $($r.Output)" }
  $r = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'none')
  if ($r.Output -match "notify: .*'Clean' is missing") { Pass 'update run notifies about the deleted task' } else { Fail "update did not notify: $($r.Output)" }

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
  $null = Invoke-Aicm @('uninstall', '-Purge')
  if (-not (Test-Path -LiteralPath $aicmHome)) { Pass 'uninstall -Purge removes everything' } else { Fail 'purge' }
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
  }
} finally {
  Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
  try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $svc.GetFolder('\').DeleteFolder($folderName, 0)
  } catch { }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
