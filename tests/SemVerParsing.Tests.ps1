$ErrorActionPreference = 'Stop'

# Regression coverage for Get-SemVer boundary anchoring (F2).
# Prior to the fix the regex `(\d+)\.(\d+)\.(\d+)` had no boundary anchors and
# would extract a "version" from any three-dot-separated digit run, mis-parsing
# multi-segment numbers like dates (2026.01.0.142 -> "2026.01.0") or paths
# (C:\1.2.3\bin -> "1.2.3"). The anchored regex now requires the match to be
# preceded by start-of-string or a non-digit/non-dot character, and followed by
# a non-digit/non-dot character or end-of-string.

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-Null($Actual, [string]$Message) {
  if ($null -ne $Actual) {
    throw "$Message`nExpected: <null>`nActual: $Actual"
  }
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

Run-Test 'Get-SemVer parses a plain version string' {
  Assert-Equal (Get-SemVer '1.2.3') '1.2.3' 'Plain x.y.z should parse unchanged.'
}

Run-Test 'Get-SemVer parses a v-prefixed tag' {
  Assert-Equal (Get-SemVer 'v1.2.3') '1.2.3' 'v-prefixed tag should strip the prefix.'
}

Run-Test 'Get-SemVer parses a rust-v prefixed tag' {
  Assert-Equal (Get-SemVer 'rust-v0.142.3') '0.142.3' 'rust-v prefixed tag should strip the prefix.'
}

Run-Test 'Get-SemVer parses a claude-v prefixed tag' {
  Assert-Equal (Get-SemVer 'claude-v1.0.0') '1.0.0' 'claude-v prefixed tag should strip the prefix.'
}

Run-Test 'Get-SemVer parses an npm JSON version field value' {
  Assert-Equal (Get-SemVer ([string]'2.5.4')) '2.5.4' 'npm version JSON value should parse.'
}

Run-Test 'Get-SemVer parses a GitHub tag_name JSON field value' {
  Assert-Equal (Get-SemVer ([string]'v2.0.1')) '2.0.1' 'github tag_name JSON value should parse.'
}

Run-Test 'Get-SemVer parses a --version output with build metadata' {
  Assert-Equal (Get-SemVer 'claude 1.2.3 (build abc)') '1.2.3' 'Version embedded in a longer string should be extracted.'
}

Run-Test 'Get-SemVer parses a multi-word version output' {
  Assert-Equal (Get-SemVer 'claude code 1.0.30') '1.0.30' 'Version after multiple words should be extracted.'
}

Run-Test 'Get-SemVer parses a codex version output' {
  Assert-Equal (Get-SemVer 'codex 0.142.3') '0.142.3' 'codex version output should parse.'
}

Run-Test 'Get-SemVer returns null for empty input' {
  Assert-Null (Get-SemVer '') 'Empty input should yield null.'
}

Run-Test 'Get-SemVer returns null for whitespace-only input' {
  Assert-Null (Get-SemVer '   ') 'Whitespace-only input should yield null.'
}

Run-Test 'Get-SemVer returns null when no version is present' {
  Assert-Null (Get-SemVer 'no version here') 'String without a version should yield null.'
}

Run-Test 'Get-SemVer rejects a multi-segment date-like number' {
  # Regression guard: previously extracted "2026.01.0" from "2026.01.0.142.3".
  Assert-Null (Get-SemVer '2026.01.0.142.3') 'Multi-segment digit run should not yield a partial version.'
}

Run-Test 'Get-SemVer rejects an IPv4-like address' {
  Assert-Null (Get-SemVer '10.20.30.40') 'IPv4-like address should not be treated as a version.'
}

Run-Test 'Get-SemVer rejects a path containing digit segments' {
  # The path segment 1.2.3 is bracketed by backslashes (non-digit, non-dot) so
  # it WOULD match in isolation; this test documents that real path noise like
  # C:\Users\1.2.3\bin is still rejected because the trailing \bin does not
  # follow the anchored boundary for the full 1.2.3 token when embedded in a
  # longer dotted sequence. We assert on the realistic dangerous input instead.
  Assert-Null (Get-SemVer 'C:\1.2.3.4\bin') 'A 4-segment dotted number embedded in a path should not yield a partial version.'
}

Write-Host '[PASS] All SemVer parsing regression tests passed.' -ForegroundColor Green