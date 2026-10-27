# Update-policy tests for Windows and PowerShell Common helpers.
# The portable part runs anywhere PowerShell 7 exists (config validation, route holds, fingerprints).
# The native part runs the Windows updater with fake CLIs and tests\fixtures\npm-fake.js in a throwaway
# profile; it is skipped with a clear message off Windows.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$script:fails = 0
$script:skips = 0

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function Skip([string]$m) { Write-Host "skip - $m"; $script:skips++ }

$onWindows = $false
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $onWindows = [bool]$IsWindows }
else { $onWindows = ($env:OS -eq 'Windows_NT') }

$savedEnv = @{}
foreach ($k in @('AICM_HOME', 'HOME', 'USERPROFILE', 'PATH', 'AICM_MIN_RELEASE_AGE_DAYS', 'AICM_NOTIFY', 'AICM_PROCESSES',
  'AICM_WORKTREES', 'AICM_VERIFY_SIGNATURES', 'AICM_CODEX_RECYCLE', 'AICM_CODEX_UNQUARANTINE', 'CODEX_HOME',
  'FAKE_NPM_DIR', 'FAKE_NPM_PREFIX', 'FAKE_NPM_ROOT', 'NPM', 'BREW', 'TEMP', 'TMP')) {
  $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
}

function Write-Policy([string]$Json, [switch]$Bom) {
  $file = Join-Path $aicmHome 'update-policy.json'
  if ($Bom) {
    [System.IO.File]::WriteAllText($file, $Json, (New-Object System.Text.UTF8Encoding($true)))
  } else {
    [System.IO.File]::WriteAllText($file, $Json, (New-Object System.Text.UTF8Encoding($false)))
  }
}

function Reset-PolicyHome {
  if (Test-Path -LiteralPath $aicmHome) { Remove-Item -LiteralPath $aicmHome -Recurse -Force }
  New-Item -ItemType Directory -Path $aicmHome -Force | Out-Null
  # An existing install: the home is marked. Fixtures below write state\ before a run, and an unmarked
  # folder holding state\ without an installed copy is no longer adopted (no proof it is ours).
  [System.IO.File]::WriteAllText((Join-Path $aicmHome '.aicm-home'), "AI CLI Auto Manager home (logs, state, archive, installed copy)`r`n")
  @(
    'pincli | pincli | Pin CLI | @fake/pin | | | |',
    'agecli | agecli | Age CLI | @fake/age | | | |',
    'solocli | solocli | Solo CLI | | | | upgrade |',
    'excli | excli | Excluded CLI | | | | upgrade |',
    'schedcli | schedcli | Sched CLI | | | | upgrade |'
  ) | Set-Content -LiteralPath (Join-Path $aicmHome 'ai-clis.local.conf') -Encoding ASCII
}

function New-FakeNpmRegistry {
  @'
{
  "@fake/pin": { "latest": "1.3.0", "versions": {
    "1.0.0": { "daysAgo": 90 },
    "1.1.0": { "daysAgo": 30 },
    "1.2.0": { "daysAgo": 10 },
    "1.3.0": { "daysAgo": 1 } } },
  "@fake/age": { "latest": "2.0.0", "versions": {
    "1.0.0": { "daysAgo": 30 },
    "2.0.0": { "daysAgo": 1 } } },
  "@fake/rec": { "latest": "1.0.0", "versions": { "1.0.0": { "daysAgo": 30 } } },
  "@xai-official/grok": { "latest": "2.0.0", "versions": {
    "1.0.0": { "daysAgo": 30 },
    "2.0.0": { "daysAgo": 1 } } }
}
'@ | Set-Content -LiteralPath (Join-Path $work 'registry.json') -Encoding ASCII
}

