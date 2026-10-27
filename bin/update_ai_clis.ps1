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

# Update policy preflight. A policy file needs Node.js and must be valid before this run creates a
# log directory, lock or state file; a broken policy never starts a run.
Initialize-AicmUpdatePolicy $MinReleaseAgeDays

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

# The selected targets, normalized (lower case, sorted, no duplicates): 'all' or e.g. 'claude,codex'.
function Get-RunTargets {
  $selected = @(($Targets -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
  if ($selected.Count -eq 0 -or $selected -contains 'all') { return 'all' }
  return ($selected -join ',')
}

# A scheduled retry has nothing to do when the last run finished today (local calendar day) without
# failures or pending work and covered every target of this run. A partial manual run
# ('aicm update --targets claude') therefore does not stop the full scheduled run.
function Test-DoneToday {
  $last = Read-AicmState 'last-update'
  if (-not $last -or -not $last.PSObject.Properties['ok'] -or -not $last.ok) { return $false }
  if ($last.PSObject.Properties['pending'] -and $last.pending) { return $false }
  # State from before policy fingerprints is not trusted for a same-day skip: a policy may have
  # appeared, changed or been removed, and a conservative run is cheap.
  if (-not $last.PSObject.Properties['policyFingerprint']) { return $false }
  if ([string]$last.policyFingerprint -ne (Get-AicmPolicyFingerprint)) { return $false }
  $day = ''
  if ($last.PSObject.Properties['localDate']) { $day = ConvertTo-AicmDay $last.localDate }
  elseif ($last.PSObject.Properties['finishedAt']) {
    $finished = ConvertTo-AicmDate $last.finishedAt
    if ($finished) { $day = $finished.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
  }
  if ($day -ne (Get-AicmToday)) { return $false }
  # State from before targets were recorded: unknown coverage, so run.
  if (-not $last.PSObject.Properties['targets']) { return $false }
  $done = @(([string]$last.targets) -split ',' | Where-Object { $_ })
  if ($done -contains 'all') { return $true }
  $want = Get-RunTargets
  if ($want -eq 'all') { return $false }
  foreach ($t in ($want -split ',')) { if ($done -notcontains $t) { return $false } }
  return $true
}

# Another run holds the lock. When it started more than 3 hours ago it is probably stuck (a postinstall
# waiting on the network, say), and it blocks every later run; say so once instead of exiting quietly.
$script:StuckHours = 3
function Test-StuckRun {
  $run = Read-AicmState 'update-running'
  if (-not $run -or -not $run.PSObject.Properties['startedAt']) { return }
  $started = ConvertTo-AicmDate $run.startedAt
  if (-not $started) { return }
  $hours = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime()).TotalHours
  if ($hours -lt $script:StuckHours) { return }
  $runPid = if ($run.PSObject.Properties['pid']) { $run.pid } else { '?' }
  Write-Host "the run holding the lock started at $($started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) (pid $runPid)"
  Send-AicmAttention 'update-stuck' @("the daily update has been running for more than $($script:StuckHours) hours and blocks the next runs; if it is stuck, end it (powershell running update_ai_clis.ps1, see Task Manager) and run 'aicm update'")
}

# A real run claims (marks) the home; a dry run only checks it. A folder this tool did not create is
# refused before any log, lock or state is written into it.
try { if ($DryRun) { Assert-AicmHomeUsable } else { Confirm-AicmHome } }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
Ensure-Directory $LogDir
$logFile = Join-Path $LogDir ("update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$latestLog = Join-Path $LogDir 'latest.log'
$runningFile = Join-Path (Join-Path (Get-AicmHome) 'state') 'update-running.json'

$mutexName = Get-AicmLockName 'update'
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$hasLock = $false
$transcribing = $false
try {
  try { $hasLock = $mutex.WaitOne(0) }
  catch {
    # The previous holder died without releasing the lock: the lock is ours now.
    $ex = $_.Exception
    while ($ex -and -not ($ex -is [System.Threading.AbandonedMutexException])) { $ex = $ex.InnerException }
    if (-not $ex) { throw }
    $hasLock = $true
  }
  # No log file for runs that do nothing: a retry must not replace latest.log with one line.
  if (-not $hasLock) {
    Write-Host "[$(Get-Timestamp)] another update run is already active"
    Test-StuckRun
    exit 0
  }
  if (Read-AicmState 'attention-update-stuck') { Send-AicmAttention 'update-stuck' @() }
  if ($Scheduled -and -not $DryRun -and (Test-DoneToday)) {
    Write-Host "[$(Get-Timestamp)] already updated today; nothing to retry"
    exit 0
  }
  Write-AicmState 'update-running' ([ordered]@{ startedAt = Get-AicmTimestamp; pid = $PID })

  Start-Transcript -Path $logFile -Force | Out-Null
  $transcribing = $true
  Copy-Item -LiteralPath $logFile -Destination $latestLog -Force -ErrorAction SilentlyContinue
  try {
    $script:failures = New-Object System.Collections.Generic.List[string]
    $script:deferred = [ordered]@{}
    $script:policyHolds = @{}
    $script:targetFail = @{}
    $script:npmPending = @{}
    $script:verify = New-Object System.Collections.Generic.List[object]
    $script:updated = New-Object System.Collections.Generic.List[string]
    $script:installOkPkg = New-Object System.Collections.Generic.List[string]
    $script:installOkId = New-Object System.Collections.Generic.List[string]
    $script:pending = $false
    $script:registryOk = $null
    $script:processCache = $null
    # npm packages this run looked after, and those known from earlier runs that are still installed.
    $script:managedNpm = New-Object System.Collections.Generic.List[string]
    $script:knownNpm = [ordered]@{}
    # Upper limit for one install or self-update (env AICM_INSTALL_TIMEOUT_SECONDS, default 30 minutes).
    $script:InstallTimeoutSeconds = if ($env:AICM_INSTALL_TIMEOUT_SECONDS -match '^\d+$' -and [int]$env:AICM_INSTALL_TIMEOUT_SECONDS -gt 0) { [int]$env:AICM_INSTALL_TIMEOUT_SECONDS } else { 1800 }

    function Get-CommandPath([string]$Name) {
      if (-not $Name) { return $null }
      $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return [string]$cmd.Source }
      return $null
    }

    function Note-NpmPending([string]$Package) {
      $script:pending = $true
      if ($Package) { $script:npmPending[$Package] = 'pending' }
    }

    function Add-PolicyHold([string]$Id, [string]$Reason) {
      if ($Id -and $Reason) { $script:policyHolds[$Id] = $Reason }
    }

    function Get-PolicyHoldReason([string]$Id) {
      if ($script:policyHolds.ContainsKey($Id)) { return [string]$script:policyHolds[$Id] }
      return ''
    }

    # Prints and records a non-npm route hold. Returns $true when the route must not be touched.
    function Hold-PolicyRoute([string]$Id, [string]$Method) {
      $why = Get-AicmPolicyRouteHold $Id $Method
      if (-not $why) { return $false }
      Write-Host "hold: $why"
      Add-PolicyHold $Id $why
      return $true
    }

    function Add-TargetFailures([string]$Id, [int]$Start) {
      for ($i = $Start; $i -lt $script:failures.Count; $i++) {
        if (-not $script:targetFail.ContainsKey($Id)) {
          $script:targetFail[$Id] = New-Object System.Collections.Generic.List[string]
        }
        $script:targetFail[$Id].Add([string]$script:failures[$i]) | Out-Null
      }
    }

    function Read-VersionSnapshot([string]$Name) {
      $snap = @{ path = ''; version = ''; exitCode = $null }
      if (-not $Name) { return $snap }
      $path = Get-CommandPath $Name
      if (-not $path) { return $snap }
      $snap.path = $path
      $result = Invoke-AicmWithTimeout $Name @('--version') $VersionTimeoutSeconds
      $code = $result.ExitCode
      if ($null -eq $code) { $code = 1 }
      $snap.exitCode = [int]$code
      $line = ''
      foreach ($row in @($result.Output -split "`r?`n")) {
        $trim = ([string]$row).Trim()
        if ($trim) { $line = $trim; break }
      }
      $snap.version = $line
      return $snap
    }

    function Write-VersionSnapshot([string]$Name, $Snap) {
      if (-not $Snap.path) {
        Write-Host "${Name}: not installed"
        return
      }
      if ($Snap.exitCode -eq 124) {
        Write-Host "${Name}: TIMEOUT after ${VersionTimeoutSeconds}s"
      } elseif ($Snap.exitCode -ne 0) {
        $detail = if ($Snap.version) { ": $($Snap.version)" } else { '' }
        Write-Host "${Name}: ERROR rc=$($Snap.exitCode)$detail"
      } elseif (-not $Snap.version) {
        Write-Host "${Name}: ERROR empty version"
      } else {
        Write-Host "${Name}: $($Snap.version)"
      }
      Write-Host "  path: $($Snap.path)"
    }

    function Get-JsonString([string]$Text) {
      if ($null -eq $Text) { $Text = '' }
      return (ConvertTo-Json -InputObject $Text -Compress)
    }

    function Get-JsonNumber($Value) {
      if ($null -eq $Value) { return 'null' }
      return ([int]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    # Selected catalog rows only. Commandless rows are unsupported, not failures.
    function Initialize-VerifyRows {
      $script:verify = New-Object System.Collections.Generic.List[object]
      foreach ($entry in @(Read-AicmCatalog)) {
        $selected = $false
        if ($entry.Id -eq 'codex') { $selected = Test-GptTargetEnabled } else { $selected = Test-TargetEnabled $entry.Id }
        if (-not $selected) { continue }
        $script:verify.Add(@{
          id = [string]$entry.Id
          command = [string]$entry.Command
          entry = $entry
          excluded = [bool](Test-AicmPolicyExcluded $entry.Id)
          before = @{ path = ''; version = ''; exitCode = $null }
          after = @{ path = ''; version = ''; exitCode = $null }
          status = ''
          reason = ''
        })
      }
    }

    function Capture-VerifySide([string]$Side) {
      foreach ($row in $script:verify.ToArray()) {
        if ($row.excluded) {
          Write-Host "$($row.id): excluded by update policy; version is not checked"
          continue
        }
        if (-not $row.command) {
          Write-Host "$($row.id): no command; version is not checked"
          continue
        }
        $snap = Read-VersionSnapshot $row.command
        Write-VersionSnapshot $row.command $snap
        $row[$Side] = $snap
      }
    }

    function Get-TargetFailReason([string]$Id) {
      if (-not $script:targetFail.ContainsKey($Id)) { return '' }
      return (($script:targetFail[$Id] | ForEach-Object { [string]$_ }) -join '; ')
    }

    function Get-TargetDeferReason($Entry) {
      foreach ($n in @(Get-AicmNpmNames $Entry)) {
        if ($script:deferred.Contains($n)) { return [string]$script:deferred[$n] }
      }
      foreach ($n in @(Get-AicmNpmNames $Entry)) {
        if ($script:npmPending.ContainsKey($n)) { return 'pending' }
      }
      return ''
    }

    function Note-InstallPkg([string]$Package) {
      if ($Package -and -not $script:installOkPkg.Contains($Package)) { [void]$script:installOkPkg.Add($Package) }
    }

    function Note-InstallId([string]$Id) {
      if ($Id -and -not $script:installOkId.Contains($Id)) { [void]$script:installOkId.Add($Id) }
    }

    # True only after an installer command itself exits 0. A hold, a skip, or a network pending is not an install.
    function Test-CliInstallSucceeded($Entry, [string]$Id) {
      if ($script:installOkId.Contains($Id)) { return $true }
      foreach ($n in @(Get-AicmNpmNames $Entry)) {
        if ($n -and $script:installOkPkg.Contains([string]$n)) { return $true }
      }
      return $false
    }

    # At least one targeted row is healthy after, and its before probe was unhealthy or a different version.
    # A missing, empty, nonzero, or timed-out after probe never counts.
    function Test-VersionChanged {
      foreach ($row in $script:verify.ToArray()) {
        # Only a row that actually reached "updated" may fire the hook: excluded/held rows can show
        # different --version text between probes without any update.
        if ($row.status -ne 'updated') { continue }
        $before = $row.before
        $after = $row.after
        if ($after.exitCode -ne 0 -or -not $after.version) { continue }
        if ($before.exitCode -ne 0 -or -not $before.version -or $before.version -ne $after.version) { return $true }
      }
      return $false
    }

    # Record verify failures before state is written. A bad before probe is ignored when after is healthy.
    function Complete-UpdateResults {
      foreach ($row in $script:verify.ToArray()) {
        $beforePresent = [bool]$row.before.path
        $afterPresent = [bool]$row.after.path
        $beforeOk = ($row.before.exitCode -eq 0 -and $row.before.version)
        $afterOk = ($row.after.exitCode -eq 0 -and $row.after.version)
        if ($row.excluded) {
          $row.status = 'skipped'
          $row.reason = 'update policy excludes this CLI'
          continue
        }
        if ($beforePresent -and -not $afterPresent) {
          $row.status = 'verifyFailed'
          $row.reason = 'command missing after update'
          $script:failures.Add("$($row.command) missing after update") | Out-Null
          continue
        }
        if ($afterPresent -and -not $afterOk) {
          $row.status = 'verifyFailed'
          if ($row.after.exitCode -eq 124) {
            $row.reason = 'version timed out'
            $script:failures.Add("$($row.command) version timeout") | Out-Null
          } elseif ($null -ne $row.after.exitCode -and $row.after.exitCode -ne 0) {
            $row.reason = 'version failed'
            $script:failures.Add("$($row.command) version rc=$($row.after.exitCode)") | Out-Null
          } else {
            $row.reason = 'empty version'
            $script:failures.Add("$($row.command) version empty") | Out-Null
          }
          continue
        }
        $failReason = Get-TargetFailReason $row.id
        if ($failReason) {
          $row.status = 'updateFailed'
          $row.reason = $failReason
          continue
        }
        if (-not $row.command) {
          $row.status = 'unsupported'
          $row.reason = 'unsupported verification'
          continue
        }
        $holdReason = Get-PolicyHoldReason $row.id
        if ($holdReason) {
          $row.status = 'skipped'
          $row.reason = $holdReason
          continue
        }
        $deferReason = Get-TargetDeferReason $row.entry
        if ($deferReason) {
          $row.status = 'deferred'
          $row.reason = $deferReason
          continue
        }
        if (-not $beforePresent -and -not $afterPresent) {
          if (Test-CliInstallSucceeded $row.entry $row.id) {
            $row.status = 'verifyFailed'
            $row.reason = 'command missing after update'
            $script:failures.Add("$(if ($row.command) { $row.command } else { $row.id }) missing after update") | Out-Null
            continue
          }
          $row.status = 'skipped'
          $row.reason = 'not installed'
          continue
        }
        if ($beforeOk -and $afterOk -and $row.before.version -eq $row.after.version) {
          $row.status = 'unchanged'
          $row.reason = ''
        } else {
          $row.status = 'updated'
          $row.reason = ''
        }
      }
    }

    function Get-ResultsJson {
      $parts = New-Object System.Collections.Generic.List[string]
      foreach ($row in $script:verify.ToArray()) {
        $b = $row.before
        $a = $row.after
        $parts.Add(('{"id":' + (Get-JsonString $row.id) + ',"command":' + (Get-JsonString $row.command) + ',"before":{"path":' + (Get-JsonString $b.path) + ',"version":' + (Get-JsonString $b.version) + ',"exitCode":' + (Get-JsonNumber $b.exitCode) + '},"after":{"path":' + (Get-JsonString $a.path) + ',"version":' + (Get-JsonString $a.version) + ',"exitCode":' + (Get-JsonNumber $a.exitCode) + '},"status":' + (Get-JsonString $row.status) + ',"reason":' + (Get-JsonString $row.reason) + '}'))
      }
      if ($parts.Count -eq 0) { return '[]' }
      return '[' + ($parts -join ',') + ']'
    }

    # Effective policy and the holds every route would take, printed outside Invoke-Step so dry-run
    # shows the same reasons.
    function Write-PolicyReport {
      if (-not $script:AicmPolicyPresent) { return }
      Write-Host ''
      Write-Host '== update policy =='
      Write-Host "file: $(Join-Path (Get-AicmHome) 'update-policy.json')"
      Write-Host "fingerprint: $(Get-AicmPolicyFingerprint)"
      Write-Host "global_min_release_age_days: $MinReleaseAgeDays"
      foreach ($id in @($script:AicmPolicyTools.Keys | Sort-Object)) {
        $rule = $script:AicmPolicyTools[$id]
        if ($rule.Exclude) {
          Write-Host "${id}: excluded by update policy"
        } else {
          $pin = if ($rule.Pin) { $rule.Pin } else { '-' }
          $explicit = if ($rule.ExplicitAge -ge 0) { $rule.ExplicitAge } else { '-' }
          Write-Host "${id}: pin=$pin minReleaseAgeDays=$explicit effectiveMinReleaseAgeDays=$($rule.EffectiveAge)"
        }
      }
      foreach ($entry in @(Read-AicmCatalog)) {
        $selected = if ($entry.Id -eq 'codex') { Test-GptTargetEnabled } else { Test-TargetEnabled $entry.Id }
        if (-not $selected -or (Test-AicmPolicyExcluded $entry.Id)) { continue }
        $pin = Get-AicmPolicyPin $entry.Id
        $age = Get-AicmPolicyExplicitAge $entry.Id
        if (-not $pin -and $age -le 0) { continue }
        $install = Get-AicmCliInstall $entry
        if (-not $install.Installed) { continue }
        $why = Get-AicmPolicyRouteHold $entry.Id $install.Method
        if ($why) { Write-Host "hold: $why"; continue }
        if ($pin -and $install.Method -eq 'npm' -and $install.NpmPackage) {
          $installed = Get-NpmInstalledVersion $install.NpmPackage
          if ($installed -and $installed -ne $pin -and (Compare-AicmVersion $installed $pin) -gt 0) {
            Write-Host "hold: installed $($install.NpmPackage) $installed is newer than the pinned version $pin; no automatic downgrade"
          }
        }
      }
    }

    function Write-LastUpdate($Fields) {
      $json = $Fields | ConvertTo-Json -Depth 6
      $trim = $json.TrimEnd()
      if (-not $trim.EndsWith('}')) { throw 'update state JSON was not an object' }
      $trim = $trim.Substring(0, $trim.Length - 1).TrimEnd().TrimEnd(',')
      $trim += ",`r`n    `"results`": $(Get-ResultsJson)`r`n}"
      $dir = Join-Path (Get-AicmHome) 'state'
      Initialize-AicmDirectory $dir
      $file = Join-Path $dir 'last-update.json'
      $tmp = "$file.$PID.tmp"
      Set-Content -LiteralPath $tmp -Value $trim -Encoding UTF8
      if (Test-Path -LiteralPath $file) { [System.IO.File]::Replace($tmp, $file, [NullString]::Value) }
      else { [System.IO.File]::Move($tmp, $file) }
    }

    # After last-update.json is on disk. Stdout is discarded. A history failure is a warning only.
    function Add-UpdateHistory {
      if (-not (Resolve-AicmExecutable 'node')) { return }
      $js = Join-Path (Get-AicmRoot) 'lib\maintenance.js'
      if (-not (Test-Path -LiteralPath $js -PathType Leaf)) { return }
      $file = Join-Path (Join-Path (Get-AicmHome) 'state') 'last-update.json'
      $result = Invoke-AicmWithTimeout 'node' @($js, 'history-add', '--kind', 'update', '--file', $file) 60
      if ($result.ExitCode -ne 0) {
        $detail = ([string]$result.StdErr).Trim()
        if (-not $detail) { $detail = "exit $($result.ExitCode)" }
        Write-Host "warn: update history failed: $detail"
      }
    }

    # npm is run through Invoke-AicmWithTimeout, never with '& npm ... 2>...': a warning on stderr
    # (an old .npmrc setting) would turn into a terminating error under ErrorActionPreference Stop.
    function Test-NpmGlobalPackage([string]$Package) {
      $npm = Get-CommandPath 'npm'
      if (-not $npm) { return $false }
      return ((Invoke-AicmWithTimeout 'npm' @('list', '-g', '--depth=0', $Package) 60).ExitCode -eq 0)
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
      $raw = (Invoke-AicmWithTimeout 'npm' @('list', '-g', '--depth=0', '--json', $Package) 60).StdOut
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

    # Runs the real install. --before applies the waiting period to the dependencies too; the time
    # limit keeps a postinstall that hangs on the network from holding the lock forever.
    function Invoke-NpmGlobalInstall([string]$Spec, [string[]]$Extra = @()) {
      $installArgs = @('install', '-g', $Spec) + @($Extra)
      $result = Invoke-AicmWithTimeout 'npm' $installArgs $script:InstallTimeoutSeconds
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      return $result
    }

    function Update-NpmPackage([string]$Package, [string]$Pin = '', [int]$Age = -1, [string]$Id = '') {
      # A hold recorded earlier in this run (for example an interrupted install kept for manual
      # repair) must not be bypassed by the normal npm update path.
      if ($Id) {
        $existingHold = Get-PolicyHoldReason $Id
        if ($existingHold) { Write-Host "hold: $existingHold"; return }
      }
      if (-not (Get-CommandPath 'npm')) { throw 'npm is not installed' }
      if ($Age -lt 0) { $Age = $MinReleaseAgeDays }
      $isAmp = @('@ampcode/cli', '@sourcegraph/amp') -contains $Package
      if (-not (Test-NpmRegistry)) { Note-NpmPending $Package; return }
      if (-not $script:managedNpm.Contains($Package)) { $script:managedNpm.Add($Package) }
      $installed = Get-NpmInstalledVersion $Package
      if ($Pin) {
        if ($installed -eq $Pin) {
          Write-Host "already at the pinned version: $Package $installed"
          return
        }
        if ($installed) {
          # Two Amp commit builds with the same timestamp have no trustworthy order.
          $installedBase = if ($installed -match '^(0\.0\.\d{10})-g') { $Matches[1] } else { '' }
          $pinBase = if ($Pin -match '^(0\.0\.\d{10})-g') { $Matches[1] } else { '' }
          if ($isAmp -and $installedBase -and $installedBase -eq $pinBase) {
            $why = "cannot order installed $Package $installed against the pinned Amp build $Pin (same timestamp); nothing was installed"
            Write-Host "hold: $why"
            Add-PolicyHold $Id "update policy: $why"
            return
          }
          $cmp = Compare-AicmVersion $installed $Pin
          if ($cmp -gt 0) {
            $why = "installed $Package $installed is newer than the pinned version $Pin; no automatic downgrade"
            Write-Host "hold: $why"
            Add-PolicyHold $Id "update policy: $why"
            return
          }
          if ($cmp -eq 0) {
            $why = "cannot order installed $Package $installed against the pinned version $Pin; no downgrade or upgrade was attempted"
            Write-Host "hold: $why"
            Add-PolicyHold $Id "update policy: $why"
            return
          }
        }
        $why = Test-AicmPolicyPinRelease $Package $Pin $Age -Amp:$isAmp
        if ($why) {
          Write-Host "hold: $why"
          Add-PolicyHold $Id "update policy: $why"
          return
        }
        Write-Host "candidate: $Package $installed -> $Pin (pinned)"
        Test-AicmNpmRelease $Package $installed $Pin $Age
        $result = Invoke-NpmGlobalInstall "$Package@$Pin" @(Get-AicmNpmBeforeArgs $Age)
        if ($result.ExitCode -eq 124) { throw "npm install for $Package did not finish within $($script:InstallTimeoutSeconds)s and was stopped" }
        if ($result.ExitCode -ne 0) {
          if ($result.Output -match 'EBUSY|EPERM|resource busy|operation not permitted') { Add-Deferred $Package 'files are in use'; return }
          throw "npm install failed for $Package with exit code $($result.ExitCode)"
        }
        Note-InstallPkg $Package
        $script:updated.Add($Package)
        return
      }
      $target = Get-AicmNpmTarget $Package $Age -Installed $installed -SkipDeprecated
      if (-not $target) {
        Write-Host "hold: no release of $Package is $Age days old yet"
        if ($Id -and (Get-AicmPolicyExplicitAge $Id) -ge 0) {
          Add-PolicyHold $Id "update policy: no release of $Package is $Age days old yet"
        }
        return
      }
      # Skip the reinstall when already current: reinstalling a CLI that is running fails on Windows (EBUSY).
      if ($installed -and (Compare-AicmVersion $installed $target) -ge 0) {
        Write-Host "already current: $Package $installed (newest release at least $Age days old: $target)"
        return
      }
      Write-Host "candidate: $Package $installed -> $target"
      $users = @(Get-NpmPackageUsers $Package)
      if ($users.Count -gt 0) {
        Add-Deferred $Package "is running ($($users.Count) processes, e.g. $($users[0].Name) pid $($users[0].ProcessId))"
        return
      }
      Test-AicmNpmRelease $Package $installed $target $Age
      $result = Invoke-NpmGlobalInstall "$Package@$target" @(Get-AicmNpmBeforeArgs $Age)
      if ($result.ExitCode -eq 124) { throw "npm install for $Package did not finish within $($script:InstallTimeoutSeconds)s and was stopped" }
      if ($result.ExitCode -ne 0) {
        # A file still held by a process that started meanwhile: try again later instead of failing.
        if ($result.Output -match 'EBUSY|EPERM|resource busy|operation not permitted') { Add-Deferred $Package 'files are in use'; return }
        throw "npm install failed for $Package with exit code $($result.ExitCode)"
      }
      Note-InstallPkg $Package
      $script:updated.Add($Package)
    }

    # npm CLIs this updater managed before (state update-npm: package -> version). One that is gone now
    # was either removed on purpose or lost to an interrupted install (npm moved it to a backup folder
    # .<name>-XXXXXXXX and never finished). With such a backup it is reinstalled at the same version;
    # otherwise it is reported once and forgotten, so an intentional uninstall is not fought daily.
    function Restore-MissingNpmPackages {
      $prev = Read-AicmState 'update-npm'
      if (-not $prev -or -not (Get-CommandPath 'npm')) { return }
      $info = Get-AicmNpmInfo
      foreach ($p in @($prev.PSObject.Properties)) {
        $pkg = $p.Name; $version = [string]$p.Value
        $entry = @(Read-AicmCatalog | Where-Object { (Get-AicmNpmNames $_) -contains $pkg }) | Select-Object -First 1
        if ($entry) {
          $active = Get-AicmCliInstall $entry
          if ($active.Installed -and ($active.Method -ne 'npm' -or $active.NpmPackage -ne $pkg)) {
            Write-Host "pass : unused npm copy $pkg is not restored while PATH selects $($active.Path)"
            # Keep the old entry while policy or target selection can still matter: removing the policy
            # later may need it to repair an interrupted install. With every target selected and no
            # policy rule the entry is dropped, so an intentionally removed hidden package is not revived.
            $heldAge = Get-AicmPolicyExplicitAge $entry.Id
            $ownerSelected = if ($entry.Id -eq 'codex') { Test-GptTargetEnabled } else { Test-TargetEnabled $entry.Id }
            if ((Test-AicmPolicyExcluded $entry.Id) -or (Get-AicmPolicyPin $entry.Id) -or $heldAge -ge 0 -or -not $ownerSelected) {
              $script:knownNpm[$pkg] = $version
            }
            continue
          }
        }
        if ($info.Packages.ContainsKey($pkg)) { $script:knownNpm[$pkg] = $version; continue }
        # Recovery follows target selection and policy. A skipped package keeps its old entry so
        # removing the policy later can still repair an interrupted install.
        $ownerId = if ($entry) { [string]$entry.Id } else { '' }
        if ($ownerId) {
          $selected = if ($ownerId -eq 'codex') { Test-GptTargetEnabled } else { Test-TargetEnabled $ownerId }
          if (-not $selected) {
            Write-Host "pass : $pkg is not restored because $ownerId is not selected for this run"
            $script:knownNpm[$pkg] = $version
            continue
          }
          if (Test-AicmPolicyExcluded $ownerId) {
            Write-Host "pass : $pkg is not restored because update policy excludes $ownerId"
            $script:knownNpm[$pkg] = $version
            continue
          }
          $pin = Get-AicmPolicyPin $ownerId
          if ($pin) {
            # Conservative hold: an interrupted install under a configured pin cannot rerun the full
            # release/security guards safely, and the inherited global age must still apply. Keep the
            # backup and state so a manual install can repair it; never reinstall unchecked.
            if ($version -eq $pin) {
              $why = "update policy pins $ownerId to $pin; automatic recovery is held to keep the release guards, so restore it manually with: npm install -g $pkg@$pin"
            } else {
              $why = "update policy pins $ownerId to $pin, so the interrupted $pkg $version install is not restored"
            }
            Write-Host "hold: $why"
            Add-PolicyHold $ownerId $why
            $script:knownNpm[$pkg] = $version
            continue
          }
          $age = Get-AicmPolicyExplicitAge $ownerId
          if ($age -gt 0) {
            $isAmp = @('@ampcode/cli', '@sourcegraph/amp') -contains $pkg
            try { $why = Test-AicmPolicyPinRelease $pkg $version $age -Amp:$isAmp }
            catch { $why = "could not check the release age of $pkg $version" }
            if ($why) {
              Write-Host "hold: update policy: $why; the interrupted $pkg install is not restored"
              Add-PolicyHold $ownerId "update policy: $why"
              $script:knownNpm[$pkg] = $version
              continue
            }
          }
        } elseif ((Get-RunTargets) -ne 'all') {
          Write-Host "pass : $pkg is not restored because it is not selected for this run"
          $script:knownNpm[$pkg] = $version
          continue
        }
        $backup = Get-AicmNpmBackup $pkg
        Write-Host ""
        Write-Host "== missing npm CLI: $pkg =="
        if (-not $backup) {
          Write-Host "fail: $pkg ($version) was installed at the last update and is gone now"
          $script:failures.Add("$pkg disappeared since the last update; reinstall it with 'npm install -g $pkg@$version', or ignore this if you removed it") | Out-Null
          continue
        }
        Write-Host "found npm's backup of an interrupted install: $backup"
        if (-not (Test-NpmRegistry)) { $script:knownNpm[$pkg] = $version; Note-NpmPending $pkg; continue }
        $result = Invoke-NpmGlobalInstall "$pkg@$version"
        if ($result.ExitCode -eq 0) {
          Write-Host "restored: $pkg $version"
          $script:knownNpm[$pkg] = $version
          Note-InstallPkg $pkg
          $script:updated.Add($pkg)
        } else {
          $script:knownNpm[$pkg] = $version
          $script:failures.Add("$pkg was lost by an interrupted install and could not be reinstalled; run 'npm install -g $pkg@$version'") | Out-Null
        }
      }
      $script:AicmNpmInfo = $null
    }

    function Install-NpmPackage([string]$Package, [string]$Pin = '', [int]$Age = -1, [string]$Id = '') {
      Update-NpmPackage $Package $Pin $Age $Id
    }

    function Update-AgyCli {
      if (-not (Get-CommandPath 'agy')) { throw 'agy is not installed' }
      $result = Invoke-AicmWithTimeout 'agy' @('update') 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "agy update failed with exit code $($result.ExitCode)" }
    }

    function Update-KimiCli {
      $pin = Get-AicmPolicyPin 'kimi'
      $age = Get-AicmPolicyEffectiveAge 'kimi' $MinReleaseAgeDays
      $inst = Get-ActiveInstall 'kimi'
      if ($inst -and $inst.Installed -and $inst.Method -ne 'npm') {
        if (Hold-PolicyRoute 'kimi' $inst.Method) { return }
        Write-Host 'pass : standalone Kimi is not updated; hidden npm copies are skipped'
        Write-ShadowWarning 'kimi'
        return
      }
      if (Test-NpmGlobalPackage '@moonshot-ai/kimi-code') {
        Update-NpmPackage '@moonshot-ai/kimi-code' $pin $age 'kimi'
      } elseif (Get-CommandPath 'kimi') {
        if (Hold-PolicyRoute 'kimi' 'standalone') { return }
        Write-Host 'kimi command exists but is not npm-managed; skipping unattended update'
        Write-Host '      reinstall/update with npm for automation: npm install -g @moonshot-ai/kimi-code@latest'
      } elseif ($InstallMissing) {
        Install-NpmPackage '@moonshot-ai/kimi-code' $pin $age 'kimi'
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
      $pin = Get-AicmPolicyPin 'claude'
      $age = Get-AicmPolicyEffectiveAge 'claude' $MinReleaseAgeDays
      $inst = Get-ActiveInstall 'claude'
      if ($inst -and $inst.Installed -and $inst.Method -ne 'npm') {
        if (Hold-PolicyRoute 'claude' $inst.Method) { return }
        Invoke-ActiveSelfUpdate $inst @('update')
        Write-ShadowWarning 'claude'
      } elseif (Test-NpmGlobalPackage '@anthropic-ai/claude-code') {
        Update-NpmPackage '@anthropic-ai/claude-code' $pin $age 'claude'
      } elseif (Get-CommandPath 'claude') {
        if (Hold-PolicyRoute 'claude' 'vendor') { return }
        $result = Invoke-AicmWithTimeout 'claude' @('update') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "claude update failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage '@anthropic-ai/claude-code' $pin $age 'claude'
      } else {
        Pass-Missing 'claude' 'command not found and npm global package not installed'
      }
    }

    function Update-OpenCodeCli {
      $pin = Get-AicmPolicyPin 'opencode'
      $age = Get-AicmPolicyEffectiveAge 'opencode' $MinReleaseAgeDays
      $inst = Get-ActiveInstall 'opencode'
      if ($inst -and $inst.Installed -and $inst.Method -ne 'npm') {
        if (Hold-PolicyRoute 'opencode' $inst.Method) { return }
        Invoke-ActiveSelfUpdate $inst @('upgrade')
        Write-ShadowWarning 'opencode'
      } elseif ($inst -and $inst.Installed -and $inst.Method -eq 'npm') {
        Update-NpmPackage $inst.NpmPackage $pin $age 'opencode'
      } elseif (Get-CommandPath 'opencode') {
        if (Hold-PolicyRoute 'opencode' 'vendor') { return }
        $result = Invoke-AicmWithTimeout 'opencode' @('upgrade') 300
        if ($result.Output) { Write-Host $result.Output.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "opencode upgrade failed with exit code $($result.ExitCode)" }
      } elseif ($InstallMissing) {
        Install-NpmPackage '@opencode/cli' $pin $age 'opencode'
      } else {
        Pass-Missing 'opencode' 'command not found and npm global package not installed'
      }
    }

    # Limitation: the vendor updaters (claude update, opencode upgrade, agy update, winget, catalog
    # self-updates) and the Grok installer install whatever their vendor serves; the npm waiting period
    # and release checks cannot be applied to them. Only the Grok installer is gated (see Update-GrokCli).
    function Install-OrUpdate-GrokCli {
      $result = Invoke-AicmWithTimeout 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://x.ai/cli/install.ps1 | iex') 300
      if ($result.Output) { Write-Host $result.Output.TrimEnd() }
      if ($result.ExitCode -ne 0) { throw "grok installer failed with exit code $($result.ExitCode)" }
      Note-InstallId 'grok'
    }

    function Update-GrokCli {
      $pin = Get-AicmPolicyPin 'grok'
      $age = Get-AicmPolicyEffectiveAge 'grok' $MinReleaseAgeDays
      # The common owner detector decides the route, exactly like the other CLIs: an npm launcher gets
      # the npm pin/age checks, while a standalone copy stays on the gated vendor installer even when a
      # hidden npm package exists under the same prefix.
      $inst = Get-ActiveInstall 'grok'
      if ($inst -and $inst.Installed -and $inst.Method -eq 'npm' -and $inst.NpmPackage -and (Test-NpmGlobalPackage $inst.NpmPackage)) {
        Update-NpmPackage $inst.NpmPackage $pin $age 'grok'
      } elseif ($inst -and $inst.Installed) {
        if (Hold-PolicyRoute 'grok' 'vendor') { return }
        # The vendor installer is a remote script that always installs the newest release. Run it only
        # when the installed version is known, a newer release exists, and that newest release is itself
        # past the waiting period. The npm package carries the same version numbers and publish dates.
        $have = Get-AicmSemver (Invoke-AicmWithTimeout $inst.Path @('--version') 15).Output
        if (-not $have) {
          Write-Host 'skip: cannot read the installed grok version, so the installer is not run unattended; update it by hand'
          return
        }
        if (-not (Get-CommandPath 'npm')) {
          Write-Host 'skip: npm is needed to look up Grok release dates; the installer is not run unattended. Update grok by hand'
          return
        }
        if (-not (Test-NpmRegistry)) { Note-NpmPending '@xai-official/grok'; return }
        $want = Get-AicmNpmTarget '@xai-official/grok' $age
        if (-not $want -or (Compare-AicmVersion $have $want) -ge 0) {
          Write-Host "already current: grok $have (newest release at least $age days old: $want)"
          return
        }
        if ($age -gt 0) {
          $newest = Get-AicmSemver (Invoke-AicmWithTimeout 'npm' @('view', '@xai-official/grok', 'version') 60).StdOut
          if ($newest -and $newest -ne $want) {
            Write-Host "hold: grok $want is old enough, but the installer would install $newest, which is still in its $age-day waiting period"
            return
          }
        }
        Install-OrUpdate-GrokCli
        Write-ShadowWarning 'grok'
      } elseif ($InstallMissing) {
        if (Hold-PolicyRoute 'grok' 'vendor') { return }
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
      if (Test-AicmPolicyExcluded $entry.Id) { continue }
      $install = Get-AicmCliInstall $entry
      if ($install.Installed -or ($InstallMissing -and $entry.Npm -and (Test-TargetNamed $entry.Id))) {
        $catalogExtras.Add([pscustomobject]@{ Entry = $entry; Install = $install })
      }
    }

    Write-Host "[$(Get-Timestamp)] AI CLI update started"
    Write-Host "host=$env:COMPUTERNAME user=$env:USERNAME dry_run=$DryRun targets=$(($Targets -join ',')) install_missing=$InstallMissing min_release_age_days=$MinReleaseAgeDays"
    Remove-OldLogs $LogDir $LogRetentionDays
    # npm lists global packages but its prefix is not a readable folder: npm-owned and other copies
    # cannot be told apart, so no CLI is updated or restored (an update through the wrong owner would
    # install a second copy or skip the one in use).
    $npmPrefixProblem = (Get-AicmNpmInfo).PrefixProblem
    if ($npmPrefixProblem) {
      Write-Host "error: $npmPrefixProblem. Install owners cannot be told apart, so no CLI is updated this run; check: npm prefix -g"
      $script:failures.Add('npm global prefix unreadable')
    }
    if (-not $DryRun -and -not $npmPrefixProblem) { Restore-MissingNpmPackages }

    Initialize-VerifyRows
    Write-PolicyReport
    Write-Host ""
    Write-Host "== before versions =="
    Capture-VerifySide 'before'

    if (-not $npmPrefixProblem -and (Test-GptTargetEnabled)) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'codex') {
        Write-Host 'skip: codex excluded by update policy'
      } else {
        $codexPin = Get-AicmPolicyPin 'codex'
        $codexAge = Get-AicmPolicyEffectiveAge 'codex' $MinReleaseAgeDays
        $codexInstall = Get-ActiveInstall 'codex'
        if ($codexInstall -and $codexInstall.Installed -and $codexInstall.Method -ne 'npm') {
          if (-not (Hold-PolicyRoute 'codex' $codexInstall.Method)) {
            Pass-Missing 'gpt' 'update the PATH copy with its owning app or installer; hidden npm copies are skipped'
          }
        } elseif (Test-NpmGlobalPackage '@openai/codex') {
          Invoke-Step 'gpt/codex via npm' { Update-NpmPackage '@openai/codex' $codexPin $codexAge 'codex' }
        } elseif (-not (Get-CommandPath 'codex') -and $InstallMissing) {
          Invoke-Step 'gpt/codex via npm install' { Install-NpmPackage '@openai/codex' $codexPin $codexAge 'codex' }
        } elseif (-not (Get-CommandPath 'codex')) {
          Pass-Missing 'gpt' 'codex command not found and npm global package not installed'
        } else {
          Pass-Missing 'gpt' 'codex command exists but no supported Windows package manager was detected'
        }
        # The Codex desktop app puts its own copy on PATH and updates it itself; say so when npm's copy is hidden.
        Write-ShadowWarning 'codex'
      }
      Add-TargetFailures 'codex' $failStart
    }

    if (-not $npmPrefixProblem -and (Test-TargetEnabled 'opencode')) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'opencode') { Write-Host 'skip: opencode excluded by update policy' }
      else { Invoke-Step 'opencode' { Update-OpenCodeCli } }
      Add-TargetFailures 'opencode' $failStart
    }

    if (-not $npmPrefixProblem -and (Test-TargetEnabled 'agy')) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'agy') {
        Write-Host 'skip: agy excluded by update policy'
      } elseif (Get-CommandPath 'agy') {
        if (-not (Hold-PolicyRoute 'agy' 'standalone')) { Invoke-Step 'antigravity cli via agy' { Update-AgyCli } }
      } else {
        Pass-Missing 'agy' 'command not found'
      }
      Add-TargetFailures 'agy' $failStart
    }

    if (-not $npmPrefixProblem -and (Test-TargetEnabled 'kimi')) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'kimi') { Write-Host 'skip: kimi excluded by update policy' }
      else { Invoke-Step 'kimi code via npm' { Update-KimiCli } }
      Add-TargetFailures 'kimi' $failStart
    }

    if (-not $npmPrefixProblem -and (Test-TargetEnabled 'claude')) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'claude') { Write-Host 'skip: claude excluded by update policy' }
      else { Invoke-Step 'claude code' { Update-ClaudeCli } }
      Add-TargetFailures 'claude' $failStart
    }

    if (-not $npmPrefixProblem -and (Test-TargetEnabled 'grok')) {
      $failStart = $script:failures.Count
      if (Test-AicmPolicyExcluded 'grok') { Write-Host 'skip: grok excluded by update policy' }
      else { Invoke-Step 'grok build' { Update-GrokCli } }
      Add-TargetFailures 'grok' $failStart
    }

    foreach ($x in $(if ($npmPrefixProblem) { @() } else { $catalogExtras })) {
      $failStart = $script:failures.Count
      $e = $x.Entry
      $pin = Get-AicmPolicyPin $e.Id
      $age = Get-AicmPolicyEffectiveAge $e.Id $MinReleaseAgeDays
      if (-not $x.Install.Installed) {
        Invoke-Step "$($e.Name) via npm install" { Install-NpmPackage $e.Npm $pin $age $e.Id }
        Add-TargetFailures $e.Id $failStart
        continue
      }
      switch ($x.Install.Method) {
        'npm' { $pkg = $(if ($x.Install.NpmPackage) { $x.Install.NpmPackage } else { $e.Npm }); Invoke-Step "$($e.Name) via npm" { Update-NpmPackage $pkg $pin $age $e.Id } }
        'winget' {
          if (Hold-PolicyRoute $e.Id 'winget') { }
          elseif ($e.Winget) { Invoke-Step "$($e.Name) via winget" { Update-WingetPackage $e.Winget } }
          else { Pass-Missing $e.Id 'installed with winget but the catalog has no winget id' }
        }
        default {
          if (Hold-PolicyRoute $e.Id 'standalone') { }
          elseif ($e.SelfUpdate -and $e.SelfUpdate -ne '@installer') { Invoke-Step "$($e.Name) self-update" { Invoke-SelfUpdate $e } }
          else { Write-Host ""; Write-Host "pass: $($e.Name) is installed standalone without a self-update command; update it manually" }
        }
      }
      Add-TargetFailures $e.Id $failStart
    }

    $env:PATH = $env:PATH
    Write-Host ""
    Write-Host "== after versions =="
    Capture-VerifySide 'after'
    Complete-UpdateResults

    # Optional user hook. A missing or broken after probe never runs it.
    $hook = Join-Path (Get-AicmHome) 'hooks\post-update.ps1'
    $versionsChanged = Test-VersionChanged
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

    $problems = @(Get-AicmScheduleProblems -Skip 'Update') + $procAttention + $script:AicmNpmNotes.ToArray()
    foreach ($p in $problems) { Write-Host "problem: $p" }
    if (-not $DryRun) {
      # Remember since when each package has been deferred; remind when it stays stuck for 5+ days.
      # The reminder text has no day count: it must stay the same from day to day, or it would be
      # announced again every day (attention items are matched by their text).
      $prevDeferred = Read-AicmState 'update-deferred'
      $since = [ordered]@{}
      foreach ($k in @($script:deferred.Keys)) {
        $first = (Get-Date).ToUniversalTime()
        if ($prevDeferred -and $prevDeferred.PSObject.Properties[$k]) {
          $prevFirst = ConvertTo-AicmDate $prevDeferred.PSObject.Properties[$k].Value
          if ($prevFirst) { $first = $prevFirst.ToUniversalTime() }
        }
        $since[$k] = $first.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        if (((Get-Date).ToUniversalTime() - $first).TotalDays -ge 5) { $problems += "$k has not been updated for more than 5 days because it is always running; close its sessions for a moment or run 'aicm update' when it is idle" }
      }
      Write-AicmState 'update-deferred' $since
      # npm CLIs looked after: the next run reports one that disappears (see Restore-MissingNpmPackages).
      $script:AicmNpmInfo = $null
      $npmNow = (Get-AicmNpmInfo).Packages
      $npmState = [ordered]@{}
      foreach ($k in @($script:knownNpm.Keys)) { $npmState[$k] = $script:knownNpm[$k] }
      foreach ($k in $script:managedNpm) { if ($npmNow.ContainsKey($k)) { $npmState[$k] = $npmNow[$k] } }
      Write-AicmState 'update-npm' $npmState
      Remove-AicmNpmLeftovers
      Update-AicmAppCopy
      Write-LastUpdate ([ordered]@{
        finishedAt = Get-AicmTimestamp
        localDate = Get-AicmToday
        targets = Get-RunTargets
        policyFingerprint = Get-AicmPolicyFingerprint
        version = Get-AicmVersion
        ok = ($script:failures.Count -eq 0)
        pending = ($script:pending -or $script:deferred.Count -gt 0)
        deferred = @($script:deferred.Keys)
        failures = $script:failures.ToArray()
        logFile = $logFile
      })
      Add-UpdateHistory
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
    if ($transcribing) {
      Stop-Transcript | Out-Null
      Copy-Item -LiteralPath $logFile -Destination $latestLog -Force -ErrorAction SilentlyContinue
    }
  }
} finally {
  if ($hasLock) {
    Remove-Item -LiteralPath $runningFile -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex() | Out-Null
  }
  $mutex.Dispose()
}
