$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

$script:RealInstallFactoryFromBootstrap = ${function:Install-FactoryFromBootstrap}
$script:RealInvokeNpmInstallGlobal = ${function:Invoke-NpmInstallGlobal}
$script:RealGetNpmCommandPath = ${function:Get-NpmCommandPath}
$script:RealResolveApplicationCommandPath = ${function:Resolve-ApplicationCommandPath}

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

function Assert-NotContains([string]$Actual, [string]$UnexpectedSubstring, [string]$Message) {
  if (($null -ne $Actual) -and $Actual.Contains($UnexpectedSubstring)) {
    throw "$Message`nUnexpected substring: $UnexpectedSubstring`nActual: $Actual"
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
  $script:CapturedInfos = @()
  $script:StoredUserPath = ''
  $script:SetUserPathCalls = 0
  $script:ConfirmCalls = @()
  $script:InstallFactoryCalls = 0
  $script:NpmInstallCalls = @()
  $script:LatestFactoryOfficialVersion = $null
  $script:LatestFactoryNpmVersion = $null
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

function Write-Info([string]$Message) {
  $script:CapturedInfos += $Message
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

function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$Registry) {
  $script:NpmInstallCalls += $PackageSpec
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
  Assert-NotContains $script:CapturedWarnings[0] 'C:\Users\Tester' 'Expected Factory alias mismatch warning to avoid absolute local paths.'
}

Run-Test 'Get-CommandVersionInfo skips a broken shim and uses the next runnable command' {
  $originalPath = $env:PATH
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $brokenDir = Join-Path $tempRoot 'broken'
  $workingDir = Join-Path $tempRoot 'working'
  try {
    New-Item -ItemType Directory -Path $brokenDir,$workingDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $brokenDir 'droid.cmd') -Value "@echo off`r`necho broken shim 1>&2`r`nexit /b 1`r`n" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $workingDir 'droid.cmd') -Value "@echo off`r`necho droid 2.3.4`r`nexit /b 0`r`n" -Encoding ASCII
    $env:PATH = "$brokenDir;$workingDir;$originalPath"

    $info = Get-CommandVersionInfo 'droid'

    Assert-Equal $info.Version '2.3.4' 'Expected version probing to continue past a broken shim.'
    Assert-True ($info.Source.StartsWith($workingDir, [StringComparison]::OrdinalIgnoreCase)) 'Expected version probing to report the runnable command source.'
  } finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'Get-CommandSourcePath ignores non-executable Function definitions' {
  function fake-func-cmd { Write-Output 'not a real binary' }
  $cmd = Get-Command fake-func-cmd -ErrorAction SilentlyContinue

  Assert-True ($null -ne $cmd) 'Expected the fake function command to exist for the test.'
  Assert-True ($cmd.CommandType -eq 'Function') 'Expected CommandType to be Function for the test fixture.'

  $source = Get-CommandSourcePath $cmd

  Assert-True ($null -eq $source) 'Expected Get-CommandSourcePath to return null for a Function whose only meaningful property is the Definition body.'
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

Run-Test 'Update-Factory falls back to npm when bootstrap download fails' {
  $script:BestNpmMirror = 'https://registry.npmjs.org'
  function Install-FactoryFromBootstrap() {
    $script:InstallFactoryCalls += 1
    throw 'bootstrap unavailable'
  }
  function Get-FactoryNpmVersion() { return '0.170.0' }

  Update-Factory

  Assert-Equal $script:InstallFactoryCalls 1 'Expected Update-Factory to try the official bootstrap before npm.'
  Assert-Equal $script:NpmInstallCalls.Count 1 'Expected Update-Factory to use npm fallback after bootstrap failure.'
  Assert-Equal $script:NpmInstallCalls[0] 'droid@latest' 'Expected Factory npm fallback to install the official droid package.'
  Assert-True ($script:CapturedWarnings -contains 'Official bootstrap failed: bootstrap unavailable') 'Expected bootstrap failure to be logged before npm fallback.'
}

Run-Test 'Update-Factory rejects an older npm fallback after official download failure' {
  $script:LatestFactoryOfficialVersion = '0.170.0'
  $script:LatestFactoryNpmVersion = '0.162.1'
  function Install-FactoryFromBootstrap() {
    $script:InstallFactoryCalls += 1
    throw 'proxy EOF'
  }

  Assert-ThrowsContains { Update-Factory } 'npm latest is only v0.162.1' 'Expected stale npm fallback to be rejected explicitly.'
  Assert-Equal $script:NpmInstallCalls.Count 0 'Expected no npm install when npm cannot reach the selected official target.'
}

Run-Test 'Update-Factory retries official npm registry when mirror omits Windows optional binary' {
  $script:LatestFactoryOfficialVersion = '0.170.0'
  $script:LatestFactoryNpmVersion = '0.170.0'
  $script:BestNpmMirror = 'https://registry.npmmirror.com'
  $script:NpmInstallRegistries = @()
  $script:FactoryNpmVersions = @('missing', '0.170.0')

  function Install-FactoryFromBootstrap() { throw 'proxy EOF' }
  function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$Registry) {
    $script:NpmInstallRegistries += $Registry
  }
  function Get-FactoryNpmVersion() {
    $version = $script:FactoryNpmVersions[0]
    $script:FactoryNpmVersions = @($script:FactoryNpmVersions | Select-Object -Skip 1)
    if ($version -eq 'missing') { return $null }
    return $version
  }

  Update-Factory

  Assert-Equal $script:NpmInstallRegistries.Count 2 'Expected Factory npm fallback to retry after the mirror omitted the Windows optional binary.'
  Assert-Equal $script:NpmInstallRegistries[0] 'https://registry.npmmirror.com' 'Expected the configured regional mirror to be attempted first.'
  Assert-Equal $script:NpmInstallRegistries[1] 'https://registry.npmjs.org' 'Expected the official registry to be used for the exact Windows optional binary.'
}

Run-Test 'Get-LatestFactoryVersion reports channel drift and selects the newer version' {
  function Get-Text([string]$Url) { return '$version = "0.170.0"' }
  function Get-NpmLatestVersion([string]$PackageName) { return '0.162.1' }

  $version = Get-LatestFactoryVersion

  Assert-Equal $version '0.170.0' 'Expected the newer official Factory version.'
  Assert-True ($script:CapturedInfos -contains 'Factory CLI latest version sources differ: official=v0.170.0, npm=v0.162.1. Using v0.170.0.') 'Expected channel drift to be visible.'
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

Run-Test 'Assert-FileSha256 falls back when Get-FileHash is unavailable' {
  $tempFile = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($tempFile, 'factory-checksum', [Text.Encoding]::ASCII)
    $expected = 'ef5866a71f1326d3f96b42bd74ec4a6ddb1c783ca5f9c27755fe3ee6af8a4345'

    function Get-Command {
      param(
        [string]$Name,
        [System.Management.Automation.ActionPreference]$ErrorAction = 'Continue'
      )
      if ($Name -eq 'Get-FileHash') { return $null }
      Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction $ErrorAction
    }

    function Get-FileHash { throw 'Get-FileHash unavailable' }

    Assert-FileSha256 $tempFile $expected 'Factory CLI'
  } finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
  }
}

