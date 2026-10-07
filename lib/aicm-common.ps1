# Shared helpers for AI CLI Auto Manager on Windows.
# Dot-source this file; it defines functions only and has no side effects.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts with the ANSI code page.

function Get-AicmRoot {
  return (Split-Path -Parent $PSScriptRoot)
}

function Get-AicmVersion {
  $file = Join-Path (Get-AicmRoot) 'VERSION'
  if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -TotalCount 1).Trim() }
  return 'unknown'
}

function Get-AicmUserHome {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  return $HOME
}

function Get-AicmHome {
  if ($env:AICM_HOME) { return $env:AICM_HOME }
  return (Join-Path (Get-AicmUserHome) '.ai-cli-auto-manager')
}

function Get-AicmTempDir {
  if ($env:TEMP) { return $env:TEMP.TrimEnd('\', '/') }
  return [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
}

function Get-AicmLocalAppData {
  if ($env:LOCALAPPDATA) { return $env:LOCALAPPDATA }
  return (Join-Path (Get-AicmUserHome) 'AppData\Local')
}

# Per-user lock name. A separate AICM_HOME (tests, a second setup) gets its own lock, so it never
# waits for or blocks the real scheduled runs.
function Get-AicmLockName([string]$Kind) {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $userPart = if ($identity -and $identity.User) { $identity.User.Value } else { $env:USERNAME }
  $name = "Local\ai-cli-auto-manager-$Kind-$($userPart -replace '[^A-Za-z0-9._-]', '-')"
  if ($env:AICM_HOME) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($env:AICM_HOME.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
    $name += "-$hash"
  }
  return $name
}

function Initialize-AicmDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-AicmTimestamp {
  return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Format-AicmSize([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
  return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Expand-AicmPath([string]$Path) {
  $p = $Path
  if ($p -eq '~') { $p = Get-AicmUserHome }
  elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = (Get-AicmUserHome) + $p.Substring(1) }
  $p = $p.Replace('{temp}', (Get-AicmTempDir))
  $p = $p.Replace('{localappdata}', (Get-AicmLocalAppData))
  $p = $p.Replace('{cache}', (Get-AicmLocalAppData))
  return [System.IO.Path]::GetFullPath($p.Replace('/', '\'))
}

function Test-AicmUnder([string]$Path, [string]$Root) {
  $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
  return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-AicmSamePath([string]$A, [string]$B) {
  $x = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
  $y = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
  return [string]::Equals($x, $y, [System.StringComparison]::OrdinalIgnoreCase)
}

# A rule may only touch the home folder (never the home folder itself) or the temp folder.
function Test-AicmAllowedPath([string]$Path) {
  $userHome = Get-AicmUserHome
  $temp = Get-AicmTempDir
  if (Test-AicmSamePath $Path $userHome) { return $false }
  if (Test-AicmUnder $Path $temp) { return $true }
  return (Test-AicmUnder $Path $userHome)
}

$script:AicmProtectedNames = @(
  'MEMORY.md', 'CLAUDE.md', 'AGENTS.md', 'GEMINI.md',
  'auth.json', '.credentials.json', 'credentials.json', 'credentials',
  'settings.json', 'settings.local.json', 'config.toml', 'config.json', 'config.yaml',
  '.env'
)

function Test-AicmProtected([System.IO.FileSystemInfo]$Item) {
  foreach ($name in $script:AicmProtectedNames) {
    if ([string]::Equals($Item.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  if ($Item.Name -like '*.env') { return $true }
  if ($Item.FullName -match '[\\/]memory[\\/]') { return $true }
  return $false
}

function Test-AicmLink([System.IO.FileSystemInfo]$Item) {
  return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Enumerates files below $Root without ever entering a symlink or junction.
function Get-AicmFiles([string]$Root, [string]$Pattern = '*', [switch]$TopOnly) {
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push([System.IO.DirectoryInfo]::new($Root))
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $children = $null
    try { $children = $dir.GetFileSystemInfos() } catch { continue }
    foreach ($child in $children) {
      if (Test-AicmLink $child) { continue }
      if ($child -is [System.IO.DirectoryInfo]) {
        if (-not $TopOnly) { $stack.Push($child) }
      } elseif ($child.Name -like $Pattern) {
        $child
      }
    }
  }
}

# Removes a folder tree. Links inside it are unlinked, never followed, so their targets survive.
function Remove-AicmTree([System.IO.DirectoryInfo]$Dir) {
  if (Test-AicmLink $Dir) {
    [System.IO.Directory]::Delete($Dir.FullName, $false)
    return
  }
  foreach ($child in $Dir.GetFileSystemInfos()) {
    if ($child -is [System.IO.DirectoryInfo]) {
      Remove-AicmTree $child
    } else {
      if ($child.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
        $child.Attributes = $child.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
      }
      $child.Delete()
    }
  }
  $Dir.Delete($false)
}

# Removes empty folders below $Root, deepest first. $Root itself and links are kept.
function Remove-AicmEmptyDirs([string]$Root) {
  $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push([System.IO.DirectoryInfo]::new($Root))
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $subs = $null
    try { $subs = $dir.GetDirectories() } catch { continue }
    foreach ($sub in $subs) {
      if (Test-AicmLink $sub) { continue }
      $dirs.Add($sub)
      $stack.Push($sub)
    }
  }
  $removed = 0
  foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
    try {
      if (@($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete($false); $removed++ }
    } catch { }
  }
  return $removed
}

function Test-AicmOsMatch([string]$Os) {
  switch ($Os.ToLowerInvariant()) {
    'all' { return $true }
    'windows' { return $true }
    default { return $false }
  }
}

function ConvertFrom-AicmRuleLine([string]$Line, [string]$Source) {
  $t = $Line.Trim()
  if (-not $t -or $t.StartsWith('#')) { return $null }
  $cols = @($Line.Split('|') | ForEach-Object { $_.Trim() })
  if ($cols.Count -lt 8) { throw "invalid rule in ${Source}: expected 9 columns: $t" }
  while ($cols.Count -lt 9) { $cols += '' }
  $kind = $cols[2].ToLowerInvariant()
  if (@('age', 'cap', 'keep-latest', 'command', 'archive', 'codex') -notcontains $kind) { throw "invalid rule kind '$kind' in ${Source}: $t" }
  $default = $cols[7].ToLowerInvariant()
  if (@('on', 'off') -notcontains $default) { throw "invalid default '$default' in ${Source}: $t" }
  $days = 0
  if ($cols[5]) { $days = [int]$cols[5] }
  $limit = 0
  if ($cols[6]) { $limit = [int]$cols[6] }
  if ($kind -eq 'age' -and $days -lt 1) { throw "age rule needs days >= 1 in ${Source}: $t" }
  if ($kind -eq 'keep-latest' -and $limit -lt 1) { throw "keep-latest rule needs limit >= 1 in ${Source}: $t" }
  if ($kind -eq 'archive' -and ($days -lt 1 -or $limit -lt 1)) { throw "archive rule needs days >= 1 (archive after) and limit >= 1 (delete after) in ${Source}: $t" }
  if ($kind -eq 'codex' -and $days -lt 1) { throw "codex rule needs days >= 1 in ${Source}: $t" }
  return [pscustomobject]@{
    Id = $cols[0]; Os = $cols[1].ToLowerInvariant(); Kind = $kind; Path = $cols[3]; Pattern = $(if ($cols[4]) { $cols[4] } else { '*' })
    Days = $days; Limit = $limit; Enabled = ($default -eq 'on'); Note = $cols[8]; Source = $Source
  }
}

# Returns the rules that apply to this OS. Local rows replace built-in rows with the same id.
function Read-AicmRules([string]$RulesFile, [string]$LocalFile) {
  $ordered = New-Object System.Collections.Generic.List[string]
  $byId = @{}
  foreach ($file in @($RulesFile, $LocalFile)) {
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { continue }
    $source = Split-Path -Leaf $file
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
      $rule = ConvertFrom-AicmRuleLine $line $source
      if (-not $rule) { continue }
      if (-not (Test-AicmOsMatch $rule.Os)) { continue }
      if (-not $byId.ContainsKey($rule.Id)) { $ordered.Add($rule.Id) }
      $byId[$rule.Id] = $rule
    }
  }
  foreach ($id in $ordered) { $byId[$id] }
}

# Writes to a temp file and swaps it in, so a crash mid-write never leaves a half-written state file.
function Write-AicmState([string]$Name, $Object) {
  $dir = Join-Path (Get-AicmHome) 'state'
  Initialize-AicmDirectory $dir
  $file = Join-Path $dir "$Name.json"
  $tmp = "$file.$PID.tmp"
  $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
  if (Test-Path -LiteralPath $file) { [System.IO.File]::Replace($tmp, $file, [NullString]::Value) }
  else { [System.IO.File]::Move($tmp, $file) }
}

function Read-AicmState([string]$Name) {
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') "$Name.json"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Notifies the items that are new or were last announced 7+ days ago, so a lasting problem does not
# raise a notification every day. Items that went away are forgotten.
function Send-AicmAttention([string]$Key, [string[]]$Items) {
  $list = @($Items | Where-Object { $_ })
  $seen = @{}
  $prev = Read-AicmState "attention-$Key"
  if ($prev) { foreach ($p in $prev.PSObject.Properties) { $seen[$p.Name] = [string]$p.Value } }
  $now = (Get-Date).ToUniversalTime()
  $keep = [ordered]@{}
  $due = New-Object System.Collections.Generic.List[string]
  foreach ($i in $list) {
    $last = [datetime]::MinValue
    if ($seen.ContainsKey($i)) { [void][datetime]::TryParse($seen[$i], [ref]$last) }
    if (($now - $last.ToUniversalTime()).TotalDays -ge 7) { $due.Add($i); $keep[$i] = $now.ToString('o') }
    else { $keep[$i] = $seen[$i] }
  }
  Write-AicmState "attention-$Key" $keep
  if ($due.Count -gt 0) { Send-AicmNotification 'AI CLI Auto Manager' ($due.ToArray() -join '; ') }
}

# Desktop notification. Never fails the caller. Disable with AICM_NOTIFY=0.
function Send-AicmNotification([string]$Title, [string]$Body) {
  Write-Host "notify: $Title - $Body"
  if ($env:AICM_NOTIFY -eq '0') { return }
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $texts = $xml.GetElementsByTagName('text')
    [void]$texts.Item(0).AppendChild($xml.CreateTextNode($Title))
    [void]$texts.Item(1).AppendChild($xml.CreateTextNode($Body))
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
  } catch {
    Write-Host "warn: desktop notification unavailable: $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------------------
# Archive lifecycle helpers
# ---------------------------------------------------------------------------

function Get-AicmArchiveRoot {
  return (Join-Path (Get-AicmHome) 'archive')
}

# Days after which the CLI deletes these files itself (0 when it does not). The archive step has to
# run before that, and the cleanup runs weekly, so it archives a week earlier than the CLI deletes.
function Get-AicmNativeRetentionDays([string]$RuleId) {
  $userHome = Get-AicmUserHome
  $read = {
    param($File, $Pattern)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $text = Get-Content -LiteralPath $File -Raw -ErrorAction SilentlyContinue
    if ($text -and $text -match $Pattern) { return $Matches }
    return $null
  }
  switch ($RuleId) {
    'claude-transcripts' {
      $m = & $read (Join-Path $userHome '.claude\settings.json') '"cleanupPeriodDays"\s*:\s*(\d+)'
      if ($m) { return [int]$m[1] }
      return 30
    }
    'gemini-tmp' {
      $m = & $read (Join-Path $userHome '.gemini\settings.json') '"maxAge"\s*:\s*"(\d+)([hdw])"'
      if ($m) { switch ($m[2]) { 'h' { return [int][Math]::Ceiling([int]$m[1] / 24) } 'w' { return [int]$m[1] * 7 } default { return [int]$m[1] } } }
      return 30
    }
    'qwen-tmp' {
      $m = & $read (Join-Path $userHome '.qwen\settings.json') '"cleanupPeriodDays"\s*:\s*(\d+)'
      if ($m) { return [int]$m[1] }
      return 30
    }
  }
  return 0
}

function Get-AicmArchiveDays($Rule) {
  $native = Get-AicmNativeRetentionDays $Rule.Id
  if ($native -gt 0) { return [Math]::Max(1, [Math]::Min($Rule.Days, $native - 8)) }
  return $Rule.Days
}

function Get-AicmCodexId([string]$Name) {
  if ($Name -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
  return ''
}

# Codex threads from its state DB (read-only): id -> rollout path, last update (unix seconds), archived.
# Needs Python with sqlite3; returns $null when that is not available or the layout is unknown.
function Get-AicmCodexThreads([string]$CodexHome) {
  if ($env:AICM_CODEX_DB_READER -eq '0') { return $null }
  $db = Get-ChildItem -LiteralPath $CodexHome -Filter 'state_*.sqlite' -File -ErrorAction SilentlyContinue |
    Sort-Object { [int](($_.BaseName -split '_')[-1]) } -Descending | Select-Object -First 1
  if (-not $db) { return $null }
  $python = @('python', 'python3', 'py') | Where-Object { Resolve-AicmExecutable $_ } | Select-Object -First 1
  if (-not $python) { return $null }
  $code = "import sqlite3,sys`ncon=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)`nfor r in con.execute('select id, rollout_path, updated_at, archived from threads'):`n    print('\t'.join('' if v is None else str(v) for v in r))"
  $script = [System.IO.Path]::GetTempFileName() + '.py'
  [System.IO.File]::WriteAllText($script, $code)
  try {
    $r = Invoke-AicmWithTimeout $python @($script, $db.FullName) 120
    if ($r.ExitCode -ne 0) { return $null }
    $threads = @{}
    foreach ($line in ($r.Output -split "`r?`n")) {
      $c = $line.Split("`t")
      if ($c.Count -lt 4 -or -not $c[0]) { continue }
      $u = 0.0
      [void][double]::TryParse($c[2], [ref]$u)
      if ($u -gt 1e11) { $u = $u / 1000 }
      $threads[$c[0]] = [pscustomobject]@{ Rollout = $c[1]; Updated = $u; Archived = ($c[3] -eq '1') }
    }
    return $threads
  } finally {
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# Installed copy: scheduled jobs run ~/.ai-cli-auto-manager/app, not the git clone, so moving or
# deleting the clone cannot stop them. The daily update refreshes the copy when the clone has a
# newer VERSION.
# ---------------------------------------------------------------------------

function Get-AicmAppDir { return (Join-Path (Get-AicmHome) 'app') }

# Antivirus scanners briefly lock freshly written files, so a folder move is retried a few times.
function Move-AicmDirectory([string]$From, [string]$To) {
  for ($i = 1; ; $i++) {
    try { Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop; return }
    catch { if ($i -ge 5) { throw }; Start-Sleep -Milliseconds (300 * $i) }
  }
}

# Files of $Source (bin, lib, rules, windows) that are missing from $Copy or differ in size, plus the
# files every copy needs. Empty when the copy is complete.
function Get-AicmAppCopyGaps([string]$Source, [string]$Copy) {
  $gaps = New-Object System.Collections.Generic.List[string]
  foreach ($f in 'VERSION', 'bin\aicm.ps1', 'lib\aicm-common.ps1', 'windows\run-hidden.vbs') {
    if (-not (Test-Path -LiteralPath (Join-Path $Copy $f) -PathType Leaf)) { $gaps.Add($f) }
  }
  if (-not (Get-ChildItem -LiteralPath (Join-Path $Copy 'rules') -File -ErrorAction SilentlyContinue)) { $gaps.Add('rules') }
  $base = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
  foreach ($d in 'bin', 'lib', 'rules', 'windows') {
    $dir = Join-Path $base $d
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Force)) {
      $rel = $f.FullName.Substring($base.Length + 1)
      $copied = Get-Item -LiteralPath (Join-Path $Copy $rel) -Force -ErrorAction SilentlyContinue
      if (-not $copied -or $copied.Length -ne $f.Length) { $gaps.Add($rel) }
    }
  }
  return $gaps.ToArray()
}

# Copies bin, lib, rules, windows and VERSION from $Source into the app folder. The new copy is built
# next to the old one and checked file by file before the swap; when anything fails, the old copy
# stays (or is put back), so the scheduled tasks never point at a missing or half-copied folder.
function Sync-AicmAppCopy([string]$Source) {
  $app = Get-AicmAppDir
  if (Test-AicmSamePath $Source $app) { return $app }
  $new = "$app.new"
  $old = "$app.old"
  # A run that stopped between the two moves left only app.old behind: put it back first.
  if (-not (Test-Path -LiteralPath $app) -and (Test-Path -LiteralPath $old)) { Move-AicmDirectory $old $app }
  foreach ($d in $new, $old) { if (Test-Path -LiteralPath $d) { Remove-AicmTree ([System.IO.DirectoryInfo]::new($d)) } }
  try {
    New-Item -ItemType Directory -Path $new -Force | Out-Null
    foreach ($d in 'bin', 'lib', 'rules', 'windows') { Copy-Item -LiteralPath (Join-Path $Source $d) -Destination (Join-Path $new $d) -Recurse -Force -ErrorAction Stop }
    foreach ($f in 'VERSION', 'LICENSE', 'README.md') {
      $p = Join-Path $Source $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $new $f) -Force -ErrorAction Stop }
    }
    [System.IO.File]::WriteAllText((Join-Path $new 'SOURCE'), $Source)
    $gaps = @(Get-AicmAppCopyGaps $Source $new)
    if ($gaps.Count -gt 0) { throw "the new copy is incomplete (missing or different: $($gaps[0]))" }
  } catch {
    if (Test-Path -LiteralPath $new) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($new)) } catch { } }
    throw
  }
  if (Test-Path -LiteralPath $app) { Move-AicmDirectory $app $old }
  try {
    Move-AicmDirectory $new $app
  } catch {
    if (-not (Test-Path -LiteralPath $app) -and (Test-Path -LiteralPath $old)) { Move-AicmDirectory $old $app }
    if (Test-Path -LiteralPath $new) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($new)) } catch { } }
    throw
  }
  if (Test-Path -LiteralPath $old) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($old)) } catch { } }
  return $app
}

# Called at the end of the daily update when it runs from the installed copy. Copies only a newer
# version (checking out an old tag in the clone never downgrades the jobs), then re-registers the
# scheduled tasks from the new copy so changed script names or arguments take effect.
function Update-AicmAppCopy {
  $ErrorActionPreference = 'Continue'
  $app = Get-AicmAppDir
  if (-not (Test-AicmSamePath (Get-AicmRoot) $app)) { return }
  $sourceFile = Join-Path $app 'SOURCE'
  if (-not (Test-Path -LiteralPath $sourceFile)) { return }
  $source = (Get-Content -LiteralPath $sourceFile -TotalCount 1).Trim()
  $current = Get-AicmVersion
  $srcVersion = Join-Path $source 'VERSION'
  if (-not $source -or -not (Test-Path -LiteralPath $srcVersion) -or -not (Test-Path -LiteralPath (Join-Path $source 'bin\aicm.ps1'))) {
    Write-Host "installed copy: source $source is gone; keeping version $current"
    return
  }
  $newVersion = (Get-Content -LiteralPath $srcVersion -TotalCount 1).Trim()
  if ($newVersion -eq $current) { return }
  if ((Compare-AicmVersion $newVersion $current) -le 0) {
    Write-Host "installed copy: $source has version $newVersion, not newer than $current; keeping $current"
    return
  }
  try { [void](Sync-AicmAppCopy $source) }
  catch { Write-Host "installed copy: could not refresh ($($_.Exception.Message)); keeping $current, trying again next run"; return }
  Write-Host "installed copy: updated $current -> $newVersion from $source"
  if (-not (Read-AicmState 'schedule')) { return }
  try {
    $exe = (Get-Process -Id $PID).Path
    $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $app 'bin\aicm.ps1') schedule refresh 2>&1
    foreach ($line in @($out)) { if ("$line".Trim()) { Write-Host "schedule refresh: $line" } }
    if ($LASTEXITCODE -ne 0) { Write-Host "schedule refresh: failed (exit code $LASTEXITCODE); run: aicm.ps1 schedule install" }
  } catch {
    Write-Host "schedule refresh: failed ($($_.Exception.Message)); run: aicm.ps1 schedule install"
  }
}

