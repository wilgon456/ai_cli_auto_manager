# Native exclusive handles reject open readers/writers, including FILE_SHARE_DELETE readers.
[CmdletBinding()]
param([ValidateSet('move','purge')][string]$Operation, [string]$Source, [string]$Destination = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'aicm-file-guard.cs')
if ($Operation -eq 'move') { $ok = [Aicm.FileGuard]::TryMove($Source, $Destination) }
else { $ok = [Aicm.FileGuard]::TryDelete(@($Source), @($Source)) }
if (-not $ok) { exit 1 }
