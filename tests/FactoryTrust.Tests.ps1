$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$oldSkipMain = $env:CHECK_AI_CLI_SKIP_MAIN
$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. (Join-Path $repoRoot 'install.ps1')
$env:CHECK_AI_CLI_SKIP_MAIN = $oldSkipMain
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-False([bool]$Condition, [string]$Message) {
  if ($Condition) { throw $Message }
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  & $Body
  Write-Host "[PASS] $Name" -ForegroundColor Green
}

Run-Test 'Factory download base accepts only official HTTPS hosts' {
  Assert-True (Test-FactoryDownloadBaseUrl 'https://downloads.factory.ai') 'Expected downloads.factory.ai to be accepted.'
  Assert-True (Test-FactoryDownloadBaseUrl 'https://app.factory.ai/releases') 'Expected app.factory.ai to be accepted.'
  Assert-False (Test-FactoryDownloadBaseUrl 'http://downloads.factory.ai') 'HTTP Factory URL must be rejected.'
  Assert-False (Test-FactoryDownloadBaseUrl 'https://downloads.factory.ai.evil.test') 'Lookalike Factory host must be rejected.'
  Assert-False (Test-FactoryDownloadBaseUrl 'https://user:pass@downloads.factory.ai') 'Factory URL with credentials must be rejected.'
  Assert-False (Test-FactoryDownloadBaseUrl 'https://downloads.factory.ai?redirect=evil') 'Factory URL with query parameters must be rejected.'
}

Run-Test 'Latest release resolver rejects an invalid release tag' {
  $oldRef = $env:CHECK_AI_CLI_REF
  $env:CHECK_AI_CLI_REF = ''
  function Invoke-RestMethod { return [pscustomobject]@{ tag_name = 'not-a-release'; object = [pscustomobject]@{ sha = 'unused' } } }
  function Get-LatestMainCommitRef { return ('a' * 40) }

  try { $resolved = Get-ResolvedRef } finally { $env:CHECK_AI_CLI_REF = $oldRef }

  Assert-True ($resolved -eq ('a' * 40)) 'Expected invalid latest release tag to fall back to the immutable main commit.'
}
