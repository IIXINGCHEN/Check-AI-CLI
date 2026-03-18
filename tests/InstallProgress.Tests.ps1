$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
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

Run-Test 'install.ps1 can load helpers without executing main flow' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
if (-not (Get-Command New-ByteProgressState -ErrorAction SilentlyContinue)) {
  throw 'New-ByteProgressState was not loaded.'
}
'ready'
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'ready' 'Expected install.ps1 to expose helper functions in test mode.'
}

Run-Test 'PowerShell byte progress renders hash bar at fifty percent' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$state = New-ByteProgressState 200 20
Add-ByteProgress `$state 100 | Out-Null
Get-ByteProgressLine `$state
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '[##########..........] 50%' 'Expected byte progress to render ten filled segments at 50%.'
}

Run-Test 'PowerShell byte progress clamps at one hundred percent' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$state = New-ByteProgressState 80 20
Add-ByteProgress `$state 120 | Out-Null
Get-ByteProgressLine `$state
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '[####################] 100%' 'Expected byte progress to clamp at 100%.'
}

Run-Test 'Get-RemoteFileSize falls back to GET RawContentLength when HEAD lacks content length' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$script:Methods = @()
function Invoke-WebRequest {
  param(
    [string]`$Uri,
    [hashtable]`$Headers,
    [string]`$Method,
    [switch]`$UseBasicParsing
  )
  `$script:Methods += `$Method
  if (`$Method -eq 'Head') {
    return [pscustomobject]@{ Headers = @{} }
  }
  return [pscustomobject]@{
    Headers = @{}
    RawContentLength = 216
  }
}
`$size = Get-RemoteFileSize 'https://example.test/file'
('{0}|{1}' -f `$size, (`$script:Methods -join ','))
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '216|Head,Get' 'Expected Get-RemoteFileSize to retry with GET and use RawContentLength when HEAD lacks Content-Length.'
}

Run-Test 'Warn-ShadowedCurrentUserInstall reports an older machine-wide install' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$script:Warnings = @()
function Write-Warn([string]`$Message) { `$script:Warnings += `$Message }
function Get-MachineInstallDir() { return 'C:\Program Files\Tools\Check-AI-CLI' }
function Test-InstallHasCommand([string]`$Dir) {
  return `$Dir -eq 'C:\Program Files\Tools\Check-AI-CLI'
}
Warn-ShadowedCurrentUserInstall 'C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI' 'CurrentUser'
`$script:Warnings -join '|'
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'Detected another Check-AI-CLI install at: C:\Program Files\Tools\Check-AI-CLI|A machine-wide install may still resolve before this CurrentUser install in new PowerShell sessions.|Fix: rerun the installer as Administrator to update the machine-wide copy, or uninstall the older Program Files install.' 'Expected installer to warn when a stale Program Files install can shadow a CurrentUser install.'
}

Run-Test 'Warn-ShadowedCurrentUserInstall stays quiet when no machine-wide install exists' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$script:Warnings = @()
function Write-Warn([string]`$Message) { `$script:Warnings += `$Message }
function Get-MachineInstallDir() { return 'C:\Program Files\Tools\Check-AI-CLI' }
function Test-InstallHasCommand([string]`$Dir) { return `$false }
Warn-ShadowedCurrentUserInstall 'C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI' 'CurrentUser'
`$script:Warnings.Count
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '0' 'Expected no shadowing warning when no machine-wide install is present.'
}

Write-Host '[PASS] All install progress PowerShell tests passed.' -ForegroundColor Green
