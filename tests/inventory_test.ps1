# Tests for bin\inventory_ai_clis.ps1 and the update path for npm-managed CLIs on Windows (waiting period,
# red-flag checks, staged signature check, catalog-driven updates).
# Uses fake CLIs and a fake npm (tests\fixtures\npm-fake.js) in a throwaway profile folder;
# real CLIs and the real npm are never run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aicm-test-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$fakeBin = Join-Path $work 'fakebin'
$prefix = Join-Path $work 'npmprefix'
$npmRoot = Join-Path $prefix 'node_modules'
$solo = Join-Path $work 'solo'
$fake = Join-Path $root 'tests\fixtures\npm-fake.js'
$script:fails = 0
. (Join-Path $PSScriptRoot 'test-env.ps1')
$runtimePath = New-TestRuntimePath $work

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
# PowerShell 7 reads "2026-10-07" from JSON as a DateTime; Windows PowerShell keeps the string.
function ConvertTo-TestDay($v) { if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd') } return [string]$v }
function Get-Calls { if (Test-Path -LiteralPath "$work\npm-calls.log") { return @(Get-Content -LiteralPath "$work\npm-calls.log") } return @() }

$fakeEnv = @{ FAKE_NPM_DIR = $work; FAKE_NPM_PREFIX = $prefix; FAKE_NPM_ROOT = $npmRoot }

function Invoke-FakeNpm([string[]]$Arguments) {
  foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $fakeEnv[$k]) }
  & node $fake @Arguments | Out-Null
}

