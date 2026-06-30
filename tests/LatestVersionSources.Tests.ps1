$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-ThrowsContains([scriptblock]$Action, [string]$ExpectedSubstring, [string]$Message) {
  try {
    & $Action
  } catch {
    if ($_.Exception.Message.Contains($ExpectedSubstring)) { return }
    throw "$Message`nExpected exception containing: $ExpectedSubstring`nActual: $($_.Exception.Message)"
  }

  throw "$Message`nExpected exception containing: $ExpectedSubstring"
}

function Reset-TestState {
  $script:CapturedWarnings = @()
  $script:CapturedInfos = @()
  $env:CHECK_AI_CLI_OPENCODE_VERSION = ''
  $env:CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS = ''
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  try {
    Reset-TestState
    & $Body
    Write-Host "[PASS] $Name" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    throw
  }
}

function Write-Warn([string]$Message) {
  $script:CapturedWarnings += $Message
}

function Write-Info([string]$Message) {
  $script:CapturedInfos += $Message
}

Run-Test 'Get-LatestClaudeVersion prefers bootstrap stable over repo (installable channel)' {
  function Get-ClaudeRepoLatestVersion() {
    return '2.1.101'
  }

  function Get-ClaudeBootstrapStableVersion() {
    return '2.1.91'
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '2.1.69'
  }

  $version = Get-LatestClaudeVersion

  # Bootstrap stable is what the native updater and install.ps1 can actually install.
  # GitHub releases may be ahead due to staged rollout.
  Assert-Equal $version '2.1.91' 'Expected Claude latest version to reflect the installable stable channel, not the GitHub release that may be staged.'
}

Run-Test 'Get-LatestClaudeVersion prefers newer npm package over bootstrap stable' {
  function Get-ClaudeRepoLatestVersion() {
    return '2.1.200'
  }

  function Get-ClaudeBootstrapStableVersion() {
    return '2.1.152'
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '2.1.162'
  }

  $version = Get-LatestClaudeVersion

  Assert-Equal $version '2.1.162' 'Expected Claude latest version to use the newer official npm installable version when it is ahead of bootstrap stable.'
  Assert-Equal $script:CapturedWarnings.Count 0 'Expected Claude stable/npm source differences to avoid warning-level output.'
  Assert-True ($script:CapturedInfos -contains 'Claude Code latest version sources differ: stable=v2.1.152, npm=v2.1.162. Using v2.1.162.') 'Expected Claude stable/npm source difference to be logged as informational output.'
}

Run-Test 'Get-LatestClaudeVersion falls back to repo when installable sources are unavailable' {
  function Get-ClaudeRepoLatestVersion() {
    return '2.1.72'
  }

  function Get-ClaudeBootstrapStableVersion() {
    return $null
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return $null
  }

  $version = Get-LatestClaudeVersion

  Assert-Equal $version '2.1.72' 'Expected Claude latest version to fall back to GitHub repo when stable and npm installable sources are unavailable.'
}

Run-Test 'Get-LatestCodexVersion prefers official repo release over npm metadata' {
  function Get-GitHubLatestReleaseVersion([string]$Repo) {
    return '0.109.0'
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '0.110.0'
  }

  $version = Get-LatestCodexVersion

  Assert-Equal $version '0.109.0' 'Expected Codex latest version to come from the official GitHub release channel.'
}

Run-Test 'Get-LatestGeminiVersion prefers official repo release over npm metadata' {
  function Get-GitHubLatestReleaseVersion([string]$Repo) {
    return '0.24.0'
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '0.25.0'
  }

  $version = Get-LatestGeminiVersion

  Assert-Equal $version '0.24.0' 'Expected Gemini latest version to come from the official GitHub release channel.'
}

Run-Test 'Get-LatestOpenCodeVersion falls back to npm only when repo source is unavailable' {
  function Get-GitHubLatestReleaseVersion([string]$Repo) {
    return $null
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '1.2.21'
  }

  $version = Get-LatestOpenCodeVersion

  Assert-Equal $version '1.2.21' 'Expected OpenCode to fall back to the official npm package only when GitHub release metadata is unavailable.'
}

