param(
  [switch]$Auto
)

$ErrorActionPreference = 'Stop'

# npm-only AI CLI checker:
#   @anthropic-ai/claude-code@latest
#   @openai/codex@latest
#   @google/gemini-cli@latest
#   @xai-official/grok@latest
#   opencode-ai@latest
# No Factory, remote install scripts, scoop/choco/brew, or native self-upgrade.

function Get-AutoMode() {
  if ($Auto) { return $true }
  $v = $env:CHECK_AI_CLI_AUTO
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

$script:AutoMode = Get-AutoMode
$script:UpdateFailed = $false
$script:BestNpmMirror = $null
$script:EffectiveProxyUrl = $null
$script:EffectiveNoProxy = $null
$script:NetworkInfo = $null

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

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

# ---------------------------------------------------------------------------
# Tool registry (single source of truth)
# ---------------------------------------------------------------------------

function Get-AiCliTools() {
  return @(
    @{
      Id = 'claude'
      Title = 'Claude Code'
      Package = '@anthropic-ai/claude-code'
      Spec = '@anthropic-ai/claude-code@latest'
      Commands = @('claude', 'claude-code')
      Kind = 'npm'
    },
    @{
      Id = 'codex'
      Title = 'OpenAI Codex'
      Package = '@openai/codex'
      Spec = '@openai/codex@latest'
      Commands = @('codex')
      Kind = 'npm'
      NeedsOptionalProbe = $true
    },
    @{
      Id = 'gemini'
      Title = 'Gemini CLI'
      Package = '@google/gemini-cli'
      Spec = '@google/gemini-cli@latest'
      Commands = @('gemini')
      Kind = 'npm'
    },
    @{
      Id = 'grok'
      Title = 'Grok Build'
      Package = '@xai-official/grok'
      Spec = '@xai-official/grok@latest'
      Commands = @('grok')
      Kind = 'npm'
      NeedsOptionalProbe = $true
    },
    @{
      Id = 'opencode'
      Title = 'OpenCode'
      Package = 'opencode-ai'
      Spec = 'opencode-ai@latest'
      Commands = @('opencode')
      Kind = 'npm'
    }
  )
}

function Get-AiCliToolById([string]$Id) {
  foreach ($t in (Get-AiCliTools)) {
    if ($t.Id -eq $Id) { return $t }
  }
  return $null
}

# ---------------------------------------------------------------------------
# Network / proxy / npm mirror
# ---------------------------------------------------------------------------

$script:NpmMirrors = @{
  taobao  = 'https://registry.npmmirror.com'
  tencent = 'https://mirrors.cloud.tencent.com/npm/'
  huawei  = 'https://repo.huaweicloud.com/repository/npm/'
  default = 'https://registry.npmjs.org'
}

function Get-SystemProxySettings() {
  $result = @{
    Enabled = $false
    Server = $null
    Bypass = $null
  }
  try {
    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($settings) {
      $result.Enabled = [bool]$settings.ProxyEnable
      $result.Server = $settings.ProxyServer
      $result.Bypass = $settings.ProxyOverride
    }
  } catch { }
  return $result
}

function Get-EnvProxySettings() {
  return @{
    HttpProxy = if ($env:HTTP_PROXY) { $env:HTTP_PROXY } elseif ($env:http_proxy) { $env:http_proxy } else { $null }
    HttpsProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:https_proxy) { $env:https_proxy } else { $null }
    NoProxy = if ($env:NO_PROXY) { $env:NO_PROXY } elseif ($env:no_proxy) { $env:no_proxy } else { $null }
    AllProxy = if ($env:ALL_PROXY) { $env:ALL_PROXY } elseif ($env:all_proxy) { $env:all_proxy } else { $null }
  }
}

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