# AICM_TASK_PATH lets tests register throwaway tasks in their own folder.
$script:AicmTaskPath = if ($env:AICM_TASK_PATH) { $env:AICM_TASK_PATH } else { '\AI CLI Auto Manager\' }

function Get-AicmTask([string]$Name) {
  return (Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $Name -ErrorAction SilentlyContinue)
}

# Registry keys that turn Windows Script Host off (value Enabled = 0); the tasks normally start
# through wscript.exe, so they cannot run then. AICM_WSH_KEYS (paths separated by ';') replaces the
# two real keys in tests.
function Get-AicmWshDisabled {
  $keys = if ($env:AICM_WSH_KEYS) { $env:AICM_WSH_KEYS -split ';' } else {
    @('HKCU:\Software\Microsoft\Windows Script Host\Settings', 'HKLM:\Software\Microsoft\Windows Script Host\Settings')
  }
  foreach ($k in $keys) {
    if (-not $k) { continue }
    $v = $null
    try { $v = (Get-ItemProperty -LiteralPath $k -Name 'Enabled' -ErrorAction Stop).Enabled } catch { continue }
    if ("$v".Trim() -eq '0') { $k }
  }
}

# A registered task that cannot do its work: turned off, pointing at a file that is gone, or failed
# on its last run. Result codes 0x41301 (running), 0x41303 (has not run yet) and 0x41325 (queued) are
# not failures. Exit code 1 is the job reporting its own failure, which it already notified, so it is
# only reported when the job did not get as far as writing its state file.
function Get-AicmTaskProblems($Task, [string]$Job) {
  if ($Task.State -eq 'Disabled') {
    "scheduled task '$Job' is disabled; enable it in Task Scheduler or run: aicm.ps1 schedule install"
  }
  foreach ($a in @($Task.Actions)) {
    $files = @([regex]::Matches([string]$a.Arguments, '"([^"]+\.(?:ps1|vbs))"') | ForEach-Object { $_.Groups[1].Value })
    if ($a.Execute -and [System.IO.Path]::IsPathRooted([string]$a.Execute)) { $files += [string]$a.Execute }
    foreach ($f in $files) {
      if (-not (Test-Path -LiteralPath $f)) { "scheduled task '$Job' starts $f, which does not exist; run: aicm.ps1 schedule install"; break }
    }
  }
  $info = $null
  try { $info = $Task | Get-ScheduledTaskInfo -ErrorAction Stop } catch { return }
  $code = [int64]$info.LastTaskResult
  if ($code -in @(0, 0x41301, 0x41303, 0x41325)) { return }
  if ($code -eq 1) {
    $stateName = @{ Update = 'last-update'; Inventory = 'inventory'; Clean = 'last-clean' }[$Job]
    $state = if ($stateName) { Read-AicmState $stateName } else { $null }
    try { if ($state -and [datetime]::Parse($state.finishedAt) -ge $info.LastRunTime.AddMinutes(-1)) { return } } catch { }
  }
  "scheduled task '$Job' failed on its last run (result 0x{0:X}); see {1}" -f $code, (Join-Path (Get-AicmHome) 'logs')
}

# Checks that every scheduled job recorded at install time still exists.
# Returns a list of human-readable problems (empty when healthy).
# Also flags a job that is registered but has not completed for too long (its script is gone, it keeps
# crashing, ...), once the schedule has existed that long. -NoStale: existence only (doctor checks age itself).
function Get-AicmScheduleProblems([string]$Skip = '', [switch]$NoStale) {
  $problems = New-Object System.Collections.Generic.List[string]
  $sched = Read-AicmState 'schedule'
  if (-not $sched) { return $problems }
  $limits = @{ Update = @('last-update', 3); Inventory = @('inventory', 9); Clean = @('last-clean', 9) }
  $installedDays = 0
  try { $installedDays = ((Get-Date).ToUniversalTime() - [datetime]::Parse($sched.installedAt).ToUniversalTime()).TotalDays } catch { }
  $launcher = if ($sched.PSObject.Properties['launcher']) { [string]$sched.launcher } else { 'wscript' }
  if ($launcher -eq 'wscript') {
    foreach ($k in @(Get-AicmWshDisabled)) {
      $problems.Add("Windows Script Host is turned off ($k = 0), so the scheduled tasks cannot start; run: aicm.ps1 schedule install (it then starts them through PowerShell)")
    }
  }
  foreach ($job in @($sched.jobs)) {
    if ($job -eq $Skip) { continue }
    $task = Get-AicmTask $job
    if (-not $task) {
      $problems.Add("scheduled task '$job' is missing; run: aicm.ps1 schedule install")
      continue
    }
    foreach ($p in @(Get-AicmTaskProblems $task $job)) { $problems.Add($p) }
    if ($NoStale -or -not $limits.ContainsKey($job)) { continue }
    $state = Read-AicmState $limits[$job][0]
    $days = [double]::PositiveInfinity
    if ($state) { try { $days = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.finishedAt).ToUniversalTime()).TotalDays } catch { } }
    $limit = $limits[$job][1]
    if ($days -gt $limit -and $installedDays -gt $limit) {
      $problems.Add("scheduled task '$job' has not completed for over $limit days; see $(Join-Path (Get-AicmHome) 'logs')")
    }
  }
  return $problems
}

