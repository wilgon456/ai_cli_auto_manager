# Native Windows Job Object and exclusive quarantine regressions. Only fixture PIDs/files are used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('aicm-maintenance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$exe = (Get-Process -Id $PID).Path
$managed = $null
$descendant = $null
try {
  Add-Type -Path (Join-Path $root 'lib\aicm-file-guard.cs')
  $source = Join-Path $work 'old.tmp'
  $destination = Join-Path $work 'payload'
  [IO.File]::WriteAllText($source, 'recoverable')
  $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $reader = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
  try {
    if ([Aicm.FileGuard]::TryMove($source, $destination)) { throw 'Moved a locked file' }
    if (-not (Test-Path -LiteralPath $source)) { throw 'Locked source disappeared' }
  } finally { $reader.Dispose() }
  if (-not [Aicm.FileGuard]::TryMove($source, $destination)) { throw 'Could not quarantine idle file' }
  if ([IO.File]::ReadAllText($destination) -ne 'recoverable') { throw 'Quarantine changed payload' }
  if (-not [Aicm.FileGuard]::TryDelete(@($destination), @($destination))) { throw 'Could not purge idle payload' }
  Write-Host 'ok - locked readers are kept; idle payloads move and purge'

  # Per-command boundaries close before the manager exits. Independent daemon hooks stay alive.
  . (Join-Path $root 'lib\aicm-common.ps1')
  $savedHome = $env:AICM_HOME
  $hookDaemon = $null
  try {
    $env:AICM_HOME = Join-Path $work 'per-command-manager'
    $hookDaemon = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -PassThru -WindowStyle Hidden
    $command = Join-Path $work 'tool with spaces.cmd'
    @('@echo off', 'echo %~1', 'exit /b 7') | Set-Content -LiteralPath $command -Encoding ASCII
    for ($i = 0; $i -lt 5; $i++) {
      $r = Invoke-AicmWithTimeout $command @('argument with spaces') 10
      if ($r.ExitCode -ne 7 -or $r.StdOut.Trim() -ne 'argument with spaces') { throw "Native command argument/exit-code mismatch: $($r | ConvertTo-Json -Compress)" }
    }
    $command = Join-Path $work 'spawn-grandchild.ps1'
    $recordFile = Join-Path $work 'grandchild.json'
    $content = @"
`$p = Start-Process -FilePath '$($exe.Replace("'", "''"))' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -PassThru
@{ pid = `$p.Id; tag = `$env:AI_CLI_MANAGER_SESSION } | ConvertTo-Json | Set-Content -LiteralPath '$($recordFile.Replace("'", "''"))'
"@
    Set-Content -LiteralPath $command -Value $content -Encoding UTF8
    $r = Invoke-AicmWithTimeout $exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $command) 20
    if ($r.ExitCode -ne 0) { throw "Per-command fixture failed: $($r.Output)" }
    $record = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json
    if ($record.tag -notmatch '^[a-f0-9-]{36}$') { throw 'Per-command child has no session tag' }
    $left = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if ($left -and -not $left.WaitForExit(5000)) { $left.Kill(); throw 'Grandchild survived immediate CLI exit' }
    if ($hookDaemon.HasExited) { throw 'Independent post-update daemon was killed' }
    Write-Host 'ok - per-command Job cleans grandchildren and preserves independent daemon hooks'
  } finally {
    $env:AICM_HOME = $savedHome
    if ($hookDaemon) { try { if (-not $hookDaemon.HasExited) { $hookDaemon.Kill() } } catch { } }
  }

  $lib = (Join-Path $root 'lib\aicm-common.ps1').Replace("'", "''")
  $out = (Join-Path $work 'child.json').Replace("'", "''")
  $fixture = Join-Path $work 'managed.ps1'
  $spawnScript = Join-Path $work 'long-command.ps1'
  $spawnProgram = @"
`$p = Start-Process -FilePath '$($exe.Replace("'", "''"))' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -PassThru
@{ pid = `$p.Id; created = `$p.StartTime.ToUniversalTime().ToString('o'); tag = `$env:AI_CLI_MANAGER_SESSION } | ConvertTo-Json | Set-Content -LiteralPath '$out'
Start-Sleep -Seconds 300
"@
  Set-Content -LiteralPath $spawnScript -Value $spawnProgram -Encoding UTF8
  $program = @"
. '$lib'
`$null = Invoke-AicmWithTimeout '$($exe.Replace("'", "''"))' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '$($spawnScript.Replace("'", "''"))') 300
"@
  Set-Content -LiteralPath $fixture -Value $program -Encoding UTF8
  $savedHome = $env:AICM_HOME
  $savedTag = $env:AI_CLI_MANAGER_SESSION
  try {
    $env:AICM_HOME = Join-Path $work 'manager'
    $env:AI_CLI_MANAGER_SESSION = ''
    $managed = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$fixture`"") -PassThru -WindowStyle Hidden
  } finally { $env:AICM_HOME = $savedHome; $env:AI_CLI_MANAGER_SESSION = $savedTag }
  $deadline = (Get-Date).AddSeconds(30)
  while (-not (Test-Path -LiteralPath (Join-Path $work 'child.json'))) {
    if ((Get-Date) -gt $deadline -or $managed.HasExited) { throw 'Managed fixture failed to start' }
    Start-Sleep -Milliseconds 100
  }
  $record = Get-Content -LiteralPath (Join-Path $work 'child.json') -Raw | ConvertFrom-Json
  if ($record.tag -notmatch '^[a-f0-9-]{36}$') { throw 'Missing session environment marker' }
  $descendant = Get-Process -Id $record.pid
  Stop-Process -Id $managed.Id -Force
  if (-not $descendant.WaitForExit(10000)) { throw 'Job descendant survived manager death' }
  Write-Host 'ok - manager crash closes Job handle and kills tagged descendants'
} finally {
  foreach ($p in @($managed, $descendant)) { if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } } }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
