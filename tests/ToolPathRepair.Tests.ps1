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

function Assert-NotContains([string]$Actual, [string]$Unexpected, [string]$Message) {
  if (($null -ne $Actual) -and $Actual.Contains($Unexpected)) {
    throw "$Message`nUnexpected substring: $Unexpected`nActual: $Actual"
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

Run-Test 'Ensure-UserPathContains does not log absolute PATH entries' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Tools'
    $env:PATH = 'C:\Tools'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    Ensure-UserPathContains 'C:\Users\Tester\AppData\Roaming\npm'

    Assert-Equal $script:CapturedInfos.Count 1 'Expected one info log when User PATH is changed.'
    Assert-NotContains $script:CapturedInfos[0] 'C:\Users\Tester' 'Expected PATH add log to avoid absolute local paths.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Ensure-UserPathPrefers does not log absolute PATH entries' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Tools;C:\Users\Tester\AppData\Roaming\npm'
    $env:PATH = $script:StoredUserPath

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    Ensure-UserPathPrefers 'C:\Users\Tester\AppData\Roaming\npm'

    Assert-Equal $script:CapturedInfos.Count 1 'Expected one info log when User PATH is reordered.'
    Assert-NotContains $script:CapturedInfos[0] 'C:\Users\Tester' 'Expected PATH reorder log to avoid absolute local paths.'
  } finally {
    $env:PATH = $originalPath
  }
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

Run-Test 'Get-PreferredToolPathDirs prioritizes Claude native user bin over npm global bin on Windows' {
  $originalUserProfile = $env:USERPROFILE
  try {
    $env:USERPROFILE = 'C:\Users\Tester'

    function Get-NpmGlobalBinDir() {
      return 'C:\Users\Tester\AppData\Roaming\npm'
    }

    function Test-Path([string]$Path, [string]$LiteralPath) {
      $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
      return $target -like 'C:\Users\Tester\.local\bin*'
    }

    $dirs = @(Get-PreferredToolPathDirs 'claude')

    Assert-Equal $dirs.Count 2 'Expected Claude path repair candidates to include native user bin and npm global bin.'
    Assert-Equal $dirs[0] 'C:\Users\Tester\.local\bin' 'Expected Claude native user bin to outrank npm global bin on Windows.'
    Assert-Equal $dirs[1] 'C:\Users\Tester\AppData\Roaming\npm' 'Expected npm global bin to remain as Claude fallback candidate.'
  } finally {
    $env:USERPROFILE = $originalUserProfile
  }
}

Run-Test 'Get-LocalClaudeVersion repairs native user bin before npm shim on Windows' {
  $originalPath = $env:PATH
  $originalUserProfile = $env:USERPROFILE
  try {
    $env:USERPROFILE = 'C:\Users\Tester'
    $script:StoredUserPath = 'C:\Tools'
    $script:ResolvedClaude = @{ Name = 'claude'; Version = '0.9.0'; Source = 'C:\Users\Tester\AppData\Roaming\npm\claude.cmd' }
    $env:PATH = 'C:\Windows\System32;C:\Users\Tester\AppData\Roaming\npm;C:\Legacy'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    function Get-NpmGlobalBinDir() {
      return 'C:\Users\Tester\AppData\Roaming\npm'
    }

    function Test-Path([string]$Path, [string]$LiteralPath) {
      $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
      return $target -like 'C:\Users\Tester\.local\bin*'
    }

    function Get-CommandVersionInfo([string]$CommandName) {
      if ($CommandName -in @('claude', 'claude-code')) {
        $firstPath = ($env:PATH -split ';')[0]
        if ($firstPath.EndsWith('.local\bin', [System.StringComparison]::OrdinalIgnoreCase)) {
          return @{ Name = 'claude'; Version = '2.1.84'; Source = 'C:\Users\Tester\.local\bin\claude' }
        }
        if ($firstPath.EndsWith('npm', [System.StringComparison]::OrdinalIgnoreCase)) {
          return @{ Name = 'claude'; Version = '0.9.0'; Source = 'C:\Users\Tester\AppData\Roaming\npm\claude.cmd' }
        }
      }
      return @{ Name = $CommandName; Version = $null; Source = $null }
    }

    $version = Get-LocalClaudeVersion

    Assert-Equal $version '2.1.84' 'Expected Claude version detection to prefer the native Windows install over an older npm shim.'
    Assert-StartsWith $script:StoredUserPath 'C:\Users\Tester\.local\bin' 'Expected User PATH to prioritize Claude native user bin.'
    Assert-StartsWith $env:PATH 'C:\Users\Tester\.local\bin' 'Expected process PATH to prioritize Claude native user bin.'
  } finally {
    $env:PATH = $originalPath
    $env:USERPROFILE = $originalUserProfile
  }
}

Run-Test 'Get-LocalClaudeVersion prefers newer npm fallback over older native install' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'native-bin;npm-bin'
    $env:PATH = 'native-bin;npm-bin;legacy-bin'

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'claude') { return @('native-bin', 'npm-bin') }
      return @()
    }

    function Get-CommandVersionInfo([string]$CommandName) {
      if ($CommandName -notin @('claude', 'claude-code')) {
        return @{ Name = $CommandName; Version = $null; Source = $null }
      }
      $firstPath = ($env:PATH -split ';')[0]
      if ($firstPath.EndsWith('npm-bin', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Name = $CommandName; Version = '2.1.152'; Source = 'npm-bin/claude.cmd' }
      }
      if ($firstPath.EndsWith('native-bin', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Name = $CommandName; Version = '2.1.141'; Source = 'native-bin/claude' }
      }
      return @{ Name = $CommandName; Version = $null; Source = $null }
    }

    $version = Get-LocalClaudeVersion

    Assert-Equal $version '2.1.152' 'Expected Claude version detection to prefer the newer npm fallback over an older native install.'
    $firstUserPath = ($script:StoredUserPath -split ';')[0]
    $firstProcessPath = ($env:PATH -split ';')[0]
    if (-not $firstUserPath.EndsWith('npm-bin', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Expected User PATH to prioritize the newer npm Claude fallback."
    }
    if (-not $firstProcessPath.EndsWith('npm-bin', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Expected process PATH to prioritize the newer npm Claude fallback."
    }
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

Run-Test 'Get-LocalFactoryVersion prefers newer npm droid over older user bin install' {
  $originalPath = $env:PATH
  try {
    $script:NativeFactoryDir = Join-Path ([IO.Path]::GetTempPath()) 'factory-native-bin-test'
    $script:NpmFactoryDir = Join-Path ([IO.Path]::GetTempPath()) 'factory-npm-bin-test'
    $script:StoredUserPath = "$script:NativeFactoryDir;$script:NpmFactoryDir"
    $env:PATH = "$script:NativeFactoryDir;$script:NpmFactoryDir;legacy-bin"

    function Get-UserPathValue() {
      return $script:StoredUserPath
    }

    function Set-UserPathValue([string]$PathValue) {
      $script:StoredUserPath = $PathValue
    }

    function Get-PreferredToolPathDirs([string]$ToolId) {
      if ($ToolId -eq 'factory') { return @($script:NativeFactoryDir, $script:NpmFactoryDir) }
      return @()
    }

    function Get-CommandVersionInfo([string]$CommandName) {
      if ($CommandName -ne 'droid') { return @{ Name = $CommandName; Version = $null; Source = $null } }
      $firstPath = ($env:PATH -split ';')[0]
      if ((Normalize-Dir $firstPath) -eq (Normalize-Dir $script:NpmFactoryDir)) {
        return @{ Name = 'droid'; Version = '0.164.0'; Source = (Join-Path $script:NpmFactoryDir 'droid.cmd') }
      }
      return @{ Name = 'droid'; Version = '0.162.1'; Source = (Join-Path $script:NativeFactoryDir 'droid.exe') }
    }

    $version = Get-LocalFactoryVersion

    Assert-Equal $version '0.164.0' 'Expected Factory version detection to prefer the newer npm fallback over an older user-bin install.'
    Assert-StartsWith $script:StoredUserPath (Normalize-Dir $script:NpmFactoryDir) 'Expected User PATH to prioritize the newer npm Factory fallback.'
    Assert-StartsWith $env:PATH (Normalize-Dir $script:NpmFactoryDir) 'Expected process PATH to prioritize the newer npm Factory fallback.'
  } finally {
    $env:PATH = $originalPath
  }
}

Write-Host '[PASS] All tool PATH repair regression tests passed.' -ForegroundColor Green
