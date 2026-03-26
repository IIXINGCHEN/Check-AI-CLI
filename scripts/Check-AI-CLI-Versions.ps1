param(
  [switch]$Auto,
  [switch]$FactoryOnly
)

$ErrorActionPreference = 'Stop'

# Main script lives under scripts/ for clearer structure

# Auto mode: install if missing, update if outdated, no Y/N prompts
function Get-AutoMode() {
  if ($Auto) { return $true }
  $v = $env:CHECK_AI_CLI_AUTO
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

$script:AutoMode = Get-AutoMode

# Consistent output formatting
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Some installer scripts rely on PowerShell progress output (Write-Progress / Invoke-WebRequest).
# If user's $ProgressPreference is set to SilentlyContinue, downloads may look "stuck".
function Get-ShowProgress() {
  $v = $env:CHECK_AI_CLI_SHOW_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-QuietProgressMode() {
  if (Get-ShowProgress) { return $false }
  $v = $env:CHECK_AI_CLI_QUIET_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Invoke-WithTempProgressPreference([string]$Mode, [scriptblock]$Action) {
  $prev = $ProgressPreference
  $ProgressPreference = $Mode
  try { & $Action } finally { $ProgressPreference = $prev }
}

function Require-WebRequest() {
  $cmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  if ($cmd) { return }
  throw "Invoke-WebRequest not found. Use Windows PowerShell 5.1+ or PowerShell 7+."
}

function Get-RetryCount() {
  $v = $env:CHECK_AI_CLI_RETRY
  if ([string]::IsNullOrWhiteSpace($v)) { return 3 }
  $n = 0
  if (-not [int]::TryParse($v.Trim(), [ref]$n)) { return 3 }
  if ($n -lt 1) { return 1 }
  if ($n -gt 10) { return 10 }
  return $n
}

function Test-NonEmptyFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  return (Get-Item -LiteralPath $Path).Length -gt 0
}

function Invoke-WebRequestWithHeaders([string]$Uri, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  if ($OutFile) {
    $mode = 'Continue'
    if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
    Invoke-WithTempProgressPreference $mode {
      Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -OutFile $OutFile -ErrorAction Stop | Out-Null
    }
    return
  }
  return Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -ErrorAction Stop
}

function Download-FileWithRetry([string]$Url, [string]$OutFile, [string]$Label) {
  $tries = Get-RetryCount
  $tmp = "$OutFile.download"
  for ($i = 1; $i -le $tries; $i++) {
    try {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      Invoke-WebRequestWithHeaders $Url $tmp
      if (-not (Test-NonEmptyFile $tmp)) { throw "Downloaded file is empty." }
      Move-Item -LiteralPath $tmp -Destination $OutFile -Force
      return
    } catch {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      if ($i -eq $tries) { throw "Failed to download ${Label}: $($_.Exception.Message)" }
      Write-Warn "${Label} download attempt $i/$tries failed: $($_.Exception.Message)"
      Start-Sleep -Seconds 2
    }
  }
}

function Get-FactoryBootstrapInfo() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) { throw 'Failed to download Factory installer script.' }
  $versionMatch = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
  if (-not $versionMatch.Success) { throw 'Failed to parse Factory version from installer script.' }
  $baseUrlMatch = [regex]::Match($text, '\$baseUrl\s*=\s*"([^"]+)"')
  if (-not $baseUrlMatch.Success) { throw 'Failed to parse Factory base URL from installer script.' }
  $baseUrl = $baseUrlMatch.Groups[1].Value.Trim()
  if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw 'Factory base URL is empty in installer script.' }
  return @{ Version = $versionMatch.Groups[1].Value; BaseUrl = $baseUrl }
}

function Get-EffectiveWindowsArchitecture() {
  $arch = $env:PROCESSOR_ARCHITECTURE
  $wow64Arch = $env:PROCESSOR_ARCHITEW6432

  if (-not [string]::IsNullOrWhiteSpace($wow64Arch)) {
    return $wow64Arch.ToUpperInvariant()
  }

  if (-not [string]::IsNullOrWhiteSpace($arch)) {
    $normalized = $arch.ToUpperInvariant()
    if ($normalized -eq 'X86') {
      if ([Environment]::Is64BitOperatingSystem) { return 'AMD64' }
      return 'X86'
    }
    return $normalized
  }

  if ([Environment]::Is64BitOperatingSystem) { return 'AMD64' }
  return 'X86'
}

function Test-FactoryAvx2Support() {
  try {
    $type = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(int ProcessorFeature);' -Name 'Kernel32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    return $type::IsProcessorFeaturePresent(40)
  } catch {
    try { return ([Win32.Kernel32]::IsProcessorFeaturePresent(40)) } catch { return $false }
  }
}

function Get-FactoryArchitectures() {
  $arch = Get-EffectiveWindowsArchitecture
  if ($arch -eq 'ARM64') { return @{ Factory = 'arm64'; Ripgrep = 'arm64' } }
  if ($arch -ne 'AMD64' -and $arch -ne 'X64') { throw "Unsupported architecture: $arch" }
  $factoryArch = 'x64'
  if (-not (Test-FactoryAvx2Support)) { $factoryArch = 'x64-baseline' }
  return @{ Factory = $factoryArch; Ripgrep = 'x64' }
}

function Get-ExpectedSha256([string]$Url) {
  $text = Get-Text $Url
  if ([string]::IsNullOrWhiteSpace($text)) { throw "Failed to fetch checksum: $Url" }
  return $text.Trim().Split()[0].ToLowerInvariant()
}

function Assert-FileSha256([string]$Path, [string]$ExpectedHash, [string]$Label) {
  $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) { throw "$Label checksum verification failed" }
}

function Stop-FactoryProcesses() {
  $droidProcesses = Get-Process -Name 'droid' -ErrorAction SilentlyContinue
  if (-not $droidProcesses) { return }
  Write-Info 'Stopping old droid process(es)'
  Stop-Process -Name 'droid' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

function Install-FactoryFile([string]$SourcePath, [string]$DestinationPath) {
  $parent = Split-Path -Parent $DestinationPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\\')
}

function Path-ContainsDir([string]$PathValue, [string]$Dir) {
  $needle = (Normalize-Dir $Dir).ToLowerInvariant()
  foreach ($p in @($PathValue -split ';')) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try {
      if ((Normalize-Dir $p).ToLowerInvariant() -eq $needle) { return $true }
    } catch { }
  }
  return $false
}

function Remove-PathEntry([string]$PathValue, [string]$Dir) {
  $needle = (Normalize-Dir $Dir).ToLowerInvariant()
  $items = @()
  foreach ($p in @($PathValue -split ';')) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try { if ((Normalize-Dir $p).ToLowerInvariant() -ne $needle) { $items += $p } } catch { $items += $p }
  }
  return ($items -join ';')
}

