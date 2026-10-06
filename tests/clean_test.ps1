# Regression test for bin\clean_ai_leftovers.ps1. Runs against a throwaway profile folder, never the real one.
# Works on Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aicm-test-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$fakeTemp = Join-Path $work 'tmp'
$fakeLocal = Join-Path $fakeHome 'AppData\Local'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$outside = Join-Path $work 'outside'
$script:fails = 0

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function Expect-Exists([string]$p, [string]$m) { if (Test-Path -LiteralPath $p) { Pass $m } else { Fail "$m ($p missing)" } }
function Expect-Gone([string]$p, [string]$m) { if (-not (Test-Path -LiteralPath $p)) { Pass $m } else { Fail "$m ($p still there)" } }

function New-TestFile([string]$Path, [int]$DaysOld, [int]$Bytes = 16) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
  (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld)
}

function Invoke-Clean([string[]]$Arguments) {
  $exe = (Get-Process -Id $PID).Path
  $saved = @{}
  foreach ($k in 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = $fakeTemp; $env:TMP = $fakeTemp
    $env:LOCALAPPDATA = $fakeLocal; $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\clean_ai_leftovers.ps1') @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

try {
  New-Item -ItemType Directory -Path $fakeHome, $fakeTemp, $fakeLocal, $aicmHome, $outside -Force | Out-Null

  New-TestFile "$fakeHome\.codex\sessions\2026\08\old.jsonl" 40
  New-TestFile "$fakeHome\.codex\sessions\2026\10\new.jsonl" 1
  New-TestFile "$fakeHome\.codex\sessions\MEMORY.md" 90
  New-TestFile "$outside\precious.txt" 90
  New-Item -ItemType Junction -Path "$fakeHome\.codex\sessions\linked" -Target $outside | Out-Null
  New-TestFile "$fakeHome\.claude\projects\p\old.jsonl" 40
  New-TestFile "$fakeHome\.claude\projects\p\notes.md" 40
  New-TestFile "$fakeHome\.claude\projects\p\memory\fact.md" 400
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

  @(
    'codex-trace-db      | all     | cap         | ~/.codex                     | logs_*.sqlite | 30 | 1 | on |'
    'playwright-browsers | windows | keep-latest | {localappdata}/ms-playwright | *             |    | 2 | on |'
    'escape-home         | all     | age         | ~/../escape                  | *             | 1  |   | on |'
    'home-itself         | all     | age         | ~                            | *             | 1  |   | on |'
    'system-dir          | all     | age         | C:/Windows                   | *             | 1  |   | on |'
  ) | Set-Content -LiteralPath "$aicmHome\clean-rules.local.conf" -Encoding UTF8

  Write-Host '# dry run'
  $r = Invoke-Clean @('-DryRun')
  Write-Host $r.Output
  if ($r.ExitCode -eq 1) { Pass 'dry run reports refused rules with exit 1' } else { Fail "dry run exit was $($r.ExitCode)" }
  Expect-Exists "$fakeHome\.codex\sessions\2026\08\old.jsonl" 'dry run removes nothing'
  Expect-Exists "$fakeLocal\ms-playwright\chromium-1000" 'dry run keeps old builds'
  if ($r.Output -match 'refused') { Pass 'outside paths are refused' } else { Fail 'refused rows missing' }
  if ($r.Output -match 'would remove') { Pass 'dry run says would remove' } else { Fail 'dry run wording' }

  Write-Host '# real run'
  $r = Invoke-Clean @()
  Write-Host $r.Output
  Expect-Gone "$fakeHome\.codex\sessions\2026\08\old.jsonl" 'old transcript removed'
  Expect-Gone "$fakeHome\.codex\sessions\2026\08" 'emptied folder pruned'
  Expect-Exists "$fakeHome\.codex\sessions" 'rule root kept'
  Expect-Exists "$fakeHome\.codex\sessions\2026\10\new.jsonl" 'fresh transcript kept'
  Expect-Exists "$fakeHome\.codex\sessions\MEMORY.md" 'protected name kept'
  Expect-Exists "$outside\precious.txt" 'junction target outside never touched'
  Expect-Exists "$fakeHome\.codex\sessions\linked" 'junction itself kept by age rule'
  Expect-Gone "$fakeHome\.claude\projects\p\old.jsonl" 'old claude transcript removed'
  Expect-Exists "$fakeHome\.claude\projects\p\notes.md" 'pattern limits to *.jsonl'
  Expect-Exists "$fakeHome\.claude\projects\p\memory\fact.md" 'memory folder kept'
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
  New-TestFile "$fakeHome\.codex\sessions\busy.jsonl" 40
  $lock = [System.IO.File]::Open("$fakeHome\.codex\sessions\busy.jsonl", 'Open', 'Read', 'None')
  try { $r = Invoke-Clean @('-Rules', 'codex-sessions') } finally { $lock.Dispose() }
  Expect-Exists "$fakeHome\.codex\sessions\busy.jsonl" 'locked file kept'
  if ($r.ExitCode -eq 0 -and $r.Output -match 'in use') { Pass 'locked file reported as in use' } else { Fail "locked file handling (exit $($r.ExitCode))" }

  Write-Host '# explicit rule runs even when off'
  $null = Invoke-Clean @('-Rules', 'codex-images')
  Expect-Gone "$fakeHome\.codex\generated_images\pic.png" '-Rules runs an off rule'

  Write-Host '# unknown rule id'
  $r = Invoke-Clean @('-Rules', 'nope')
  if ($r.ExitCode -eq 2) { Pass 'unknown id rejected' } else { Fail "unknown id exit $($r.ExitCode)" }

  Write-Host '# bad rule file'
  'x | all | weird | ~/.x | * | 1 | | on |' | Set-Content -LiteralPath "$work\bad.conf" -Encoding UTF8
  $r = Invoke-Clean @('-DryRun', '-LocalRulesFile', "$work\bad.conf")
  if ($r.ExitCode -ne 0) { Pass 'bad kind rejected' } else { Fail 'bad kind accepted' }
} finally {
  # Unlink junctions before removing the work folder so their targets are never walked.
  foreach ($j in "$fakeHome\.codex\sessions\linked", "$fakeLocal\ms-playwright\chromium-1000\linked") {
    if (Test-Path -LiteralPath $j) { [System.IO.Directory]::Delete($j, $false) }
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