# ---------------------------------------------------------------------------
# Running CLIs and the AI CLI catalog
# ---------------------------------------------------------------------------

function Join-AicmProcessArguments([string[]]$Arguments) {
  $quoted = foreach ($arg in $Arguments) {
    if ($null -eq $arg -or $arg -eq '') { '""' }
    elseif ($arg -notmatch '[\s"]') { $arg }
    else { '"' + ($arg -replace '"', '\"') + '"' }
  }
  return ($quoted -join ' ')
}

# Returns a path that CreateProcess can start. npm writes name.ps1 next to name.cmd; the .ps1 cannot be
# started directly, so the .cmd twin is preferred.
function Resolve-AicmExecutable([string]$Name) {
  if ([System.IO.Path]::IsPathRooted($Name) -and (Test-Path -LiteralPath $Name)) {
    $path = $Name
  } else {
    $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $path = $cmd.Source
  }
  if ($path -like '*.ps1') {
    $twin = [System.IO.Path]::ChangeExtension($path, '.cmd')
    if (Test-Path -LiteralPath $twin) { return $twin }
  }
  return $path
}

function Invoke-AicmWithTimeout([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds) {
  $exe = Resolve-AicmExecutable $Name
  if (-not $exe) { throw "command not found: $Name" }
  if ($exe -like '*.ps1') {
    $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exe) + @($Arguments)
    $exe = (Get-Command powershell.exe).Source
  }
  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $startArgs = @{ FilePath = $exe; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $stdoutFile; RedirectStandardError = $stderrFile }
    if (@($Arguments).Count -gt 0) { $startArgs.ArgumentList = (Join-AicmProcessArguments $Arguments) }
    $process = Start-Process @startArgs
    # Touch the handle now; otherwise ExitCode stays empty after a timed WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill() } catch { }
      $partial = @(
        Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        "TIMEOUT after ${TimeoutSeconds}s"
      ) -join ''
      return [pscustomobject]@{ ExitCode = 124; Output = $partial }
    }
    $process.WaitForExit()
    $output = @(
      Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
      Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
    ) -join ''
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
  } finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-AicmSemver([string]$Text) {
  if ($Text -match '(\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.\-]+)?)') { return $Matches[1] }
  return ''
}