function Prepend-PathEntry([string]$PathValue, [string]$Dir) {
  $normalized = Normalize-Dir $Dir
  $trimmed = Remove-PathEntry $PathValue $normalized
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return $normalized }
  return "$normalized;$trimmed"
}

function Get-UserPathValue() {
  return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPathValue([string]$PathValue) {
  [Environment]::SetEnvironmentVariable('Path', $PathValue, 'User')
}

function Ensure-UserPathContains([string]$Dir) {
  $userPath = Get-UserPathValue
  if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
  if (Path-ContainsDir $userPath $Dir) { return }
  $normalized = Normalize-Dir $Dir
  $newPath = if ($userPath) { "$userPath;$normalized" } else { $normalized }
  Set-UserPathValue $newPath
  if (-not (Path-ContainsDir $env:PATH $normalized)) {
    $env:PATH = if ([string]::IsNullOrWhiteSpace($env:PATH)) { $normalized } else { "$normalized;$env:PATH" }
  }
  Write-Info "Added $normalized to your PATH permanently"
}

function Ensure-UserPathPrefers([string]$Dir) {
  $normalized = Normalize-Dir $Dir
  $userPath = Get-UserPathValue
  $newUserPath = Prepend-PathEntry $userPath $normalized
  if ($newUserPath -ne $userPath) {
    Set-UserPathValue $newUserPath
    Write-Info "Moved $normalized to the front of your PATH permanently"
  }
  $env:PATH = Prepend-PathEntry $env:PATH $normalized
}

function Get-NpmGlobalBinDir() {
  $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
  if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
  if (-not $npmCmd) { return $null }
  try {
    $prefix = (& $npmCmd.Path config get prefix 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -eq 'undefined') { return $null }
    return $prefix.TrimEnd('/','\')
  } catch { return $null }
}

function Get-ClaudeUserBinDir() {
  $dir = Join-Path $env:USERPROFILE '.local/bin'
  foreach ($name in @('claude','claude.cmd','claude.exe')) {
    if (Test-Path -LiteralPath (Join-Path $dir $name)) { return $dir }
  }
  return $null
}

function Get-PreferredToolPathDirs([string]$ToolId) {
  $dirs = @()
  if ($ToolId -eq 'factory') {
    $factoryDir = Join-Path $env:USERPROFILE 'bin'
    if (Test-Path -LiteralPath $factoryDir) { $dirs += $factoryDir }
  }
  if ($ToolId -eq 'claude') {
    $claudeDir = Get-ClaudeUserBinDir
    if ($claudeDir) { $dirs += $claudeDir }
  }
  if ($ToolId -eq 'opencode') {
    $openCodeDir = Get-OpenCodeUserBinDir
    if ($openCodeDir) { $dirs += $openCodeDir }
  }
  if ($ToolId -in @('claude','codex','gemini','opencode')) {
    $npmBin = Get-NpmGlobalBinDir
    if ($npmBin) { $dirs += $npmBin }
  }
  return @($dirs | Select-Object -Unique)
}

function Get-OrderedPathValue([string]$PathValue, [string[]]$Dirs) {
  $ordered = $PathValue
  for ($i = $Dirs.Count - 1; $i -ge 0; $i--) { $ordered = Prepend-PathEntry $ordered $Dirs[$i] }
  return $ordered
}

function Repair-ToolUserPath([string]$ToolId) {
  $dirs = @(Get-PreferredToolPathDirs $ToolId)
  if ($dirs.Count -eq 0) { return $false }
  $userPath = Get-UserPathValue
  $newUserPath = Get-OrderedPathValue $userPath $dirs
  if ($newUserPath -ne $userPath) { Set-UserPathValue $newUserPath ; Write-Info "Updated your PATH permanently to prefer $ToolId" }
  $env:PATH = Get-OrderedPathValue $env:PATH $dirs
  return $true
}

function Install-FactoryFromBootstrap() {
  $bootstrap = Get-FactoryBootstrapInfo
  $arch = Get-FactoryArchitectures
  $binaryName = 'droid.exe'
  $rgBinaryName = 'rg.exe'
  $version = $bootstrap.Version
  $baseUrl = $bootstrap.BaseUrl.TrimEnd('/')
  $factoryUrl = "$baseUrl/factory-cli/releases/$version/windows/$($arch.Factory)/$binaryName"
  $factoryShaUrl = "$factoryUrl.sha256"
  $rgUrl = "$baseUrl/ripgrep/windows/$($arch.Ripgrep)/$rgBinaryName"
  $rgShaUrl = "$rgUrl.sha256"
  Write-Info "Downloading Factory CLI v$version for Windows-$($arch.Factory)"

  $tempDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
  $binaryPath = Join-Path $tempDir $binaryName
  $rgBinaryPath = Join-Path $tempDir $rgBinaryName

  try {
    Download-FileWithRetry $factoryUrl $binaryPath 'Factory CLI binary'
    Write-Info 'Fetching and verifying checksum'
    Assert-FileSha256 $binaryPath (Get-ExpectedSha256 $factoryShaUrl) 'Factory CLI'
    Write-Info 'Checksum verification passed'

    Write-Info "Downloading ripgrep for Windows-$($arch.Ripgrep)"
    Download-FileWithRetry $rgUrl $rgBinaryPath 'ripgrep binary'
    Write-Info 'Fetching and verifying ripgrep checksum'
    Assert-FileSha256 $rgBinaryPath (Get-ExpectedSha256 $rgShaUrl) 'ripgrep'
    Write-Info 'Ripgrep checksum verification passed'

    $installDir = Join-Path $env:USERPROFILE 'bin'
    $factoryBinDir = Join-Path $env:USERPROFILE '.factory\bin'
    $installPath = Join-Path $installDir $binaryName
    $rgInstallPath = Join-Path $factoryBinDir $rgBinaryName

    Stop-FactoryProcesses
    Install-FactoryFile $binaryPath $installPath
    Install-FactoryFile $rgBinaryPath $rgInstallPath

    Write-Info "Factory CLI v$version installed successfully to $installPath"
    Write-Info "Ripgrep installed successfully to $rgInstallPath"
    Ensure-UserPathContains $installDir
    Write-Info 'Run ''droid'' to get started!'
  } finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# ============================================================================
# Network Detection & npm Registry Management
# ============================================================================

# npm mirrors configuration
$script:NpmMirrors = @{
  'taobao'  = 'https://registry.npmmirror.com'
  'tencent' = 'https://mirrors.cloud.tencent.com/npm/'
  'huawei'  = 'https://repo.huaweicloud.com/repository/npm/'
  'default' = 'https://registry.npmjs.org'
}

# Network detection cache
$script:NetworkInfo = $null
$script:OriginalNpmRegistry = $null

# Network status enum-like values
# ProxyMode: 'direct' | 'global' | 'rule' | 'unknown'
# Region: 'china' | 'global' | 'unknown'

# Detect Windows system proxy settings
function Get-SystemProxySettings() {
  $result = @{
    Enabled = $false
    Server = $null
    Bypass = $null
    AutoConfig = $false
    AutoConfigUrl = $null
  }
  
  try {
    # Check Internet Settings registry
    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    
    if ($settings) {
      $result.Enabled = [bool]$settings.ProxyEnable
      $result.Server = $settings.ProxyServer
      $result.Bypass = $settings.ProxyOverride
      $result.AutoConfig = [bool]$settings.AutoConfigURL
      $result.AutoConfigUrl = $settings.AutoConfigURL
    }
  } catch { }
  
  return $result
}

# Detect environment proxy variables
function Get-EnvProxySettings() {
  $result = @{
    HttpProxy = $null
    HttpsProxy = $null
    NoProxy = $null
    AllProxy = $null
  }
  
  # Check common proxy environment variables (case-insensitive)
  $result.HttpProxy = if ($env:HTTP_PROXY) { $env:HTTP_PROXY } elseif ($env:http_proxy) { $env:http_proxy } else { $null }
  $result.HttpsProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:https_proxy) { $env:https_proxy } else { $null }
  $result.NoProxy = if ($env:NO_PROXY) { $env:NO_PROXY } elseif ($env:no_proxy) { $env:no_proxy } else { $null }
  $result.AllProxy = if ($env:ALL_PROXY) { $env:ALL_PROXY } elseif ($env:all_proxy) { $env:all_proxy } else { $null }
  
  return $result
}

# Test actual connectivity to determine real network path
function Test-ActualConnectivity() {
  $result = @{
    GoogleOK = $false
    GoogleTime = -1
    BaiduOK = $false
    BaiduTime = -1
    NpmjsOK = $false
    NpmjsTime = -1
    NpmmirrorOK = $false
    NpmmirrorTime = -1
  }
  
  # Test endpoints with timing
  $tests = @(
    @{ Name = 'Google'; Url = 'https://www.google.com/generate_204'; Key = 'GoogleOK'; TimeKey = 'GoogleTime' },
    @{ Name = 'Baidu'; Url = 'https://www.baidu.com'; Key = 'BaiduOK'; TimeKey = 'BaiduTime' },
    @{ Name = 'npmjs'; Url = 'https://registry.npmjs.org'; Key = 'NpmjsOK'; TimeKey = 'NpmjsTime' },
    @{ Name = 'npmmirror'; Url = 'https://registry.npmmirror.com'; Key = 'NpmmirrorOK'; TimeKey = 'NpmmirrorTime' }
  )
  
  foreach ($test in $tests) {
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $null = Invoke-WebRequest -Uri $test.Url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
      $sw.Stop()
      $result[$test.Key] = $true
      $result[$test.TimeKey] = $sw.ElapsedMilliseconds
    } catch {
      $result[$test.Key] = $false
      $result[$test.TimeKey] = -1
    }
  }
  
  return $result
}

# Determine proxy mode based on connectivity tests
function Get-ProxyMode([hashtable]$Connectivity) {
  $googleOK = $Connectivity.GoogleOK
  $baiduOK = $Connectivity.BaiduOK
  
  if ($googleOK -and $baiduOK) {
    # Both accessible - either global proxy or outside China
    return 'global'
  }
  elseif (-not $googleOK -and $baiduOK) {
    # Only Baidu - direct connection in China (no proxy or rule-based proxy not covering Google)
    return 'direct'
  }
  elseif ($googleOK -and -not $baiduOK) {
    # Only Google - unusual, might be rule-based proxy
    return 'rule'
  }
  else {
    # Neither accessible - network issues
    return 'unknown'
  }
}

# Determine effective region for npm registry selection
function Get-EffectiveRegion([hashtable]$Connectivity, [string]$ProxyMode) {
  # If user specified region, respect it
  $envOverride = $env:CHECK_AI_CLI_REGION
  if (-not [string]::IsNullOrWhiteSpace($envOverride)) {
    $region = $envOverride.Trim().ToLowerInvariant()
    if ($region -eq 'china' -or $region -eq 'cn') { return 'china' }
    if ($region -eq 'global' -or $region -eq 'intl') { return 'global' }
  }
  
  # Determine based on actual connectivity and speed
  switch ($ProxyMode) {
    'global' {
      # Compare npm registry speeds
      if ($Connectivity.NpmjsOK -and $Connectivity.NpmmirrorOK) {
        # Both accessible, choose faster one
        if ($Connectivity.NpmjsTime -le $Connectivity.NpmmirrorTime) {
          return 'global'
        } else {
          return 'china'
        }
      }
      elseif ($Connectivity.NpmjsOK) {
        return 'global'
      }
      elseif ($Connectivity.NpmmirrorOK) {
        return 'china'
      }
      return 'global'
    }
    'direct' {
      # Direct connection in China, use China mirror
      return 'china'
    }
    'rule' {
      # Rule-based proxy, test both and pick faster
      if ($Connectivity.NpmmirrorOK -and (-not $Connectivity.NpmjsOK -or $Connectivity.NpmmirrorTime -lt $Connectivity.NpmjsTime)) {
        return 'china'
      }
      return 'global'
    }
    default {
      return 'unknown'
    }
  }
}

# Main network detection function
function Initialize-NetworkDetection() {
  if ($null -ne $script:NetworkInfo) { return $script:NetworkInfo }
  
  Write-Info "Detecting network environment..."
  
  # Collect all proxy settings
  $sysProxy = Get-SystemProxySettings
  $envProxy = Get-EnvProxySettings
  
  # Check if any proxy is configured
  $hasProxy = $sysProxy.Enabled -or $sysProxy.AutoConfig -or 
              (-not [string]::IsNullOrWhiteSpace($envProxy.HttpProxy)) -or
              (-not [string]::IsNullOrWhiteSpace($envProxy.HttpsProxy)) -or
              (-not [string]::IsNullOrWhiteSpace($envProxy.AllProxy))
  
  # Show proxy status
  if ($hasProxy) {
    if ($sysProxy.Enabled) {
      Write-Info "System proxy detected: $($sysProxy.Server)"
    }
    if ($sysProxy.AutoConfig) {
      Write-Info "PAC auto-config detected: $($sysProxy.AutoConfigUrl)"
    }
    if ($envProxy.HttpProxy -or $envProxy.HttpsProxy) {
      $proxyUrl = if ($envProxy.HttpsProxy) { $envProxy.HttpsProxy } else { $envProxy.HttpProxy }
      Write-Info "Environment proxy detected: $proxyUrl"
    }
  } else {
    Write-Info "No proxy configured (direct connection)"
  }
  
  # Test actual connectivity
  Write-Info "Testing connectivity to determine best npm source..."
  $connectivity = Test-ActualConnectivity
  
  # Determine proxy mode
  $proxyMode = Get-ProxyMode $connectivity
  
  # Determine effective region
  $region = Get-EffectiveRegion $connectivity $proxyMode
  
  # Build result
  $script:NetworkInfo = @{
    HasProxy = $hasProxy
    SystemProxy = $sysProxy
    EnvProxy = $envProxy
    Connectivity = $connectivity
    ProxyMode = $proxyMode
    Region = $region
  }
  
  # Log detection results
  $modeDesc = switch ($proxyMode) {
    'global' { 'Global proxy (all traffic proxied)' }
    'direct' { 'Direct connection (China network)' }
    'rule'   { 'Rule-based proxy (selective)' }
    default  { 'Unknown (network issues)' }
  }
  Write-Info "Network mode: $modeDesc"
  Write-Info "Effective region for npm: $region"
  
  return $script:NetworkInfo
}

# Get current npm registry
function Get-NpmRegistry() {
  try {
    $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
    if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
    if ($npmCmd) {
      $registry = & $npmCmd.Path config get registry 2>$null
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($registry)) {
        return $registry.Trim().TrimEnd('/')
      }
    }
  } catch { }
  return $script:NpmMirrors['default']
}

