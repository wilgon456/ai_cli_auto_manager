# Native Windows launcher and Task Scheduler exit-code tests; only throwaway paths/tasks are used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work ('home ' + [string][char]0xD55C + [string][char]0xAE00)
$taskPath = '\AICM Launcher Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\'
$script:fails = 0
. (Join-Path $PSScriptRoot 'test-env.ps1')
. (Join-Path $root 'lib\aicm-common.ps1')
. (Join-Path $root 'lib\aicm-scheduler.ps1')
function Pass([string]$Message) { Write-Host "ok   - $Message" }
function Fail([string]$Message) { Write-Host "FAIL - $Message"; $script:fails++ }

$auditCases = @(
  @{ action = [pscustomobject]@{ ClassId = '{test-com-handler}' }; expected = $false },
  @{ action = [pscustomobject]@{ Execute = 'powershell.exe' }; expected = $false },
  @{ action = [pscustomobject]@{ Execute = 'C:\Windows\System32\wscript.exe' }; expected = $true },
  @{ action = [pscustomobject]@{ Execute = 'cmd.exe'; Arguments = '/c cscript.exe test.vbs' }; expected = $true },
  @{ action = [pscustomobject]@{ Arguments = '"C:\example\run.vbs";other' }; expected = $true }
)
$auditPassed = $true
foreach ($case in $auditCases) {
  if ((Test-AicmWindowsScriptAction $case.action) -ne $case.expected) { $auditPassed = $false }
}
try {
  foreach ($task in @(Get-ScheduledTask)) {
    foreach ($action in @($task.Actions)) { [void](Test-AicmWindowsScriptAction $action) }
  }
} catch { $auditPassed = $false }
if ($auditPassed) { Pass 'system task audit handles COM actions and detects Windows Script Host actions' } else { Fail 'system task audit' }

$saved = @{}
foreach ($key in 'USERPROFILE', 'HOME', 'AICM_HOME', 'LOCALAPPDATA', 'WINDIR', 'AICM_TASK_PATH') { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
  $local = Join-Path $fakeHome 'AppData\Local'
  New-Item -ItemType Directory -Path $local -Force | Out-Null
  $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome; $env:LOCALAPPDATA = $local
  $env:AICM_HOME = Join-Path $fakeHome '.ai-cli-auto-manager'
  $exe = Initialize-AicmWindowlessLauncher $root
  if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Initialize-AicmWindowlessLauncher $root) -eq $exe) { Pass 'compiled GUI launcher is reused after hash verification' } else { Fail 'launcher compilation or verification' }
  $launcherHash = Get-AicmFileSha256 $exe
  $visible = $false
  try { Assert-AicmLauncherVisible -Launcher $exe -ExpectedHash $launcherHash -Names @() -TaskPath $taskPath; $visible = $true } catch { }
  if ($visible) { Pass 'Task Scheduler can run and hash the launcher in its own context' } else { Fail 'scheduler launcher visibility check' }
  $wrongHashRefused = $false
  try { Assert-AicmLauncherVisible -Launcher $exe -ExpectedHash ('0' * 64) -Names @() -TaskPath $taskPath } catch { $wrongHashRefused = $_.Exception.Message -match 'cannot run and verify the launcher' }
  if ($wrongHashRefused) { Pass 'scheduler visibility check rejects a different launcher hash' } else { Fail 'scheduler accepted the wrong launcher hash' }

  $fixture = Join-Path $work 'test script.ps1'
  @'
param([string]$Output, [string]$Text, [int]$Result, [string]$Log)
Start-Transcript -Path $Log -Force | Out-Null
Write-Host 'windowless transcript fixture'
[IO.File]::WriteAllText($Output, $Text, (New-Object Text.UTF8Encoding($false)))
Stop-Transcript | Out-Null
exit $Result
'@ | Set-Content -LiteralPath $fixture -Encoding ASCII
  $nodeTest = Join-Path $work 'launch-test.js'
  @'