function ConvertTo-NoProxy([string]$Bypass) {
  if ([string]::IsNullOrWhiteSpace($Bypass)) { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($entry in ($Bypass -split ';')) {
    $t = $entry.Trim()
    if (-not $t -or $t -eq '<local>') { continue }
    $t = $t -replace '\*$', ''
    if ($t) { $null = $out.Add($t) }
  }
  if ($out.Count -eq 0) { return $null }
  return ($out -join ',')
}

function Get-NormalizedProxy([hashtable]$SystemProxy, [hashtable]$EnvProxy) {
  $noProxy = $null
  if ($EnvProxy -and -not [string]::IsNullOrWhiteSpace($EnvProxy.NoProxy)) {
    $noProxy = $EnvProxy.NoProxy.Trim()
  }

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

  if ($SystemProxy -and $SystemProxy.Enabled -and -not [string]::IsNullOrWhiteSpace($SystemProxy.Server)) {
    $server = [string]$SystemProxy.Server
    $candidate = $server
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

function Set-EffectiveProxyEnvironment($Proxy) {
  $script:EffectiveProxyUrl = $null
  $script:EffectiveNoProxy = $null
  if (-not $Proxy -or [string]::IsNullOrWhiteSpace($Proxy.Url)) { return $Proxy }

  $url = [string]$Proxy.Url
  $noProxy = $Proxy.NoProxy
  if ($Proxy.IsHttpProxy) {
    $env:HTTP_PROXY = $url; $env:http_proxy = $url
    $env:HTTPS_PROXY = $url; $env:https_proxy = $url
    $env:ALL_PROXY = $null; $env:all_proxy = $null
    $script:EffectiveProxyUrl = $url
  } else {
    $env:ALL_PROXY = $url; $env:all_proxy = $url
  }
  if (-not [string]::IsNullOrWhiteSpace($noProxy)) {
    $env:NO_PROXY = $noProxy; $env:no_proxy = $noProxy
    $script:EffectiveNoProxy = $noProxy
  }
  return $Proxy
}

function Get-WebRequestProxyParameters() {
  if ($script:EffectiveProxyUrl) { return @{ Proxy = $script:EffectiveProxyUrl } }
  return @{}
}

function Test-UrlTiming([string]$Url, [int]$TimeoutSec = 5) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $px = Get-WebRequestProxyParameters
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest @px -Uri $Url -UseBasicParsing -Method Head -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
    } finally { $ProgressPreference = $prev }
    $sw.Stop()
    return [int]$sw.ElapsedMilliseconds
  } catch {
    $sw.Stop()
    return -1
  }
}

function Test-ActualConnectivity() {
  $result = @{
    NpmjsOK = $false; NpmjsTime = -1
    NpmmirrorOK = $false; NpmmirrorTime = -1
  }
  $npmjs = Test-UrlTiming 'https://registry.npmjs.org' 5
  if ($npmjs -ge 0) { $result.NpmjsOK = $true; $result.NpmjsTime = $npmjs }
  $mirror = Test-UrlTiming 'https://registry.npmmirror.com' 5
  if ($mirror -ge 0) { $result.NpmmirrorOK = $true; $result.NpmmirrorTime = $mirror }
  return $result
}

function Get-EffectiveRegion([hashtable]$Connectivity) {
  $override = $env:CHECK_AI_CLI_REGION
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    switch ($override.Trim().ToLowerInvariant()) {
      { $_ -in @('china', 'cn') } { return 'china' }
      { $_ -in @('global', 'intl') } { return 'global' }
    }
  }
  if ($Connectivity.NpmmirrorOK -and (-not $Connectivity.NpmjsOK -or ($Connectivity.NpmmirrorTime -ge 0 -and $Connectivity.NpmjsTime -ge 0 -and $Connectivity.NpmmirrorTime -lt $Connectivity.NpmjsTime))) {
    return 'china'
  }
  if ($Connectivity.NpmjsOK) { return 'global' }
  if ($Connectivity.NpmmirrorOK) { return 'china' }
  return 'unknown'
}

