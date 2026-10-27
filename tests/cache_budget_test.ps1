# Budget cleanup rules (Invoke-AicmBudget in lib\aicm-common.ps1, Invoke-BudgetRule in
# bin\clean_ai_leftovers.ps1). The engine checks run on Windows PowerShell 5.1, PowerShell 7 and also
# PowerShell 7 on macOS/Linux, against throwaway folders only, with a recording deleter. On Windows the
# cleanup script itself also runs end to end: FileGuard keeps a file another handle holds open.
# Multi-GiB counts are checked arithmetically on Windows (no large files are allocated there) and with
# a sparse file elsewhere.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$script:fails = 0
function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function P([string[]]$Parts) { $p = $Parts[0]; foreach ($x in $Parts[1..($Parts.Count - 1)]) { $p = Join-Path $p $x }; return $p }
$onWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')

function New-CacheFile([string]$Path, [int]$DaysOld, [int]$Bytes = 1048576) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
  [System.IO.File]::SetLastWriteTimeUtc($Path, (Get-Date).ToUniversalTime().AddDays(-$DaysOld))
}
function New-Rule([int]$Days, [int]$Limit, [string]$Pattern = '*') {
  return [pscustomobject]@{ Id = 'npm-cache'; Kind = 'budget'; Days = $Days; Limit = $Limit; Pattern = $Pattern; Enabled = $true; Note = '' }
}
# Records the order of deletions; files named in $script:busy are "in use" and kept.
$script:deleted = New-Object System.Collections.Generic.List[string]
$script:busy = @()
$recordingDelete = {
  param([System.IO.FileInfo]$File)
  if ($script:busy -contains $File.Name) { return $false }
  $script:deleted.Add($File.Name)
  [System.IO.File]::Delete($File.FullName)
  return (-not (Test-Path -LiteralPath $File.FullName))
}

