<#
.SYNOPSIS
  Updates installed AI coding CLIs on Windows (AI CLI Auto Manager).
.DESCRIPTION
  Conservative updater for selected AI coding CLIs.
  Missing CLIs/packages are treated as pass/skip, not failures.
#>
[CmdletBinding()]
param(
  [Alias('Check')]
  [switch]$DryRun,
  [string]$LogDir = $(if ($env:LOG_DIR) { $env:LOG_DIR } else { Join-Path $(if ($env:AICM_HOME) { $env:AICM_HOME } else { Join-Path $env:USERPROFILE '.ai-cli-auto-manager' }) 'logs' }),
  [int]$LogRetentionDays = $(if ($env:LOG_RETENTION_DAYS) { [int]$env:LOG_RETENTION_DAYS } else { 30 }),
  [int]$VersionTimeoutSeconds = $(if ($env:VERSION_TIMEOUT_SECONDS) { [int]$env:VERSION_TIMEOUT_SECONDS } else { 10 }),
  [string[]]$Targets = $(if ($env:AI_CLI_TARGETS) { $env:AI_CLI_TARGETS } else { 'all' }),
  [switch]$InstallMissing,
  # npm releases younger than this are not installed yet (env AICM_MIN_RELEASE_AGE_DAYS, default 3; 0 = newest).
  [int]$MinReleaseAgeDays = -1,
  # Set by the scheduled task, which also retries during the day: a run after a complete success the
  # same day exits right away.
  [switch]$Scheduled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\aicm-common.ps1')
if ($MinReleaseAgeDays -lt 0) { $MinReleaseAgeDays = Get-AicmMinReleaseAgeDays }

function Get-Timestamp {
  return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Remove-OldLogs([string]$Path, [int]$RetentionDays) {
  if ($DryRun) {
    Write-Host 'dry-run: skipped log cleanup'
    return
  }
  if ($RetentionDays -lt 0) {
    Write-Host "warn: invalid LogRetentionDays=$RetentionDays; skipping log cleanup"
    return
  }
  if ($RetentionDays -eq 0) {
    Write-Host 'pass: log cleanup disabled'
    return
  }
  $cutoff = (Get-Date).AddDays(-$RetentionDays)
  $logs = @(Get-ChildItem -LiteralPath $Path -Filter 'update-*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
  foreach ($log in $logs) {
    Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
  }
  Write-Host "log cleanup: removed $($logs.Count) update logs older than ${RetentionDays}d"
}

function Test-TargetEnabled([string]$Name) {
  $selected = @(($Targets -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
  return ($selected -contains 'all') -or ($selected -contains $Name.ToLowerInvariant())
}

# True only when the id is named explicitly (not through 'all'); used before installing anything new.
function Test-TargetNamed([string]$Name) {
  $selected = @(($Targets -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
  return ($selected -contains $Name.ToLowerInvariant())
}

function Test-GptTargetEnabled {
  return (Test-TargetEnabled 'gpt') -or (Test-TargetEnabled 'codex')
}

Ensure-Directory $LogDir
$logFile = Join-Path $LogDir ("update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$latestLog = Join-Path $LogDir 'latest.log'

Start-Transcript -Path $logFile -Force | Out-Null
try {
  Copy-Item -LiteralPath $logFile -Destination $latestLog -Force -ErrorAction SilentlyContinue

  $mutexName = Get-AicmLockName 'update'
  $mutex = [System.Threading.Mutex]::new($false, $mutexName)
  $hasLock = $false
  try {
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock) {
      Write-Host "[$(Get-Timestamp)] another update run is already active"
      exit 0
    }

    if ($Scheduled -and -not $DryRun) {
      $last = Read-AicmState 'last-update'
      $lastPending = $last -and $last.PSObject.Properties['pending'] -and $last.pending
      if ($last -and $last.ok -and -not $lastPending) {
        $lastDay = $null
        try { $lastDay = [datetime]::Parse($last.finishedAt).ToLocalTime().Date } catch { }
        if ($lastDay -eq (Get-Date).Date) {
          Write-Host "[$(Get-Timestamp)] already updated today ($($last.finishedAt)); nothing to retry"
          exit 0
        }
      }
    }

    $script:failures = New-Object System.Collections.Generic.List[string]
    $script:deferred = [ordered]@{}
    $script:updated = New-Object System.Collections.Generic.List[string]
    $script:pending = $false
    $script:registryOk = $null
    $script:processCache = $null

    function Get-CommandPath([string]$Name) {
      $cmd = Get-Command $Name -ErrorAction SilentlyContinue
      if ($cmd) { return $cmd.Source }
      return $null
    }

    # Every version line printed is also collected, so before and after can be compared.
    $script:versionText = ''
    function Write-Version([string]$Name) {
      $path = Get-CommandPath $Name
      if ($path) {
        $result = Invoke-AicmWithTimeout $Name @('--version') $VersionTimeoutSeconds
        $firstLine = (($result.Output -split "`r?`n") | Where-Object { $_ } | Select-Object -First 1)
        $script:versionText += "$Name=$firstLine;"
        if ($result.ExitCode -eq 124) {
          Write-Host "${Name}: TIMEOUT after ${VersionTimeoutSeconds}s"
        } elseif ($result.ExitCode -ne 0) {
          $detail = if ($firstLine) { ": $firstLine" } else { '' }
          Write-Host "${Name}: ERROR rc=$($result.ExitCode)$detail"
        } else {
          $versionLine = if ($firstLine) { $firstLine } else { 'unknown' }
          Write-Host "${Name}: $versionLine"
        }
        Write-Host "  path: $path"
      } else {
        Write-Host "${Name}: not installed"
      }
    }

    function Test-NpmGlobalPackage([string]$Package) {
      $npm = Get-CommandPath 'npm'
      if (-not $npm) { return $false }
      & npm list -g --depth=0 $Package *> $null
      return ($LASTEXITCODE -eq 0)
    }

    function Invoke-Step([string]$Name, [scriptblock]$Action) {
      Write-Host ""
      Write-Host "== $Name =="
      if ($DryRun) {
        Write-Host "dry-run: skipped $Name"
        return
      }
      try {
        & $Action
        Write-Host "ok: $Name"
      } catch {
        Write-Host "fail: $Name failed: $($_.Exception.Message)"
        $script:failures.Add($Name) | Out-Null
      }
    }

    function Pass-Missing([string]$Tool, [string]$Reason) {
      Write-Host "pass: $Tool not installed or not managed here ($Reason)"
    }

    function Get-NpmInstalledVersion([string]$Package) {
      $raw = (& npm list -g --depth=0 --json $Package 2>$null) -join "`n"
      try {
        $deps = ($raw | ConvertFrom-Json).dependencies
        if ($deps -and $deps.PSObject.Properties[$Package]) { return [string]$deps.PSObject.Properties[$Package].Value.version }
      } catch { }
      return ''
    }

    # Only releases at least $MinReleaseAgeDays old are installed, and only after they look like the
    # installed release (provenance kept, no new install scripts) and pass a staged signature check.
    # Registry reachable? Checked once per run; when it is not, npm updates are skipped, not failed.
    function Test-NpmRegistry {
      if ($null -eq $script:registryOk) {
        $r = Invoke-AicmWithTimeout 'npm' @('ping') 30
        $script:registryOk = ($r.ExitCode -eq 0)
        if (-not $script:registryOk) { Write-Host 'registry unreachable: npm updates are skipped this run and retried later' }
      }
      return $script:registryOk
    }

    # Processes running from a global npm package. Windows cannot replace their files (EBUSY).
    function Get-NpmPackageUsers([string]$Package) {
      if ($null -eq $script:processCache) {
        $script:processCache = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, Name, ExecutablePath, CommandLine)
      }
      $prefix = (Get-AicmNpmInfo).Prefix
      if (-not $prefix) { return @() }
      $dir = (Join-Path $prefix ('node_modules\' + $Package.Replace('/', '\'))) + '\'
      return @($script:processCache | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.CommandLine -and $_.CommandLine.IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
    }

    function Add-Deferred([string]$Package, [string]$Why) {
      Write-Host "deferred: $Package $Why; retried on the next run"
      $script:deferred[$Package] = $Why
    }

    function Update-NpmPackage([string]$Package) {
      if (-not (Get-CommandPath 'npm')) { throw 'npm is not installed' }
      if (-not (Test-NpmRegistry)) { $script:pending = $true; return }
      $installed = Get-NpmInstalledVersion $Package
      $target = Get-AicmNpmTarget $Package $MinReleaseAgeDays
      if (-not $target) {
        Write-Host "hold: no release of $Package is $MinReleaseAgeDays days old yet"
        return
      }
      # Skip the reinstall when already current: reinstalling a CLI that is running fails on Windows (EBUSY).
      if ($installed -and (Compare-AicmVersion $installed $target) -ge 0) {
        Write-Host "already current: $Package $installed (newest release at least $MinReleaseAgeDays days old: $target)"
        return
      }
      Write-Host "candidate: $Package $installed -> $target"
      $users = @(Get-NpmPackageUsers $Package)
      if ($users.Count -gt 0) {
        Add-Deferred $Package "is running ($($users.Count) processes, e.g. $($users[0].Name) pid $($users[0].ProcessId))"
        return
      }
      Test-AicmNpmRelease $Package $installed $target
      # npm writes errors to stderr; keep them as text instead of turning them into a terminating error.
      $ErrorActionPreference = 'Continue'
      $out = @(& npm install -g "$Package@$target" 2>&1 | ForEach-Object { "$_" })
      $rc = $LASTEXITCODE
      $out | ForEach-Object { Write-Host $_ }
      if ($rc -ne 0) {
        # A file still held by a process that started meanwhile: try again later instead of failing.
        if (($out -join "`n") -match 'EBUSY|EPERM|resource busy|operation not permitted') { Add-Deferred $Package 'files are in use'; return }
        throw "npm install failed for $Package with exit code $rc"
      }
      $script:updated.Add($Package)
    }

    function Install-NpmPackage([string]$Package) {
      Update-NpmPackage $Package
    }

    function Update-AgyCli {
      if (-not (Get-CommandPath 'agy')) { throw 'agy is not installed' }
      $result = Invoke-AicmWithTimeout 'agy' @('update') 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "agy update failed with exit code $($result.ExitCode)" }
    }

    function Update-KimiCli {
      if (Test-NpmGlobalPackage '@moonshot-ai/kimi-code') {
        Update-NpmPackage '@moonshot-ai/kimi-code'
      } elseif (Get-CommandPath 'kimi') {
        Write-Host 'kimi command exists but is not npm-managed; skipping unattended update'
        Write-Host '      reinstall/update with npm for automation: npm install -g @moonshot-ai/kimi-code@latest'
      } elseif ($InstallMissing) {
        Install-NpmPackage '@moonshot-ai/kimi-code'
      } else {
        Pass-Missing 'kimi' 'command not found and npm global package not installed'
      }
    }

    # The copy on PATH decides how a CLI is updated. A second copy elsewhere (for example an npm copy
    # behind a standalone one) is reported, because updating it would not change what the terminal runs.
    function Get-ActiveInstall([string]$Id) {
      $entry = @(Read-AicmCatalog | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
      if (-not $entry) { return $null }
      return (Get-AicmCliInstall $entry)
    }

    function Write-ShadowWarning([string]$Id) {
      $inst = Get-ActiveInstall $Id
      if ($inst -and $inst.NpmCopy -and $inst.Method -ne 'npm') {
        Write-Host "warn: PATH runs $($inst.Path); the npm copy $($inst.NpmCopy) is a second install that the terminal does not use."
        Write-Host "      $(Get-AicmShadowFix $inst)"
      }
    }

    function Invoke-ActiveSelfUpdate($Install, [string[]]$SelfArgs) {
      $result = Invoke-AicmWithTimeout $Install.Path $SelfArgs 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "$($Install.Path) $($SelfArgs -join ' ') failed with exit code $($result.ExitCode)" }
    }

    function Update-ClaudeCli {
      $inst = Get-ActiveInstall 'claude'
      if ($inst -and $inst.Installed -and $inst.Method -eq 'standalone') {
        Invoke-ActiveSelfUpdate $inst @('update')
        Write-ShadowWarning 'claude'
      } elseif (Test-NpmGlobalPackage '@anthropic-ai/claude-code') {
        Update-NpmPackage '@anthropic-ai/claude-code'
      } elseif (Get-CommandPath 'claude') {
        $result = Invoke-AicmWithTimeout 'claude' @('update') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "claude update failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage '@anthropic-ai/claude-code'
      } else {
        Pass-Missing 'claude' 'command not found and npm global package not installed'
      }
    }

    function Update-OpenCodeCli {
      $inst = Get-ActiveInstall 'opencode'
      if ($inst -and $inst.Installed -and $inst.Method -eq 'standalone') {
        Invoke-ActiveSelfUpdate $inst @('upgrade')
        Write-ShadowWarning 'opencode'
      } elseif (Test-NpmGlobalPackage 'opencode-ai') {
        Update-NpmPackage 'opencode-ai'
      } elseif (Get-CommandPath 'opencode') {
        $result = Invoke-AicmWithTimeout 'opencode' @('upgrade') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "opencode upgrade failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage 'opencode-ai'
      } else {
        Pass-Missing 'opencode' 'command not found and npm global package not installed'
      }
    }

    function Install-OrUpdate-GrokCli {
      $result = Invoke-AicmWithTimeout 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://x.ai/cli/install.ps1 | iex') 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "grok installer failed with exit code $($result.ExitCode)" }
    }

    function Update-GrokCli {
      $grokPath = Get-CommandPath 'grok'
      $npmPrefix = (Get-AicmNpmInfo).Prefix
      if ($grokPath -and $npmPrefix -and (Test-AicmUnder $grokPath $npmPrefix) -and (Test-NpmGlobalPackage '@xai-official/grok')) {
        Update-NpmPackage '@xai-official/grok'
      } elseif ($grokPath) {
        # The vendor installer is a remote script; run it only when a newer release (past the waiting
        # period) exists. The npm package carries the same version numbers.
        if ((Get-CommandPath 'npm') -and (Test-NpmRegistry)) {
          $have = Get-AicmSemver (Invoke-AicmWithTimeout $grokPath @('--version') 15).Output
          $want = Get-AicmNpmTarget '@xai-official/grok' $MinReleaseAgeDays
          if ($have -and (-not $want -or (Compare-AicmVersion $have $want) -ge 0)) {
            Write-Host "already current: grok $have (newest release at least $MinReleaseAgeDays days old: $want)"
            return
          }
        }
        Install-OrUpdate-GrokCli
        Write-ShadowWarning 'grok'
      } elseif ($InstallMissing) {
        Install-OrUpdate-GrokCli
      } else {
        Pass-Missing 'grok' 'command not found'
      }
    }

    function Update-WingetPackage([string]$Id) {
      $result = Invoke-AicmWithTimeout 'winget' @('upgrade', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity') 900
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      $noUpdate = ($result.ExitCode -eq -1978335189) -or ($result.Output -match '(?i)no (applicable|available) upgrade|no newer package')
      if ($result.ExitCode -ne 0 -and -not $noUpdate) { throw "winget upgrade $Id failed with exit code $($result.ExitCode)" }
    }

    function Invoke-SelfUpdate($Entry) {
      $selfArgs = @($Entry.SelfUpdate -split '\s+' | Where-Object { $_ })
      $result = Invoke-AicmWithTimeout $Entry.Command $selfArgs 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "$($Entry.Command) $($Entry.SelfUpdate) failed with exit code $($result.ExitCode)" }
    }

    # Catalog CLIs without dedicated logic (rules\ai-clis.conf). Only installed ones are touched.
    $catalogExtras = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Read-AicmCatalog | Where-Object { -not $_.Builtin })) {
      if (-not (Test-TargetEnabled $entry.Id)) { continue }
      $install = Get-AicmCliInstall $entry
      if ($install.Installed -or ($InstallMissing -and $entry.Npm -and (Test-TargetNamed $entry.Id))) {
        $catalogExtras.Add([pscustomobject]@{ Entry = $entry; Install = $install })
      }
    }

    Write-Host "[$(Get-Timestamp)] AI CLI update started"
    Write-Host "host=$env:COMPUTERNAME user=$env:USERNAME dry_run=$DryRun targets=$(($Targets -join ',')) install_missing=$InstallMissing min_release_age_days=$MinReleaseAgeDays"
    Remove-OldLogs $LogDir $LogRetentionDays

    Write-Host ""
    Write-Host "== before versions =="
    if (Test-GptTargetEnabled) { Write-Version codex }
    if (Test-TargetEnabled 'opencode') { Write-Version opencode }
    if (Test-TargetEnabled 'agy') { Write-Version agy }
    if (Test-TargetEnabled 'kimi') { Write-Version kimi }
    if (Test-TargetEnabled 'claude') { Write-Version claude }
    if (Test-TargetEnabled 'grok') { Write-Version grok }
    foreach ($x in $catalogExtras) { if ($x.Entry.Command) { Write-Version $x.Entry.Command } else { Write-Host "$($x.Entry.Name): $(Get-AicmWingetVersion $x.Entry.Winget) (winget)" } }

    if (Test-GptTargetEnabled) {
      if (Test-NpmGlobalPackage '@openai/codex') {
        Invoke-Step 'gpt/codex via npm' { Update-NpmPackage '@openai/codex' }
      } elseif (-not (Get-CommandPath 'codex') -and $InstallMissing) {
        Invoke-Step 'gpt/codex via npm install' { Install-NpmPackage '@openai/codex' }
      } elseif (-not (Get-CommandPath 'codex')) {
        Pass-Missing 'gpt' 'codex command not found and npm global package not installed'
      } else {
        Pass-Missing 'gpt' 'codex command exists but no supported Windows package manager was detected'
      }
      # The Codex desktop app puts its own copy on PATH and updates it itself; say so when npm's copy is hidden.
      Write-ShadowWarning 'codex'
    }

    if (Test-TargetEnabled 'opencode') {
      Invoke-Step 'opencode' { Update-OpenCodeCli }
    }

    if (Test-TargetEnabled 'agy') {
      if (Get-CommandPath 'agy') {
        Invoke-Step 'antigravity cli via agy' { Update-AgyCli }
      } else {
        Pass-Missing 'agy' 'command not found'
      }
    }

    if (Test-TargetEnabled 'kimi') {
      Invoke-Step 'kimi code via npm' { Update-KimiCli }
    }

    if (Test-TargetEnabled 'claude') {
      Invoke-Step 'claude code' { Update-ClaudeCli }
    }

    if (Test-TargetEnabled 'grok') {
      Invoke-Step 'grok build' { Update-GrokCli }
    }

    foreach ($x in $catalogExtras) {
      $e = $x.Entry
      if (-not $x.Install.Installed) {
        Invoke-Step "$($e.Name) via npm install" { Install-NpmPackage $e.Npm }
        continue
      }
      switch ($x.Install.Method) {
        'npm' { Invoke-Step "$($e.Name) via npm" { Update-NpmPackage $e.Npm } }
        'winget' {
          if ($e.Winget) { Invoke-Step "$($e.Name) via winget" { Update-WingetPackage $e.Winget } }
          else { Pass-Missing $e.Id 'installed with winget but the catalog has no winget id' }
        }
        default {
          if ($e.SelfUpdate -and $e.SelfUpdate -ne '@installer') { Invoke-Step "$($e.Name) self-update" { Invoke-SelfUpdate $e } }
          else { Write-Host ""; Write-Host "pass: $($e.Name) is installed standalone without a self-update command; update it manually" }
        }
      }
    }

    $versionsBefore = $script:versionText
    $script:versionText = ''
    Write-Host ""
    Write-Host "== after versions =="
    if (Test-GptTargetEnabled) { Write-Version codex }
    if (Test-TargetEnabled 'opencode') { Write-Version opencode }
    if (Test-TargetEnabled 'agy') { Write-Version agy }
    if (Test-TargetEnabled 'kimi') { Write-Version kimi }
    if (Test-TargetEnabled 'claude') { Write-Version claude }
    if (Test-TargetEnabled 'grok') { Write-Version grok }
    $script:AicmWingetText = $null
    foreach ($x in $catalogExtras) { if ($x.Entry.Command) { Write-Version $x.Entry.Command } else { Write-Host "$($x.Entry.Name): $(Get-AicmWingetVersion $x.Entry.Winget) (winget)" } }

    # Optional user hook, e.g. reload a daemon that keeps old CLI binaries loaded. Runs only when a CLI
    # version actually changed (the job retries during the day). Failure is only a warning.
    $hook = Join-Path (Get-AicmHome) 'hooks\post-update.ps1'
    $versionsChanged = $versionsBefore -ne $script:versionText
    if (-not $DryRun -and -not $versionsChanged -and (Test-Path -LiteralPath $hook)) { Write-Host ''; Write-Host 'post-update hook skipped: no CLI version changed' }
    if (-not $DryRun -and $versionsChanged -and (Test-Path -LiteralPath $hook)) {
      Write-Host ""
      Write-Host "== post-update hook =="
      try {
        & $hook
        Write-Host "ok: post-update hook"
      } catch {
        Write-Host "warn: post-update hook failed: $($_.Exception.Message)"
      }
    }

    Write-Host ""
    Write-Host "log_file=$logFile"

    # MCP servers, browsers and agent CLIs left running after their session ended (lib\processes.js).
    $procAttention = @()
    if ($env:AICM_PROCESSES -ne '0' -and -not $DryRun) {
      Write-Host ''
      Write-Host '== processes left behind by agent sessions =='
      $procAttention = @((Invoke-AicmNodeModule 'processes' @()).Attention)
    }

    $problems = @(Get-AicmScheduleProblems -Skip 'Update') + $procAttention
    foreach ($p in $problems) { Write-Host "problem: $p" }
    if (-not $DryRun) {
      # Remember since when each package has been deferred; remind when it stays stuck for 5+ days.
      $prevDeferred = Read-AicmState 'update-deferred'
      $since = [ordered]@{}
      foreach ($k in @($script:deferred.Keys)) {
        $first = Get-AicmTimestamp
        if ($prevDeferred -and $prevDeferred.PSObject.Properties[$k]) { $first = [string]$prevDeferred.PSObject.Properties[$k].Value }
        $since[$k] = $first
        $days = 0
        try { $days = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($first).ToUniversalTime()).TotalDays } catch { }
        if ($days -ge 5) { $problems += "$k has not been updated for $days days because it is always running; close its sessions for a moment or run 'aicm update' when it is idle" }
      }
      Write-AicmState 'update-deferred' $since
      Remove-AicmNpmLeftovers
      Update-AicmAppCopy
      Write-AicmState 'last-update' ([ordered]@{
        finishedAt = Get-AicmTimestamp
        version = Get-AicmVersion
        ok = ($script:failures.Count -eq 0)
        pending = ($script:pending -or $script:deferred.Count -gt 0)
        deferred = @($script:deferred.Keys)
        failures = $script:failures.ToArray()
        logFile = $logFile
      })
      $attention = @($script:failures | ForEach-Object { "update failed: $_" }) + $problems
      Send-AicmAttention 'update' $attention
    }

    if ($script:failures.Count -gt 0) {
      Write-Host "[$(Get-Timestamp)] AI CLI update finished with failures: $($script:failures -join ', ')"
      exit 1
    }

    Write-Host "[$(Get-Timestamp)] AI CLI update finished successfully"
    exit 0
  } finally {
    if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
  }
} finally {
  Stop-Transcript | Out-Null
  Copy-Item -LiteralPath $logFile -Destination $latestLog -Force -ErrorAction SilentlyContinue
}