Run-Test 'Get-LatestFactoryVersion falls back to npm when bootstrap endpoint is unavailable' {
  function Get-Text([string]$Url) {
    return $null
  }

  function Get-NpmLatestVersion([string]$PackageName) {
    Assert-Equal $PackageName 'droid' 'Expected Factory fallback to query the official droid npm package.'
    return '0.100.0'
  }

  $version = Get-LatestFactoryVersion

  Assert-Equal $version '0.100.0' 'Expected Factory latest version to fall back to npm when bootstrap metadata is unavailable.'
}

Run-Test 'Install-FactoryFromBootstrap works when New-TemporaryFile is unavailable' {
  $script:InstallSequence = @()
  $originalUserProfile = $env:USERPROFILE

  function New-TemporaryFile() {
    throw 'New-TemporaryFile is unavailable in this host'
  }

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
  }

  function Stop-FactoryProcesses() {
    $script:InstallSequence += 'stop'
  }

  function Install-FactoryFile([string]$SourcePath, [string]$DestinationPath) {
    $script:InstallSequence += "install:$([IO.Path]::GetFileName($SourcePath))"
  }

  try {
    $env:USERPROFILE = 'C:\Users\Tester'
    & $script:RealInstallFactoryFromBootstrap
  } finally {
    $env:USERPROFILE = $originalUserProfile
    Remove-Item Function:\New-TemporaryFile -ErrorAction SilentlyContinue
  }

  Assert-Equal ($script:InstallSequence -join ',') 'download:Factory CLI binary,verify:Factory CLI,download:ripgrep binary,verify:ripgrep,install:droid.exe,install:rg.exe' 'Expected Factory bootstrap to install verified files without New-TemporaryFile.'
  foreach ($message in $script:CapturedInfos) {
    Assert-NotContains $message 'C:\Users\Tester' 'Expected Factory bootstrap info logs to avoid absolute local paths.'
  }
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

    function Invoke-CurlDownload([string]$Url, [string]$OutFile) {
      throw 'curl unavailable in test'
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

Run-Test 'Download-FileWithRetry falls back to curl after PowerShell EOF failures' {
  $originalRetry = $env:CHECK_AI_CLI_RETRY
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $outFile = Join-Path $tempDir 'factory.exe'
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  try {
    $env:CHECK_AI_CLI_RETRY = '1'
    function Invoke-WebRequestWithHeaders([string]$Uri, [string]$OutFile) { throw 'unexpected EOF' }
    function Invoke-CurlDownload([string]$Url, [string]$OutFile) { Set-Content -LiteralPath $OutFile -Value 'complete-binary' }

    Download-FileWithRetry 'https://downloads.factory.ai/factory.exe' $outFile 'Factory CLI binary'

    Assert-True (Test-Path -LiteralPath $outFile) 'Expected curl fallback to publish the completed file.'
    Assert-True ((Get-Item -LiteralPath $outFile).Length -gt 0) 'Expected a non-empty completed file.'
  } finally {
    $env:CHECK_AI_CLI_RETRY = $originalRetry
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Run-Test 'Install-FactoryFile retries after stopping a process holding the destination' {
  $script:InstallFileCalls = @()
  $script:StopProcessCalls = @()
  $script:GetProcessQueries = @()
  $script:CopyAttempt = 0

  # Real Install-FactoryFile under test (do NOT mock it). Mock only the
  # collaborators it touches when a copy fails.
  $src = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.exe')
  $dst = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '\droid.exe')
  [IO.File]::WriteAllBytes($src, [byte[]](1,2,3,4))
  try {
    function Copy-Item {
      param([Parameter(Position=0)][string]$Path, [Parameter(Position=1)][string]$Destination, [switch]$Force)
      $script:InstallFileCalls += $Destination
      $script:CopyAttempt += 1
      if ($script:CopyAttempt -eq 1) { throw 'Access denied: file in use' }
      # Second attempt succeeds
    }

    function Get-Process {
      param([string]$Name)
      $script:GetProcessQueries += $Name
      return @([pscustomobject]@{ Id = 1234; Name = $Name })
    }

    function Stop-Process {
      param([string]$Name, [switch]$Force)
      $script:StopProcessCalls += $Name
    }

    function Start-Sleep {
      param([int]$Seconds)
    }

    Install-FactoryFile $src $dst

    Assert-Equal $script:InstallFileCalls.Count 2 'Expected Install-FactoryFile to retry copy once after the first attempt failed.'
    Assert-Equal $script:GetProcessQueries[0] 'droid' 'Expected process lookup to target the destination tool name (droid), not a blanket kill.'
    Assert-Equal $script:StopProcessCalls[0] 'droid' 'Expected only the locking process (droid) to be stopped, not all tools.'
  } finally {
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    $dstParent = Split-Path -Parent $dst
    if (Test-Path -LiteralPath $dstParent) { Remove-Item -LiteralPath $dstParent -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\Stop-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
  }
}

Run-Test 'Install-FactoryFile does not kill any process when copy succeeds' {
  $script:StopProcessCalls = @()
  $script:GetProcessQueries = @()

  $src = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.exe')
  $dst = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '\droid.exe')
  [IO.File]::WriteAllBytes($src, [byte[]](1,2,3,4))
  try {
    function Get-Process {
      param([string]$Name)
      return $null
    }

    function Stop-Process {
      param([string]$Name)
      $script:StopProcessCalls += $Name
    }

    # Copy-Item is NOT mocked: real copy succeeds on first try.
    Install-FactoryFile $src $dst

    Assert-Equal $script:StopProcessCalls.Count 0 'Expected no process to be stopped when the initial copy succeeds.'
    Assert-True (Test-Path -LiteralPath $dst) 'Expected the destination file to exist after a successful copy.'
  } finally {
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    $dstParent = Split-Path -Parent $dst
    if (Test-Path -LiteralPath $dstParent) { Remove-Item -LiteralPath $dstParent -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\Stop-Process -ErrorAction SilentlyContinue
  }
}

Run-Test 'Resolve-ApplicationCommandPath returns the first on-disk PATH hit for multi-npm installs' {
  ${function:Resolve-ApplicationCommandPath} = $script:RealResolveApplicationCommandPath
  Remove-Item Function:\Get-Command -ErrorAction SilentlyContinue
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $firstDir = Join-Path $tempRoot 'first'
  $secondDir = Join-Path $tempRoot 'second'
  $originalPath = $env:PATH
  try {
    New-Item -ItemType Directory -Path $firstDir,$secondDir -Force | Out-Null
    $firstNpm = Join-Path $firstDir 'npm.cmd'
    $secondNpm = Join-Path $secondDir 'npm.cmd'
    Set-Content -LiteralPath $firstNpm -Value "@echo off`r`necho first`r`n" -Encoding ASCII
    Set-Content -LiteralPath $secondNpm -Value "@echo off`r`necho second`r`n" -Encoding ASCII
    $env:PATH = "$firstDir;$secondDir;$originalPath"

    $resolved = Resolve-ApplicationCommandPath -Name @('npm.cmd', 'npm')

    Assert-Equal $resolved $firstNpm 'Expected multi-path npm resolution to keep the first PATH entry only.'
    Assert-True (-not $resolved.Contains(' ')) 'Expected resolved npm path to be a single filesystem path, not a space-joined dual path.'
  } finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'Invoke-NpmInstallGlobal invokes a single npm.cmd when multiple copies exist on PATH' {
  # Earlier tests install temporary Invoke-NpmInstallGlobal doubles in function
  # scope and leave them behind. Restore the real implementations first.
  ${function:Invoke-NpmInstallGlobal} = $script:RealInvokeNpmInstallGlobal
  ${function:Get-NpmCommandPath} = $script:RealGetNpmCommandPath
  ${function:Resolve-ApplicationCommandPath} = $script:RealResolveApplicationCommandPath
  Remove-Item Function:\Get-Command -ErrorAction SilentlyContinue

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $firstDir = Join-Path $tempRoot 'first'
  $secondDir = Join-Path $tempRoot 'second'
  $originalPath = $env:PATH
  $originalMirror = $script:BestNpmMirror
  try {
    New-Item -ItemType Directory -Path $firstDir,$secondDir -Force | Out-Null
    $firstNpm = Join-Path $firstDir 'npm.cmd'
    $secondNpm = Join-Path $secondDir 'npm.cmd'
    $firstLog = Join-Path $firstDir 'invoked.txt'
    $secondLog = Join-Path $secondDir 'invoked.txt'
    Set-Content -LiteralPath $firstNpm -Value ("@echo off`r`necho %~f0> `"$firstLog`"`r`necho %*>> `"$firstLog`"`r`nexit /b 0`r`n") -Encoding ASCII
    Set-Content -LiteralPath $secondNpm -Value ("@echo off`r`necho %~f0> `"$secondLog`"`r`necho %*>> `"$secondLog`"`r`nexit /b 0`r`n") -Encoding ASCII
    $env:PATH = "$firstDir;$secondDir;$originalPath"
    $script:BestNpmMirror = 'https://registry.npmjs.org'

    Invoke-NpmInstallGlobal '@openai/codex@latest'

    Assert-True (Test-Path -LiteralPath $firstLog) 'Expected the first PATH npm.cmd to be invoked.'
    Assert-True (-not (Test-Path -LiteralPath $secondLog)) 'Expected the second PATH npm.cmd to remain unused.'
    $log = Get-Content -LiteralPath $firstLog -Raw
    Assert-Contains $log $firstNpm 'Expected npm install to invoke the first PATH npm.cmd.'
    Assert-Contains $log 'install -g @openai/codex@latest --registry https://registry.npmjs.org' 'Expected npm install arguments to be preserved.'
  } finally {
    $env:PATH = $originalPath
    $script:BestNpmMirror = $originalMirror
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'Update-Codex surfaces real npm failures instead of a false missing-installer message' {
  function Get-NpmCommandPath() { return 'C:\fake\npm.cmd' }
  function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$RegistryOverride = $null) {
    throw 'network unreachable while fetching package metadata'
  }

  try {
    Assert-ThrowsContains { Update-Codex } 'network unreachable while fetching package metadata' 'Expected Codex update to preserve the real npm error.'
  } finally {
    ${function:Invoke-NpmInstallGlobal} = $script:RealInvokeNpmInstallGlobal
    ${function:Get-NpmCommandPath} = $script:RealGetNpmCommandPath
  }
}

Run-Test 'Update-Codex retries official registry when mirror omits Windows optional package' {
  $script:BestNpmMirror = 'https://registry.npmmirror.com'
  $script:NpmInstallRegistries = @()
  $script:CodexProbeResults = @(
    @{ Version = $null; Output = 'Error: Missing optional dependency @openai/codex-win32-x64. Reinstall Codex: npm install -g @openai/codex@latest'; Source = 'C:\npm\codex.cmd' },
    @{ Version = '0.144.3'; Output = 'codex-cli 0.144.3'; Source = 'C:\npm\codex.cmd' }
  )

  function Get-NpmCommandPath() { return 'C:\fake\npm.cmd' }
  function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$RegistryOverride = $null) {
    Assert-Equal $PackageSpec '@openai/codex@latest' 'Expected Codex update to install @openai/codex@latest.'
    $script:NpmInstallRegistries += $RegistryOverride
  }
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Invoke-CodexVersionProbe() {
    $next = $script:CodexProbeResults[0]
    $script:CodexProbeResults = @($script:CodexProbeResults | Select-Object -Skip 1)
    return $next
  }

  try {
    Update-Codex
  } finally {
    ${function:Invoke-NpmInstallGlobal} = $script:RealInvokeNpmInstallGlobal
    ${function:Get-NpmCommandPath} = $script:RealGetNpmCommandPath
    Remove-Item Function:\Repair-ToolUserPath -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-CodexVersionProbe -ErrorAction SilentlyContinue
  }

  Assert-equal $script:NpmInstallRegistries.Count 2 'Expected Codex to retry after the mirror omitted the Windows optional package.'
  Assert-equal $script:NpmInstallRegistries[0] 'https://registry.npmmirror.com' 'Expected the regional mirror to be attempted first.'
  Assert-equal $script:NpmInstallRegistries[1] 'https://registry.npmjs.org' 'Expected the official registry retry for the Windows optional package.'
  Assert-True ($script:CapturedWarnings -like '*missing optional package @openai/codex-win32-x64*').Count -ge 1 -or ($script:CapturedWarnings | Where-Object { $_ -like '*missing optional package @openai/codex-win32-x64*' }).Count -ge 1 'Expected a warning about the missing Windows optional package.'
}

Run-Test 'Get-CodexMissingOptionalPackageName extracts the platform package name' {
  $name = Get-CodexMissingOptionalPackageName 'Error: Missing optional dependency @openai/codex-win32-x64. Reinstall Codex: npm install -g @openai/codex@latest'
  Assert-equal $name '@openai/codex-win32-x64' 'Expected Codex optional dependency parser to extract the platform package name.'
}

Run-Test 'Get-CodexOptionalPackageSpec reads npm alias from package.json optionalDependencies' {
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $pkgRoot = Join-Path $tempRoot 'node_modules\@openai\codex'
  New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null
  try {
    $json = @'
{
  "name": "@openai/codex",
  "version": "0.144.3",
  "optionalDependencies": {
    "@openai/codex-win32-x64": "npm:@openai/codex@0.144.3-win32-x64"
  }
}
'@
    Set-Content -LiteralPath (Join-Path $pkgRoot 'package.json') -Value $json -Encoding UTF8
    function Get-CodexInstalledPackageRoot() { return $pkgRoot }

    $spec = Get-CodexOptionalPackageSpec '@openai/codex-win32-x64'
    Assert-equal $spec '@openai/codex@0.144.3-win32-x64' 'Expected optional package alias to strip the npm: prefix.'
  } finally {
    Remove-Item Function:\Get-CodexInstalledPackageRoot -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'Update-Codex installs exact optional package when official reinstall still lacks platform binary' {
  $script:BestNpmMirror = 'https://registry.npmmirror.com'
  $script:NpmInstallCalls = @()
  $script:CodexProbeResults = @(
    @{ Version = $null; Output = 'Error: Missing optional dependency @openai/codex-win32-x64.'; Source = 'codex.cmd' },
    @{ Version = $null; Output = 'Error: Missing optional dependency @openai/codex-win32-x64.'; Source = 'codex.cmd' },
    @{ Version = '0.144.3'; Output = 'codex-cli 0.144.3'; Source = 'codex.cmd' }
  )

  function Get-NpmCommandPath() { return 'npm.cmd' }
  function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$RegistryOverride = $null) {
    $script:NpmInstallCalls += @{ Spec = $PackageSpec; Registry = $RegistryOverride }
  }
  function Repair-ToolUserPath([string]$ToolId) { return $true }
  function Invoke-CodexVersionProbe() {
    $next = $script:CodexProbeResults[0]
    $script:CodexProbeResults = @($script:CodexProbeResults | Select-Object -Skip 1)
    return $next
  }
  function Get-CodexOptionalPackageSpec([string]$OptionalPackageName) {
    Assert-Equal $OptionalPackageName '@openai/codex-win32-x64' 'Expected optional package recovery to target the missing Windows package.'
    return '@openai/codex@0.144.3-win32-x64'
  }

  try {
    Update-Codex
  } finally {
    ${function:Invoke-NpmInstallGlobal} = $script:RealInvokeNpmInstallGlobal
    ${function:Get-NpmCommandPath} = $script:RealGetNpmCommandPath
    Remove-Item Function:\Repair-ToolUserPath -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-CodexVersionProbe -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-CodexOptionalPackageSpec -ErrorAction SilentlyContinue
  }

  Assert-equal $script:NpmInstallCalls.Count 3 'Expected mirror install, official reinstall, then exact optional package install.'
  Assert-equal $script:NpmInstallCalls[0].Spec '@openai/codex@latest' 'Expected first install to be @openai/codex@latest.'
  Assert-equal $script:NpmInstallCalls[0].Registry 'https://registry.npmmirror.com' 'Expected first install on the mirror.'
  Assert-equal $script:NpmInstallCalls[1].Registry 'https://registry.npmjs.org' 'Expected second install on official registry.'
  Assert-equal $script:NpmInstallCalls[2].Spec '@openai/codex@0.144.3-win32-x64' 'Expected third install to target the exact optional package.'
  Assert-equal $script:NpmInstallCalls[2].Registry 'https://registry.npmjs.org' 'Expected optional package install on official registry.'
}


Run-Test 'Resolve-ApplicationCommandPath returns a single curl.exe when Git and System32 both provide curl' {
  ${function:Resolve-ApplicationCommandPath} = $script:RealResolveApplicationCommandPath
  Remove-Item Function:\Get-Command -ErrorAction SilentlyContinue
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
  $gitDir = Join-Path $tempRoot 'git'
  $systemDir = Join-Path $tempRoot 'system32'
  $originalPath = $env:PATH
  try {
    New-Item -ItemType Directory -Path $gitDir,$systemDir -Force | Out-Null
    $gitCurl = Join-Path $gitDir 'curl.exe'
    $systemCurl = Join-Path $systemDir 'curl.exe'
    Set-Content -LiteralPath $gitCurl -Value 'git-curl' -Encoding ASCII
    Set-Content -LiteralPath $systemCurl -Value 'system-curl' -Encoding ASCII
    $env:PATH = "$gitDir;$systemDir;$originalPath"

    $resolved = Resolve-ApplicationCommandPath -Name @('curl.exe')

    Assert-Equal $resolved $gitCurl 'Expected curl resolution to keep the first PATH entry only.'
    Assert-True (-not $resolved.Contains(' ')) 'Expected resolved curl path to be a single filesystem path.'
  } finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host '[PASS] All Factory review regression tests passed.' -ForegroundColor Green