Run-Test 'Update-Claude prefers native updater before official install script' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }
  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.119'; Source = 'stable'; Stable = '2.1.119'; Npm = $null; Repo = $null } }
  function Get-LocalClaudeVersion() { return '2.1.119' }

  $script:NativeUpdateCalls = 0
  $script:InstallScriptCalls = 0

  function Invoke-ClaudeNativeUpdate() {
    $script:NativeUpdateCalls += 1
  }

  function Update-ClaudeViaInstallScript() {
    $script:InstallScriptCalls += 1
  }

  Update-Claude

  Assert-Equal $script:NativeUpdateCalls 1 'Expected Claude update to try the native Claude updater first on Windows.'
  Assert-Equal $script:InstallScriptCalls 0 'Expected the official install script to stay unused when native Claude update succeeds.'
}

Run-Test 'Update-Claude falls back to official install script when native Claude update fails' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }
  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.119'; Source = 'stable'; Stable = '2.1.119'; Npm = $null; Repo = $null } }
  function Get-LocalClaudeVersion() { return '2.1.119' }

  $script:NativeUpdateCalls = 0
  $script:InstallScriptCalls = 0

  function Invoke-ClaudeNativeUpdate() {
    $script:NativeUpdateCalls += 1
    throw 'native update failed'
  }

  function Update-ClaudeViaInstallScript() {
    $script:InstallScriptCalls += 1
  }

  Update-Claude

  Assert-Equal $script:NativeUpdateCalls 1 'Expected Claude update to attempt the native updater before falling back.'
  Assert-Equal $script:InstallScriptCalls 1 'Expected Claude update to fall back to the official install script when native update fails.'
  Assert-True ($script:CapturedWarnings -contains 'native Claude update failed: native update failed') 'Expected a warning when the native Claude updater fails.'
}

Run-Test 'Update-ClaudeViaNpm installs the official Claude package and repairs PATH' {
  $script:NpmInstallCalls = @()
  $script:RepairCalls = @()

  function Invoke-NpmInstallGlobal([string]$PackageSpec) {
    $script:NpmInstallCalls += $PackageSpec
  }

  function Repair-ToolUserPath([string]$ToolId) {
    $script:RepairCalls += $ToolId
    return $true
  }

  Update-ClaudeViaNpm

  Assert-Equal $script:NpmInstallCalls.Count 1 'Expected Claude npm fallback to run one npm install.'
  Assert-Equal $script:NpmInstallCalls[0] '@anthropic-ai/claude-code@latest' 'Expected Claude npm fallback to install the official Claude Code package.'
  Assert-Equal $script:RepairCalls[0] 'claude' 'Expected Claude npm fallback to refresh Claude PATH candidates after installation.'
}

Run-Test 'Update-Claude falls back to npm when native and official install paths fail' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }

  $script:NpmInstallCalls = 0

  function Invoke-ClaudeNativeUpdate() {
    throw 'native update failed'
  }

  function Update-ClaudeViaInstallScript() {
    throw 'install script failed: ECONNREFUSED'
  }

  function Update-ClaudeViaNpm() {
    $script:NpmInstallCalls += 1
  }

  Update-Claude

  Assert-Equal $script:NpmInstallCalls 1 'Expected Claude update to try npm after native and official install paths fail.'
  Assert-True ($script:CapturedWarnings -contains 'official Claude install script failed: install script failed: ECONNREFUSED') 'Expected official install script failure detail to be logged before npm fallback.'
}

