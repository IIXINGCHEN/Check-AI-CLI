$ErrorActionPreference = 'Stop'

# Proxy propagation: detected proxy must be normalized and exported so child
# processes (curl/node/claude updater/opencode/npm) actually use it.
# Main script has a dot-source guard (InvocationName -ne '.'), so sourcing only loads functions.

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual:   $Actual"
  }
}
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Null($Actual, [string]$Message) {
  if ($null -ne $Actual) { throw "$Message`nExpected: <null>`nActual:   $Actual" }
}
# "Not set" = absent or empty/whitespace. PS 5.1 and PS 7 differ on whether a
# missing env var reads back as $null or '', so env assertions use this form.
function Assert-EnvNotSet([string]$Name, [string]$Message) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrEmpty($v)) { throw "$Message`nExpected: <not set>`nActual:   $v" }
}

# Build hashtables shaped like Get-SystemProxySettings / Get-EnvProxySettings output
function New-SysProxy([string]$Server, [string]$Bypass = $null, [bool]$Enabled = $true) {
  return @{ Enabled = $Enabled; Server = $Server; Bypass = $Bypass; AutoConfig = $false; AutoConfigUrl = $null }
}
function New-EnvProxy([string]$Http = $null, [string]$Https = $null, [string]$All = $null, [string]$No = $null) {
  return @{ HttpProxy = $Http; HttpsProxy = $Https; NoProxy = $No; AllProxy = $All }
}

# Snapshot/restore process env so tests stay hermetic
$envKeys = 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy'
$script:envSnapshot = @{}
foreach ($k in $envKeys) { $script:envSnapshot[$k] = [Environment]::GetEnvironmentVariable($k) }

function Reset-ProxyEnv() {
  foreach ($k in $envKeys) {
    $saved = $script:envSnapshot[$k]
    if ([string]::IsNullOrEmpty($saved)) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
    else { Set-Item -LiteralPath "Env:$k" -Value $saved }
  }
  $script:EffectiveProxyUrl = $null
  $script:EffectiveNoProxy = $null
  $script:NetworkInfo = $null
  $script:CapturedWarnings = @()
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  try {
    Reset-ProxyEnv
    & $Body
    Write-Host "[PASS] $Name" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    Reset-ProxyEnv
    throw
  }
}

function Write-Warn([string]$Message) {
  $script:CapturedWarnings += $Message
}

Run-Test 'Initialize-NetworkDetection warns when only PAC proxy is detected' {
  function Get-SystemProxySettings() {
    return @{ Enabled = $false; Server = $null; Bypass = $null; AutoConfig = $true; AutoConfigUrl = 'http://proxy.local/proxy.pac' }
  }
  function Get-EnvProxySettings() { return New-EnvProxy }
  function Test-ActualConnectivity() {
    return @{ GoogleOK = $false; GoogleTime = -1; BaiduOK = $false; BaiduTime = -1; NpmjsOK = $false; NpmjsTime = -1; NpmmirrorOK = $false; NpmmirrorTime = -1 }
  }

  [void](Initialize-NetworkDetection)

  Assert-True ($script:CapturedWarnings -contains 'PAC auto-config detected but cannot be resolved automatically. Set HTTP_PROXY/HTTPS_PROXY for reliable CLI updates.') 'Expected PAC-only proxy configurations to produce an actionable warning.'
}

Run-Test 'Get-NormalizedProxy adds http:// scheme to bare host:port (registry form)' {
  $p = Get-NormalizedProxy (New-SysProxy '127.0.0.1:7890' 'localhost;127.*;<local>') (New-EnvProxy)
  Assert-Equal $p.Url 'http://127.0.0.1:7890' 'Registry ProxyServer without scheme must gain an http:// prefix so curl/node accept it.'
  Assert-True ($p.IsHttpProxy) 'An http proxy must be flagged IsHttpProxy so -Proxy can be attached to Invoke-WebRequest.'
  Assert-Equal $p.Source 'system' 'When only the system proxy is set, source must be system.'
  Assert-Equal $p.NoProxy 'localhost,127.' 'Registry ProxyOverride must be translated to comma-joined NO_PROXY (strip <local> and trailing wildcard).'
}

Run-Test 'Get-NormalizedProxy leaves an already-schemed URL untouched' {
  $p = Get-NormalizedProxy (New-SysProxy 'http://10.0.0.5:8080') (New-EnvProxy)
  Assert-Equal $p.Url 'http://10.0.0.5:8080' 'A URL that already has a scheme must not be re-prefixed.'
}

