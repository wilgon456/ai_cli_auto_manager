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
  [string[]]$Targets = $(if ($env:AI_CLI_TARGETS) { $env:AI_CLI_TARGETS } else { 'kimi,gpt,opencode,agy,claude,grok' }),
  [switch]$InstallMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\aicm-common.ps1')

function Get-Timestamp {
  return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Join-ProcessArguments([string[]]$Arguments) {
  $quoted = foreach ($arg in $Arguments) {
    if ($null -eq $arg) {
      '""'
    } elseif ($arg -eq '') {
      '""'
    } elseif ($arg -notmatch '[\s"]') {
      $arg
    } else {
      '"' + ($arg -replace '"', '\"') + '"'
    }
  }
  return ($quoted -join ' ')
}

function Invoke-WithTimeout([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds) {
  $cmd = Get-Command $Name -ErrorAction Stop
  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $argLine = Join-ProcessArguments $Arguments
    $process = Start-Process -FilePath $cmd.Source -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill() } catch { }
      $partialOutput = @(
        if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue }
        "TIMEOUT after ${TimeoutSeconds}s"
      ) -join ''
      return [pscustomobject]@{ ExitCode = 124; Output = $partialOutput }
    }

    $output = @(
      Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
      Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
    ) -join ''
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
  } finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
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

function Test-GptTargetEnabled {
  return (Test-TargetEnabled 'gpt') -or (Test-TargetEnabled 'codex')
}

Ensure-Directory $LogDir
$logFile = Join-Path $LogDir ("update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$latestLog = Join-Path $LogDir 'latest.log'

Start-Transcript -Path $logFile -Force | Out-Null
try {
  Copy-Item -LiteralPath $logFile -Destination $latestLog -Force -ErrorAction SilentlyContinue

  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $userPart = if ($identity -and $identity.User) { $identity.User.Value -replace '[^A-Za-z0-9._-]', '-' } else { $env:USERNAME -replace '[^A-Za-z0-9._-]', '-' }
  $mutexName = "Local\ai-cli-auto-manager-update-$userPart"
  $mutex = [System.Threading.Mutex]::new($false, $mutexName)
  $hasLock = $false
  try {
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock) {
      Write-Host "[$(Get-Timestamp)] another update run is already active"
      exit 0
    }

    $script:failures = New-Object System.Collections.Generic.List[string]

    function Get-CommandPath([string]$Name) {
      $cmd = Get-Command $Name -ErrorAction SilentlyContinue
      if ($cmd) { return $cmd.Source }
      return $null
    }

    function Write-Version([string]$Name) {
      $path = Get-CommandPath $Name
      if ($path) {
        $result = Invoke-WithTimeout $Name @('--version') $VersionTimeoutSeconds
        $firstLine = (($result.Output -split "`r?`n") | Where-Object { $_ } | Select-Object -First 1)
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

    function Update-NpmPackage([string]$Package) {
      if (-not (Get-CommandPath 'npm')) { throw 'npm is not installed' }
      # Skip the reinstall when already current: reinstalling a CLI that is running fails on Windows (EBUSY).
      $installed = Get-NpmInstalledVersion $Package
      $latest = ((& npm view $Package version 2>$null) -join '').Trim()
      if ($installed -and $latest -and $installed -eq $latest) {
        Write-Host "already current: $Package $installed"
        return
      }
      & npm install -g "$Package@latest"
      if ($LASTEXITCODE -ne 0) { throw "npm install failed for $Package with exit code $LASTEXITCODE" }
    }

    function Install-NpmPackage([string]$Package) {
      Update-NpmPackage $Package
    }

    function Update-AgyCli {
      if (-not (Get-CommandPath 'agy')) { throw 'agy is not installed' }
      $result = Invoke-WithTimeout 'agy' @('update') 300
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

    function Update-ClaudeCli {
      if (Test-NpmGlobalPackage '@anthropic-ai/claude-code') {
        Update-NpmPackage '@anthropic-ai/claude-code'
      } elseif (Get-CommandPath 'claude') {
        $result = Invoke-WithTimeout 'claude' @('update') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "claude update failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage '@anthropic-ai/claude-code'
      } else {
        Pass-Missing 'claude' 'command not found and npm global package not installed'
      }
    }

    function Update-OpenCodeCli {
      if (Test-NpmGlobalPackage 'opencode-ai') {
        Update-NpmPackage 'opencode-ai'
      } elseif (Get-CommandPath 'opencode') {
        $result = Invoke-WithTimeout 'opencode' @('upgrade') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "opencode upgrade failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage 'opencode-ai'
      } else {
        Pass-Missing 'opencode' 'command not found and npm global package not installed'
      }
    }

    function Install-OrUpdate-GrokCli {
      $result = Invoke-WithTimeout 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://x.ai/cli/install.ps1 | iex') 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "grok installer failed with exit code $($result.ExitCode)" }
    }

    function Update-GrokCli {
      if (Get-CommandPath 'grok') {
        Install-OrUpdate-GrokCli
      } elseif ($InstallMissing) {
        Install-OrUpdate-GrokCli
      } else {
        Pass-Missing 'grok' 'command not found'
      }
    }

    Write-Host "[$(Get-Timestamp)] AI CLI update started"
    Write-Host "host=$env:COMPUTERNAME user=$env:USERNAME dry_run=$DryRun targets=$(($Targets -join ',')) install_missing=$InstallMissing"
    Remove-OldLogs $LogDir $LogRetentionDays

    Write-Host ""
    Write-Host "== before versions =="
    if (Test-GptTargetEnabled) { Write-Version codex }
    if (Test-TargetEnabled 'opencode') { Write-Version opencode }
    if (Test-TargetEnabled 'agy') { Write-Version agy }
    if (Test-TargetEnabled 'kimi') { Write-Version kimi }
    if (Test-TargetEnabled 'claude') { Write-Version claude }
    if (Test-TargetEnabled 'grok') { Write-Version grok }

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

    Write-Host ""
    Write-Host "== after versions =="
    if (Test-GptTargetEnabled) { Write-Version codex }
    if (Test-TargetEnabled 'opencode') { Write-Version opencode }
    if (Test-TargetEnabled 'agy') { Write-Version agy }
    if (Test-TargetEnabled 'kimi') { Write-Version kimi }
    if (Test-TargetEnabled 'claude') { Write-Version claude }
    if (Test-TargetEnabled 'grok') { Write-Version grok }

    # Optional user hook, e.g. reload a daemon that keeps old CLI binaries loaded. Failure is only a warning.
    $hook = Join-Path (Get-AicmHome) 'hooks\post-update.ps1'
    if (-not $DryRun -and (Test-Path -LiteralPath $hook)) {
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

    $problems = @(Get-AicmScheduleProblems -Skip 'Update')
    foreach ($p in $problems) { Write-Host "problem: $p" }
    if (-not $DryRun) {
      Write-AicmState 'last-update' ([ordered]@{
        finishedAt = Get-AicmTimestamp
        version = Get-AicmVersion
        ok = ($script:failures.Count -eq 0)
        failures = @($script:failures)
        logFile = $logFile
      })
      $attention = @($script:failures | ForEach-Object { "update failed: $_" }) + $problems
      if ($attention.Count -gt 0) { Send-AicmNotification 'AI CLI Auto Manager' ($attention -join '; ') }
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