# Set npm registry
function Set-NpmRegistry([string]$Registry) {
  try {
    $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
    if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
    if ($npmCmd) {
      & $npmCmd.Path config set registry $Registry 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Info "npm registry set to: $Registry"
        return $true
      }
    }
  } catch { }
  Write-Warn "Failed to set npm registry"
  return $false
}

# Select best npm mirror based on network detection
function Get-BestNpmMirror() {
  $netInfo = Initialize-NetworkDetection
  
  if ($netInfo.Region -eq 'china') {
    # For China, test mirrors and pick fastest
    $connectivity = $netInfo.Connectivity
    if ($connectivity.NpmmirrorOK) {
      Write-Info "Using China npm mirror: npmmirror (taobao)"
      return $script:NpmMirrors['taobao']
    }
    # Try other China mirrors
    foreach ($name in @('tencent', 'huawei')) {
      $url = $script:NpmMirrors[$name]
      try {
        $null = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        Write-Info "Using China npm mirror: $name"
        return $url
      } catch { continue }
    }
    # Fallback to taobao
    Write-Info "Using China npm mirror: npmmirror (taobao) [fallback]"
    return $script:NpmMirrors['taobao']
  }
  
  Write-Info "Using official npm registry"
  return $script:NpmMirrors['default']
}

