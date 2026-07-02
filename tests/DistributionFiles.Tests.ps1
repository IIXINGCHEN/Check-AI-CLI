$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\DistributionFiles.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
  if (-not $Text.Contains($Expected)) {
    throw "$Message`nExpected substring: $Expected"
  }
}

function Assert-SequenceEqual([string[]]$Actual, [string[]]$Expected, [string]$Message) {
  $actualText = ($Actual -join "`n")
  $expectedText = ($Expected -join "`n")
  if ($actualText -ne $expectedText) {
    throw "$Message`nExpected:`n$expectedText`nActual:`n$actualText"
  }
}

function Get-ChecksumManifestPaths() {
  Get-Content -LiteralPath (Join-Path $repoRoot 'checksums.sha256') |
    Where-Object { $_ -and ($_ -notmatch '^#') } |
    ForEach-Object { ($_ -split '\s+', 2)[1].Trim() }
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

Run-Test 'distribution file list is the canonical checksum payload source' {
  $distribution = @(Get-DistributionFilePaths)

  Assert-True ($distribution -contains 'distribution-files.txt') 'Expected distribution list to include itself for integrity verification.'
  Assert-True (-not ($distribution -contains 'checksums.sha256')) 'checksums.sha256 cannot be part of its own checksum payload.'
  Assert-SequenceEqual (Get-ChecksumTargetPaths) $distribution 'Checksum targets must come from the distribution file list.'
  Assert-SequenceEqual (Get-ChecksumManifestPaths) $distribution 'checksums.sha256 must contain exactly the distribution file list paths.'
}

Run-Test 'release assets are checksums plus distribution payload' {
  $expected = @('checksums.sha256') + @(Get-DistributionFilePaths)
  Assert-SequenceEqual (Get-ReleaseAssetPaths) $expected 'Release assets must derive from the distribution file list.'
}

Run-Test 'cache purge surfaces consume the distribution file list' {
  $workflow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/purge-cdn-cache.yml')
  $psTool = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tools/purge-github-cache.ps1')
  $shTool = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tools/purge-github-cache.sh')

  Assert-Contains $workflow 'distribution-files.txt' 'Expected purge workflow to read the canonical distribution file list.'
  Assert-Contains $psTool 'Get-AllPurgeFilePaths' 'Expected PowerShell purge tool to use the shared distribution helper.'
  Assert-Contains $shTool 'distribution-files.txt' 'Expected shell purge tool to read the canonical distribution file list.'
}

Write-Host '[PASS] All distribution file consistency tests passed.' -ForegroundColor Green
