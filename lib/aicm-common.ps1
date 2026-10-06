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
  if (@('age', 'cap', 'keep-latest', 'command') -notcontains $kind) { throw "invalid rule kind '$kind' in ${Source}: $t" }
  $default = $cols[7].ToLowerInvariant()
  if (@('on', 'off') -notcontains $default) { throw "invalid default '$default' in ${Source}: $t" }
  $days = 0
  if ($cols[5]) { $days = [int]$cols[5] }
  $limit = 0
  if ($cols[6]) { $limit = [int]$cols[6] }
  if ($kind -eq 'age' -and $days -lt 1) { throw "age rule needs days >= 1 in ${Source}: $t" }
  if ($kind -eq 'keep-latest' -and $limit -lt 1) { throw "keep-latest rule needs limit >= 1 in ${Source}: $t" }
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

function Write-AicmState([string]$Name, $Object) {
  $dir = Join-Path (Get-AicmHome) 'state'
  Initialize-AicmDirectory $dir
  $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir "$Name.json") -Encoding UTF8
}

function Read-AicmState([string]$Name) {
  $file = Join-Path (Join-Path (Get-AicmHome) 'state') "$Name.json"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
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

# AICM_TASK_PATH lets tests register throwaway tasks in their own folder.
$script:AicmTaskPath = if ($env:AICM_TASK_PATH) { $env:AICM_TASK_PATH } else { '\AI CLI Auto Manager\' }

function Get-AicmTask([string]$Name) {
  return (Get-ScheduledTask -TaskPath $script:AicmTaskPath -TaskName $Name -ErrorAction SilentlyContinue)
}

# Checks that every scheduled job recorded at install time still exists.
# Returns a list of human-readable problems (empty when healthy).
function Get-AicmScheduleProblems([string]$Skip = '') {
  $problems = New-Object System.Collections.Generic.List[string]
  $sched = Read-AicmState 'schedule'
  if (-not $sched) { return $problems }
  foreach ($job in @($sched.jobs)) {
    if ($job -eq $Skip) { continue }
    if (-not (Get-AicmTask $job)) {
      $problems.Add("scheduled task '$job' is missing; run: aicm.ps1 schedule install")
    }
  }
  return $problems
}