# Configure npm for optimal speed based on network detection
function Initialize-NpmForRegion() {
  # Save original registry
  $script:OriginalNpmRegistry = Get-NpmRegistry
  
  $bestMirror = Get-BestNpmMirror
  $currentRegistry = Get-NpmRegistry
  
  if ($currentRegistry.TrimEnd('/') -ne $bestMirror.TrimEnd('/')) {
    Write-Info "Switching npm registry for better speed..."
    [void](Set-NpmRegistry $bestMirror)
  } else {
    Write-Info "npm registry already optimal: $currentRegistry"
  }
}

# Restore original npm registry
function Restore-NpmRegistry() {
  if ($null -ne $script:OriginalNpmRegistry) {
    $current = Get-NpmRegistry
    if ($current.TrimEnd('/') -ne $script:OriginalNpmRegistry.TrimEnd('/')) {
      Write-Info "Restoring original npm registry: $($script:OriginalNpmRegistry)"
      [void](Set-NpmRegistry $script:OriginalNpmRegistry)
    }
  }
}

# Fetch text content, return $null on failure
function Get-Text([string]$Uri) {
  $tries = Get-RetryCount
  for ($i = 1; $i -le $tries; $i++) {
    try {
      $content = (Invoke-WebRequestWithHeaders $Uri $null).Content
      if ($content -is [string]) { return $content }
      if ($content -is [string[]]) { return ($content -join "`n") }
      if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
      return ($content | Out-String)
    } catch {
      if ($i -eq $tries) {
        Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
        return $null
      }
      Start-Sleep -Seconds 2
    }
  }
}

# Fetch JSON, return $null on failure
function Get-Json([string]$Uri) {
  $tries = Get-RetryCount
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  for ($i = 1; $i -le $tries; $i++) {
    try {
      return Invoke-RestMethod -Uri $Uri -Headers $headers -ErrorAction Stop
    } catch {
      if ($i -eq $tries) {
        Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
        return $null
      }
      Start-Sleep -Seconds 2
    }
  }
}

# Extract x.y.z from arbitrary text
function Get-SemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
}

# Split version into integer parts for comparison
function Get-VersionParts([string]$Version) {
  $v = Get-SemVer $Version
  if (-not $v) { return $null }
  $p = $v.Split('.')
  return @([int]$p[0], [int]$p[1], [int]$p[2])
}

# Compare versions: returns -1/0/1, or $null if not comparable
function Compare-Version([string]$Current, [string]$Latest) {
  $a = Get-VersionParts $Current
  $b = Get-VersionParts $Latest
  if (-not $a -or -not $b) { return $null }
  for ($i = 0; $i -lt 3; $i++) {
    if ($a[$i] -lt $b[$i]) { return -1 }
    if ($a[$i] -gt $b[$i]) { return 1 }
  }
  return 0
}

function Get-CommandVersionInfo([string]$CommandName) {
  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
  if (-not $cmd) { return @{ Name = $CommandName; Version = $null; Source = $null } }
  try {
    $out = & $CommandName '--version' 2>$null | Out-String
    $v = Get-SemVer $out
    if ($v) {
      return @{ Name = $CommandName; Version = $v; Source = $cmd.Source }
    }
    Write-Warn "Failed to parse local version from: $CommandName"
  } catch {
    Write-Warn "Failed to run: $CommandName --version ($($_.Exception.Message))"
  }
  return @{ Name = $CommandName; Version = $null; Source = $cmd.Source }
}

# Get local command version, return $null if missing or failed
function Get-LocalCommandVersion([string[]]$CommandNames) {
  foreach ($name in $CommandNames) {
    $info = Get-CommandVersionInfo $name
    if ($info.Version) { return $info.Version }
  }
  return $null
}

function Get-LocalClaudeVersion() {
  [void](Repair-ToolUserPath 'claude')
  return Get-LocalCommandVersion @('claude','claude-code')
}

function Get-LocalCodexVersion() {
  [void](Repair-ToolUserPath 'codex')
  return Get-LocalCommandVersion @('codex')
}

function Get-LocalGeminiVersion() {
  [void](Repair-ToolUserPath 'gemini')
  return Get-LocalCommandVersion @('gemini')
}

