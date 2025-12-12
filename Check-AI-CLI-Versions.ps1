$ErrorActionPreference = 'Stop'

# 中文注释: 统一输出格式, 便于扫读
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

# 中文注释: 获取文本内容, 失败时返回 $null
function Get-Text([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    return (Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing).Content
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
  }
}

# 中文注释: 获取 JSON, 失败时返回 $null
function Get-Json([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
  }
}

# 中文注释: 从字符串中提取 x.y.z 版本号
function Get-SemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
}

# 中文注释: 将版本号拆分为 3 段整数, 用于比较
function Get-VersionParts([string]$Version) {
  $v = Get-SemVer $Version
  if (-not $v) { return $null }
  $p = $v.Split('.')
  return @([int]$p[0], [int]$p[1], [int]$p[2])
}

# 中文注释: 比较版本号, 返回 -1/0/1, 无法比较返回 $null
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

# 中文注释: 获取本地命令版本, 不存在或失败返回 $null
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

# 中文注释: 从 Factory Windows 安装脚本中提取最新版本
function Get-LatestFactoryVersion() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) { return $null }
  $m = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
  if (-not $m.Success) { return $null }
  return Get-SemVer $m.Groups[1].Value
}

# 中文注释: 从 npm registry 获取 Claude Code 最新版本(备用方案)
function Get-LatestClaudeVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

# 中文注释: 从 GitHub Releases API 获取 Codex 最新版本
function Get-LatestCodexVersion() {
  $json = Get-Json 'https://api.github.com/repos/openai/codex/releases/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.tag_name)
}

# 中文注释: 从 npm registry 获取 Gemini CLI 最新版本
function Get-LatestGeminiVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@google/gemini-cli/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

# 中文注释: 统一的升级确认交互
function Confirm-Yes([string]$Prompt) {
  $ans = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans.Trim().ToUpperInvariant().StartsWith('Y')
}

# 中文注释: Factory CLI 安装/更新
function Update-Factory() {
  Write-Info "Updating Factory CLI (Droid)..."
  $script = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $script) { throw "Failed to download installer script." }
  Invoke-Expression $script
}

# 中文注释: Claude Code 安装/更新
function Update-Claude() {
  Write-Info "Updating Claude Code..."
  $script = Get-Text 'https://claude.ai/install.ps1'
  if (-not $script) { throw "Failed to download installer script." }
  Invoke-Expression $script
}

# 中文注释: OpenAI Codex 安装/更新(Windows 默认 npm)
function Update-Codex() {
  Write-Info "Updating OpenAI Codex..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { throw "npm not found. Install Node.js first." }
  & npm install -g '@openai/codex'
}

# 中文注释: Gemini CLI 安装/更新(优先 npm)
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
  if (-not $Latest) { return }
  if (-not $Local) { if (Confirm-Yes "Install now? (Y/N)") { Try-Update $DoUpdate }; return }
  $cmp = Compare-Version $Local $Latest
  if ($cmp -eq 0) { Write-Success "Already up to date." ; return }
  if ($cmp -eq 1) { Write-Warn "Local version is newer than latest source." ; return }
  if ($cmp -eq -1 -and (Confirm-Yes "Update now? (Y/N)")) { Try-Update $DoUpdate }
}

function Check-OneTool([string]$Title, [scriptblock]$GetLatest, [scriptblock]$GetLocal, [scriptblock]$DoUpdate) {
  Write-ToolHeader $Title
  $latest = Get-AndPrintLatest $GetLatest
  $local = Get-AndPrintLocal $GetLocal
  Handle-UpdateFlow $latest $local $DoUpdate
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
