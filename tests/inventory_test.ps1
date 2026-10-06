# Tests for bin\inventory_ai_clis.ps1 and the catalog-driven part of bin\update_ai_clis.ps1 on Windows.
# Uses fake CLIs and a fake npm in a throwaway profile folder; real CLIs are never run or updated.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("aicm-test-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$aicmHome = Join-Path $fakeHome '.ai-cli-auto-manager'
$fakeBin = Join-Path $work 'fakebin'
$prefix = Join-Path $work 'npmprefix'
$solo = Join-Path $work 'solo'
$script:fails = 0

function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }

function Set-NpmPackage([string]$Name, [string]$Version) {
  $dir = Join-Path $prefix ("node_modules\" + $Name.Replace('/', '\'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  "{`"name`":`"$Name`",`"version`":`"$Version`"}" | Set-Content -LiteralPath (Join-Path $dir 'package.json') -Encoding ASCII
}

function Invoke-Script([string]$Script, [string[]]$Arguments) {
  $exe = (Get-Process -Id $PID).Path
  $saved = @{}
  $names = 'USERPROFILE', 'TEMP', 'TMP', 'LOCALAPPDATA', 'AICM_HOME', 'AICM_NOTIFY', 'PATH'
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:USERPROFILE = $fakeHome; $env:TEMP = "$work\tmp"; $env:TMP = "$work\tmp"; $env:LOCALAPPDATA = "$fakeHome\AppData\Local"
    $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'
    $env:PATH = "$fakeBin;$prefix;$solo;$($saved['PATH'])"
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments 2>&1 | Out-String -Width 300
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

try {
  New-Item -ItemType Directory -Path $fakeHome, "$work\tmp", "$fakeHome\AppData\Local", $aicmHome, $fakeBin, $prefix, $solo -Force | Out-Null
  @('@fake/npmcli 1.2.0', '@fake/shadow 3.1.0', '@fake/newcli 0.5.0') | Set-Content -LiteralPath "$work\latest.txt" -Encoding ASCII

  # Fake npm (npm.ps1 plus the npm.cmd twin that real npm installs also have).
  $npmImpl = @'
param()
$prefix = '__PREFIX__'; $work = '__WORK__'
$root = Join-Path $prefix 'node_modules'
function Get-Packages {
  $map = [ordered]@{}
  foreach ($pj in (Get-ChildItem -LiteralPath $root -Recurse -Filter package.json -ErrorAction SilentlyContinue)) {
    $j = Get-Content -LiteralPath $pj.FullName -Raw | ConvertFrom-Json
    $map[$j.name] = @{ version = $j.version }
  }
  return $map
}
function Get-Latest([string]$Name) {
  foreach ($line in (Get-Content -LiteralPath "$work\latest.txt")) { $p = $line -split ' '; if ($p[0] -eq $Name) { return $p[1] } }
  return ''
}
$a = @($args)
switch ($a[0]) {
  'prefix' { Write-Output $prefix; exit 0 }
  'root' { Write-Output $root; exit 0 }
  { $_ -in 'ls', 'list' } {
    $pkg = @($a | Select-Object -Skip 1 | Where-Object { $_ -notlike '-*' })
    $all = Get-Packages
    if ($a -contains '--json') {
      $deps = [ordered]@{}
      foreach ($k in $all.Keys) { if ($pkg.Count -eq 0 -or $pkg -contains $k) { $deps[$k] = $all[$k] } }
      Write-Output (@{ dependencies = $deps } | ConvertTo-Json -Depth 4)
      exit 0
    }
    if ($pkg.Count -gt 0 -and -not $all.Contains($pkg[0])) { exit 1 }
    exit 0
  }
  'view' { Write-Output (Get-Latest $a[1]); exit 0 }
  'install' {
    $spec = $a[-1]; $name = $spec -replace '@latest$', ''
    Add-Content -LiteralPath "$work\npm-installs.log" -Value $name
    $dir = Join-Path $root $name.Replace('/', '\')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    "{`"name`":`"$name`",`"version`":`"$(Get-Latest $name)`"}" | Set-Content -LiteralPath (Join-Path $dir 'package.json') -Encoding ASCII
    exit 0
  }
  default { exit 0 }
}
'@
  $npmImpl.Replace('__PREFIX__', $prefix).Replace('__WORK__', $work) | Set-Content -LiteralPath "$fakeBin\npm.ps1" -Encoding ASCII
  '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0npm.ps1" %*' | Set-Content -LiteralPath "$fakeBin\npm.cmd" -Encoding ASCII

  # npm-managed CLI: shim in the npm prefix, version read from its package.json.
  Set-NpmPackage '@fake/npmcli' '1.0.0'
  "(Get-Content -LiteralPath '$prefix\node_modules\@fake\npmcli\package.json' -Raw | ConvertFrom-Json).version | ForEach-Object { 'fakenpm ' + `$_ }" |
    Set-Content -LiteralPath "$prefix\fakenpm-impl.ps1" -Encoding ASCII
  '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fakenpm-impl.ps1" %*' | Set-Content -LiteralPath "$prefix\fakenpm.cmd" -Encoding ASCII
  # Standalone CLI with a self-update command.
  @(
    '@echo off'
    'if "%1"=="upgrade" (echo upgraded>>"%~dp0..\solo-upgrades.log" & exit /b 0)'
    'echo fakesolo version 2.0.0'
  ) | Set-Content -LiteralPath "$solo\fakesolo.cmd" -Encoding ASCII
  # Standalone CLI on PATH with an older npm copy hidden behind it.
  @('@echo off', 'echo fakeshadow 3.1.0') | Set-Content -LiteralPath "$solo\fakeshadow.cmd" -Encoding ASCII
  Set-NpmPackage '@fake/shadow' '3.0.0'

  $catalog = @(
    '# id        | command    | name         | npm          | brew | winget | self_update | note'
    'fakenpm     | fakenpm    | Fake NPM     | @fake/npmcli |      |        |             |'
    'fakesolo    | fakesolo   | Fake Solo    |              |      |        | upgrade     |'
    'fakeshadow  | fakeshadow | Fake Shadow  | @fake/shadow |      |        |             | ships with an app'
    'fakegone    | fakegone   | Fake Missing | @fake/gone   |      |        |             |'
    'fakenew     | fakenew    | Fake New     | @fake/newcli |      |        |             |'
  )
  $catalog | Set-Content -LiteralPath "$work\catalog.conf" -Encoding UTF8
  $catalog | Set-Content -LiteralPath "$aicmHome\ai-clis.local.conf" -Encoding UTF8
  $inv = @('-CatalogFile', "$work\catalog.conf", '-LocalCatalogFile', "$work\none.conf")

  Write-Host '# first inventory'
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' $inv
  Write-Host $r.Output
  if ($r.ExitCode -eq 0) { Pass 'inventory exits 0' } else { Fail "inventory exit $($r.ExitCode)" }
  if ($r.Output -match '(?m)^Fake NPM +npm +1\.0\.0 +1\.2\.0 +behind +yes') { Pass 'npm CLI: method, versions, behind, covered' } else { Fail 'npm CLI row' }
  if ($r.Output -match '(?m)^Fake Solo +standalone +2\.0\.0 +installed +yes') { Pass 'standalone CLI with self-update is covered' } else { Fail 'standalone row' }
  if ($r.Output -match '(?m)^Fake Shadow +standalone +3\.1\.0 +3\.1\.0 +current +no: ships with an app') { Pass 'standalone without updater is flagged' } else { Fail 'shadow row' }
  if ($r.Output -match 'npm copy 3\.0\.0 is also installed, but PATH runs') { Pass 'hidden npm copy reported' } else { Fail 'hidden npm copy' }
  if ($r.Output -notmatch 'Fake Missing') { Pass 'missing CLI not listed' } else { Fail 'missing CLI listed' }
  if ($r.Output -match '3 AI CLIs installed \(catalog has 5\)') { Pass 'count line' } else { Fail 'count line' }
  $md = Get-Content -LiteralPath "$aicmHome\inventory.md" -Raw -ErrorAction SilentlyContinue
  if ($md -and $md.Contains('| Fake NPM | npm | 1.0.0 | 1.2.0 | behind | yes |')) { Pass 'markdown report' } else { Fail 'markdown report' }
  $state = Get-Content -LiteralPath "$aicmHome\state\inventory.json" -Raw | ConvertFrom-Json
  if (@($state.clis | Where-Object { $_.id -eq 'fakesolo' }).Count -eq 1) { Pass 'json state' } else { Fail 'json state' }
  if ($r.Output -match 'duplicate installs the daily update does not reach:' -and $r.Output -match 'Fake Shadow: PATH runs 3\.1\.0 at .*fakeshadow\.cmd, but the daily update refreshes the npm copy \(3\.0\.0\)\. fix: keep one copy') { Pass 'duplicate install the update cannot reach is reported with a fix' } else { Fail 'duplicate report' }
  if (([regex]::Matches($r.Output, 'notify:')).Count -eq 1 -and $r.Output -match 'notify: .*Fake Shadow: PATH runs') { Pass 'first run notifies only about the duplicate' } else { Fail 'first run notifications' }
  if (@($state.shadowProblems).Count -eq 1) { Pass 'duplicate kept in state for doctor' } else { Fail 'shadow state' }

  Write-Host '# offline'
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' ($inv + '-Offline')
  if ($r.Output -notmatch 'notify:') { Pass 'a known duplicate does not notify again' } else { Fail 'duplicate notified twice' }
  if ($r.Output -match '(?m)^Fake NPM +npm +1\.0\.0 +installed') { Pass '-Offline skips latest lookups' } else { Fail "offline: $($r.Output)" }

  Write-Host '# update through the catalog'
  # Never '-Targets all' here: that would also run the dedicated updaters for real CLIs on this machine.
  $r = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'fakenpm,fakesolo,fakeshadow')
  Write-Host $r.Output
  if ($r.ExitCode -eq 0) { Pass 'update exits 0' } else { Fail "update exit $($r.ExitCode)" }
  $installs = @(Get-Content -LiteralPath "$work\npm-installs.log" -ErrorAction SilentlyContinue)
  if ($installs -contains '@fake/npmcli') { Pass 'npm CLI updated through npm' } else { Fail 'npm CLI not updated' }
  if (Test-Path -LiteralPath "$work\solo-upgrades.log") { Pass 'standalone CLI self-updated' } else { Fail 'self-update not run' }
  if ($r.Output -match 'pass: Fake Shadow is installed standalone') { Pass 'no updater: reported, not failed' } else { Fail 'shadow handling' }
  if ($installs -notcontains '@fake/shadow') { Pass 'hidden npm copy is not touched' } else { Fail 'hidden copy was updated' }
  $r = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'fakenpm')
  if ($r.Output -match 'already current: @fake/npmcli 1\.2\.0') { Pass 'current npm CLI not reinstalled' } else { Fail "reinstalled a current CLI: $($r.Output)" }
  if (@(Get-Content -LiteralPath "$work\npm-installs.log").Count -eq 1) { Pass 'only one npm install happened' } else { Fail 'npm install count' }

  Write-Host '# install-missing only when named'
  $null = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'fakenpm', '-InstallMissing')
  if (@(Get-Content -LiteralPath "$work\npm-installs.log") -notcontains '@fake/newcli') { Pass 'unnamed CLI is not installed' } else { Fail 'unnamed CLI installed' }
  $null = Invoke-Script 'bin\update_ai_clis.ps1' @('-Targets', 'fakenew', '-InstallMissing')
  if (@(Get-Content -LiteralPath "$work\npm-installs.log") -contains '@fake/newcli') { Pass 'named target is installed with -InstallMissing' } else { Fail 'named install' }

  Write-Host '# changes since the last inventory'
  Remove-Item -LiteralPath "$solo\fakesolo.cmd"
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' $inv
  if ($r.Output -match 'removed: Fake Solo') { Pass 'removed CLI reported' } else { Fail 'removed' }
  if ($r.Output -match 'new: Fake New') { Pass 'new CLI reported' } else { Fail 'new' }
  if ($r.Output -match 'updated: Fake NPM 1\.0\.0 -> 1\.2\.0') { Pass 'version change reported' } else { Fail 'updated' }
  if ($r.Output -match 'notify: .*removed: Fake Solo') { Pass 'added/removed CLIs raise a notification' } else { Fail 'notification' }

  Write-Host '# bad catalog'
  'Bad Id | x | x |  |  |  |  |' | Set-Content -LiteralPath "$work\bad.conf" -Encoding UTF8
  $r = Invoke-Script 'bin\inventory_ai_clis.ps1' @('-CatalogFile', "$work\bad.conf", '-LocalCatalogFile', "$work\none.conf")
  if ($r.ExitCode -ne 0) { Pass 'bad catalog rejected' } else { Fail 'bad catalog accepted' }
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