function Get-LocalFactoryVersion() {
  [void](Repair-ToolUserPath 'factory')
  $droid = Get-CommandVersionInfo 'droid'
  $factory = Get-CommandVersionInfo 'factory'

  if ($droid.Version) {
    if ($factory.Version) {
      $cmp = Compare-Version $factory.Version $droid.Version
      if ($cmp -eq -1) {
        $factorySource = if ($factory.Source) { $factory.Source } else { 'factory' }
        $droidSource = if ($droid.Source) { $droid.Source } else { 'droid' }
        Write-Warn "Factory alias mismatch detected: factory resolves to v$($factory.Version) at $factorySource, but droid resolves to v$($droid.Version) at $droidSource. Using droid for version checks."
      }
    }
    return $droid.Version
  }

  if ($factory.Version) { return $factory.Version }
  return $null
}

# Extract latest Factory CLI version from its Windows installer script
function Get-LatestFactoryVersion() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) { return $null }
  $m = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
  if (-not $m.Success) { return $null }
  return Get-SemVer $m.Groups[1].Value
}

function Get-NpmLatestVersion([string]$PackageName) {
  $json = Get-Json "https://registry.npmjs.org/$PackageName/latest"
  if (-not $json -or -not $json.version) { return $null }
  return Get-SemVer ([string]$json.version)
}

function Get-GitHubLatestReleaseVersion([string]$Repo) {
  $json = Get-Json "https://api.github.com/repos/$Repo/releases/latest"
  if (-not $json -or -not $json.tag_name) { return $null }
  return Get-SemVer ([string]$json.tag_name)
}

function Get-ClaudeBootstrapStableVersion() {
  $text = Get-Text 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/stable'
  return Get-SemVer $text
}

function Get-ClaudeRepoLatestVersion() {
  return Get-GitHubLatestReleaseVersion 'anthropics/claude-code'
}

function Select-HigherVersion([string]$First, [string]$Second) {
  if (-not $First) { return $Second }
  if (-not $Second) { return $First }
  if ((Compare-Version $First $Second) -eq -1) { return $Second }
  return $First
}

function Resolve-VersionConflict([string]$ToolName, [string]$PrimaryLabel, [string]$Primary, [string]$SecondaryLabel, [string]$Secondary) {
  $selected = Select-HigherVersion $Primary $Secondary
  if ($Primary -and $Secondary -and $Primary -ne $Secondary) { Write-Warn "$ToolName latest version conflict: $PrimaryLabel=v$Primary, $SecondaryLabel=v$Secondary. Using v$selected." }
  return $selected
}

function Get-LatestClaudeVersion() {
  $repo = Get-ClaudeRepoLatestVersion
  if ($repo) { return $repo }
  $stable = Get-ClaudeBootstrapStableVersion
  if ($stable) { return $stable }
  return Get-NpmLatestVersion '@anthropic-ai/claude-code'
}

function Get-LatestCodexVersion() {
  $repo = Get-GitHubLatestReleaseVersion 'openai/codex'
  if ($repo) { return $repo }
  return Get-NpmLatestVersion '@openai/codex'
}

function Get-LatestGeminiVersion() {
  $repo = Get-GitHubLatestReleaseVersion 'google-gemini/gemini-cli'
  if ($repo) { return $repo }
  return Get-NpmLatestVersion '@google/gemini-cli'
}

function Get-TargetOpenCodeVersion() {
  $v = $env:CHECK_AI_CLI_OPENCODE_VERSION
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return Get-SemVer $v
}

function Get-LatestOpenCodeVersion() {
  $target = Get-TargetOpenCodeVersion
  if ($target) { return $target }

  $repo = Get-GitHubLatestReleaseVersion 'anomalyco/opencode'
  if ($repo) { return $repo }
  $npm = Get-NpmLatestVersion 'opencode-ai'
  if ($npm) { return $npm }
  Write-Warn 'Failed to determine latest OpenCode version from official sources.'
  return $null
}

# Run npm install -g in a way that avoids PowerShell npm.ps1 "-Command" parsing edge cases.
function Invoke-NpmInstallGlobal([string]$PackageSpec) {
  $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
  if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
  if ($npmCmd) {
    & $npmCmd.Path install -g $PackageSpec
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    return
  }

  $npmPs1 = Get-Command npm -CommandType ExternalScript -ErrorAction SilentlyContinue
  if (-not $npmPs1) { throw "npm not found. Install Node.js first." }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $npmPs1.Path install -g $PackageSpec
  if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
}

# Standard yes/no confirmation prompt
function Confirm-Yes([string]$Prompt) {
  if ($script:AutoMode) { return $true }
  $ans = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans.Trim().ToUpperInvariant().StartsWith('Y')
}

# Security warning for remote script execution
function Confirm-RemoteScriptExecution([string]$Url, [string]$ToolName, [string]$ActionDescription = 'download and execute a script from the internet', [string]$WarningTitle = 'Remote Script Execution') {
  if ($script:AutoMode) {
    Write-Warn "[SECURITY] Auto mode: $ActionDescription from $Url"
    return $true
  }
  Write-Host ''
  Write-Warn '============================================================='
  Write-Warn "  SECURITY WARNING: $WarningTitle"
  Write-Warn '============================================================='
  Write-Host ('Tool: ' + $ToolName) -ForegroundColor Yellow
  Write-Host ('URL:  ' + $Url) -ForegroundColor Yellow
  Write-Host ''
  Write-Host ('This will ' + $ActionDescription + '.') -ForegroundColor Red
  Write-Host 'Only proceed if you trust the source.' -ForegroundColor Red
  Write-Host ''
  $ans = Read-Host 'Type YES to confirm execution'
  return $ans -eq 'YES'
}

# Install/update Factory CLI
function Update-Factory() {
  Write-Info "Updating Factory CLI (Droid)..."
  Write-Info "Trying: official bootstrap"
  $url = 'https://app.factory.ai/cli/windows'
  $actionDescription = 'fetch metadata from the official bootstrap, then download and install verified binaries locally'
  if (-not (Confirm-RemoteScriptExecution $url 'Factory CLI' $actionDescription 'Verified Binary Download')) {
    Write-Warn "Installation cancelled by user."
    return
  }
  try {
    Install-FactoryFromBootstrap
  } catch {
    throw "Factory CLI installer failed: $($_.Exception.Message)"
  }
}

