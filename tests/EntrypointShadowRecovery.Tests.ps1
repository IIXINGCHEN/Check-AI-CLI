$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
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

function Invoke-PwshSnippet([string]$Script) {
  $output = & pwsh -NoProfile -Command $Script 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($output | Out-String).Trim()
    throw "Snippet failed:`n$text"
  }
  return (($output | Out-String).TrimEnd())
}

Run-Test 'bin/check-ai-cli.ps1 forwards Program Files launch to a newer CurrentUser install' {
  $script = @"
`$env:CHECK_AI_CLI_TEST_MODE = '1'
`$env:CHECK_AI_CLI_TEST_INSTALL_ROOT = 'C:\Program Files\Tools\Check-AI-CLI'
`$env:LOCALAPPDATA = 'C:\Users\Tester\AppData\Local'
function Test-Path {
  param([string]`$Path, [string]`$LiteralPath)
  `$target = if (`$PSBoundParameters.ContainsKey('LiteralPath')) { `$LiteralPath } else { `$Path }
  return `$target -eq 'C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI\bin\check-ai-cli.ps1'
}
function Get-Item {
  param([string]`$LiteralPath)
  [pscustomobject]@{ LastWriteTimeUtc = if (`$LiteralPath -like '*AppData*') { [datetime]'2026-07-13T00:00:00Z' } else { [datetime]'2026-07-12T00:00:00Z' } }
}
. '$repoRoot\bin\check-ai-cli.ps1'
'{0}|{1}' -f `$script:ShadowRecoveryAction, `$script:ShadowRecoveryTarget
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'forward|C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI\bin\check-ai-cli.ps1' 'Expected Program Files launch to forward to the CurrentUser entrypoint when available.'
}

Run-Test 'bin/check-ai-cli.ps1 keeps Program Files launch when CurrentUser install is older' {
  $script = @"
`$env:CHECK_AI_CLI_TEST_MODE = '1'
`$env:CHECK_AI_CLI_TEST_INSTALL_ROOT = 'C:\Program Files\Tools\Check-AI-CLI'
`$env:LOCALAPPDATA = 'C:\Users\Tester\AppData\Local'
function Test-Path {
  param([string]`$Path, [string]`$LiteralPath)
  `$target = if (`$PSBoundParameters.ContainsKey('LiteralPath')) { `$LiteralPath } else { `$Path }
  return `$target -eq 'C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI\bin\check-ai-cli.ps1'
}
function Get-Item {
  param([string]`$LiteralPath)
  [pscustomobject]@{ LastWriteTimeUtc = if (`$LiteralPath -like '*AppData*') { [datetime]'2026-06-30T00:00:00Z' } else { [datetime]'2026-07-12T00:00:00Z' } }
}
. '$repoRoot\bin\check-ai-cli.ps1'
'{0}|{1}' -f `$script:ShadowRecoveryAction, `$script:ShadowRecoveryTarget
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'local|C:\Program Files\Tools\Check-AI-CLI\scripts\Check-AI-CLI-Versions.ps1' 'Expected a stale CurrentUser install to be ignored in favor of the newer Program Files install.'
}

Write-Host '[PASS] All entrypoint shadow recovery regression tests passed.' -ForegroundColor Green
