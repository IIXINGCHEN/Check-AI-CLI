$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\Get-ReleaseAssets.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
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

Run-Test 'Get-ReleaseAssetPaths returns expected core assets' {
  $assets = Get-ReleaseAssetPaths

  Assert-True ($assets -contains 'checksums.sha256') 'Expected release assets to include checksums.sha256.'
  Assert-True ($assets -contains 'install.ps1') 'Expected release assets to include install.ps1.'
  Assert-True ($assets -contains 'scripts/Check-AI-CLI-Versions.ps1') 'Expected release assets to include the PowerShell main script.'
  Assert-True ($assets -contains 'scripts/check-ai-cli-versions.sh') 'Expected release assets to include the shell main script.'
}

Run-Test 'Get-ReleaseIntroText mentions checksums and tag placeholder' {
  $text = Get-ReleaseIntroText 'v1.2.3'

  Assert-True ($text.Contains('v1.2.3')) 'Expected release intro to include the release tag.'
  Assert-True ($text.Contains('checksums.sha256')) 'Expected release intro to mention checksums.sha256.'
}

Write-Host '[PASS] All release asset metadata tests passed.' -ForegroundColor Green