# 1 when $A is newer, -1 when older, 0 when equal or not comparable.
function Compare-AicmVersion([string]$A, [string]$B) {
  if (-not $A -or -not $B -or $A -eq $B) { return 0 }
  $va = $null; $vb = $null
  if ([version]::TryParse(($A -replace '[-+].*$', ''), [ref]$va) -and [version]::TryParse(($B -replace '[-+].*$', ''), [ref]$vb)) {
    return $va.CompareTo($vb)
  }
  return 0
}

$script:AicmBuiltinIds = @('claude', 'codex', 'opencode', 'grok', 'kimi', 'agy')

function Read-AicmCatalog([string]$CatalogFile = '', [string]$LocalFile = '') {
  if (-not $CatalogFile) { $CatalogFile = Join-Path (Get-AicmRoot) 'rules\ai-clis.conf' }
  if (-not $LocalFile) { $LocalFile = Join-Path (Get-AicmHome) 'ai-clis.local.conf' }
  $ordered = New-Object System.Collections.Generic.List[string]
  $byId = @{}
  foreach ($file in @($CatalogFile, $LocalFile)) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $source = Split-Path -Leaf $file
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
      $t = $line.Trim()
      if (-not $t -or $t.StartsWith('#')) { continue }
      $c = @($line.Split('|') | ForEach-Object { $v = $_.Trim(); if ($v -eq '-') { '' } else { $v } })
      if ($c.Count -lt 7) { throw "invalid catalog row in ${source}: expected 8 columns: $t" }
      while ($c.Count -lt 8) { $c += '' }
      if ($c[0] -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "invalid catalog id '$($c[0])' in $source" }
      if (-not $c[1] -and -not $c[5]) { throw "catalog row '$($c[0])' in $source needs a command or a winget id" }
      $entry = [pscustomobject]@{
        Id = $c[0]; Command = $c[1]; Name = $(if ($c[2]) { $c[2] } else { $c[0] }); Npm = $c[3]; Brew = $c[4]; Winget = $c[5]
        SelfUpdate = $c[6]; Note = $c[7]; Builtin = ($script:AicmBuiltinIds -contains $c[0])
      }
      if (-not $byId.ContainsKey($entry.Id)) { $ordered.Add($entry.Id) }
      $byId[$entry.Id] = $entry
    }
  }
  foreach ($id in $ordered) { $byId[$id] }
}