# Install/update Claude Code via official bootstrap (GCS binary)
function Update-ClaudeViaBootstrap() {
  Write-Info "Trying: official bootstrap"

  # Check for 32-bit Windows
  if (-not [Environment]::Is64BitProcess) {
    throw "Claude Code does not support 32-bit Windows."
  }

  $GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
  $DOWNLOAD_DIR = "$env:USERPROFILE\.claude\downloads"
  $platform = "win32-x64"

  New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

  # Get stable version
  try {
    $version = Invoke-RestMethod -Uri "$GCS_BUCKET/stable" -ErrorAction Stop
  } catch {
    throw "Failed to get stable version: $($_.Exception.Message)"
  }

  # Get manifest and checksum
  try {
    $manifest = Invoke-RestMethod -Uri "$GCS_BUCKET/$version/manifest.json" -ErrorAction Stop
    $checksum = $manifest.platforms.$platform.checksum
    if (-not $checksum) { throw "Platform $platform not found in manifest" }
  } catch {
    throw "Failed to get manifest: $($_.Exception.Message)"
  }

  # Download binary
  $binaryPath = "$DOWNLOAD_DIR\claude-$version-$platform.exe"
  try {
    $mode = 'Continue'
    if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
    Invoke-WithTempProgressPreference $mode {
      Invoke-WebRequest -Uri "$GCS_BUCKET/$version/$platform/claude.exe" -OutFile $binaryPath -ErrorAction Stop
    }
  } catch {
    if (Test-Path $binaryPath) { Remove-Item -Force $binaryPath }
    throw "Failed to download binary: $($_.Exception.Message)"
  }

  # Verify checksum
  $actualChecksum = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
  if ($actualChecksum -ne $checksum) {
    Remove-Item -Force $binaryPath
    throw "Checksum verification failed"
  }

  # Run claude install
  try {
    & $binaryPath install
  } finally {
    Start-Sleep -Seconds 1
    try { Remove-Item -Force $binaryPath } catch { Write-Warn "Could not remove temporary file: $binaryPath" }
  }
}

# Install/update Claude Code (official stable preferred, npm fallback)
function Update-Claude() {
  Write-Info "Updating Claude Code..."

  try {
    Update-ClaudeViaBootstrap
    return
  } catch {
    Write-Warn "official bootstrap failed: $($_.Exception.Message)"
  }

  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@anthropic-ai/claude-code@latest'
  } catch {
    throw "No installer found. Install curl/wget or Node.js (npm) first."
  }
}

# Install/update OpenAI Codex (Windows defaults to npm)
function Update-Codex() {
  Write-Info "Updating OpenAI Codex..."
  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@openai/codex'
  } catch {
    throw "No installer found. Install Node.js (npm) first."
  }
}

# Install/update Gemini CLI (prefers npm)
function Update-Gemini() {
  Write-Info "Updating Gemini CLI..."
  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@google/gemini-cli@latest'
  } catch {
    throw "No installer found. Install Node.js (npm) first."
  }
}

function Get-OpenCodeUserInstallPath() {
  $dir = Join-Path $env:USERPROFILE '.opencode\bin'
  foreach ($name in @('opencode.exe','opencode')) {
    $p = Join-Path $dir $name
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Get-OpenCodeUserBinDir() {
  $path = Get-OpenCodeUserInstallPath
  if (-not $path) { return $null }
  return (Split-Path -Parent $path)
}

function Repair-OpenCodeUserPath() {
  return (Repair-ToolUserPath 'opencode')
}

function New-OpenCodeCommandInfo([string]$Path, [string]$Version) {
  return @{ Name = 'opencode'; Source = $Path; Version = $Version }
}

function Get-OpenCodeUserInfo() {
  $path = Get-OpenCodeUserInstallPath
  if (-not $path) { return $null }
  return (New-OpenCodeCommandInfo $path (Get-OpenCodeVersionAtPath $path))
}

function Should-PreferOpenCodeUserInfo([hashtable]$Resolved, [hashtable]$User) {
  if (-not $User -or -not $User.Source) { return $false }
  if (-not $Resolved -or -not $Resolved.Source) { return $true }
  if ($Resolved.Source -eq $User.Source) { return $true }
  if (-not $User.Version) { return $false }
  if (-not $Resolved.Version) { return $true }
  return (Compare-Version $User.Version $Resolved.Version) -ge 0
}

function Get-PreferredOpenCodeInfo() {
  [void](Repair-OpenCodeUserPath)
  $resolved = Get-OpenCodeResolvedInfo
  $user = Get-OpenCodeUserInfo
  if (Should-PreferOpenCodeUserInfo $resolved $user) { return $user }
  return $resolved
}

function Report-OpenCodeResolutionMismatch() {
  $resolved = Get-OpenCodeResolvedInfo
  $user = Get-OpenCodeUserInfo
  if (-not $user) { return }
  if (Should-PreferOpenCodeUserInfo $resolved $user) { return }
  if (-not $resolved.Source) { Write-OpenCodeStandaloneOnly $user.Source $user.Version ; return }
  Write-OpenCodeResolvedMismatch $resolved $user.Source $user.Version
}

function Write-OpenCodeResolutionTips([string]$UserPath) {
  $binDir = Split-Path -Parent $UserPath
  Write-Warn "Tip: ensure User PATH starts with $binDir"
  Write-Warn 'Tip: restart PowerShell after PATH changes if this session still resolves an older shim'
}

function Write-OpenCodeStandaloneOnly([string]$UserPath, [string]$UserVersion) {
  Write-Warn 'PowerShell cannot resolve opencode from the current PATH.'
  Write-Warn "OpenCode user install path: $UserPath"
  if ($UserVersion) { Write-Warn "OpenCode user install version: v$UserVersion" }
  Write-OpenCodeResolutionTips $UserPath
}

function Write-OpenCodeResolvedMismatch([hashtable]$Resolved, [string]$UserPath, [string]$UserVersion) {
  Write-Warn "PowerShell resolves opencode to: $($Resolved.Source)"
  if ($Resolved.Version) { Write-Warn "Resolved opencode version: v$($Resolved.Version)" }
  Write-Warn "OpenCode user install path: $UserPath"
  if ($UserVersion) { Write-Warn "OpenCode user install version: v$UserVersion" }
  Write-OpenCodeResolutionTips $UserPath
}

function Get-OpenCodeResolvedInfo() {
  return Get-CommandVersionInfo 'opencode'
}

function Get-OpenCodeVersionAtPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  try { return Get-SemVer ((& $Path '--version' 2>&1 | Out-String)) } catch { return $null }
}

function Get-OpenCodeCommandPath() {
  return (Get-PreferredOpenCodeInfo).Source
}

function Invoke-OpenCodeVersionProbe() {
  $preferred = Get-PreferredOpenCodeInfo
  if (-not $preferred.Source) { return @{ Version = $null; Output = '' } }
  try {
    $out = & $preferred.Source '--version' 2>&1 | Out-String
    return @{ Version = (Get-SemVer $out); Output = $out }
  } catch {
    return @{ Version = $null; Output = $_.Exception.Message }
  }
}

function Get-OpenCodeNpmExePath() {
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) { return $null }
  $baseDir = Split-Path -Parent $cmd.Source
  $glob = Join-Path $baseDir 'node_modules\opencode-ai\node_modules\opencode-*\bin\opencode.exe'
  $hit = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Get-LocalOpenCodeVersion() {
  $preferred = Get-PreferredOpenCodeInfo
  Report-OpenCodeResolutionMismatch
  return $preferred.Version
}

function Try-FixOpenCodeNpmShim([string]$ExePath) {
  if ([string]::IsNullOrWhiteSpace($ExePath)) { return $false }
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $cmd -or $cmd.CommandType -ne 'ExternalScript') { return $false }
  if (-not (Test-Path -LiteralPath $cmd.Source)) { return $false }
  $text = [IO.File]::ReadAllText($cmd.Source)
  if (-not $text.Contains('/bin/sh')) { return $false }
  
  # Create backup before modifying
  $backupPath = "$($cmd.Source).backup"
  try {
    Copy-Item -LiteralPath $cmd.Source -Destination $backupPath -Force
    Write-Info "Created backup: $backupPath"
  } catch {
    Write-Warn "Failed to create backup, aborting shim fix: $($_.Exception.Message)"
    return $false
  }
  
  $repl = '& "' + $ExePath + '" $args'
  $newText = [regex]::Replace($text, '&\s+\"/bin/sh\$exe\"[^\r\n]*', $repl)
  $enc = New-Object System.Text.UTF8Encoding($false)
  try {
    [IO.File]::WriteAllText($cmd.Source, $newText, $enc)
    Write-Info "Fixed npm shim: $($cmd.Source)"
    return $true
  } catch {
    # Restore from backup on failure
    Write-Warn "Failed to write shim, restoring backup: $($_.Exception.Message)"
    try { Copy-Item -LiteralPath $backupPath -Destination $cmd.Source -Force } catch { }
    return $false
  }
}

