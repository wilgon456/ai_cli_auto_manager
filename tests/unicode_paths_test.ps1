# Non-ASCII (Korean) profile, AICM_HOME, clone and npm prefix paths. Windows PowerShell 5.1 reads
# BOM-less files and redirected child output with the ANSI code page unless told otherwise; this test
# checks the UTF-8 contract for what the manager writes itself (SOURCE, state JSON, the marker) and for
# Node.js/npm output. Native evidence needs Windows (CI runs it in powershell 5.1 and pwsh); elsewhere
# only the portable parts run. Throwaway folders and a fake npm only; no real profile, task or package.
# This file stays ASCII: the Korean text is built from code points.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('aicm-test-' + [guid]::NewGuid().ToString('N'))
$onWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$ko = -join ([char[]](0xD55C, 0xAE00, 0xC0AC, 0xC6A9, 0xC790))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:fails = 0
function Pass([string]$m) { Write-Host "ok   - $m" }
function Fail([string]$m) { Write-Host "FAIL - $m"; $script:fails++ }
function P([string[]]$Parts) { $p = $Parts[0]; foreach ($x in $Parts[1..($Parts.Count - 1)]) { $p = Join-Path $p $x }; return $p }

$fakeHome = P @($work, "home-$ko")
$aicmHome = P @($fakeHome, '.ai-cli-auto-manager')
$clone = P @($work, "clone-$ko")
$prefix = P @($work, "npm-$ko")
$fakeBin = P @($work, 'bin')
$result = P @($work, 'result.json')

