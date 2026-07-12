$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

function Assert-ThrowsContains([scriptblock]$Action, [string]$Expected, [string]$Message) {
  try { & $Action } catch {
    if ($_.Exception.Message -notlike "*$Expected*") { throw "$Message`nActual: $($_.Exception.Message)" }
    return
  }
  throw "$Message`nExpected an exception containing: $Expected"
}

$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. (Join-Path $repoRoot 'install.ps1')

function Run-Test([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Host "[PASS] $Name" -ForegroundColor Green }
  catch { Write-Host "[FAIL] $Name" -ForegroundColor Red; throw }
}

Run-Test 'main resolves to immutable commit SHA' {
  $old = $env:CHECK_AI_CLI_REF
  try {
    $env:CHECK_AI_CLI_REF = 'main'
    function Get-LatestMainCommitRef { return '0123456789abcdef0123456789abcdef01234567' }
    Assert-Equal (Get-ResolvedRef) '0123456789abcdef0123456789abcdef01234567' 'Expected main to resolve to a commit.'
  } finally { $env:CHECK_AI_CLI_REF = $old }
}

Run-Test 'mutable fallback fails closed' {
  $old = $env:CHECK_AI_CLI_REF
  try {
    Remove-Item Env:CHECK_AI_CLI_REF -ErrorAction SilentlyContinue
    function Get-LatestStableRef { return $null }
    function Get-LatestMainCommitRef { return $null }
    Assert-ThrowsContains { Get-ResolvedRef } 'Refusing mutable main fallback' 'Expected immutable resolution failure to stop installation.'
  } finally { $env:CHECK_AI_CLI_REF = $old }
}

Run-Test 'manifest pin accepts matching digest and rejects mismatch' {
  $old = $env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($tmp, 'manifest', [Text.Encoding]::ASCII)
    $actual = Get-Sha256 $tmp
    $env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 = $actual
    Assert-ManifestAnchor $tmp
    $env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 = ('0' * 64)
    Assert-ThrowsContains { Assert-ManifestAnchor $tmp } 'does not match' 'Expected a bad manifest pin to fail.'
  } finally {
    $env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 = $old
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

Run-Test 'manifest parser rejects traversal and malformed hashes' {
  $validHash = ('a' * 64)
  Assert-ThrowsContains { Read-Manifest "$validHash  ../install.ps1" } 'Invalid distribution path' 'Expected traversal to fail.'
  Assert-ThrowsContains { Read-Manifest "abc  install.ps1" } 'Invalid SHA-256' 'Expected malformed hash to fail.'
}

Write-Host '[PASS] All checksum chain regression tests passed.' -ForegroundColor Green
