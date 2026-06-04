$ErrorActionPreference = 'Stop'

function Get-DistributionRepoRoot() {
  return (Split-Path -Parent $PSScriptRoot)
}

function Get-DistributionListPath([string]$Root = (Get-DistributionRepoRoot)) {
  return (Join-Path $Root 'distribution-files.txt')
}

function Read-DistributionFileList([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Missing distribution file list: $Path" }

  $seen = @{}
  $paths = @()
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $t = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith('#')) { continue }
    if ([IO.Path]::IsPathRooted($t) -or $t.Contains('\') -or $t.Contains('..')) {
      throw "Invalid distribution path: $t"
    }
    if (-not $seen.ContainsKey($t)) {
      $seen[$t] = $true
      $paths += $t
    }
  }
  return $paths
}

function Get-DistributionFilePaths([string]$Root = (Get-DistributionRepoRoot)) {
  $paths = @(Read-DistributionFileList (Get-DistributionListPath $Root))
  if ($paths.Count -eq 0) { throw 'distribution-files.txt has no paths.' }
  if ($paths -contains 'checksums.sha256') { throw 'checksums.sha256 cannot checksum itself.' }
  if (-not ($paths -contains 'distribution-files.txt')) {
    throw 'distribution-files.txt must include itself for integrity verification.'
  }
  foreach ($path in $paths) {
    $full = Join-Path $Root $path
    if (-not (Test-Path -LiteralPath $full)) { throw "Missing distribution file: $path" }
  }
  return $paths
}

function Get-ChecksumTargetPaths([string]$Root = (Get-DistributionRepoRoot)) {
  return @(Get-DistributionFilePaths $Root)
}

function Get-ReleaseAssetPaths([string]$Root = (Get-DistributionRepoRoot)) {
  return @('checksums.sha256') + @(Get-DistributionFilePaths $Root)
}

function Get-CriticalPurgeFilePaths() {
  return @('checksums.sha256')
}

function Get-AllPurgeFilePaths([string]$Root = (Get-DistributionRepoRoot)) {
  return @(Get-ReleaseAssetPaths $Root)
}
