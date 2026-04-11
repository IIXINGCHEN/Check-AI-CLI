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

function Reset-TestState {
  $script:CapturedWarnings = @()
  $env:CHECK_AI_CLI_OPENCODE_VERSION = ''
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

Run-Test 'Get-LatestClaudeVersion falls back to repo when bootstrap stable is unavailable' {
  function Get-ClaudeRepoLatestVersion() {
    return '2.1.72'
  }

  function Get-ClaudeBootstrapStableVersion() {
    return $null
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '2.1.69'
  }

  $version = Get-LatestClaudeVersion

  Assert-Equal $version '2.1.72' 'Expected Claude latest version to fall back to GitHub repo when bootstrap stable is unavailable.'
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

Run-Test 'Update-Claude prefers official bootstrap before npm fallback' {
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

Run-Test 'Report-PostUpdate recommends native Claude recovery steps instead of npm' {
  function Get-AndPrintLocal([scriptblock]$GetLocal) {
    return '2.1.84'
  }

  Report-PostUpdate 'Claude Code' '2.1.91' { '2.1.84' }

  Assert-True ($script:CapturedWarnings -contains 'Update may have failed (still older than latest).') 'Expected stale-version warning after Claude post-update recheck.'
  Assert-True ($script:CapturedWarnings -contains 'Tip: try claude update') 'Expected native Claude update remediation hint.'
  Assert-True ($script:CapturedWarnings -contains 'Tip: if needed, reinstall via irm https://claude.ai/install.ps1 | iex') 'Expected official Claude install script remediation hint.'
}

Write-Host '[PASS] All latest version source regression tests passed.' -ForegroundColor Green