function Read-Row([string]$Id) {
  $state = Get-Content -LiteralPath (Join-Path $aicmHome 'state\last-update.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($row in @($state.results)) { if ($row.id -eq $Id) { return $row } }
  return $null
}

try {
  New-Item -ItemType Directory -Path $fakeHome, $aicmHome, "$work\tmp" -Force | Out-Null
  $env:AICM_HOME = $aicmHome
  $env:USERPROFILE = $fakeHome
  $env:HOME = $fakeHome
  $env:TEMP = "$work\tmp"
  $env:TMP = "$work\tmp"
  Remove-Item Env:AICM_MIN_RELEASE_AGE_DAYS -ErrorAction SilentlyContinue
  . (Join-Path $root 'lib/aicm-common.ps1')

  Write-Host '# PowerShell sources parse as ASTs'
  foreach ($file in @('lib/aicm-common.ps1', 'bin/update_ai_clis.ps1')) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { Fail "$file has parse errors: $($errors[0].Message)" }
    else { Pass "$file parses without errors" }
  }

  Write-Host '# common helpers read, validate and fingerprint a policy'
  Reset-PolicyHome
  $policy = @'
{"schemaVersion":1,"tools":{
 "gpt":{"minReleaseAgeDays":2},
 "pincli":{"pin":"1.1.0"},
 "agecli":{"minReleaseAgeDays":0},
 "solocli":{"minReleaseAgeDays":7},
 "excli":{"exclude":true}
}}
'@
  Write-Policy $policy
  Initialize-AicmUpdatePolicy 3
  $fp = Get-AicmPolicyFingerprint
  if ($fp -match '^policy:[0-9a-f]{64}$') { Pass 'valid policy yields a policy fingerprint' } else { Fail "fingerprint '$fp'" }
  $alias = Get-AicmPolicyRule 'gpt'
  $codex = Get-AicmPolicyRule 'codex'
  if ($alias -and $codex -and $alias.ExplicitAge -eq $codex.ExplicitAge -and $codex.ExplicitAge -eq 2) { Pass 'gpt aliases codex' } else { Fail 'alias rule' }
  $pinRule = Get-AicmPolicyRule 'pincli'
  if ($pinRule.Pin -eq '1.1.0' -and $pinRule.ExplicitAge -eq -1 -and $pinRule.EffectiveAge -eq 3) { Pass 'pin rule keeps the global effective age' } else { Fail 'pin rule fields' }
  $ageRule = Get-AicmPolicyRule 'agecli'
  if ($ageRule.ExplicitAge -eq 0 -and $ageRule.EffectiveAge -eq 0) { Pass 'explicit age 0 is preserved' } else { Fail 'age0 fields' }
  $soloRule = Get-AicmPolicyRule 'solocli'
  if ($soloRule.EffectiveAge -eq 7) { Pass 'per-tool age overrides the global age' } else { Fail 'per-tool age' }
  if ((Test-AicmPolicyExcluded 'excli') -and -not (Test-AicmPolicyExcluded 'pincli')) { Pass 'exclusion is per tool' } else { Fail 'exclusion lookup' }
  if ((Get-AicmPolicyPin 'pincli') -eq '1.1.0' -and (Get-AicmPolicyPin 'agecli') -eq '') { Pass 'pin lookup is per tool' } else { Fail 'pin lookup' }
  if ($pinRule.Exclude -is [bool] -and $pinRule.ExplicitAge -is [int]) { Pass 'rules are natural objects under StrictMode' } else { Fail 'rule types' }
  if (@($script:AicmPolicyTools.Keys).Count -eq 5) { Pass 'all normalized rules are stored' } else { Fail "rule count $(@($script:AicmPolicyTools.Keys).Count)" }

  $holdPin = Get-AicmPolicyRouteHold 'pincli' 'standalone'
  $holdAge = Get-AicmPolicyRouteHold 'solocli' 'standalone'
  $allowAge0 = Get-AicmPolicyRouteHold 'agecli' 'standalone'
  $allowNpm = Get-AicmPolicyRouteHold 'pincli' 'npm'
  if ($holdPin -match 'requires the npm install route') { Pass 'a pin holds a non-npm route' } else { Fail "pin route hold '$holdPin'" }
  if ($holdAge -match 'cannot be enforced') { Pass 'a positive age holds a non-npm route' } else { Fail "age route hold '$holdAge'" }
  if ([string]::IsNullOrEmpty($allowAge0)) { Pass 'explicit age 0 allows a native route' } else { Fail "age0 hold '$allowAge0'" }
  if ([string]::IsNullOrEmpty($allowNpm)) { Pass 'a pin does not hold the npm route' } else { Fail "npm hold '$allowNpm'" }

  Write-Host '# npm ownership comes from the package reference, not a shared prefix'
  $ownerPrefix = Join-Path $work 'ownerprefix'
  $ownerRoot = Join-Path $ownerPrefix 'node_modules'
  $ownerPkgDir = Join-Path (Join-Path $ownerRoot '@fake') 'pin'
  New-Item -ItemType Directory -Path $ownerPkgDir -Force | Out-Null
  '{"name":"@fake/pin","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $ownerPkgDir 'package.json') -Encoding ASCII
  'console.log("pincli")' | Set-Content -LiteralPath (Join-Path $ownerPkgDir 'cli.js') -Encoding ASCII
  $ownerEntry = [pscustomobject]@{ Id = 'pincli'; Npm = '@fake/pin'; Command = 'pincli'; Builtin = $false }
  $script:AicmNpmInfo = [pscustomobject]@{ Available = $true; Prefix = $ownerPrefix; Packages = @{ '@fake/pin' = '1.0.0' } }
  $shimPath = Join-Path $ownerPrefix 'pincli.cmd'
  "@echo off`r`nnode `"%~dp0node_modules\@fake\pin\cli.js`" %*" | Set-Content -LiteralPath $shimPath -Encoding ASCII
  if ((Get-AicmNpmPathOwner $ownerEntry $shimPath) -eq '@fake/pin') { Pass 'a prefix .cmd with a node_modules reference is npm-owned' } else { Fail 'npm shim owner' }
  if ((Get-AicmNpmPathOwner $ownerEntry (Join-Path $ownerPkgDir 'cli.js')) -eq '@fake/pin') { Pass 'a file resolved inside the package is npm-owned' } else { Fail 'package path owner' }
  $standalonePath = Join-Path $ownerPrefix 'pincli-standalone.cmd'
  "@echo off`r`necho pincli 1.0.0" | Set-Content -LiteralPath $standalonePath -Encoding ASCII
  if ((Get-AicmNpmPathOwner $ownerEntry $standalonePath) -eq '') { Pass 'a standalone launcher in the same prefix is not npm-owned' } else { Fail 'standalone launcher claimed by npm' }
  # An interrupted install keeps a real package reference even when the package folder is missing.
  Remove-Item -LiteralPath $ownerPkgDir -Recurse -Force
  if ((Get-AicmNpmPathOwner $ownerEntry $shimPath) -eq '@fake/pin') { Pass 'a shim still identifies npm after its package folder disappears' } else { Fail 'interrupted shim owner' }
  $script:AicmNpmInfo = $null

  $fp3 = Get-AicmPolicyFingerprint
  Initialize-AicmUpdatePolicy 9
  if ((Get-AicmPolicyFingerprint) -ne $fp3) { Pass 'the fingerprint tracks the global age' } else { Fail 'global age did not change the fingerprint' }
  $fpAge = Get-AicmPolicyFingerprint
  Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.0"}}}'
  Initialize-AicmUpdatePolicy 9
  if ((Get-AicmPolicyFingerprint) -ne $fpAge) { Pass 'the fingerprint tracks policy changes' } else { Fail 'policy change did not change the fingerprint' }

  Write-Host '# malformed, BOM and broken policy locations'
  Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.1.0"}}'
  try { Initialize-AicmUpdatePolicy 3; Fail 'truncated policy was accepted' } catch { Pass 'truncated JSON is rejected' }
  Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"exclude":"false"}}}'
  try { Initialize-AicmUpdatePolicy 3; Fail 'wrong exclude type was accepted' } catch { Pass 'wrong field types are rejected' }
  Write-Policy '{"schemaVersion":1,"tools":{"nope":{"exclude":true}}}'
  try { Initialize-AicmUpdatePolicy 3; Fail 'unknown id was accepted' } catch { Pass 'unknown CLI ids are rejected' }
  Write-Policy $policy -Bom
  try { Initialize-AicmUpdatePolicy 3; Pass 'a UTF-8 BOM policy is accepted' } catch { Fail "BOM policy: $($_.Exception.Message)" }

  Remove-Item -LiteralPath (Join-Path $aicmHome 'update-policy.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $aicmHome 'update-policy.json') | Out-Null
  try { Initialize-AicmUpdatePolicy 3; Fail 'a policy directory was accepted' } catch { Pass 'a policy directory fails closed' }
  Remove-Item -LiteralPath (Join-Path $aicmHome 'update-policy.json') -Recurse -Force

  if (-not $onWindows) {
    try {
      New-Item -ItemType SymbolicLink -Path (Join-Path $aicmHome 'update-policy.json') -Target (Join-Path $work 'missing.json') -ErrorAction Stop | Out-Null
      try { Initialize-AicmUpdatePolicy 3; Fail 'a dangling policy symlink was accepted' } catch { Pass 'a dangling policy symlink fails closed' }
      Remove-Item -LiteralPath (Join-Path $aicmHome 'update-policy.json') -Force
    } catch { Skip "dangling symlink test: $($_.Exception.Message)" }
  } else {
    Skip 'dangling symlink test (Windows symlink privileges)'
  }

  Write-Host '# an adapter refuses empty reader output'
  $shim = Join-Path $work 'fakenode'
  New-Item -ItemType Directory -Path $shim -Force | Out-Null
  if ($onWindows) {
    '@exit /b 0' | Set-Content -LiteralPath (Join-Path $shim 'node.cmd') -Encoding ASCII
  } else {
    "#!/bin/sh`nexit 0" | Set-Content -LiteralPath (Join-Path $shim 'node') -Encoding ASCII
    & chmod +x (Join-Path $shim 'node')
  }
  Write-Policy '{"schemaVersion":1,"tools":{}}'
  $savedPath = $env:PATH
  try {
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $savedPath
    try { Initialize-AicmUpdatePolicy 3; Fail 'empty reader output was accepted' }
    catch {
      if ($_.Exception.Message -match 'incomplete output') { Pass 'empty reader output fails closed' }
      else { Fail "empty reader output: $($_.Exception.Message)" }
    }
  } finally { $env:PATH = $savedPath }
  Remove-Item -LiteralPath (Join-Path $aicmHome 'update-policy.json') -Force

  Write-Host '# a recovery hold is not bypassed by the normal npm update path'
  try {
    & {
      $tokens = $null; $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'bin/update_ai_clis.ps1'), [ref]$tokens, [ref]$errors)
      if ($errors.Count -gt 0) { throw 'source parse error' }
      $wanted = @('Update-NpmPackage', 'Get-PolicyHoldReason')
      $nodes = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name
      }, $true)
      foreach ($n in $nodes) { . ([scriptblock]::Create($n.Extent.Text)) }
      $script:policyHolds = @{ pincli = 'update policy: automatic recovery is held for manual install' }
      $script:managedNpm = New-Object System.Collections.Generic.List[string]
      $script:updated = New-Object System.Collections.Generic.List[string]
      $script:InstallTimeoutSeconds = 600
      $MinReleaseAgeDays = 3
      $script:installs = 0
      function Get-CommandPath([string]$Name) { return 'fake-command' }
      function Test-NpmRegistry { return $true }
      function Get-NpmInstalledVersion([string]$Package) { return '' }
      function Test-AicmPolicyPinRelease([string]$Package, [string]$Pin, [int]$Age, [switch]$Amp) { return '' }
      function Test-AicmNpmRelease { }
      function Get-AicmNpmBeforeArgs { return @() }
      function Invoke-NpmGlobalInstall { $script:installs++; return [pscustomobject]@{ ExitCode = 0; Output = '' } }
      function Note-InstallPkg { }
      Update-NpmPackage '@fake/pin' '1.1.0' 3 'pincli'
    }
    if ($script:installs -eq 0) { Pass 'a held recovery cannot be installed by the normal npm path' }
    else { Fail "held recovery ran $($script:installs) npm install(s)" }
  } catch {
    Fail "recovery hold regression: $($_.Exception.Message)"
  }

  if (-not $onWindows) {
    Skip 'native Windows updater tests (not running on Windows)'
  } else {
    Write-Host '# native Windows updater with fake CLIs and fake npm'
    $fakeBin = Join-Path $work 'fakebin'
    $prefix = Join-Path $work 'npmprefix'
    $npmRoot = Join-Path $prefix 'node_modules'
    New-Item -ItemType Directory -Path $fakeBin, $prefix, $npmRoot -Force | Out-Null
    New-FakeNpmRegistry
    . (Join-Path $PSScriptRoot 'test-env.ps1')
    $runtimePath = New-TestRuntimePath $work
    $fakeJs = Join-Path $root 'tests\fixtures\npm-fake.js'
    "@echo off`r`nnode `"$fakeJs`" %*" | Set-Content -LiteralPath (Join-Path $fakeBin 'npm.cmd') -Encoding ASCII
    "@echo off`r`nexit /b 1" | Set-Content -LiteralPath (Join-Path $fakeBin 'brew.cmd') -Encoding ASCII
    "@echo off`r`nif `"%~1`"==`"--version`" (echo solocli 1.0.0 & exit /b 0)`r`necho upgrade>>`"%FAKE_NPM_DIR%\upgrades.log`"" |
      Set-Content -LiteralPath (Join-Path $fakeBin 'solocli.cmd') -Encoding ASCII
    "@echo off`r`nif `"%~1`"==`"--version`" (exit /b 9)`r`necho upgrade>>`"%FAKE_NPM_DIR%\upgrades.log`"" |
      Set-Content -LiteralPath (Join-Path $fakeBin 'excli.cmd') -Encoding ASCII
    "@echo off`r`nif `"%~1`"==`"--version`" (echo schedcli 1.0.0 & exit /b 0)`r`necho upgrade>>`"%FAKE_NPM_DIR%\upgrades.log`"" |
      Set-Content -LiteralPath (Join-Path $fakeBin 'schedcli.cmd') -Encoding ASCII
    "@echo off`r`nnode `"%~dp0node_modules\@fake\pin\cli.js`" %*" |
      Set-Content -LiteralPath (Join-Path $prefix 'pincli.cmd') -Encoding ASCII

    $savedPath = $env:PATH
    $env:PATH = "$fakeBin;$prefix;$runtimePath"
    $env:FAKE_NPM_DIR = $work
    $env:FAKE_NPM_PREFIX = $prefix
    $env:FAKE_NPM_ROOT = $npmRoot
    $env:AICM_NOTIFY = '0'
    $env:AICM_PROCESSES = '0'
    $env:AICM_WORKTREES = '0'
    $env:AICM_VERIFY_SIGNATURES = '0'
    $env:AICM_CODEX_RECYCLE = '0'
    $env:AICM_CODEX_UNQUARANTINE = '0'
    $env:NPM = ''
    $env:BREW = ''

    function Invoke-FakeNpm([string[]]$Arguments) {
      & node $fakeJs @Arguments | Out-Null
    }
    function Reset-NativeHome {
      if (Test-Path -LiteralPath $aicmHome) { Remove-Item -LiteralPath $aicmHome -Recurse -Force }
      New-Item -ItemType Directory -Path $aicmHome -Force | Out-Null
      Reset-PolicyHome
      foreach ($f in 'upgrades.log', 'npm-calls.log', 'npm-before.log') {
        Remove-Item -LiteralPath (Join-Path $work $f) -Force -ErrorAction SilentlyContinue
      }
    }
    function Reset-NpmRoot {
      if (Test-Path -LiteralPath $npmRoot) { Remove-Item -LiteralPath $npmRoot -Recurse -Force }
      New-Item -ItemType Directory -Path $npmRoot -Force | Out-Null
      $script:AicmNpmInfo = $null
    }
    function Install-FakePackage([string]$Package, [string]$Version, [string]$Command = 'pincli') {
      Invoke-FakeNpm @('install', '-g', "$Package@$Version")
      $rel = $Package -replace '/', '\'
      $pkgDir = Join-Path $npmRoot $rel
      "console.log('$Command ' + require('./package.json').version)" |
        Set-Content -LiteralPath (Join-Path $pkgDir 'cli.js') -Encoding ASCII
      # Fixture setup must not look like an updater action to the call-log assertions.
      Remove-Item -LiteralPath (Join-Path $work 'npm-calls.log') -Force -ErrorAction SilentlyContinue
    }
    function Invoke-Updater([string[]]$Arguments, [hashtable]$Extra = @{}) {
      $exe = (Get-Process -Id $PID).Path
      $extraKeys = @($Extra.Keys)
      $old = @{}
      foreach ($k in $extraKeys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Extra[$k]) }
      try {
        $ErrorActionPreference = 'Continue'
        $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\update_ai_clis.ps1') @Arguments 2>&1 | Out-String -Width 400
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
      } finally {
        foreach ($k in $extraKeys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
      }
    }
    function NpmCalls { $p = Join-Path $work 'npm-calls.log'; if (Test-Path -LiteralPath $p) { return [string](Get-Content -LiteralPath $p -Raw) } return '' }
    function UpgradesRun { Test-Path -LiteralPath (Join-Path $work 'upgrades.log') }

    Reset-NativeHome
    Reset-NpmRoot
    Write-Policy '{"schemaVersion":1,"tools":{"excli":{"exclude":true}}}'
    $r = Invoke-Updater @('-Targets', 'excli', '-InstallMissing')
    $row = Read-Row 'excli'
    if ($r.ExitCode -eq 0) { Pass 'excluded run exits 0' } else { Fail "excluded rc=$($r.ExitCode) $($r.Output)" }
    if (-not (UpgradesRun)) { Pass 'an excluded broken probe is not run' } else { Fail 'excluded CLI ran its update' }
    if ($row -and $row.status -eq 'skipped' -and $row.reason -match 'policy') { Pass 'excluded row is skipped with a policy reason' } else { Fail "excluded row $($row.status) / $($row.reason)" }

    Reset-NativeHome
    Reset-NpmRoot
    New-Item -ItemType Directory -Path (Join-Path $aicmHome 'state') -Force | Out-Null
    $logDir = Join-Path $aicmHome 'logs'
    Write-Policy '{"schemaVersion":1,"tools":{"excli":{"exclude":"false"}}}'
    $r = Invoke-Updater @('-Targets', 'excli')
    if ($r.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $logDir) -and -not (Test-Path -LiteralPath (Join-Path $aicmHome 'state\last-update.json'))) {
      Pass 'malformed policy fails before logs or state'
    } else { Fail "malformed policy rc=$($r.ExitCode) $($r.Output)" }
    Write-Policy '{"schemaVersion":1,"tools":{"excli":{"exclude":true}}}' -Bom
    $r = Invoke-Updater @('-DryRun', '-Targets', 'excli')
    if ($r.ExitCode -eq 0 -and $r.Output -match 'update policy') { Pass 'BOM policy is accepted by the updater' } else { Fail "BOM updater rc=$($r.ExitCode) $($r.Output)" }

    Reset-NativeHome
    Reset-NpmRoot
    Write-Policy '{"schemaVersion":1,"tools":{"solocli":{"pin":"1.1.0"}}}'
    $r = Invoke-Updater @('-Targets', 'solocli')
    $row = Read-Row 'solocli'
    if ($r.ExitCode -eq 0 -and -not (UpgradesRun) -and $row.status -eq 'skipped') { Pass 'a native pin hold does not run the self-update' }
    else { Fail "native pin hold rc=$($r.ExitCode) status=$($row.status)" }
    Write-Policy '{"schemaVersion":1,"tools":{"solocli":{"minReleaseAgeDays":0}}}'
    $r = Invoke-Updater @('-Targets', 'solocli')
    if ($r.ExitCode -eq 0 -and (UpgradesRun)) { Pass 'explicit age 0 permits a native self-update' } else { Fail "native age0 rc=$($r.ExitCode)" }

    Reset-NativeHome
    Reset-NpmRoot
    Write-Policy '{"schemaVersion":1,"tools":{"schedcli":{}}}'
    $r1 = Invoke-Updater @('-Scheduled', '-Targets', 'schedcli')
    $r2 = Invoke-Updater @('-Scheduled', '-Targets', 'schedcli')
    if ($r2.Output -match 'already updated today') { Pass 'unchanged scheduled run skips the retry' } else { Fail "scheduled retry $($r2.Output)" }
    Write-Policy '{"schemaVersion":1,"tools":{"schedcli":{"minReleaseAgeDays":0}}}'
    $r3 = Invoke-Updater @('-Scheduled', '-Targets', 'schedcli')
    if ($r3.Output -notmatch 'already updated today') { Pass 'a policy change reruns the same day' } else { Fail 'policy change was skipped' }

    Reset-NativeHome
    Reset-NpmRoot
    Install-FakePackage '@fake/pin' '1.0.0'
    $script:AicmNpmInfo = $null
    Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.1.0"}}}'
    $r = Invoke-Updater @('-Targets', 'pincli')
    if ($r.ExitCode -eq 0 -and (NpmCalls) -match 'install -g @fake/pin@1\.1\.0' -and (NpmCalls) -notmatch '@fake/pin@1\.3\.0') {
      Pass 'an exact pin installs the pinned version without newest'
    } else { Fail "exact pin rc=$($r.ExitCode) calls=$(NpmCalls)" }

    Reset-NativeHome
    Reset-NpmRoot
    Install-FakePackage '@fake/pin' '1.0.0'
    $script:AicmNpmInfo = $null
    Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.3.0"}}}'
    $r = Invoke-Updater @('-Targets', 'pincli')
    if ((NpmCalls) -notmatch 'install -g') { Pass 'a too-young pin has no fallback install' } else { Fail "young pin calls=$(NpmCalls)" }

    Reset-NativeHome
    Reset-NpmRoot
    Install-FakePackage '@fake/pin' '1.2.0'
    $script:AicmNpmInfo = $null
    Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.1.0"}}}'
    $r = Invoke-Updater @('-Targets', 'pincli')
    if ((NpmCalls) -notmatch 'install -g @fake/pin@1\.1\.0') { Pass 'a pin never downgrades' } else { Fail "downgrade calls=$(NpmCalls)" }

    Reset-NativeHome
    Reset-NpmRoot
    $backup = Join-Path $npmRoot '@fake\.pin-AbCd1234'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    '{"name":"@fake/pin","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $backup 'package.json') -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $aicmHome 'state') -Force | Out-Null
    '{"@fake/pin":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $aicmHome 'state\update-npm.json') -Encoding ASCII
    Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"exclude":true}}}'
    $r = Invoke-Updater @('-Targets', 'pincli')
    $stateText = Get-Content -LiteralPath (Join-Path $aicmHome 'state\update-npm.json') -Raw -Encoding UTF8
    if ((Test-Path -LiteralPath $backup) -and -not ((NpmCalls) -match 'install -g') -and $stateText -match '@fake/pin') {
      Pass 'an excluded backup and its known state are preserved'
    } else { Fail 'excluded backup protection' }

    # A normal npm Grok launcher (direct node_modules reference) takes the npm pin route.
    Reset-NativeHome
    Reset-NpmRoot
    Install-FakePackage '@xai-official/grok' '1.0.0' 'grok'
    "@echo off`r`nnode `"%~dp0node_modules\@xai-official\grok\cli.js`" %*" | Set-Content -LiteralPath (Join-Path $prefix 'grok.cmd') -Encoding ASCII
    $script:AicmNpmInfo = $null
    Write-Policy '{"schemaVersion":1,"tools":{"grok":{"pin":"1.0.0"}}}'
    $r = Invoke-Updater @('-Targets', 'grok')
    if ($r.ExitCode -eq 0 -and $r.Output -match 'already at the pinned version: @xai-official/grok 1\.0\.0' -and (NpmCalls) -notmatch 'install -g' -and $r.Output -notmatch 'requires the npm install route') {
      Pass 'an npm Grok honors its pin on the npm route'
    } else { Fail "npm grok rc=$($r.ExitCode) calls=$(NpmCalls) $($r.Output)" }

    # A standalone Grok in the npm prefix stays on the vendor route, and the pin holds it before any
    # installer runs; the hidden npm copy is never updated.
    Reset-NativeHome
    Reset-NpmRoot
    Install-FakePackage '@xai-official/grok' '1.0.0' 'grok'
    "@echo off`r`nif `"%~1`"==`"--version`" (echo grok 1.0.0 & exit /b 0)`r`necho vendor-ran>>`"%FAKE_NPM_DIR%\upgrades.log`"" |
      Set-Content -LiteralPath (Join-Path $prefix 'grok.cmd') -Encoding ASCII
    $script:AicmNpmInfo = $null
    Write-Policy '{"schemaVersion":1,"tools":{"grok":{"pin":"1.0.0"}}}'
    $r = Invoke-Updater @('-Targets', 'grok')
    if ($r.ExitCode -eq 0 -and $r.Output -match 'requires the npm install route' -and (NpmCalls) -notmatch 'install -g' -and -not (UpgradesRun)) {
      Pass 'a shared-prefix standalone Grok is held on the vendor route'
    } else { Fail "standalone grok rc=$($r.ExitCode) calls=$(NpmCalls) $($r.Output)" }

    # An explicit per-tool age keeps the hidden npm backup and state without updating that copy.
    Reset-NativeHome
    Reset-NpmRoot
    $ageBackup = Join-Path $npmRoot '@fake\.pin-AbCd1234'
    New-Item -ItemType Directory -Path $ageBackup -Force | Out-Null
    '{"name":"@fake/pin","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $ageBackup 'package.json') -Encoding ASCII
    "@echo off`r`nif `"%~1`"==`"--version`" (echo pincli 1.0.0 & exit /b 0)" |
      Set-Content -LiteralPath (Join-Path $fakeBin 'pincli.cmd') -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $aicmHome 'state') -Force | Out-Null
    '{"@fake/pin":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $aicmHome 'state\update-npm.json') -Encoding ASCII
    Write-Policy '{"schemaVersion":1,"tools":{"pincli":{"minReleaseAgeDays":7}}}'
    $r = Invoke-Updater @('-Targets', 'pincli')
    $stateText = Get-Content -LiteralPath (Join-Path $aicmHome 'state\update-npm.json') -Raw -Encoding UTF8
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $ageBackup) -and $stateText -match '@fake/pin' -and (NpmCalls) -notmatch 'install -g') {
      Pass 'an age-only policy preserves a hidden npm backup and its state'
    } else { Fail "age preservation rc=$($r.ExitCode) calls=$(NpmCalls) $($r.Output)" }
    Remove-Item -LiteralPath (Join-Path $fakeBin 'pincli.cmd') -Force -ErrorAction SilentlyContinue

    $env:PATH = $savedPath
  }
} catch {
  Fail "unexpected error: $($_.Exception.Message)"
} finally {
  foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fails -eq 0) {
  Write-Host "ALL PASSED ($($script:skips) skipped)"
  exit 0
}
Write-Host "$($script:fails) FAILED ($($script:skips) skipped)"
exit 1
