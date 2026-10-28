# Shared helpers for AI CLI Auto Manager on Windows.
# Dot-source this file; it defines functions only and has no side effects.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts with the ANSI code page.

function Get-AicmRoot {
  return (Split-Path -Parent $PSScriptRoot)
}

# Text the manager writes and reads itself (SOURCE, VERSION, .aicm-copy, state JSON, the marker) is
# UTF-8 without a BOM on every PowerShell. Windows PowerShell 5.1 would otherwise read BOM-less files
# with the ANSI code page and garble a non-ASCII path such as a Korean user name (a BOM, if present,
# is still recognized when reading).
$script:AicmUtf8 = New-Object System.Text.UTF8Encoding($false)
function Write-AicmUtf8Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $script:AicmUtf8) }
function Read-AicmUtf8Text([string]$Path) { return [System.IO.File]::ReadAllText($Path, $script:AicmUtf8) }
function Read-AicmUtf8Lines([string]$Path) { return [System.IO.File]::ReadAllLines($Path, $script:AicmUtf8) }
# The first line, trimmed; '' when the file is missing, empty or unreadable.
function Read-AicmUtf8FirstLine([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { $lines = @(Read-AicmUtf8Lines $Path) } catch { return '' }
  if ($lines.Count -eq 0) { return '' }
  return $lines[0].Trim().TrimStart([char]0xFEFF)
}

function Get-AicmVersion {
  $v = Read-AicmUtf8FirstLine (Join-Path (Get-AicmRoot) 'VERSION')
  if ($v) { return $v }
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
  # Codex reads CODEX_HOME, so its sessions and database live there when it is set.
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path (Get-AicmUserHome) '.codex' }
  $p = $p.Replace('{codex}', $codexHome)
  $p = $p.Replace('{temp}', (Get-AicmTempDir))
  $p = $p.Replace('{localappdata}', (Get-AicmLocalAppData))
  $p = $p.Replace('{cache}', (Get-AicmLocalAppData))
  return [System.IO.Path]::GetFullPath($p.Replace('/', '\'))
}

function Test-AicmUnder([string]$Path, [string]$Root) {
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + $sep
  $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + $sep
  return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-AicmSamePath([string]$A, [string]$B) {
  $x = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
  $y = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
  return [string]::Equals($x, $y, [System.StringComparison]::OrdinalIgnoreCase)
}

# Expands 8.3 short names (C:\Users\JOHNDO~1\...) so paths compare by their real long names.
function Get-AicmLongPath([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  if ($full -notmatch '~') { return $full }
  $root = [System.IO.Path]::GetPathRoot($full)
  $out = $root.TrimEnd('\')
  foreach ($part in $full.Substring($root.Length).Split('\')) {
    if (-not $part) { continue }
    $next = Join-Path $out $part
    if ($part -match '~') {
      # The search pattern matches short names too and returns the long one.
      try { $hit = @([System.IO.Directory]::GetFileSystemEntries(($out + '\'), $part)) } catch { $hit = @() }
      if ($hit.Count -eq 1) { $next = $hit[0] }
    }
    $out = $next.TrimEnd('\')
  }
  return $out
}

# The temp folder counts as a cleanup area only when it really is a temp folder: never a drive root,
# the home folder or a folder above it, and it must sit under %LOCALAPPDATA% or be named Temp/tmp.
# A TEMP variable pointing at C:\ or C:\Users would otherwise let the os-temp rule sweep the home folder.
function Test-AicmTempUsable {
  $temp = Get-AicmLongPath (Get-AicmTempDir)
  $userHome = Get-AicmLongPath (Get-AicmUserHome)
  if ([System.IO.Path]::GetPathRoot($temp).TrimEnd('\') -eq $temp) { return $false }
  if (Test-AicmUnder $userHome $temp) { return $false }
  if (@('temp', 'tmp') -contains (Split-Path -Leaf $temp).ToLowerInvariant()) { return $true }
  return (Test-AicmUnder $temp (Get-AicmLongPath (Get-AicmLocalAppData)))
}

# A rule may only touch the home folder (never the home folder itself) or the temp folder.
# $FromTemp: the rule's path is written with {temp}; it is allowed only while TEMP looks right.
function Test-AicmAllowedPath([string]$Path, [bool]$FromTemp = $false) {
  if (Test-AicmPathHasLink $Path) { return $false }
  $p = Get-AicmLongPath $Path
  $userHome = Get-AicmLongPath (Get-AicmUserHome)
  # The home folder itself, or anything above it, never.
  if (Test-AicmUnder $userHome $p) { return $false }
  $inTemp = (Test-AicmUnder $p (Get-AicmLongPath (Get-AicmTempDir))) -and (Test-AicmTempUsable)
  if ($FromTemp) { return $inTemp }
  return ($inTemp -or (Test-AicmUnder $p $userHome))
}

$script:AicmProtectedNames = @(
  'MEMORY.md', 'CLAUDE.md', 'AGENTS.md', 'GEMINI.md',
  'auth.json', '.credentials.json', 'credentials.json', 'credentials',
  'settings.json', 'settings.local.json', 'config.toml', 'config.json', 'config.yaml',
  '.env', '.npmrc', '.netrc'
)
# Keys and certificates, wherever a tool happened to put them.
$script:AicmProtectedPatterns = @('*.env', '*.pem', '*.key', 'id_rsa*', 'id_ed25519*', 'id_ecdsa*', 'id_dsa*')

function Test-AicmProtected([System.IO.FileSystemInfo]$Item) {
  foreach ($name in $script:AicmProtectedNames) {
    if ([string]::Equals($Item.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  foreach ($pattern in $script:AicmProtectedPatterns) { if ($Item.Name -like $pattern) { return $true } }
  if ($Item.FullName -match '[\\/]memory(?:[\\/]|$)') { return $true }
  return $false
}

function Test-AicmLink([System.IO.FileSystemInfo]$Item) {
  return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Check every existing component, including the root supplied by a cleanup rule.
# Lexical containment alone does not stop home\junction\cache escaping the home.
# An unreadable component is unsafe too; never guess when checking a deletion path.
function Test-AicmPathHasLink([string]$Path) {
  $current = [System.IO.Path]::GetFullPath($Path)
  while ($current) {
    try {
      $attributes = [System.IO.File]::GetAttributes($current)
      if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
    } catch [System.IO.FileNotFoundException] {
    } catch [System.IO.DirectoryNotFoundException] {
    } catch { return $true }
    $current = [System.IO.Path]::GetDirectoryName($current.TrimEnd('\'))
  }
  return $false
}

# Enumerates files below $Root without ever entering a symlink or junction.
function Get-AicmFiles([string]$Root, [string]$Pattern = '*', [switch]$TopOnly) {
  if (Test-AicmPathHasLink $Root) { return }
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

# Budget scan bounds (AICM_BUDGET_MAX_FILES, AICM_BUDGET_MAX_DEPTH, AICM_BUDGET_SCAN_SECONDS).
function Get-AicmBudgetBound([string]$Name, [int]$Default) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ($v -match '^[1-9][0-9]{0,8}$') { return [int]$v }
  return $Default
}

# SQLite database files and sidecars (also a lone -wal/-shm/-journal) never go by budget.
function Test-AicmBudgetSqliteName([string]$Name) {
  return ($Name -match '\.(sqlite\d*|db)$' -or $Name -match '\.sqlite\d' -or $Name -match '-(wal|shm|journal)$')
}

# Every ordinary file below $Root for a budget rule: links are neither entered nor counted. The status
# is complete, partial (an unreadable folder, or the time, depth or file-count bound was reached) or
# unavailable (the root itself cannot be read). An unreadable folder is never counted as empty.
function Get-AicmBudgetScan([string]$Root, [int]$MaxFiles, [int]$MaxDepth, [int]$MaxSeconds) {
  $result = [ordered]@{ status = 'complete'; count = 0; bytes = 0L; files = (New-Object System.Collections.Generic.List[System.IO.FileInfo]) }
  $top = [System.IO.DirectoryInfo]::new($Root)
  try {
    if (-not $top.Exists -or (Test-AicmLink $top)) { $result.status = 'unavailable'; return $result }
    [void]$top.GetFileSystemInfos()
  } catch { $result.status = 'unavailable'; return $result }
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push(@($top, 0))
  while ($stack.Count -gt 0) {
    $entry = $stack.Pop()
    $dir = $entry[0]; $depth = [int]$entry[1]
    if ($clock.Elapsed.TotalSeconds -gt $MaxSeconds) { $result.status = 'partial'; break }
    $children = $null
    try { $children = $dir.GetFileSystemInfos() } catch { $result.status = 'partial'; continue }
    if ($depth + 1 -gt $MaxDepth) {
      if (@($children).Count -gt 0) { $result.status = 'partial' }
      continue
    }
    foreach ($child in $children) {
      if (Test-AicmLink $child) { continue }
      if ($child -is [System.IO.DirectoryInfo]) { $stack.Push(@($child, ($depth + 1))); continue }
      $result.count++
      if ($result.count -gt $MaxFiles) { $result.status = 'partial'; break }
      $result.bytes += [int64]$child.Length
      $result.files.Add($child)
    }
    if ($result.count -gt $MaxFiles) { break }
  }
  return $result
}

# Keeps an independent-file cache at or below Limit MiB of logical bytes (see run_budget_rule in
# bin/clean_ai_leftovers.sh). Every ordinary file counts toward the total; only files matching the
# pattern, older than Days, not protected and not SQLite are candidates, oldest modification time first
# (not least recently used). Nothing is deleted after a scan that is not complete. $Delete gets each
# chosen FileInfo after it was checked again (same size and time, no link below the root) and returns
# $true only when the file is gone; a busy, multiply linked or changed file must return $false.
# A preview does not open files, so its projection assumes the candidates are not in use.
function Invoke-AicmBudget($Rule, [string]$Root, [bool]$DryRun, [scriptblock]$Delete) {
  $budget = [int64]$Rule.Limit * 1MB
  $r = [ordered]@{ files = 0; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0; totalBytes = 0L; budgetBytes = $budget; remainingBytes = 0L; projectedRemainingBytes = 0L; budgetUnmetBytes = 0L; scanStatus = 'unavailable'; detail = '' }
  $maxFiles = Get-AicmBudgetBound 'AICM_BUDGET_MAX_FILES' 200000
  $maxDepth = Get-AicmBudgetBound 'AICM_BUDGET_MAX_DEPTH' 32
  $maxSeconds = Get-AicmBudgetBound 'AICM_BUDGET_SCAN_SECONDS' 300
  $scan = Get-AicmBudgetScan $Root $maxFiles $maxDepth $maxSeconds
  $r.scanStatus = $scan.status; $r.totalBytes = [int64]$scan.bytes
  $r.remainingBytes = $r.totalBytes; $r.projectedRemainingBytes = $r.totalBytes
  if ($scan.status -ne 'complete') {
    $r.detail = "budget scan $($scan.status) (unreadable entries or a scan bound): nothing deleted by the budget"
    if ($r.totalBytes -gt $budget) { $r.budgetUnmetBytes = $r.totalBytes - $budget }
    return $r
  }
  if ($r.totalBytes -le $budget) { return $r }
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-[int]$Rule.Days)
  $cands = @($scan.files | Where-Object {
      $_.Name -like $Rule.Pattern -and $_.LastWriteTimeUtc -lt $cutoff -and $_.Length -gt 0 -and
      -not (Test-AicmProtected $_) -and -not (Test-AicmBudgetSqliteName $_.Name)
    } | Sort-Object -Property @{ Expression = { $_.LastWriteTimeUtc.Ticks } }, @{ Expression = { $_.FullName } } -CaseSensitive)
  $remaining = $r.totalBytes
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  foreach ($f in $cands) {
    if ($remaining -le $budget) { break }
    $size = [int64]$f.Length; $when = $f.LastWriteTimeUtc
    $r.files++; $r.bytes += $size
    if ($DryRun) { $remaining -= $size; continue }
    # The rule folder must still be a real folder (not moved away and replaced by a link).
    $rootNow = [System.IO.DirectoryInfo]::new($rootFull)
    if (-not $rootNow.Exists -or (Test-AicmLink $rootNow)) {
      $r.inUse++; $r.scanStatus = 'partial'
      $r.detail = 'the rule folder changed during the run (moved or replaced by a link): nothing more deleted'
      break
    }
    $ok = $false
    try {
      $f.Refresh()
      $same = $f.Exists -and -not (Test-AicmLink $f) -and ([int64]$f.Length -eq $size) -and ($f.LastWriteTimeUtc -eq $when) -and (Test-AicmUnder $f.FullName $rootFull)
      if ($same) {
        $parent = $f.Directory
        while ($same -and $parent -and $parent.FullName.TrimEnd('\', '/').Length -gt $rootFull.Length) {
          if (Test-AicmLink $parent) { $same = $false }
          $parent = $parent.Parent
        }
      }
      if ($same) { $ok = [bool](& $Delete $f) }
    } catch { $ok = $false }
    if ($ok) { $r.removed++; $r.removedBytes += $size; $remaining -= $size } else { $r.inUse++ }
  }
  $r.projectedRemainingBytes = $remaining
  $left = $remaining
  if (-not $DryRun) {
    [void](Remove-AicmEmptyDirs $Root)
    # What is really left, counted again (other programs may have written meanwhile).
    $again = Get-AicmBudgetScan $Root $maxFiles $maxDepth $maxSeconds
    if ($r.scanStatus -eq 'complete' -and $again.status -eq 'complete') { $r.remainingBytes = [int64]$again.bytes }
    else { $r.remainingBytes = $remaining; $r.scanStatus = 'partial' }
    $left = $r.remainingBytes
  }
  if ($left -gt $budget) {
    $r.budgetUnmetBytes = $left - $budget
    if (-not $r.detail) { $r.detail = "budget not reachable: $(Format-AicmSize $r.budgetUnmetBytes) above it is recent, protected, linked, SQLite or in use" }
  }
  return $r
}

# Management only: removes an installed copy or owned test workspace, including readonly files.
# An explicitly selected management root may be an alias; links BELOW it are never traversed.
# User-data cleanup must use Remove-CleanupTree instead.
function Remove-AicmTree([System.IO.DirectoryInfo]$Dir, [string]$TrustedRoot = '') {
  if ($TrustedRoot -and -not (Test-AicmUnder $Dir.FullName $TrustedRoot)) {
    throw "tree is outside its management root : $($Dir.FullName)"
  }
  $parent = if ($Dir.Parent) { $Dir.Parent.FullName } else { '' }
  while ($parent -and -not ($TrustedRoot -and (Test-AicmSamePath $parent $TrustedRoot))) {
    if ([System.IO.File]::GetAttributes($parent) -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "refusing tree cleanup through a linked parent : $($Dir.FullName)"
    }
    $parent = [System.IO.Path]::GetDirectoryName($parent.TrimEnd('\'))
  }
  if (Test-AicmLink $Dir) {
    [System.IO.Directory]::Delete($Dir.FullName, $false)
    return
  }
  foreach ($child in $Dir.GetFileSystemInfos()) {
    if ($child -is [System.IO.DirectoryInfo]) {
      Remove-AicmTree $child $TrustedRoot
    } else {
      if (-not (Test-AicmLink $child) -and ($child.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
        $child.Attributes = $child.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
      }
      $child.Delete()
    }
  }
  $Dir.Delete($false)
}

# Removes empty folders below $Root, deepest first. $Root itself, links and "memory" folders are kept.
function Remove-AicmEmptyDirs([string]$Root) {
  if (Test-AicmPathHasLink $Root) { return 0 }
  $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push([System.IO.DirectoryInfo]::new($Root))
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $subs = $null
    try { $subs = $dir.GetDirectories() } catch { continue }
    foreach ($sub in $subs) {
      if ((Test-AicmLink $sub) -or $sub.Name -ieq 'memory') { continue }
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
  if (@('age', 'age-files', 'cap', 'budget', 'keep-latest', 'command', 'archive', 'codex') -notcontains $kind) { throw "invalid rule kind '$kind' in ${Source}: $t" }
  $default = $cols[7].ToLowerInvariant()
  if (@('on', 'off') -notcontains $default) { throw "invalid default '$default' in ${Source}: $t" }
  $days = 0
  if ($cols[5]) { $days = [int]$cols[5] }
  $limit = 0
  if ($cols[6]) { $limit = [int]$cols[6] }
  if (@('age', 'age-files') -contains $kind -and $days -lt 1) { throw "$kind rule needs days >= 1 in ${Source}: $t" }
  if ($kind -eq 'budget' -and ($days -lt 1 -or $limit -lt 1)) { throw "budget rule needs days >= 1 (minimum age) and limit >= 1 (total MiB) in ${Source}: $t" }
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

# id -> category. Ids missing from the map are "other" (custom and local rules).
function Get-AicmCategoryMap {
  $existing = Get-Variable -Name AicmCategoryMap -Scope Script -ErrorAction SilentlyContinue
  if ($existing -and $existing.Value) { return $existing.Value }
  $map = @{}
  $file = Join-Path (Get-AicmRoot) 'rules\clean-categories.conf'
  if (-not (Test-Path -LiteralPath $file)) { throw "category map missing: $file" }
  foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $cols = @($line.Split('|') | ForEach-Object { $_.Trim() })
    if ($cols.Count -lt 2 -or -not $cols[0] -or -not $cols[1]) { throw "invalid category row: $t" }
    $id = $cols[0]
    $cat = $cols[1].ToLowerInvariant()
    if (@('sessions', 'cache', 'logs', 'temp', 'other') -notcontains $cat) { throw "invalid category '$cat' for $id" }
    if ($map.ContainsKey($id)) { throw "duplicate category id: $id" }
    $map[$id] = $cat
  }
  $script:AicmCategoryMap = $map
  return $map
}

function Get-AicmRuleCategory([string]$Id) {
  $map = Get-AicmCategoryMap
  if ($map.ContainsKey($Id)) { return [string]$map[$Id] }
  return 'other'
}

# Normalized names. Empty input returns an empty array. "all" cannot be combined.
function ConvertTo-AicmCategoryList([string]$Text) {
  if (-not $Text -or -not $Text.Trim()) { return @() }
  if ($Text.Trim().StartsWith(',') -or $Text.Trim().EndsWith(',')) { throw "empty category in '$Text'" }
  $seen = @{}
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($part in ($Text -split ',')) {
    $tok = $part.Trim().ToLowerInvariant()
    if (-not $tok) { throw "empty category in '$Text'" }
    if (@('sessions', 'cache', 'logs', 'temp', 'other', 'all') -notcontains $tok) { throw "unknown category: $tok" }
    if ($seen.ContainsKey($tok)) { throw "duplicate category: $tok" }
    $seen[$tok] = $true
    $out.Add($tok)
  }
  if ($seen.ContainsKey('all') -and $out.Count -gt 1) { throw "category 'all' cannot be combined with other categories" }
  return @($out.ToArray())
}

function Get-AicmProtectionPolicy {
  return 'never removes memory, credentials, settings or keys'
}

function Get-AicmRuleAction([string]$Kind, [int]$Limit) {
  switch ($Kind) {
    'archive' { return 'archive' }
    'codex' { if ($Limit -eq 0) { return 'delete' } else { return 'archive' } }
    'command' { return 'run' }
    'keep-latest' { return 'keep' }
    default { return 'delete' }
  }
}

function Get-AicmRuleReason($Rule) {
  $reason = [string]$Rule.Note
  if ($Rule.Kind -eq 'archive') {
    $eff = Get-AicmArchiveDays $Rule
    if ($eff -ne $Rule.Days) {
      $native = Get-AicmNativeRetentionDays $Rule.Id
      $extra = "archive after ${eff}d (the CLI deletes after ${native}d)"
      if ($reason) { $reason = "$reason; $extra" } else { $reason = $extra }
    }
  }
  if (-not $reason) {
    $reason = [string]$Rule.Kind
    if ([int]$Rule.Days -ne 0) { $reason = "$reason after $($Rule.Days)d" }
  }
  return $reason
}

# Writes to a temp file and swaps it in, so a crash mid-write never leaves a half-written state file.
function Write-AicmState([string]$Name, $Object) {
  $dir = Join-Path (Get-AicmHome) 'state'
  Initialize-AicmDirectory $dir
  $file = Join-Path $dir "$Name.json"
  $tmp = "$file.$PID.tmp"
  Write-AicmUtf8Text $tmp (($Object | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
  if (Test-Path -LiteralPath $file) { [System.IO.File]::Replace($tmp, $file, [NullString]::Value) }
  else { [System.IO.File]::Move($tmp, $file) }
}

function Read-AicmState([string]$Name) {
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') "$Name.json"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return ((Read-AicmUtf8Text $file) | ConvertFrom-Json) } catch { return $null }
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

# Desktop notification. Never fails the caller. Disable the desktop part with AICM_NOTIFY=0.
# Every notification is also appended to logs\notifications.log (last 500 lines kept), so one that
# never showed on screen can still be read with `aicm.ps1 status`.
function Send-AicmNotification([string]$Title, [string]$Body) {
  Write-Host "notify: $Title - $Body"
  try {
    $dir = Join-Path (Get-AicmHome) 'logs'
    Initialize-AicmDirectory $dir
    $log = Join-Path $dir 'notifications.log'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($log, ("{0} {1} - {2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Title, ($Body -replace "`r?`n", ' ')), $utf8)
    $lines = [System.IO.File]::ReadAllLines($log, $utf8)
    if ($lines.Count -gt 600) { [System.IO.File]::WriteAllLines($log, [string[]]($lines[($lines.Count - 500)..($lines.Count - 1)]), $utf8) }
  } catch { }
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

# User-data archival refuses linked ancestors, including a linked management home.
# Management-copy synchronization has its own explicit junction exception.
function Test-AicmArchiveDest([string]$Path) {
  if (-not $Path) { return $false }
  $archive = [System.IO.Path]::GetFullPath((Get-AicmArchiveRoot)).TrimEnd('\')
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not ((Test-AicmSamePath $full $archive) -or (Test-AicmUnder $full $archive))) { return $false }
  return (-not (Test-AicmPathHasLink $full))
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

# Codex threads from its state DB (read-only): id -> last update (unix seconds, 0 = unknown), archived.
# Needs Python with sqlite3; returns $null when that is not available or the layout is unknown.
function Get-AicmCodexThreads([string]$CodexHome) {
  if ($env:AICM_CODEX_DB_READER -eq '0') { return $null }
  $db = Get-ChildItem -LiteralPath $CodexHome -Filter 'state_*.sqlite' -File -ErrorAction SilentlyContinue |
    Sort-Object { [int](($_.BaseName -split '_')[-1]) } -Descending | Select-Object -First 1
  if (-not $db) { return $null }
  $python = @('python', 'python3', 'py') | Where-Object { Resolve-AicmExecutable $_ } | Select-Object -First 1
  if (-not $python) { return $null }
  # Stops (exit 3) when the table lacks the expected columns, so an unknown layout is never guessed at.
  $code = "import sqlite3,sys`ncon=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)`ncols={r[1] for r in con.execute('pragma table_info(threads)')}`nif not {'id','updated_at'} <= cols: sys.exit(3)`narch='archived' if 'archived' in cols else '0'`nfor r in con.execute('select id, updated_at, '+arch+' from threads'):`n    print('\t'.join('' if v is None else str(v) for v in r))"
  $script = [System.IO.Path]::GetTempFileName() + '.py'
  [System.IO.File]::WriteAllText($script, $code)
  try {
    $r = Invoke-AicmWithTimeout $python @($script, $db.FullName) 120
    if ($r.ExitCode -ne 0) { return $null }
    $threads = @{}
    foreach ($line in ($r.StdOut -split "`r?`n")) {
      $c = $line.Split("`t")
      if ($c.Count -lt 3 -or -not $c[0]) { continue }
      # Only unix seconds or milliseconds; anything else (a date text) leaves Updated at 0 = unknown.
      $u = 0.0
      if ($c[1] -match '^\d+(\.\d+)?$') { [void][double]::TryParse($c[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$u) }
      if ($u -gt 1e11) { $u = $u / 1000 }
      $threads[$c[0]] = [pscustomobject]@{ Updated = $u; Archived = ($c[2] -eq '1') }
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

# ---------------------------------------------------------------------------
# Ownership of AICM_HOME. The tool writes only these top-level entries: app (app.new, app.old while
# swapping), logs, state, archive and inventory.md, plus the .aicm-home marker. Users may add hooks,
# *.local.conf, repos.conf and update-policy.json. A folder that holds anything else, or a reserved
# entry with content the tool did not write (app\personal.txt), is never adopted, and nothing in it
# is replaced or removed. The marker alone does not whitelist content: every reserved entry is
# checked again before a copy swap, an uninstall or a purge removes it. AICM_HOME itself may be a
# junction or link chosen on purpose; links and junctions in the reserved entries are refused.
# ---------------------------------------------------------------------------
$script:AicmHomeMarkerText = 'AI CLI Auto Manager home (logs, state, archive, installed copy)'
$script:AicmHomeProblem = ''
$script:AicmHomeReserved = @('app', 'app.new', 'app.old', 'logs', 'state', 'archive', 'inventory.md')
$script:AicmOsJunk = @('.DS_Store', 'desktop.ini', 'Thumbs.db')

function Get-AicmEntries([string]$Dir) {
  try { return @([System.IO.DirectoryInfo]::new($Dir).GetFileSystemInfos()) } catch { return @() }
}

function Test-AicmHomeUserName([string]$Name) {
  if (@('.aicm-home', 'hooks', 'repos.conf', 'update-policy.json') -contains $Name) { return $true }
  if ($script:AicmOsJunk -contains $Name) { return $true }
  return ($Name -like '*.local.conf')
}

function Test-AicmRealDir($Item) { return ($Item -is [System.IO.DirectoryInfo] -and -not (Test-AicmLink $Item)) }
function Test-AicmRealFile($Item) { return ($Item -is [System.IO.FileInfo] -and -not (Test-AicmLink $Item)) }

# A marker the tool wrote: a small regular file whose first line is the marker text.
function Test-AicmHomeMarker([string]$HomeDir) {
  $item = Get-Item -LiteralPath (Join-Path $HomeDir '.aicm-home') -Force -ErrorAction SilentlyContinue
  if (-not (Test-AicmRealFile $item) -or $item.Length -gt 1024) { return $false }
  try { $lines = @([System.IO.File]::ReadAllLines($item.FullName, (New-Object System.Text.UTF8Encoding($false)))) } catch { return $false }
  return ($lines.Count -ge 1 -and $lines[0].TrimEnd("`r") -ceq $script:AicmHomeMarkerText)
}

# A file name the tool ships in bin, lib, rules or windows (used only for copies built before the copy
# kept its own file list in .aicm-copy). $Rel uses '/'.
function Test-AicmAppFileShape([string]$Rel) {
  $known = @(
    'bin/aicm', 'bin/aicm.ps1', 'bin/clean_ai_leftovers.ps1', 'bin/clean_ai_leftovers.sh', 'bin/inventory_ai_clis.ps1', 'bin/inventory_ai_clis.sh', 'bin/update_ai_clis.ps1', 'bin/update_ai_clis.sh',
    'lib/aicm-common.ps1', 'lib/aicm-common.sh', 'lib/aicm-scheduler.ps1', 'lib/aicm-file-guard.cs', 'lib/aicm-job.cs', 'lib/aicm-process-token.cs', 'lib/auto-maintenance.js', 'lib/codex-host.sh', 'lib/config-drift.js', 'lib/maintenance-cli.js', 'lib/maintenance-files.js', 'lib/maintenance-files.ps1', 'lib/maintenance-processes.js', 'lib/maintenance.js', 'lib/node-common.js', 'lib/npm-guard.js', 'lib/optimize.js', 'lib/processes.js', 'lib/supervise.js', 'lib/update-policy.js', 'lib/worktrees.js',
    'rules/ai-clis.conf', 'rules/clean-categories.conf', 'rules/clean-rules.conf', 'rules/maintenance.conf',
    'windows/install_scheduled_task.ps1', 'windows/run-hidden.vbs', 'windows/aicm-windowless.cs', 'windows/restore-schedule-backup.ps1',
    'windows/window-observer.cs', 'windows/check-scheduled-windows.ps1'
  )
  return $known -contains $Rel
}

# Relative paths ('/') of the files below bin, lib, rules and windows of $Dir; $null (with the reason in
# $script:AicmHomeProblem) when one of them is a link, junction or other special entry.
function Get-AicmCopyFiles([string]$Dir) {
  $base = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($d in 'bin', 'lib', 'rules', 'windows') {
    $top = Get-Item -LiteralPath (Join-Path $Dir $d) -Force -ErrorAction SilentlyContinue
    if (-not $top) { continue }
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push($top)
    while ($stack.Count -gt 0) {
      $cur = $stack.Pop()
      foreach ($c in $cur.GetFileSystemInfos()) {
        if (Test-AicmLink $c) { $script:AicmHomeProblem = "$($c.FullName) is a link, which an installed copy does not have"; return $null }
        if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) }
        else { $out.Add($c.FullName.Substring($base.Length + 1).Replace('\', '/')) }
      }
    }
  }
  return , $out.ToArray()
}

# An installed copy this tool built: a real folder with only the entries a copy has, and below bin, lib,
# rules and windows only regular files the copy was built with (listed in its .aicm-copy; a copy from an
# older version without that list: files its source checkout or this checkout also has, or files named
# like the tool's own). app and app.old also need SOURCE and VERSION; a half-built app.new (-Partial)
# may still lack them.
function Test-AicmAppCopyOwned([string]$Dir, [switch]$Partial) {
  $item = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
  if (-not (Test-AicmRealDir $item)) { $script:AicmHomeProblem = "$Dir is not a real folder"; return $false }
  foreach ($c in (Get-AicmEntries $Dir)) {
    if (@('bin', 'lib', 'rules', 'windows') -contains $c.Name) {
      if (-not (Test-AicmRealDir $c)) { $script:AicmHomeProblem = "$($c.FullName) is not a real folder"; return $false }
    } elseif (@('VERSION', 'LICENSE', 'README.md', 'SOURCE', '.aicm-copy') -contains $c.Name) {
      if (-not (Test-AicmRealFile $c)) { $script:AicmHomeProblem = "$($c.FullName) is not a regular file"; return $false }
    } elseif ($script:AicmOsJunk -notcontains $c.Name) {
      $script:AicmHomeProblem = "$Dir holds $($c.Name), which an installed copy does not have"
      return $false
    }
  }
  if (-not $Partial -and -not ((Test-Path -LiteralPath (Join-Path $Dir 'SOURCE') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $Dir 'VERSION') -PathType Leaf))) {
    $script:AicmHomeProblem = "$Dir has no SOURCE and VERSION files, so it is not an installed copy"
    return $false
  }
  $files = Get-AicmCopyFiles $Dir
  if ($null -eq $files) { return $false }
  $listFile = Join-Path $Dir '.aicm-copy'
  $listed = $null
  $source = ''
  if (Test-Path -LiteralPath $listFile -PathType Leaf) {
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($l in (Read-AicmUtf8Lines $listFile)) { if ($l) { [void]$listed.Add($l.Trim()) } }
  } else {
    $source = Read-AicmUtf8FirstLine (Join-Path $Dir 'SOURCE')
    if (-not $source -or -not [System.IO.Path]::IsPathRooted($source) -or -not (Test-Path -LiteralPath $source -PathType Container)) { $source = '' }
    if ($source -and ((Test-AicmPathHasLink $source) -or (Test-AicmSamePath $source $Dir))) { $source = '' }
  }
  $selfRoot = Test-AicmSamePath (Get-AicmRoot) $Dir
  foreach ($rel in $files) {
    if ($listed) { if ($listed.Contains($rel)) { continue } }
    elseif (($source -and (Test-Path -LiteralPath (Join-Path $source $rel) -PathType Leaf)) -or
      (-not $selfRoot -and (Test-Path -LiteralPath (Join-Path (Get-AicmRoot) $rel) -PathType Leaf)) -or (Test-AicmAppFileShape $rel)) { continue }
    $script:AicmHomeProblem = "$(Join-Path $Dir $rel) is not part of the installed copy"
    return $false
  }
  return $true
}

# Names the tool gives files in logs\ (logs, transcripts, cron/launchd output and their temp files).
function Test-AicmLogName([string]$Name) {
  foreach ($p in 'maintenance-[0-9]*.jsonl', 'maintenance-[0-9]*.txt', 'update-[0-9]*.log', 'clean-[0-9]*.log', 'inventory-[0-9]*.log', 'latest.log', 'notifications.log',
    'cron.update.log', 'cron.inventory.log', 'cron.clean.log', 'cron.maintenance.log', 'launchd.*.out.log', 'launchd.*.err.log', '*.log.[0-9]*.tmp') {
    if ($Name -like $p) { return $true }
  }
  return $false
}

# Names the tool gives files directly in state\.
function Test-AicmStateFileName([string]$Name) {
  if ($Name -like '.weekly-due.[0-9]*' -or $Name -like '.schedule-time.[0-9]*') { return $true }
  $n = $Name -replace '\.\d+\.tmp$', ''
  if (@('last-update.json', 'last-clean.json', 'last-maintenance.json', 'inventory.json', 'schedule.json', 'npm-verdicts.json', 'npm-verdicts.tsv',
    'update-running.json', 'update-npm.json', 'update-npm.tsv', 'update-deferred.json', 'inventory-error.json',
    'inventory.tsv', 'inventory-shadow.txt', 'config-drift.json', 'processes.json', 'worktrees.json') -contains $n) { return $true }
  foreach ($p in '*-attention.json', 'attention-*.tsv', 'attention-*.json') { if ($n -like $p) { return $true } }
  return $false
}

# Folders the tool keeps in state\ and the names it gives files there (manifests, history, lock).
function Test-AicmStateDirName([string]$Name) {
  return ((@('archive-index', 'history', 'sessions', 'maintenance.lock') -contains $Name) -or $Name -like 'maintenance.lock.stale-*')
}
function Test-AicmStateSubfileName([string]$Dir, [string]$Name) {
  if ($Dir -eq 'archive-index' -or $Dir -eq 'history') { return ($Name -cmatch '^\.?[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.json(\.[0-9]+\.[0-9a-f]+\.tmp)?$') }
  if ($Dir -eq 'sessions') { return ($Name -cmatch '^[a-f0-9-]{36}\.json$') }
  if ($Dir -like 'maintenance.lock*') { return ($Name -ceq 'owner.json' -or $Name -cmatch '^\.owner\.json\.[0-9]+\.[0-9a-f]+\.tmp$') }
  return $false
}

# A dated archive folder (archive\<rule>\<yyyymmdd>) holds only real folders and regular files.
function Test-AicmArchiveDay($Item) {
  if (-not (Test-AicmRealDir $Item) -or $Item.Name -notmatch '^\d{8}$') { return $false }
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push($Item)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try { $children = $dir.GetFileSystemInfos() } catch { return $false }
    foreach ($c in $children) {
      if (Test-AicmLink $c) { return $false }
      if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) }
    }
  }
  return $true
}

function Test-AicmInventoryFile($Item) {
  if (-not (Test-AicmRealFile $Item)) { return $false }
  try { $first = @([System.IO.File]::ReadAllLines($Item.FullName, (New-Object System.Text.UTF8Encoding($false))) | Select-Object -First 1) } catch { return $false }
  return ($first.Count -eq 1 -and "$($first[0])".TrimStart([char]0xFEFF) -clike '# AI CLI inventory*')
}

# True when every entry of reserved child $Name of $HomeDir is something the tool wrote.
function Test-AicmHomeChild([string]$HomeDir, [string]$Name) {
  $p = Join-Path $HomeDir $Name
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  switch ($Name) {
    { $_ -in 'app', 'app.old' } { return (Test-AicmAppCopyOwned $p) }
    'app.new' { return (Test-AicmAppCopyOwned $p -Partial) }
    'inventory.md' {
      if (Test-AicmInventoryFile $item) { return $true }
      $script:AicmHomeProblem = "$p was not written by the inventory"; return $false
    }
  }
  if (-not (Test-AicmRealDir $item)) { $script:AicmHomeProblem = "$p is not a real folder"; return $false }
  foreach ($c in (Get-AicmEntries $p)) {
    $ok = $false
    if ($Name -eq 'logs') { $ok = (Test-AicmRealFile $c) -and (Test-AicmLogName $c.Name) }
    elseif ($Name -eq 'state') {
      if ((Test-AicmRealDir $c) -and (Test-AicmStateDirName $c.Name)) {
        $ok = $true
        foreach ($s in (Get-AicmEntries $c.FullName)) {
          if (-not ((Test-AicmRealFile $s) -and (Test-AicmStateSubfileName $c.Name $s.Name))) { $script:AicmHomeProblem = "$($s.FullName) was not written by this tool"; return $false }
        }
      } else { $ok = (Test-AicmRealFile $c) -and (Test-AicmStateFileName $c.Name) }
    } elseif ($Name -eq 'archive') {
      if ((Test-AicmRealDir $c) -and $c.Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        $ok = $true
        foreach ($d in (Get-AicmEntries $c.FullName)) {
          if (-not (Test-AicmArchiveDay $d)) { $script:AicmHomeProblem = "$($d.FullName) is not a dated archive folder"; return $false }
        }
      }
    }
    if (-not $ok) { $script:AicmHomeProblem = "$($c.FullName) was not written by this tool"; return $false }
  }
  return $true
}

# missing | empty | owned (valid marker) | legacy (no marker, but only entries this tool writes or users
# add on purpose, each reserved one with content the tool wrote) | foreign (anything else; the reason is
# in $script:AicmHomeProblem). Reads only. The home folder itself may be a junction chosen on purpose.
function Get-AicmHomeStatus {
  $h = Get-AicmHome
  $script:AicmHomeProblem = ''
  # The profile folder itself, or a folder above it, is never the manager's folder, whatever marker it holds.
  $full = [System.IO.Path]::GetFullPath($h)
  $userHome = Get-AicmUserHome
  if ([System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/') -eq $full.TrimEnd('\', '/') -or
      ($userHome -and ((Test-AicmSamePath $userHome $full) -or (Test-AicmUnder $userHome $full)))) {
    $script:AicmHomeProblem = "$h is your profile folder or a folder above it"
    return 'foreign'
  }
  $item = Get-Item -LiteralPath $h -Force -ErrorAction SilentlyContinue
  if (-not $item) { return 'missing' }
  if ($item -isnot [System.IO.DirectoryInfo]) { $script:AicmHomeProblem = "$h is not a folder"; return 'foreign' }
  if (Test-AicmHomeMarker $h) { return 'owned' }
  $marker = Get-Item -LiteralPath (Join-Path $h '.aicm-home') -Force -ErrorAction SilentlyContinue
  if ($marker -and -not (Test-AicmRealFile $marker)) { $script:AicmHomeProblem = "$($marker.FullName) is not a regular file"; return 'foreign' }
  $entries = @(Get-AicmEntries $h)
  $evidence = $false
  foreach ($e in $entries) {
    if ($script:AicmHomeReserved -contains $e.Name) {
      if (-not (Test-AicmHomeChild $h $e.Name)) { return 'foreign' }
      if ($e.Name -eq 'app' -or $e.Name -eq 'app.old') { $evidence = $true }
    } elseif (-not (Test-AicmHomeUserName $e.Name)) {
      $script:AicmHomeProblem = "$h holds $($e.Name), which AI CLI Auto Manager did not create"
      return 'foreign'
    }
  }
  if ($entries.Count -eq 0) { return 'empty' }
  # Reserved names alone (a dated archive folder, a logs folder) prove nothing. An older install is
  # recognized by its installed copy; a folder with only user files (hooks, local rules) is safe to use.
  if ($evidence) { return 'legacy' }
  foreach ($e in $entries) {
    if ($script:AicmHomeReserved -contains $e.Name) {
      $script:AicmHomeProblem = "$h has no installed copy (app) that shows it is an AI CLI Auto Manager folder, but holds $($e.Name)"
      return 'foreign'
    }
  }
  return 'legacy'
}

function Get-AicmHomeRefusal {
  $why = if ($script:AicmHomeProblem) { $script:AicmHomeProblem } else { 'it is not an AI CLI Auto Manager folder' }
  return "refusing to use AICM_HOME=$(Get-AicmHome): $why. Point AICM_HOME at an empty or new folder, or move the entries this tool did not create out of it."
}

# What is running when another operation is in progress: an archive, restore or cleanup holding the
# maintenance lock, or an update or cleanup run holding its lock. '' otherwise.
function Get-AicmBusyOperation {
  $owner = Join-Path (Join-Path (Join-Path (Get-AicmHome) 'state') 'maintenance.lock') 'owner.json'
  $item = Get-Item -LiteralPath $owner -Force -ErrorAction SilentlyContinue
  if (Test-AicmRealFile $item) {
    $o = $null
    try { $o = (Read-AicmUtf8Text $owner) | ConvertFrom-Json } catch { }
    if ($o -and $o.PSObject.Properties['pid'] -and "$($o.pid)" -match '^\d+$' -and (Get-Process -Id ([int]$o.pid) -ErrorAction SilentlyContinue)) {
      return "an archive, restore or cleanup holds the maintenance lock (pid $($o.pid))"
    }
  }
  foreach ($kind in 'update', 'clean') {
    $m = $null
    try {
      $m = [System.Threading.Mutex]::new($false, (Get-AicmLockName $kind))
      $got = $false
      try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
      if (-not $got) { return "a $kind run is in progress" }
      $m.ReleaseMutex()
    } catch { } finally { if ($m) { $m.Dispose() } }
  }
  return ''
}

# Read-only check for commands that only write new logs (previews): throws for a foreign folder.
function Assert-AicmHomeUsable {
  if ((Get-AicmHomeStatus) -eq 'foreign') { throw (Get-AicmHomeRefusal) }
}

# Marks AICM_HOME as this tool's folder before a real run writes into it. A missing or empty folder and
# an unmarked folder of an older version that passes the structure check are marked; a foreign folder is
# refused (throws) and left exactly as it was.
function Confirm-AicmHome {
  $state = Get-AicmHomeStatus
  if ($state -eq 'owned') { return }
  if ($state -eq 'foreign') { throw (Get-AicmHomeRefusal) }
  $h = Get-AicmHome
  Initialize-AicmDirectory $h
  $marker = Join-Path $h '.aicm-home'
  $tmp = "$marker.$PID.tmp"
  Write-AicmUtf8Text $tmp "$($script:AicmHomeMarkerText)`r`n"
  if (Test-Path -LiteralPath $marker) { [System.IO.File]::Replace($tmp, $marker, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $marker) }
  if ($state -eq 'legacy') { [Console]::Error.WriteLine("note: $h holds only what this tool writes; marked it as the AI CLI Auto Manager home") }
}

# Archived files the index says this tool moved there: archive-relative path ('/') -> size, for records
# still holding their file (archived, pending, missing). Malformed records are ignored (their files stay).
function Get-AicmIndexedArchive([string]$HomeDir) {
  $map = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([System.StringComparer]::OrdinalIgnoreCase)
  $idx = Get-Item -LiteralPath (Join-Path (Join-Path $HomeDir 'state') 'archive-index') -Force -ErrorAction SilentlyContinue
  if (-not (Test-AicmRealDir $idx)) { return $map }
  foreach ($f in $idx.GetFiles('*.json')) {
    if ($f.Name.StartsWith('.') -or (Test-AicmLink $f) -or $f.Length -gt 65536) { continue }
    try { $r = (Read-AicmUtf8Text $f.FullName) | ConvertFrom-Json } catch { continue }
    if (-not $r -or -not $r.PSObject.Properties['stored'] -or -not $r.PSObject.Properties['status'] -or -not $r.PSObject.Properties['size']) { continue }
    $stored = [string]$r.stored
    if (@('archived', 'pending', 'missing') -notcontains [string]$r.status -or -not $stored -or $stored -match '(^|/)\.\.?(/|$)' -or $stored.Contains('\')) { continue }
    $map[$stored] = [long]$r.size
  }
  return $map
}

# archive\: removes only files an index record says this tool archived there (same size, no link on the
# way); unindexed files, even in a dated folder, stay. Then removes folders left empty.
function Invoke-AicmPurgeArchive([string]$HomeDir, [bool]$DryRun, $Kept) {
  $root = Get-Item -LiteralPath (Join-Path $HomeDir 'archive') -Force -ErrorAction SilentlyContinue
  if (-not $root) { return }
  if (-not (Test-AicmRealDir $root)) { $Kept.Add('archive (not a real folder)'); return }
  $base = $root.FullName.TrimEnd('\', '/')
  $indexed = Get-AicmIndexedArchive $HomeDir
  $removed = 0; $stay = New-Object System.Collections.Generic.List[string]
  $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    foreach ($c in $cur.GetFileSystemInfos()) {
      $rel = $c.FullName.Substring($base.Length + 1).Replace('\', '/')
      if (Test-AicmLink $c) { $stay.Add($rel); continue }
      if ($c -is [System.IO.DirectoryInfo]) { $dirs.Add($c); $stack.Push($c); continue }
      if ($indexed.ContainsKey($rel) -and $indexed[$rel] -eq $c.Length) {
        $removed++
        if (-not $DryRun) { $c.Delete() }
      } else { $stay.Add($rel) }
    }
  }
  if ($DryRun) { Write-Host "would remove $removed archived files listed in the archive index" }
  else {
    Write-Host "removed $removed archived files listed in the archive index"
    foreach ($d in @($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
      try { if (@($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete($false) } } catch { }
    }
  }
  $i = 0
  foreach ($rel in $stay) { if (++$i -le 20) { $Kept.Add("archive\$($rel.Replace('/', '\')) (not in the archive index)") } }
  if ($stay.Count -gt 20) { $Kept.Add("... and $($stay.Count - 20) more under archive") }
  if ($stay.Count -eq 0) {
    if ($DryRun) { Write-Host "would remove $base" }
    else { try { $root.Delete($false); Write-Host "removed $base" } catch { } }
  }
}

# What -Purge removes: only what this tool wrote. Each reserved entry is checked first (the marker does
# not whitelist content): an installed copy holding files a copy never has, a log or state file under a
# name the tool never uses, or anything linked stays. Hooks, *.local.conf, repos.conf, update-policy.json
# and anything else the user put there stay, and the folder itself goes only when nothing is left in it.
# -DryRun changes nothing and writes no marker, log or state. Throws (nothing changed) for a folder that
# is neither marked nor recognized by its structure.
function Invoke-AicmPurge([string]$HomeDir, [switch]$DryRun) {
  if (-not (Test-Path -LiteralPath $HomeDir)) { Write-Host "nothing to purge: $HomeDir does not exist"; return }
  if ((Get-AicmHomeStatus) -eq 'foreign') {
    throw "refusing to purge ${HomeDir}: $($script:AicmHomeProblem); nothing was changed. 'aicm.ps1 uninstall' without -Purge removes only the tasks and the installed copy"
  }
  $kept = New-Object System.Collections.Generic.List[string]
  $act = {
    param($Item)
    if ($DryRun) { Write-Host "would remove $($Item.FullName)"; return }
    if ($Item -is [System.IO.DirectoryInfo]) { Remove-AicmTree $Item $HomeDir } else { $Item.Delete() }
    Write-Host "removed $($Item.FullName)"
  }
  foreach ($name in 'app', 'app.new', 'app.old') {
    $item = Get-Item -LiteralPath (Join-Path $HomeDir $name) -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    if (Test-AicmSamePath (Get-AicmRoot) $item.FullName) { $kept.Add("$name (this command runs from it)"); continue }
    if (Test-AicmAppCopyOwned $item.FullName -Partial:($name -eq 'app.new')) { & $act $item } else { $kept.Add("$name ($($script:AicmHomeProblem))") }
  }
  $inv = Get-Item -LiteralPath (Join-Path $HomeDir 'inventory.md') -Force -ErrorAction SilentlyContinue
  if ($inv) { if (Test-AicmInventoryFile $inv) { & $act $inv } else { $kept.Add('inventory.md') } }
  # archive before state: its index says which archived files are the tool's.
  Invoke-AicmPurgeArchive $HomeDir $DryRun $kept
  foreach ($folder in 'logs', 'state') {
    $dir = Get-Item -LiteralPath (Join-Path $HomeDir $folder) -Force -ErrorAction SilentlyContinue
    if (-not $dir) { continue }
    if (-not (Test-AicmRealDir $dir)) { $kept.Add("$folder (not a real folder)"); continue }
    $left = $false
    foreach ($c in (Get-AicmEntries $dir.FullName)) {
      if ($folder -eq 'logs') {
        if ((Test-AicmRealFile $c) -and (Test-AicmLogName $c.Name)) { & $act $c } else { $kept.Add("logs\$($c.Name)"); $left = $true }
      } elseif ($folder -eq 'state') {
        if ((Test-AicmRealDir $c) -and (Test-AicmStateDirName $c.Name)) {
          if ($c.Name -eq 'maintenance.lock') {
            $owner = $null
            try { $owner = [System.IO.File]::ReadAllText((Join-Path $c.FullName 'owner.json')) | ConvertFrom-Json } catch { }
            if ($owner -and $owner.PSObject.Properties['pid'] -and (Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue)) {
              $kept.Add("state\$($c.Name) (held by a running cleanup)"); $left = $true; continue
            }
          }
          $subLeft = $false
          foreach ($s in (Get-AicmEntries $c.FullName)) {
            if ((Test-AicmRealFile $s) -and (Test-AicmStateSubfileName $c.Name $s.Name)) { if (-not $DryRun) { $s.Delete() } }
            else { $kept.Add("state\$($c.Name)\$($s.Name)"); $subLeft = $true }
          }
          if ($subLeft) { $left = $true }
          elseif ($DryRun) { Write-Host "would remove $($c.FullName)" }
          else { $c.Delete($false); Write-Host "removed $($c.FullName)" }
        } elseif ((Test-AicmRealFile $c) -and (Test-AicmStateFileName $c.Name)) { & $act $c }
        else { $kept.Add("state\$($c.Name)"); $left = $true }
      }
    }
    if ($left) { continue }
    if ($DryRun) { Write-Host "would remove $($dir.FullName)" }
    else { try { $dir.Delete($false); Write-Host "removed $($dir.FullName)" } catch { } }
  }
  if ($kept.Count -gt 0) {
    Write-Host 'kept what this tool did not write:'
    foreach ($k in $kept) { Write-Host "  $k" }
  }
  if ($DryRun) {
    $others = @(Get-AicmEntries $HomeDir | Where-Object { $_.Name -ne '.aicm-home' -and $script:AicmHomeReserved -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($others.Count -eq 0 -and $kept.Count -eq 0) { Write-Host "would remove $HomeDir" }
    else { Write-Host "would keep $HomeDir, which still holds files you wrote: $($others -join ' ')" }
    Write-Host 'dry run: nothing was changed'
    return
  }
  $left = @(Get-AicmEntries $HomeDir | Where-Object { $_.Name -ne '.aicm-home' })
  if ($left.Count -eq 0) {
    Remove-Item -LiteralPath (Join-Path $HomeDir '.aicm-home') -Force -ErrorAction SilentlyContinue
    [System.IO.Directory]::Delete($HomeDir, $false)
    Write-Host "removed $HomeDir"
  } else {
    Write-Host "kept $HomeDir, which still holds files you wrote: $(($left | ForEach-Object { $_.Name }) -join ' ')"
  }
}

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
  foreach ($f in 'VERSION', 'bin\aicm.ps1', 'lib\aicm-common.ps1', 'lib\aicm-scheduler.ps1', 'windows\aicm-windowless.cs') {
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
  Confirm-AicmHome
  $new = "$app.new"
  $old = "$app.old"
  # Nothing is moved or removed unless each copy folder is one this tool built.
  foreach ($d in $app, $new, $old) {
    if (-not (Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue)) { continue }
    if (-not (Test-AicmAppCopyOwned $d -Partial:($d -eq $new))) {
      throw "installed copy: refusing to replace or remove ${d}: $($script:AicmHomeProblem); move it out of the way and run again"
    }
  }
  # A run that stopped between the two moves left only app.old behind: put it back first.
  if (-not (Test-Path -LiteralPath $app) -and (Test-Path -LiteralPath $old)) { Move-AicmDirectory $old $app }
  foreach ($d in $new, $old) { if (Test-Path -LiteralPath $d) { Remove-AicmTree ([System.IO.DirectoryInfo]::new($d)) (Get-AicmHome) } }
  try {
    New-Item -ItemType Directory -Path $new -Force | Out-Null
    foreach ($d in 'bin', 'lib', 'rules', 'windows') { Copy-Item -LiteralPath (Join-Path $Source $d) -Destination (Join-Path $new $d) -Recurse -Force -ErrorAction Stop }
    foreach ($f in 'VERSION', 'LICENSE', 'README.md') {
      $p = Join-Path $Source $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $new $f) -Force -ErrorAction Stop }
    }
    Write-AicmUtf8Text (Join-Path $new 'SOURCE') $Source
    # The copy's own file list: what a later sync, uninstall or purge may replace or remove.
    $copied = Get-AicmCopyFiles $new
    if ($null -eq $copied) { throw "the new copy is incomplete ($($script:AicmHomeProblem))" }
    Write-AicmUtf8Text (Join-Path $new '.aicm-copy') ((@($copied | Sort-Object) -join "`n") + "`n")
    $gaps = @(Get-AicmAppCopyGaps $Source $new)
    if ($gaps.Count -gt 0) { throw "the new copy is incomplete (missing or different: $($gaps[0]))" }
  } catch {
    if (Test-Path -LiteralPath $new) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($new)) (Get-AicmHome) } catch { } }
    throw
  }
  if (Test-Path -LiteralPath $app) { Move-AicmDirectory $app $old }
  try {
    Move-AicmDirectory $new $app
  } catch {
    if (-not (Test-Path -LiteralPath $app) -and (Test-Path -LiteralPath $old)) { Move-AicmDirectory $old $app }
    if (Test-Path -LiteralPath $new) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($new)) (Get-AicmHome) } catch { } }
    throw
  }
  if (Test-Path -LiteralPath $old) { try { Remove-AicmTree ([System.IO.DirectoryInfo]::new($old)) (Get-AicmHome) } catch { } }
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
  $source = Read-AicmUtf8FirstLine $sourceFile
  $current = Get-AicmVersion
  $srcVersion = Join-Path $source 'VERSION'
  if (-not $source -or -not (Test-Path -LiteralPath $srcVersion) -or -not (Test-Path -LiteralPath (Join-Path $source 'bin\aicm.ps1'))) {
    Write-Host "installed copy: source $source is gone; keeping version $current"
    return
  }
  $newVersion = Read-AicmUtf8FirstLine $srcVersion
  if ($newVersion -eq $current) { return }
  if ((Compare-AicmVersion $newVersion $current) -le 0) {
    Write-Host "installed copy: $source has version $newVersion, not newer than $current; keeping $current"
    return
  }
  if (Read-AicmState 'schedule') {
    # The new source backs up and migrates existing actions BEFORE it swaps the old installed copy.
    try {
      $exe = (Get-Process -Id $PID).Path
      $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'bin\aicm.ps1') schedule refresh 2>&1
      foreach ($line in @($out)) { if ("$line".Trim()) { Write-Host "schedule refresh: $line" } }
      if ($LASTEXITCODE -ne 0 -or (Read-AicmUtf8FirstLine (Join-Path $app 'VERSION')) -ne $newVersion) {
        Write-Host "installed copy: could not refresh; keeping or reviewing $current, trying again next run"; return
      }
    } catch { Write-Host "installed copy: could not refresh ($($_.Exception.Message)); trying again next run"; return }
  } else {
    try { [void](Sync-AicmAppCopy $source) }
    catch { Write-Host "installed copy: could not refresh ($($_.Exception.Message)); keeping $current, trying again next run"; return }
  }
  Write-Host "installed copy: updated $current -> $newVersion from $source"
}

# AICM_TASK_PATH lets tests register throwaway tasks in their own folder.
$script:AicmTaskPath = if ($env:AICM_TASK_PATH) { $env:AICM_TASK_PATH } else { '\AI CLI Auto Manager\' }

function Get-AicmTask([string]$Name) {
  return (Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $Name -ErrorAction SilentlyContinue)
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
    $stateName = @{ Update = 'last-update'; Inventory = 'inventory'; Clean = 'last-clean'; Maintenance = 'last-maintenance' }[$Job]
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
  $limits = @{ Update = @('last-update', 3); Inventory = @('inventory', 9); Clean = @('last-clean', 9); Maintenance = @('last-maintenance', 1) }
  $installedDays = 0
  try { $installedDays = ((Get-Date).ToUniversalTime() - [datetime]::Parse($sched.installedAt).ToUniversalTime()).TotalDays } catch { }
  $launcher = if ($sched.PSObject.Properties['launcher']) { [string]$sched.launcher } else { 'wscript' }
  if ($launcher -eq 'wscript' -or $launcher -eq 'powershell') {
    $problems.Add('scheduled tasks use a legacy launcher; run: aicm.ps1 schedule refresh to migrate them')
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

# Ends a process and everything it started. npm.cmd runs cmd.exe, which runs node; killing only
# cmd.exe would leave node (and a hanging postinstall) running.
function Stop-AicmProcessTree([System.Diagnostics.Process]$Process) {
  $ErrorActionPreference = 'Continue'
  $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if ($env:SystemRoot -and (Test-Path -LiteralPath $taskkill)) {
    try { & $taskkill /T /PID $Process.Id 2>&1 | Out-Null } catch { }
    try { [void]$Process.WaitForExit(1000) } catch { }
    try { if (-not $Process.HasExited) { & $taskkill /T /F /PID $Process.Id 2>&1 | Out-Null } } catch { }
  }
  try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
  try { [void]$Process.WaitForExit(5000) } catch { }
}

# How the redirected output of a child is decoded. Node.js (and npm, which runs on it) writes UTF-8
# to a file or pipe on every Windows code page, so its output is read as UTF-8; Windows PowerShell 5.1
# would otherwise read it with the ANSI code page and garble a non-ASCII path such as a Korean npm
# prefix. Other programs (winget, the CLIs themselves, cmd, python) keep the PowerShell default: their
# encoding is not ours to assume. -OutputEncoding overrides the choice for one call.
function Get-AicmChildEncoding([string]$Name, [string]$Exe) {
  foreach ($n in @($Name, $Exe)) {
    if (-not $n) { continue }
    if (@('node', 'npm', 'npx') -contains [System.IO.Path]::GetFileNameWithoutExtension($n).ToLowerInvariant()) { return 'Utf8' }
  }
  return 'Default'
}

function Read-AicmChildOutput([string]$File, [string]$Encoding) {
  if ($Encoding -eq 'Utf8') {
    try { return (Read-AicmUtf8Text $File) } catch { return '' }
  }
  $text = Get-Content -LiteralPath $File -Raw -ErrorAction SilentlyContinue
  # An empty file gives no value at all, which stays $null even through [string]; callers get ''.
  if ($null -eq $text) { return '' }
  return $text
}

# Runs a command with a time limit. Returns .ExitCode (124 on timeout), .StdOut, .StdErr and .Output
# (both streams together, for display). Parse .StdOut only: npm prints warnings on stderr.
function Invoke-AicmWithTimeout([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds, [ValidateSet('', 'Utf8', 'Default')][string]$OutputEncoding = '') {
  Initialize-AicmProcessContainment
  $exe = Resolve-AicmExecutable $Name
  if (-not $exe) { throw "command not found: $Name" }
  $encoding = if ($OutputEncoding) { $OutputEncoding } else { Get-AicmChildEncoding $Name $exe }
  if ($exe -like '*.ps1') {
    $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exe) + @($Arguments)
    $exe = (Get-Command powershell.exe).Source
  }
  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  $contained = $null
  $process = $null
  try {
    $savedSession = $env:AI_CLI_MANAGER_SESSION
    $childSession = [guid]::NewGuid().ToString()
    try {
      $env:AI_CLI_MANAGER_SESSION = $childSession
      if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $contained = [Aicm.ProcessJob]::Start($exe, (Join-AicmProcessArguments $Arguments), $stdoutFile, $stderrFile)
        $process = $contained.Process
      } else {
        # Portable helper tests use native pwsh on Unix; Windows always takes the Job boundary.
        $process = Start-Process -FilePath $exe -ArgumentList (Join-AicmProcessArguments $Arguments) -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -NoNewWindow
      }
    } finally { $env:AI_CLI_MANAGER_SESSION = $savedSession }
    Write-AicmSessionRecord $process $childSession
    # Touch the handle now; otherwise ExitCode stays empty after a timed WaitForExit.
    $null = $process.Handle
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { Stop-AicmProcessTree $process } else { $process.WaitForExit() }
    if ($contained) { $contained.Dispose() } # command ended: close its Job before reading output
    $stdout = Read-AicmChildOutput $stdoutFile $encoding
    $stderr = Read-AicmChildOutput $stderrFile $encoding
    if ($timedOut) {
      $stderr += "TIMEOUT after ${TimeoutSeconds}s"
      return [pscustomobject]@{ ExitCode = 124; Output = ($stdout + $stderr); StdOut = $stdout; StdErr = $stderr }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr); StdOut = $stdout; StdErr = $stderr }
  } finally {
    if ($contained) { $contained.Dispose(); $contained.Process.Dispose() }
    elseif ($process) { $process.Dispose() }
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-AicmSemver([string]$Text) {
  if ($Text -match '(\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.\-]+)?)') { return $Matches[1] }
  return ''
}

# 1 when $A is newer, -1 when older, 0 when equal or not comparable. Semver order: the dotted numbers
# first (missing parts count as 0), then a prerelease (2.0.0-beta.3) is older than its release (2.0.0);
# two prereleases compare part by part, numbers numerically and below words. Build metadata (+x) is ignored.
function Compare-AicmVersion([string]$A, [string]$B) {
  if (-not $A -or -not $B -or $A -eq $B) { return 0 }
  $pa = $A.Trim() -replace '\+.*$', ''
  $pb = $B.Trim() -replace '\+.*$', ''
  if ($pa -notmatch '^v?(\d+(\.\d+)*)(-(.+))?$') { return 0 }
  $na = $Matches[1]; $ra = if ($Matches[4]) { $Matches[4] } else { '' }
  if ($pb -notmatch '^v?(\d+(\.\d+)*)(-(.+))?$') { return 0 }
  $nb = $Matches[1]; $rb = if ($Matches[4]) { $Matches[4] } else { '' }
  $xa = @($na.Split('.')); $xb = @($nb.Split('.'))
  $count = [Math]::Max($xa.Count, $xb.Count)
  for ($i = 0; $i -lt $count; $i++) {
    $ea = if ($i -lt $xa.Count) { [decimal]$xa[$i] } else { [decimal]0 }
    $eb = if ($i -lt $xb.Count) { [decimal]$xb[$i] } else { [decimal]0 }
    if ($ea -ne $eb) { if ($ea -gt $eb) { return 1 } else { return -1 } }
  }
  if ($ra -eq $rb) { return 0 }
  if (-not $ra) { return 1 }
  if (-not $rb) { return -1 }
  $ia = @($ra.Split('.')); $ib = @($rb.Split('.'))
  $count = [Math]::Max($ia.Count, $ib.Count)
  for ($i = 0; $i -lt $count; $i++) {
    if ($i -ge $ia.Count) { return -1 }
    if ($i -ge $ib.Count) { return 1 }
    $sa = $ia[$i]; $sb = $ib[$i]
    $da = $sa -match '^\d+$'; $db = $sb -match '^\d+$'
    if ($da -and $db) { $c = ([decimal]$sa).CompareTo([decimal]$sb) }
    elseif ($da) { $c = -1 }
    elseif ($db) { $c = 1 }
    else { $c = [string]::CompareOrdinal($sa, $sb) }
    if ($c -ne 0) { if ($c -gt 0) { return 1 } else { return -1 } }
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
  $info = [pscustomobject]@{ Available = $false; Prefix = ''; Packages = @{}; PrefixProblem = '' }
  if (Resolve-AicmExecutable 'npm') {
    $info.Available = $true
    $reported = ''
    $prefix = Invoke-AicmWithTimeout 'npm' @('prefix', '-g') 30 -OutputEncoding Utf8
    if ($prefix.ExitCode -eq 0) {
      $first = @($prefix.StdOut -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
      if ($first) { $reported = $first.Trim() }
    }
    $list = Invoke-AicmWithTimeout 'npm' @('ls', '-g', '--depth=0', '--json') 60 -OutputEncoding Utf8
    try {
      $deps = ($list.StdOut | ConvertFrom-Json).dependencies
      if ($deps) { foreach ($p in $deps.PSObject.Properties) { $info.Packages[$p.Name] = [string]$p.Value.version } }
    } catch { }
    # A prefix that cannot be a real folder (undecodable text, or neither it nor its parent exists) while
    # npm lists global packages would make every npm-owned CLI look standalone. It is reported, never used.
    $bad = $false
    if ($reported) {
      $parent = Split-Path -Parent $reported
      $missing = (-not (Test-Path -LiteralPath $reported -PathType Container)) -and (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container))
      $bad = ($reported.IndexOf([char]0xFFFD) -ge 0) -or $missing
    }
    if ($bad -and $info.Packages.Count -gt 0) { $info.PrefixProblem = "npm reports its global prefix as '$reported', which is not a folder here" }
    elseif ($reported) { $info.Prefix = $reported }
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

function Get-AicmNpmNames($Entry) {
  $names = New-Object System.Collections.Generic.List[string]
  if ($Entry.Npm) { [void]$names.Add($Entry.Npm) }
  if ($Entry.Id -eq 'amp' -and @('@ampcode/cli', '@sourcegraph/amp') -contains $Entry.Npm) {
    foreach ($n in @('@ampcode/cli', '@sourcegraph/amp')) {
      if ($names -notcontains $n) { [void]$names.Add($n) }
    }
  }
  if ($Entry.Id -eq 'opencode' -and @('@opencode/cli', 'opencode-ai') -contains $Entry.Npm) {
    foreach ($n in @('@opencode/cli', 'opencode-ai')) {
      if ($names -notcontains $n) { [void]$names.Add($n) }
    }
  }
  return @($names)
}

# Package that owns the resolved command when both canonical and alias are installed.
function Get-AicmSelectedNpmPackage($Entry, [string]$ResolvedPath = '') {
  $npm = Get-AicmNpmInfo
  $names = @(Get-AicmNpmNames $Entry)
  $root = Get-AicmNpmRoot
  if ($ResolvedPath -and $root) {
    foreach ($pkg in $names) {
      $pkgDir = Join-Path $root ($pkg -replace '/', [IO.Path]::DirectorySeparatorChar)
      if ((Test-Path -LiteralPath $pkgDir) -and (Test-AicmUnder $ResolvedPath $pkgDir)) { return $pkg }
    }
    # npm's Windows launchers live in the prefix, outside the package directory.
    # Read their package reference instead of preferring the canonical package blindly.
    if ([IO.Path]::GetExtension($ResolvedPath) -in @('.cmd', '.bat', '.ps1')) {
      try {
        $shim = Get-Item -LiteralPath $ResolvedPath -ErrorAction Stop
        if ($shim.Length -le 65536) {
          $text = [IO.File]::ReadAllText($ResolvedPath).Replace('/', '\')
          foreach ($pkg in $names) {
            $reference = 'node_modules\' + $pkg.Replace('/', '\') + '\'
            if ($text.IndexOf($reference, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $pkg }
          }
        }
      } catch { }
    }
  }
  foreach ($pkg in $names) {
    if ($npm.Packages.ContainsKey($pkg)) { return $pkg }
  }
  return $Entry.Npm
}

# Package whose npm install owns the command path: resolved inside its package folder, or a small
# npm launcher (.cmd/.bat/.ps1) in the npm prefix that references that package's node_modules folder.
# A standalone exe or wrapper in the same prefix is not npm-owned, even when a hidden npm copy exists.
# The launcher is read, never executed; a real package reference still identifies an interrupted
# install whose package folder is currently missing.
function Get-AicmNpmPathOwner($Entry, [string]$Path) {
  if (-not $Path) { return '' }
  $npm = Get-AicmNpmInfo
  $root = Get-AicmNpmRoot
  $names = New-Object System.Collections.Generic.List[string]
  if ($Entry.Npm) { [void]$names.Add($Entry.Npm) }
  foreach ($n in @(Get-AicmNpmNames $Entry)) { if (-not $names.Contains($n)) { [void]$names.Add($n) } }
  if ($root) {
    foreach ($pkg in $names) {
      $pkgDir = Join-Path $root ($pkg -replace '/', [IO.Path]::DirectorySeparatorChar)
      if ((Test-Path -LiteralPath $pkgDir) -and (Test-AicmUnder $Path $pkgDir)) { return $pkg }
    }
  }
  if ($npm.Prefix -and (Test-AicmUnder $Path $npm.Prefix)) {
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@('.cmd', '.bat', '.ps1') -contains $ext) {
      try {
        $shim = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($shim.Length -le 65536) {
          $text = [IO.File]::ReadAllText($Path).Replace('/', '\')
          foreach ($pkg in $names) {
            $reference = 'node_modules\' + $pkg.Replace('/', '\') + '\'
            if ($text.IndexOf($reference, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $pkg }
          }
        }
      } catch { }
    }
  }
  return ''
}

# Where the copy on PATH came from (npm | winget | standalone), plus a stale npm copy hidden behind it.
function Get-AicmCliInstall($Entry) {
  $result = [ordered]@{ Installed = $false; Path = ''; Method = ''; NpmCopy = ''; NpmPackage = $Entry.Npm }
  $npm = Get-AicmNpmInfo
  if (-not $Entry.Command) {
    if ($Entry.Winget -and (Get-AicmWingetVersion $Entry.Winget)) { $result.Installed = $true; $result.Method = 'winget' }
    return [pscustomobject]$result
  }
  $cmd = Get-Command $Entry.Command -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    $result.NpmPackage = Get-AicmSelectedNpmPackage $Entry
    if ($result.NpmPackage -and $npm.Packages.ContainsKey($result.NpmPackage)) {
      $result.Installed = $true; $result.Method = 'npm'; $result.Path = '(npm package, command not on PATH)'
    }
    return [pscustomobject]$result
  }
  $result.Installed = $true
  $result.Path = $cmd.Source
  if ($npm.PrefixProblem -and $cmd.Source -notmatch '\\WinGet\\') {
    # Without a readable npm prefix the owner cannot be told; never guess "standalone".
    $result.Method = 'unknown'
    return [pscustomobject]$result
  }
  $owner = Get-AicmNpmPathOwner $Entry $cmd.Source
  if ($owner) { $result.NpmPackage = $owner } else { $result.NpmPackage = Get-AicmSelectedNpmPackage $Entry $cmd.Source }
  $npmVersion = ''
  if ($result.NpmPackage -and $npm.Packages.ContainsKey($result.NpmPackage)) { $npmVersion = $npm.Packages[$result.NpmPackage] }
  if ($owner) { $result.Method = 'npm' }
  elseif ($cmd.Source -match '\\WinGet\\') { $result.Method = 'winget' }
  else { $result.Method = 'standalone' }
  if ($result.Method -ne 'npm' -and $npmVersion) { $result.NpmCopy = $npmVersion }
  return [pscustomobject]$result
}

# How to get rid of a second copy that hides behind (or in front of) the one on PATH.
function Get-AicmShadowFix($Install) {
  $npm = Get-AicmNpmInfo
  $dir = Split-Path -Parent $Install.Path
  return "fix : keep one copy - uninstall the unused npm copy, or put $($npm.Prefix) before $dir in your user PATH to select npm for daily updates."
}

# Whether the daily update keeps the copy on PATH current: 'yes' or 'no: <why>'.
function Get-AicmUpdateCoverage($Entry, $Install) {
  if ($Install.Method -eq 'unknown') { return 'no: npm global prefix unreadable, so the install owner is unknown' }
  if ($Entry.Builtin -and $Install.Method -ne 'npm') {
    switch ($Entry.Id) {
      'codex' { return 'no : update the PATH copy with its owning app or installer; hidden npm copies are skipped' }
      'kimi' { return 'no : standalone Kimi is not updated; install with npm for automation' }
      'claude' { return 'yes' }
      'opencode' { return 'yes' }
      'agy' { return 'yes' }
      'grok' { return 'yes' }
    }
  }
  switch ($Install.Method) {
    'npm' { if ($Entry.Npm) { return 'yes' } else { return 'no: unknown npm package' } }
    'winget' { if ($Entry.Winget) { return 'yes' } else { return 'no: add its winget id to the catalog' } }
    'standalone' {
      if ($Entry.SelfUpdate -and $Entry.SelfUpdate -ne '@installer') { return 'yes' }
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

# ---------------------------------------------------------------------------
# Per-CLI update policies ($AICM_HOME\update-policy.json)
#   Node.js is required only when the file exists. Validation runs before the updater creates a log,
#   lock or state file, so a broken policy never starts a run.
# ---------------------------------------------------------------------------
$script:AicmPolicyPresent = $false
$script:AicmPolicyFingerprint = ''
$script:AicmPolicyTools = @{}

# Reads and validates the policy. Throws (fail closed) on a missing Node.js or an invalid file.
function Initialize-AicmUpdatePolicy([int]$GlobalAge) {
  $script:AicmPolicyPresent = $false
  $script:AicmPolicyFingerprint = "none:$GlobalAge"
  $script:AicmPolicyTools = @{}
  $file = Join-Path (Get-AicmHome) 'update-policy.json'
  $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    # No entry at all: no policy. A dangling symlink still yields an item above; a path that cannot be
    # inspected but is present must not be treated as absent.
    if (Test-Path -LiteralPath $file) { throw "update policy: $file exists but is not a readable file" }
    return
  }
  if ($item.PSIsContainer -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw "update policy: $file is not a file"
  }
  $script:AicmPolicyPresent = $true
  if (-not (Resolve-AicmExecutable 'node')) { throw "update policy: $file exists but Node.js is required to read it" }
  $ids = @(Read-AicmCatalog | ForEach-Object { $_.Id } | Sort-Object -Unique)
  $module = Join-Path (Get-AicmRoot) 'lib\update-policy.js'
  $r = Invoke-AicmWithTimeout 'node' @($module, 'load', '--file', $file, '--ids', ($ids -join ','), '--global-age', "$GlobalAge") 60
  if ($r.ExitCode -ne 0) {
    $detail = ([string]$r.StdOut).Trim()
    if (-not $detail) { $detail = ([string]$r.StdErr).Trim() }
    throw "update policy: $detail"
  }
  $rules = @{}
  $fingerprint = ''
  $sawSchema = $false
  $sawFingerprint = $false
  foreach ($line in @($r.StdOut -split "`r?`n")) {
    if (-not $line) { continue }
    $f = @($line -split "`t")
    if ($f[0] -eq 'schema') {
      if ($f.Count -lt 2 -or $f[1] -ne '1') { throw 'update policy: unexpected schema version' }
      $sawSchema = $true
    } elseif ($f[0] -eq 'fingerprint') {
      if ($f.Count -lt 2 -or $f[1] -notmatch '^[0-9a-f]{64}$') { throw 'update policy: invalid fingerprint' }
      $fingerprint = $f[1]
      $sawFingerprint = $true
    } elseif ($f[0] -eq 'rule') {
      if ($f.Count -ne 6 -or $f[1] -notmatch '^[a-z0-9][a-z0-9-]*$' -or $f[2] -notmatch '^[01]$') { throw 'update policy: invalid rule output' }
      $pin = if ($f[3] -eq '-') { '' } else { [string]$f[3] }
      $explicitAge = if ($f[4] -eq '-') { -1 } else { [int]$f[4] }
      $rules[$f[1]] = [pscustomobject]@{
        Exclude = ($f[2] -eq '1'); Pin = $pin; ExplicitAge = $explicitAge; EffectiveAge = [int]$f[5]
      }
    } else {
      throw "update policy: unexpected output '$($f[0])'"
    }
  }
  # Empty or truncated output is not a valid policy even when the reader exits 0.
  if (-not $sawSchema -or -not $sawFingerprint -or -not $fingerprint) { throw 'update policy: incomplete output from the policy reader' }
  $script:AicmPolicyFingerprint = "policy:$fingerprint"
  $script:AicmPolicyTools = $rules
}

function Get-AicmPolicyFingerprint { return $script:AicmPolicyFingerprint }

function Get-AicmPolicyRule([string]$Id) {
  if ($Id -eq 'gpt') { $Id = 'codex' }
  if ($script:AicmPolicyTools.ContainsKey($Id)) { return $script:AicmPolicyTools[$Id] }
  return $null
}

function Test-AicmPolicyExcluded([string]$Id) {
  $rule = Get-AicmPolicyRule $Id
  return [bool]($rule -and $rule.Exclude)
}

function Get-AicmPolicyPin([string]$Id) {
  $rule = Get-AicmPolicyRule $Id
  if ($rule -and $rule.Pin) { return [string]$rule.Pin }
  return ''
}

# -1 when no per-tool age was configured and the global baseline applies.
function Get-AicmPolicyExplicitAge([string]$Id) {
  $rule = Get-AicmPolicyRule $Id
  if ($rule -and $rule.ExplicitAge -ge 0) { return [int]$rule.ExplicitAge }
  return -1
}

function Get-AicmPolicyEffectiveAge([string]$Id, [int]$GlobalAge) {
  $explicit = Get-AicmPolicyExplicitAge $Id
  if ($explicit -ge 0) { return $explicit }
  return $GlobalAge
}

function Test-AicmPolicyHasRules {
  return [bool]($script:AicmPolicyPresent -and $script:AicmPolicyTools.Count -gt 0)
}

# A pin/positive age cannot be enforced by a non-npm install owner. '' when the route may run.
function Get-AicmPolicyRouteHold([string]$Id, [string]$Method) {
  $pin = Get-AicmPolicyPin $Id
  if ($pin -and $Method -ne 'npm') {
    $owner = if ($Method) { $Method } else { 'an unknown route' }
    return "update policy pins $Id to $pin, which requires the npm install route; the active copy is managed by $owner, so no update was attempted"
  }
  $age = Get-AicmPolicyExplicitAge $Id
  if ($age -gt 0 -and $Method -ne 'npm') {
    $owner = if ($Method) { $Method } else { 'an unknown route' }
    return "update policy sets minReleaseAgeDays=$age for $Id, which cannot be enforced for $owner installs; no update was attempted"
  }
  return ''
}

# Validates an exact pin against the registry. '' when it may be installed; otherwise a hold reason.
function Test-AicmPolicyPinRelease([string]$Package, [string]$Pin, [int]$Age, [switch]$Amp) {
  $view = Save-AicmNpmView @($Package, 'name', 'time', 'dist-tags', 'versions')
  try {
    $module = Join-Path (Get-AicmRoot) 'lib\update-policy.js'
    $nodeArgs = @($module, 'pin-check', '--file', $view, '--pin', $Pin, '--age', "$Age")
    if ($Amp) { $nodeArgs += '--amp' }
    $r = Invoke-AicmWithTimeout 'node' $nodeArgs 60
    if ($r.ExitCode -ne 0) {
      $why = ([string]$r.StdOut).Trim()
      if (-not $why) { $why = ([string]$r.StdErr).Trim() }
      return ($why -replace '^error:\s*', '')
    }
  } finally {
    Remove-Item -LiteralPath $view -Force -ErrorAction SilentlyContinue
  }
  $dep = Invoke-AicmWithTimeout 'npm' @('view', "$Package@$Pin", 'deprecated') 60
  if ($dep.ExitCode -ne 0) { throw "could not read the deprecation state of $Package@${Pin}: $($dep.Output.Trim())" }
  $why = ([string]$dep.StdOut).Trim()
  if ($why) { return "pinned version $Pin is deprecated ($why)" }
  return ''
}

function Invoke-AicmNpmGuard([string[]]$Arguments) {
  $guard = Join-Path (Get-AicmRoot) 'lib\npm-guard.js'
  $r = Invoke-AicmWithTimeout 'node' (@($guard) + $Arguments) 60
  if ($r.ExitCode -ne 0) { throw "npm-guard failed: $($r.Output.Trim())" }
  return @($r.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Writes `npm view <args> --json` to a temp file. Only stdout goes into the file: npm prints warnings
# (for example about an old setting in .npmrc) on stderr, and they would break the JSON.
function Save-AicmNpmView([string[]]$Arguments) {
  $r = Invoke-AicmWithTimeout 'npm' (@('view') + $Arguments + @('--json')) 90
  if ($r.ExitCode -ne 0) { throw "npm view $($Arguments -join ' ') failed: $($r.Output.Trim())" }
  $file = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($file, $r.StdOut)
  return $file
}

# A value read back from a state file as a date. PowerShell 7's ConvertFrom-Json already turns ISO
# strings into DateTime; Windows PowerShell leaves strings. $null when it is not a date.
function ConvertTo-AicmDate($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value }
  $d = [datetime]::MinValue
  $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
  if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
  return $null
}

# A local calendar day (yyyy-MM-dd) read back from a state file ('' when there is none).
function ConvertTo-AicmDay($Value) {
  if ($null -eq $Value) { return '' }
  if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
  return [string]$Value
}

function Get-AicmToday { return (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }

# The global node_modules folder ('' when npm is missing).
function Get-AicmNpmRoot {
  $prefix = (Get-AicmNpmInfo).Prefix
  if (-not $prefix) { return '' }
  foreach ($root in @((Join-Path $prefix 'node_modules'), (Join-Path $prefix 'lib\node_modules'))) {
    if (Test-Path -LiteralPath $root) { return $root }
  }
  return ''
}

# npm's backup of a package it was replacing (node_modules\[@scope\].<name>-XXXXXXXX with a package.json),
# left behind when the install was interrupted. '' when there is none.
function Get-AicmNpmBackup([string]$Package) {
  $root = Get-AicmNpmRoot
  if (-not $root) { return '' }
  $parts = $Package.Split('/')
  $parent = if ($parts.Count -gt 1) { Join-Path $root $parts[0] } else { $root }
  $name = $parts[$parts.Count - 1]
  if (-not (Test-Path -LiteralPath $parent)) { return '' }
  foreach ($d in ([System.IO.DirectoryInfo]::new($parent)).GetDirectories(".$name-*")) {
    if ($d.Name -match ('^\.' + [regex]::Escape($name) + '-[A-Za-z0-9]{8}$') -and -not (Test-AicmLink $d) -and (Test-Path -LiteralPath (Join-Path $d.FullName 'package.json'))) {
      return $d.FullName
    }
  }
  return ''
}

# npm leaves folders named node_modules\.<name>-XXXXXXXX behind when an install stops half way: its
# staging folder, or its backup of the copy it was replacing. On this tool's first test machine one of
# them was 238 MB. Removes those older than a day, but only while <name> itself is installed (has a
# package.json): otherwise the leftover may be the only good copy of a CLI whose install was cut off.
function Remove-AicmNpmLeftovers {
  # A backup folder can be the only copy of a CLI whose policy excludes updates or pins a version.
  # While any policy rule is configured, skip global housekeeping rather than guess which leftovers
  # are policy-protected.
  if (Test-AicmPolicyHasRules) {
    Write-Host 'pass: npm leftover cleanup skipped while update policy is configured'
    return
  }
  $root = Get-AicmNpmRoot
  if (-not $root) { return }
  $cutoff = (Get-Date).AddDays(-1)
  $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
  foreach ($d in ([System.IO.DirectoryInfo]::new($root)).GetDirectories()) {
    if (Test-AicmLink $d) { continue }
    if ($d.Name.StartsWith('@')) { foreach ($s in $d.GetDirectories()) { $dirs.Add($s) } } else { $dirs.Add($d) }
  }
  foreach ($d in $dirs) {
    if ($d.Name -notmatch '^\.([^.].*)-[A-Za-z0-9]{8}$') { continue }
    $owner = $Matches[1]
    if ((Test-AicmLink $d) -or $d.LastWriteTime -gt $cutoff) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $d.Parent.FullName $owner) 'package.json'))) {
      Write-Host "kept npm leftover $($d.FullName) ($owner is not installed; this may be its only copy)"
      continue
    }
    $bytes = 0L
    foreach ($f in (Get-AicmFiles $d.FullName)) { $bytes += $f.Length }
    try { Remove-AicmTree $d $root; Write-Host "removed npm leftover $($d.FullName) ($(Format-AicmSize $bytes))" }
    catch { Write-Host "kept npm leftover $($d.FullName) (in use)" }
  }
}

# The version to install: the newest stable release that is at least N days old ('' when none is).
# Unpublished versions never count. -SkipDeprecated (the updater) also passes over deprecated releases
# newer than -Installed; when every newer one is deprecated, -Installed is returned (nothing to do).
function Get-AicmNpmTarget([string]$Package, [int]$MinAgeDays, [string]$Installed = '', [switch]$SkipDeprecated) {
  if ($MinAgeDays -le 0 -and -not $SkipDeprecated) {
    $r = Invoke-AicmWithTimeout 'npm' @('view', $Package, 'version') 60
    return (Get-AicmSemver $r.StdOut)
  }
  $view = Save-AicmNpmView @($Package, 'name', 'time', 'dist-tags', 'versions')
  try { $list = @(Invoke-AicmNpmGuard @('candidates', "$([Math]::Max(0, $MinAgeDays))", $view)) }
  finally { Remove-Item -LiteralPath $view -Force -ErrorAction SilentlyContinue }
  if (-not $SkipDeprecated) { if ($list.Count -gt 0) { return $list[0] } else { return '' } }
  $checked = 0
  foreach ($v in $list) {
    if ($Installed -and (Compare-AicmVersion $v $Installed) -le 0) { return $v }
    if ($checked -ge 5) { break }
    $checked++
    $r = Invoke-AicmWithTimeout 'npm' @('view', "$Package@$v", 'deprecated') 60
    if ($r.ExitCode -ne 0) { throw "npm view $Package@$v deprecated failed: $($r.Output.Trim())" }
    $why = $r.StdOut.Trim()
    if (-not $why) { return $v }
    Write-Host "skip: $Package@$v is deprecated ($why)"
  }
  return $Installed
}

# --before=<now minus the waiting period>: npm then resolves the dependencies, too, to versions published
# before that moment, so the waiting period covers them (their install scripts run in the real install).
# Nothing when there is no waiting period.
function Get-AicmNpmBeforeArgs([int]$MinAgeDays) {
  if ($MinAgeDays -le 0) { return }
  return ('--before=' + (Get-Date).ToUniversalTime().AddDays(-$MinAgeDays).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture))
}

# Signature verdicts per package@version, kept for the day, so the scheduled retries do not download
# and stage the same release again. Values: ok | unverifiable | bad: <summary>.
function Get-AicmNpmVerdict([string]$Spec) {
  $s = Read-AicmState 'npm-verdicts'
  if (-not $s -or -not $s.PSObject.Properties[$Spec]) { return '' }
  $e = $s.PSObject.Properties[$Spec].Value
  if (-not $e -or -not $e.PSObject.Properties['day'] -or -not $e.PSObject.Properties['verdict']) { return '' }
  if ((ConvertTo-AicmDay $e.day) -ne (Get-AicmToday)) { return '' }
  return [string]$e.verdict
}

function Set-AicmNpmVerdict([string]$Spec, [string]$Verdict) {
  $today = Get-AicmToday
  $keep = [ordered]@{}
  $s = Read-AicmState 'npm-verdicts'
  if ($s) {
    foreach ($p in $s.PSObject.Properties) {
      if ($p.Name -ne $Spec -and $p.Value -and $p.Value.PSObject.Properties['day'] -and (ConvertTo-AicmDay $p.Value.day) -eq $today) { $keep[$p.Name] = $p.Value }
    }
  }
  $keep[$Spec] = [ordered]@{ day = $today; verdict = $Verdict }
  Write-AicmState 'npm-verdicts' $keep
}

# Notes for the caller's attention list (stable texts, so they are announced once a week at most).
$script:AicmNpmNotes = New-Object System.Collections.Generic.List[string]
$script:AicmNoKeysNote = 'the npm registry publishes no signing keys (a private registry?), so release signatures cannot be checked; updates go on without that check. Set AICM_VERIFY_SIGNATURES=0 to skip it'
function Add-AicmNpmNote([string]$Text) { if (-not $script:AicmNpmNotes.Contains($Text)) { $script:AicmNpmNotes.Add($Text) } }

# Throws when the candidate looks unlike the installed release or fails the registry signature check.
function Test-AicmNpmRelease([string]$Package, [string]$Installed, [string]$Target, [int]$MinAgeDays = -1) {
  if ($MinAgeDays -lt 0) { $MinAgeDays = Get-AicmMinReleaseAgeDays }
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
  $spec = "$Package@$Target"
  $verdict = Get-AicmNpmVerdict $spec
  if ($verdict -eq 'ok') { Write-Host "signatures ok (checked earlier today): $spec"; return }
  if ($verdict -eq 'unverifiable') { Write-Host "signatures not checkable (checked earlier today): $spec"; Add-AicmNpmNote $script:AicmNoKeysNote; return }
  if ($verdict -like 'bad:*') { throw "signature check failed for ${spec} (checked earlier today): $($verdict.Substring(4).Trim())" }
  $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-stage-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  try {
    # --ignore-scripts: nothing from the candidate runs before it has passed the checks.
    $r = Invoke-AicmWithTimeout 'npm' (@('install', $spec, '--prefix', $stage, '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error') + @(Get-AicmNpmBeforeArgs $MinAgeDays)) 900
    if ($r.ExitCode -ne 0) { throw "staged install of $spec failed: $($r.Output.Trim())" }
    $r = Invoke-AicmWithTimeout 'npm' @('audit', 'signatures', '--prefix', $stage) 300
    $summary = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() }) -join ' / '
    if ($r.ExitCode -eq 0) {
      Set-AicmNpmVerdict $spec 'ok'
      Write-Host "signatures ok: $summary"
      return
    }
    # A registry without signing keys (Verdaccio and other private registries): nothing can be checked.
    if ($r.Output -match 'installed from a supported registry') {
      Set-AicmNpmVerdict $spec 'unverifiable'
      Write-Host "warn: signatures not checkable for ${spec}: $summary"
      Add-AicmNpmNote $script:AicmNoKeysNote
      return
    }
    # Remember a real signature problem for the day; other errors (network) are tried again next run.
    if ($r.Output -match '(?i)(invalid|missing)[^\r\n]*signature') { Set-AicmNpmVerdict $spec "bad: $summary" }
    throw "signature check failed for ${spec}: $summary"
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

# A Job handle belongs to this PowerShell process, never to its children.
function Initialize-AicmProcessContainment([switch]$WholeProcess, [switch]$OwnSession) {
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
  if (-not ('Aicm.ProcessJob' -as [type])) { Add-Type -Path (Join-Path (Get-AicmRoot) 'lib\aicm-job.cs') }
  if ($WholeProcess) { [Aicm.ProcessJob]::Initialize() }
  if ($WholeProcess -or $OwnSession) { $script:AicmSessionRecording = $true }
  if (($WholeProcess -or $OwnSession) -and -not $env:AI_CLI_MANAGER_SESSION) {
    $env:AI_CLI_MANAGER_SESSION = [guid]::NewGuid().ToString()
    Write-AicmSessionRecord (Get-Process -Id $PID) $env:AI_CLI_MANAGER_SESSION
  }
}

function Write-AicmSessionRecord([System.Diagnostics.Process]$Process, [string]$Session) {
  if (-not (Get-Variable -Name AicmSessionRecording -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) { return }
  try {
    $owner = Get-Process -Id $PID
    $dir = Join-Path (Get-AicmHome) 'state\sessions'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $record = @{ session = $Session; pid = $Process.Id; created = $Process.StartTime.ToUniversalTime().ToString('o')
      ownerPid = $PID; ownerCreated = $owner.StartTime.ToUniversalTime().ToString('o'); platform = 'win32' }
    $record | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dir "$Session.json") -Encoding UTF8
  } catch { } # A fast command may already have exited; its Job still guarantees containment.
}
