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

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function Get-Calls { if (Test-Path -LiteralPath "$work\npm-calls.log") { return @(Get-Content -LiteralPath "$work\npm-calls.log") } return @() }

$fakeEnv = @{ FAKE_NPM_DIR = $work; FAKE_NPM_PREFIX = $prefix; FAKE_NPM_ROOT = $npmRoot }

function Invoke-FakeNpm([string[]]$Arguments) {
  foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $fakeEnv[$k]) }
  & node $fake @Arguments | Out-Null
}

function New-NpmCli([string]$Command, [string]$Package, [string]$Version) {
  Invoke-FakeNpm @('install', '-g', "$Package@$Version")
  $pj = Join-Path $npmRoot (($Package -replace '/', '\') + '\package.json')
  "(Get-Content -LiteralPath '$pj' -Raw | ConvertFrom-Json).version | ForEach-Object { '$Command ' + `$_ }" |
    Set-Content -LiteralPath "$prefix\$Command-impl.ps1" -Encoding ASCII
  "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$Command-impl.ps1`" %*" | Set-Content -LiteralPath "$prefix\$Command.cmd" -Encoding ASCII
}

function Invoke-Script([string]$Script, [string[]]$Arguments, [hashtable]$Extra = @{}) {
  $exe = (Get-Process -Id $PID).Path
  $names = @('USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'PATH', 'AICM_MIN_RELEASE_AGE_DAYS', 'AICM_VERIFY_SIGNATURES', 'AICM_ALLOW') + @($fakeEnv.Keys) + @($Extra.Keys)
  $saved = @{}
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = "$work\tmp"; $env:TMP = "$work\tmp"; $env:LOCALAPPDATA = "$fakeHome\AppData\Local"
    $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'; $env:AICM_PROCESSES = '0'; $env:AICM_WORKTREES = '0'
    foreach ($k in 'AICM_MIN_RELEASE_AGE_DAYS', 'AICM_VERIFY_SIGNATURES', 'AICM_ALLOW') { [Environment]::SetEnvironmentVariable($k, $null) }
    foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $fakeEnv[$k]) }
    foreach ($k in $Extra.Keys) { [Environment]::SetEnvironmentVariable($k, $Extra[$k]) }
    $env:PATH = "$fakeBin;$prefix;$solo;$($saved['PATH'])"
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
  if ($r.Output -match 'Fake Shadow: PATH runs 3\.1\.0 at .*fakeshadow\.cmd, but the daily update refreshes the npm copy \(3\.0\.0\)\. fix: keep one copy') { Pass 'unreachable duplicate reported with a fix' } else { Fail 'duplicate report' }
  if (([regex]::Matches($r.Output, 'notify:')).Count -eq 1 -and $r.Output -match 'notify: .*Fake Shadow: PATH runs') { Pass 'first run notifies only about the duplicate' } else { Fail 'first run notifications' }
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
  if ($r.Output -match 'notify: .*@fake/npmcli has not been updated for 6 days') { Pass 'reminder after 5+ days of deferral' } else { Fail "reminder: $($r.Output)" }
  $r = Invoke-Script $upd @('-Targets', 'fakenpm')
  if ($r.Output -notmatch 'notify:') { Pass 'the same reminder is not repeated the next day' } else { Fail 'reminder repeated' }

  $reg.'@fake/npmcli'.versions.'1.3.0'.ebusy = $false
  $reg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$work\registry.json" -Encoding ASCII
  New-Item -ItemType Directory -Path (Join-Path $npmRoot '@fake\.npmcli-AbCd1234') -Force | Out-Null
  'x' | Set-Content -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234\stale.txt')
  (Get-Item -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234')).LastWriteTime = (Get-Date).AddDays(-3)
  $r = Invoke-Script $upd @('-Targets', 'fakenpm', '-Scheduled')
  if ((Get-Calls) -contains 'install -g @fake/npmcli@1.3.0') { Pass 'scheduled retry installs once the CLI is free' } else { Fail "retry: $($r.Output)" }
  if (-not (Test-Path -LiteralPath (Join-Path $npmRoot '@fake\.npmcli-AbCd1234'))) { Pass 'npm staging leftover removed' } else { Fail 'npm leftover kept' }
  $deferredNow = Get-Content -LiteralPath "$aicmHome\state\update-deferred.json" -Raw | ConvertFrom-Json
  if (@($deferredNow.PSObject.Properties).Count -eq 0) { Pass 'deferral cleared after the update' } else { Fail 'deferral not cleared' }
  $r = Invoke-Script $upd @('-Targets', 'fakenpm', '-Scheduled')
  if ($r.Output -match 'already updated today') { Pass 'later scheduled run the same day exits at once' } else { Fail "early exit: $($r.Output)" }

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

  Write-Host '# bad catalog'
  'Bad Id | x | x |  |  |  |  |' | Set-Content -LiteralPath "$work\bad.conf" -Encoding UTF8
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' @('-CatalogFile', "$work\bad.conf", '-LocalCatalogFile', "$work\none.conf")
  if ($r.ExitCode -ne 0) { Pass 'bad catalog rejected' } else { Fail 'bad catalog accepted' }
} finally {
  foreach ($k in $fakeEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
