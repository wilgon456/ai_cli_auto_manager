# Windows scheduling helpers. Dot-source after aicm-common.ps1; definition only.
# Launcher binaries and backups live outside app, so a running launcher is not replaced by app sync.
# Keep ASCII-only for Windows PowerShell 5.1.

function Get-AicmSha256Text([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-AicmWindowlessArea {
  $local = Get-AicmLocalAppData
  if (-not [IO.Path]::IsPathRooted($local)) { throw 'LOCALAPPDATA must be an absolute directory' }
  $localItem = Get-Item -LiteralPath $local -Force -ErrorAction Stop
  if (-not (Test-AicmRealDir $localItem)) { throw 'LOCALAPPDATA is not a real directory' }
  $parent = Join-Path $local 'AI CLI Auto Manager'
  if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
  if (-not (Test-AicmRealDir (Get-Item -LiteralPath $parent -Force))) { throw 'launcher parent is not a real directory' }
  $id = Get-AicmSha256Text ([IO.Path]::GetFullPath((Get-AicmHome)).TrimEnd('\', '/').ToLowerInvariant())
  # Task Scheduler's executable-path limit is short, so filenames use 96-bit prefixes.
  # The marker and records below still verify the complete SHA-256 values.
  $area = Join-Path $parent ("w-" + $id.Substring(0, 24))
  if (-not (Test-Path -LiteralPath $area)) { [void][IO.Directory]::CreateDirectory($area) }
  if (-not (Test-AicmRealDir (Get-Item -LiteralPath $area -Force))) { throw 'launcher area is not a real directory' }
  $marker = Join-Path $area '.aicm-windowless'
  $expected = "AI CLI Auto Manager windowless 1 $id"
  if (Test-Path -LiteralPath $marker) {
    if (-not (Test-AicmRealFile (Get-Item -LiteralPath $marker -Force)) -or (Read-AicmUtf8Text $marker).Trim() -cne $expected) { throw 'launcher area has an invalid ownership marker' }
  } else {
    if (@(Get-ChildItem -LiteralPath $area -Force).Count -ne 0) { throw 'launcher area is not empty and has no ownership marker' }
    $file = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes($expected + [Environment]::NewLine); $file.Write($bytes, 0, $bytes.Length) }
    finally { $file.Dispose() }
  }
  return $area
}

function Initialize-AicmWindowlessLauncher([string]$SourceRoot) {
  $source = Join-Path $SourceRoot 'windows\aicm-windowless.cs'
  if (-not (Test-AicmRealFile (Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue))) { throw 'windowless launcher source is missing or linked' }
  $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
  $area = Get-AicmWindowlessArea
  $stem = 'aicm-run-' + $sourceHash.Substring(0, 24)
  $exe = Join-Path $area "$stem.exe"
  $record = Join-Path $area "$stem.json"
  if ($exe.Length -gt 259) { throw 'windowless launcher path exceeds the Windows scheduled-task limit' }
  $exeItem = Get-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
  $recordItem = Get-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
  if ($exeItem -or $recordItem) {
    if (-not (Test-AicmRealFile $exeItem) -or -not (Test-AicmRealFile $recordItem)) { throw 'windowless launcher is incomplete; refusing to replace it' }
    $saved = $null
    try { $saved = (Read-AicmUtf8Text $record) | ConvertFrom-Json } catch { }
    if (-not $saved -or $saved.sourceHash -cne $sourceHash -or $saved.exeHash -cne (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'windowless launcher integrity check failed' }
    return $exe
  }
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
  if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '.NET Framework csc.exe is unavailable; refusing to create visible scheduled tasks' }
  $temp = Join-Path $area ("compile-" + [guid]::NewGuid().ToString('N') + '.exe')
  try {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $compiler
    $start.Arguments = Join-AicmProcessArguments @('/nologo', '/target:winexe', '/platform:anycpu', "/out:$temp", $source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($start)
    if (-not $proc) { throw 'could not start compiler' }
    try {
      $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
      $stderrTask = $proc.StandardError.ReadToEndAsync()
      if (-not $proc.WaitForExit(60000)) { $proc.Kill(); $proc.WaitForExit(); throw 'launcher compilation timed out' }
      $out = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
      if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $temp -PathType Leaf)) { throw "launcher compilation failed: $out" }
    } finally { $proc.Dispose() }
    $exeHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::Move($temp, $exe) # never replace an existing file
    $json = (@{ sourceHash = $sourceHash; exeHash = $exeHash } | ConvertTo-Json -Compress)
    $file = [IO.File]::Open($record, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes($json); $file.Write($bytes, 0, $bytes.Length) }
    finally { $file.Dispose() }
    return $exe
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
}

function New-AicmScheduleBackup([string[]]$Names, [string]$TaskPath) {
  if ($Names.Count -eq 0) { return '' }
  $app = Get-AicmAppDir
  $appItem = Get-Item -LiteralPath $app -Force -ErrorAction SilentlyContinue
  if (-not $appItem) { throw 'managed tasks exist but their installed copy is missing; refusing to change them' }
  if (-not (Test-AicmAppCopyOwned $app)) { throw "cannot back up the installed copy: $($script:AicmHomeProblem)" }
  foreach ($entry in (Get-AicmEntries $app)) {
    if (Test-AicmLink $entry) { throw 'cannot back up an installed copy with a linked entry' }
  }
  $area = Get-AicmWindowlessArea
  $base = Join-Path $area 'backups'
  if (-not (Test-Path -LiteralPath $base)) { [void][IO.Directory]::CreateDirectory($base) }
  if (-not (Test-AicmRealDir (Get-Item -LiteralPath $base -Force))) { throw 'backup folder is not a real directory' }
  $backup = Join-Path $base ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
  $xmlHashes = @{}
  $appHashes = @{}
  foreach ($name in $Names) {
    if (@('Update', 'Inventory', 'Clean', 'Maintenance') -notcontains $name) { throw 'unrecognized managed task name' }
    $xml = [string](Export-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction Stop)
    [xml]$parsed = $xml
    if (@($parsed.Task.Actions.Exec).Count -ne 1) { throw "task $name does not have one restorable executable action" }
    Write-AicmUtf8Text (Join-Path $backup "$name.xml") $xml
    if ((Read-AicmUtf8Text (Join-Path $backup "$name.xml")) -cne $xml) { throw "could not verify backup for $name" }
    $xmlHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $backup "$name.xml") -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  if ($appItem) {
    $appBackup = Join-Path $backup 'app'
    Copy-Item -LiteralPath $app -Destination $appBackup -Recurse -ErrorAction Stop
    $sourceFiles = @(Get-ChildItem -LiteralPath $app -Recurse -File -Force)
    $backupFiles = @(Get-ChildItem -LiteralPath $appBackup -Recurse -File -Force)
    if ($sourceFiles.Count -ne $backupFiles.Count) { throw 'installed-copy backup is incomplete' }
    foreach ($f in $sourceFiles) {
      $relative = $f.FullName.Substring($app.TrimEnd('\', '/').Length + 1)
      $copied = Get-Item -LiteralPath (Join-Path $appBackup $relative) -Force -ErrorAction Stop
      if (-not (Test-AicmRealFile $copied) -or
          (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $copied.FullName -Algorithm SHA256).Hash) {
        throw "installed-copy backup verification failed for $relative"
      }
      $appHashes[$relative] = (Get-FileHash -LiteralPath $copied.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  $stateDir = Join-Path (Get-AicmHome) 'state'
  $stateItem = Get-Item -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue
  if ($stateItem -and -not (Test-AicmRealDir $stateItem)) { throw 'schedule state folder is linked or invalid' }
  $schedule = Join-Path $stateDir 'schedule.json'
  $schedItem = Get-Item -LiteralPath $schedule -Force -ErrorAction SilentlyContinue
  if ($schedItem) {
    if (-not (Test-AicmRealFile $schedItem)) { throw 'schedule state is not a real file' }
    Copy-Item -LiteralPath $schedule -Destination (Join-Path $backup 'schedule.json') -ErrorAction Stop
  }
  $meta = @{ format = 1; taskPath = $TaskPath; names = @($Names); aicmHome = (Get-AicmHome); hasApp = [bool]$appItem; xmlHashes = $xmlHashes; appHashes = $appHashes }
  Write-AicmUtf8Text (Join-Path $backup 'backup.json') (($meta | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
  return $backup
}

function Get-AicmOldTaskArguments($Task, [string]$ExpectedScript, [string]$App) {
  if (@($Task.Actions).Count -ne 1) { throw "task $($Task.TaskName) has multiple actions; refusing to change it" }
  $action = @($Task.Actions)[0]
  $execute = [string]$action.Execute
  $argsText = [string]$action.Arguments
  if ($execute -match '(?i)(?:^|[\\/])wscript(?:\.exe)?$') {
    $pattern = '(?i)^\s*(?:(?://B|//Nologo)\s+)*"(?<vbs>[^"]+)"\s+(?:"?(?:[^"]*[\\/])?powershell(?:\.exe)?"?)\s+(?<ps>.+)$'
    if ($argsText -notmatch $pattern) { throw "task $($Task.TaskName) has an unrecognized legacy launcher" }
    $vbs = $Matches.vbs; $argsText = $Matches.ps
    if (-not (Test-AicmSamePath $vbs (Join-Path $App 'windows\run-hidden.vbs'))) { throw "task $($Task.TaskName) points to a different legacy script" }
  } elseif ($execute -notmatch '(?i)(?:^|[\\/])powershell(?:\.exe)?$') {
    # An earlier source version has its own immutable launcher in this installation's area.
    $area = Get-AicmWindowlessArea
    if (-not [IO.Path]::IsPathRooted($execute) -or
        -not (Test-AicmSamePath (Split-Path -Parent $execute) $area) -or
        (Split-Path -Leaf $execute) -notmatch '^aicm-run-[0-9a-f]{24}\.exe$') {
      throw "task $($Task.TaskName) has an unrecognized action; refusing to replace it"
    }
    $binary = Get-Item -LiteralPath $execute -Force -ErrorAction SilentlyContinue
    $record = [IO.Path]::ChangeExtension($execute, '.json')
    $recordItem = Get-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
    if (-not (Test-AicmRealFile $binary) -or -not (Test-AicmRealFile $recordItem)) { throw 'previous launcher is missing or linked' }
    $saved = (Read-AicmUtf8Text $record) | ConvertFrom-Json
    if ($saved.exeHash -cne (Get-FileHash -LiteralPath $execute -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'previous launcher integrity check failed' }
  }
  $script = [regex]::Escape((Join-Path $App "bin\$ExpectedScript"))
  if ($argsText -notmatch ('(?i)(?:^|\s)-File\s+(?:"' + $script + '"|' + $script + ')(?:\s|$)')) { throw "task $($Task.TaskName) does not run its expected installed script" }
  return $argsText
}

function Restore-AicmTaskActions([string]$Backup) {
  $meta = (Read-AicmUtf8Text (Join-Path $Backup 'backup.json')) | ConvertFrom-Json
  foreach ($name in @($meta.names)) {
    if (@('Update', 'Inventory', 'Clean', 'Maintenance') -notcontains [string]$name) { throw 'backup has an unrecognized task name' }
    [xml]$xml = Read-AicmUtf8Text (Join-Path $Backup "$name.xml")
    $items = @($xml.Task.Actions.Exec)
    if ($items.Count -ne 1) { throw "backup for $name does not have one executable action" }
    $old = $items[0]
    $commandNode = $old.SelectSingleNode("*[local-name()='Command']")
    $argumentNode = $old.SelectSingleNode("*[local-name()='Arguments']")
    $directoryNode = $old.SelectSingleNode("*[local-name()='WorkingDirectory']")
    if (-not $commandNode -or -not $commandNode.InnerText) { throw "backup for $name has no executable" }
    $actionArgs = @{ Execute = [string]$commandNode.InnerText }
    if ($argumentNode -and $argumentNode.InnerText) { $actionArgs.Argument = [string]$argumentNode.InnerText }
    if ($directoryNode -and $directoryNode.InnerText) { $actionArgs.WorkingDirectory = [string]$directoryNode.InnerText }
    $action = New-ScheduledTaskAction @actionArgs
    Set-ScheduledTask -TaskPath ([string]$meta.taskPath) -TaskName $name -Action $action -ErrorAction Stop | Out-Null
  }
}

function Get-AicmTaskPreservedHash([string]$TaskPath, [string]$Name) {
  [xml]$xml = [string](Export-ScheduledTask -TaskPath $TaskPath -TaskName $Name -ErrorAction Stop)
  return (Get-AicmSha256Text ($xml.Task.Triggers.OuterXml + $xml.Task.Principals.OuterXml + $xml.Task.Settings.OuterXml))
}

function Test-AicmUpdaterParent {
  # Auto-refresh can be invoked by the scheduled Update itself. A manual refresh must wait for it.
  try {
    $self = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($self.ParentProcessId)" -ErrorAction Stop
    $expected = Join-Path (Get-AicmAppDir) 'bin\update_ai_clis.ps1'
    return ($parent.Name -match '(?i)^(powershell|pwsh)\.exe$' -and
      ([string]$parent.CommandLine).IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -ge 0)
  } catch { return $false }
}

function Assert-AicmManagedTasksIdle([string[]]$Names, [string]$TaskPath, [bool]$Refresh) {
  foreach ($name in $Names) {
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction Stop
    if ($task.State -notin @('Running', 'Queued')) { continue }
    if ($Refresh -and $name -eq 'Update' -and (Test-AicmUpdaterParent)) { continue }
    throw "scheduled task $name is running or queued; retry when it is idle"
  }
}

function Convert-AicmLegacyTasks([string[]]$Names, [string]$TaskPath, [string]$Launcher, [string]$Backup) {
  $scripts = @{ Update = 'update_ai_clis.ps1'; Inventory = 'inventory_ai_clis.ps1'; Clean = 'clean_ai_leftovers.ps1'; Maintenance = 'aicm.ps1' }
  $pending = @()
  foreach ($name in $Names) {
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction Stop
    $arguments = Get-AicmOldTaskArguments $task $scripts[$name] (Get-AicmAppDir)
    if (@($task.Actions).Count -eq 1 -and [string]$task.Actions[0].Execute -ceq $Launcher) { continue }
    $old = @($task.Actions)[0]
    $params = @{ Execute = $Launcher; Argument = $arguments }
    if ($old.WorkingDirectory) { $params.WorkingDirectory = [string]$old.WorkingDirectory }
    $pending += @{ name = $name; action = (New-ScheduledTaskAction @params); args = $arguments
      workingDirectory = [string]$old.WorkingDirectory; preserved = (Get-AicmTaskPreservedHash $TaskPath $name) }
  }
  try {
    foreach ($item in $pending) {
      Set-ScheduledTask -TaskPath $TaskPath -TaskName $item.name -Action $item.action -ErrorAction Stop | Out-Null
      $after = Get-ScheduledTask -TaskPath $TaskPath -TaskName $item.name -ErrorAction Stop
      if (@($after.Actions).Count -ne 1 -or [string]$after.Actions[0].Execute -cne $Launcher -or
          [string]$after.Actions[0].Arguments -cne $item.args -or [string]$after.Actions[0].WorkingDirectory -cne $item.workingDirectory) {
        throw "task $($item.name) action did not retain its arguments or working directory; review backup $Backup"
      }
      if ((Get-AicmTaskPreservedHash $TaskPath $item.name) -cne $item.preserved) {
        throw "task $($item.name) trigger, principal or settings changed; review backup $Backup"
      }
    }
  } catch {
    if ($Backup) { try { Restore-AicmTaskActions $Backup } catch { Write-Warning "Could not restore all task actions; use backup $Backup" } }
    throw
  }
  return @($pending | ForEach-Object { [string]$_.name })
}