function Initialize-NetworkDetection() {
  Write-Info 'Detecting network environment...'
  $sys = Get-SystemProxySettings
  $envp = Get-EnvProxySettings
  $proxy = Get-NormalizedProxy $sys $envp
  if ($proxy) {
    Write-Info ("System proxy detected: {0}" -f (Get-LogSafeProxyUrl $proxy.Url))
    [void](Set-EffectiveProxyEnvironment $proxy)
    Write-Info ("Applying detected proxy to all network operations: {0}" -f (Get-LogSafeProxyUrl $proxy.Url))
  } else {
    Write-Info 'No proxy configured (direct connection)'
  }
  Write-Info 'Testing connectivity to determine best npm source...'
  $conn = Test-ActualConnectivity
  $region = Get-EffectiveRegion $conn
  $script:NetworkInfo = @{ Connectivity = $conn; Region = $region; Proxy = $proxy }
  if ($proxy) { Write-Info 'Network mode: Global proxy (all traffic proxied)' }
  else { Write-Info 'Network mode: Direct' }
  Write-Info "Effective region for npm: $region"
  return $script:NetworkInfo
}

function Get-BestNpmMirror() {
  if ($script:BestNpmMirror) { return $script:BestNpmMirror }
  $region = 'unknown'
  $conn = $null
  if ($script:NetworkInfo) {
    $region = $script:NetworkInfo.Region
    $conn = $script:NetworkInfo.Connectivity
  }
  if ($region -eq 'china') {
    if ($conn -and $conn.NpmmirrorOK) {
      Write-Info 'Using China npm mirror: npmmirror (taobao)'
      $script:BestNpmMirror = $script:NpmMirrors['taobao']
      return $script:BestNpmMirror
    }
    foreach ($name in @('tencent', 'huawei')) {
      $url = $script:NpmMirrors[$name]
      if ((Test-UrlTiming $url 4) -ge 0) {
        Write-Info "Using China npm mirror: $name"
        $script:BestNpmMirror = $url
        return $script:BestNpmMirror
      }
    }
    Write-Info 'Using China npm mirror: npmmirror (taobao) [fallback]'
    $script:BestNpmMirror = $script:NpmMirrors['taobao']
    return $script:BestNpmMirror
  }
  Write-Info 'Using official npm registry'
  $script:BestNpmMirror = $script:NpmMirrors['default']
  return $script:BestNpmMirror
}

function Get-OfficialNpmRegistry() { return $script:NpmMirrors['default'] }

function Get-RegistryCandidates() {
  $mirror = Get-BestNpmMirror
  $official = Get-OfficialNpmRegistry
  if ($mirror -eq $official) { return @($official) }
  return @($mirror, $official)
}

# ---------------------------------------------------------------------------
# HTTP helpers / semver
# ---------------------------------------------------------------------------

function Get-Text([string]$Uri) {
  $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
  $px = Get-WebRequestProxyParameters
  $retry = Get-RetryCount
  for ($i = 1; $i -le $retry; $i++) {
    try {
      $prev = $ProgressPreference
      $ProgressPreference = 'SilentlyContinue'
      try {
        $resp = Invoke-WebRequest @px -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
      } finally { $ProgressPreference = $prev }
      return [string]$resp.Content
    } catch {
      if ($i -eq $retry) { return $null }
      Start-Sleep -Seconds $i
    }
  }
  return $null
}

function Get-Json([string]$Uri) {
  $text = Get-Text $Uri
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-SemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, '(?<![0-9.])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-VersionParts([string]$Version) {
  $v = Get-SemVer $Version
  if (-not $v) { return $null }
  $p = $v.Split('.')
  return @([int]$p[0], [int]$p[1], [int]$p[2])
}

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

# ---------------------------------------------------------------------------
# Command / PATH helpers
# ---------------------------------------------------------------------------

function Get-CommandSourcePath($CommandInfo) {
  if (-not $CommandInfo) { return $null }
  if ($CommandInfo.Path) { return [string]$CommandInfo.Path }
  if ($CommandInfo.Source) { return [string]$CommandInfo.Source }
  return $null
}

function Resolve-ApplicationCommand {
  param(
    [string[]]$Name,
    [string[]]$CommandType = @('Application', 'ExternalScript')
  )
  foreach ($n in $Name) {
    $cmd = Get-Command $n -CommandType $CommandType -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd }
  }
  return $null
}

