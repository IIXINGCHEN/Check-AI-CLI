# Purge GitHub raw.githubusercontent.com CDN cache
# Usage: .\purge-github-cache.ps1 [-All] [-Wait]
# 
# GitHub CDN caches raw files for ~5 minutes. This script helps purge the cache
# by making requests with cache-busting headers.

param(
  [switch]$All,    # Purge all files (default: only checksums.sha256)
  [switch]$Wait,   # Wait and verify cache is cleared
  [switch]$Verify  # Only verify, don't purge
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

$RepoOwner = 'IIXINGCHEN'
$RepoName = 'Check-AI-CLI'
$Branch = 'main'

$BaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$CdnBaseUrl = "https://rawcdn.githack.com/$RepoOwner/$RepoName/$Branch"
$JsDelivrUrl = "https://cdn.jsdelivr.net/gh/$RepoOwner/$RepoName@$Branch"
$PurgeJsDelivrUrl = "https://purge.jsdelivr.net/gh/$RepoOwner/$RepoName@$Branch"

# Files to purge
$CriticalFiles = @(
  'checksums.sha256'
)

$AllFiles = @(
  'checksums.sha256',
  'install.ps1',
  'install.sh',
  'uninstall.ps1',
  'uninstall.sh',
  'bin/check-ai-cli',
  'bin/check-ai-cli.cmd',
  'bin/check-ai-cli.ps1',
  'scripts/Check-AI-CLI-Versions.ps1',
  'scripts/check-ai-cli-versions.sh'
)

function Get-LocalFileHash([string]$RelativePath) {
  $localPath = Join-Path $PSScriptRoot "..\$RelativePath"
  if (-not (Test-Path -LiteralPath $localPath)) { return $null }
  return (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RemoteFileHash([string]$Url) {
  try {
    $headers = @{
      'Cache-Control' = 'no-cache, no-store, must-revalidate'
      'Pragma' = 'no-cache'
      'User-Agent' = 'check-ai-cli-cache-purger'
    }
    $content = (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 15).Content
    if ($content -is [byte[]]) {
      $stream = [System.IO.MemoryStream]::new($content)
    } else {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
      $stream = [System.IO.MemoryStream]::new($bytes)
    }
    $hash = Get-FileHash -InputStream $stream -Algorithm SHA256
    $stream.Dispose()
    return $hash.Hash.ToLowerInvariant()
  } catch {
    return $null
  }
}

function Invoke-PurgeGitHubRaw([string]$RelativePath) {
  $url = "$BaseUrl/$RelativePath"
  Write-Info "Purging: $RelativePath"
  
  # Method 1: Request with cache-busting headers
  try {
    $headers = @{
      'Cache-Control' = 'no-cache, no-store, must-revalidate, max-age=0'
      'Pragma' = 'no-cache'
      'Expires' = '0'
      'User-Agent' = 'check-ai-cli-cache-purger/' + [guid]::NewGuid().ToString('N')
    }
    $null = Invoke-WebRequest -Uri "$url`?t=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
  } catch { }
  
  # Method 2: Request with random query string (cache bust)
  try {
    $rand = [guid]::NewGuid().ToString('N')
    $null = Invoke-WebRequest -Uri "$url`?purge=$rand" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
  } catch { }
}

function Invoke-PurgeJsDelivr([string]$RelativePath) {
  $purgeUrl = "$PurgeJsDelivrUrl/$RelativePath"
  try {
    $null = Invoke-WebRequest -Uri $purgeUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
    Write-Success "  jsDelivr purged: $RelativePath"
  } catch {
    Write-Warn "  jsDelivr purge failed: $RelativePath"
  }
}

function Test-CacheSync([string]$RelativePath) {
  $localHash = Get-LocalFileHash $RelativePath
  if (-not $localHash) {
    Write-Warn "Local file not found: $RelativePath"
    return $false
  }
  
  $remoteUrl = "$BaseUrl/$RelativePath"
  $remoteHash = Get-RemoteFileHash $remoteUrl
  
  if (-not $remoteHash) {
    Write-Warn "Remote file not accessible: $RelativePath"
    return $false
  }
  
  if ($localHash -eq $remoteHash) {
    Write-Success "Synced: $RelativePath"
    return $true
  } else {
    Write-Warn "Not synced: $RelativePath"
    Write-Warn "  Local:  $localHash"
    Write-Warn "  Remote: $remoteHash"
    return $false
  }
}

function Wait-ForCacheSync([string[]]$Files, [int]$MaxWaitSeconds = 300) {
  Write-Info "Waiting for CDN cache to sync (max $MaxWaitSeconds seconds)..."
  $startTime = Get-Date
  $checkInterval = 10
  
  while ($true) {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $MaxWaitSeconds) {
      Write-Fail "Timeout waiting for cache sync"
      return $false
    }
    
    $allSynced = $true
    foreach ($file in $Files) {
      if (-not (Test-CacheSync $file)) {
        $allSynced = $false
      }
    }
    
    if ($allSynced) {
      Write-Success "All files synced!"
      return $true
    }
    
    $remaining = [math]::Ceiling($MaxWaitSeconds - $elapsed)
    Write-Info "Waiting $checkInterval seconds... ($remaining seconds remaining)"
    Start-Sleep -Seconds $checkInterval
  }
}

# Main
Write-Host ""
Write-Host "=========================================="
Write-Host " GitHub CDN Cache Purge Tool"
Write-Host "=========================================="
Write-Host ""

$filesToPurge = if ($All) { $AllFiles } else { $CriticalFiles }

if ($Verify) {
  Write-Info "Verifying cache sync status..."
  $allOk = $true
  foreach ($file in $filesToPurge) {
    if (-not (Test-CacheSync $file)) { $allOk = $false }
  }
  if ($allOk) {
    Write-Success "All files are in sync!"
    exit 0
  } else {
    Write-Fail "Some files are not in sync"
    exit 1
  }
}

Write-Info "Purging $($filesToPurge.Count) file(s)..."

foreach ($file in $filesToPurge) {
  Invoke-PurgeGitHubRaw $file
  Invoke-PurgeJsDelivr $file
}

Write-Host ""
Write-Info "Verifying cache status..."
foreach ($file in $filesToPurge) {
  Test-CacheSync $file | Out-Null
}

if ($Wait) {
  Write-Host ""
  Wait-ForCacheSync $filesToPurge
}

Write-Host ""
Write-Info "Tips:"
Write-Host "  - GitHub CDN cache typically expires in ~5 minutes"
Write-Host "  - Use -Wait to wait until cache is synced"
Write-Host "  - Use -Verify to only check sync status"
Write-Host "  - Use -All to purge all files (not just checksums)"
Write-Host ""