Run-Test 'Update-Claude falls back to official install script when native update leaves Claude below target' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }
  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.119'; Source = 'stable'; Stable = '2.1.119'; Npm = $null; Repo = $null } }
  $script:LocalClaudeVersion = '2.1.112'
  function Get-LocalClaudeVersion() { return $script:LocalClaudeVersion }

  $script:NativeUpdateCalls = 0
  $script:InstallScriptCalls = 0
  $script:NpmInstallCalls = 0

  function Invoke-ClaudeNativeUpdate() {
    $script:NativeUpdateCalls += 1
  }

  function Update-ClaudeViaInstallScript() {
    $script:InstallScriptCalls += 1
    $script:LocalClaudeVersion = '2.1.119'
  }

  function Update-ClaudeViaNpm() {
    $script:NpmInstallCalls += 1
  }

  Update-Claude

  Assert-Equal $script:NativeUpdateCalls 1 'Expected Claude update to try native updater first.'
  Assert-Equal $script:InstallScriptCalls 1 'Expected Claude update to fall back when native updater exits successfully but leaves Claude below target.'
  Assert-Equal $script:NpmInstallCalls 0 'Expected Claude update to stop after official install script reaches the target.'
  Assert-True ($script:CapturedWarnings -contains 'native Claude update completed but local version is still older than target v2.1.119.') 'Expected no-op native updater warning.'
}

Run-Test 'Update-Claude falls back to npm when official install script leaves Claude below target' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }
  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.119'; Source = 'stable'; Stable = '2.1.119'; Npm = $null; Repo = $null } }
  function Get-LocalClaudeVersion() { return '2.1.112' }

  $script:NpmInstallCalls = 0

  function Invoke-ClaudeNativeUpdate() {
    throw 'native update failed'
  }

  function Update-ClaudeViaInstallScript() {
  }

  function Update-ClaudeViaNpm() {
    $script:NpmInstallCalls += 1
  }

  Update-Claude

  Assert-Equal $script:NpmInstallCalls 1 'Expected Claude update to try npm when official install script completes but Claude remains below target.'
  Assert-True ($script:CapturedWarnings -contains 'official Claude install script completed but local version is still older than target v2.1.119.') 'Expected stale official install script result to be logged before npm fallback.'
}

Run-Test 'Update-Claude reports npm failure after all Claude update paths fail' {
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Get-LatestClaudeVersion() { return '2.1.119' }
  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.119'; Source = 'stable'; Stable = '2.1.119'; Npm = $null; Repo = $null } }

  function Invoke-ClaudeNativeUpdate() {
    throw 'native update failed'
  }

  function Update-ClaudeViaInstallScript() {
    throw 'install script failed: ECONNREFUSED'
  }

  function Update-ClaudeViaNpm() {
    throw 'npm install failed with exit code 1'
  }

  try {
    Update-Claude
  } catch {
    $message = $_.Exception.Message
    Assert-True $message.Contains('install script failed: ECONNREFUSED') 'Expected Claude update failure to include the official install script error.'
    Assert-True $message.Contains('npm install failed with exit code 1') 'Expected Claude update failure to include the npm fallback error.'
    Assert-True $message.Contains("Try 'claude update'") 'Expected Claude update failure to keep the native recovery hint.'
    return
  }

  throw 'Expected Update-Claude to throw when all Claude update paths fail.'
}

Run-Test 'Invoke-ClaudeNativeUpdate uses bounded timeout for claude update' {
  function Get-Command([string]$Name, [object[]]$ArgumentList) {
    if ($Name -eq 'claude') { return [pscustomobject]@{ Source = 'C:\Tools\claude.exe' } }
    return $null
  }

  $script:CapturedClaudePath = ''
  $script:CapturedTimeout = 0

  function Invoke-ClaudeNativeUpdateProcess([string]$ClaudePath, [int]$TimeoutSeconds) {
    $script:CapturedClaudePath = $ClaudePath
    $script:CapturedTimeout = $TimeoutSeconds
    throw 'simulated timeout'
  }

  $env:CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS = '17'

  Assert-ThrowsContains { Invoke-ClaudeNativeUpdate } 'simulated timeout' 'Expected native Claude update process failures to surface.'
  Assert-Equal $script:CapturedClaudePath 'C:\Tools\claude.exe' 'Expected native Claude update to invoke the resolved claude executable.'
  Assert-Equal $script:CapturedTimeout 17 'Expected native Claude update to use the configured timeout.'
}

