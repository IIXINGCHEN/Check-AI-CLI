$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

$script:RealInstallFactoryFromBootstrap = ${function:Install-FactoryFromBootstrap}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Actual, [string]$ExpectedSubstring, [string]$Message) {
  if (($null -eq $Actual) -or (-not $Actual.Contains($ExpectedSubstring))) {
    throw "$Message`nExpected substring: $ExpectedSubstring`nActual: $Actual"
  }
}

function Assert-ThrowsContains([scriptblock]$Action, [string]$ExpectedSubstring, [string]$Message) {
  try {
    & $Action
  } catch {
    Assert-Contains $_.Exception.Message $ExpectedSubstring $Message
    return
  }

  throw "$Message`nExpected exception containing: $ExpectedSubstring"
}

function Reset-TestDoubles {
  $script:CapturedWarnings = @()
  $script:StoredUserPath = ''
  $script:SetUserPathCalls = 0
  $script:ConfirmCalls = @()
  $script:InstallFactoryCalls = 0
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  try {
    Reset-TestDoubles
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

function Get-UserPathValue() {
  return $script:StoredUserPath
}

function Set-UserPathValue([string]$PathValue) {
  $script:SetUserPathCalls += 1
  $script:StoredUserPath = $PathValue
}

function Confirm-RemoteScriptExecution([string]$Url, [string]$ToolName, [string]$ActionDescription = 'download and execute a script from the internet', [string]$WarningTitle = 'Remote Script Execution') {
  $script:ConfirmCalls += @{
    Url = $Url
    ToolName = $ToolName
    ActionDescription = $ActionDescription
    WarningTitle = $WarningTitle
  }
  return $true
}

function Install-FactoryFromBootstrap() {
  $script:InstallFactoryCalls += 1
}

Run-Test 'Ensure-UserPathContains does not append duplicate normalized user PATH entries' {
  $originalPath = $env:PATH
  try {
    $script:StoredUserPath = 'C:\Users\Tester\BIN\'
    $env:PATH = 'C:\Windows\System32'

    Ensure-UserPathContains 'c:\users\tester\bin'

    Assert-Equal $script:SetUserPathCalls 0 'Expected no persisted PATH update when equivalent path already exists.'
    Assert-Equal $script:StoredUserPath 'C:\Users\Tester\BIN\' 'Expected existing user PATH value to remain unchanged.'
    Assert-Equal $env:PATH 'C:\Windows\System32' 'Expected process PATH to remain unchanged when entry already exists in user PATH.'
  } finally {
    $env:PATH = $originalPath
  }
}

Run-Test 'Get-LocalFactoryVersion prefers droid and warns when factory shim is older' {
  function Get-CommandVersionInfo([string]$CommandName) {
    switch ($CommandName) {
      'droid' { return @{ Name = 'droid'; Version = '2.3.4'; Source = 'C:\Users\Tester\bin\droid.exe' } }
      'factory' { return @{ Name = 'factory'; Version = '1.9.9'; Source = 'C:\legacy\factory.exe' } }
      default { return @{ Name = $CommandName; Version = $null; Source = $null } }
    }
  }

  $version = Get-LocalFactoryVersion

  Assert-Equal $version '2.3.4' 'Expected Factory version detection to prefer droid when available.'
  Assert-True ($script:CapturedWarnings.Count -eq 1) 'Expected a warning when factory resolves to an older binary.'
  Assert-True ($script:CapturedWarnings[0] -like '*Using droid for version checks*') 'Expected warning to explain that droid is used for version checks.'
}

Run-Test 'Update-Factory uses verified binary download warning text' {
  Update-Factory

  Assert-Equal $script:InstallFactoryCalls 1 'Expected Update-Factory to continue into the bootstrap installer after confirmation.'
  Assert-Equal $script:ConfirmCalls.Count 1 'Expected Update-Factory to prompt exactly once.'
  Assert-Equal $script:ConfirmCalls[0].Url 'https://app.factory.ai/cli/windows' 'Expected Factory bootstrap URL to be confirmed.'
  Assert-Equal $script:ConfirmCalls[0].ToolName 'Factory CLI' 'Expected Factory tool name in confirmation.'
  Assert-Equal $script:ConfirmCalls[0].ActionDescription 'fetch metadata from the official bootstrap, then download and install verified binaries locally' 'Expected Factory confirmation to describe verified binary download flow.'
  Assert-Equal $script:ConfirmCalls[0].WarningTitle 'Verified Binary Download' 'Expected Factory confirmation to use the new warning title.'
}

Run-Test 'Get-FactoryArchitectures detects WOW64 AMD64 hosts and falls back to baseline without AVX2' {
  $originalArch = $env:PROCESSOR_ARCHITECTURE
  $originalWow64Arch = $env:PROCESSOR_ARCHITEW6432
  try {
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'AMD64'

    function Test-FactoryAvx2Support() {
      return $false
    }

    $arch = Get-FactoryArchitectures

    Assert-Equal $arch.Factory 'x64-baseline' 'Expected WOW64 AMD64 hosts without AVX2 to use x64-baseline Factory payload.'
    Assert-Equal $arch.Ripgrep 'x64' 'Expected WOW64 AMD64 hosts to use x64 ripgrep payload.'
  } finally {
    $env:PROCESSOR_ARCHITECTURE = $originalArch
    $env:PROCESSOR_ARCHITEW6432 = $originalWow64Arch
  }
}

Run-Test 'Get-FactoryArchitectures rejects true 32-bit x86 hosts' {
  function Get-EffectiveWindowsArchitecture() {
    return 'X86'
  }

  Assert-ThrowsContains { Get-FactoryArchitectures } 'Unsupported architecture: X86' 'Expected true 32-bit x86 hosts to remain unsupported.'
}

Run-Test 'Get-FactoryBootstrapInfo fails clearly when bootstrap metadata is incomplete' {
  function Get-Text([string]$Url) {
    return @'
$version = "1.2.3"
Write-Host "bootstrap without base url"
'@
  }

  Assert-ThrowsContains { Get-FactoryBootstrapInfo } 'Failed to parse Factory base URL from installer script.' 'Expected bootstrap parsing to fail when baseUrl metadata disappears.'
}

Run-Test 'Install-FactoryFromBootstrap stops before install when checksum verification fails' {
  $script:InstallSequence = @()

  function Get-FactoryBootstrapInfo() {
    return @{ Version = '9.9.9'; BaseUrl = 'https://downloads.factory.ai' }
  }

  function Get-FactoryArchitectures() {
    return @{ Factory = 'x64'; Ripgrep = 'x64' }
  }

  function Download-FileWithRetry([string]$Url, [string]$OutFile, [string]$Label) {
    $script:InstallSequence += "download:$Label"
    New-Item -ItemType File -Path $OutFile -Force | Out-Null
  }

  function Get-ExpectedSha256([string]$Url) {
    return 'expected-hash'
  }

  function Assert-FileSha256([string]$Path, [string]$ExpectedHash, [string]$Label) {
    $script:InstallSequence += "verify:$Label"
    if ($Label -eq 'Factory CLI') {
      throw 'Factory CLI checksum verification failed'
    }
  }

  function Stop-FactoryProcesses() {
    $script:InstallSequence += 'stop-processes'
  }

  function Install-FactoryFile([string]$SourcePath, [string]$DestinationPath) {
    $script:InstallSequence += "install:$DestinationPath"
  }

  function Ensure-UserPathContains([string]$Dir) {
    $script:InstallSequence += "path:$Dir"
  }

  Assert-ThrowsContains { & $script:RealInstallFactoryFromBootstrap } 'Factory CLI checksum verification failed' 'Expected install flow to surface checksum verification failures.'
  Assert-Equal ($script:InstallSequence -join ',') 'download:Factory CLI binary,verify:Factory CLI' 'Expected checksum failure to stop before ripgrep download and file installation.'
}

Run-Test 'Download-FileWithRetry removes temp file after retry exhaustion' {
  $originalRetry = $env:CHECK_AI_CLI_RETRY
  $script:DownloadAttempts = 0
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  $outFile = Join-Path $tempDir 'factory.exe'
  $tmpFile = "$outFile.download"

  try {
    $env:CHECK_AI_CLI_RETRY = '2'

    function Invoke-WebRequestWithHeaders([string]$Uri, [string]$OutFile) {
      $script:DownloadAttempts += 1
      Set-Content -LiteralPath $OutFile -Value 'partial-download'
      throw 'network down'
    }

    function Start-Sleep {
      param([int]$Seconds)
    }

    Assert-ThrowsContains { Download-FileWithRetry 'https://downloads.factory.ai/factory.exe' $outFile 'Factory CLI binary' } 'Failed to download Factory CLI binary: network down' 'Expected retry exhaustion to surface the wrapped download error.'
    Assert-Equal $script:DownloadAttempts 2 'Expected download helper to retry the configured number of attempts.'
    Assert-True (-not (Test-Path -LiteralPath $tmpFile)) 'Expected temporary download file to be removed after retry exhaustion.'
  } finally {
    $env:CHECK_AI_CLI_RETRY = $originalRetry
    if (Test-Path -LiteralPath $tempDir) {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host '[PASS] All Factory review regression tests passed.' -ForegroundColor Green
