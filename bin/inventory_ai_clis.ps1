<#
.SYNOPSIS
  Lists the AI coding CLIs installed on this Windows machine (weekly job of AI CLI Auto Manager).
.DESCRIPTION
  Looks for every CLI in rules\ai-clis.conf (plus ~/.ai-cli-auto-manager/ai-clis.local.conf) and reports
  its version, the latest published version, how it was installed, whether the daily update keeps it
  current, and stale npm copies hidden behind another copy on PATH.
  Writes ~/.ai-cli-auto-manager/inventory.md and state\inventory.json, and raises a desktop notification
  when a CLI appeared or disappeared since the last run.
.EXAMPLE
  .\bin\inventory_ai_clis.ps1
.EXAMPLE
  .\bin\inventory_ai_clis.ps1 -Offline
#>
[CmdletBinding()]
param(
  [switch]$Offline,
  [string]$CatalogFile = '',
  [string]$LocalCatalogFile = '',
  [string]$LogDir = '',
  [int]$LogRetentionDays = $(if ($env:LOG_RETENTION_DAYS) { [int]$env:LOG_RETENTION_DAYS } else { 30 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\aicm-common.ps1')

if (-not $LogDir) { $LogDir = Join-Path (Get-AicmHome) 'logs' }
Initialize-AicmDirectory $LogDir
$transcript = Join-Path $LogDir ("inventory-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $transcript -Force | Out-Null

$exitCode = 0
try {
  Write-Host "[$(Get-AicmTimestamp)] AI CLI inventory started (version=$(Get-AicmVersion), offline=$Offline)"
  $catalog = @(Read-AicmCatalog $CatalogFile $LocalCatalogFile)
  $npm = Get-AicmNpmInfo
  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($entry in $catalog) {
    $install = Get-AicmCliInstall $entry
    if (-not $install.Installed) { continue }
    $version = ''
    if ($install.Method -eq 'winget' -and -not $entry.Command) {
      $version = Get-AicmWingetVersion $entry.Winget
    } elseif ($install.Path -and (Test-Path -LiteralPath $install.Path)) {
      try {
        $r = Invoke-AicmWithTimeout $install.Path @('--version') 15
        if ($r.ExitCode -eq 0) { $version = Get-AicmSemver $r.Output }
      } catch { }
    }
    if (-not $version -and $install.Method -eq 'npm' -and $npm.Packages.ContainsKey($entry.Npm)) { $version = $npm.Packages[$entry.Npm] }

    $latest = ''
    if (-not $Offline -and $entry.Npm -and $npm.Available) {
      $r = Invoke-AicmWithTimeout 'npm' @('view', $entry.Npm, 'version') 30
      if ($r.ExitCode -eq 0) { $latest = Get-AicmSemver $r.Output }
    }
    $state = if (-not $version) { 'unknown' } elseif (-not $latest) { 'installed' } elseif ((Compare-AicmVersion $version $latest) -lt 0) { 'behind' } else { 'current' }
    # A newer release that is still inside the waiting period is expected, not a problem.
    if ($state -eq 'behind' -and $install.Method -eq 'npm') {
      try {
        $target = Get-AicmNpmTarget $entry.Npm (Get-AicmMinReleaseAgeDays)
        if (-not $target -or (Compare-AicmVersion $version $target) -ge 0) { $state = 'held' }
      } catch { }
    }
    $coverage = Get-AicmUpdateCoverage $entry $install
    $rows.Add([pscustomobject][ordered]@{
      id = $entry.Id; name = $entry.Name; command = $entry.Command; method = $install.Method; version = $version
      latest = $latest; state = $state; autoUpdate = $coverage; npmCopy = $install.NpmCopy; path = $install.Path
    })
  }

  $known = @{}
  foreach ($entry in $catalog) { if ($entry.Npm) { $known[$entry.Npm] = $true } }
  $otherNpm = @($npm.Packages.Keys | Where-Object { -not $known.ContainsKey($_) -and @('npm', 'corepack', 'pnpm', 'yarn') -notcontains $_ } | Sort-Object | ForEach-Object { "$_ $($npm.Packages[$_])" })

  Write-Host ''
  Write-Host ("{0,-20} {1,-11} {2,-14} {3,-14} {4,-9} {5}" -f 'CLI', 'via', 'version', 'latest', 'state', 'daily update')
  foreach ($row in $rows) {
    Write-Host ("{0,-20} {1,-11} {2,-14} {3,-14} {4,-9} {5}" -f $row.name, $row.method, $row.version, $row.latest, $row.state, $row.autoUpdate)
    if ($row.npmCopy) { Write-Host ("{0,-20} npm copy {1} is also installed, but PATH runs {2}" -f '', $row.npmCopy, $row.path) }
  }
  Write-Host ''
  Write-Host "$($rows.Count) AI CLIs installed (catalog has $($catalog.Count))"
  if ($otherNpm.Count -gt 0) { Write-Host "other global npm packages: $($otherNpm -join ', ')" }

  # Compare with the previous inventory.
  $previous = Read-AicmState 'inventory'
  $changes = New-Object System.Collections.Generic.List[string]
  if ($previous) {
    $before = @{}
    foreach ($p in @($previous.clis)) { $before[[string]$p.id] = $p }
    foreach ($row in $rows) {
      if (-not $before.ContainsKey($row.id)) { $changes.Add("new: $($row.name) $($row.version)") }
      elseif ([string]$before[$row.id].version -ne $row.version) { $changes.Add("updated: $($row.name) $($before[$row.id].version) -> $($row.version)") }
    }
    $now = @($rows | ForEach-Object { $_.id })
    foreach ($id in $before.Keys) { if ($now -notcontains $id) { $changes.Add("removed: $($before[$id].name)") } }
  }
  if ($changes.Count -gt 0) {
    Write-Host ''
    Write-Host 'changes since the last inventory:'
    foreach ($c in $changes) { Write-Host "  $c" }
  }

  # Two copies where the daily update only reaches the one the terminal does not run.
  $shadow = New-Object System.Collections.Generic.List[string]
  foreach ($row in $rows) {
    if ($row.npmCopy -and $row.autoUpdate -like 'no*') {
      $shadow.Add("$($row.name): PATH runs $($row.version) at $($row.path), but the daily update refreshes the npm copy ($($row.npmCopy)). $(Get-AicmShadowFix ([pscustomobject]@{ Path = $row.path }))")
    }
  }
  if ($shadow.Count -gt 0) {
    Write-Host ''
    Write-Host 'duplicate installs the daily update does not reach:'
    foreach ($s in $shadow) { Write-Host "  $s" }
  }
  $previousShadow = @()
  if ($previous -and $previous.PSObject.Properties['shadowProblems']) { $previousShadow = @($previous.shadowProblems | ForEach-Object { ($_ -split ':')[0] }) }
  $newShadow = @($shadow | Where-Object { $previousShadow -notcontains ($_ -split ':')[0] })

  $stamp = Get-AicmTimestamp
  Write-AicmState 'inventory' ([ordered]@{ finishedAt = $stamp; version = Get-AicmVersion; ok = $true; host = $env:COMPUTERNAME; clis = $rows.ToArray(); otherNpm = $otherNpm; changes = $changes.ToArray(); shadowProblems = $shadow.ToArray() })

  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# AI CLI inventory - $env:COMPUTERNAME")
  $md.Add('')
  $md.Add("Updated $((Get-Date).ToString('yyyy-MM-dd HH:mm')) by AI CLI Auto Manager $(Get-AicmVersion).")
  $md.Add('')
  $md.Add('| CLI | via | version | latest | state | daily update | path |')
  $md.Add('| --- | --- | --- | --- | --- | --- | --- |')
  foreach ($row in $rows) {
    $pathText = $row.path
    if ($row.npmCopy) { $pathText += " (stale npm copy $($row.npmCopy) also installed)" }
    $md.Add("| $($row.name) | $($row.method) | $($row.version) | $($row.latest) | $($row.state) | $($row.autoUpdate) | $pathText |")
  }
  if ($otherNpm.Count -gt 0) { $md.Add(''); $md.Add("Other global npm packages: $($otherNpm -join ', ')") }
  if ($shadow.Count -gt 0) { $md.Add(''); $md.Add('Duplicate installs the daily update does not reach:'); foreach ($s in $shadow) { $md.Add("- $s") } }
  if ($changes.Count -gt 0) { $md.Add(''); $md.Add('Changes since the last inventory:'); foreach ($c in $changes) { $md.Add("- $c") } }
  $mdPath = Join-Path (Get-AicmHome) 'inventory.md'
  # MCP servers and skills compared across the installed CLIs (lib\config-drift.js).
  Write-Host ''
  $cfg = Invoke-AicmNodeModule 'config-drift' @('--markdown')
  if (@($cfg.Lines).Count -gt 0) {
    $md.Add(''); $md.Add('## Configuration across CLIs'); $md.Add('')
    foreach ($l in $cfg.Lines) { $md.Add($l) }
  }
  $md | Set-Content -LiteralPath $mdPath -Encoding UTF8
  Write-Host ''
  Write-Host "report: $mdPath"

  $attention = New-Object System.Collections.Generic.List[string]
  foreach ($a in @($cfg.Attention)) { if ($a) { $attention.Add($a) } }
  foreach ($c in $changes) { if ($c -notlike 'updated:*') { $attention.Add($c) } }
  # Notify once when a duplicate problem appears, not every week while it lasts (doctor keeps reporting it).
  foreach ($s in $newShadow) { $attention.Add(($s -split '\. fix:')[0]) }
  foreach ($p in (Get-AicmScheduleProblems -Skip 'Inventory')) { Write-Host "problem: $p"; $attention.Add($p) }
  if ($attention.Count -gt 0) { Send-AicmNotification 'AI CLI Auto Manager' ($attention -join '; ') }

  if ($LogRetentionDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem -LiteralPath $LogDir -Filter 'inventory-*.log' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  }
  Write-Host "[$(Get-AicmTimestamp)] AI CLI inventory finished"
} catch {
  Write-Host "error: $($_.Exception.Message)"
  Write-AicmState 'inventory-error' ([ordered]@{ finishedAt = Get-AicmTimestamp; ok = $false; error = $_.Exception.Message })
  Send-AicmNotification 'AI CLI Auto Manager' "inventory failed: $($_.Exception.Message)"
  $exitCode = 1
} finally {
  Stop-Transcript | Out-Null
}
exit $exitCode
