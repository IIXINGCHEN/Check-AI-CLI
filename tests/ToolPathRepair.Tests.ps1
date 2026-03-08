$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-StartsWith([string]$Actual, [string]$ExpectedPrefix, [string]$Message) {
  if (($null -eq $Actual) -or (-not $Actual.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "$Message`nExpected prefix: $ExpectedPrefix`nActual: $Actual"
  }
}

function Reset-TestState {
  $script:StoredUserPath = ''
  $script:CapturedInfos = @()
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

function Write-Info([string]$Message) {
  $script:CapturedInfos += $Message
}

Run-Test 'Get-LocalClaudeVersion repairs npm global bin into User PATH' {
  $originalPath = $env:PATH
  try {
    $script:ResolvedClaude = @{ Name = 'claude'; Version = $null; Source = $null }
    $env:PATH = 'C:\Windows\System32;C:\Legacy'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
      $script:ResolvedClaude = @{ Name = 'claude'; Version = '0.9.0'; Source = 'C:\Users\Tester\AppData\Roaming\npm\claude.cmd' }
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'claude') { return @('C:\Users\Tester\AppData\Roaming\npm') }
      return @()
    }

    function Get-CommandVersionInfo([string]$CommandName) {
      if ($CommandName -in @('claude', 'claude-code')) { return $script:ResolvedClaude }
      return @{ Name = $CommandName; Version = $null; Source = $null }
    }

    $version = Get-LocalClaudeVersion

    Assert-Equal $version '0.9.0' 'Expected Claude version detection to recover after npm PATH repair.'
    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\AppData\Roaming\npm' 'Expected User PATH to prioritize npm global bin for Claude.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\AppData\Roaming\npm' 'Expected process PATH to prioritize npm global bin for Claude.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Get-LocalFactoryVersion repairs user bin before probing droid' {
  $originalPath = $env:PATH
  try {
    $script:ResolvedDroid = @{ Name = 'droid'; Version = $null; Source = $null }
    $script:ResolvedFactory = @{ Name = 'factory'; Version = $null; Source = $null }
    $env:PATH = 'C:\Windows\System32;C:\Legacy'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
      $script:ResolvedDroid = @{ Name = 'droid'; Version = '2.3.4'; Source = 'C:\Users\Tester\bin\droid.exe' }
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'factory') { return @('C:\Users\Tester\bin') }
      return @()
    }

    function Get-CommandVersionInfo([string]$CommandName) {
      switch ($CommandName) {
        'droid' { return $script:ResolvedDroid }
        'factory' { return $script:ResolvedFactory }
        default { return @{ Name = $CommandName; Version = $null; Source = $null } }
      }
    }

    $version = Get-LocalFactoryVersion

    Assert-Equal $version '2.3.4' 'Expected Factory version detection to recover after repairing ~/bin.'
    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\bin' 'Expected User PATH to prioritize ~/bin for Factory CLI.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\bin' 'Expected process PATH to prioritize ~/bin for Factory CLI.'
  } finally {
    $env:PATH = $originalPath
  }
}

Write-Host '[PASS] All tool PATH repair regression tests passed.' -ForegroundColor Green
