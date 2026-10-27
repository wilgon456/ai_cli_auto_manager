# Ownership of AICM_HOME (lib\aicm-common.ps1): a populated folder this tool did not create is never
# adopted, an installed copy holding personal files is never replaced or removed, and -Purge (also
# with -DryRun) removes only what the tool wrote. Runs in Windows PowerShell 5.1 and PowerShell 7
# (also on macOS/Linux for the portable parts) against throwaway folders only; it never touches Task
# Scheduler, the real profile or a real AICM_HOME.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$script:fails = 0
function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function P([string[]]$Parts) { $p = $Parts[0]; foreach ($x in $Parts[1..($Parts.Count - 1)]) { $p = Join-Path $p $x }; return $p }
function Put([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text)
}
# Every path and length below a folder, to prove a call changed nothing at all.
function Get-Snapshot([string]$Dir) {
  return ((Get-ChildItem -LiteralPath $Dir -Recurse -Force | Sort-Object FullName | ForEach-Object {
    if ($_ -is [System.IO.FileInfo]) { "$($_.FullName)|$($_.Length)|$([System.IO.File]::ReadAllText($_.FullName))" } else { $_.FullName }
  }) -join "`n")
}

. (P @($root, 'lib', 'aicm-common.ps1'))
$savedHome = $env:AICM_HOME
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
  # An existing project used as AICM_HOME: not adopted, not changed, not purged.
  $proj = P @($work, 'project')
  Put (P @($proj, 'src', 'main.c')) 'int main(void) { return 0; }'
  Put (P @($proj, 'app', 'personal.txt')) 'mine'
  Put (P @($proj, 'app', 'SOURCE')) 'mine'
  Put (P @($proj, 'logs', 'build.log')) 'mine'
  Put (P @($proj, 'archive', 'notes', 'a.txt')) 'mine'
  Put (P @($proj, 'inventory.md')) '# my inventory'
  $env:AICM_HOME = $proj
  $before = Get-Snapshot $proj
  if ((Get-AicmHomeStatus) -eq 'foreign') { Pass 'an existing project is foreign' } else { Fail 'project not foreign' }
  $threw = $false; try { Confirm-AicmHome } catch { $threw = $_.Exception.Message -match 'refusing to use AICM_HOME' }
  if ($threw) { Pass 'claiming a foreign folder is refused' } else { Fail 'foreign folder claimed' }
  $threw = $false; try { Assert-AicmHomeUsable } catch { $threw = $true }
  if ($threw) { Pass 'a preview refuses a foreign folder' } else { Fail 'preview accepted a foreign folder' }
  $threw = $false; try { [void](Sync-AicmAppCopy $root) } catch { $threw = $true }
  if ($threw) { Pass 'no installed copy is synced into a foreign folder' } else { Fail 'sync wrote into a foreign folder' }
  $threw = $false; try { Invoke-AicmPurge $proj -DryRun } catch { $threw = $true }
  $threw2 = $false; try { Invoke-AicmPurge $proj } catch { $threw2 = $true }
  if ($threw -and $threw2) { Pass 'purge and purge -DryRun refuse a foreign folder' } else { Fail 'foreign purge not refused' }
  if (-not (Test-Path -LiteralPath (P @($proj, '.aicm-home'))) -and (Get-Snapshot $proj) -eq $before) { Pass 'the project is left byte for byte, without a marker' } else { Fail 'project changed' }

  # The default name is not ownership, nor is a marker the tool did not write.
  $def = P @($work, 'other', '.ai-cli-auto-manager')
  Put (P @($def, 'notes.txt')) 'mine'
  $env:AICM_HOME = $def
  if ((Get-AicmHomeStatus) -eq 'foreign') { Pass 'an unmarked default-named folder with a foreign file is foreign' } else { Fail 'default name trusted' }
  Put (P @($def, '.aicm-home')) 'something else'
  if ((Get-AicmHomeStatus) -eq 'foreign') { Pass 'a marker with foreign content is not ownership' } else { Fail 'arbitrary marker trusted' }

  # A new home is claimed; a copy holding personal files is never replaced or removed.
  $own = P @($work, 'owned')
  $env:AICM_HOME = $own
  $app = Sync-AicmAppCopy $root
  if ((Test-Path -LiteralPath (P @($own, '.aicm-home'))) -and (Test-Path -LiteralPath (P @($app, 'SOURCE')))) { Pass 'a new home is claimed and gets a copy' } else { Fail 'new home' }
  foreach ($victim in 'app', 'app.old', 'app.new') {
    $file = P @($own, $victim, 'personal.txt')
    Put $file 'my notes'
    $msg = ''; try { [void](Sync-AicmAppCopy $root) } catch { $msg = $_.Exception.Message }
    if ($msg -match 'refusing to replace or remove' -and [System.IO.File]::ReadAllText($file) -eq 'my notes') { Pass "sync never erases $victim\personal.txt" } else { Fail "sync with $victim\personal.txt: $msg" }
    Remove-Item -LiteralPath $file -Force
    if ($victim -ne 'app') { Remove-Item -LiteralPath (P @($own, $victim)) -Recurse -Force }
  }

  foreach ($nested in 'bin', 'lib') {
    $file = P @($own, 'app', $nested, 'personal-note.txt')
    Put $file 'my notes'
    $msg = ''; try { [void](Sync-AicmAppCopy $root) } catch { $msg = $_.Exception.Message }
    if ($msg -match 'is not part of the installed copy' -and [System.IO.File]::ReadAllText($file) -eq 'my notes') { Pass "sync never erases app\$nested\personal-note.txt" } else { Fail "nested $nested : $msg" }
    Remove-Item -LiteralPath $file -Force
  }
  if ((Get-Content -LiteralPath (P @($own, 'app', '.aicm-copy')) -Raw) -match '(?m)^lib/aicm-common\.ps1$') { Pass 'the copy keeps its own file list' } else { Fail 'no .aicm-copy list' }

  # Legacy copies without a roster must preserve user scripts, including a self-referential SOURCE.
  foreach ($selfSource in $false, $true) {
    foreach ($relative in 'lib/personal.js', 'bin/personal.sh') {
      Remove-Item -LiteralPath (P @($own, 'app', '.aicm-copy')) -Force
      if ($selfSource) { Put (P @($own, 'app', 'SOURCE')) (P @($own, 'app')) }
      $personal = Join-Path (P @($own, 'app')) $relative
      Put $personal 'personal source: keep'
      $msg = ''; try { [void](Sync-AicmAppCopy $root) } catch { $msg = $_.Exception.Message }
      if ($msg -match 'is not part of the installed copy' -and [IO.File]::ReadAllText($personal) -eq 'personal source: keep') { Pass "legacy copy preserves $relative (self source: $selfSource)" } else { Fail "legacy ownership $relative : $msg" }
      Remove-Item -LiteralPath $personal -Force
      [void](Sync-AicmAppCopy $root)
    }
  }

  # The profile folder itself is never the home, whatever marker it holds; a dated archive is no evidence.
  $savedProfile = $env:USERPROFILE
  $profileDir = P @($work, 'profile')
  Put (P @($profileDir, '.aicm-home')) "AI CLI Auto Manager home (logs, state, archive, installed copy)`r`n"
  $env:USERPROFILE = $profileDir; $env:AICM_HOME = $profileDir
  try {
    $threw = $false; try { [void](Sync-AicmAppCopy $root) } catch { $threw = $_.Exception.Message -match 'profile folder' }
    if ($threw -and -not (Test-Path -LiteralPath (P @($profileDir, 'app')))) { Pass 'a marker never makes the profile folder an install target' } else { Fail 'profile root used' }
  } finally { $env:USERPROFILE = $savedProfile }
  $dated = P @($work, 'dated')
  Put (P @($dated, 'archive', 'demo', '20261027', 'personal.txt')) 'keep'
  $env:AICM_HOME = $dated
  $threw = $false; try { [void](Sync-AicmAppCopy $root) } catch { $threw = $true }
  if ($threw -and -not (Test-Path -LiteralPath (P @($dated, '.aicm-home'))) -and -not (Test-Path -LiteralPath (P @($dated, 'app')))) { Pass 'a dated archive folder alone is not evidence of ownership' } else { Fail 'dated archive adopted' }
  $env:AICM_HOME = $own

  # Another operation holding the maintenance lock is reported (uninstall refuses while it runs).
  if (-not (Get-AicmBusyOperation)) { Pass 'nothing reported busy without a lock' } else { Fail "busy without a lock: $(Get-AicmBusyOperation)" }
  $lockOwner = P @($own, 'state', 'maintenance.lock', 'owner.json')
  Put $lockOwner "{`"pid`":$PID,`"lease`":`"x`"}"
  if ((Get-AicmBusyOperation) -match 'maintenance lock') { Pass 'a live maintenance lock is reported busy' } else { Fail 'live lock not seen' }
  Remove-Item -LiteralPath (Split-Path -Parent $lockOwner) -Recurse -Force

  # Purge removes only what the tool wrote; -DryRun changes nothing.
  Put (P @($own, 'logs', 'update-20240101-000000.log')) 'x'
  Put (P @($own, 'logs', 'notifications.log')) 'x'
  Put (P @($own, 'logs', 'personal.txt')) 'mine'
  Put (P @($own, 'state', 'last-update.json')) '{}'
  Put (P @($own, 'state', 'schedule.json')) '{}'
  Put (P @($own, 'state', 'personal.md')) 'mine'
  Put (P @($own, 'state', 'archive-index', 'm1.json')) '{"id":"m1","original":"x","stored":"codex-images/20200101/sub/img.png","rule":"codex-images","archivedAt":"2020-01-01T00:00:00Z","size":1,"status":"archived"}'
  Put (P @($own, 'state', 'history', 'h1.json')) '{}'
  Put (P @($own, 'state', 'history', 'notes.md')) 'mine'
  Put (P @($own, 'archive', 'codex-images', '20200101', 'sub', 'img.png')) 'x'
  Put (P @($own, 'archive', 'codex-images', '20200101', 'personal.txt')) 'mine'
  Put (P @($own, 'archive', 'codex-images', 'mine', 'keep.txt')) 'mine'
  Put (P @($own, 'archive', 'readme.txt')) 'mine'
  Put (P @($own, 'inventory.md')) "# AI CLI inventory - test`r`n"
  Put (P @($own, 'hooks', 'post-update.ps1')) 'Write-Host hi'
  $before = Get-Snapshot $own
  $out = Invoke-AicmPurge $own -DryRun 6>&1 | Out-String -Width 4096
  if ((Get-Snapshot $own) -eq $before -and $out -match 'would remove .*update-20240101-000000\.log' -and $out -match 'logs.personal\.txt' -and $out -match 'would remove 1 archived files' -and $out -match '20200101.personal\.txt \(not in the archive index\)' -and $out -match 'nothing was changed') { Pass 'purge -DryRun lists what goes and stays and changes nothing' } else { Fail "purge dry run: $out" }
  $out = Invoke-AicmPurge $own 6>&1 | Out-String
  $keptOk = $true
  foreach ($f in @(@('logs', 'personal.txt'), @('archive', 'codex-images', '20200101', 'personal.txt'), @('state', 'personal.md'), @('state', 'history', 'notes.md'), @('archive', 'codex-images', 'mine', 'keep.txt'), @('archive', 'readme.txt'), @('hooks', 'post-update.ps1'), @('.aicm-home'))) {
    if (-not (Test-Path -LiteralPath (P (@($own) + $f)))) { $keptOk = $false; Write-Host "missing $($f -join '\')" }
  }
  $goneOk = $true
  foreach ($f in @(@('app'), @('logs', 'update-20240101-000000.log'), @('state', 'last-update.json'), @('state', 'archive-index'), @('state', 'history', 'h1.json'), @('archive', 'codex-images', '20200101', 'sub'), @('inventory.md'))) {
    if (Test-Path -LiteralPath (P (@($own) + $f))) { $goneOk = $false; Write-Host "left $($f -join '\')" }
  }
  if ($keptOk) { Pass 'purge keeps personal logs, state and archive files' } else { Fail "purge lost personal files: $out" }
  if ($goneOk) { Pass 'purge removes what the tool wrote' } else { Fail "purge left tool files: $out" }

  # A missing home: the dry run creates nothing.
  $none = P @($work, 'never-created')
  $env:AICM_HOME = $none
  Invoke-AicmPurge $none -DryRun | Out-Null
  if (-not (Test-Path -LiteralPath $none)) { Pass 'purge -DryRun of a missing home creates nothing' } else { Fail 'dry run created the home' }

  # An unmarked folder of an older version is migrated by its structure; a stray file blocks that.
  $leg = P @($work, 'legacy', '.ai-cli-auto-manager')
  New-Item -ItemType Directory -Path $leg -Force | Out-Null
  $env:AICM_HOME = P @($work, 'copysrc')
  $copy = Sync-AicmAppCopy $root
  Copy-Item -LiteralPath $copy -Destination (P @($leg, 'app')) -Recurse
  Put (P @($leg, 'logs', 'update-20240101-000000.log')) 'x'
  Put (P @($leg, 'state', 'last-update.json')) '{}'
  Put (P @($leg, 'hooks', 'post-update.ps1')) 'Write-Host hi'
  $env:AICM_HOME = $leg
  if ((Get-AicmHomeStatus) -eq 'legacy') { Pass 'an unmarked older install is recognized by its structure' } else { Fail "legacy: $($script:AicmHomeProblem)" }
  Confirm-AicmHome 2>$null
  if (Test-Path -LiteralPath (P @($leg, '.aicm-home'))) { Pass 'a recognized older install is marked' } else { Fail 'legacy not marked' }
  Remove-Item -LiteralPath (P @($leg, '.aicm-home')) -Force
  Put (P @($leg, 'state', 'notes.md')) 'mine'
  if ((Get-AicmHomeStatus) -eq 'foreign' -and $script:AicmHomeProblem -match 'notes\.md') { Pass 'an older install with a foreign state file is not adopted' } else { Fail 'stray state file adopted' }

  # Links: a selected home root may be a junction or link; a linked reserved entry is refused.
  $onWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
  $target = P @($work, 'linked-target')
  $alias = P @($work, 'linked-home')
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  if ($onWindows) { New-Item -ItemType Junction -Path $alias -Target $target | Out-Null } else { New-Item -ItemType SymbolicLink -Path $alias -Target $target | Out-Null }
  try {
    $env:AICM_HOME = $alias
    $null = Sync-AicmAppCopy $root
    $null = Sync-AicmAppCopy $root
    if ((Test-Path -LiteralPath (P @($target, 'app', 'SOURCE'))) -and -not (Test-Path -LiteralPath (P @($target, 'app.old')))) { Pass 'a home selected as a junction or link still syncs' } else { Fail 'linked home sync' }
    $outside = P @($work, 'outside-logs')
    Put (P @($outside, 'update-20240101-000000.log')) 'keep'
    if ($onWindows) { New-Item -ItemType Junction -Path (P @($target, 'logs')) -Target $outside | Out-Null } else { New-Item -ItemType SymbolicLink -Path (P @($target, 'logs')) -Target $outside | Out-Null }
    Invoke-AicmPurge $alias 6>&1 | Out-Null
    if ((Test-Path -LiteralPath (P @($outside, 'update-20240101-000000.log'))) -and (Test-Path -LiteralPath (P @($target, 'logs')))) { Pass 'purge keeps a linked logs folder and its target' } else { Fail 'linked logs followed' }
    $l = Get-Item -LiteralPath (P @($target, 'logs')) -Force
    if ($onWindows) { [System.IO.Directory]::Delete($l.FullName, $false) } else { $l.Delete() }
  } finally {
    $a = Get-Item -LiteralPath $alias -Force -ErrorAction SilentlyContinue
    if ($a) { if ($onWindows) { [System.IO.Directory]::Delete($alias, $false) } else { $a.Delete() } }
  }
} finally {
  $env:AICM_HOME = $savedHome
  $resolved = [System.IO.Path]::GetFullPath($work)
  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -match '^aicm-test-[0-9a-f]{32}$') {
    # The temp root is the trusted root: on macOS it sits below the /var -> /private/var link.
    Remove-AicmTree ([System.IO.DirectoryInfo]::new($resolved)) $tempRoot.TrimEnd([char]92, [char]47)
  }
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