function Test-OpenCodeRunnable() {
  return [bool](Get-LocalOpenCodeVersion)
}

function Try-RepairOpenCodeNpmShim() {
  $exe = Get-OpenCodeNpmExePath
  if (-not $exe) { return $false }
  return Try-FixOpenCodeNpmShim $exe
}

function Get-OpenCodeMissingRuntimePackageName([string]$Text) {
  if ($Text -match '\"(opencode-(?:win32|windows)-[a-z0-9-]+)\"') { return $Matches[1] }
  return $null
}

function Try-InstallOpenCodeRuntimePackage([string]$TargetVersion) {
  $probe = Invoke-OpenCodeVersionProbe
  $pkg = Get-OpenCodeMissingRuntimePackageName $probe.Output
  if (-not $pkg) { return $false }
  Write-Warn "Trying npm install for missing runtime package: $pkg"
  try { Invoke-NpmInstallGlobal $pkg } catch { return $false }
  return (Test-OpenCodeRunnable)
}

function Try-OpenCodeSelfUpgrade([string]$TargetVersion) {
  $path = Get-OpenCodeCommandPath
  if (-not $path) { return $false }
  $arg = $null
  if ($TargetVersion) { $arg = "v$TargetVersion" }
  try {
    if ($arg) { & $path upgrade $arg } else { & $path upgrade }
    if ($LASTEXITCODE -ne 0) { throw "opencode upgrade failed with exit code $LASTEXITCODE" }
    return $true
  } catch {
    Write-Warn "opencode upgrade failed: $($_.Exception.Message)"
    return $false
  }
}

function Get-BashCommandPath() {
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\bash.exe"
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  return $null
}

function Test-BashUsable([string]$BashPath) {
  if ([string]::IsNullOrWhiteSpace($BashPath)) { return $false }
  try {
    $out = & $BashPath -lc 'echo __bash_ok__' 2>$null | Out-String
    return $LASTEXITCODE -eq 0 -and $out.Trim() -eq '__bash_ok__'
  } catch {
    return $false
  }
}

function Try-InstallOpenCodeWithCurl([string]$TargetVersion) {
  $bash = Get-BashCommandPath
  if (-not $bash) { return $false }
  if (-not (Test-BashUsable $bash)) {
    Write-Warn "bash found but not usable. Skipping curl install. Tip: install Git for Windows (Git Bash) or a WSL distro."
    return $false
  }
  $v = Get-SemVer $TargetVersion
  $cmd = 'curl -fsSL https://opencode.ai/install | bash'
  if ($v) { $cmd = "curl -fsSL https://opencode.ai/install | bash -s -- --version $v" }
  try {
    & $bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { Write-Warn "curl install failed with exit code $LASTEXITCODE" ; return $false }
    return $true
  } catch {
    Write-Warn "curl install failed: $($_.Exception.Message)"
    return $false
  }
}

function Test-OpenCodeAtLeast([string]$TargetVersion) {
  $v = Get-LocalOpenCodeVersion
  if (-not $v) { return $false }
  if (-not $TargetVersion) { return $true }
  $cmp = Compare-Version $v $TargetVersion
  return ($cmp -eq 0 -or $cmp -eq 1)
}

function Try-InstallOpenCodeWithScoop() {
  $cmd = Get-Command scoop -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  & scoop install extras/opencode
  if ($LASTEXITCODE -eq 0) { return $true }
  & scoop bucket add extras 2>$null | Out-Null
  & scoop install extras/opencode
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "scoop install failed with exit code $LASTEXITCODE"
    return $false
  }
  return $true
}

function Try-InstallOpenCodeWithChoco() {
  $cmd = Get-Command choco -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  & choco upgrade opencode -y
  if ($LASTEXITCODE -eq 0) { return $true }
  & choco install opencode -y
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "choco install failed with exit code $LASTEXITCODE"
    return $false
  }
  return $true
}

function Try-InstallOpenCodeWithNpm([string]$TargetVersion) {
  try {
    Invoke-NpmInstallGlobal 'opencode-ai@latest'
    if (Test-OpenCodeRunnable) { return $true }
    if (Try-RepairOpenCodeNpmShim -and (Test-OpenCodeRunnable)) { return $true }
    if (Try-InstallOpenCodeRuntimePackage $TargetVersion -and (Test-OpenCodeRunnable)) { return $true }
    Write-Warn "opencode installed but still not runnable. Prefer scoop/choco, or run the bundled exe under npm node_modules."
    return $false
  } catch {
    Write-Warn "npm install failed: $($_.Exception.Message)"
    return $false
  }
}