$script:AicmNpmInfo = $null
# Global npm prefix and installed global packages (name -> version), cached per run.
function Get-AicmNpmInfo {
  if ($script:AicmNpmInfo) { return $script:AicmNpmInfo }
  $info = [pscustomobject]@{ Available = $false; Prefix = ''; Packages = @{} }
  if (Resolve-AicmExecutable 'npm') {
    $info.Available = $true
    $prefix = Invoke-AicmWithTimeout 'npm' @('prefix', '-g') 30
    if ($prefix.ExitCode -eq 0) {
      $first = @($prefix.Output -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
      if ($first) { $info.Prefix = $first.Trim() }
    }
    $list = Invoke-AicmWithTimeout 'npm' @('ls', '-g', '--depth=0', '--json') 60
    try {
      $deps = ($list.Output | ConvertFrom-Json).dependencies
      if ($deps) { foreach ($p in $deps.PSObject.Properties) { $info.Packages[$p.Name] = [string]$p.Value.version } }
    } catch { }
  }
  $script:AicmNpmInfo = $info
  return $info
}

$script:AicmWingetText = $null
function Get-AicmWingetText {
  if ($null -ne $script:AicmWingetText) { return $script:AicmWingetText }
  $script:AicmWingetText = ''
  if (Resolve-AicmExecutable 'winget') {
    $r = Invoke-AicmWithTimeout 'winget' @('list', '--accept-source-agreements', '--disable-interactivity') 120
    if ($r.ExitCode -eq 0) { $script:AicmWingetText = $r.Output }
  }
  return $script:AicmWingetText
}

function Get-AicmWingetVersion([string]$Id) {
  foreach ($line in ((Get-AicmWingetText) -split "`r?`n")) {
    if ($line -match ('(?i)(^|\s)' + [regex]::Escape($Id) + '\s+(\S+)')) { return $Matches[2] }
  }
  return ''
}

# Where the copy on PATH came from (npm | winget | standalone), plus a stale npm copy hidden behind it.
function Get-AicmCliInstall($Entry) {
  $result = [ordered]@{ Installed = $false; Path = ''; Method = ''; NpmCopy = '' }
  $npm = Get-AicmNpmInfo
  $npmVersion = ''
  if ($Entry.Npm -and $npm.Packages.ContainsKey($Entry.Npm)) { $npmVersion = $npm.Packages[$Entry.Npm] }
  if (-not $Entry.Command) {
    if ($Entry.Winget -and (Get-AicmWingetVersion $Entry.Winget)) { $result.Installed = $true; $result.Method = 'winget' }
    return [pscustomobject]$result
  }
  $cmd = Get-Command $Entry.Command -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    if ($npmVersion) { $result.Installed = $true; $result.Method = 'npm'; $result.Path = '(npm package, command not on PATH)' }
    return [pscustomobject]$result
  }
  $result.Installed = $true
  $result.Path = $cmd.Source
  if ($npm.Prefix -and (Test-AicmUnder $cmd.Source $npm.Prefix)) { $result.Method = 'npm' }
  elseif ($cmd.Source -match '\\WinGet\\') { $result.Method = 'winget' }
  else { $result.Method = 'standalone' }
  if ($result.Method -ne 'npm' -and $npmVersion) { $result.NpmCopy = $npmVersion }
  return [pscustomobject]$result
}