# Runs $Code in a child of this same PowerShell with the lib of $Lib dot-sourced and the throwaway profile.
# The code goes in as UTF-16 (-EncodedCommand), so the Korean paths reach the child unchanged.
function Invoke-Child([string]$Lib, [string]$Code, [hashtable]$Extra = @{}) {
  $text = "Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; . '$(P @($Lib, 'lib', 'aicm-common.ps1'))'; $Code"
  $names = @('HOME', 'USERPROFILE', 'AICM_HOME', 'AICM_NOTIFY', 'PATH', 'AICM_TEST_TEXT', 'AICM_TEST_NPM_PREFIX')
  $saved = @{}
  foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    $env:HOME = $fakeHome; $env:USERPROFILE = $fakeHome; $env:AICM_HOME = $aicmHome; $env:AICM_NOTIFY = '0'
    foreach ($k in $Extra.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$Extra[$k]) }
    $exe = (Get-Process -Id $PID).Path
    $ErrorActionPreference = 'Continue'
    $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($text))) 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
  } finally {
    foreach ($k in $names) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

function Read-Result { return ([System.IO.File]::ReadAllText($result, $utf8) | ConvertFrom-Json) }

New-Item -ItemType Directory -Path $work, $fakeHome, $fakeBin -Force | Out-Null
try {
  New-Item -ItemType Directory -Path $clone -Force | Out-Null
  foreach ($d in 'bin', 'lib', 'rules', 'windows') { Copy-Item -LiteralPath (P @($root, $d)) -Destination (P @($clone, $d)) -Recurse }
  foreach ($f in 'VERSION', 'LICENSE', 'README.md') { Copy-Item -LiteralPath (P @($root, $f)) -Destination (P @($clone, $f)) }
  $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

  # 1. The installed copy records its Korean source path as UTF-8, and reads it back on this engine.
  $r = Invoke-Child $clone "`$a = Sync-AicmAppCopy (Get-AicmRoot); [IO.File]::WriteAllText('$result', (ConvertTo-Json @{ app = `$a }), (New-Object Text.UTF8Encoding(`$false)))"
  $app = P @($aicmHome, 'app')
  $sourceBytes = [System.IO.File]::ReadAllBytes((P @($app, 'SOURCE')))
  if ($r.ExitCode -eq 0 -and $utf8.GetString($sourceBytes).Trim() -eq $clone -and $sourceBytes[0] -ne 0xEF) { Pass 'SOURCE holds the Korean clone path as UTF-8 without a BOM' } else { Fail "SOURCE: $($r.Output)" }
  $marker = [System.IO.File]::ReadAllBytes((P @($aicmHome, '.aicm-home')))
  if ($marker[0] -ne 0xEF) { Pass 'the home marker has no BOM' } else { Fail 'marker BOM' }
  [System.IO.File]::WriteAllText((P @($clone, 'VERSION')), "99.0.0`n")
  $r = Invoke-Child $app 'Update-AicmAppCopy'
  if ($r.Output -match 'updated .* -> 99\.0\.0' -and $r.Output -notmatch 'is gone' -and ([System.IO.File]::ReadAllText((P @($app, 'VERSION')))).Trim() -eq '99.0.0') {
    Pass 'the installed copy finds its Korean source and updates from it'
  } else { Fail "update from a Korean clone: $($r.Output)" }

  # 2. State JSON with Korean text round-trips and is written without a BOM.
  $r = Invoke-Child $clone "Write-AicmState 'unicode-check' ([ordered]@{ path = `$env:AICM_TEST_TEXT }); `$s = Read-AicmState 'unicode-check'; [IO.File]::WriteAllText('$result', (ConvertTo-Json @{ path = `$s.path }), (New-Object Text.UTF8Encoding(`$false)))" @{ AICM_TEST_TEXT = $clone }
  $stateBytes = [System.IO.File]::ReadAllBytes((P @($aicmHome, 'state', 'unicode-check.json')))
  if ($r.ExitCode -eq 0 -and (Read-Result).path -eq $clone -and $stateBytes[0] -ne 0xEF) { Pass 'state JSON keeps a Korean path and has no BOM' } else { Fail "state JSON: $($r.Output)" }

  if (-not $node) {
    Write-Host 'skip - Node.js not found: npm/node output checks'
  } else {
    # 3. Node.js output is read as UTF-8 whatever the console code page.
    $r = Invoke-Child $clone "`$o = Invoke-AicmWithTimeout 'node' @('-e', 'process.stdout.write(process.env.AICM_TEST_TEXT)') 60; [IO.File]::WriteAllText('$result', (ConvertTo-Json @{ out = `$o.StdOut.Trim() }), (New-Object Text.UTF8Encoding(`$false)))" @{ AICM_TEST_TEXT = $ko; PATH = "$(Split-Path -Parent $node.Source)$([System.IO.Path]::PathSeparator)$env:PATH" }
    if ($r.ExitCode -eq 0 -and (Read-Result).out -eq $ko) { Pass 'Node.js output with Korean text is decoded as UTF-8' } else { Fail "node output: $($r.Output)" }

    # 4. A fake npm (a Node.js script, like the real one) under a Korean global prefix.
    $pkg = P @($prefix, 'node_modules', '@fake', 'cli')
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    [System.IO.File]::WriteAllText((P @($pkg, 'package.json')), '{"name":"@fake/cli","version":"1.0.0"}')
    [System.IO.File]::WriteAllText((P @($pkg, 'cli.js')), "console.log('fakecli 1.0.0')`n")
    $js = @(
      'const a = process.argv.slice(2).join(" ");',
      'if (a === "prefix -g") { process.stdout.write(process.env.AICM_TEST_NPM_PREFIX + "\n"); }',
      'else if (a.startsWith("ls -g")) { process.stdout.write(JSON.stringify({ dependencies: { "@fake/cli": { version: "1.0.0" } } }) + "\n"); }',
      'else { process.exit(1); }'
    ) -join "`n"
    [System.IO.File]::WriteAllText((P @($fakeBin, 'npm-fake.js')), $js)
    if ($onWindows) {
      [System.IO.File]::WriteAllText((P @($fakeBin, 'npm.cmd')), "@`"$($node.Source)`" `"%~dp0npm-fake.js`" %*`r`n")
      [System.IO.File]::WriteAllText((P @($prefix, 'fakecli.cmd')), "@`"$($node.Source)`" `"%~dp0node_modules\@fake\cli\cli.js`" %*`r`n")
    } else {
      [System.IO.File]::WriteAllText((P @($fakeBin, 'npm')), "#!/bin/sh`nexec '$($node.Source)' `"`$(dirname `"`$0`")/npm-fake.js`" `"`$@`"`n")
      [System.IO.File]::WriteAllText((P @($prefix, 'fakecli')), "#!/bin/sh`necho 'fakecli 1.0.0'`n")
      & chmod +x (P @($fakeBin, 'npm')) (P @($prefix, 'fakecli'))
    }
    $sep = [System.IO.Path]::PathSeparator
    $sys = if ($onWindows) { "$env:SystemRoot\System32$sep$env:SystemRoot\System32\WindowsPowerShell\v1.0" } else { '/usr/bin:/bin' }
    $code = "`$i = Get-AicmNpmInfo; `$e = [pscustomobject]@{ Id = 'fakecli'; Command = 'fakecli'; Name = 'Fake'; Npm = '@fake/cli'; Brew = ''; Winget = ''; SelfUpdate = ''; Note = ''; Builtin = `$false }; `$c = Get-AicmCliInstall `$e; " +
      "[IO.File]::WriteAllText('$result', (ConvertTo-Json @{ prefix = `$i.Prefix; problem = `$i.PrefixProblem; method = `$c.Method; package = `$c.NpmPackage }), (New-Object Text.UTF8Encoding(`$false)))"
    $r = Invoke-Child $clone $code @{ AICM_TEST_NPM_PREFIX = $prefix; PATH = "$prefix$sep$fakeBin$sep$(Split-Path -Parent $node.Source)$sep$sys" }
    $got = Read-Result
    if ($r.ExitCode -eq 0 -and $got.prefix -eq $prefix -and -not $got.problem) { Pass 'a Korean npm global prefix is read exactly' } else { Fail "npm prefix: $($got | ConvertTo-Json -Compress) $($r.Output)" }
    if ($onWindows) {
      if ($got.method -eq 'npm' -and $got.package -eq '@fake/cli') { Pass 'a CLI in the Korean npm prefix is owned by npm' } else { Fail "owner: $($got | ConvertTo-Json -Compress)" }
    } else { Write-Host 'skip - npm launcher ownership (.cmd shims) is Windows-only' }

    # 5. A prefix that cannot be a folder while npm lists packages: reported, never used to pick an owner.
    $broken = P @($work, "gone-$([char]0xFFFD)", 'npm')
    $r = Invoke-Child $clone $code @{ AICM_TEST_NPM_PREFIX = $broken; PATH = "$prefix$sep$fakeBin$sep$(Split-Path -Parent $node.Source)$sep$sys" }
    $got = Read-Result
    if ($r.ExitCode -eq 0 -and -not $got.prefix -and $got.problem -match 'not a folder' -and $got.method -eq 'unknown') { Pass 'an unreadable npm prefix leaves the owner unknown instead of guessing' } else { Fail "broken prefix: $($got | ConvertTo-Json -Compress) $($r.Output)" }
  }
} finally {
  $resolved = [System.IO.Path]::GetFullPath($work)
  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -match '^aicm-test-[0-9a-f]{32}$') {
    . (P @($root, 'lib', 'aicm-common.ps1'))
    Remove-AicmTree ([System.IO.DirectoryInfo]::new($resolved)) $tempRoot.TrimEnd([char]92, [char]47)
  }
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
