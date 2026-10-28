<# This starts the real scheduled tasks. Review their effects and obtain approval before use.
   Console-window sampling sees the caller's desktop only and can miss windows between samples. #>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutputDir,
  [switch]$RunTasks,
  [switch]$SkipUpdate,
  [switch]$IncludeExternalPaseo,
  [ValidateRange(30, 14400)][int]$TimeoutSeconds = 1800
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\aicm-scheduler.ps1')
if (-not $RunTasks) { throw 'Pass -RunTasks only after approving execution of the real update and cleanup tasks.' }
if (-not $SkipUpdate) {
  $managerHome = if ($env:AICM_HOME) { $env:AICM_HOME } else { Join-Path $env:USERPROFILE '.ai-cli-auto-manager' }
  if (Get-Item -LiteralPath (Join-Path $managerHome 'hooks\post-update.ps1') -Force -ErrorAction SilentlyContinue) {
    throw 'Update has a user post-update hook. Review its effects separately before attempting a live Update; use -SkipUpdate to observe the other tasks.'
  }
}
$observingSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
$interactiveDesktop = [Environment]::UserInteractive -and
  @((Get-Process -Name explorer -ErrorAction SilentlyContinue) | Where-Object { $_.SessionId -eq $observingSession }).Count -gt 0
if (-not $interactiveDesktop) { throw 'Run the observer in the interactive desktop session with Explorer; no task was started.' }
if (Test-Path -LiteralPath $OutputDir) { throw 'Choose a new output directory.' }
New-Item -ItemType Directory -Path $OutputDir -ErrorAction Stop | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot 'window-observer.cs')
$targets = @(
  @{ Path = '\AI CLI Auto Manager\'; Name = 'Clean' },
  @{ Path = '\AI CLI Auto Manager\'; Name = 'Inventory' }
)
if (-not $SkipUpdate) { $targets += @{ Path = '\AI CLI Auto Manager\'; Name = 'Update' } }
if ($IncludeExternalPaseo) { $targets += @{ Path = '\'; Name = 'Paseo-Session-Cleanup' } }
$summaries = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
  $task = Get-ScheduledTask -TaskPath $target.Path -TaskName $target.Name -ErrorAction Stop
  if ($task.State -in @('Running', 'Queued')) { throw "$($target.Name) is running or queued; wait before testing" }
  if (@($task.Actions).Count -ne 1) { throw "$($target.Name) does not have one action" }
  $action = @($task.Actions)[0]
  if ($target.Name -eq 'Paseo-Session-Cleanup') {
    $arguments = [string]$action.Arguments
    if ($arguments -notmatch '(?i)(?:^|\s)--dry-run(?:\s|$)' -or
        $arguments -notmatch '(?i)(?:^|\s)--min-age-hours\s+168(?:\s|$)' -or
        $arguments -notmatch '(?i)cleanup_paseo_sessions\.ps1') { throw 'Paseo cleanup does not have the required dry-run arguments' }
  }
  $exeName = [IO.Path]::GetFileName([string]$action.Execute)
  $beforeProcesses = @([AicmWindowObserver.Snapshot]::Processes())
  $beforeIds = @($beforeProcesses | Where-Object { $_.Name -ieq $exeName } | ForEach-Object { $_.Pid })
  $seenWindows = @{}
  foreach ($window in @([AicmWindowObserver.Snapshot]::Windows($beforeProcesses))) {
    $seenWindows["$($window.Handle):$($window.OwnerPid):$($window.ClassName)"] = $true
  }
  $beforeTime = (Get-ScheduledTaskInfo -TaskPath $target.Path -TaskName $target.Name).LastRunTime
  $logFile = Join-Path $OutputDir ($target.Name + '-windows.jsonl')
  $writer = New-Object IO.StreamWriter($logFile, $false, (New-Object Text.UTF8Encoding($false)))
  $roots = New-Object 'System.Collections.Generic.HashSet[uint32]'
  $maxInterval = 0L; $lastSample = -1L; $related = 0; $unattributed = 0
  $sessionConfirmed = $true; $finished = $false; $lastResult = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $nextSample = 0L; $nextTaskCheck = 0L
  try {
    Start-ScheduledTask -TaskPath $target.Path -TaskName $target.Name
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
      $now = $clock.ElapsedMilliseconds
      if ($lastSample -ge 0) { $maxInterval = [Math]::Max($maxInterval, $now - $lastSample) }
      $lastSample = $now
      $processes = @([AicmWindowObserver.Snapshot]::Processes())
      foreach ($process in $processes) {
        if ($process.Name -ieq $exeName -and $beforeIds -notcontains $process.Pid) {
          [void]$roots.Add($process.Pid)
          try { if ((Get-Process -Id $process.Pid -ErrorAction Stop).SessionId -ne $observingSession) { $sessionConfirmed = $false } }
          catch { $sessionConfirmed = $false }
        }
      }
      $currentWindows = @{}
      foreach ($window in @([AicmWindowObserver.Snapshot]::Windows($processes))) {
        $key = "$($window.Handle):$($window.OwnerPid):$($window.ClassName)"
        $currentWindows[$key] = $true
        if ($seenWindows.ContainsKey($key)) { continue }
        $isRelated = @($window.ParentChain | Where-Object { $roots.Contains([uint32]$_.Pid) }).Count -gt 0
        if ($isRelated) { $related++ } else { $unattributed++ }
        $entry = [ordered]@{
          elapsedMs = $now; class = $window.ClassName; ownerPid = $window.OwnerPid
          sessionId = $window.SessionId; relatedToObservedTaskRoot = $isRelated
          parentChain = @($window.ParentChain | ForEach-Object { @{ pid = $_.Pid; parent = $_.Parent; name = $_.Name } })
        }
        $writer.WriteLine(($entry | ConvertTo-Json -Depth 5 -Compress)); $writer.Flush()
      }
      $seenWindows = $currentWindows
      if ($now -ge $nextTaskCheck) {
        $nextTaskCheck = $now + 500
        $task = Get-ScheduledTask -TaskPath $target.Path -TaskName $target.Name -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskPath $target.Path -TaskName $target.Name -ErrorAction Stop
        if ($info.LastRunTime -gt $beforeTime -and $task.State -notin @('Running', 'Queued')) {
          $finished = $true; $lastResult = $info.LastTaskResult; break
        }
      }
      $nextSample += 100
      $delay = $nextSample - $clock.ElapsedMilliseconds
      if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    }
  } finally { $writer.Dispose(); $clock.Stop() }
  $status = if (-not $finished -or $roots.Count -eq 0 -or -not $sessionConfirmed -or $maxInterval -gt 150 -or $unattributed -gt 0) { 'inconclusive' }
            elseif ($related -gt 0 -or $lastResult -ne 0) { 'failed' } else { 'passed-sampled' }
  $summaries.Add([pscustomobject]@{
    task = $target.Name; finished = $finished; lastResult = $lastResult; observedRoots = @($roots)
    sameSession = $sessionConfirmed; maxIntervalMs = $maxInterval
    relatedNewWindows = $related; unattributedNewWindows = $unattributed; status = $status
  })
}
$vbsTasks = @(Get-ScheduledTask | Where-Object {
  @($_.Actions | Where-Object { Test-AicmWindowsScriptAction $_ }).Count -gt 0
} | ForEach-Object { @{ path = $_.TaskPath; name = $_.TaskName } })
$report = @{ samplingIntervalMs = 100; desktopSession = $observingSession; tasks = @($summaries.ToArray()); remainingVbsTasks = $vbsTasks }
[IO.File]::WriteAllText((Join-Path $OutputDir 'summary.json'), (($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
$report | ConvertTo-Json -Depth 6
if (@($summaries | Where-Object { $_.status -ne 'passed-sampled' }).Count -gt 0 -or $vbsTasks.Count -gt 0) { exit 1 }