# How to get rid of a second copy that hides behind (or in front of) the one on PATH.
function Get-AicmShadowFix($Install) {
  $npm = Get-AicmNpmInfo
  $dir = Split-Path -Parent $Install.Path
  return "fix: keep one copy - uninstall the npm copy, or put $($npm.Prefix) before $dir in your user PATH so the daily-updated npm copy is the one that runs."
}

# Whether the daily update keeps the copy on PATH current: 'yes' or 'no: <why>'.
function Get-AicmUpdateCoverage($Entry, $Install) {
  switch ($Install.Method) {
    'npm' { if ($Entry.Npm) { return 'yes' } else { return 'no: unknown npm package' } }
    'winget' { if ($Entry.Winget) { return 'yes' } else { return 'no: add its winget id to the catalog' } }
    'standalone' {
      # The dedicated updaters for these prefer the npm copy when one exists.
      if ($Entry.Builtin -and $Install.NpmCopy -and (@('claude', 'codex', 'opencode', 'kimi') -contains $Entry.Id)) {
        return 'no: the update refreshes the npm copy, not the one on PATH'
      }
      if ($Entry.SelfUpdate) { return 'yes' }
      if ($Entry.Note) { return "no: $($Entry.Note)" }
      return 'no: installed standalone without a self-update command'
    }
  }
  return 'no'
}

