<#
.SYNOPSIS
  Kept for compatibility. Registers only the daily update task, as before.
.DESCRIPTION
  New installs should run:  .\bin\aicm.ps1 schedule install
  which registers both the daily update and the weekly cleanup.
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
$splat = @{ Command = 'schedule'; Action = 'install'; UpdateAt = $At; LogRetentionDays = $LogRetentionDays; NoClean = $true }
if ($Targets) { $splat.Targets = @($Targets) }
if ($InstallMissing) { $splat.InstallMissing = $true }
& $aicm @splat
