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
    Set-NpmRegistry $bestMirror
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
      Set-NpmRegistry $script:OriginalNpmRegistry
    }
  }
}

# Fetch text content, return $null on failure
function Get-Text([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    $content = (Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing).Content
    if ($content -is [string]) { return $content }
    if ($content -is [string[]]) { return ($content -join "`n") }
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return ($content | Out-String)
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
  }
}

# Fetch JSON, return $null on failure
function Get-Json([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
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

# Get local command version, return $null if missing or failed
function Get-LocalCommandVersion([string[]]$CommandNames) {
  foreach ($name in $CommandNames) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try {
      $out = & $name '--version' 2>$null | Out-String
      $v = Get-SemVer $out
      if ($v) { return $v }
      Write-Warn "Failed to parse local version from: $name"
    } catch {
      Write-Warn "Failed to run: $name --version ($($_.Exception.Message))"
    }
  }
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

# Get latest Claude Code version from npm registry (fallback source)
function Get-LatestClaudeVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

# Get latest Codex version from GitHub Releases API
function Get-LatestCodexVersion() {
  $json = Get-Json 'https://api.github.com/repos/openai/codex/releases/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.tag_name)
}

# Get latest Gemini CLI version from npm registry
function Get-LatestGeminiVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@google/gemini-cli/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

function Get-TargetOpenCodeVersion() {
  $v = $env:CHECK_AI_CLI_OPENCODE_VERSION
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return Get-SemVer $v
}

function Get-LatestOpenCodeVersion() {
  $target = Get-TargetOpenCodeVersion
  if ($target) { return $target }

  try {
    $json = Get-Json 'https://api.github.com/repos/anomalyco/opencode/releases/latest'
    if ($json -and $json.tag_name) {
      return Get-SemVer ([string]$json.tag_name)
    }
  } catch {
    Write-Warn "Failed to fetch latest OpenCode version from GitHub: $($_.Exception.Message)"
  }

  Write-Warn "Using fallback OpenCode version: 1.1.21"
  $fallback = Get-SemVer '1.1.21'
  if (-not $fallback) {
    Write-Error "Critical: Failed to parse fallback version. This should never happen."
    throw "Unable to determine OpenCode version"
  }
  return $fallback
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
function Confirm-RemoteScriptExecution([string]$Url, [string]$ToolName) {
  if ($script:AutoMode) {
    Write-Warn "[SECURITY] Auto mode: executing remote script from $Url"
    return $true
  }
  Write-Host ""
  Write-Warn "┌─────────────────────────────────────────────────────────────┐"
  Write-Warn "│ SECURITY WARNING: Remote Script Execution                   │"
  Write-Warn "└─────────────────────────────────────────────────────────────┘"
  Write-Host "Tool: $ToolName" -ForegroundColor Yellow
  Write-Host "URL:  $Url" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "This will download and execute a script from the internet." -ForegroundColor Red
  Write-Host "Only proceed if you trust the source." -ForegroundColor Red
  Write-Host ""
  $ans = Read-Host "Type 'YES' to confirm execution"
  return $ans -eq 'YES'
}

# Install/update Factory CLI
function Update-Factory() {
  Write-Info "Updating Factory CLI (Droid)..."
  Write-Info "Trying: official bootstrap"
  $url = 'https://app.factory.ai/cli/windows'
  if (-not (Confirm-RemoteScriptExecution $url 'Factory CLI')) {
    Write-Warn "Installation cancelled by user."
    return
  }
  try {
    $script = Get-Text $url
    if (-not $script) { throw "Failed to download installer script." }
    $mode = 'Continue'
    if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
    Invoke-WithTempProgressPreference $mode { Invoke-Expression $script }
  } catch {
    throw "Factory CLI installer failed."
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

# Install/update Claude Code (npm preferred, bootstrap fallback)
function Update-Claude() {
  Write-Info "Updating Claude Code..."

  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@anthropic-ai/claude-code@latest'
    return
  } catch {
    Write-Warn "npm install failed: $($_.Exception.Message)"
  }

  try {
    Update-ClaudeViaBootstrap
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

function Report-OpenCodeResolutionMismatch() {
  $user = Get-OpenCodeUserInstallPath
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $user -or -not $cmd -or -not $cmd.Source) { return }
  if ($cmd.Source -eq $user) { return }
  Write-Warn "PowerShell resolves opencode to: $($cmd.Source)"
  Write-Warn "OpenCode user install path: $user"
  Write-Warn "Tip: current session: Set-Alias opencode `"$user`""
  Write-Warn 'Tip: permanent: add the same line into $PROFILE'
}

function Get-OpenCodeCommandPath() {
  $user = Get-OpenCodeUserInstallPath
  if ($user) { return $user }
  $cmds = Get-Command opencode -All -ErrorAction SilentlyContinue
  if (-not $cmds) { return $null }
  $exe = $cmds | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.exe$' } | Select-Object -First 1
  if ($exe) { return $exe.Source }
  $app = $cmds | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
  if ($app) { return $app.Source }
  return $cmds[0].Source
}

function Invoke-OpenCodeVersionProbe() {
  $path = Get-OpenCodeCommandPath
  if (-not $path) { return @{ Version = $null; Output = '' } }
  try {
    $out = & $path '--version' 2>&1 | Out-String
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
  $probe = Invoke-OpenCodeVersionProbe
  if ($probe.Version) { return $probe.Version }
  $exe = Get-OpenCodeNpmExePath
  if (-not $exe) { return $null }
  try { return Get-SemVer ((& $exe '--version' 2>&1 | Out-String)) } catch { return $null }
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
  
  $repl = "& `"$ExePath`" `$args"
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
  return [bool]((Invoke-OpenCodeVersionProbe).Version)
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
  if ($Title -eq 'OpenCode') { Report-OpenCodeResolutionMismatch }
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
  if ($Title -eq 'OpenCode') { Report-OpenCodeResolutionMismatch }
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
  Write-Host "  [Q] Quit"
  $s = Read-Host "Enter choice (1/2/3/4/5/A/Q)"
  if ([string]::IsNullOrWhiteSpace($s)) { return 'A' }
  return $s.Trim().ToUpperInvariant()
}

function Invoke-Selection([string]$Selection) {
  if ($Selection -eq '1' -or $Selection -eq 'A') {
    Check-OneTool "Factory CLI (Droid)" { Get-LatestFactoryVersion } { Get-LocalCommandVersion @('factory','droid') } { Update-Factory }
  }
  if ($Selection -eq '2' -or $Selection -eq 'A') {
    Check-OneTool "Claude Code" { Get-LatestClaudeVersion } { Get-LocalCommandVersion @('claude','claude-code') } { Update-Claude }
  }
  if ($Selection -eq '3' -or $Selection -eq 'A') {
    Check-OneTool "OpenAI Codex" { Get-LatestCodexVersion } { Get-LocalCommandVersion @('codex') } { Update-Codex }
  }
  if ($Selection -eq '4' -or $Selection -eq 'A') {
    Check-OneTool "Gemini CLI" { Get-LatestGeminiVersion } { Get-LocalCommandVersion @('gemini') } { Update-Gemini }
  }
  if ($Selection -eq '5' -or $Selection -eq 'A') {
    Check-OneTool "OpenCode" { Get-LatestOpenCodeVersion } { Get-LocalOpenCodeVersion } { Update-OpenCode }
  }
}

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
