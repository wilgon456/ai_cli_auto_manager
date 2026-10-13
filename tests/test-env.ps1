# Expose only the runtimes tests need, never the user's CLI or package-manager PATH.
function New-TestRuntimePath([string]$Work) {
  $toolsDir = Join-Path $Work 'runtimes'
  New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
  foreach ($name in 'node', 'python', 'python3', 'py') {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -notmatch '\\WindowsApps\\') {
      ('@"{0}" %*' -f $command.Source) | Set-Content -LiteralPath (Join-Path $toolsDir "$name.cmd") -Encoding ASCII
    }
  }
  # The dispatcher test does not need packages; it must never query real npm/winget.
  @('@echo off', 'echo {"dependencies":{}}', 'exit /b 1') |
    Set-Content -LiteralPath (Join-Path $toolsDir 'npm.cmd') -Encoding ASCII
  return "$toolsDir;$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
}

function Remove-TestWorkspace([string]$Work) {
  $resolved = [System.IO.Path]::GetFullPath($Work)
  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolved) -notmatch '^aicm-test-[0-9a-f]{32}$') {
    throw "unsafe test cleanup path : $resolved"
  }
  . (Join-Path $PSScriptRoot '..\lib\aicm-common.ps1')
  if (Test-Path -LiteralPath $resolved) { Remove-AicmTree ([System.IO.DirectoryInfo]::new($resolved)) }
}