Run-Test 'Get-NormalizedProxy parses per-protocol registry form and prefers https' {
  $p = Get-NormalizedProxy (New-SysProxy 'http=127.0.0.1:8080;https=127.0.0.1:8443;ftp=127.0.0.1:8021') (New-EnvProxy)
  Assert-Equal $p.Url 'http://127.0.0.1:8443' 'Per-protocol ProxyServer must pick the https entry and normalize its scheme.'
}

Run-Test 'Get-NormalizedProxy prefers environment proxy over system proxy' {
  $p = Get-NormalizedProxy (New-SysProxy '127.0.0.1:7890') (New-EnvProxy -Https 'http://env-proxy:9000')
  Assert-Equal $p.Url 'http://env-proxy:9000' 'When HTTPS_PROXY is set, it must win over the registry server.'
  Assert-True ($p.Source -like 'env:*') 'Source must reflect that the proxy came from the environment.'
}

Run-Test 'Get-NormalizedProxy returns null when no proxy is configured' {
  Assert-Null (Get-NormalizedProxy (New-SysProxy $null $null $false) (New-EnvProxy)) 'With no system and no env proxy, result must be null (direct connection).'
  Assert-Null (Get-NormalizedProxy (New-SysProxy '127.0.0.1:7890' $null $false) (New-EnvProxy)) 'A registry server with Enabled=false must not be used.'
}

Run-Test 'Get-NormalizedProxy flags a SOCKS proxy as non-HTTP' {
  $p = Get-NormalizedProxy (New-SysProxy 'socks5://127.0.0.1:1080') (New-EnvProxy)
  Assert-Equal $p.Url 'socks5://127.0.0.1:1080' 'SOCKS URL must be preserved verbatim.'
  Assert-True (-not $p.IsHttpProxy) 'A socks scheme must NOT be flagged IsHttpProxy (PS -Proxy cannot use SOCKS).'
}

Run-Test 'Set-EffectiveProxyEnvironment exports HTTP proxy to all env vars and sets WebProxy params' {
  $proxy = @{ Url = 'http://127.0.0.1:7890'; NoProxy = 'localhost,127.'; Source = 'system'; IsHttpProxy = $true }
  [void](Set-EffectiveProxyEnvironment $proxy)
  foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy') {
    Assert-Equal ([Environment]::GetEnvironmentVariable($k)) 'http://127.0.0.1:7890' "$k must be set so curl/node/npm subprocesses inherit the proxy."
  }
  Assert-Equal $env:NO_PROXY 'localhost,127.' 'NO_PROXY must be exported from the bypass list.'
  Assert-Equal $script:EffectiveProxyUrl 'http://127.0.0.1:7890' 'EffectiveProxyUrl must hold the URL for IW -Proxy splatting.'
  $px = Get-WebRequestProxyParameters
  Assert-Equal $px.Proxy 'http://127.0.0.1:7890' 'Get-WebRequestProxyParameters must return the splattable Proxy parameter.'
}

Run-Test 'Set-EffectiveProxyEnvironment exports SOCKS only via ALL_PROXY (no -Proxy for IW)' {
  $proxy = @{ Url = 'socks5://127.0.0.1:1080'; NoProxy = $null; Source = 'system'; IsHttpProxy = $false }
  [void](Set-EffectiveProxyEnvironment $proxy)
  Assert-Equal ([Environment]::GetEnvironmentVariable('ALL_PROXY')) 'socks5://127.0.0.1:1080' 'SOCKS must be exported to ALL_PROXY for socks-capable subprocesses.'
  Assert-EnvNotSet 'HTTP_PROXY' 'HTTP_PROXY must NOT be set for a SOCKS-only proxy.'
  Assert-Null $script:EffectiveProxyUrl 'SOCKS proxy must not populate EffectiveProxyUrl (Invoke-WebRequest -Proxy cannot use SOCKS).'
  Assert-True ((Get-WebRequestProxyParameters).Count -eq 0) 'WebProxyParameters must be empty for SOCKS so IW is not given an unusable proxy.'
}

Run-Test 'Set-EffectiveProxyEnvironment with null input is a no-op (no env pollution when direct)' {
  $script:EffectiveProxyUrl = 'sentinel'
  [void](Set-EffectiveProxyEnvironment $null)
  Assert-Null $script:EffectiveProxyUrl 'Null input must reset EffectiveProxyUrl so direct connections are not proxied.'
  Assert-True ((Get-WebRequestProxyParameters).Count -eq 0) 'No proxy must yield empty splat parameters.'
  foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
    Assert-EnvNotSet $k "Null input must not write $k."
  }
}

Reset-ProxyEnv
Write-Host '[PASS] All proxy-propagation tests passed.' -ForegroundColor Green
