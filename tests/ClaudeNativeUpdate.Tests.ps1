$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-StartsWith([string]$Actual, [string]$ExpectedPrefix, [string]$Message) {
  if (($null -eq $Actual) -or (-not $Actual.StartsWith($ExpectedPrefix, [System.StringComparison]::Ordinal))) {
    throw "$Message`nExpected prefix: $ExpectedPrefix`nActual: $Actual"
  }
}

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
  if (-not $Text.Contains($Expected)) {
    throw "$Message`nExpected substring: $Expected`nActual: $Text"
  }
}

function Invoke-PwshSnippet([string]$Script) {
  $output = & $pwsh -NoProfile -Command $Script 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($output | Out-String).Trim()
    throw "Snippet failed:`n$text"
  }
  return (($output | Out-String).TrimEnd())
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    Write-Host "[PASS] $Name" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    throw
  }
}

# Invoke-ClaudeNativeUpdateProcess starts `claude update`, waits, then inspects
# $proc.ExitCode. After WaitForExit some process/shim launches leave ExitCode as
# $null; the old `if ($proc.ExitCode -ne 0)` treated `$null -ne 0` as a failure
# and threw "claude update failed with exit code " (empty). The fix returns
# silently on a null ExitCode and lets the downstream version check decide.
# These tests mock Start-Process to return a process whose ExitCode we control.

Run-Test 'Invoke-ClaudeNativeUpdateProcess tolerates a null ExitCode without throwing' {
  $script = @"
. '$repoRoot\scripts\Check-AI-CLI-Versions.ps1'
`$script:MockExitCode = `$null
function Start-Process {
  param([string]`$FilePath, `$ArgumentList, [switch]`$NoNewWindow, [switch]`$PassThru)
  `$p = [pscustomobject]@{ Id = 4242; HasExited = `$true; ExitCode = `$script:MockExitCode }
  `$p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param(`$timeoutMs) return `$true }
  `$p | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
  `$p
}
function Stop-Process { param(`$Id, [switch]`$Force) }
try { Invoke-ClaudeNativeUpdateProcess 'C:\fake\claude.exe' 5; 'returned' } catch { 'threw' }
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'returned' 'Expected a null ExitCode to be tolerated without throwing (regression: previously threw with an empty exit code).'
}

Run-Test 'Invoke-ClaudeNativeUpdateProcess succeeds when ExitCode is zero' {
  $script = @"
. '$repoRoot\scripts\Check-AI-CLI-Versions.ps1'
`$script:MockExitCode = 0
function Start-Process {
  param([string]`$FilePath, `$ArgumentList, [switch]`$NoNewWindow, [switch]`$PassThru)
  `$p = [pscustomobject]@{ Id = 4242; HasExited = `$true; ExitCode = `$script:MockExitCode }
  `$p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param(`$timeoutMs) return `$true }
  `$p | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
  `$p
}
function Stop-Process { param(`$Id, [switch]`$Force) }
try { Invoke-ClaudeNativeUpdateProcess 'C:\fake\claude.exe' 5; 'returned' } catch { 'threw' }
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'returned' 'Expected a zero ExitCode to be treated as success.'
}

Run-Test 'Invoke-ClaudeNativeUpdateProcess throws on a non-zero ExitCode' {
  $script = @"
. '$repoRoot\scripts\Check-AI-CLI-Versions.ps1'
`$script:MockExitCode = 1
function Start-Process {
  param([string]`$FilePath, `$ArgumentList, [switch]`$NoNewWindow, [switch]`$PassThru)
  `$p = [pscustomobject]@{ Id = 4242; HasExited = `$true; ExitCode = `$script:MockExitCode }
  `$p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param(`$timeoutMs) return `$true }
  `$p | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
  `$p
}
function Stop-Process { param(`$Id, [switch]`$Force) }
try { Invoke-ClaudeNativeUpdateProcess 'C:\fake\claude.exe' 5; 'returned' } catch { 'threw:' + `$_.Exception.Message }
"@

  $result = Invoke-PwshSnippet $script

  Assert-StartsWith $result 'threw:' 'Expected a non-zero ExitCode to throw.'
  Assert-Contains $result 'exit code 1' 'Expected the thrown message to report the exit code.'
}

Write-Host '[PASS] All Claude native-update PowerShell tests passed.' -ForegroundColor Green
