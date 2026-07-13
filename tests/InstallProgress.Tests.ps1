$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Invoke-PwshSnippet([string]$Script) {
  $output = & $pwsh -NoProfile -Command $Script 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($output | Out-String).Trim()
    throw "Snippet failed:`n$text"
  }
  return (($output | Out-String).TrimEnd())
}


function Get-TestProgramFilesInstallDir() {
  return (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI')
}

function Get-TestCurrentUserInstallDir([string]$UserName = 'Tester') {
  return (Join-Path (Join-Path $env:SystemDrive ('Users\' + $UserName)) 'AppData\Local\Programs\Tools\Check-AI-CLI')
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

Run-Test 'install.ps1 Get-InstallProgressPercent advances per file and stays below 100 mid-set' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$percents = @(
  (Get-InstallProgressPercent 1 3),
  (Get-InstallProgressPercent 2 3),
  (Get-InstallProgressPercent 3 3),
  (Get-InstallProgressPercent 1 1)
)
`$percents -join ','
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '0,33,67,0' 'Expected outer progress percent to start at 0, advance per file, and stay below 100 until the set completes.'
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

Run-Test 'Get-BaseUrl fails closed when no immutable ref can be resolved' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Invoke-RestMethod { throw 'boom' }
try { Get-BaseUrl } catch { `$_.Exception.Message }
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'Failed to resolve an immutable release tag or main commit. Refusing mutable main fallback.' 'Expected installer to fail closed instead of using mutable main.'
}

Run-Test 'Get-BaseUrl resolves explicit main to a commit SHA' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
`$env:CHECK_AI_CLI_REF = 'main'
Remove-Item Env:CHECK_AI_CLI_RAW_BASE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Get-LatestMainCommitRef { return '0123456789abcdef0123456789abcdef01234567' }
Get-BaseUrl
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/0123456789abcdef0123456789abcdef01234567' 'Expected explicit main to be pinned to an immutable commit.'
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
  $pf = Get-TestProgramFilesInstallDir
  $user = Get-TestCurrentUserInstallDir
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$script:Warnings = @()
function Write-Warn([string]`$Message) { `$script:Warnings += `$Message }
function Get-MachineInstallDir() { return '$pf' }
function Test-InstallHasCommand([string]`$Dir) {
  return `$Dir -eq '$pf'
}
Warn-ShadowedCurrentUserInstall '$user' 'CurrentUser'
`$script:Warnings -join '|'
"@

  $result = Invoke-PwshSnippet $script

  Assert-True ($result -like ("Detected another Check-AI-CLI install at: $pf|*")) 'Expected shadow warning header.'
  Assert-True ($result -like '*New PowerShell sessions may still launch the older Program Files copy*') 'Expected shadow impact explanation.'
  Assert-True ($result -like '*uninstall.ps1 -ProgramFiles*') 'Expected Program Files uninstall recovery command.'
  Assert-True ($result -like '*install.ps1 as Administrator*' -or $result -like '*rerun install.ps1 as Administrator*') 'Expected admin reinstall recovery option.'
}

Run-Test 'Default install target is CurrentUser even when the process is already elevated' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_INSTALL_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_PATH_SCOPE -ErrorAction SilentlyContinue
Remove-Item Env:CHECK_AI_CLI_INSTALL_SCOPE -ErrorAction SilentlyContinue
. '$repoRoot\install.ps1'
function Test-IsAdmin() { return `$true }
'dir=' + (Get-InstallDir) + '|scope=' + (Get-PathScope) + '|machine=' + (Test-MachineInstallRequested)
"@

  $result = Invoke-PwshSnippet $script
  $userDir = Join-Path $env:LOCALAPPDATA 'Programs\Tools\Check-AI-CLI'
  Assert-Equal $result ("dir=$userDir|scope=CurrentUser|machine=False") 'Expected safe CurrentUser default even under an elevated shell.'
}

Run-Test '-Machine / Machine PATH scope selects Program Files and requires admin' {
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
Remove-Item Env:CHECK_AI_CLI_INSTALL_DIR -ErrorAction SilentlyContinue
`$env:CHECK_AI_CLI_PATH_SCOPE = 'Machine'
. '$repoRoot\install.ps1'
function Test-IsAdmin() { return `$false }
'dir=' + (Get-InstallDir) + '|scope=' + (Get-PathScope) + '|machine=' + (Test-MachineInstallRequested) + '|needsAdmin=' + (Test-NeedsAdminForInstall (Get-InstallDir) (Get-PathScope))
"@

  $result = Invoke-PwshSnippet $script
  $pfDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI'
  Assert-equal $result ("dir=$pfDir|scope=Machine|machine=True|needsAdmin=True") 'Expected Machine scope to select Program Files and require admin.'
}

