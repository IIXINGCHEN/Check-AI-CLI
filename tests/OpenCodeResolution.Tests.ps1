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

function Assert-StartsWith([string]$Actual, [string]$ExpectedPrefix, [string]$Message) {
  if (($null -eq $Actual) -or (-not $Actual.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "$Message`nExpected prefix: $ExpectedPrefix`nActual: $Actual"
  }
}

function Reset-TestState {
  $script:CapturedWarnings = @()
  $script:OriginalNpmRegistry = $null
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

Run-Test 'Get-LocalOpenCodeVersion repairs old shim resolution to prefer standalone install' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Tools;C:\Legacy'
    $env:PATH = 'C:\Windows\System32;C:\Users\Tester\AppData\Roaming\npm;C:\Legacy'
    $script:ResolvedOpenCode = @{ Name = 'opencode'; Version = '1.2.17'; Source = 'C:\Users\Tester\AppData\Roaming\npm\opencode.ps1' }

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
      $script:ResolvedOpenCode = @{ Name = 'opencode'; Version = '1.2.21'; Source = 'C:\Users\Tester\.opencode\bin\opencode.exe' }
    }

    function Get-OpenCodeUserInstallPath() {
      return 'C:\Users\Tester\.opencode\bin\opencode.exe'
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'opencode') { return @('C:\Users\Tester\.opencode\bin') }
      return @()
    }

    function Get-OpenCodeResolvedInfo() {
      return $script:ResolvedOpenCode
    }

    function Get-OpenCodeVersionAtPath([string]$Path) {
      return '1.2.21'
    }

    $version = Get-LocalOpenCodeVersion

    Assert-Equal $version '1.2.21' 'Expected old shim resolution to be replaced by the standalone OpenCode install.'
    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\.opencode\bin' 'Expected User PATH to prioritize the standalone OpenCode bin directory.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\.opencode\bin' 'Expected current process PATH to prioritize the standalone OpenCode bin directory.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Ensure-UserPathPrefers moves target directory to the front of user and process PATH' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Tools;C:\Users\Tester\.opencode\bin;C:\Other'
    $env:PATH = 'C:\Windows\System32;C:\Users\Tester\.opencode\bin;C:\Legacy'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'opencode') { return @('C:\Users\Tester\.opencode\bin') }
      return @()
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    Ensure-UserPathPrefers 'C:\Users\Tester\.opencode\bin'

    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\.opencode\bin' 'Expected persisted User PATH to prioritize the OpenCode bin directory.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\.opencode\bin' 'Expected current process PATH to prioritize the OpenCode bin directory.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Get-LocalOpenCodeVersion repairs PATH when standalone install exists but command is unresolved' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Tools'
    $env:PATH = 'C:\Windows\System32;C:\Legacy'
    $script:ResolvedOpenCode = @{ Name = 'opencode'; Version = $null; Source = $null }

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
      $script:ResolvedOpenCode = @{ Name = 'opencode'; Version = '1.2.21'; Source = 'C:\Users\Tester\.opencode\bin\opencode.exe' }
    }

    function Get-OpenCodeUserInstallPath() {
      return 'C:\Users\Tester\.opencode\bin\opencode.exe'
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'opencode') { return @('C:\Users\Tester\.opencode\bin') }
      return @()
    }

    function Get-OpenCodeResolvedInfo() {
      return $script:ResolvedOpenCode
    }

    function Get-OpenCodeVersionAtPath([string]$Path) {
      return '1.2.21'
    }

    $version = Get-LocalOpenCodeVersion

    Assert-Equal $version '1.2.21' 'Expected Get-LocalOpenCodeVersion to recover by promoting the standalone OpenCode install into PATH.'
    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\.opencode\bin' 'Expected User PATH repair to persist the OpenCode bin directory first.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\.opencode\bin' 'Expected current process PATH repair to prioritize the OpenCode bin directory.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Restore-NpmRegistry does not leak Set-NpmRegistry return values' {
  function Get-NpmRegistry() {
    return 'https://registry.npmjs.org'
  }

  function Set-NpmRegistry([string]$Registry) {
    return $true
  }

  $script:OriginalNpmRegistry = 'https://registry.npmmirror.com'
  $output = @(Restore-NpmRegistry)

  Assert-Equal $output.Count 0 'Expected Restore-NpmRegistry to avoid emitting helper return values.'
}

Write-Host '[PASS] All OpenCode resolution regression tests passed.' -ForegroundColor Green
