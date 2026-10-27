# Read-only check of cleanup JSON serialization. Defines extracted functions only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Match([bool]$Ok, [string]$Message) {
  if (-not $Ok) { throw $Message }
}

$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/clean_ai_leftovers.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) { throw $parseErrors[0].ToString() }

$wanted = @('ConvertTo-CleanJsonText', 'ConvertTo-CleanJson', 'Write-CleanJsonBail')
$chunks = New-Object System.Collections.Generic.List[string]
foreach ($stmt in $ast.EndBlock.Statements) {
  if ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $stmt.Name) {
    $chunks.Add($stmt.Extent.Text)
  }
}
Assert-Match ($chunks.Count -eq 3) 'expected JSON helper, ConvertTo-CleanJson, and bail definitions'
. ([scriptblock]::Create(($chunks -join "`n")))

function Get-AicmProtectionPolicy { return 'protected files kept' }

function New-OffArchiveRow([string]$Path, [string]$Reason) {
  return [pscustomobject]@{
    id = 'claude-transcripts'
    category = 'sessions'
    path = $Path
    action = 'archive'
    reason = $Reason
    status = 'off'
    enabled = $false
    days = 30
    limit = 60
    direct = $false
    files = 2
    bytes = 9
    purge = 1
    purgeBytes = 64
    removed = 0
    removedBytes = 0
    purged = 0
    purgedBytes = 0
    inUse = 0
  }
}

function Get-ParsedCount($Value) {
  if ($null -eq $Value) { return 0 }
  if ($Value -is [System.Array]) { return $Value.Length }
  return 1
}

