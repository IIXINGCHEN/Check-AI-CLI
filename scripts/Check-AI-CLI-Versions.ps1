param(
  [switch]$Auto
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
function Get-QuietProgressMode() {
  $v = $env:CHECK_AI_CLI_QUIET_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Invoke-WithTempProgressPreference([string]$Mode, [scriptblock]$Action) {
  $prev = $ProgressPreference
  $ProgressPreference = $Mode
  try { & $Action } finally { $ProgressPreference = $prev }
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

# Standard yes/no confirmation prompt
function Confirm-Yes([string]$Prompt) {
  if ($script:AutoMode) { return $true }
  $ans = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans.Trim().ToUpperInvariant().StartsWith('Y')
}

# Install/update Factory CLI
function Update-Factory() {
  Write-Info "Updating Factory CLI (Droid)..."
  $script = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $script) { throw "Failed to download installer script." }
  $mode = 'Continue'
  if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
  Invoke-WithTempProgressPreference $mode { Invoke-Expression $script }
}

# Install/update Claude Code (npm only)
function Update-Claude() {
  Write-Info "Updating Claude Code..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { throw "npm not found. Claude Code requires Node.js. Install from https://nodejs.org/" }
  & npm install -g '@anthropic-ai/claude-code@latest'
}

# Install/update OpenAI Codex (Windows defaults to npm)
function Update-Codex() {
  Write-Info "Updating OpenAI Codex..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { throw "npm not found. Install Node.js first." }
  & npm install -g '@openai/codex'
}

# Install/update Gemini CLI (prefers npm)
function Update-Gemini() {
  Write-Info "Updating Gemini CLI..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { throw "npm not found. Install Node.js first." }
  & npm install -g '@google/gemini-cli@latest'
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
    if (Confirm-Yes "Install now? (Y/N)") { Try-Update $DoUpdate ; return $true }
    return $false
  }
  if (-not $Latest) { Write-Warn "Latest version unknown. Skipping update check." ; return $false }
  $cmp = Compare-Version $Local $Latest
  if ($cmp -eq 0) { Write-Success "Already up to date." ; return $false }
  if ($cmp -eq 1) { Write-Warn "Local version is newer than latest source." ; return $false }
  if ($cmp -eq -1 -and (Confirm-Yes "Update now? (Y/N)")) { Try-Update $DoUpdate ; return $true }
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
  Write-Host " Factory CLI (Droid) | Claude Code | OpenAI Codex | Gemini CLI"
  Write-Host "==============================================="
  Write-Host ""
}

function Ask-Selection() {
  Write-Host "Select tools to check:"
  Write-Host "  [1] Factory CLI (Droid)"
  Write-Host "  [2] Claude Code"
  Write-Host "  [3] OpenAI Codex"
  Write-Host "  [4] Gemini CLI"
  Write-Host "  [A] Check all (default)"
  $s = Read-Host "Enter choice (1/2/3/4/A)"
  if ([string]::IsNullOrWhiteSpace($s)) { return 'A' }
  return $s.Trim().ToUpperInvariant()
}

Show-Banner
$sel = Ask-Selection

if ($sel -eq '1' -or $sel -eq 'A') {
  Check-OneTool "Factory CLI (Droid)" { Get-LatestFactoryVersion } { Get-LocalCommandVersion @('factory','droid') } { Update-Factory }
}
if ($sel -eq '2' -or $sel -eq 'A') {
  Check-OneTool "Claude Code" { Get-LatestClaudeVersion } { Get-LocalCommandVersion @('claude','claude-code') } { Update-Claude }
}
if ($sel -eq '3' -or $sel -eq 'A') {
  Check-OneTool "OpenAI Codex" { Get-LatestCodexVersion } { Get-LocalCommandVersion @('codex') } { Update-Codex }
}
if ($sel -eq '4' -or $sel -eq 'A') {
  Check-OneTool "Gemini CLI" { Get-LatestGeminiVersion } { Get-LocalCommandVersion @('gemini') } { Update-Gemini }
}