function Update-OpenCode() {
  Write-Info "Updating OpenCode..."
  $target = Get-TargetOpenCodeVersion
  if ($target) { Write-Info "Target OpenCode version: v$target" }
  Write-Info "Trying: curl/wget install"
  if (Try-InstallOpenCodeWithCurl $target -and (Test-OpenCodeAtLeast $target)) { return }
  $installed = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
  if ($installed) {
    Write-Info "Trying: opencode upgrade"
    Try-OpenCodeSelfUpgrade $target | Out-Null
    if (Test-OpenCodeAtLeast $target) { return }
  }
  Write-Info "Trying: scoop install"
  if (Try-InstallOpenCodeWithScoop) { Try-OpenCodeSelfUpgrade $target | Out-Null ; if (Test-OpenCodeAtLeast $target) { return } }
  Write-Info "Trying: choco install"
  if (Try-InstallOpenCodeWithChoco) { Try-OpenCodeSelfUpgrade $target | Out-Null ; if (Test-OpenCodeAtLeast $target) { return } }
  Write-Info "Trying: npm install"
  if (Try-InstallOpenCodeWithNpm $target -and (Test-OpenCodeAtLeast $target)) { return }
  throw "No installer found. Install Git Bash (for curl), scoop/choco, or Node.js (npm) first."
}

function Write-ToolHeader([string]$Title) {
  Write-Host ""
  Write-Host $Title
  Write-Host ('=' * $Title.Length)
}

function Get-AndPrintLatest([scriptblock]$GetLatest) {
  Write-Info "Fetching latest version..."
  $latest = & $GetLatest
  if ($latest) { Write-Success "Latest version: v$latest" } else { Write-Warn "Latest version: unknown" }
  return $latest
}

function Get-AndPrintLocal([scriptblock]$GetLocal) {
  $local = & $GetLocal
  if ($local) { Write-Success "Local version: v$local" } else { Write-Warn "Local version: not installed" }
  return $local
}

function Try-Update([scriptblock]$DoUpdate) {
  try { & $DoUpdate } catch { Write-Fail $_.Exception.Message }
}

function Handle-UpdateFlow([string]$Latest, [string]$Local, [scriptblock]$DoUpdate) {
  if (-not $Local) {
    if (-not $Latest) { Write-Warn "Latest version unknown. Installing anyway." }
    if (Confirm-Yes "Install now? (Y/N): ") { Try-Update $DoUpdate ; return $true }
    return $false
  }
  if (-not $Latest) { Write-Warn "Latest version unknown. Skipping update check." ; return $false }
  $cmp = Compare-Version $Local $Latest
  if ($cmp -eq 0) { Write-Success "Already up to date." ; return $false }
  if ($cmp -eq 1) { Write-Warn "Local version is newer than latest source." ; return $false }
  if ($cmp -eq -1 -and (Confirm-Yes "Update now? (Y/N): ")) { Try-Update $DoUpdate ; return $true }
  return $false
}

function Report-PostUpdate([string]$Title, [string]$Latest, [scriptblock]$GetLocal) {
  Write-Info "Re-checking local version..."
  $newLocal = Get-AndPrintLocal $GetLocal
  if (-not $newLocal) { Write-Warn "Update may not have installed correctly." ; return }
  if (-not $Latest) { return }
  $cmp = Compare-Version $newLocal $Latest
  if ($cmp -eq -1) {
    Write-Warn "Update may have failed (still older than latest)."
    if ($Title -eq 'Claude Code') { Write-Warn "Tip: try npm install -g @anthropic-ai/claude-code@latest" }
    if ($Title -eq 'OpenCode') {
      if ($Latest) { Write-Warn "Tip: try opencode upgrade v$Latest" } else { Write-Warn "Tip: try opencode upgrade" }
      Write-Warn "Tip: override target via CHECK_AI_CLI_OPENCODE_VERSION"
      Write-Warn "Tip: Windows recommend scoop/choco: scoop install extras/opencode OR choco install opencode -y"
    }
  }
}

function Check-OneTool([string]$Title, [scriptblock]$GetLatest, [scriptblock]$GetLocal, [scriptblock]$DoUpdate) {
  Write-ToolHeader $Title
  $latest = Get-AndPrintLatest $GetLatest
  $local = Get-AndPrintLocal $GetLocal
  $didUpdate = Handle-UpdateFlow $latest $local $DoUpdate
  if ($didUpdate) { Report-PostUpdate $Title $latest $GetLocal }
}

function Show-Banner() {
  Write-Host ""
  Write-Host "==============================================="
  Write-Host " AI CLI Version Checker"
  Write-Host " Factory CLI (Droid) | Claude Code | OpenAI Codex | Gemini CLI | OpenCode"
  Write-Host "==============================================="
  Write-Host ""
}

function Ask-Selection() {
  Write-Host "Select tools to check:"
  Write-Host "  [1] Factory CLI (Droid)"
  Write-Host "  [2] Claude Code"
  Write-Host "  [3] OpenAI Codex"
  Write-Host "  [4] Gemini CLI"
  Write-Host "  [5] OpenCode"
  Write-Host "  [A] Check all (default)"
  Write-Host "  [U] Check all and Update all (auto-yes)"
  Write-Host "  [Q] Quit"
  $s = Read-Host 'Enter choice (1-5/A/U/Q)'
  if ([string]::IsNullOrWhiteSpace($s)) { return 'A' }
  return $s.Trim().ToUpperInvariant()
}

function Invoke-Selection([string]$Selection) {
  # U = Update all (auto-yes mode for all tools)
  $checkAll = ($Selection -eq 'A' -or $Selection -eq 'U')
  if ($Selection -eq 'U') { $script:AutoMode = $true }
  
  if ($Selection -eq '1' -or $checkAll) {
    Check-OneTool "Factory CLI (Droid)" { Get-LatestFactoryVersion } { Get-LocalFactoryVersion } { Update-Factory }
  }
  if ($Selection -eq '2' -or $checkAll) {
    Check-OneTool "Claude Code" { Get-LatestClaudeVersion } { Get-LocalClaudeVersion } { Update-Claude }
  }
  if ($Selection -eq '3' -or $checkAll) {
    Check-OneTool "OpenAI Codex" { Get-LatestCodexVersion } { Get-LocalCodexVersion } { Update-Codex }
  }
  if ($Selection -eq '4' -or $checkAll) {
    Check-OneTool "Gemini CLI" { Get-LatestGeminiVersion } { Get-LocalGeminiVersion } { Update-Gemini }
  }
  if ($Selection -eq '5' -or $checkAll) {
    Check-OneTool "OpenCode" { Get-LatestOpenCodeVersion } { Get-LocalOpenCodeVersion } { Update-OpenCode }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Require-WebRequest
  Show-Banner

  # Initialize network detection and optimize npm registry
  Initialize-NpmForRegion

  if ($FactoryOnly) {
    Invoke-Selection '1'
    Restore-NpmRegistry
    exit 0
  }

  $sel = Ask-Selection
  if ($sel -eq 'Q') {
    Restore-NpmRegistry
    exit 0
  }
  Invoke-Selection $sel
  Restore-NpmRegistry
}
