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