const fs = require('fs');
const cp = require('child_process');
const [exe, script, dest, log] = process.argv.slice(2);
const text = 'Korean \uD55C\uAE00, spaces, "quotes", and a trailing slash \\';
const result = cp.spawnSync(exe, [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
  '-Output', dest, '-Text', text, '-Result', '37', '-Log', log
], { windowsHide: true, timeout: 30000 });
if (result.error || result.status !== 37) {
  console.error('launcher status:', result.status, 'error:', result.error && result.error.message);
  process.exit(1);
}
if (fs.readFileSync(dest, 'utf8') !== text) {
  console.error('launcher altered fixture arguments');
  process.exit(2);
}
if (!fs.readFileSync(log, 'utf8').includes('windowless transcript fixture')) process.exit(3);
'@ | Set-Content -LiteralPath $nodeTest -Encoding ASCII
  $node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
  & $node $nodeTest $exe $fixture (Join-Path $work 'output.txt') (Join-Path $work 'transcript.log')
  if ($LASTEXITCODE -eq 0) { Pass 'arguments, transcript and nonzero exit code survive the launcher' } else { Fail "argument/log/exit fixture: $LASTEXITCODE" }

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

  Add-Type -Path (Join-Path $root 'windows\window-observer.cs')
  $snapshot = @([AicmWindowObserver.Snapshot]::Processes())
  if (@($snapshot | Where-Object { $_.Pid -eq $PID }).Count -eq 1) { Pass 'window observer captures process ancestry' } else { Fail 'window observer could not find the current process' }
  $sampler = [AicmWindowObserver.Sampler]::new('aicm-no-such-process.exe', [uint32][Diagnostics.Process]::GetCurrentProcess().SessionId)
  $sampler.Start()
  Start-Sleep -Milliseconds 700
  $samples = $sampler.Stop()
  if ($samples.SampleCount -ge 3 -and -not $samples.Error) { Pass 'window sampling continues while the caller is blocked' } else { Fail 'background window sampler did not complete' }

  $hookDir = Join-Path $env:AICM_HOME 'hooks'
  New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
  'exit 0' | Set-Content -LiteralPath (Join-Path $hookDir 'post-update.ps1') -Encoding ASCII
  $observerOutput = Join-Path $work 'observer-must-not-start'
  $ps = (Get-Process -Id $PID).Path
  $preference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & $ps -NoProfile -File (Join-Path $root 'windows\check-scheduled-windows.ps1') -OutputDir $observerOutput -RunTasks 2>&1 | Out-String -Width 400
  $childStatus = $LASTEXITCODE
  $ErrorActionPreference = $preference
  if ($childStatus -ne 0 -and $out -match 'post-update hook' -and -not (Test-Path -LiteralPath $observerOutput)) { Pass 'live observer refuses an update with a user hook before starting tasks' } else { Fail "observer hook guard: $out" }

  # A scheduled Update may refresh its own copy while it is still the running task. The updater
  # below is a harmless fixture; it never calls a vendor CLI and uses only the fake home.
  $env:AICM_TASK_PATH = $taskPath
  $preference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $installOutput = & $ps -NoProfile -File (Join-Path $root 'bin\aicm.ps1') schedule install -NoInventory -NoClean -NoMaintenance -KeepLegacyTask 2>&1 | Out-String -Width 400
  $installStatus = $LASTEXITCODE
  $ErrorActionPreference = $preference
  if ($installStatus -ne 0) { throw "fixture schedule install failed: $installOutput" }
  $fixtureApp = Join-Path $env:AICM_HOME 'app'
  $fixtureUpdate = Join-Path $fixtureApp 'bin\update_ai_clis.ps1'
  $finished = Join-Path $work 'auto-refresh-result.txt'
  $quote = { param([string]$s) return $s.Replace("'", "''") }
  $dummy = @'
$env:USERPROFILE = '{0}'
$env:HOME = '{0}'
$env:LOCALAPPDATA = '{1}'
$env:AICM_HOME = '{2}'
$env:AICM_TASK_PATH = '{3}'
& '{4}' -NoProfile -File '{5}' schedule refresh
[IO.File]::WriteAllText('{6}', [string]$LASTEXITCODE)
exit $LASTEXITCODE
'@ -f (& $quote $fakeHome), (& $quote $local), (& $quote $env:AICM_HOME), (& $quote $taskPath), (& $quote $ps), (& $quote (Join-Path $root 'bin\aicm.ps1')), (& $quote $finished)
  # This generated fixture embeds a Unicode path; Windows PowerShell 5.1 needs its UTF-8 BOM.
  [IO.File]::WriteAllText($fixtureUpdate, $dummy, (New-Object Text.UTF8Encoding($true)))
  Start-ScheduledTask -TaskPath $taskPath -TaskName 'Update'
  $deadline = (Get-Date).AddSeconds(120)
  while (-not (Test-Path -LiteralPath $finished) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
  while ((Get-ScheduledTask -TaskPath $taskPath -TaskName 'Update').State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
  $updateResult = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Update').LastTaskResult
  if ((Test-Path -LiteralPath $finished) -and [IO.File]::ReadAllText($finished) -eq '0' -and $updateResult -eq 0) { Pass 'a scheduled updater can refresh itself without stopping the task' } else { Fail "scheduled updater did not complete its isolated refresh (result $updateResult)" }

  [IO.File]::AppendAllText($exe, 'tampered')
  $tamperRefused = $false
  try { [void](Initialize-AicmWindowlessLauncher $root) } catch { $tamperRefused = $_.Exception.Message -match 'integrity check failed' }
  if ($tamperRefused) { Pass 'a modified launcher is not silently reused' } else { Fail 'modified launcher was accepted' }

  $env:AICM_HOME = Join-Path $fakeHome 'another-manager'
  $env:WINDIR = Join-Path $work 'no-compiler'
  $refused = $false
  try { [void](Initialize-AicmWindowlessLauncher $root) } catch { $refused = $_.Exception.Message -match 'csc.exe is unavailable' }
  if ($refused) { Pass 'missing compiler fails closed' } else { Fail 'missing compiler was not refused' }
} finally {
  foreach ($name in 'Exit 37', 'Update') {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue }
    if ($task) { Unregister-ScheduledTask -TaskPath $taskPath -TaskName $name -Confirm:$false }
  }
  foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
  if (Test-Path -LiteralPath $work) { Remove-TestWorkspace $work }
}
if ($script:fails -gt 0) { Write-Host "$script:fails check(s) failed"; exit 1 }
Write-Host 'all checks passed'
