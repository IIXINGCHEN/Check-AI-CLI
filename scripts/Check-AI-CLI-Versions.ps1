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
$script:UpdateFailed = $false

function Get-AllowRemoteScriptExecution() {
  $v = $env:CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

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

# --- Byte-level progress bar helpers ---

function New-ByteProgressState([long]$TotalBytes, [int]$Width = 30) {
  return @{
    TotalBytes = [Math]::Max(1L, $TotalBytes)
    CurrentBytes = 0L
    Width = [Math]::Max(1, $Width)
    Visible = $false
  }
}

function Get-ByteProgressPercent([hashtable]$State) {
  $value = [int][Math]::Floor((Get-ByteProgressPercentValue $State))
  if ($value -lt 0) { return 0 }
  if ($value -gt 100) { return 100 }
  return $value
}

function Get-ByteProgressPercentValue([hashtable]$State) {
  $value = ([double]$State.CurrentBytes * 100.0) / [double]$State.TotalBytes
  if ($value -lt 0) { return 0.0 }
  if ($value -gt 100) { return 100.0 }
  return $value
}

function Get-ByteProgressPercentText([hashtable]$State) {
  return (Get-ByteProgressPercentValue $State).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ByteProgressFill([hashtable]$State) {
  $fill = [int][Math]::Floor(((Get-ByteProgressPercentValue $State) / 100.0) * $State.Width)
  if ($fill -lt 0) { return 0 }
  if ($fill -gt $State.Width) { return $State.Width }
  return $fill
}

function New-BarText([string]$Character, [int]$Count) {
  if ($Count -le 0) { return '' }
  return ($Character * $Count)
}

function Get-ByteProgressLine([hashtable]$State) {
  $fill = Get-ByteProgressFill $State
  $bar = New-BarText '#' $fill
  return "{0} {1}%" -f $bar, (Get-ByteProgressPercentText $State)
}

function Add-ByteProgress([hashtable]$State, [long]$Bytes) {
  $next = $State.CurrentBytes + [Math]::Max(0L, $Bytes)
  if ($next -gt $State.TotalBytes) { $next = $State.TotalBytes }
  $State.CurrentBytes = $next
  return $State
}

function Write-ByteProgress([hashtable]$State) {
  Write-Host "`r$(Get-ByteProgressLine $State)" -NoNewline
  $State.Visible = $true
}

function Close-ByteProgress([hashtable]$State) {
  if (-not $State.Visible) { return }
  Write-Host ''
  $State.Visible = $false
}

# --- Download with ##### progress bar ---

function Get-RemoteFileSize([string]$Uri) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  $px = Get-WebRequestProxyParameters
  try {
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      $resp = Invoke-WebRequest @px -Uri $Uri -Headers $headers -UseBasicParsing -Method Head -TimeoutSec 15 -ErrorAction Stop
    } finally {
      $ProgressPreference = $prev
    }
    if ($resp.Headers -and $resp.Headers['Content-Length']) {
      return [long]$resp.Headers['Content-Length']
    }
  } catch {}
  return 0L
}

# Internal: raw download without progress tracking (avoids recursion)
function Invoke-RawDownload([string]$Uri, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  $px = Get-WebRequestProxyParameters
  $mode = 'SilentlyContinue'
  Invoke-WithTempProgressPreference $mode {
    Invoke-WebRequest @px -Uri $Uri -Headers $headers -UseBasicParsing -OutFile $OutFile -TimeoutSec 300 -ErrorAction Stop | Out-Null
  }
}

function Download-FileWithProgress([string]$Uri, [string]$OutFile, [string]$Label) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  $px = Get-WebRequestProxyParameters
  $totalBytes = Get-RemoteFileSize $Uri
  $state = $null
  if ($totalBytes -gt 0) {
    $state = New-ByteProgressState $totalBytes
  }

  if ($state) {
    # Stream download with chunk-based progress
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      $response = Invoke-WebRequest @px -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
      if ($response.RawContentStream) {
        $response.RawContentStream.Position = 0
        $fs = [System.IO.FileStream]::new($OutFile, 'Create', 'Write', 'None')
        try {
          $chunk = New-Object byte[] 81920
          $stream = $response.RawContentStream
          $read = 0
          do {
            $read = $stream.Read($chunk, 0, $chunk.Length)
            if ($read -gt 0) {
              $fs.Write($chunk, 0, $read)
              Add-ByteProgress $state $read | Out-Null
              Write-ByteProgress $state
            }
          } while ($read -gt 0)
          if ($state.CurrentBytes -lt $state.TotalBytes) {
            throw "Download incomplete: received $($state.CurrentBytes) of $($state.TotalBytes) bytes"
          }
          Close-ByteProgress $state
        } finally {
          $fs.Dispose()
        }
      } else {
        # Fallback: write Content directly (PowerShell 5.1)
        $buffer = $response.Content
        [System.IO.File]::WriteAllBytes($OutFile, $buffer)
        Add-ByteProgress $state $buffer.Length | Out-Null
        Write-ByteProgress $state
        Close-ByteProgress $state
      }
    } finally {
      $ProgressPreference = $prevProgress
    }
  } else {
    # Unknown size: fallback to raw download without progress bar
    Invoke-RawDownload $Uri $OutFile
  }
}

function Invoke-WebRequestWithHeaders([string]$Uri, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  if ($OutFile) {
    Download-FileWithProgress $Uri $OutFile ''
    return
  }
  $prev = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  $px = Get-WebRequestProxyParameters
  try {
    return Invoke-WebRequest @px -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
  } finally {
    $ProgressPreference = $prev
  }
}

function Get-CurlApplication() {
  return (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)
}

