<#
.SYNOPSIS
  Removes stale AI coding CLI leftovers (old transcripts, temp files, caches) on Windows.
.DESCRIPTION
  Rules come from rules\clean-rules.conf plus an optional local override file.
  Only files older than each rule's age are removed. Links are never followed,
  protected files (memory, credentials, settings) are never removed, and files
  that are in use are skipped.
.EXAMPLE
  .\bin\clean_ai_leftovers.ps1 -DryRun
.EXAMPLE
  .\bin\clean_ai_leftovers.ps1 -Rules codex-sessions,claude-transcripts
#>
[CmdletBinding()]
param(
  [Alias('Check')]
  [switch]$DryRun,
  [switch]$Report,
  [string[]]$Rules = @(),
  [string]$RulesFile = '',
  [string]$LocalRulesFile = '',
  [string]$LogDir = '',
  [int]$LogRetentionDays = $(if ($env:LOG_RETENTION_DAYS) { [int]$env:LOG_RETENTION_DAYS } else { 30 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\aicm-common.ps1')

if (-not $RulesFile) { $RulesFile = Join-Path (Get-AicmRoot) 'rules\clean-rules.conf' }
if (-not $LocalRulesFile) { $LocalRulesFile = Join-Path (Get-AicmHome) 'clean-rules.local.conf' }
if (-not $LogDir) { $LogDir = Join-Path (Get-AicmHome) 'logs' }
if ($Report) { $DryRun = $true }

$selected = @(($Rules -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Get-DisplayPath([string]$Path) {
  $userHome = Get-AicmUserHome
  if (Test-AicmUnder $Path $userHome) { return '~' + $Path.Substring($userHome.TrimEnd('\').Length) }
  return $Path
}

function Get-TreeBytes([string]$Path) {
  $sum = 0L
  foreach ($f in (Get-AicmFiles $Path)) { $sum += $f.Length }
  return $sum
}

function Remove-FileQuietly([System.IO.FileInfo]$File) {
  try {
    if ($File.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
      $File.Attributes = $File.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
    $File.Delete()
    return $true
  } catch {
    return $false
  }
}

function Invoke-AgeRule($Rule, [string]$Root) {
  $cutoff = (Get-Date).AddDays(-$Rule.Days)
  $candidates = @(Get-AicmFiles $Root $Rule.Pattern | Where-Object { $_.LastWriteTime -lt $cutoff -and -not (Test-AicmProtected $_) })
  $result = [ordered]@{ files = $candidates.Count; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0 }
  foreach ($f in $candidates) { $result.bytes += $f.Length }
  if ($DryRun) { return $result }
  foreach ($f in $candidates) {
    $len = $f.Length
    if (Remove-FileQuietly $f) { $result.removed++; $result.removedBytes += $len } else { $result.inUse++ }
  }
  [void](Remove-AicmEmptyDirs $Root)
  return $result
}

function Invoke-CapRule($Rule, [string]$Root) {
  $cutoff = (Get-Date).AddDays(-[Math]::Max($Rule.Days, 1))
  $limitBytes = [int64]$Rule.Limit * 1MB
  $result = [ordered]@{ files = 0; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0 }
  foreach ($f in @(Get-AicmFiles $Root $Rule.Pattern -TopOnly)) {
    if (Test-AicmProtected $f) { continue }
    $tooOld = ($Rule.Days -gt 0) -and ($f.LastWriteTime -lt $cutoff)
    $tooBig = ($Rule.Limit -gt 0) -and ($f.Length -gt $limitBytes)
    if (-not ($tooOld -or $tooBig)) { continue }
    $group = @($f) + @(foreach ($suffix in '-wal', '-shm', '-journal') {
      $side = Join-Path $f.DirectoryName ($f.Name + $suffix)
      if (Test-Path -LiteralPath $side) { Get-Item -LiteralPath $side -Force }
    })
    foreach ($g in $group) { $result.files++; $result.bytes += $g.Length }
    if ($DryRun) { continue }
    # Remove the main file first: if the owning app holds it open, nothing else is touched.
    if (-not (Remove-FileQuietly $f)) { $result.inUse += $group.Count; continue }
    foreach ($g in $group) {
      if ($g.FullName -eq $f.FullName) { $result.removed++; $result.removedBytes += $g.Length; continue }
      $len = $g.Length
      if (Remove-FileQuietly $g) { $result.removed++; $result.removedBytes += $len } else { $result.inUse++ }
    }
  }
  return $result
}

function Invoke-KeepLatestRule($Rule, [string]$Root) {
  $result = [ordered]@{ files = 0; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0; folders = @() }
  $groups = @{}
  foreach ($d in ([System.IO.DirectoryInfo]::new($Root)).GetDirectories()) {
    if (Test-AicmLink $d) { continue }
    if ($d.Name -notlike $Rule.Pattern) { continue }
    if ($d.Name -notmatch '^(?<name>.+)-(?<build>\d+)$') { continue }
    $key = $Matches['name']
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
    $groups[$key].Add([pscustomobject]@{ Dir = $d; Build = [int64]$Matches['build'] })
  }
  foreach ($key in $groups.Keys) {
    $old = @($groups[$key] | Sort-Object Build -Descending | Select-Object -Skip $Rule.Limit)
    foreach ($entry in $old) {
      $bytes = Get-TreeBytes $entry.Dir.FullName
      $result.files++
      $result.bytes += $bytes
      $result.folders += $entry.Dir.Name
      if ($DryRun) { continue }
      try {
        Remove-AicmTree $entry.Dir
        $result.removed++
        $result.removedBytes += $bytes
      } catch {
        $result.inUse++
      }
    }
  }
  return $result
}

function New-ArchiveResult {
  return [ordered]@{ files = 0; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0; purge = 0; purgeBytes = 0L; purged = 0; purgedBytes = 0L; detail = '' }
}

# Archive date folders (archive\<rule>\yyyyMMdd) older than $Days are removed.
function Invoke-ArchivePurge($Result, [string]$ArchiveDir, [int]$Days, [bool]$PurgeDry) {
  if (-not (Test-Path -LiteralPath $ArchiveDir -PathType Container)) { return }
  $cutoff = (Get-Date).Date.AddDays(-$Days)
  foreach ($d in ([System.IO.DirectoryInfo]::new($ArchiveDir)).GetDirectories()) {
    if (Test-AicmLink $d) { continue }
    $when = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($d.Name, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$when)) { continue }
    if ($when -ge $cutoff) { continue }
    $bytes = Get-TreeBytes $d.FullName
    $Result.purge++
    $Result.purgeBytes += $bytes
    if ($PurgeDry) { continue }
    try { Remove-AicmTree $d; $Result.purged++; $Result.purgedBytes += $bytes } catch { $Result.inUse++ }
  }
}

# Session files older than the archive age move to ~/.ai-cli-auto-manager/archive/<rule>/<today>/,
# keeping their relative path; archive folders older than the rule's limit are deleted.
# Old archive folders are purged even when the rule is off, so remnants never stay behind.
function Invoke-ArchiveRule($Rule, [string]$Root, [bool]$PurgeDry) {
  $result = New-ArchiveResult
  $days = Get-AicmArchiveDays $Rule
  if ($days -ne $Rule.Days) { $result.detail = "archive after ${days}d (the CLI deletes after $(Get-AicmNativeRetentionDays $Rule.Id)d)" }
  $cutoff = (Get-Date).AddDays(-$days)
  $candidates = @(Get-AicmFiles $Root $Rule.Pattern | Where-Object { $_.LastWriteTime -lt $cutoff -and -not (Test-AicmProtected $_) })
  $result.files = $candidates.Count
  foreach ($f in $candidates) { $result.bytes += $f.Length }
  $archiveDir = Join-Path (Get-AicmArchiveRoot) $Rule.Id
  if (-not $DryRun -and $candidates.Count -gt 0) {
    $dest = Join-Path $archiveDir (Get-Date -Format 'yyyyMMdd')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($f in $candidates) {
      $target = Join-Path $dest $f.FullName.Substring($rootFull.Length + 1)
      try {
        Initialize-AicmDirectory (Split-Path -Parent $target)
        if (Test-Path -LiteralPath $target) { $target = $target + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) }
        $len = $f.Length
        [System.IO.File]::Move($f.FullName, $target)
        $result.removed++
        $result.removedBytes += $len
      } catch {
        $result.inUse++
      }
    }
    [void](Remove-AicmEmptyDirs $Root)
  }
  Invoke-ArchivePurge $result $archiveDir $Rule.Limit $PurgeDry
  return $result
}

# Codex keeps every session in its own database as well as in rollout files, so files are never
# deleted directly: `codex archive` after Days, `codex delete --force` once a session has been
# unused for Days + Limit. Threads whose file is already gone count as archived and are deleted
# on the same schedule (needs Python to read the database; skipped otherwise).
function Invoke-CodexRule($Rule, [string]$Root) {
  $result = New-ArchiveResult
  $codex = Resolve-AicmExecutable 'codex'
  if (-not $codex) { $result.detail = 'codex command not found: nothing touched'; return $result }
  $now = Get-Date
  $archiveCut = $now.AddDays(-$Rule.Days)
  $deleteCut = $now.AddDays(-($Rule.Days + $Rule.Limit))
  $old = @()
  if (Test-Path -LiteralPath (Join-Path $Root 'sessions')) {
    $old = @(Get-AicmFiles (Join-Path $Root 'sessions') 'rollout-*' | Where-Object { $_.LastWriteTime -lt $archiveCut -and (Get-AicmCodexId $_.Name) })
  }
  $toDelete = @()
  if (Test-Path -LiteralPath (Join-Path $Root 'archived_sessions')) {
    $toDelete = @(Get-AicmFiles (Join-Path $Root 'archived_sessions') 'rollout-*' | Where-Object { $_.LastWriteTime -lt $deleteCut -and (Get-AicmCodexId $_.Name) })
  }
  # limit 0: no archive stage, sessions unused for Days are deleted right away.
  $toArchive = $old
  if ($Rule.Limit -eq 0) { $toDelete = @($toDelete) + @($old); $toArchive = @() }
  $threads = Get-AicmCodexThreads $Root
  $orphans = @()
  if ($threads) {
    $epochCut = ($deleteCut.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
    foreach ($id in $threads.Keys) {
      $t = $threads[$id]
      if ($t.Rollout -and -not (Test-Path -LiteralPath $t.Rollout) -and $t.Updated -gt 0 -and $t.Updated -lt $epochCut) { $orphans += $id }
    }
  } else {
    $result.detail = 'Codex database not read (Python not found): sessions whose file is already gone are left alone'
  }
  $result.files = $toArchive.Count
  foreach ($f in $toArchive) { $result.bytes += $f.Length }
  $result.purge = $toDelete.Count + $orphans.Count
  foreach ($f in $toDelete) { $result.purgeBytes += $f.Length }
  if ($orphans.Count -gt 0) { $result.detail = "$($orphans.Count) of the deletions are sessions whose file is already gone" }
  if ($DryRun) { return $result }

  foreach ($f in $toArchive) {
    $len = $f.Length
    $r = Invoke-AicmWithTimeout $codex @('archive', (Get-AicmCodexId $f.Name)) 120
    if ($r.ExitCode -eq 0) { $result.removed++; $result.removedBytes += $len } else { $result.inUse++ }
  }
  foreach ($f in $toDelete) {
    $id = Get-AicmCodexId $f.Name
    $len = $f.Length
    $r = Invoke-AicmWithTimeout $codex @('delete', '--force', $id) 120
    if ($r.ExitCode -eq 0) { $result.purged++; $result.purgedBytes += $len; continue }
    # A file Codex does not know (older layout) cannot be orphaned; remove it directly.
    if ($threads -and -not $threads.ContainsKey($id) -and (Remove-FileQuietly $f)) { $result.purged++; $result.purgedBytes += $len; continue }
    $result.inUse++
  }
  $failed = @()
  foreach ($id in $orphans) {
    $r = Invoke-AicmWithTimeout $codex @('delete', '--force', $id) 120
    if ($r.ExitCode -eq 0) { $result.purged++ } else { $failed += $id }
  }
  if ($failed.Count -gt 0) {
    # Deleting a session also deletes the sub-agent sessions it spawned, so a later delete of one of
    # those fails although it is already gone. Count what the database no longer has as done.
    $after = Get-AicmCodexThreads $Root
    foreach ($id in $failed) { if ($after -and -not $after.ContainsKey($id)) { $result.purged++ } else { $result.inUse++ } }
  }
  return $result
}

function Invoke-CommandRule($Rule) {
  $cmd = Get-Command $Rule.Path -ErrorAction SilentlyContinue
  if (-not $cmd) { return [ordered]@{ status = 'not installed' } }
  $argList = @($Rule.Pattern -split '\s+' | Where-Object { $_ })
  if ($DryRun) { return [ordered]@{ status = "would run: $($Rule.Path) $($argList -join ' ')" } }
  $output = & $cmd.Source @argList 2>&1
  $rc = $LASTEXITCODE
  $lastLine = @($output | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | Select-Object -Last 1)
  if ($rc -ne 0) { throw "$($Rule.Path) $($argList -join ' ') exited with $rc" }
  $detail = if ($lastLine) { $lastLine[0].Trim() } else { 'done' }
  return [ordered]@{ status = "ran: $detail" }
}

function Remove-OldCleanLogs {
  if ($DryRun -or $LogRetentionDays -le 0) { return }
  $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
  Get-ChildItem -LiteralPath $LogDir -Filter 'clean-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

$allRules = @(Read-AicmRules $RulesFile $LocalRulesFile)
if ($selected.Count -gt 0) {
  $knownIds = @($allRules | ForEach-Object { $_.Id })
  $unknown = @($selected | Where-Object { $knownIds -notcontains $_ })
  if ($unknown.Count -gt 0) {
    Write-Host "unknown rule id: $($unknown -join ', ')"
    Write-Host "known ids: $($knownIds -join ', ')"
    exit 2
  }
}

$transcript = $null
if (-not $Report) {
  Initialize-AicmDirectory $LogDir
  $transcript = Join-Path $LogDir ("clean-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Start-Transcript -Path $transcript -Force | Out-Null
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$mutex = [System.Threading.Mutex]::new($false, "Local\ai-cli-auto-manager-clean-$($identity.User.Value)")
$hasLock = $false
$exitCode = 0
try {
  $hasLock = $mutex.WaitOne(0)
  if (-not $hasLock) {
    Write-Host "[$(Get-AicmTimestamp)] another cleanup run is already active"
    exit 0
  }

  $mode = if ($Report) { 'report' } elseif ($DryRun) { 'dry-run' } else { 'clean' }
  if (-not $Report) {
    Write-Host "[$(Get-AicmTimestamp)] AI leftover cleanup started (mode=$mode, version=$(Get-AicmVersion))"
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($rule in $allRules) {
    $explicit = $selected -contains $rule.Id
    if ($selected.Count -gt 0 -and -not $explicit) { continue }
    $row = [ordered]@{ id = $rule.Id; kind = $rule.Kind; enabled = ($rule.Enabled -or $explicit); path = $rule.Path; status = ''; files = 0; bytes = 0L; removed = 0; removedBytes = 0L; inUse = 0; purge = 0; purgeBytes = 0L; purged = 0; purgedBytes = 0L; detail = ''; totalBytes = $null; note = $rule.Note }
    $archiving = @('archive', 'codex') -contains $rule.Kind
    try {
      if ($rule.Kind -eq 'command') {
        $row.path = $rule.Path
        if (-not $row.enabled) { $row.status = 'off' }
        else { $row.status = (Invoke-CommandRule $rule).status }
      } else {
        $root = Expand-AicmPath $rule.Path
        $row.path = Get-DisplayPath $root
        if (-not (Test-AicmAllowedPath $root)) {
          $row.status = 'refused: outside home and temp'
          $errors.Add("$($rule.Id): path outside home and temp")
        } elseif (-not (Test-Path -LiteralPath $root -PathType Container)) {
          $row.status = 'not present'
        } elseif (Test-AicmLink (Get-Item -LiteralPath $root -Force)) {
          $row.status = 'skipped: path is a link'
        } else {
          if ($Report) { $row.totalBytes = Get-TreeBytes $root }
          $wasDry = $DryRun
          if (-not $row.enabled) { $DryRun = $true }
          try {
            $r = switch ($rule.Kind) {
              'age' { Invoke-AgeRule $rule $root }
              'cap' { Invoke-CapRule $rule $root }
              'keep-latest' { Invoke-KeepLatestRule $rule $root }
              'archive' { Invoke-ArchiveRule $rule $root $wasDry }
              'codex' { Invoke-CodexRule $rule $root }
            }
          } finally { $DryRun = $wasDry }
          foreach ($k in 'files', 'bytes', 'removed', 'removedBytes', 'inUse') { $row[$k] = $r[$k] }
          if ($archiving) { foreach ($k in 'purge', 'purgeBytes', 'purged', 'purgedBytes', 'detail') { $row[$k] = $r[$k] } }
          if (-not $row.enabled) { $row.status = 'off' }
          elseif ($archiving -and $DryRun) { $row.status = 'would archive' }
          elseif ($archiving) { $row.status = 'archived' }
          elseif ($DryRun) { $row.status = 'would remove' }
          else { $row.status = 'removed' }
        }
      }
    } catch {
      $row.status = "error: $($_.Exception.Message)"
      $errors.Add("$($rule.Id): $($_.Exception.Message)")
    }
    $rows.Add([pscustomobject]$row)
  }

  Write-Host ''
  foreach ($row in $rows) {
    $age = switch ($row.kind) { 'age' { 'age' } 'cap' { 'cap' } 'keep-latest' { 'keep' } 'archive' { 'arch' } 'codex' { 'arch' } default { 'cmd' } }
    $unit = if ($row.kind -eq 'keep-latest') { 'dirs ' } else { 'files' }
    $done = @('removed', 'archived') -contains $row.status
    $size = if ($row.kind -eq 'command') { '' } elseif ($done) { "{0,6} {1} {2,10}" -f $row.removed, $unit, (Format-AicmSize $row.removedBytes) } else { "{0,6} {1} {2,10}" -f $row.files, $unit, (Format-AicmSize $row.bytes) }
    $total = if ($null -ne $row.totalBytes) { "  of {0,10}" -f (Format-AicmSize $row.totalBytes) } else { '' }
    $busy = if ($row.inUse -gt 0) { " ($($row.inUse) in use or failed, kept)" } else { '' }
    $purgeText = ''
    if (@('archive', 'codex') -contains $row.kind -and $row.status -notlike 'not present*' -and $row.status -notlike 'refused*') {
      $purgeText = if ($done) { "; deleted from archive: $($row.purged) ($(Format-AicmSize $row.purgedBytes))" } else { "; would delete from archive: $($row.purge) ($(Format-AicmSize $row.purgeBytes))" }
    }
    Write-Host ("{0,-22} {1,-4} {2,-22}{3}  {4}{5}{6}  {7}" -f $row.id, $age, $size, $total, $row.status, $purgeText, $busy, $row.path)
    if ($row.detail) { Write-Host ("{0,-22} {1}" -f '', $row.detail) }
  }

  # Archiving moves files; only deletions free space.
  $plannedBytes = 0L; $freedBytes = 0L; $offBytes = 0L; $archiveBytes = 0L; $archivedBytes = 0L
  foreach ($row in $rows) {
    $isArchive = @('archive', 'codex') -contains $row.kind
    if (-not $row.enabled) {
      if ($isArchive) { $freedBytes += $row.purgedBytes } else { $offBytes += $row.bytes }
      continue
    }
    if ($isArchive) {
      $plannedBytes += $row.purgeBytes; $freedBytes += $row.purgedBytes
      $archiveBytes += $row.bytes; $archivedBytes += $row.removedBytes
    } else {
      $plannedBytes += $row.bytes; $freedBytes += $row.removedBytes
    }
  }
  Write-Host ''
  if ($DryRun) {
    Write-Host "reclaimable now: $(Format-AicmSize $plannedBytes)   to archive: $(Format-AicmSize $archiveBytes)"
  } else {
    Write-Host "freed: $(Format-AicmSize $freedBytes)   archived: $(Format-AicmSize $archivedBytes) (in $(Get-DisplayPath (Get-AicmArchiveRoot)) and ~\.codex\archived_sessions)"
  }
  if ($offBytes -gt 0) {
    Write-Host "also reclaimable by rules that are off: $(Format-AicmSize $offBytes) (turn on in $(Get-DisplayPath $LocalRulesFile))"
  }

  if (-not $DryRun) {
    Write-AicmState 'last-clean' ([ordered]@{
      finishedAt = Get-AicmTimestamp
      version = Get-AicmVersion
      ok = ($errors.Count -eq 0)
      freedBytes = [int64]$freedBytes
      errors = $errors.ToArray()
      archivedBytes = [int64]$archivedBytes
      rules = @($rows | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; removed = $_.removed; removedBytes = [int64]$_.removedBytes; purged = $_.purged; purgedBytes = [int64]$_.purgedBytes; inUse = $_.inUse } })
    })
    Remove-OldCleanLogs
  }

  $problems = @($errors) + @(Get-AicmScheduleProblems -Skip 'Clean')
  if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "problem: $p" }
    if (-not $DryRun) { Send-AicmNotification 'AI CLI Auto Manager' ("cleanup needs attention: " + ($problems -join '; ')) }
  }
  if ($errors.Count -gt 0) { $exitCode = 1 }
  if (-not $Report) {
    Write-Host "[$(Get-AicmTimestamp)] AI leftover cleanup finished (exit=$exitCode)"
  }
} finally {
  if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
  $mutex.Dispose()
  if ($transcript) { Stop-Transcript | Out-Null }
}
exit $exitCode