. (P @($root, 'lib', 'aicm-common.ps1'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
  Write-Host '# rule grammar'
  $bad = 0
  foreach ($line in @('x | all | budget | ~/c | * | 0 | 5 | on | n', 'x | all | budget | ~/c | * | 30 | 0 | on | n', 'x | all | budget | ~/c | * | 30 |  | on | n')) {
    try { [void](ConvertFrom-AicmRuleLine $line 'test.conf') } catch { $bad++ }
  }
  if ($bad -eq 3) { Pass 'budget rules need days >= 1 and limit >= 1' } else { Fail "zero or missing budget values accepted ($bad of 3 refused)" }
  $threw = $false
  try { [void](ConvertFrom-AicmRuleLine 'x | all | budget | ~/c | * | 30 | 5x | on | n' 'test.conf') } catch { $threw = $true }
  if ($threw) { Pass 'a malformed budget limit is refused' } else { Fail 'malformed budget limit accepted' }
  $ok = ConvertFrom-AicmRuleLine 'npm-cache | all | budget | ~/.npm/_cacache | * | 30 | 2048 | on | n' 'local.conf'
  if ($ok.Kind -eq 'budget' -and $ok.Limit -eq 2048 -and $ok.Days -eq 30) { Pass 'a local budget override parses' } else { Fail 'budget override did not parse' }
  $defaults = @(Read-AicmRules (P @($root, 'rules', 'clean-rules.conf')) '')
  if (@($defaults | Where-Object { $_.Kind -eq 'budget' }).Count -eq 0) { Pass 'no default rule is a budget rule' } else { Fail 'a default rule became a budget rule' }

  Write-Host '# over budget: oldest first, protected/recent/SQLite kept'
  $cache = P @($work, 'c1')
  New-CacheFile (P @($cache, 'a', 'oldest.bin')) 90
  New-CacheFile (P @($cache, 'b', 'older.bin')) 60
  New-CacheFile (P @($cache, 'old.bin')) 45
  New-CacheFile (P @($cache, 'fresh.bin')) 0
  New-CacheFile (P @($cache, '.env')) 120
  New-CacheFile (P @($cache, 'index.sqlite')) 120
  New-CacheFile (P @($cache, 'index.sqlite-wal')) 120
  $preview = Invoke-AicmBudget (New-Rule 30 4) $cache $true $recordingDelete
  if ($script:deleted.Count -eq 0 -and (Test-Path -LiteralPath (P @($cache, 'a', 'oldest.bin')))) { Pass 'a preview deletes nothing' } else { Fail 'preview deleted files' }
  if ($preview.totalBytes -eq 7MB -and $preview.budgetBytes -eq 4MB -and $preview.projectedRemainingBytes -eq 4MB -and $preview.remainingBytes -eq 7MB -and $preview.files -eq 3 -and $preview.scanStatus -eq 'complete') {
    Pass 'preview: total, budget and projection'
  } else { Fail "preview numbers: $($preview | ConvertTo-Json -Compress)" }
  $run = Invoke-AicmBudget (New-Rule 30 5) $cache $false $recordingDelete
  if (($script:deleted -join ',') -eq 'oldest.bin,older.bin') { Pass 'oldest modification time goes first and deletion stops at the budget' } else { Fail "deleted: $($script:deleted -join ',')" }
  $kept = @('old.bin', 'fresh.bin', '.env', 'index.sqlite', 'index.sqlite-wal' | Where-Object { Test-Path -LiteralPath (P @($cache, $_)) })
  if ($kept.Count -eq 5) { Pass 'protected, recent, SQLite and not-needed files stay' } else { Fail "kept only: $($kept -join ',')" }
  if ($run.remainingBytes -eq 5MB -and $run.budgetUnmetBytes -eq 0 -and $run.removedBytes -eq 2MB) { Pass 'a real run reports what is left' } else { Fail "run numbers: $($run | ConvertTo-Json -Compress)" }

  Write-Host '# budget out of reach'
  $script:deleted.Clear()
  $cache2 = P @($work, 'c2')
  New-CacheFile (P @($cache2, 'old.bin')) 90
  New-CacheFile (P @($cache2, 'busy.bin')) 95
  New-CacheFile (P @($cache2, 'new.bin')) 1
  New-CacheFile (P @($cache2, 'credentials.json')) 90
  $script:busy = @('busy.bin')
  $r2 = Invoke-AicmBudget (New-Rule 30 1) $cache2 $false $recordingDelete
  $script:busy = @()
  if (($script:deleted -join ',') -eq 'old.bin' -and $r2.inUse -eq 1 -and (Test-Path -LiteralPath (P @($cache2, 'busy.bin')))) { Pass 'a file in use is kept and the next oldest is tried' } else { Fail "busy: deleted=$($script:deleted -join ',') inUse=$($r2.inUse)" }
  if ($r2.remainingBytes -eq 3MB -and $r2.budgetUnmetBytes -eq 2MB -and $r2.detail -like 'budget not reachable*') { Pass 'an unreachable budget is reported' } else { Fail "unmet: $($r2 | ConvertTo-Json -Compress)" }

  Write-Host '# under budget'
  $script:deleted.Clear()
  $r3 = Invoke-AicmBudget (New-Rule 30 100) $cache2 $false $recordingDelete
  if ($script:deleted.Count -eq 0 -and $r3.files -eq 0 -and $r3.budgetUnmetBytes -eq 0 -and $r3.remainingBytes -eq 3MB) { Pass 'under budget nothing is deleted' } else { Fail 'under budget deleted files' }

  Write-Host '# a scan that is not complete deletes nothing'
  $cache3 = P @($work, 'c3')
  New-CacheFile (P @($cache3, 'x', 'y', 'z', 'deep.bin')) 90
  New-CacheFile (P @($cache3, 'top.bin')) 90
  $env:AICM_BUDGET_MAX_DEPTH = '2'
  try { $r4 = Invoke-AicmBudget (New-Rule 30 1) $cache3 $false $recordingDelete } finally { Remove-Item Env:\AICM_BUDGET_MAX_DEPTH }
  if ($r4.scanStatus -eq 'partial' -and $script:deleted.Count -eq 0 -and (Test-Path -LiteralPath (P @($cache3, 'top.bin')))) { Pass 'the depth bound makes the scan partial and nothing is deleted' } else { Fail "depth: $($r4.scanStatus) deleted=$($script:deleted -join ',')" }
  $env:AICM_BUDGET_MAX_FILES = '1'
  try { $r5 = Invoke-AicmBudget (New-Rule 30 1) $cache3 $false $recordingDelete } finally { Remove-Item Env:\AICM_BUDGET_MAX_FILES }
  if ($r5.scanStatus -eq 'partial' -and $script:deleted.Count -eq 0) { Pass 'the file-count bound makes the scan partial' } else { Fail "count: $($r5.scanStatus)" }
  $r6 = Invoke-AicmBudget (New-Rule 30 1) (P @($work, 'missing')) $false $recordingDelete
  if ($r6.scanStatus -eq 'unavailable' -and $r6.totalBytes -eq 0) { Pass 'a missing root is unavailable, not an empty cache' } else { Fail "missing root: $($r6.scanStatus)" }

  Write-Host '# links are neither followed nor counted'
  $cache4 = P @($work, 'c4'); $outside = P @($work, 'outside')
  New-CacheFile (P @($outside, 'victim.bin')) 90
  New-CacheFile (P @($cache4, 'old.bin')) 90
  $linked = $false
  try {
    if ($onWindows) { cmd /c mklink /J (P @($cache4, 'jump')) $outside 2>&1 | Out-Null } else { New-Item -ItemType SymbolicLink -Path (P @($cache4, 'jump')) -Target $outside | Out-Null }
    $linked = Test-Path -LiteralPath (P @($cache4, 'jump', 'victim.bin'))
  } catch { $linked = $false }
  if ($linked) {
    $script:deleted.Clear()
    $r7 = Invoke-AicmBudget (New-Rule 30 0) $cache4 $false $recordingDelete
    if ((Test-Path -LiteralPath (P @($outside, 'victim.bin'))) -and $r7.totalBytes -eq 1MB) { Pass 'a link inside the cache is not entered' } else { Fail "link followed: total=$($r7.totalBytes)" }
  } else { Write-Host 'skip - link creation not permitted here' }

  Write-Host '# a rule folder replaced by a link during the run'
  $cache6 = P @($work, 'c6'); $moved = P @($work, 'c6-moved')
  New-CacheFile (P @($cache6, 'first.bin')) 90
  New-CacheFile (P @($cache6, 'second.bin')) 80
  New-CacheFile (P @($cache6, 'third.bin')) 70
  $script:swapped = $false
  $swapDelete = {
    param([System.IO.FileInfo]$File)
    [System.IO.File]::Delete($File.FullName)
    if (-not $script:swapped) {
      $script:swapped = $true
      [System.IO.Directory]::Move($cache6, $moved)
      try {
        if ($onWindows) { cmd /c mklink /J $cache6 $moved 2>&1 | Out-Null } else { New-Item -ItemType SymbolicLink -Path $cache6 -Target $moved | Out-Null }
      } catch { }
    }
    return $true
  }
  $r9 = Invoke-AicmBudget (New-Rule 30 0) $cache6 $false $swapDelete
  if ((Test-Path -LiteralPath (P @($moved, 'second.bin'))) -and (Test-Path -LiteralPath (P @($moved, 'third.bin'))) -and $r9.scanStatus -eq 'partial' -and $r9.removed -eq 1) {
    Pass 'deletion stops once the rule folder is replaced by a link'
  } else { Fail "root swap: removed=$($r9.removed) scan=$($r9.scanStatus) $(Get-ChildItem -LiteralPath $moved | ForEach-Object Name)" }

  Write-Host '# counts above 2 GiB'
  $big = Invoke-AicmBudget (New-Rule 30 4096) $cache2 $true $recordingDelete
  if ($big.budgetBytes -eq 4294967296L) { Pass 'a 4096 MiB budget is 4294967296 bytes (64-bit)' } else { Fail "budget bytes: $($big.budgetBytes)" }
  if (-not $onWindows) {
    $cache5 = P @($work, 'c5'); New-Item -ItemType Directory -Path $cache5 -Force | Out-Null
    foreach ($pair in @(@('three.bin', 3221225472L), @('one.bin', 1073741824L))) {
      $fs = [System.IO.File]::Open((P @($cache5, $pair[0])), 'CreateNew')
      try { $fs.SetLength($pair[1]) } finally { $fs.Dispose() }
    }
    $r8 = Invoke-AicmBudget (New-Rule 30 1) $cache5 $true $recordingDelete
    if ($r8.totalBytes -eq 4294967296L) { Pass 'sparse 3 GiB + 1 GiB counts 4294967296 logical bytes' } else { Fail "sparse total: $($r8.totalBytes)" }
  }

  if ($onWindows) {
    Write-Host '# end to end on Windows: FileGuard keeps an open file'
    $fakeHome = P @($work, 'home'); $aicmHome = P @($fakeHome, '.ai-cli-auto-manager')
    $c = P @($fakeHome, 'cache')
    New-CacheFile (P @($c, 'held.bin')) 90
    New-CacheFile (P @($c, 'old.bin')) 80
    New-CacheFile (P @($c, 'fresh.bin')) 0
    $rules = P @($work, 'rules.conf')
    [System.IO.File]::WriteAllText($rules, "npm-cache | all | budget | ~/cache | * | 30 | 1 | on | fixture`n")
    $saved = @{}
    foreach ($k in 'USERPROFILE', 'HOME', 'AICM_HOME', 'AICM_NOTIFY', 'AICM_WORKTREES', 'AICM_PROCESSES', 'AICM_CLOCK_CHECK') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    $held = [System.IO.File]::Open((P @($c, 'held.bin')), 'Open', 'Read', 'Read')
    try {
      $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome; $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_WORKTREES = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_CLOCK_CHECK = '0'
      $exe = (Get-Process -Id $PID).Path
      # Windows PowerShell turns native stderr into ErrorRecords even when redirected.
      $savedPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (P @($root, 'bin', 'clean_ai_leftovers.ps1')) -RulesFile $rules -LocalRulesFile (P @($work, 'none.conf')) -Json 2>$null | Out-String
      $childExit = $LASTEXITCODE
      $ErrorActionPreference = $savedPreference
      if ($childExit -ne 0) { throw "cleanup exited ${childExit}: $out" }
      $doc = $out | ConvertFrom-Json
      $rule = @($doc.rules)[0]
      if ((Test-Path -LiteralPath (P @($c, 'held.bin'))) -and -not (Test-Path -LiteralPath (P @($c, 'old.bin'))) -and (Test-Path -LiteralPath (P @($c, 'fresh.bin')))) { Pass 'the open file is kept, the next oldest goes' } else { Fail "end to end: $out" }
      if ($rule.scanStatus -eq 'complete' -and $rule.budgetBytes -eq 1048576 -and $rule.inUse -eq 1 -and $rule.budgetUnmetBytes -eq 1048576) { Pass 'JSON reports the busy file and the unmet budget' } else { Fail "JSON: $out" }
    } finally {
      $held.Dispose()
      foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
  }
} finally {
  if (Test-Path -LiteralPath $work) {
    if ($onWindows) { . (P @($PSScriptRoot, 'test-env.ps1')); Remove-TestWorkspace $work } else { Remove-Item -LiteralPath $work -Recurse -Force }
  }
}

Write-Host ''
if ($script:fails) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