function Invoke-CurlDownload([string]$Url, [string]$OutFile) {
  $curl = Get-CurlApplication
  if (-not $curl) { throw 'curl.exe is unavailable' }

  # Windows ships curl.exe. It uses HTTP(S)_PROXY inherited from network
  # detection and is a deliberately independent transport when HttpClient/IWR
  # is truncated by a local proxy. HTTP/1.1 avoids common proxy HTTP/2 EOFs.
  $curlArgs = @(
    '--fail', '--location', '--silent', '--show-error', '--http1.1',
    '--retry', '2', '--retry-all-errors', '--connect-timeout', '30',
    '--max-time', '300', '--output', $OutFile, $Url
  )
  & $curl.Path @curlArgs
  if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE" }
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
      $webError = $_.Exception.Message
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      if ($i -lt $tries) {
        Write-Warn "${Label} download attempt $i/$tries failed: $webError"
        Start-Sleep -Seconds 2
        continue
      }

      # Retrying the same transport cannot repair a proxy/HttpClient protocol
      # incompatibility. Use curl.exe once as an independent final transport.
      Write-Warn "${Label} download via PowerShell failed; trying curl.exe with HTTP/1.1"
      try {
        Invoke-CurlDownload $Url $tmp
        if (-not (Test-NonEmptyFile $tmp)) { throw 'Downloaded file is empty.' }
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
        return
      } catch {
        $curlError = $_.Exception.Message
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw "Failed to download ${Label}: $webError; curl.exe fallback failed: $curlError"
      }
    }
  }
}

function Get-FactoryBootstrapInfo() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) {
    $detail = if ($script:LastGetTextError) { " ($script:LastGetTextError)" } else { '' }
    throw "Failed to download Factory installer script.$detail"
  }
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