Run-Test 'Request-ElevatedInstall uses temp -File bootstrap instead of -Command join' {
  $text = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
  Assert-True ($text.Contains('function Request-ElevatedInstall')) 'Expected Request-ElevatedInstall to exist.'
  Assert-True ($text.Contains('function New-ElevatedInstallBootstrap')) 'Expected New-ElevatedInstallBootstrap to exist.'
  Assert-True ($text.Contains('PSScriptRoot')) 'Expected PSScriptRoot guard for irm|iex refusal.'
  Assert-True ($text.Contains('-Machine')) 'Expected -Machine guidance/re-entry.'
  Assert-True ($text.Contains('RunAs')) 'Expected UAC RunAs elevation.'
  Assert-True ($text.Contains('CHECK_AI_CLI_ELEVATION_DONE')) 'Expected elevation re-entry marker.'
  Assert-True ($text.Contains("'-File', `$bootstrap") -or $text.Contains("'-File', $bootstrap")) 'Expected -File bootstrap elevation path.'
  Assert-True ($text.Contains('New-ElevatedInstallBootstrap') -and $text.Contains('-File')) 'Expected elevation to use bootstrap file launch.'
  Assert-True (-not $text.Contains("'-Command', `$command") -and -not $text.Contains("'-Command', $command")) 'Expected legacy -Command elevation join to be removed.'
}

Run-Test 'New-ElevatedInstallBootstrap preserves env values containing semicolons as single assignments' {
  $env:CHECK_AI_CLI_SKIP_MAIN = '1'
  . (Join-Path $repoRoot 'install.ps1')
  $originalProxy = $env:HTTP_PROXY
  $originalHttps = $env:HTTPS_PROXY
  $bootstrap = $null
  try {
    $env:HTTP_PROXY = 'http://127.0.0.1:7890;http://backup:7890'
    $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
    $bootstrap = New-ElevatedInstallBootstrap (Join-Path $repoRoot 'install.ps1')
    $text = Get-Content -LiteralPath $bootstrap -Raw
    Assert-True ($text.Contains("HTTP_PROXY = 'http://127.0.0.1:7890;http://backup:7890'")) 'Expected semicolon-bearing proxy to stay inside one quoted assignment.'
    Assert-True ($text -match '-Machine') 'Expected bootstrap to invoke install.ps1 -Machine.'
  } finally {
    if ($null -eq $originalProxy) { Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue } else { $env:HTTP_PROXY = $originalProxy }
    if ($null -eq $originalHttps) { Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue } else { $env:HTTPS_PROXY = $originalHttps }
    if ($bootstrap -and (Test-Path -LiteralPath $bootstrap)) { Remove-Item -LiteralPath $bootstrap -Force -ErrorAction SilentlyContinue }
  }
}

Run-Test 'Program Files INSTALL_DIR rejects PATH_SCOPE=CurrentUser mix' {
  $env:CHECK_AI_CLI_SKIP_MAIN = '1'
  $originalDir = $env:CHECK_AI_CLI_INSTALL_DIR
  $originalScope = $env:CHECK_AI_CLI_PATH_SCOPE
  try {
    . (Join-Path $repoRoot 'install.ps1')
    $env:CHECK_AI_CLI_INSTALL_DIR = (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI')
    $env:CHECK_AI_CLI_PATH_SCOPE = 'CurrentUser'
    $threw = $false
    $message = ''
    try {
      [void](Get-PathScope)
    } catch {
      $threw = $true
      $message = $_.Exception.Message
    }
    Assert-True $threw 'Expected mixed PF install dir + CurrentUser PATH scope to throw.'
    Assert-True ($message -like '*Cannot combine*Program Files*CurrentUser*') 'Expected mixed intent rejection message.'
  } finally {
    if ($null -eq $originalDir) { Remove-Item Env:CHECK_AI_CLI_INSTALL_DIR -ErrorAction SilentlyContinue } else { $env:CHECK_AI_CLI_INSTALL_DIR = $originalDir }
    if ($null -eq $originalScope) { Remove-Item Env:CHECK_AI_CLI_PATH_SCOPE -ErrorAction SilentlyContinue } else { $env:CHECK_AI_CLI_PATH_SCOPE = $originalScope }
  }
}

Run-Test 'Warn-ShadowedCurrentUserInstall stays quiet when no machine-wide install exists' {
  $pf = Get-TestProgramFilesInstallDir
  $user = Get-TestCurrentUserInstallDir
  $script = @"
`$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. '$repoRoot\install.ps1'
`$script:Warnings = @()
function Write-Warn([string]`$Message) { `$script:Warnings += `$Message }
function Get-MachineInstallDir() { return '$pf' }
function Test-InstallHasCommand([string]`$Dir) { return `$false }
Warn-ShadowedCurrentUserInstall '$user' 'CurrentUser'
`$script:Warnings.Count
"@

  $result = Invoke-PwshSnippet $script

  Assert-Equal $result '0' 'Expected no shadowing warning when no machine-wide install is present.'
}

Write-Host '[PASS] All install progress PowerShell tests passed.' -ForegroundColor Green