# ---------------------------------------------------------------------------
# Release checks for npm installs (logic in lib\npm-guard.js, shared with macOS/Linux)
#   AICM_MIN_RELEASE_AGE_DAYS  only install versions at least this old (default 3, 0 = newest)
#   AICM_VERIFY_SIGNATURES     0 skips the staged `npm audit signatures` check (default on)
#   AICM_ALLOW                 comma list of pkg@version accepted despite red flags
# ---------------------------------------------------------------------------

function Get-AicmMinReleaseAgeDays {
  if ($env:AICM_MIN_RELEASE_AGE_DAYS -match '^\d+$') { return [int]$env:AICM_MIN_RELEASE_AGE_DAYS }
  return 3
}

function Invoke-AicmNpmGuard([string[]]$Arguments) {
  $guard = Join-Path (Get-AicmRoot) 'lib\npm-guard.js'
  $r = Invoke-AicmWithTimeout 'node' (@($guard) + $Arguments) 60
  if ($r.ExitCode -ne 0) { throw "npm-guard failed: $($r.Output.Trim())" }
  return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Save-AicmNpmView([string[]]$Arguments) {
  $r = Invoke-AicmWithTimeout 'npm' (@('view') + $Arguments + @('--json')) 90
  if ($r.ExitCode -ne 0) { throw "npm view $($Arguments -join ' ') failed: $($r.Output.Trim())" }
  $file = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($file, $r.Output)
  return $file
}

# npm leaves its staging folders (node_modules\.<name>-XXXXXXXX) behind when an install fails half way;
# on this tool's first test machine one of them was 238 MB. Removes those older than a day.
function Remove-AicmNpmLeftovers {
  $prefix = (Get-AicmNpmInfo).Prefix
  if (-not $prefix) { return }
  $root = Join-Path $prefix 'node_modules'
  if (-not (Test-Path -LiteralPath $root)) { $root = Join-Path $prefix 'lib\node_modules' }
  if (-not (Test-Path -LiteralPath $root)) { return }
  $cutoff = (Get-Date).AddDays(-1)
  $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  foreach ($d in ([System.IO.DirectoryInfo]::new($root)).GetDirectories()) {
    if (Test-AicmLink $d) { continue }
    if ($d.Name.StartsWith('@')) { foreach ($s in $d.GetDirectories()) { $dirs.Add($s) } } else { $dirs.Add($d) }
  }
  foreach ($d in $dirs) {
    if ($d.Name -notmatch '^\.[^.].*-[A-Za-z0-9]{8}$' -or (Test-AicmLink $d) -or $d.LastWriteTime -gt $cutoff) { continue }
    $bytes = 0L
    foreach ($f in (Get-AicmFiles $d.FullName)) { $bytes += $f.Length }
    try { Remove-AicmTree $d; Write-Host "removed npm leftover $($d.FullName) ($(Format-AicmSize $bytes))" }
    catch { Write-Host "kept npm leftover $($d.FullName) (in use)" }
  }
}

# The version to install: the newest stable release that is at least N days old ('' when none is).
function Get-AicmNpmTarget([string]$Package, [int]$MinAgeDays) {
  if ($MinAgeDays -le 0) {
    $r = Invoke-AicmWithTimeout 'npm' @('view', $Package, 'version') 60
    return (Get-AicmSemver $r.Output)
  }
  $view = Save-AicmNpmView @($Package, 'time', 'dist-tags')
  try { return (@(Invoke-AicmNpmGuard @('pick', "$MinAgeDays", $view)) | Select-Object -First 1) }
  finally { Remove-Item -LiteralPath $view -Force -ErrorAction SilentlyContinue }
}

# Throws when the candidate looks unlike the installed release or fails the registry signature check.
function Test-AicmNpmRelease([string]$Package, [string]$Installed, [string]$Target) {
  $allowed = @(($env:AICM_ALLOW -split ',') | ForEach-Object { $_.Trim() }) -contains "$Package@$Target"
  if ($Installed) {
    $old = Save-AicmNpmView @("$Package@$Installed")
    $new = Save-AicmNpmView @("$Package@$Target")
    try { $flags = @(Invoke-AicmNpmGuard @('compare', $old, $new)) }
    finally { Remove-Item -LiteralPath $old, $new -Force -ErrorAction SilentlyContinue }
    foreach ($f in $flags) { Write-Host "red flag: $Package $f" }
    if ($flags.Count -gt 0 -and -not $allowed) {
      throw "blocked $Package@$Target ($($flags -join '; ')). If this is expected, set AICM_ALLOW=$Package@$Target"
    }
  }
  if ($env:AICM_VERIFY_SIGNATURES -eq '0') { return }
  $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-stage-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  try {
    # --ignore-scripts: nothing from the candidate runs before it has passed the checks.
    $r = Invoke-AicmWithTimeout 'npm' @('install', "$Package@$Target", '--prefix', $stage, '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error') 900
    if ($r.ExitCode -ne 0) { throw "staged install of $Package@$Target failed: $($r.Output.Trim())" }
    $r = Invoke-AicmWithTimeout 'npm' @('audit', 'signatures', '--prefix', $stage) 300
    $summary = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() }) -join ' / '
    if ($r.ExitCode -ne 0) { throw "signature check failed for $Package@${Target}: $summary" }
    Write-Host "signatures ok: $summary"
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# Node.js modules (worktrees, config drift, processes), shared with macOS/Linux
# ---------------------------------------------------------------------------

# Runs lib\<Module>.js and prints its output. Returns .Lines (output without attention lines) and
# .Attention (the "attention:" lines, for notifications).
function Invoke-AicmNodeModule([string]$Module, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 900) {
  if (-not (Resolve-AicmExecutable 'node')) {
    Write-Host "${Module}: Node.js not found, skipped"
    return [pscustomobject]@{ Lines = @(); Attention = @() }
  }
  $script = Join-Path (Get-AicmRoot) "lib\$Module.js"
  $r = Invoke-AicmWithTimeout 'node' (@($script) + $Arguments) $TimeoutSeconds
  $lines = @($r.Output -split "`r?`n" | Where-Object { $_ -ne '' })
  foreach ($l in $lines) { Write-Host $l }
  $attention = @($lines | Where-Object { $_ -like 'attention: *' } | ForEach-Object { $_.Substring(11) })
  if ($r.ExitCode -ne 0) { $attention += "${Module} failed with exit code $($r.ExitCode)" }
  return [pscustomobject]@{ Lines = @($lines | Where-Object { $_ -notlike 'attention: *' }); Attention = $attention }
}