function Get-FileSha256([string]$Path) {
  $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($getFileHash) {
    try { return (Microsoft.PowerShell.Utility\Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { }
  }

  $certutil = Get-Command certutil.exe -ErrorAction SilentlyContinue
  $certutilPath = if ($certutil) { $certutil.Source } else { $null }
  if ([string]::IsNullOrWhiteSpace($certutilPath)) { throw 'No SHA256 hash tool found.' }
  $out = & $certutilPath -hashfile $Path SHA256
  if ($LASTEXITCODE -ne 0) { throw "certutil failed with exit code $LASTEXITCODE" }
  foreach ($line in $out) {
    $hash = ($line -replace '\s','').ToLowerInvariant()
    if ($hash -match '^[a-f0-9]{64}$') { return $hash }
  }
  throw 'Failed to parse SHA256 hash.'
}

function Assert-FileSha256([string]$Path, [string]$ExpectedHash, [string]$Label) {
  $actualHash = Get-FileSha256 $Path
  if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) { throw "$Label checksum verification failed" }
}

# Retained for backward compatibility with tests that mock it. The actual
# process-stop logic now lives inside Install-FactoryFile (on-demand, only when
# the destination is locked) instead of running unconditionally before install.
function Stop-FactoryProcesses() {
  $droidProcesses = Get-Process -Name 'droid' -ErrorAction SilentlyContinue
  if (-not $droidProcesses) { return }
  Write-Info 'Stopping old droid process(es)'
  Stop-Process -Name 'droid' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

# Copy a binary to its destination, retrying once after stopping any process
# that holds the destination locked. The process name is derived from the
# destination file name (e.g. droid.exe -> droid) so only the tool being
# updated is affected, and only when the initial copy fails.
function Install-FactoryFile([string]$SourcePath, [string]$DestinationPath) {
  $parent = Split-Path -Parent $DestinationPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  try {
    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
    return
  } catch {
    # Copy failed - typically the destination is locked by a running instance
    # of the same tool. Stop that process by name and retry once.
    $destName = Split-Path -Leaf $DestinationPath
    $procName = [IO.Path]::GetFileNameWithoutExtension($destName)
    $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if (-not $running) { throw }
    Write-Info "Stopping running $procName process to complete update"
    Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
  }
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\\')
}

function Test-ValidPathEntry([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) {
    Write-Warn 'Invalid path entry: empty or whitespace'
    return $false
  }
  if ($Dir.Contains(';') -or $Dir -match '[\r\n]') {
    Write-Warn 'Invalid path entry: contains semicolon'
    return $false
  }
  if ($Dir -match '[<>"|?*]') {
    Write-Warn 'Invalid path entry: contains invalid characters'
    return $false
  }
  return $true
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
  if (-not (Test-ValidPathEntry $Dir)) { throw 'Refusing to prepend invalid PATH entry.' }
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
  if (-not (Test-ValidPathEntry $Dir)) { throw 'Refusing to add invalid PATH entry.' }
  $userPath = Get-UserPathValue
  if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
  if (Path-ContainsDir $userPath $Dir) { return }
  $normalized = Normalize-Dir $Dir
  $newPath = if ($userPath) { "$userPath;$normalized" } else { $normalized }
  Set-UserPathValue $newPath
  if (-not (Path-ContainsDir $env:PATH $normalized)) {
    $env:PATH = if ([string]::IsNullOrWhiteSpace($env:PATH)) { $normalized } else { "$normalized;$env:PATH" }
  }
  Write-Info "Added a tool directory to your PATH permanently"
}

function Ensure-UserPathPrefers([string]$Dir) {
  if (-not (Test-ValidPathEntry $Dir)) { throw 'Refusing to prioritize invalid PATH entry.' }
  $normalized = Normalize-Dir $Dir
  $userPath = Get-UserPathValue
  $newUserPath = Prepend-PathEntry $userPath $normalized
  if ($newUserPath -ne $userPath) {
    Set-UserPathValue $newUserPath
    Write-Info "Moved a tool directory to the front of your PATH permanently"
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
    $npmBin = Get-NpmGlobalBinDir
    if ($npmBin) { $dirs += $npmBin }
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
  $dirs = @(Get-PreferredToolPathDirs $ToolId | Where-Object { Test-ValidPathEntry $_ })
  if ($dirs.Count -eq 0) { return $false }
  $userPath = Get-UserPathValue
  $newUserPath = Get-OrderedPathValue $userPath $dirs
  if ($newUserPath -ne $userPath) { Set-UserPathValue $newUserPath ; Write-Info "Updated your PATH permanently to prefer $ToolId" }
  $env:PATH = Get-OrderedPathValue $env:PATH $dirs
  return $true
}

function New-TemporaryDirectory() {
  $path = Join-Path ([IO.Path]::GetTempPath()) "check-ai-cli-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
  return $path
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

  $tempDir = New-TemporaryDirectory
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

    Install-FactoryFile $binaryPath $installPath
    Install-FactoryFile $rgBinaryPath $rgInstallPath

    Write-Info "Factory CLI v$version installed successfully."
    Write-Info "Ripgrep installed successfully."
    Ensure-UserPathContains $installDir
    Write-Info 'Run ''droid'' to get started!'
  } finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
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
$script:BestNpmMirror = $null

# Effective proxy applied to all network operations (own IW/IRM + child processes).
# Null = direct connection. Set by Set-EffectiveProxyEnvironment during detection.
$script:EffectiveProxyUrl = $null
$script:EffectiveNoProxy = $null

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

# --- Proxy normalization and propagation -------------------------------------
# A proxy is detected and stored in NetworkInfo, but that alone does not make any
# network operation use it. curl / Node (undici) / the native Claude updater /
# opencode / npm only honor proxy when it is exported to the process environment
# (HTTP_PROXY / HTTPS_PROXY / ALL_PROXY), and our own Invoke-WebRequest needs the
# explicit -Proxy parameter to behave identically across PS 5.1 and PS 7+.

# Ensure a proxy string carries an http(s):// scheme. curl accepts a bare
# host:port, but Node/undici ProxyAgent reject it, so we normalize universally.
function ConvertTo-ProxyUrl([string]$Raw) {
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $v = $Raw.Trim()
  if ($v -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://') { return $v }
  return ('http://' + $v)
}

function Get-LogSafeProxyUrl([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
  return [regex]::Replace($Url, '^([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s]+@', '$1***@')
}

function Test-HttpProxyScheme([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  $u = $Url.ToLowerInvariant()
  return ($u -like 'http://*' -or $u -like 'https://*')
}

# Translate a WinINET ProxyOverride bypass list ("localhost;127.*;10.*;<local>")
# into a comma-joined NO_PROXY ("localhost,127.,10.") understood by curl/Node.
function ConvertTo-NoProxy([string]$Bypass) {
  if ([string]::IsNullOrWhiteSpace($Bypass)) { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($entry in ($Bypass -split ';')) {
    $t = $entry.Trim()
    if (-not $t) { continue }
    if ($t -eq '<local>') { continue }
    $t = $t -replace '\*$', ''
    if ($t) { $null = $out.Add($t) }
  }
  if ($out.Count -eq 0) { return $null }
  return ($out -join ',')
}

# Resolve detected proxy settings into a single normalized descriptor.
# Returns @{ Url; NoProxy; Source; IsHttpProxy } or $null when no proxy applies.
function Get-NormalizedProxy([hashtable]$SystemProxy, [hashtable]$EnvProxy) {
  $noProxy = $null
  if ($EnvProxy -and -not [string]::IsNullOrWhiteSpace($EnvProxy.NoProxy)) {
    $noProxy = $EnvProxy.NoProxy.Trim()
  }

  # 1) Environment proxy wins (already URL-shaped, explicitly opted in).
  $rawEnv = $null
  $envKey = $null
  if ($EnvProxy -and -not [string]::IsNullOrWhiteSpace($EnvProxy.AllProxy)) { $rawEnv = $EnvProxy.AllProxy; $envKey = 'all_proxy' }
  elseif ($EnvProxy -and -not [string]::IsNullOrWhiteSpace($EnvProxy.HttpsProxy)) { $rawEnv = $EnvProxy.HttpsProxy; $envKey = 'https_proxy' }
  elseif ($EnvProxy -and -not [string]::IsNullOrWhiteSpace($EnvProxy.HttpProxy)) { $rawEnv = $EnvProxy.HttpProxy; $envKey = 'http_proxy' }

  if ($rawEnv) {
    $url = ConvertTo-ProxyUrl $rawEnv
    if (-not $url) { return $null }
    return @{ Url = $url; NoProxy = $noProxy; Source = "env:$envKey"; IsHttpProxy = (Test-HttpProxyScheme $url) }
  }

  # 2) WinINET static proxy from the registry.
  if ($SystemProxy -and $SystemProxy.Enabled -and -not [string]::IsNullOrWhiteSpace($SystemProxy.Server)) {
    $server = [string]$SystemProxy.Server
    $candidate = $server
    # Per-protocol form: "http=host:port;https=host:port;socks=host:port"
    if ($server.Contains('=')) {
      $chosen = $null
      foreach ($part in ($server -split ';')) {
        $kv = $part -split '=', 2
        if ($kv.Length -ne 2) { continue }
        $proto = $kv[0].Trim().ToLowerInvariant()
        $val = $kv[1].Trim()
        if (-not $val) { continue }
        if ($proto -eq 'https') { $chosen = $val; break }
        if ($proto -eq 'http' -and -not $chosen) { $chosen = $val }
        if ($proto -match 'socks' -and -not $chosen) { $chosen = $val }
      }
      $candidate = $chosen
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    $url = ConvertTo-ProxyUrl $candidate
    if (-not $url) { return $null }
    if (-not $noProxy) { $noProxy = ConvertTo-NoProxy $SystemProxy.Bypass }
    return @{ Url = $url; NoProxy = $noProxy; Source = 'system'; IsHttpProxy = (Test-HttpProxyScheme $url) }
  }

  return $null
}

# Export the normalized proxy to the process environment so every child process
# (curl, node, claude updater, opencode, npm) inherits it, and record the value
# to splat onto our own Invoke-WebRequest/-RestMethod calls. Idempotent.
function Set-EffectiveProxyEnvironment($Proxy) {
  $script:EffectiveProxyUrl = $null
  $script:EffectiveNoProxy = $null

  if (-not $Proxy -or [string]::IsNullOrWhiteSpace($Proxy.Url)) { return $Proxy }

  $url = [string]$Proxy.Url
  $noProxy = $Proxy.NoProxy

  if ($Proxy.IsHttpProxy) {
    $env:HTTP_PROXY  = $url; $env:http_proxy  = $url
    $env:HTTPS_PROXY = $url; $env:https_proxy = $url
    $env:ALL_PROXY   = $url; $env:all_proxy   = $url
    $script:EffectiveProxyUrl = $url
  } else {
    # SOCKS-only: curl and socks-capable Node can use ALL_PROXY, but PowerShell
    # Invoke-WebRequest -Proxy does not support SOCKS, so we leave it un-proxied.
    $env:ALL_PROXY = $url; $env:all_proxy = $url
  }

  if (-not [string]::IsNullOrWhiteSpace($noProxy)) {
    $env:NO_PROXY = $noProxy; $env:no_proxy = $noProxy
    $script:EffectiveNoProxy = $noProxy
  }

  return $Proxy
}

# Splat hashtable for Invoke-WebRequest / Invoke-RestMethod -Proxy.
# Empty when direct so splatting is a no-op.
function Get-WebRequestProxyParameters() {
  if ($script:EffectiveProxyUrl) { return @{ Proxy = $script:EffectiveProxyUrl } }
  return @{}
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
  
  $px = Get-WebRequestProxyParameters
  foreach ($test in $tests) {
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $null = Invoke-WebRequest @px -Uri $test.Url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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
      Write-Info "System proxy detected: $(Get-LogSafeProxyUrl $sysProxy.Server)"
    }
    if ($sysProxy.AutoConfig) {
      Write-Info "PAC auto-config detected: $(Get-LogSafeProxyUrl $sysProxy.AutoConfigUrl)"
    }
    if ($envProxy.HttpProxy -or $envProxy.HttpsProxy) {
      $proxyUrl = if ($envProxy.HttpsProxy) { $envProxy.HttpsProxy } else { $envProxy.HttpProxy }
      Write-Info "Environment proxy detected: $(Get-LogSafeProxyUrl $proxyUrl)"
    }
  } else {
    Write-Info "No proxy configured (direct connection)"
  }

  # Apply the detected proxy to ALL network operations: export it to the process
  # environment so child processes (curl/node/claude updater/opencode/npm) inherit
  # it, and record it for our own Invoke-WebRequest -Proxy. Must happen before the
  # connectivity test so that test (and every later download) is proxy-accurate.
  $effectiveProxy = Get-NormalizedProxy $sysProxy $envProxy
  if ($effectiveProxy) {
    [void](Set-EffectiveProxyEnvironment $effectiveProxy)
    $safeProxyUrl = Get-LogSafeProxyUrl $effectiveProxy.Url
    if ($effectiveProxy.IsHttpProxy) {
      Write-Info "Applying detected proxy to all network operations: $safeProxyUrl"
    } else {
      Write-Info "Applying proxy to subprocess downloads (SOCKS; own fetches stay direct): $safeProxyUrl"
    }
  } else {
    $script:EffectiveProxyUrl = $null
    if ($sysProxy.AutoConfig) {
      Write-Warn 'PAC auto-config detected but cannot be resolved automatically. Set HTTP_PROXY/HTTPS_PROXY for reliable CLI updates.'
    }
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
        $px = Get-WebRequestProxyParameters
        $null = Invoke-WebRequest @px -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
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

# Fetch text content, return $null on failure
function Get-Text([string]$Uri) {
  $script:LastGetTextError = $null
  $tries = Get-RetryCount
  $lastErr = $null
  for ($i = 1; $i -le $tries; $i++) {
    try {
      $content = (Invoke-WebRequestWithHeaders $Uri $null).Content
      if ($content -is [string]) { return $content }
      if ($content -is [string[]]) { return ($content -join "`n") }
      if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
      return ($content | Out-String)
    } catch {
      $lastErr = $_.Exception.Message
      $statusCode = ''
      try {
        $resp = $_.Exception.Response
        if ($resp) { $statusCode = " [HTTP $([int]$resp.StatusCode)]" }
      } catch {}
      if ($i -eq $tries) {
        Write-Warn "Request failed: $Uri ($lastErr)$statusCode"
        $script:LastGetTextError = "Request to $Uri failed after $tries attempt(s): $lastErr$statusCode"
        return $null
      }
      Write-Warn "Request attempt $i/$tries failed: $Uri ($lastErr)$statusCode"
      Start-Sleep -Seconds 2
    }
  }
}

# Fetch JSON, return $null on failure
function Get-Json([string]$Uri) {
  $tries = Get-RetryCount
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  $px = Get-WebRequestProxyParameters
  for ($i = 1; $i -le $tries; $i++) {
    try {
      return Invoke-RestMethod @px -Uri $Uri -Headers $headers -ErrorAction Stop
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
  # Anchor version boundary: reject when preceded/followed by digit or dot to avoid
  # mis-extracting from multi-segment numbers like dates '2026.01.0.142' or paths 'C:\1.2.3\bin'.
  $m = [regex]::Match($Text, '(?:^|[^\d.])(\d+)\.(\d+)\.(\d+)(?=[^\d.]|$)')
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
  $commands = @(Get-Command $CommandName -All -ErrorAction SilentlyContinue)
  if ($commands.Count -eq 0) { return @{ Name = $CommandName; Version = $null; Source = $null } }

  $firstSource = $null
  foreach ($cmd in $commands) {
    $source = Get-CommandSourcePath $cmd
    if (-not $firstSource) { $firstSource = $source }
    if ([string]::IsNullOrWhiteSpace($source)) { continue }
    try {
      $out = & $source '--version' 2>$null | Out-String
      $v = Get-SemVer $out
      if ($v) { return @{ Name = $CommandName; Version = $v; Source = $source } }
    } catch { }
  }

  Write-Warn "Failed to parse local version from: $CommandName"
  return @{ Name = $CommandName; Version = $null; Source = $firstSource }
}

function Get-CommandSourcePath($CommandInfo) {
  if ($null -eq $CommandInfo) { return $null }
  # Only Application and ExternalScript have an on-disk Source safe to invoke.
  # Functions/Cmdlets/Aliases expose a Definition body that must NOT be treated as a path.
  if ($CommandInfo.CommandType -notin @('Application', 'ExternalScript')) { return $null }
  $source = [string]$CommandInfo.Source
  if ([string]::IsNullOrWhiteSpace($source)) { return $null }
  return $source
}

# Get local command version, return $null if missing or failed
function Get-LocalCommandVersion([string[]]$CommandNames) {
  foreach ($name in $CommandNames) {
    $info = Get-CommandVersionInfo $name
    if ($info.Version) { return $info.Version }
  }
  return $null
}

function Test-CommandSourceInDir([string]$Source, [string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Dir)) { return $false }
  try {
    $sourceDir = Split-Path -Parent $Source
    return (Normalize-Dir $sourceDir) -eq (Normalize-Dir $Dir)
  } catch { return $false }
}

function Get-ClaudeVersionCandidate([string]$Dir) {
  $oldPath = $env:PATH
  try {
    $env:PATH = Prepend-PathEntry $env:PATH $Dir
    foreach ($name in @('claude','claude-code')) {
      $info = Get-CommandVersionInfo $name
      if ($info.Version -and (Test-CommandSourceInDir $info.Source $Dir)) {
        return @{ Dir = $Dir; Version = $info.Version; Source = $info.Source }
      }
    }
  } finally {
    $env:PATH = $oldPath
  }
  return $null
}

function Get-BestClaudeVersionCandidate() {
  $best = $null
  foreach ($dir in @(Get-PreferredToolPathDirs 'claude')) {
    $candidate = Get-ClaudeVersionCandidate $dir
    if (-not $candidate) { continue }
    if (-not $best -or (Compare-Version $best.Version $candidate.Version) -eq -1) {
      $best = $candidate
    }
  }
  return $best
}

function Get-FactoryVersionCandidate([string]$Dir) {
  $oldPath = $env:PATH
  try {
    $env:PATH = Prepend-PathEntry $env:PATH $Dir
    foreach ($name in @('droid','factory')) {
      $info = Get-CommandVersionInfo $name
      if ($info.Version -and (Test-CommandSourceInDir $info.Source $Dir)) {
        return @{ Dir = $Dir; Version = $info.Version; Source = $info.Source }
      }
    }
  } finally {
    $env:PATH = $oldPath
  }
  return $null
}

function Get-BestFactoryVersionCandidate() {
  $best = $null
  foreach ($dir in @(Get-PreferredToolPathDirs 'factory')) {
    $candidate = Get-FactoryVersionCandidate $dir
    if (-not $candidate) { continue }
    if (-not $best -or (Compare-Version $best.Version $candidate.Version) -eq -1) {
      $best = $candidate
    }
  }
  return $best
}

function Get-LocalClaudeVersion() {
  $candidate = Get-BestClaudeVersionCandidate
  if ($candidate) {
    Ensure-UserPathPrefers $candidate.Dir
    return $candidate.Version
  }
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
  $candidate = Get-BestFactoryVersionCandidate
  if ($candidate) {
    Ensure-UserPathPrefers $candidate.Dir
    return $candidate.Version
  }
  [void](Repair-ToolUserPath 'factory')
  $droid = Get-CommandVersionInfo 'droid'
  $factory = Get-CommandVersionInfo 'factory'

  if ($droid.Version) {
    if ($factory.Version) {
      $cmp = Compare-Version $factory.Version $droid.Version
      if ($cmp -eq -1) {
        Write-Warn "Factory alias mismatch detected: factory resolves to v$($factory.Version), but droid resolves to v$($droid.Version). Using droid for version checks."
      }
    }
    return $droid.Version
  }

  if ($factory.Version) { return $factory.Version }
  return $null
}

# Resolve both Factory release channels. The native bootstrap often publishes
# before npm, so npm is not automatically an equivalent fallback target.
$script:LatestFactoryOfficialVersion = $null
$script:LatestFactoryNpmVersion = $null

function Get-LatestFactoryVersion() {
  $official = $null
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if ($text) {
    $m = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
    if ($m.Success) { $official = Get-SemVer $m.Groups[1].Value }
  }
  $npm = Get-NpmLatestVersion 'droid'
  $script:LatestFactoryOfficialVersion = $official
  $script:LatestFactoryNpmVersion = $npm

  if ($official -and $npm) {
    $cmp = Compare-Version $official $npm
    if ($cmp -ne 0) {
      $selected = if ($cmp -eq 1) { $official } else { $npm }
      Write-Info "Factory CLI latest version sources differ: official=v$official, npm=v$npm. Using v$selected."
      return $selected
    }
    return $official
  }
  if ($official) { return $official }
  return $npm
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
  if ($Primary -and $Secondary -and $Primary -ne $Secondary) { Write-Info "$ToolName latest version sources differ: $PrimaryLabel=v$Primary, $SecondaryLabel=v$Secondary. Using v$selected." }
  return $selected
}

function Get-LatestClaudeVersion() {
  $repo = Get-ClaudeRepoLatestVersion
  $stable = Get-ClaudeBootstrapStableVersion
  $npm = Get-NpmLatestVersion '@anthropic-ai/claude-code'
  # Native stable and npm are installable sources. GitHub releases may be ahead
  # due to staged rollout, so only use repo metadata if installable sources fail.
  $installable = Resolve-VersionConflict 'Claude Code' 'stable' $stable 'npm' $npm
  if ($installable) { return $installable }
  return $repo
}

function Get-LatestCodexVersion() {
  $npm = Get-NpmLatestVersion '@openai/codex'
  if ($npm) { return $npm }
  return Get-GitHubLatestReleaseVersion 'openai/codex'
}

function Get-LatestGeminiVersion() {
  $npm = Get-NpmLatestVersion '@google/gemini-cli'
  if ($npm) { return $npm }
  return Get-GitHubLatestReleaseVersion 'google-gemini/gemini-cli'
}

function Get-ClaudeNativeUpdateTimeoutSeconds() {
  $default = 120
  $v = $env:CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS
  if ([string]::IsNullOrWhiteSpace($v)) { return $default }
  $n = 0
  if (-not [int]::TryParse($v.Trim(), [ref]$n)) { return $default }
  if ($n -lt 10) { return 10 }
  if ($n -gt 900) { return 900 }
  return $n
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

# Run npm install -g using the best regional mirror via --registry, applied per command.
# This avoids persistently rewriting the user's ~/.npmrc (no Set/Restore needed, safe
# under Ctrl+C or exceptions). Avoids PowerShell npm.ps1 "-Command" parsing edge cases.
function Invoke-NpmInstallGlobal([string]$PackageSpec) {
  if ($null -eq $script:BestNpmMirror) { $script:BestNpmMirror = Get-BestNpmMirror }
  $registry = $script:BestNpmMirror
  $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
  if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
  if ($npmCmd) {
    & $npmCmd.Path install -g $PackageSpec --registry $registry
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    return
  }

  $npmPs1 = Get-Command npm -CommandType ExternalScript -ErrorAction SilentlyContinue
  if (-not $npmPs1) { throw "npm not found. Install Node.js first." }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $npmPs1.Path install -g $PackageSpec --registry $registry
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
    if ($WarningTitle -ne 'Remote Script Execution') {
      Write-Warn "[SECURITY] Auto mode: $ActionDescription from $Url"
      return $true
    }
    if (Get-AllowRemoteScriptExecution) {
      Write-Warn "[SECURITY] Auto mode: remote script execution explicitly allowed for $ToolName from $Url"
      return $true
    }
    Write-Warn "[SECURITY] Auto mode: skipping remote script execution from $Url. Set CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT=1 to allow."
    return $false
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
    return
  } catch {
    Write-Warn "Official bootstrap failed: $($_.Exception.Message)"
  }
  $official = $script:LatestFactoryOfficialVersion
  $npm = $script:LatestFactoryNpmVersion
  if ($official -and $npm -and (Compare-Version $npm $official) -eq -1) {
    throw "Official Factory CLI v$official download failed, and npm latest is only v$npm. Skipping the older npm fallback because it cannot reach the selected target."
  }

  Write-Info "Trying: npm install (fallback)"
  try {
    Invoke-NpmInstallGlobal 'droid@latest'
    Write-Info "Factory CLI installed via npm."
  } catch {
    throw "Factory CLI installer failed. Both official bootstrap and npm fallback failed."
  }
}

# Install/update Claude Code via native updater
function Invoke-ClaudeNativeUpdate() {
  Write-Info "Trying: claude update"
  $cmd = Get-Command claude -ErrorAction SilentlyContinue
  if (-not $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) {
    throw 'claude command not found in PATH'
  }

  Invoke-ClaudeNativeUpdateProcess $cmd.Source (Get-ClaudeNativeUpdateTimeoutSeconds)
}

function Invoke-ClaudeNativeUpdateProcess([string]$ClaudePath, [int]$TimeoutSeconds) {
  $proc = $null
  try {
    $proc = Start-Process -FilePath $ClaudePath -ArgumentList @('update') -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      throw "claude update timed out after ${TimeoutSeconds}s"
    }
    $proc.Refresh()
    if ($null -eq $proc.ExitCode) { return }
    if ($proc.ExitCode -ne 0) {
      throw "claude update failed with exit code $($proc.ExitCode)"
    }
  } catch {
    if ($proc -and -not $proc.HasExited) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    throw
  }
}

function Test-ClaudeVersionAtLeast([string]$TargetVersion) {
  if ([string]::IsNullOrWhiteSpace($TargetVersion)) { return $true }
  $local = Get-LocalClaudeVersion
  if ([string]::IsNullOrWhiteSpace($local)) { return $false }
  return (Compare-Version $local $TargetVersion) -ge 0
}

# Install/update Claude Code via official install.ps1
function Update-ClaudeViaInstallScript() {
  Write-Info "Trying: official install.ps1"
  if (-not [Environment]::Is64BitProcess) {
    throw "Claude Code does not support 32-bit Windows."
  }

  $url = 'https://claude.ai/install.ps1'
  if (-not (Confirm-RemoteScriptExecution $url 'Claude Code')) {
    throw 'Remote script execution declined'
  }

  $scriptText = Get-Text $url
  if ([string]::IsNullOrWhiteSpace($scriptText)) {
    throw 'Failed to download install.ps1'
  }

  $installer = [scriptblock]::Create($scriptText)
  & $installer
}

function Update-ClaudeViaNpm() {
  Write-Info "Trying: npm install (fallback)"
  Invoke-NpmInstallGlobal '@anthropic-ai/claude-code@latest'
  [void](Repair-ToolUserPath 'claude')
}

# Install/update Claude Code (native updater preferred, official install and npm fallbacks)
function Update-Claude() {
  Write-Info "Updating Claude Code..."

  [void](Repair-ToolUserPath 'claude')
  $target = Get-LatestClaudeVersion
  $stable = Get-ClaudeBootstrapStableVersion
  $nativeDetail = $null
  $installScriptDetail = $null

  if ($stable -and $target -and ((Compare-Version $stable $target) -eq -1)) {
    Write-Info "Skipping native Claude update: stable channel v$stable is older than target v$target."
  } else {
    try {
      Invoke-ClaudeNativeUpdate
      if (Test-ClaudeVersionAtLeast $target) { return }
      if ($target) {
        Write-Warn "native Claude update completed but local version is still older than target v$target."
      } else {
        Write-Warn "native Claude update completed but local Claude version could not be verified."
      }
    } catch {
      $nativeDetail = $_.Exception.Message
      if ([string]::IsNullOrWhiteSpace($nativeDetail)) { $nativeDetail = 'native updater failed' }
      Write-Warn "native Claude update failed: $nativeDetail"
    }
  }

  try {
    Update-ClaudeViaInstallScript
    if (Test-ClaudeVersionAtLeast $target) { return }
    if ($target) {
      $installScriptDetail = "official install.ps1 completed but local version is still older than target v$target"
      Write-Warn "official Claude install script completed but local version is still older than target v$target."
    } else {
      $installScriptDetail = 'official install.ps1 completed but local Claude version could not be verified'
      Write-Warn "official Claude install script completed but local Claude version could not be verified."
    }
  } catch {
    $installScriptDetail = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($installScriptDetail)) { $installScriptDetail = 'official install.ps1 failed' }
    Write-Warn "official Claude install script failed: $installScriptDetail"
  }

  try {
    Update-ClaudeViaNpm
    if (-not (Test-ClaudeVersionAtLeast $target)) {
      throw "npm Claude install completed but local version is still older than target v$target"
    }
  } catch {
    $npmDetail = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($npmDetail)) { $npmDetail = 'npm fallback failed' }
    $details = @()
    if ($nativeDetail) { $details += "native updater: $nativeDetail" }
    if ($installScriptDetail) { $details += "official install.ps1: $installScriptDetail" }
    $details += "npm fallback: $npmDetail"
    throw "Claude Code update failed: $($details -join '; '). Try 'claude update', reinstall via irm https://claude.ai/install.ps1 | iex, or run npm install -g @anthropic-ai/claude-code@latest"
  }
}

# Install/update OpenAI Codex (Windows defaults to npm)
function Update-Codex() {
  Write-Info "Updating OpenAI Codex..."
  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@openai/codex@latest'
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
  Write-Warn 'Tip: ensure User PATH starts with the OpenCode user install directory'
  Write-Warn 'Tip: restart PowerShell after PATH changes if this session still resolves an older shim'
}

function Write-OpenCodeStandaloneOnly([string]$UserPath, [string]$UserVersion) {
  Write-Warn 'PowerShell cannot resolve opencode from the current PATH.'
  Write-Warn 'OpenCode user install path is available but is not first in PATH.'
  if ($UserVersion) { Write-Warn "OpenCode user install version: v$UserVersion" }
  Write-OpenCodeResolutionTips $UserPath
}

function Write-OpenCodeResolvedMismatch([hashtable]$Resolved, [string]$UserPath, [string]$UserVersion) {
  Write-Warn 'PowerShell resolves opencode to a different PATH entry.'
  if ($Resolved.Version) { Write-Warn "Resolved opencode version: v$($Resolved.Version)" }
  Write-Warn 'OpenCode user install path is available.'
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
    Write-Info 'Created backup for npm shim.'
  } catch {
    Write-Warn "Failed to create backup, aborting shim fix: $($_.Exception.Message)"
    return $false
  }
  
  $repl = '& "' + $ExePath + '" $args'
  $newText = [regex]::Replace($text, '&\s+\"/bin/sh\$exe\"[^\r\n]*', $repl)
  $enc = New-Object System.Text.UTF8Encoding($false)
  try {
    [IO.File]::WriteAllText($cmd.Source, $newText, $enc)
    Write-Info 'Fixed npm shim.'
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

function Get-OpenCodeUpgradeTimeoutSeconds() {
  $default = 120
  $v = $env:CHECK_AI_CLI_OPENCODE_UPGRADE_TIMEOUT_SECONDS
  if ([string]::IsNullOrWhiteSpace($v)) { return $default }
  $n = 0
  if (-not [int]::TryParse($v.Trim(), [ref]$n)) { return $default }
  if ($n -lt 10) { return 10 }
  if ($n -gt 900) { return 900 }
  return $n
}

function Invoke-OpenCodeUpgradeMethod([string]$Path, [string]$ArgString, [string]$Method) {
  $proc = $null
  $timeout = Get-OpenCodeUpgradeTimeoutSeconds
  try {
    $upgradeArgs = if ($ArgString) { @('upgrade',$ArgString,'--pure') } else { @('upgrade','--pure') }
    if ($Method) { $upgradeArgs += @('--method',$Method) }
    $proc = Start-Process -FilePath $Path -ArgumentList $upgradeArgs -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($timeout * 1000)) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      return "opencode upgrade timed out after ${timeout}s"
    }
    if ($proc.ExitCode -ne 0) {
      return "opencode upgrade failed with exit code $($proc.ExitCode)"
    }
    return ''
  } catch {
    return "opencode upgrade exception: $($_.Exception.Message)"
  }
}

function Try-OpenCodeSelfUpgrade([string]$TargetVersion) {
  $path = Get-OpenCodeCommandPath
  if (-not $path) { return $false }
  $arg = $null
  if ($TargetVersion) { $arg = "v$TargetVersion" }

  $lastErr = ''

  # Attempt 1: auto-detect method (default)
  $err = Invoke-OpenCodeUpgradeMethod $path $arg ''
  if (Test-OpenCodeAtLeast $TargetVersion) { return $true }
  if ($err) { $lastErr = $err }

  # Attempt 2: npm method (more reliable behind proxies)
  Write-Info "Trying: opencode upgrade --method npm"
  $err = Invoke-OpenCodeUpgradeMethod $path $arg 'npm'
  [void](Sync-OpenCodeStandaloneFromNpm)
  if (Test-OpenCodeAtLeast $TargetVersion) { return $true }
  if ($err) { $lastErr = $err }

  if ($lastErr) { Write-Warn $lastErr }
  return $false
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
  $url = 'https://opencode.ai/install'
  if (-not (Confirm-RemoteScriptExecution $url 'OpenCode')) {
    Write-Warn 'Remote script execution declined.'
    return $false
  }
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

function Get-OpenCodeNpmBinDir() {
  $prefix = Get-NpmGlobalBinDir
  if (-not $prefix) { return $null }
  $nodeModules = Join-Path $prefix 'node_modules'
  if (-not (Test-Path -LiteralPath $nodeModules)) { return $null }
  $pkgDir = Join-Path $nodeModules 'opencode-ai'
  if (-not (Test-Path -LiteralPath $pkgDir)) { return $null }
  $innerModules = Join-Path $pkgDir 'node_modules'
  if (-not (Test-Path -LiteralPath $innerModules)) { return $null }
  # Prefer x64 baseline (wider compatibility), fallback to x64
  foreach ($arch in @('opencode-windows-x64-baseline','opencode-windows-x64')) {
    $exe = Join-Path $innerModules "$arch\bin\opencode.exe"
    if (Test-Path -LiteralPath $exe) { return (Split-Path -Parent $exe) }
  }
  return $null
}

function Sync-OpenCodeStandaloneFromNpm() {
  $npmBinDir = Get-OpenCodeNpmBinDir
  if (-not $npmBinDir) { return $false }
  $npmExe = Join-Path $npmBinDir 'opencode.exe'
  if (-not (Test-Path -LiteralPath $npmExe)) { return $false }

  $npmVersion = Get-OpenCodeVersionAtPath $npmExe
  if (-not $npmVersion) { return $false }

  $standaloneDir = Join-Path $env:USERPROFILE '.opencode\bin'
  $standaloneExe = Join-Path $standaloneDir 'opencode.exe'
  $standaloneVersion = Get-OpenCodeVersionAtPath $standaloneExe

  $cmp = Compare-Version $standaloneVersion $npmVersion
  if ($cmp -ne -1) { return $false }

  Write-Info "Syncing standalone opencode from npm (v$npmVersion)"
  try {
    if (-not (Test-Path -LiteralPath $standaloneDir)) { New-Item -ItemType Directory -Path $standaloneDir -Force | Out-Null }
    try {
      Copy-Item -Path $npmExe -Destination $standaloneExe -Force -ErrorAction Stop
    } catch {
      # Destination is likely locked by a running opencode instance. Stop only
      # opencode (not other tools) and retry once, instead of killing it
      # unconditionally before every sync.
      $running = Get-Process -Name 'opencode' -ErrorAction SilentlyContinue
      if (-not $running) { throw }
      Write-Info 'Stopping running opencode process to complete sync'
      Stop-Process -Name 'opencode' -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
      Copy-Item -Path $npmExe -Destination $standaloneExe -Force
    }
    Write-Info "Standalone opencode synced to v$npmVersion"
    return $true
  } catch {
    Write-Warn "Failed to sync standalone opencode: $($_.Exception.Message)"
    return $false
  }
}

function Try-InstallOpenCodeWithNpm([string]$TargetVersion) {
  try {
    Invoke-NpmInstallGlobal 'opencode-ai@latest'
    [void](Sync-OpenCodeStandaloneFromNpm)
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
  if ($target) { Write-Info "Target OpenCode version: v$target" } else { $target = Get-LatestOpenCodeVersion }
  $hasNative = [bool](Get-OpenCodeCommandPath)
  if ($hasNative) {
    Write-Info "Trying: opencode upgrade"
    if ((Try-OpenCodeSelfUpgrade $target) -and (Test-OpenCodeAtLeast $target)) { return }
  }
  Write-Info "Trying: scoop install"
  if (Try-InstallOpenCodeWithScoop) { if ((Try-OpenCodeSelfUpgrade $target) -and (Test-OpenCodeAtLeast $target)) { return } }
  Write-Info "Trying: choco install"
  if (Try-InstallOpenCodeWithChoco) { if ((Try-OpenCodeSelfUpgrade $target) -and (Test-OpenCodeAtLeast $target)) { return } }
  Write-Info "Trying: npm install"
  if (Try-InstallOpenCodeWithNpm $target -and (Test-OpenCodeAtLeast $target)) { return }
  Write-Info "Trying: curl/wget install"
  if (Try-InstallOpenCodeWithCurl $target -and (Test-OpenCodeAtLeast $target)) { return }
  throw "No installer found. Install scoop/choco, Node.js (npm), or Git Bash (for curl) first."
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
  try { & $DoUpdate } catch {
    $script:UpdateFailed = $true
    Write-Fail $_.Exception.Message
  }
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
    if ($Title -eq 'Factory CLI (Droid)') {
      Write-Warn "Tip: try npm install -g droid@latest"
      Write-Warn "Tip: manually reinstall from https://app.factory.ai/cli/windows"
      return
    }
    if ($Title -eq 'Claude Code') {
      Write-Warn "Tip: try claude update"
      Write-Warn "Tip: if needed, reinstall via irm https://claude.ai/install.ps1 | iex"
      Write-Warn "Tip: fallback via npm install -g @anthropic-ai/claude-code@latest"
      return
    }
    if ($Title -eq 'OpenAI Codex') {
      Write-Warn "Tip: try npm install -g @openai/codex@latest"
      Write-Warn "Tip: verify Node.js version (node -v) meets codex requirements"
    }
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

  # Detect network/proxy once: exports proxy to child processes and primes the
  # regional npm mirror used by Invoke-NpmInstallGlobal. Does not touch ~/.npmrc.
  [void](Initialize-NetworkDetection)

  if ($FactoryOnly) {
    Invoke-Selection '1'
    if ($script:UpdateFailed) { exit 1 }
    exit 0
  }

  $sel = Ask-Selection
  if ($sel -eq 'Q') {
    exit 0
  }
  Invoke-Selection $sel
  if ($script:UpdateFailed) { exit 1 }
}
