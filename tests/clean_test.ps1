# Regression test for bin\clean_ai_leftovers.ps1. Runs against a throwaway profile folder, never the real one,
# with a fake `codex` command; the real Codex is never called. Works on Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aicm-test-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$fakeTemp = Join-Path $work 'tmp'
$fakeLocal = Join-Path $fakeHome 'AppData\Local'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$codexHome = Join-Path $fakeHome '.codex'
$fakeBin = Join-Path $work 'fakebin'
$outside = Join-Path $work 'outside'
$today = Get-Date -Format 'yyyyMMdd'
$script:fails = 0

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function Expect-Exists([string]$p, [string]$m) { if (Test-Path -LiteralPath $p) { Pass $m } else { Fail "$m ($p missing)" } }
function Expect-Gone([string]$p, [string]$m) { if (-not (Test-Path -LiteralPath $p)) { Pass $m } else { Fail "$m ($p still there)" } }
function Get-CodexCalls { if (Test-Path -LiteralPath "$work\codex-calls.log") { return @(Get-Content -LiteralPath "$work\codex-calls.log") } return @() }

function New-TestFile([string]$Path, [int]$DaysOld, [int]$Bytes = 16) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
  (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld)
}

function Invoke-Clean([string[]]$Arguments, [switch]$NoFakeCodex) {
  $exe = (Get-Process -Id $PID).Path
  $saved = @{}
  foreach ($k in 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'CODEX_HOME', 'PATH') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = $fakeTemp; $env:TMP = $fakeTemp
    $env:LOCALAPPDATA = $fakeLocal; $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_WORKTREES = '0'
    # If a real codex were ever reached, it would only see the throwaway home.
    $env:CODEX_HOME = $codexHome
    if (-not $NoFakeCodex) { $env:PATH = "$fakeBin;$($saved['PATH'])" }
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\clean_ai_leftovers.ps1') @Arguments 2>&1 | Out-String -Width 300
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

$U1 = '11111111-1111-4111-8111-111111111111'; $U2 = '22222222-2222-4222-8222-222222222222'
$U3 = '33333333-3333-4333-8333-333333333333'; $U4 = '44444444-4444-4444-8444-444444444444'
$UX = 'ffffffff-ffff-4fff-8fff-ffffffffffff'; $UO = '55555555-5555-4555-8555-555555555555'; $UY = '66666666-6666-4666-8666-666666666666'
$UE = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
$python = @('python', 'python3', 'py') | Where-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
$pythonPath = if ($python) { (Get-Command $python -CommandType Application | Select-Object -First 1).Source } else { 'python' }

try {
  New-Item -ItemType Directory -Path $fakeHome, $fakeTemp, $fakeLocal, $aicmHome, $outside, $fakeBin -Force | Out-Null

  # Fake codex (codex.ps1 and codex.cmd, like an npm install): records calls; archive moves the rollout
  # to archived_sessions, delete removes it. Ids starting with "ffffffff" fail, like unknown ids do.
  $impl = @'
$calls = '__WORK__\codex-calls.log'
$codexHome = '__CODEX__'
Add-Content -LiteralPath $calls -Value ($args -join ' ')
$id = $args[-1]
if ($id -like 'ffffffff*' -or $id -like 'eeeeeeee*') { Write-Output "Error: failed to $($args[0]) session"; exit 1 }
# Deleting session 55555555-... also deletes its sub-agent session eeeeeeee-..., like the real Codex does.
if ($args[0] -eq 'delete' -and $id -like '55555555*' -and (Test-Path -LiteralPath '__WORK__\dbdel.py')) {
  & '__PYTHON__' '__WORK__\dbdel.py' 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
}
switch ($args[0]) {
  'archive' {
    $f = Get-ChildItem -LiteralPath "$codexHome\sessions" -Recurse -File -Filter "*$id*" | Select-Object -First 1
    if (-not $f) { exit 1 }
    New-Item -ItemType Directory -Path "$codexHome\archived_sessions" -Force | Out-Null
    Move-Item -LiteralPath $f.FullName -Destination "$codexHome\archived_sessions\$($f.Name)"
  }
  'delete' { Get-ChildItem -LiteralPath $codexHome -Recurse -File -Filter "*$id*" -ErrorAction SilentlyContinue | Remove-Item -Force }
}
exit 0
'@
  $impl.Replace('__WORK__', $work).Replace('__CODEX__', $codexHome).Replace('__PYTHON__', $pythonPath) | Set-Content -LiteralPath "$fakeBin\codex-impl.ps1" -Encoding ASCII
  "& '$fakeBin\codex-impl.ps1' @args; exit `$LASTEXITCODE" | Set-Content -LiteralPath "$fakeBin\codex.ps1" -Encoding ASCII
  "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0codex-impl.ps1`" %*" | Set-Content -LiteralPath "$fakeBin\codex.cmd" -Encoding ASCII

  # age rule: old scratch file goes, new one stays, protected names stay, junctions are not followed.
  New-TestFile "$codexHome\.tmp\2026\08\old.bin" 40
  New-TestFile "$codexHome\.tmp\2026\10\new.bin" 1
  New-TestFile "$codexHome\.tmp\MEMORY.md" 90
  New-TestFile "$outside\precious.txt" 90
  New-Item -ItemType Junction -Path "$codexHome\.tmp\linked" -Target $outside | Out-Null
  # archive rule: Claude transcripts, only *.jsonl, memory folder untouched; Claude's own setting is 20 days.
  New-Item -ItemType Directory -Path "$fakeHome\.claude" -Force | Out-Null
  '{ "cleanupPeriodDays": 20 }' | Set-Content -LiteralPath "$fakeHome\.claude\settings.json" -Encoding ASCII
  New-TestFile "$fakeHome\.claude\projects\p\old.jsonl" 15
  New-TestFile "$fakeHome\.claude\projects\p\recent.jsonl" 10
  New-TestFile "$fakeHome\.claude\projects\p\notes.md" 40
  New-TestFile "$fakeHome\.claude\projects\p\memory\fact.md" 400
  New-TestFile "$aicmHome\archive\claude-transcripts\20200101\p\ancient.jsonl" 2000
  New-TestFile "$aicmHome\archive\claude-transcripts\$today\p\kept.jsonl" 15
  # codex rule: archive after 30 days, delete 60 days after that.
  New-TestFile "$codexHome\sessions\2026\08\01\rollout-2026-08-01T10-00-00-$U1.jsonl" 40
  New-TestFile "$codexHome\sessions\2026\10\01\rollout-2026-10-01T10-00-00-$U2.jsonl" 2
  New-TestFile "$codexHome\archived_sessions\rollout-2026-06-01T10-00-00-$U3.jsonl" 100
  New-TestFile "$codexHome\archived_sessions\rollout-2026-08-01T10-00-00-$U4.jsonl" 50
  New-TestFile "$codexHome\archived_sessions\rollout-2026-05-01T10-00-00-$UX.jsonl" 120
  New-TestFile "$fakeHome\.codex\generated_images\pic.png" 90
  New-TestFile "$fakeHome\.codex\logs_2.sqlite" 1 2097152
  New-TestFile "$fakeHome\.codex\logs_2.sqlite-wal" 1 10
  New-TestFile "$fakeHome\.codex\logs_9.sqlite" 1 10
  New-TestFile "$fakeTemp\claude\old\diff.txt" 5
  New-TestFile "$fakeTemp\claude\new\diff.txt" 0
  New-TestFile "$fakeTemp\stale.tmp" 10
  New-TestFile "$fakeTemp\fresh.tmp" 1
  foreach ($b in 1000, 1100, 1200) { New-TestFile "$fakeLocal\ms-playwright\chromium-$b\chrome.exe" 1 }
  New-TestFile "$fakeLocal\ms-playwright\ffmpeg\ffmpeg.exe" 1
  New-Item -ItemType Junction -Path "$fakeLocal\ms-playwright\chromium-1000\linked" -Target $outside | Out-Null

  # Codex database with two sessions whose file is already gone (100 and 50 days unused), when Python exists.
  $dbOk = $false
  if ($python) {
    $now = [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
    $sql = "create table threads (id text, rollout_path text, updated_at integer, archived integer);" +
      "insert into threads values ('$U1', '$($codexHome -replace '\\', '/')/sessions/x-$U1.jsonl', $($now - 40 * 86400), 0);" +
      "insert into threads values ('$UO', '$($codexHome -replace '\\', '/')/sessions/gone-$UO.jsonl', $($now - 100 * 86400), 0);" +
      "insert into threads values ('$UY', '$($codexHome -replace '\\', '/')/sessions/gone-$UY.jsonl', $($now - 50 * 86400), 0);" +
      "insert into threads values ('$UE', '$($codexHome -replace '\\', '/')/sessions/gone-$UE.jsonl', $($now - 100 * 86400), 0);"
    & $python -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit()' "$codexHome\state_5.sqlite" $sql
    $dbOk = ($LASTEXITCODE -eq 0)
    "import sqlite3,sys`nc=sqlite3.connect(r'$codexHome\state_5.sqlite')`nc.execute('delete from threads where id = ?', (sys.argv[1],))`nc.commit()" |
      Set-Content -LiteralPath "$work\dbdel.py" -Encoding ASCII
  }

  @(
    'codex-trace-db      | all     | cap         | ~/.codex                     | logs_*.sqlite | 30 | 1 | on |'
    'codex-sessions      | all     | codex       | ~/.codex                     | rollout-*     | 30 | 60 | on |'
    'claude-transcripts  | all     | archive     | ~/.claude/projects           | *.jsonl       | 30 | 60 | on |'
    'playwright-browsers | windows | keep-latest | {localappdata}/ms-playwright | *             |    | 2 | on |'
    'escape-home         | all     | age         | ~/../escape                  | *             | 1  |   | on |'
    'home-itself         | all     | age         | ~                            | *             | 1  |   | on |'
    'system-dir          | all     | age         | C:/Windows                   | *             | 1  |   | on |'
  ) | Set-Content -LiteralPath "$aicmHome\clean-rules.local.conf" -Encoding UTF8

  Write-Host '# dry run'
  $r = Invoke-Clean @('-DryRun')
  Write-Host $r.Output
  if ($r.ExitCode -eq 1) { Pass 'dry run reports refused rules with exit 1' } else { Fail "dry run exit was $($r.ExitCode)" }
  Expect-Exists "$codexHome\.tmp\2026\08\old.bin" 'dry run removes nothing'
  Expect-Exists "$fakeHome\.claude\projects\p\old.jsonl" 'dry run archives nothing'
  Expect-Exists "$fakeLocal\ms-playwright\chromium-1000" 'dry run keeps old builds'
  if (@(Get-CodexCalls).Count -eq 0) { Pass 'dry run does not call codex' } else { Fail 'dry run called codex' }
  if ($r.Output -match 'refused') { Pass 'outside paths are refused' } else { Fail 'refused rows missing' }
  if ($r.Output -match 'would remove' -and $r.Output -match 'would archive') { Pass 'dry run wording' } else { Fail 'dry run wording' }
  if ($r.Output -match 'archive after 12d \(the CLI deletes after 20d\)') { Pass "archives a week before Claude's own cleanup" } else { Fail 'native retention' }

  Write-Host '# real run'
  $r = Invoke-Clean @()
  Write-Host $r.Output
  Expect-Gone "$codexHome\.tmp\2026\08\old.bin" 'old scratch file removed'
  Expect-Gone "$codexHome\.tmp\2026\08" 'emptied folder pruned'
  Expect-Exists "$codexHome\.tmp" 'rule root kept'
  Expect-Exists "$codexHome\.tmp\2026\10\new.bin" 'fresh scratch file kept'
  Expect-Exists "$codexHome\.tmp\MEMORY.md" 'protected name kept'
  Expect-Exists "$outside\precious.txt" 'junction target outside never touched'
  Expect-Exists "$codexHome\.tmp\linked" 'junction itself kept by age rule'

  Expect-Gone "$fakeHome\.claude\projects\p\old.jsonl" 'transcript older than the archive age left the project folder'
  Expect-Exists "$aicmHome\archive\claude-transcripts\$today\p\old.jsonl" '... and sits in todays archive with its relative path'
  Expect-Exists "$fakeHome\.claude\projects\p\recent.jsonl" 'recent transcript kept in place'
  Expect-Exists "$fakeHome\.claude\projects\p\notes.md" 'pattern limits to *.jsonl'
  Expect-Exists "$fakeHome\.claude\projects\p\memory\fact.md" 'memory folder kept'
  Expect-Gone "$aicmHome\archive\claude-transcripts\20200101" 'archive folder past its limit deleted (remnants)'
  Expect-Exists "$aicmHome\archive\claude-transcripts\$today\p\kept.jsonl" 'todays archive folder kept'

  $calls = @(Get-CodexCalls)
  if ($calls -contains "archive $U1") { Pass 'codex session unused 30+ days archived with codex archive' } else { Fail "codex archive: $calls" }
  Expect-Exists "$codexHome\archived_sessions\rollout-2026-08-01T10-00-00-$U1.jsonl" '... and Codex moved it to archived_sessions'
  if (-not ($calls -match $U2)) { Pass 'recent codex session untouched' } else { Fail 'recent codex session touched' }
  if ($calls -contains "delete --force $U3") { Pass 'archived session unused 90+ days deleted with codex delete' } else { Fail 'codex delete' }
  if (-not ($calls -match $U4)) { Pass 'archived session younger than 90 days kept' } else { Fail 'young archived session touched' }
  Expect-Exists "$codexHome\archived_sessions\rollout-2026-08-01T10-00-00-$U4.jsonl" '... file still there'
  if ($dbOk) {
    if ($calls -contains "delete --force $UO") { Pass 'session whose file is gone and unused 90+ days deleted' } else { Fail 'orphan delete' }
    if (-not ($calls -match $UY)) { Pass 'session whose file is gone but used within 90 days kept' } else { Fail 'young orphan touched' }
    $codexRow = @($r.Output -split "`r?`n" | Where-Object { $_ -like 'codex-sessions *' }) | Select-Object -First 1
    if ($codexRow -and $codexRow -notmatch 'in use or failed') { Pass 'sub-agent session removed with its parent is not reported as failed' } else { Fail "sub-agent recount: $codexRow" }
    Expect-Gone "$codexHome\archived_sessions\rollout-2026-05-01T10-00-00-$UX.jsonl" 'file Codex does not know is removed directly'
  } else {
    Write-Host 'skip - Codex database checks (no Python here)'
  }

  Expect-Exists "$fakeHome\.codex\generated_images\pic.png" 'off rule keeps files'
  Expect-Gone "$fakeHome\.codex\logs_2.sqlite" 'oversized trace DB removed'
  Expect-Gone "$fakeHome\.codex\logs_2.sqlite-wal" 'trace DB sidecar removed'
  Expect-Exists "$fakeHome\.codex\logs_9.sqlite" 'small fresh DB kept'
  Expect-Gone "$fakeTemp\claude\old\diff.txt" 'old claude temp removed'
  Expect-Exists "$fakeTemp\claude\new\diff.txt" 'fresh claude temp kept'
  Expect-Gone "$fakeTemp\stale.tmp" 'stale temp file removed'
  Expect-Exists "$fakeTemp\fresh.tmp" 'fresh temp file kept'
  Expect-Gone "$fakeLocal\ms-playwright\chromium-1000" 'oldest build removed'
  Expect-Exists "$fakeLocal\ms-playwright\chromium-1100" 'second newest build kept'
  Expect-Exists "$fakeLocal\ms-playwright\chromium-1200" 'newest build kept'
  Expect-Exists "$fakeLocal\ms-playwright\ffmpeg" 'unversioned folder kept'
  Expect-Exists "$outside\precious.txt" 'junction inside removed build not followed'
  Expect-Exists "$aicmHome\state\last-clean.json" 'state file written'
  $state = Get-Content -LiteralPath "$aicmHome\state\last-clean.json" -Raw | ConvertFrom-Json
  if (-not $state.ok) { Pass 'state records refused rules' } else { Fail 'state ok flag' }

  Write-Host '# file in use is kept, not an error'
  New-TestFile "$codexHome\.tmp\busy.bin" 40
  $lock = [System.IO.File]::Open("$codexHome\.tmp\busy.bin", 'Open', 'Read', 'None')
  try { $r = Invoke-Clean @('-Rules', 'codex-tmp') } finally { $lock.Dispose() }
  Expect-Exists "$codexHome\.tmp\busy.bin" 'locked file kept'
  if ($r.ExitCode -eq 0 -and $r.Output -match 'in use') { Pass 'locked file reported as in use' } else { Fail "locked file handling (exit $($r.ExitCode))" }

  Write-Host '# without a codex command nothing of Codex is touched'
  New-TestFile "$codexHome\sessions\2026\07\01\rollout-2026-07-01T10-00-00-$U2.jsonl" 60
  # Only where no real codex exists: never let a test reach the real Codex.
  if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host 'skip - a real codex is installed on this machine'
  } else {
    $r = Invoke-Clean @('-Rules', 'codex-sessions') -NoFakeCodex
    if ($r.Output -match 'codex command not found: nothing touched') { Pass 'missing codex command reported' } else { Fail 'missing codex' }
    Expect-Exists "$codexHome\sessions\2026\07\01\rollout-2026-07-01T10-00-00-$U2.jsonl" 'codex files kept without the codex command'
  }

  Write-Host '# defaults: Codex sessions deleted after 30 days, Claude transcripts left to Claude, archive remnants purged'
  $local = @(Get-Content -LiteralPath "$aicmHome\clean-rules.local.conf" | Where-Object { $_ -notlike 'codex-sessions*' -and $_ -notlike 'claude-transcripts*' })
  $local | Set-Content -LiteralPath "$aicmHome\clean-rules.local.conf" -Encoding UTF8
  $U7 = '77777777-7777-4777-8777-777777777777'
  New-TestFile "$codexHome\sessions\2026\08\02\rollout-2026-08-02T10-00-00-$U7.jsonl" 40
  New-TestFile "$fakeHome\.claude\projects\q\old.jsonl" 40
  New-TestFile "$aicmHome\archive\claude-transcripts\20200102\q\ancient.jsonl" 2000
  Remove-Item -LiteralPath "$work\codex-calls.log" -ErrorAction SilentlyContinue
  $null = Invoke-Clean @('-Rules', 'codex-sessions')
  $calls = @(Get-CodexCalls)
  if ($calls -contains "delete --force $U7" -and -not ($calls -like 'archive*')) { Pass 'default: unused 30+ days goes straight to codex delete' } else { Fail "default codex delete: $calls" }
  $null = Invoke-Clean @()
  Expect-Exists "$fakeHome\.claude\projects\q\old.jsonl" "default: Claude transcripts left to Claude's own cleanup"
  Expect-Gone "$aicmHome\archive\claude-transcripts\20200102" 'default: old archive remnants purged although the rule is off'

  Write-Host '# explicit rule runs even when off'
  $null = Invoke-Clean @('-Rules', 'codex-images')
  Expect-Gone "$fakeHome\.codex\generated_images\pic.png" '-Rules runs an off rule'
  Expect-Exists "$aicmHome\archive\codex-images\$today\pic.png" '... and archives it'

  Write-Host '# unknown rule id'
  $r = Invoke-Clean @('-Rules', 'nope')
  if ($r.ExitCode -eq 2) { Pass 'unknown id rejected' } else { Fail "unknown id exit $($r.ExitCode)" }

  Write-Host '# bad rule file'
  'x | all | weird | ~/.x | * | 1 | | on |' | Set-Content -LiteralPath "$work\bad.conf" -Encoding UTF8
  $r = Invoke-Clean @('-DryRun', '-LocalRulesFile', "$work\bad.conf")
  if ($r.ExitCode -ne 0) { Pass 'bad kind rejected' } else { Fail 'bad kind accepted' }
  'x | all | archive | ~/.x | * | 30 | | on |' | Set-Content -LiteralPath "$work\bad2.conf" -Encoding UTF8
  $r = Invoke-Clean @('-DryRun', '-LocalRulesFile', "$work\bad2.conf")
  if ($r.ExitCode -ne 0) { Pass 'archive rule needs a delete-after limit' } else { Fail 'archive rule without limit accepted' }
} finally {
  # Unlink junctions before removing the work folder so their targets are never walked.
  foreach ($j in "$codexHome\.tmp\linked", "$fakeLocal\ms-playwright\chromium-1000\linked") {
    if (Test-Path -LiteralPath $j) { [System.IO.Directory]::Delete($j, $false) }
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