$script:CleanCategories = @('sessions')
$path = 'C:\arch"ive\off'
$reason = 'local' + [char]1 + 'rule' + [char]27
$row = New-OffArchiveRow $path $reason
$rows = New-Object System.Collections.Generic.List[object]
$rows.Add($row)
$errs = New-Object System.Collections.Generic.List[string]
$errs.Add('fail' + [char]1 + 'esc' + [char]27 + '"\')

$json = ConvertTo-CleanJson $true $rows $errs 64 0 0
$parsed = $json | ConvertFrom-Json
Assert-Match ($parsed.schemaVersion -eq 1) 'schemaVersion'
Assert-Match ($parsed.summary.plannedBytes -eq 64) 'summary plannedBytes'
Assert-Match ((Get-ParsedCount $parsed.rules) -eq 1) 'one rule'
$rule = $parsed.rules
if ($parsed.rules -is [System.Array]) { $rule = $parsed.rules[0] }
Assert-Match ($rule.purgeCandidates -eq 1) 'purgeCandidates'
Assert-Match ($rule.purgeCandidateBytes -eq 64) 'purgeCandidateBytes'
Assert-Match ($rule.enabled -eq $false) 'enabled false'
Assert-Match ($rule.status -eq 'off') 'status off'
Assert-Match ($rule.action -eq 'archive') 'action archive'
Assert-Match ($rule.path -eq $path) 'path roundtrip'
Assert-Match ($rule.reason -eq $reason) 'reason control roundtrip'
Assert-Match ((Get-ParsedCount $parsed.errors) -eq 1) 'one error'
$err0 = $parsed.errors
if ($parsed.errors -is [System.Array]) { $err0 = $parsed.errors[0] }
Assert-Match ($err0 -eq $errs[0]) 'error control roundtrip'

$empty = New-Object System.Collections.Generic.List[object]
$emptyJson = ConvertTo-CleanJson $false $empty $null 0 0 0
$emptyParsed = $emptyJson | ConvertFrom-Json
Assert-Match ($emptyParsed.schemaVersion -eq 1) 'empty list schema'
Assert-Match ((Get-ParsedCount $emptyParsed.rules) -eq 0) 'empty generic list rules'
Assert-Match ((Get-ParsedCount $emptyParsed.errors) -eq 0) 'empty errors'

$plain = New-Object 'object[]' 1
$plain[0] = $row
$plainJson = ConvertTo-CleanJson $true $plain $errs 64 0 0
$plainParsed = $plainJson | ConvertFrom-Json
Assert-Match ($plainParsed.schemaVersion -eq 1) 'plain array schema'
Assert-Match ($plainParsed.summary.plannedBytes -eq 64) 'plain array plannedBytes'
$plainRule = $plainParsed.rules
if ($plainParsed.rules -is [System.Array]) { $plainRule = $plainParsed.rules[0] }
Assert-Match ($plainRule.path -eq $path) 'plain array path'
Assert-Match ($plainRule.reason -eq $reason) 'plain array reason'

$Json = $true
$DryRun = $true
$bailMessage = 'bail' + [char]1 + [char]27 + '"'
$writer = New-Object System.IO.StringWriter
$previous = [Console]::Out
[Console]::SetOut($writer)
try {
  $native = @(Write-CleanJsonBail 'error' $bailMessage)
} finally {
  [Console]::SetOut($previous)
}
Assert-Match ($native.Count -eq 1) 'bail is one success-stream string'
Assert-Match ([string]::IsNullOrEmpty($writer.ToString())) 'bail has no direct console duplicate'
$bail = $native[0] | ConvertFrom-Json
Assert-Match ($bail.schemaVersion -eq 1) 'bail schema'
Assert-Match ((Get-ParsedCount $bail.rules) -eq 0) 'bail rules empty'
$bailErr = $bail.errors
if ($bail.errors -is [System.Array]) { $bailErr = $bail.errors[0] }
Assert-Match ($bailErr -eq $bailMessage) 'bail error control roundtrip'

function Assert-AsciiJson([string]$Text, [string]$Label) {
  foreach ($ch in $Text.ToCharArray()) {
    if ([int]$ch -gt 127) { throw "$Label contains a non-ASCII code unit" }
  }
}

$uniPath = 'C:\data\' + [char]0xD55C + [char]0xAE00 + [char]0xD83D + [char]0xDE00
$uniReason = 'reason' + [char]0xD55C + [char]0xD83D + [char]0xDE00
$uniRow = New-OffArchiveRow $uniPath $uniReason
$uniRows = New-Object System.Collections.Generic.List[object]
$uniRows.Add($uniRow)
$uniErrs = New-Object System.Collections.Generic.List[string]
$uniErrs.Add('err' + [char]0xAE00)
$uniJson = ConvertTo-CleanJson $true $uniRows $uniErrs 64 0 0
Assert-AsciiJson $uniJson 'unicode clean json'
$uniParsed = $uniJson | ConvertFrom-Json
$uniRule = $uniParsed.rules
if ($uniParsed.rules -is [System.Array]) { $uniRule = $uniParsed.rules[0] }
Assert-Match ($uniRule.path -eq $uniPath) 'unicode path roundtrip'
Assert-Match ($uniRule.reason -eq $uniReason) 'unicode reason roundtrip'
$uniErr = $uniParsed.errors
if ($uniParsed.errors -is [System.Array]) { $uniErr = $uniParsed.errors[0] }
Assert-Match ($uniErr -eq $uniErrs[0]) 'unicode error roundtrip'
Assert-Match ($uniRule.purgeCandidates -eq 1) 'unicode purgeCandidates'
Assert-Match ($uniRule.purgeCandidateBytes -eq 64) 'unicode purgeCandidateBytes'

$uniBail = 'stop' + [char]0xD55C + [char]0xD83D + [char]0xDE00
$uniNative = @(Write-CleanJsonBail 'error' $uniBail)
Assert-Match ($uniNative.Count -eq 1) 'unicode bail is one success-stream string'
Assert-AsciiJson ([string]$uniNative[0]) 'unicode bail json'
$uniBailDoc = $uniNative[0] | ConvertFrom-Json
$uniBailErr = $uniBailDoc.errors
if ($uniBailDoc.errors -is [System.Array]) { $uniBailErr = $uniBailDoc.errors[0] }
Assert-Match ($uniBailErr -eq $uniBail) 'unicode bail roundtrip'

Write-Host 'PASS maintenance JSON list, array, control-character escaping, and ASCII transport'