function Resolve-ApplicationCommandPath {
  param(
    [string[]]$Name,
    [string[]]$CommandType = @('Application', 'ExternalScript')
  )
  return (Get-CommandSourcePath (Resolve-ApplicationCommand -Name $Name -CommandType $CommandType))
}

function Normalize-Dir([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) { return $null }
  try { return [IO.Path]::GetFullPath($Dir).TrimEnd('\') } catch { return $Dir.TrimEnd('\') }
}

function Test-ValidPathEntry([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
  if ($Dir -match '[\*\?]') { return $false }
  return $true
}

function Path-ContainsDir([string]$PathValue, [string]$Dir) {
  $target = Normalize-Dir $Dir
  if (-not $target) { return $false }
  foreach ($part in @($PathValue -split ';')) {
    if (-not (Test-ValidPathEntry $part)) { continue }
    $n = Normalize-Dir $part
    if ($n -and $n.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Remove-PathEntry([string]$PathValue, [string]$Dir) {
  $target = Normalize-Dir $Dir
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($part in @($PathValue -split ';')) {
    if (-not (Test-ValidPathEntry $part)) { continue }
    $n = Normalize-Dir $part
    if ($n -and $target -and $n.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($part) { $null = $kept.Add($part) }
  }
  return ($kept -join ';')
}

function Prepend-PathEntry([string]$PathValue, [string]$Dir) {
  $clean = Remove-PathEntry $PathValue $Dir
  $dir = Normalize-Dir $Dir
  if (-not $dir) { return $clean }
  if ([string]::IsNullOrWhiteSpace($clean)) { return $dir }
  return ($dir + ';' + $clean)
}

function Get-UserPathValue() {
  return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPathValue([string]$PathValue) {
  [Environment]::SetEnvironmentVariable('Path', $PathValue, 'User')
  $env:Path = $PathValue + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
}

function Ensure-UserPathPrefers([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return $false }
  $dir = Normalize-Dir $Dir
  $user = Get-UserPathValue
  if ([string]::IsNullOrWhiteSpace($user)) { $user = '' }
  $next = Prepend-PathEntry $user $dir
  if ($next -ne $user) {
    Set-UserPathValue $next
    Write-Info "Moved a tool directory to the front of your PATH permanently"
  } else {
    $process = $env:Path
    if (-not (Path-ContainsDir $process $dir) -or -not $process.TrimStart().StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
      $env:Path = Prepend-PathEntry $process $dir
    }
  }
  return $true
}

function Get-NpmCommandPath() {
  $npmPath = Resolve-ApplicationCommandPath -Name @('npm.cmd', 'npm') -CommandType @('Application')
  if ($npmPath) { return $npmPath }
  return (Resolve-ApplicationCommandPath -Name @('npm') -CommandType @('ExternalScript'))
}

function Get-NpmGlobalBinDir() {
  $npmPath = Get-NpmCommandPath
  if (-not $npmPath) { return $null }
  try {
    $prefix = (& $npmPath config get prefix 2>$null | Out-String).Trim()
  } catch { return $null }
  if ([string]::IsNullOrWhiteSpace($prefix)) { return $null }
  # Windows npm prefix is typically the global bin dir itself.
  if (Test-Path -LiteralPath (Join-Path $prefix 'npm.cmd')) { return (Normalize-Dir $prefix) }
  $bin = Join-Path $prefix 'bin'
  if (Test-Path -LiteralPath $bin) { return (Normalize-Dir $bin) }
  return (Normalize-Dir $prefix)
}

function Repair-ToolUserPath([string]$ToolId) {
  $npmBin = Get-NpmGlobalBinDir
  if ($npmBin) { [void](Ensure-UserPathPrefers $npmBin) }
  return $true
}

function Get-CommandVersionInfo([string]$CommandName) {
  $cmd = Resolve-ApplicationCommand -Name @($CommandName)
  if (-not $cmd) { return @{ Name = $CommandName; Source = $null; Version = $null } }
  $source = Get-CommandSourcePath $cmd
  $version = $null
  try {
    $out = & $source '--version' 2>&1 | Out-String
    $version = Get-SemVer $out
    if (-not $version) {
      $out2 = & $source '-v' 2>&1 | Out-String
      $version = Get-SemVer $out2
    }
  } catch { }
  return @{ Name = $CommandName; Source = $source; Version = $version }
}

function Get-InstalledToolCandidate([string]$ToolId, [string[]]$CommandNames) {
  $saved = $env:Path
  try {
    $npmBin = Get-NpmGlobalBinDir
    if ($npmBin) {
      $env:Path = $npmBin + ';' + $saved
    }
    foreach ($name in $CommandNames) {
      $info = Get-CommandVersionInfo $name
      if ($info.Source) {
        return @{
          Version = $info.Version
          Path = $info.Source
          Source = $info.Source
          Kind = 'npm'
          Command = $name
        }
      }
    }
    return @{ Version = $null; Path = $null; Source = $null; Kind = $null; Command = $null }
  } finally {
    $env:Path = $saved
  }
}

function Get-LocalToolVersion([hashtable]$Tool) {
  [void](Repair-ToolUserPath $Tool.Id)
  $candidate = Get-InstalledToolCandidate $Tool.Id $Tool.Commands
  return $candidate.Version
}

# ---------------------------------------------------------------------------
# npm install / latest
# ---------------------------------------------------------------------------

function Invoke-NpmInstallGlobal([string]$PackageSpec, [string]$RegistryOverride = $null) {
  if ([string]::IsNullOrWhiteSpace($RegistryOverride) -and $null -eq $script:BestNpmMirror) {
    $script:BestNpmMirror = Get-BestNpmMirror
  }
  $registry = if ([string]::IsNullOrWhiteSpace($RegistryOverride)) { $script:BestNpmMirror } else { $RegistryOverride }
  $npmPath = Get-NpmCommandPath
  if (-not $npmPath) { throw 'npm not found. Install Node.js first.' }

  if ($npmPath -like '*.ps1') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $npmPath install -g $PackageSpec --registry $registry
  } else {
    & $npmPath install -g $PackageSpec --registry $registry
  }
  if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
}

function Get-NpmLatestVersion([string]$PackageName, [string]$Registry = $null) {
  $registries = if ($Registry) { @($Registry) } else { Get-RegistryCandidates }
  foreach ($reg in $registries) {
    $base = $reg.TrimEnd('/')
    $encoded = ($PackageName -replace '/', '%2F')
    # scoped packages: registry.npmjs.org/@scope%2Fname/latest
    $url = "$base/$PackageName/latest"
    if ($PackageName.StartsWith('@')) {
      $url = "$base/$encoded/latest"
    }
    $json = Get-Json $url
    if ($json -and $json.version) {
      $ver = Get-SemVer ([string]$json.version)
      if ($ver) { return $ver }
    }
  }
  return $null
}

function Get-LatestToolVersion([hashtable]$Tool) {
  return (Get-NpmLatestVersion $Tool.Package)
}

function Invoke-VersionProbe([string[]]$CommandNames) {
  foreach ($name in $CommandNames) {
    $cmd = Resolve-ApplicationCommand -Name @($name)
    if (-not $cmd) { continue }
    $source = Get-CommandSourcePath $cmd
    try {
      $out = & $source '--version' 2>&1 | Out-String
      $ver = Get-SemVer $out
      return @{ Version = $ver; Output = $out; Source = $source }
    } catch {
      return @{ Version = $null; Output = $_.Exception.Message; Source = $source }
    }
  }
  return @{ Version = $null; Output = ''; Source = $null }
}

function Get-MissingOptionalPackageName([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  # e.g. Cannot find module '@openai/codex-win32-x64' or similar optional dep hints
  $m = [regex]::Match($Text, "Cannot find module ['\`"](@[^'\`"]+)['\`"]")
  if ($m.Success) { return $m.Groups[1].Value }
  $m2 = [regex]::Match($Text, "missing optional dependency[:\s]+(@?[A-Za-z0-9_@/.-]+)", 'IgnoreCase')
  if ($m2.Success) { return $m2.Groups[1].Value }
  return $null
}

function Test-ToolRunnable([hashtable]$Tool) {
  $probe = Invoke-VersionProbe $Tool.Commands
  return [bool]$probe.Version
}

function Update-ToolViaNpm([hashtable]$Tool) {
  Write-Info "Updating $($Tool.Title)..."
  if (-not (Get-NpmCommandPath)) {
    throw 'No installer found. Install Node.js (npm) first. This checker only supports: npm i -g <package>@latest'
  }

  $target = Get-LatestToolVersion $Tool
  $official = Get-OfficialNpmRegistry
  $registries = Get-RegistryCandidates

  $installed = $false
  $lastError = $null
  foreach ($reg in $registries) {
    try {
      Write-Info "Trying: npm install ($reg)"
      Invoke-NpmInstallGlobal $Tool.Spec $reg
      $installed = $true
      break
    } catch {
      $lastError = $_.Exception.Message
      Write-Warn "npm install via $reg failed: $lastError"
    }
  }
  if (-not $installed) {
    throw "npm install failed for $($Tool.Spec). Last error: $lastError"
  }

  [void](Repair-ToolUserPath $Tool.Id)
  $probe = Invoke-VersionProbe $Tool.Commands

  if (-not $probe.Version -and $Tool.NeedsOptionalProbe) {
    $missing = Get-MissingOptionalPackageName $probe.Output
    if ($missing) {
      Write-Warn "Install may be missing optional package $missing; retrying official npm registry"
      Invoke-NpmInstallGlobal $Tool.Spec $official
      [void](Repair-ToolUserPath $Tool.Id)
      $probe = Invoke-VersionProbe $Tool.Commands
    } elseif ($registries[0] -ne $official) {
      Write-Warn 'Installed package is not runnable; retrying official npm registry'
      Invoke-NpmInstallGlobal $Tool.Spec $official
      [void](Repair-ToolUserPath $Tool.Id)
      $probe = Invoke-VersionProbe $Tool.Commands
    }
  }

  if (-not $probe.Version) {
    if (-not [string]::IsNullOrWhiteSpace($probe.Output)) {
      throw "$($Tool.Title) installed but is not runnable: $($probe.Output.Trim())"
    }
    throw "$($Tool.Title) installed but local version could not be verified."
  }

  if ($target) {
    $cmp = Compare-Version $probe.Version $target
    if ($cmp -eq -1) {
      throw "$($Tool.Title) installed v$($probe.Version) but target is v$target"
    }
  }
}

# ---------------------------------------------------------------------------
# Lifecycle / UI
# ---------------------------------------------------------------------------

function Confirm-Yes([string]$Prompt) {
  if ($script:AutoMode) { return $true }
  $ans = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans.Trim().ToUpperInvariant().StartsWith('Y')
}

function Write-ToolHeader([string]$Title) {
  Write-Host ''
  Write-Host $Title
  Write-Host ('=' * $Title.Length)
}

function Get-AndPrintLatest([scriptblock]$GetLatest) {
  Write-Info 'Fetching latest version...'
  $latest = & $GetLatest
  if ($latest) { Write-Success "Latest version: v$latest" } else { Write-Warn 'Latest version: unknown' }
  return $latest
}

function Get-AndPrintLocal([scriptblock]$GetLocal) {
  $local = & $GetLocal
  if ($local) { Write-Success "Local version: v$local" } else { Write-Warn 'Local version: not installed' }
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
    if (-not $Latest) { Write-Warn 'Latest version unknown. Installing anyway.' }
    if (Confirm-Yes 'Install now? (Y/N): ') { Try-Update $DoUpdate; return $true }
    return $false
  }
  if (-not $Latest) { Write-Warn 'Latest version unknown. Skipping update check.'; return $false }
  $cmp = Compare-Version $Local $Latest
  if ($cmp -eq 0) { Write-Success 'Already up to date.'; return $false }
  if ($cmp -eq 1) { Write-Warn 'Local version is newer than latest source.'; return $false }
  if ($cmp -eq -1 -and (Confirm-Yes 'Update now? (Y/N): ')) { Try-Update $DoUpdate; return $true }
  return $false
}

function Report-PostUpdate([string]$Title, [string]$Latest, [scriptblock]$GetLocal) {
  Write-Info 'Re-checking local version...'
  $newLocal = Get-AndPrintLocal $GetLocal
  if (-not $newLocal) {
    $script:UpdateFailed = $true
    Write-Warn 'Update may not have installed correctly.'
    return
  }
  if (-not $Latest) { return }
  $cmp = Compare-Version $newLocal $Latest
  if ($cmp -eq -1) {
    $script:UpdateFailed = $true
    Write-Warn 'Update may have failed (still older than latest).'
    Write-Warn 'Tip: npm i -g <package>@latest --registry https://registry.npmjs.org'
    Write-Warn 'Tip: ensure npm global bin is first on PATH (where.exe <command>)'
  }
}

function Invoke-ToolLifecycle([hashtable]$Adapter) {
  Write-ToolHeader $Adapter.Title
  $latest = Get-AndPrintLatest $Adapter.GetLatest
  $local = Get-AndPrintLocal $Adapter.GetLocal
  $didUpdate = Handle-UpdateFlow $latest $local $Adapter.Update
  if ($didUpdate) { Report-PostUpdate $Adapter.Title $latest $Adapter.GetLocal }
  return @{
    Title = $Adapter.Title
    Latest = $latest
    Local = $local
    Updated = $didUpdate
    Failed = $script:UpdateFailed
  }
}

function Check-OneTool([hashtable]$Tool) {
  [void](Invoke-ToolLifecycle @{
    Title = $Tool.Title
    GetLatest = { Get-LatestToolVersion $Tool }.GetNewClosure()
    GetLocal = { Get-LocalToolVersion $Tool }.GetNewClosure()
    Update = { Update-ToolViaNpm $Tool }.GetNewClosure()
  })
}

function Show-Banner() {
  Write-Host ''
  Write-Host '==============================================='
  Write-Host ' AI CLI Version Checker (npm-only)'
  Write-Host ' Claude Code | OpenAI Codex | Gemini CLI | Grok Build | OpenCode'
  Write-Host '==============================================='
  Write-Host ''
}

function Ask-Selection() {
  Write-Host 'Select tools to check:'
  Write-Host '  [1] Claude Code'
  Write-Host '  [2] OpenAI Codex'
  Write-Host '  [3] Gemini CLI'
  Write-Host '  [4] Grok Build'
  Write-Host '  [5] OpenCode'
  Write-Host '  [A] Check all (default)'
  Write-Host '  [U] Check all and Update all (auto-yes)'
  Write-Host '  [Q] Quit'
  $s = Read-Host 'Enter choice (1-5/A/U/Q)'
  if ([string]::IsNullOrWhiteSpace($s)) { return 'A' }
  return $s.Trim().ToUpperInvariant()
}

function Invoke-Selection([string]$Selection) {
  $checkAll = ($Selection -eq 'A' -or $Selection -eq 'U')
  if ($Selection -eq 'U') { $script:AutoMode = $true }

  $tools = Get-AiCliTools
  $map = @{
    '1' = 'claude'
    '2' = 'codex'
    '3' = 'gemini'
    '4' = 'grok'
    '5' = 'opencode'
  }

  if ($checkAll) {
    foreach ($t in $tools) { Check-OneTool $t }
    return
  }
  if ($map.ContainsKey($Selection)) {
    $tool = Get-AiCliToolById $map[$Selection]
    if ($tool) { Check-OneTool $tool }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Require-WebRequest
  Show-Banner
  [void](Initialize-NetworkDetection)

  $sel = Ask-Selection
  if ($sel -eq 'Q') { exit 0 }
  Invoke-Selection $sel
  if ($script:UpdateFailed) { exit 1 }
}
