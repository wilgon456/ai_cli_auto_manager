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

  $lib = (Join-Path $root 'lib\aicm-common.ps1').Replace("'", "''")
  $out = (Join-Path $work 'child.json').Replace("'", "''")
  $fixture = Join-Path $work 'managed.ps1'
  $program = @"
. '$lib'
Initialize-AicmProcessContainment
`$p = Start-Process -FilePath '$($exe.Replace("'", "''"))' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -PassThru
@{ pid = `$p.Id; created = `$p.StartTime.ToUniversalTime().ToString('o'); tag = `$env:AI_CLI_MANAGER_SESSION } | ConvertTo-Json | Set-Content -LiteralPath '$out'
Start-Sleep -Seconds 300
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
