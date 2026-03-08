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

Run-Test 'Get-LatestClaudeVersion prefers official repo release over other official channels' {
  function Get-ClaudeRepoLatestVersion() {
    return '2.1.72'
  }

  function Get-ClaudeBootstrapStableVersion() {
    return '2.1.71'
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    return '2.1.69'
  }

  $version = Get-LatestClaudeVersion

  Assert-Equal $version '2.1.72' 'Expected Claude latest version to come from the official GitHub release channel.'
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
  $script:BootstrapCalls = 0
  $script:NpmCalls = 0

  function Update-ClaudeViaBootstrap() {
    $script:BootstrapCalls += 1
  }

  function Invoke-NpmInstallGlobal([string]$PackageSpec) {
    $script:NpmCalls += 1
  }

  Update-Claude

  Assert-Equal $script:BootstrapCalls 1 'Expected Claude update to try the official bootstrap first.'
  Assert-Equal $script:NpmCalls 0 'Expected npm fallback to stay unused when the official bootstrap succeeds.'
}

Write-Host '[PASS] All latest version source regression tests passed.' -ForegroundColor Green