function New-NpmCli([string]$Command, [string]$Package, [string]$Version) {
  Invoke-FakeNpm @('install', '-g', "$Package@$Version")
  $rel = $Package -replace '/', '\'
  $pkgDir = Join-Path $npmRoot $rel
  "console.log('$Command ' + require('./package.json').version)" |
    Set-Content -LiteralPath (Join-Path $pkgDir 'cli.js') -Encoding ASCII
  # A real npm global .cmd calls the package script directly, so ownership detection can read the
  # node_modules reference instead of guessing from the prefix.
  "@node `"%~dp0node_modules\$rel\cli.js`" %*" | Set-Content -LiteralPath "$prefix\$Command.cmd" -Encoding ASCII
}

function Invoke-Script([string]$Script, [string[]]$Arguments, [hashtable]$Extra = @{}) {
  $exe = (Get-Process -Id $PID).Path
  $names = @('HOME', 'CODEX_HOME', 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'AICM_PROCESSES', 'AICM_WORKTREES', 'PATH', 'AICM_MIN_RELEASE_AGE_DAYS', 'AICM_VERIFY_SIGNATURES', 'AICM_ALLOW') + @($fakeEnv.Keys) + @($Extra.Keys)
  $saved = @{}
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = "$work\tmp"; $env:TMP = "$work\tmp"; $env:LOCALAPPDATA = "$fakeHome\AppData\Local"
    $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_WORKTREES = '0'
    foreach ($k in 'AICM_MIN_RELEASE_AGE_DAYS', 'AICM_VERIFY_SIGNATURES', 'AICM_ALLOW') { [Environment]::SetEnvironmentVariable($k, $null) }
    foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $fakeEnv[$k]) }
    $env:HOME = $fakeHome; $env:CODEX_HOME = "$fakeHome\.codex"
    $env:PATH = "$fakeBin;$prefix;$solo;$runtimePath"
    foreach ($k in $Extra.Keys) { [Environment]::SetEnvironmentVariable($k, $Extra[$k]) }
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments 2>&1 | Out-String -Width 400
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

try {
  New-Item -ItemType Directory -Path $fakeHome, "$work\tmp", "$fakeHome\AppData\Local", $aicmHome, $fakeBin, $npmRoot, $solo -Force | Out-Null
  @'
{
  "@fake/npmcli": { "latest": "1.2.0", "versions": {
    "1.0.0": { "daysAgo": 30, "provenance": true },
    "1.1.0": { "daysAgo": 10, "provenance": true },
    "1.2.0": { "daysAgo": 1, "provenance": true } } },
  "@fake/shadow": { "latest": "3.1.0", "versions": { "3.0.0": { "daysAgo": 40 }, "3.1.0": { "daysAgo": 20 } } },
  "@fake/newcli": { "latest": "0.5.0", "versions": { "0.5.0": { "daysAgo": 20 } } },
  "@fake/evil": { "latest": "1.1.0", "versions": {
    "1.0.0": { "daysAgo": 30, "provenance": true },
    "1.1.0": { "daysAgo": 10, "scripts": { "postinstall": "npm install -g openclaw@latest" } } } },
  "@fake/badsig": { "latest": "1.1.0", "versions": { "1.0.0": { "daysAgo": 30 }, "1.1.0": { "daysAgo": 10, "badsig": true } } }
}
'@ | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII

  # Fake npm: npm.cmd plus the npm.ps1 twin, like a real npm install.
  "@node `"$fake`" %*" | Set-Content -LiteralPath "$fakeBin\npm.cmd" -Encoding ASCII
  "& node '$fake' @args; exit `$LASTEXITCODE" | Set-Content -LiteralPath "$fakeBin\npm.ps1" -Encoding ASCII

  New-NpmCli 'fakenpm' '@fake/npmcli' '1.0.0'
  New-NpmCli 'fakeevil' '@fake/evil' '1.0.0'
  New-NpmCli 'fakebadsig' '@fake/badsig' '1.0.0'
  Invoke-FakeNpm @('install', '-g', '@fake/shadow@3.0.0')
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  @(
    '@echo off'
    'if "%1"=="upgrade" (echo upgraded>>"%~dp0..\solo-upgrades.log" & exit /b 0)'
    'echo fakesolo version 2.0.0'
  ) | Set-Content -LiteralPath "$solo\fakesolo.cmd" -Encoding ASCII
  @('@echo off', 'echo fakeshadow 3.1.0') | Set-Content -LiteralPath "$solo\fakeshadow.cmd" -Encoding ASCII

  $catalog = @(
    '# id        | command    | name         | npm          | brew | winget | self_update | note'
    'fakenpm     | fakenpm    | Fake NPM     | @fake/npmcli |      |        |             |'
    'fakesolo    | fakesolo   | Fake Solo    |              |      |        | upgrade     |'
    'fakeshadow  | fakeshadow | Fake Shadow  | @fake/shadow |      |        |             | ships with an app'
    'fakegone    | fakegone   | Fake Missing | @fake/gone   |      |        |             |'
    'fakenew     | fakenew    | Fake New     | @fake/newcli |      |        |             |'
    'fakeevil    | fakeevil   | Fake Evil    | @fake/evil   |      |        |             |'
    'fakebadsig  | fakebadsig | Fake Badsig  | @fake/badsig |      |        |             |'
  )
  $catalog | Set-Content -LiteralPath "$work\catalog.conf" -Encoding UTF8
  $catalog | Set-Content -LiteralPath "$aicmHome\ai-clis.local.conf" -Encoding UTF8
  $inv = @('-CatalogFile', "$work\catalog.conf", '-LocalCatalogFile', "$work\none.conf")
  $upd = 'bin\update_ai_clis.ps1'

  Write-Host '# first inventory'
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' $inv
  Write-Host $r.Output
  if ($r.ExitCode -eq 0) { Pass 'inventory exits 0' } else { Fail "inventory exit $($r.ExitCode)" }
  if ($r.Output -match '(?m)^Fake NPM +npm +1\.0\.0 +1\.2\.0 +behind +yes') { Pass 'npm CLI behind the 3-day-old release' } else { Fail 'npm CLI row' }
  if ($r.Output -match '(?m)^Fake Solo +standalone +2\.0\.0 +installed +yes') { Pass 'standalone CLI with self-update is covered' } else { Fail 'standalone row' }
  if ($r.Output -match '(?m)^Fake Shadow +standalone +3\.1\.0 +3\.1\.0 +current +no: ships with an app') { Pass 'standalone without updater is flagged' } else { Fail 'shadow row' }
  if ($r.Output -match 'npm copy 3\.0\.0 is also installed, but PATH runs') { Pass 'hidden npm copy reported' } else { Fail 'hidden npm copy' }
  if ($r.Output -notmatch 'Fake Missing') { Pass 'missing CLI not listed' } else { Fail 'missing CLI listed' }
  if ($r.Output -match '5 AI CLIs installed \(catalog has 7\)') { Pass 'count line' } else { Fail 'count line' }
  $md = Get-Content -LiteralPath "$aicmHome\inventory.md" -Raw -ErrorAction SilentlyContinue
  if ($md -and $md.Contains('| Fake NPM | npm | 1.0.0 | 1.2.0 | behind | yes |')) { Pass 'markdown report' } else { Fail 'markdown report' }
  $state = Get-Content -LiteralPath "$aicmHome\state\inventory.json" -Raw | ConvertFrom-Json
  if (@($state.clis | Where-Object { $_.id -eq 'fakesolo' }).Count -eq 1) { Pass 'json state' } else { Fail 'json state' }
  if ($r.Output -match 'Fake Shadow : PATH runs 3\.1\.0 at .*fakeshadow\.cmd; an unused npm copy \(3\.0\.0\) is also installed\. fix : keep one copy') { Pass 'unreachable duplicate reported with a fix' } else { Fail 'duplicate report' }
  if (([regex]::Matches($r.Output, 'notify:')).Count -eq 1 -and $r.Output -match 'notify: .*Fake Shadow : PATH runs') { Pass 'first run notifies only about the duplicate' } else { Fail 'first run notifications' }
  if (@($state.shadowProblems).Count -eq 1) { Pass 'duplicate kept in state for doctor' } else { Fail 'shadow state' }

  Write-Host '# offline'
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' ($inv + '-Offline')
  if ($r.Output -match '(?m)^Fake NPM +npm +1\.0\.0 +installed') { Pass '-Offline skips latest lookups' } else { Fail "offline: $($r.Output)" }
  if ($r.Output -notmatch 'notify:') { Pass 'a known duplicate does not notify again' } else { Fail 'duplicate notified twice' }

  New-Item -ItemType Directory -Path "$aicmHome\hooks" -Force | Out-Null
  "Add-Content -LiteralPath '$work\hook.log' -Value ran" | Set-Content -LiteralPath "$aicmHome\hooks\post-update.ps1" -Encoding ASCII

  Write-Host '# update waits 3 days and checks the release'
  # Never '-Targets all' here: that would also run the dedicated updaters for real CLIs on this machine.
  $r = Invoke-Script $upd @('-Targets', 'fakenpm,fakesolo,fakeshadow')
  Write-Host $r.Output
  if ($r.ExitCode -eq 0) { Pass 'update exits 0' } else { Fail "update exit $($r.ExitCode)" }
  if ((Get-Calls) -contains 'install -g @fake/npmcli@1.1.0') { Pass 'installs the newest release at least 3 days old (1.1.0, not 1.2.0)' } else { Fail "waiting period: $(Get-Calls)" }
  if ((Get-Calls) -contains 'stage @fake/npmcli@1.1.0 --ignore-scripts') { Pass 'staged without running install scripts' } else { Fail 'staged install' }
  $before = @(Get-Content -LiteralPath "$work\npm-before.log" -ErrorAction SilentlyContinue)
  if (@($before | Where-Object { $_ -match '^install -g @fake/npmcli@1\.1\.0 before=\d{4}-' }).Count -eq 1 -and @($before | Where-Object { $_ -match '^stage @fake/npmcli@1\.1\.0 before=\d{4}-' }).Count -eq 1) { Pass 'staged and real install pass --before (waiting period for dependencies)' } else { Fail "--before: $before" }
  if ($r.Output -match 'signatures ok') { Pass 'signature check ran' } else { Fail 'signature check' }
  if (Test-Path -LiteralPath "$work\solo-upgrades.log") { Pass 'standalone CLI self-updated' } else { Fail 'self-update not run' }
  if ($r.Output -match 'pass: Fake Shadow is installed standalone') { Pass 'no updater: reported, not failed' } else { Fail 'shadow handling' }
  if (-not ((Get-Calls) -match '@fake/shadow')) { Pass 'hidden npm copy is not touched' } else { Fail 'hidden copy was updated' }

  $r = Invoke-Script $upd @('-Targets', 'fakenpm')
  if ($r.Output -match 'already current: @fake/npmcli 1\.1\.0') { Pass 'nothing newer than the waiting period: not reinstalled' } else { Fail "reinstalled: $($r.Output)" }
  if (@(Get-Content -LiteralPath "$work\hook.log" -ErrorAction SilentlyContinue).Count -eq 1) { Pass 'post-update hook ran once: only the run that changed a version' } else { Fail "hook runs: $(@(Get-Content -LiteralPath "$work\hook.log" -ErrorAction SilentlyContinue).Count)" }
  if ($r.Output -match 'post-update hook skipped: no CLI version changed') { Pass 'hook skipped when nothing changed' } else { Fail 'hook skip message' }
  # npm with an old .npmrc setting prints a warning on stderr; the JSON it prints must still parse.
  $r = Invoke-Script $upd @('-Targets', 'fakenpm') @{ FAKE_NPM_WARN = '1' }
  if ($r.ExitCode -eq 0 -and $r.Output -match 'already current: @fake/npmcli 1\.1\.0') { Pass 'npm warnings on stderr do not break the JSON' } else { Fail "npm warning: exit $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' $inv
  if ($r.Output -match '(?m)^Fake NPM +npm +1\.1\.0 +1\.2\.0 +held +yes') { Pass 'inventory shows a release in its waiting period as held' } else { Fail "held state: $($r.Output)" }

  $null = Invoke-Script $upd @('-Targets', 'fakenpm') @{ AICM_MIN_RELEASE_AGE_DAYS = '0' }
  if ((Get-Calls) -contains 'install -g @fake/npmcli@1.2.0') { Pass 'AICM_MIN_RELEASE_AGE_DAYS=0 takes the newest release' } else { Fail 'no waiting period' }

  Write-Host '# red flags block the update'
  $r = Invoke-Script $upd @('-Targets', 'fakeevil')
  if ($r.ExitCode -ne 0) { Pass 'blocked update fails the run' } else { Fail 'blocked update exit 0' }
  if ($r.Output -match 'red flag: @fake/evil provenance: 1\.0\.0 was published with a provenance attestation, 1\.1\.0 was not') { Pass 'lost provenance flagged' } else { Fail "provenance flag: $($r.Output)" }
  if ($r.Output -match 'red flag: @fake/evil install script: 1\.1\.0 adds "postinstall"') { Pass 'new install script flagged' } else { Fail 'install script flag' }
  if (-not ((Get-Calls) -match '@fake/evil@1\.1\.0')) { Pass 'flagged release is neither staged nor installed' } else { Fail 'flagged release touched' }
  if ($r.Output -match 'notify: .*update failed') { Pass 'blocked update notifies' } else { Fail 'no notification' }
  $null = Invoke-Script $upd @('-Targets', 'fakeevil') @{ AICM_ALLOW = '@fake/evil@1.1.0' }
  if ((Get-Calls) -contains 'install -g @fake/evil@1.1.0') { Pass 'AICM_ALLOW accepts a reviewed release' } else { Fail 'allow list' }

  $r = Invoke-Script $upd @('-Targets', 'fakebadsig')
  if ($r.ExitCode -ne 0 -and $r.Output -match 'signature check failed for @fake/badsig@1\.1\.0') { Pass 'bad registry signature blocks the update' } else { Fail "bad signature: $($r.Output)" }
  if ((Get-Calls) -notcontains 'install -g @fake/badsig@1.1.0') { Pass 'release with a bad signature not installed' } else { Fail 'bad signature installed' }
  $r = Invoke-Script $upd @('-Targets', 'fakebadsig')
  if ($r.ExitCode -ne 0 -and $r.Output -match 'checked earlier today' -and @(Get-Calls | Where-Object { $_ -eq 'stage @fake/badsig@1.1.0 --ignore-scripts' }).Count -eq 1) { Pass 'a bad signature verdict is kept for the day: no second download' } else { Fail "verdict cache: $($r.Output)" }

  Write-Host '# install-missing only when named'
  $null = Invoke-Script $upd @('-Targets', 'fakenpm', '-InstallMissing')
  if (-not ((Get-Calls) -match '@fake/newcli')) { Pass 'unnamed CLI is not installed' } else { Fail 'unnamed CLI installed' }
  $null = Invoke-Script $upd @('-Targets', 'fakenew', '-InstallMissing')
  if ((Get-Calls) -contains 'install -g @fake/newcli@0.5.0') { Pass 'named target is installed with -InstallMissing (after checks)' } else { Fail 'named install' }

  Write-Host '# changes since the last inventory'
  Remove-Item -LiteralPath "$solo\fakesolo.cmd"
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' $inv
  if ($r.Output -match 'removed: Fake Solo') { Pass 'removed CLI reported' } else { Fail 'removed' }
  if ($r.Output -match 'new: Fake New') { Pass 'new CLI reported' } else { Fail 'new' }
  if ($r.Output -match 'updated: Fake NPM 1\.1\.0 -> 1\.2\.0') { Pass 'version change reported' } else { Fail 'updated' }
  if ($r.Output -match 'notify: .*removed: Fake Solo') { Pass 'added/removed CLIs raise a notification' } else { Fail 'notification' }

  Write-Host '# a CLI that is running is deferred, not failed'
  $reg = Get-Content -LiteralPath "$work\registry.json" -Raw | ConvertFrom-Json
  $reg.'@fake/npmcli'.latest = '1.3.0'
  $reg.'@fake/npmcli'.versions | Add-Member -NotePropertyName '1.3.0' -NotePropertyValue ([pscustomobject]@{ daysAgo = 10; provenance = $true })
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  $pkgDir = Join-Path $npmRoot '@fake\npmcli\'
  # A process whose command line points into the package folder, like a running CLI session.
  $blocker = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', "Start-Sleep -Seconds 120 # $pkgDir" -WindowStyle Hidden -PassThru
  try {
    Start-Sleep -Seconds 2
    $r = Invoke-Script $upd @('-Targets', 'fakenpm')
    if ($r.ExitCode -eq 0 -and $r.Output -match 'deferred: @fake/npmcli is running') { Pass 'running CLI deferred, run still succeeds' } else { Fail "deferral: exit $($r.ExitCode) $($r.Output)" }
    if ((Get-Calls) -notcontains 'install -g @fake/npmcli@1.3.0') { Pass 'nothing installed over the running CLI' } else { Fail 'installed over a running CLI' }
    $last = Get-Content -LiteralPath "$aicmHome\state\last-update.json" -Raw | ConvertFrom-Json
    if ($last.pending -and @($last.deferred) -contains '@fake/npmcli') { Pass 'deferral recorded as pending' } else { Fail 'pending state' }
    if ($r.Output -notmatch 'notify:.*always running') { Pass 'no reminder on the first day' } else { Fail 'reminded too early' }
  } finally { Stop-Process -Id $blocker.Id -Force -ErrorAction SilentlyContinue }

  $reg.'@fake/npmcli'.versions.'1.3.0' | Add-Member -NotePropertyName 'ebusy' -NotePropertyValue $true
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  $r = Invoke-Script $upd @('-Targets', 'fakenpm')
  if ($r.ExitCode -eq 0 -and $r.Output -match 'deferred: @fake/npmcli files are in use') { Pass 'EBUSY during install deferred, not failed' } else { Fail "ebusy: exit $($r.ExitCode) $($r.Output)" }

  # Deferred for 6 days: the next run reminds once.
  $old = (Get-Date).ToUniversalTime().AddDays(-6).ToString('o')
  "{`"@fake/npmcli`":`"$old`"}" | Set-Content -LiteralPath "$aicmHome\state\update-deferred.json" -Encoding ASCII
  $r = Invoke-Script $upd @('-Targets', 'fakenpm')
  if ($r.Output -match 'notify: .*@fake/npmcli has not been updated for more than 5 days') { Pass 'reminder after 5+ days of deferral' } else { Fail "reminder: $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'fakenpm')
  if ($r.Output -notmatch 'notify:') { Pass 'the same reminder is not repeated the next day' } else { Fail 'reminder repeated' }

  $reg.'@fake/npmcli'.versions.'1.3.0'.ebusy = $false
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  New-Item -ItemType Directory -Path (Join-Path $npmRoot '@fake\.npmcli-AbCd1234') -Force | Out-Null
  'x' | Set-Content -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234\stale.txt')
  (Get-Item -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234')).LastWriteTime = (Get-Date).AddDays(-3)
  # A leftover whose package is not installed may be the only copy of an interrupted install: kept.
  New-Item -ItemType Directory -Path (Join-Path $npmRoot '@fake\.gonecli-AbCd1234') -Force | Out-Null
  '{"name":"@fake/gonecli","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $npmRoot '@fake\.gonecli-AbCd1234\package.json')
  (Get-Item -LiteralPath (Join-Path $npmRoot '@fake\.gonecli-AbCd1234')).LastWriteTime = (Get-Date).AddDays(-3)
  $r = Invoke-Script $upd @('-Targets', 'fakenpm', '-Scheduled')
  if ((Get-Calls) -contains 'install -g @fake/npmcli@1.3.0') { Pass 'scheduled retry installs once the CLI is free' } else { Fail "retry: $($r.Output)" }
  if (-not (Test-Path -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234'))) { Pass 'npm staging leftover removed' } else { Fail 'npm leftover kept' }
  if ((Test-Path -LiteralPath (Join-Path $npmRoot '@fake\.gonecli-AbCd1234')) -and $r.Output -match 'kept npm leftover .*gonecli is not installed') { Pass 'leftover of a package that is not installed is kept' } else { Fail 'only copy removed' }
  Remove-Item -LiteralPath (Join-Path $npmRoot '@fake\.gonecli-AbCd1234') -Recurse -Force
  $deferredNow = Get-Content -LiteralPath "$aicmHome\state\update-deferred.json" -Raw | ConvertFrom-Json
  if (@($deferredNow.PSObject.Properties).Count -eq 0) { Pass 'deferral cleared after the update' } else { Fail 'deferral not cleared' }
  $last = Get-Content -LiteralPath "$aicmHome\state\last-update.json" -Raw | ConvertFrom-Json
  if ((ConvertTo-TestDay $last.localDate) -eq (Get-Date).ToString('yyyy-MM-dd') -and $last.targets -eq 'fakenpm') { Pass 'state records the local date and the targets' } else { Fail "state: $($last | ConvertTo-Json -Compress)" }
  $logsBefore = @(Get-ChildItem -LiteralPath "$aicmHome\logs" -Filter 'update-*.log').Count
  $latestBefore = Get-Content -LiteralPath "$aicmHome\logs\latest.log" -Raw
  $r = Invoke-Script $upd @('-Targets', 'fakenpm', '-Scheduled')
  if ($r.Output -match 'already updated today') { Pass 'later scheduled run the same day exits at once' } else { Fail "early exit: $($r.Output)" }
  if (@(Get-ChildItem -LiteralPath "$aicmHome\logs" -Filter 'update-*.log').Count -eq $logsBefore -and (Get-Content -LiteralPath "$aicmHome\logs\latest.log" -Raw) -eq $latestBefore) { Pass 'a retry with nothing to do writes no log and keeps latest.log' } else { Fail 'no-op retry touched the logs' }
  $r = Invoke-Script $upd @('-Targets', 'fakenpm,fakeshadow', '-Scheduled')
  if ($r.Output -notmatch 'already updated today') { Pass 'a partial run does not count for a run with more targets' } else { Fail 'partial run counted as done' }

  Write-Host '# registry unreachable: skipped, not failed'
  $r = Invoke-Script $upd @('-Targets', 'fakenpm') @{ FAKE_NPM_OFFLINE = '1' }
  $last = Get-Content -LiteralPath "$aicmHome\state\last-update.json" -Raw | ConvertFrom-Json
  if ($r.ExitCode -eq 0 -and $r.Output -match 'registry unreachable' -and $last.pending) { Pass 'offline run succeeds and stays pending' } else { Fail "offline: exit $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'fakenpm', '-Scheduled')
  if ($r.Output -notmatch 'already updated today') { Pass 'a pending day is retried by the scheduled run' } else { Fail 'pending day not retried' }

  Write-Host '# a timeout ends the whole process tree'
  # npm.cmd starts cmd.exe, which starts node; on timeout node must not keep running.
  $marker = 'aicmtreekill' + [guid]::NewGuid().ToString('N')
  "@node -e `"setTimeout(function(){}, 120000)`" $marker" | Set-Content -LiteralPath "$work\hang.cmd" -Encoding ASCII
  $savedHome = $env:AICM_HOME
  try {
    $env:AICM_HOME = $aicmHome
    . (Join-Path $root 'lib\aicm-common.ps1')
    $t = Invoke-AicmWithTimeout "$work\hang.cmd" @() 3
    $split = Invoke-AicmWithTimeout 'node' @('-e', 'console.log(1); console.error(2)') 30
  } finally { $env:AICM_HOME = $savedHome }
  Start-Sleep -Seconds 1
  $left = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marker) })
  if ($t.ExitCode -eq 124 -and $left.Count -eq 0) { Pass 'timeout returns 124 and no grandchild survives' } else { Fail "tree kill: rc=$($t.ExitCode) left=$($left.Count)" }
  foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  if ($split.StdOut.Trim() -eq '1' -and $split.StdErr.Trim() -eq '2' -and $split.Output -match '1' -and $split.Output -match '2') { Pass 'stdout and stderr are returned separately (and together in .Output)' } else { Fail "stream split: [$($split.StdOut)] [$($split.StdErr)]" }

  Write-Host '# semver order'
  $order = @(@('2.0.0-beta.3', '2.0.0', -1), @('2.0.0-beta.2', '2.0.0-beta.11', -1), @('2.0.0-alpha', '2.0.0-alpha.1', -1), @('1.2.0', '1.10.0', -1), @('1.0.0+build', '1.0.0', 0), @('2.0.0', '2.0.0-rc.1', 1))
  $wrong = @($order | Where-Object { (Compare-AicmVersion $_[0] $_[1]) -ne $_[2] })
  if ($wrong.Count -eq 0) { Pass 'a prerelease is older than its release' } else { Fail "compare: $($wrong | ForEach-Object { $_ -join ' ' })" }

  Write-Host '# a run that holds the lock for hours is reported'
  $env:AICM_HOME = $aicmHome
  try { $held = [System.Threading.Mutex]::new($false, (Get-AicmLockName 'update')) } finally { $env:AICM_HOME = $savedHome }
  [void]$held.WaitOne(0)
  try {
    "{`"startedAt`":`"$((Get-Date).ToUniversalTime().AddHours(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))`",`"pid`":1}" | Set-Content -LiteralPath "$aicmHome\state\update-running.json" -Encoding ASCII
    $logsBefore = @(Get-ChildItem -LiteralPath "$aicmHome\logs" -Filter 'update-*.log').Count
    $r = Invoke-Script $upd @('-Targets', 'fakeshadow', '-Scheduled')
    if ($r.ExitCode -eq 0 -and $r.Output -match 'already active' -and $r.Output -match 'notify: .*running for more than 3 hours') { Pass 'lock held for 3+ hours raises a notification' } else { Fail "stuck run: $($r.Output)" }
    if (@(Get-ChildItem -LiteralPath "$aicmHome\logs" -Filter 'update-*.log').Count -eq $logsBefore) { Pass 'a blocked run writes no log' } else { Fail 'blocked run wrote a log' }
    $r = Invoke-Script $upd @('-Targets', 'fakeshadow', '-Scheduled')
    if ($r.Output -notmatch 'notify:') { Pass 'the stuck-run notice is not repeated every retry' } else { Fail 'stuck notice repeated' }
  } finally { $held.ReleaseMutex(); $held.Dispose() }
  $r = Invoke-Script $upd @('-Targets', 'fakeshadow')
  if (-not (Test-Path -LiteralPath "$aicmHome\state\update-running.json") -and $r.Output -notmatch 'already active') { Pass 'lock and start time are released after a run' } else { Fail "running state left: $($r.Output)" }

  Write-Host '# unpublished and deprecated releases are passed over; registries without signing keys'
  $reg = Get-Content -LiteralPath "$work\registry.json" -Raw | ConvertFrom-Json
  $reg | Add-Member -NotePropertyName '@fake/depcli' -NotePropertyValue ([pscustomobject]@{ latest = '1.2.0'; versions = [pscustomobject]@{
    '1.0.0' = [pscustomobject]@{ daysAgo = 30 }; '1.1.0' = [pscustomobject]@{ daysAgo = 20 }
    '1.2.0' = [pscustomobject]@{ daysAgo = 10; deprecated = 'broken, use 1.1.0' }; '1.3.0' = [pscustomobject]@{ daysAgo = 5; unpublished = $true } } })
  $reg | Add-Member -NotePropertyName '@fake/nokeys' -NotePropertyValue ([pscustomobject]@{ latest = '1.1.0'; versions = [pscustomobject]@{
    '1.0.0' = [pscustomobject]@{ daysAgo = 30 }; '1.1.0' = [pscustomobject]@{ daysAgo = 10; nokeys = $true } } })
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  New-NpmCli 'fakedep' '@fake/depcli' '1.0.0'
  New-NpmCli 'fakenokeys' '@fake/nokeys' '1.0.0'
  @('fakedep | fakedep | Fake Dep | @fake/depcli | | | |', 'fakenokeys | fakenokeys | Fake NoKeys | @fake/nokeys | | | |') | Add-Content -LiteralPath "$aicmHome\ai-clis.local.conf" -Encoding UTF8
  $r = Invoke-Script $upd @('-Targets', 'fakedep')
  if ((Get-Calls) -contains 'install -g @fake/depcli@1.1.0' -and $r.Output -match 'skip: @fake/depcli@1\.2\.0 is deprecated') { Pass 'deprecated and unpublished releases are skipped' } else { Fail "deprecated: $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'fakenokeys')
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g @fake/nokeys@1.1.0' -and $r.Output -match 'notify: .*publishes no signing keys') { Pass 'registry without signing keys: warned, not failed' } else { Fail "no keys: exit $($r.ExitCode) $($r.Output)" }

  Write-Host '# a CLI lost by an interrupted install'
  $pkgDir = Join-Path $npmRoot '@fake\npmcli'
  $wasVersion = (Get-Content -LiteralPath "$pkgDir\package.json" -Raw | ConvertFrom-Json).version
  Rename-Item -LiteralPath $pkgDir -NewName '.npmcli-XyZw9876'
  $installsBefore = @(Get-Calls | Where-Object { $_ -eq "install -g @fake/npmcli@$wasVersion" }).Count
  $stateFile = Join-Path $aicmHome 'state\update-npm.json'
  # fakenpm is not selected: recovery must not touch its backup, package or state.
  $r = Invoke-Script $upd @('-Targets', 'fakeshadow')
  $stateText = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 } else { '' }
  if ($r.ExitCode -eq 0 -and $r.Output -notmatch "restored: @fake/npmcli" -and (Test-Path -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-XyZw9876')) -and -not (Test-Path -LiteralPath (Join-Path $npmRoot '@fake\npmcli')) -and $stateText -match '@fake/npmcli') {
    Pass 'an unselected CLI is not recovered and its backup and state are kept'
  } else { Fail "unselected recovery: exit $($r.ExitCode) $($r.Output)" }
  # Explicitly named: the interrupted install is recovered at the same version.
  $r = Invoke-Script $upd @('-Targets', 'fakeshadow,fakenpm')
  if ($r.ExitCode -eq 0 -and $r.Output -match "restored: @fake/npmcli $([regex]::Escape($wasVersion))" -and @(Get-Calls | Where-Object { $_ -eq "install -g @fake/npmcli@$wasVersion" }).Count -eq $installsBefore + 1) { Pass 'a selected CLI whose install was cut off is reinstalled at the same version' } else { Fail "restore: $($r.Output)" }
  Remove-Item -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-XyZw9876') -Recurse -Force
  Remove-Item -LiteralPath (Join-Path $npmRoot '@fake\newcli') -Recurse -Force
  foreach ($launcher in 'fakenew.cmd', 'fakenew.ps1') {
    Remove-Item -LiteralPath (Join-Path $prefix $launcher) -Force -ErrorAction SilentlyContinue
  }
  $r = Invoke-Script $upd @('-Targets', 'fakenew')
  if ($r.ExitCode -ne 0 -and $r.Output -match 'notify: .*@fake/newcli disappeared since the last update') { Pass 'a selected managed CLI that is gone is reported as a failure' } else { Fail "missing CLI: exit $($r.ExitCode) $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'fakenew')
  if ($r.ExitCode -eq 0 -and $r.Output -notmatch 'disappeared') { Pass 'it is reported once, then forgotten (it may have been removed on purpose)' } else { Fail "missing CLI repeated: $($r.Output)" }

  Write-Host '# builtin PATH ownership and inventory coverage agree with update behavior'
  $reg = Get-Content -LiteralPath "$work\registry.json" -Raw | ConvertFrom-Json
  foreach ($package in '@openai/codex', '@anthropic-ai/claude-code', 'opencode-ai', '@moonshot-ai/kimi-code') {
    $reg | Add-Member -NotePropertyName $package -NotePropertyValue ([pscustomobject]@{ latest = '1.1.0'; versions = [pscustomobject]@{
      '1.0.0' = [pscustomobject]@{ daysAgo = 30 }; '1.1.0' = [pscustomobject]@{ daysAgo = 10 } } })
  }
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  foreach ($id in 'codex', 'claude', 'opencode', 'kimi') {
    $package = @{ codex = '@openai/codex'; claude = '@anthropic-ai/claude-code'; opencode = 'opencode-ai'; kimi = '@moonshot-ai/kimi-code' }[$id]
    Invoke-FakeNpm @('install', '-g', "$package@1.0.0")
    if ($LASTEXITCODE -ne 0) { throw "fake builtin setup failed : $package" }
    @('@echo off', 'if "%1"=="--version" (echo 2.0.0 & exit /b 0)', ('echo {0} %*>>"{1}\self-calls.log"' -f $id, $work), 'exit /b 0') |
      Set-Content -LiteralPath "$solo\$id.cmd" -Encoding ASCII
  }
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $r = Invoke-Script $upd @('-Targets', 'codex,claude,opencode,kimi')
  if ($r.ExitCode -eq 0 -and $r.Output -match 'hidden npm copies are skipped') { Pass 'separate Codex and Kimi PATH installs are skipped' } else { Fail "builtin shadow update : $($r.Output)" }
  if (-not ((Get-Calls) -match '^(install|view|pack|audit).*(@openai/codex|@moonshot-ai/kimi-code|@anthropic-ai/claude-code|opencode-ai)')) { Pass 'no hidden builtin npm copy is updated or staged' } else { Fail 'hidden builtin npm copy touched' }
  $calls = @(Get-Content -LiteralPath "$work\self-calls.log")
  if ($calls -contains 'claude update' -and $calls -contains 'opencode upgrade' -and -not ($calls -match '^(codex|kimi) ')) { Pass 'Claude and OpenCode use their active self-updaters' } else { Fail "active self-update : $calls" }
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' @('-Offline')
  $state = Get-Content -LiteralPath "$aicmHome\state\inventory.json" -Raw | ConvertFrom-Json
  foreach ($id in 'codex', 'claude', 'opencode', 'kimi') {
    $row = @($state.clis | Where-Object { $_.id -eq $id })[0]
    $expected = if ($id -in @('claude', 'opencode')) { 'yes' } else { 'no : ' }
    if ($row.method -eq 'standalone' -and $row.autoUpdate.StartsWith($expected)) { Pass "$id inventory reflects active update coverage" } else { Fail "$id coverage : $($row.autoUpdate)" }
  }
  if ($r.Output -notmatch 'daily update refreshes the npm copy') { Pass 'duplicate guidance does not promise updates to unused copies' } else { Fail 'stale duplicate guidance' }
  foreach ($id in 'codex', 'claude', 'opencode', 'kimi') {
    $entry = @(Read-AicmCatalog | Where-Object { $_.Id -eq $id })[0]
    $coverage = Get-AicmUpdateCoverage $entry ([pscustomobject]@{ Method = 'winget'; NpmCopy = '1.0.0' })
    $expected = if ($id -in @('claude', 'opencode')) { 'yes' } else { 'no : ' }
    if ($coverage.StartsWith($expected)) { Pass "$id winget PATH coverage matches dedicated updater" } else { Fail "$id winget coverage : $coverage" }
  }
  # A previous managed npm install must not be restored over a separate active copy.
  $pkgDir = Join-Path $npmRoot '@openai\codex'
  Rename-Item -LiteralPath $pkgDir -NewName '.codex-XyZw9876'
  '{"@openai/codex":"1.0.0"}' | Set-Content -LiteralPath "$aicmHome\state\update-npm.json" -Encoding ASCII
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $r = Invoke-Script $upd @('-Targets', 'codex')
  if ($r.ExitCode -eq 0 -and $r.Output -match 'unused npm copy @openai/codex is not restored' -and -not ((Get-Calls) -match '^install -g @openai/codex')) { Pass 'recovery also leaves hidden Codex npm copy alone' } else { Fail "shadow recovery : $($r.Output)" }

  Write-Host '# OpenCode V1 retains its npm owner when V2 is also installed'
  $reg = Get-Content -LiteralPath "$work\registry.json" -Raw | ConvertFrom-Json
  $reg | Add-Member -NotePropertyName '@opencode/cli' -NotePropertyValue ([pscustomobject]@{ latest = '2.1.0'; versions = [pscustomobject]@{
    '2.0.0' = [pscustomobject]@{ daysAgo = 30 }; '2.1.0' = [pscustomobject]@{ daysAgo = 10 } } })
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  New-NpmCli 'opencode' '@opencode/cli' '2.0.0'
  @('@echo off', 'echo opencode 1.0.0') | Set-Content -LiteralPath "$npmRoot\opencode-ai\opencode.cmd" -Encoding ASCII
  '@"%~dp0node_modules\opencode-ai\opencode.cmd" %*' | Set-Content -LiteralPath "$prefix\opencode.cmd" -Encoding ASCII
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $r = Invoke-Script $upd @('-Targets', 'opencode')
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g opencode-ai@1.1.0' -and -not ((Get-Calls) -match '@opencode/cli@')) { Pass 'OpenCode V1 updates without switching to V2' } else { Fail "OpenCode V1 owner: $($r.Output)" }

  Write-Host '# Amp uses @ampcode/cli, keeps legacy @sourcegraph/amp, and updates the PATH owner'
  $reg = Get-Content -LiteralPath "$work\registry.json" -Raw | ConvertFrom-Json
  $reg | Add-Member -NotePropertyName '@ampcode/cli' -NotePropertyValue ([pscustomobject]@{ latest = '1.1.0'; versions = [pscustomobject]@{
    '1.0.0' = [pscustomobject]@{ daysAgo = 30 }; '1.1.0' = [pscustomobject]@{ daysAgo = 10 } } })
  $reg | Add-Member -NotePropertyName '@sourcegraph/amp' -NotePropertyValue ([pscustomobject]@{ latest = '0.2.0'; versions = [pscustomobject]@{
    '0.1.0' = [pscustomobject]@{ daysAgo = 30 }; '0.2.0' = [pscustomobject]@{ daysAgo = 10 } } })
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  function New-AmpOwned([string]$Package, [string]$Version) {
    Invoke-FakeNpm @('install', '-g', "$Package@$Version")
    $pkgDir = Join-Path $npmRoot ($Package -replace '/', '\')
    @('@echo off', "echo amp $Version") | Set-Content -LiteralPath (Join-Path $pkgDir 'amp.cmd') -Encoding ASCII
    return $pkgDir
  }
  $ampDir = New-AmpOwned '@ampcode/cli' '1.0.0'
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $ampPath = "$ampDir;$fakeBin;$prefix;$solo;$runtimePath"
  $r = Invoke-Script $upd @('-Targets', 'amp') -Extra @{ PATH = $ampPath }
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g @ampcode/cli@1.1.0') { Pass 'canonical Amp package is updated' } else { Fail "amp canonical: $($r.Output)" }
  if (-not ((Get-Calls) -match '@sourcegraph/amp')) { Pass 'missing legacy Amp package is not the install target' } else { Fail 'legacy probed on canonical-only' }
  $ampDir = New-AmpOwned '@sourcegraph/amp' '0.1.0'
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $ampPath = "$ampDir;$fakeBin;$prefix;$solo;$runtimePath"
  $r = Invoke-Script $upd @('-Targets', 'amp') -Extra @{ PATH = $ampPath }
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g @sourcegraph/amp@0.2.0') { Pass 'legacy Amp package is updated when it owns PATH' } else { Fail "amp legacy: $($r.Output)" }
  if (-not ((Get-Calls) -match '@ampcode/cli@')) { Pass 'canonical Amp is not updated while PATH is the legacy copy' } else { Fail 'canonical updated behind legacy' }
  Invoke-FakeNpm @('install', '-g', '@ampcode/cli@1.0.0')
  $ampDir = New-AmpOwned '@ampcode/cli' '1.0.0'
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $ampPath = "$ampDir;$fakeBin;$prefix;$solo;$runtimePath"
  $r = Invoke-Script $upd @('-Targets', 'amp') -Extra @{ PATH = $ampPath }
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g @ampcode/cli@1.1.0') { Pass 'PATH-owning Amp package is selected when both exist' } else { Fail "amp both: $($r.Output)" }
  if (-not ((Get-Calls) -contains 'install -g @sourcegraph/amp@0.2.0')) { Pass 'hidden Amp alternate is not updated' } else { Fail 'hidden amp updated' }

  # Real npm launchers sit in the prefix, not inside either package directory.
  New-AmpOwned '@sourcegraph/amp' '0.1.0' | Out-Null
  '@"%~dp0node_modules\@sourcegraph\amp\amp.cmd" %*' | Set-Content -LiteralPath "$prefix\amp.cmd" -Encoding ASCII
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $r = Invoke-Script $upd @('-Targets', 'amp')
  if ($r.ExitCode -eq 0 -and (Get-Calls) -contains 'install -g @sourcegraph/amp@0.2.0' -and -not ((Get-Calls) -match '@ampcode/cli@')) { Pass 'Windows npm shim selects the legacy Amp owner when both exist' } else { Fail "Amp shim ownership: $($r.Output)" }

  Rename-Item -LiteralPath "$npmRoot\@sourcegraph\amp" -NewName '.amp-XyZw9876'
  '{"@sourcegraph/amp":"0.2.0"}' | Set-Content -LiteralPath "$aicmHome\state\update-npm.json" -Encoding ASCII
  Remove-Item -LiteralPath "$work\npm-calls.log" -ErrorAction SilentlyContinue
  $r = Invoke-Script $upd @('-Targets', 'amp')
  if ($r.ExitCode -eq 0 -and $r.Output -match 'restored: @sourcegraph/amp' -and -not ((Get-Calls) -match '@ampcode/cli@')) { Pass 'interrupted legacy Amp install is restored without switching packages' } else { Fail "Amp legacy recovery: $($r.Output)" }

  Write-Host '# Copilot winget id is covered and updated on the installed channel'
  $wingetLinks = Join-Path $work 'WinGet\Links'
  New-Item -ItemType Directory -Path $wingetLinks -Force | Out-Null
  @('@echo off', 'echo copilot 0.0.327') | Set-Content -LiteralPath (Join-Path $wingetLinks 'copilot.cmd') -Encoding ASCII
  @(
    '@echo off'
    ('echo %*>>"{0}"' -f (Join-Path $work 'winget-calls.log'))
    'if /i "%1"=="list" (echo GitHub.Copilot 0.0.327 & exit /b 0)'
    'exit /b 0'
  ) | Set-Content -LiteralPath "$fakeBin\winget.cmd" -Encoding ASCII
  $copilotPath = "$fakeBin;$wingetLinks;$prefix;$solo;$runtimePath"
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' @('-Offline', '-LocalCatalogFile', "$work\none.conf") -Extra @{ PATH = $copilotPath }
  if ($r.Output -match '(?m)^GitHub Copilot CLI +winget .* yes') { Pass 'winget Copilot is covered' } else { Fail "copilot winget coverage: $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'copilot') -Extra @{ PATH = $copilotPath }
  $wg = if (Test-Path -LiteralPath "$work\winget-calls.log") { Get-Content -LiteralPath "$work\winget-calls.log" -Raw } else { '' }
  if ($r.ExitCode -eq 0 -and $wg -match 'upgrade --id GitHub\.Copilot') { Pass 'installed winget Copilot is upgraded' } else { Fail "copilot winget update: $($r.Output)" }
  $npmBefore = @((Get-Calls) | Where-Object { $_ -like 'install -g @github/copilot*' }).Count
  $r = Invoke-Script $upd @('-Targets', 'copilot', '-InstallMissing') -Extra @{ PATH = $copilotPath }
  $npmAfter = @((Get-Calls) | Where-Object { $_ -like 'install -g @github/copilot*' }).Count
  if ($npmAfter -eq $npmBefore) { Pass 'Copilot stays on the winget channel' } else { Fail "copilot channel changed: $($r.Output)" }

  Write-Host '# bad catalog'
  'Bad Id | x | x |  |  |  |  |' | Set-Content -LiteralPath "$work\bad.conf" -Encoding UTF8
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' @('-CatalogFile', "$work\bad.conf", '-LocalCatalogFile', "$work\none.conf")
  if ($r.ExitCode -ne 0) { Pass 'bad catalog rejected' } else { Fail 'bad catalog accepted' }
} finally {
  foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
  Remove-TestWorkspace $work
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
