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

Run-Test 'Factory curl fallback pins TLS 1.2 for Schannel proxies' {
  $args = Get-CurlDownloadArguments 'https://downloads.factory.ai/cli' 'droid.exe'
  Assert-True ($args -contains '--tlsv1.2') 'Expected curl fallback to pin TLS 1.2 for Schannel proxy compatibility.'
  Assert-True ($args -contains '--continue-at' -and $args[$args.IndexOf('--continue-at') + 1] -eq '-') 'Expected curl fallback to resume partial downloads.'
  Assert-True ((Get-CurlDownloadArguments 'https://downloads.factory.ai/cli' 'droid.exe' $true) -contains '--noproxy') 'Expected direct curl fallback to bypass the failing proxy.'
}

Run-Test 'HTTP proxy propagation does not force curl through ALL_PROXY' {
  $oldAllProxy = $env:ALL_PROXY
  $oldLowerAllProxy = $env:all_proxy
  try {
    $env:ALL_PROXY = 'sentinel'
    $env:all_proxy = 'sentinel'
    [void](Set-EffectiveProxyEnvironment @{ Url = 'http://127.0.0.1:7890'; IsHttpProxy = $true; NoProxy = $null })
    Assert-True ([string]::IsNullOrWhiteSpace($env:ALL_PROXY)) 'HTTP proxy must not be exported as ALL_PROXY for curl.'
  } finally {
    $env:ALL_PROXY = $oldAllProxy
    $env:all_proxy = $oldLowerAllProxy
  }
}

Run-Test 'Tool lifecycle adapter owns update verification' {
  $oldAuto = $script:AutoMode
  $script:AutoMode = $true
  $state = @{ Version = '1.0.0'; Updates = 0 }
  try {
    $result = Invoke-ToolLifecycle @{
      Title = 'Fixture Tool'
      GetLatest = { '1.1.0' }
      GetLocal = { $state.Version }
      Update = { $state.Updates++; $state.Version = '1.1.0' }
    }
  } finally {
    $script:AutoMode = $oldAuto
  }
  Assert-True ($result.Updated -eq $true) 'Expected lifecycle to invoke the update adapter.'
  Assert-True ($result.Failed -eq $false) 'Expected lifecycle to report verified success.'
  Assert-True ($state.Updates -eq 1 -and $state.Version -eq '1.1.0') 'Expected adapter update and post-update readback.'
}

Run-Test 'Installed resolver returns source and kind metadata' {
  $candidate = Get-InstalledToolCandidate 'factory' @('droid', 'factory')
  Assert-True ($candidate.Version -eq '0.173.0') 'Expected resolver to find the installed Factory version.'
  Assert-True ($candidate.Path -and $candidate.Source -and $candidate.Kind) 'Expected resolver to return path, source, and kind metadata.'
}

Run-Test 'Installed resolver read does not mutate PATH' {
  $oldPath = $env:PATH
  try {
    $null = Get-InstalledToolCandidate 'factory' @('droid', 'factory')
    Assert-True ($env:PATH -eq $oldPath) 'Expected resolver read to restore PATH exactly.'
  } finally {
    $env:PATH = $oldPath
  }
}

Run-Test 'Release target policy selects the highest available source' {
  $target = Select-ReleaseTarget 'Fixture Tool' @(
    @{ Label = 'official'; Version = '1.2.0' }
    @{ Label = 'npm'; Version = '1.1.0' }
  )
  Assert-True ($target -eq '1.2.0') 'Expected release policy to choose the highest available target.'
}

Run-Test 'Latest release resolver rejects an invalid release tag' {
  $oldRef = $env:CHECK_AI_CLI_REF
  $env:CHECK_AI_CLI_REF = ''
  function Invoke-RestMethod { return [pscustomobject]@{ tag_name = 'not-a-release'; object = [pscustomobject]@{ sha = 'unused' } } }
  function Get-LatestMainCommitRef { return ('a' * 40) }

  try { $resolved = Get-ResolvedRef } finally { $env:CHECK_AI_CLI_REF = $oldRef }

  Assert-True ($resolved -eq ('a' * 40)) 'Expected invalid latest release tag to fall back to the immutable main commit.'
}
