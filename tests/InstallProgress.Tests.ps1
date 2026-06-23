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
if (-not (Get-Command Download-FileWithRetry -ErrorAction SilentlyContinue)) {
  throw 'Download-FileWithRetry was not loaded.'
}
'ready'
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'ready' 'Expected install.ps1 to expose helper functions in test mode.'
}

Run-Test 'PowerShell checker progress renders project format' {
  $script = @"
. '$repoRoot\scripts\Check-AI-CLI-Versions.ps1'
`$state = New-ByteProgressState 400 20
Add-ByteProgress `$state 100 | Out-Null
Get-ByteProgressLine `$state
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '##### 25.0%' 'Expected checker progress to use the same hash-only one-decimal format.'
}

Run-Test 'install.ps1 Download-ToFile renders native web progress' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$ProgressPreference = 'Continue'
function Invoke-WebRequest {
  param([string]`$Uri, [hashtable]`$Headers, [switch]`$UseBasicParsing, [string]`$OutFile)
  `$script:SeenProgress = `$ProgressPreference
  Set-Content -LiteralPath `$OutFile -Value 'payload'
  return [pscustomobject]@{}
}
`$out = Join-Path ([IO.Path]::GetTempPath()) 'check-ai-cli-progress-test.txt'
Download-ToFile 'https://example.test/file' `$out
`$script:SeenProgress
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'Continue' 'Expected installer file downloads to leave native web progress enabled.'
}

Run-Test 'install.ps1 Download-Text suppresses native web progress' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$ProgressPreference = 'Continue'
function Invoke-WebRequest {
  param([string]`$Uri, [hashtable]`$Headers, [switch]`$UseBasicParsing)
  `$script:SeenProgress = `$ProgressPreference
  return [pscustomobject]@{ Content = 'payload' }
}
`$null = Download-Text 'https://example.test/text'
`$script:SeenProgress
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'SilentlyContinue' 'Expected installer text downloads to suppress PowerShell native web progress.'
}

Run-Test 'PowerShell checker Get-Text suppresses native web progress' {
  $script = @"
. '$repoRoot\scripts\Check-AI-CLI-Versions.ps1'
`$ProgressPreference = 'Continue'
function Invoke-WebRequest {
  param([string]`$Uri, [hashtable]`$Headers, [switch]`$UseBasicParsing, [int]`$TimeoutSec)
  `$script:SeenProgress = `$ProgressPreference
  return [pscustomobject]@{ Content = 'payload' }
}
`$null = Get-Text 'https://example.test/text'
`$script:SeenProgress
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'SilentlyContinue' 'Expected checker text downloads to suppress PowerShell native web progress.'
}

Run-Test 'Get-BaseUrl prefers latest stable release when ref is implicit' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Invoke-RestMethod {
  param([string]`$Uri, [hashtable]`$Headers)
  return [pscustomobject]@{ tag_name = 'v1.2.3' }
}
Get-BaseUrl
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/v1.2.3' 'Expected implicit installer ref to resolve to the latest stable release tag.'
}

Run-Test 'Get-BaseUrl falls back to latest main commit when stable release lookup fails' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Invoke-RestMethod {
  param([string]`$Uri, [hashtable]`$Headers)
  if (`$Uri -like '*/releases/latest') { throw 'boom' }
  if (`$Uri -like '*/git/ref/heads/main') {
    return [pscustomobject]@{
      object = [pscustomobject]@{ sha = '0123456789abcdef0123456789abcdef01234567' }
    }
  }
  throw \"unexpected uri: `$Uri\"
}
Get-BaseUrl
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/0123456789abcdef0123456789abcdef01234567' 'Expected installer to fall back to the latest main commit when latest release lookup fails.'
}

Run-Test 'Get-BaseUrl falls back to main when stable release and main commit lookups fail' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
`$script:Warnings = @()
function Write-Warn([string]`$Message) { `$script:Warnings += `$Message }
function Invoke-RestMethod { throw 'boom' }
`$url = Get-BaseUrl
'{0}|{1}' -f `$url, (`$script:Warnings -join ',')
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main|Latest stable release ref unavailable. Falling back to main.' 'Expected installer to fall back to main only when both latest release and latest main commit lookups fail.'
}

Run-Test 'Get-BaseUrl respects explicit CHECK_AI_CLI_REF' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
`$env:CHECK_AI_CLI_REF = 'main'
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Invoke-RestMethod { throw 'should not call releases api' }
Get-BaseUrl
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main' 'Expected explicit CHECK_AI_CLI_REF to bypass stable release resolution.'
}

Run-Test 'Get-BaseUrl respects explicit CHECK_AI_CLI_RAW_BASE' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
`$env:CHECK_AI_CLI_RAW_BASE = 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main'
. '$repoRoot\install.ps1'
function Invoke-RestMethod { throw 'should not call releases api' }
Get-BaseUrl
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main' 'Expected explicit CHECK_AI_CLI_RAW_BASE to bypass stable release resolution.'
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

  Assert-Equal $result 'Detected another Check-AI-CLI install at: C:\Program Files\Tools\Check-AI-CLI|New PowerShell sessions may still launch the older Program Files copy before this CurrentUser install.|Recovery: run C:\Users\Tester\AppData\Local\Programs\Tools\Check-AI-CLI\bin\check-ai-cli.cmd directly, or rerun the installer as Administrator to update the machine-wide copy, or uninstall the older Program Files install.' 'Expected installer to warn when a stale Program Files install can shadow a CurrentUser install.'
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
