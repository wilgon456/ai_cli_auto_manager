# Native Windows launcher and Task Scheduler exit-code tests; only throwaway paths/tasks are used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$taskPath = '\AICM Launcher Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\'
$script:fails = 0
. (Join-Path $PSScriptRoot 'test-env.ps1')
. (Join-Path $root 'lib\aicm-common.ps1')
. (Join-Path $root 'lib\aicm-scheduler.ps1')
function Pass([string]$Message) { Write-Host "ok   - $Message" }
function Fail([string]$Message) { Write-Host "FAIL - $Message"; $script:fails++ }

$saved = @{}
foreach ($key in 'USERPROFILE', 'HOME', 'AICM_HOME', 'LOCALAPPDATA', 'WINDIR') { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
  $local = Join-Path $fakeHome 'AppData\Local'
  New-Item -ItemType Directory -Path $local -Force | Out-Null
  $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome; $env:LOCALAPPDATA = $local
  $env:AICM_HOME = Join-Path $fakeHome '.ai-cli-auto-manager'
  $exe = Initialize-AicmWindowlessLauncher $root
  if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Initialize-AicmWindowlessLauncher $root) -eq $exe) { Pass 'compiled GUI launcher is reused after hash verification' } else { Fail 'launcher compilation or verification' }

  $fixture = Join-Path $work 'test script.ps1'
  @'
param([string]$Output, [string]$Text, [int]$Result)
[IO.File]::WriteAllText($Output, $Text, (New-Object Text.UTF8Encoding($false)))
exit $Result
'@ | Set-Content -LiteralPath $fixture -Encoding ASCII
  $nodeTest = Join-Path $work 'launch-test.js'
  @'
const fs = require('fs');
const cp = require('child_process');
const [exe, script, dest] = process.argv.slice(2);
const text = 'Korean \uD55C\uAE00, spaces, "quotes", and a trailing slash \\';
const result = cp.spawnSync(exe, [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
  '-Output', dest, '-Text', text, '-Result', '37'
], { windowsHide: true, timeout: 30000 });
if (result.error || result.status !== 37) process.exit(1);
if (fs.readFileSync(dest, 'utf8') !== text) process.exit(2);
'@ | Set-Content -LiteralPath $nodeTest -Encoding ASCII
  $node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
  & $node $nodeTest $exe $fixture (Join-Path $work 'output.txt')
  if ($LASTEXITCODE -eq 0) { Pass 'arguments and nonzero exit code survive the launcher' } else { Fail "argument/exit fixture: $LASTEXITCODE" }

  $failure = Join-Path $work 'exit-37.ps1'
  'exit 37' | Set-Content -LiteralPath $failure -Encoding ASCII
  $argsText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $failure
  $action = New-ScheduledTaskAction -Execute $exe -Argument $argsText
  $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours(1))
  Register-ScheduledTask -TaskPath $taskPath -TaskName 'Exit 37' -Action $action -Trigger $trigger -Force | Out-Null
  $before = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Exit 37').LastRunTime
  Start-ScheduledTask -TaskPath $taskPath -TaskName 'Exit 37'
  $deadline = (Get-Date).AddSeconds(90)
  do {
    Start-Sleep -Milliseconds 250
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Exit 37'
    $info = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Exit 37'
  } while ((Get-Date) -lt $deadline -and ($info.LastRunTime -le $before -or $task.State -eq 'Running'))
  if ($info.LastRunTime -gt $before -and $info.LastTaskResult -eq 37) { Pass 'Task Scheduler records the script failure code' } else { Fail "Task Scheduler result: $($info.LastTaskResult), state $($task.State)" }

  $env:AICM_HOME = Join-Path $fakeHome 'another-manager'
  $env:WINDIR = Join-Path $work 'no-compiler'
  $refused = $false
  try { [void](Initialize-AicmWindowlessLauncher $root) } catch { $refused = $_.Exception.Message -match 'csc.exe is unavailable' }
  if ($refused) { Pass 'missing compiler fails closed' } else { Fail 'missing compiler was not refused' }
} finally {
  $task = Get-ScheduledTask -TaskPath $taskPath -TaskName 'Exit 37' -ErrorAction SilentlyContinue
  if ($task) { Unregister-ScheduledTask -TaskPath $taskPath -TaskName 'Exit 37' -Confirm:$false }
  foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
  if (Test-Path -LiteralPath $work) { Remove-TestWorkspace $work }
}
if ($script:fails -gt 0) { Write-Host "$script:fails check(s) failed"; exit 1 }
Write-Host 'all checks passed'
