<#
.SYNOPSIS
  Kept for compatibility. Registers (or updates) only the daily update task, as before.
.DESCRIPTION
  New installs should run:  .\bin\aicm.ps1 schedule install
  which registers the daily update, the weekly inventory and the weekly cleanup.
  Inventory and Clean tasks that are already registered are left as they are.
#>
[CmdletBinding()]
param(
  [string]$At = '05:00',
  [string]$Targets = $(if ($env:AI_CLI_TARGETS) { $env:AI_CLI_TARGETS } else { '' }),
  [int]$LogRetentionDays = $(if ($env:LOG_RETENTION_DAYS) { [int]$env:LOG_RETENTION_DAYS } else { 30 }),
  [switch]$InstallMissing
)

$ErrorActionPreference = 'Stop'
$aicm = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\aicm.ps1'
Write-Host "note: windows\install_scheduled_task.ps1 is deprecated; use: .\bin\aicm.ps1 schedule install"
$splat = @{ Command = 'schedule'; Action = 'install'; UpdateAt = $At; LogRetentionDays = $LogRetentionDays; NoClean = $true; NoInventory = $true; KeepOtherJobs = $true }
if ($Targets) { $splat.Targets = @($Targets) }
if ($InstallMissing) { $splat.InstallMissing = $true }
& $aicm @splat
