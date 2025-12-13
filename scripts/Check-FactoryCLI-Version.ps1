$ErrorActionPreference = 'Stop'

# Factory-only version check script
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Get-Text([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    $content = (Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing).Content
    if ($content -is [string]) { return $content }
    if ($content -is [string[]]) { return ($content -join "`n") }
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return ($content | Out-String)
  } catch { return $null }
}

function Get-SemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
}

function Get-LatestFactoryVersion() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) { return $null }
  $m = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
  if (-not $m.Success) { return $null }
  return Get-SemVer $m.Groups[1].Value
}

function Get-LocalFactoryVersion() {
  foreach ($name in @('factory','droid')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try {
      $out = & $name '--version' 2>$null | Out-String
      $v = Get-SemVer $out
      if ($v) { return $v }
    } catch { }
  }
  return $null
}

Write-Host ""
Write-Host "Factory CLI (Droid)"
Write-Host "==================="

Write-Info "Fetching latest version..."
$latest = Get-LatestFactoryVersion
if ($latest) { Write-Success "Latest version: v$latest" } else { Write-Warn "Latest version: unknown" }

$local = Get-LocalFactoryVersion
if ($local) { Write-Success "Local version: v$local" } else { Write-Warn "Local version: not installed" }