Run-Test 'Report-PostUpdate recommends all supported Claude recovery steps' {
  function Get-AndPrintLocal([scriptblock]$GetLocal) {
    return '2.1.84'
  }

  Report-PostUpdate 'Claude Code' '2.1.91' { '2.1.84' }

  Assert-True ($script:CapturedWarnings -contains 'Update may have failed (still older than latest).') 'Expected stale-version warning after Claude post-update recheck.'
  Assert-True ($script:CapturedWarnings -contains 'Tip: try claude update') 'Expected native Claude update remediation hint.'
  Assert-True ($script:CapturedWarnings -contains 'Tip: if needed, reinstall via irm https://claude.ai/install.ps1 | iex') 'Expected official Claude install script remediation hint.'
  Assert-True ($script:CapturedWarnings -contains 'Tip: fallback via npm install -g @anthropic-ai/claude-code@latest') 'Expected Claude post-update guidance to include npm fallback remediation.'
}



Run-Test 'Update-Claude skips native updater when stable channel is behind target' {

  function Repair-ToolUserPath([string]$ToolId) { return $true }

  function Get-ClaudeLatestInfo() { return @{ Target = '2.1.196'; Source = 'npm'; Stable = '2.1.185'; Npm = '2.1.196'; Repo = '2.1.196' } }

  function Get-LocalClaudeVersion() { return '2.1.196' }



  $script:NativeUpdateCalls = 0

  $script:InstallScriptCalls = 0



  function Invoke-ClaudeNativeUpdate() { $script:NativeUpdateCalls += 1 }

  function Update-ClaudeViaInstallScript() { $script:InstallScriptCalls += 1 }

  function Update-ClaudeViaNpm() { throw 'npm should not run' }



  Update-Claude



  Assert-Equal $script:NativeUpdateCalls 0 'Expected Claude native updater to be skipped when stable is behind npm target.'

  Assert-Equal $script:InstallScriptCalls 1 'Expected official install script to be tried directly when stable is behind npm target.'

  Assert-True ($script:CapturedInfos -contains 'Skipping native Claude update: stable channel v2.1.185 is older than target v2.1.196.') 'Expected an informational skip message for stale stable channel.'

}





Run-Test 'Update-Claude gates official remote install script in auto mode' {
  $previousAuto = $script:AutoMode
  $previousAllow = $env:CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT
  try {
    $script:AutoMode = $true
    Remove-Item Env:CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT -ErrorAction SilentlyContinue

    function Repair-ToolUserPath([string]$ToolId) { return $true }
    function Get-ClaudeLatestInfo() { return @{ Target = '2.1.196'; Source = 'npm'; Stable = '2.1.185'; Npm = '2.1.196'; Repo = '2.1.196' } }
    function Get-LocalClaudeVersion() { return '2.1.195' }
    function Invoke-ClaudeNativeUpdate() { throw 'native should be skipped' }
    function Get-Text([string]$Uri) { throw 'remote script should not be downloaded in auto mode without opt-in' }

    $script:NpmInstallCalls = 0
    function Update-ClaudeViaNpm() { $script:NpmInstallCalls += 1 }

    Update-Claude

    Assert-Equal $script:NpmInstallCalls 1 'Expected Claude update to fall back to npm when auto mode declines official remote script execution.'
    Assert-True ($script:CapturedWarnings -contains '[SECURITY] Auto mode: skipping remote script execution from https://claude.ai/install.ps1. Set CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT=1 to allow.') 'Expected auto mode to warn when official Claude remote script is skipped.'
  } finally {
    $script:AutoMode = $previousAuto
    if ($null -eq $previousAllow) { Remove-Item Env:CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT -ErrorAction SilentlyContinue } else { $env:CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT = $previousAllow }
  }
}

Run-Test 'Test-ClaudeNativeUpdateAllowed rejects stale stable channel' {

  Assert-True (-not (Test-ClaudeNativeUpdateAllowed '2.1.196' '2.1.185')) 'Expected native update to be rejected when stable is behind target.'

  Assert-True (Test-ClaudeNativeUpdateAllowed '2.1.185' '2.1.185') 'Expected native update to be allowed when stable reaches target.'

}



Write-Host '[PASS] All latest version source regression tests passed.' -ForegroundColor Green
