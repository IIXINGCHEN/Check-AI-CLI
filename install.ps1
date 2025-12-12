$ErrorActionPreference = 'Stop'

# 中文注释: 这个脚本用于支持 `irm ... | iex` 一行命令安装/更新本仓库脚本文件
# 中文注释: 通过环境变量 CHECK_AI_CLI_RAW_BASE 可以指定加速镜像/代理前缀, 例如:
# 中文注释: $env:CHECK_AI_CLI_RAW_BASE = 'https://ghproxy.com/https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main'

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Get-BaseUrl() {
  $envBase = $env:CHECK_AI_CLI_RAW_BASE
  if (-not [string]::IsNullOrWhiteSpace($envBase)) { return $envBase.TrimEnd('/') }
  return 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main'
}

function Download-File([string]$Url, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -OutFile $OutFile | Out-Null
}

function Ensure-Directory([string]$Path) {
  if (Test-Path -LiteralPath $Path) { return }
  New-Item -ItemType Directory -Path $Path | Out-Null
}

function Install-Scripts([string]$InstallDir, [switch]$Run) {
  $base = Get-BaseUrl
  $prevProgress = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'

  try {
    Ensure-Directory $InstallDir

    $files = @(
      'Check-AI-CLI-Versions.ps1',
      'Check-FactoryCLI-Version.ps1',
      'check-ai-cli-versions.sh'
    )

    foreach ($file in $files) {
      $url = "$base/$file"
      $out = Join-Path $InstallDir $file
      Write-Info "Downloading: $file"
      Download-File $url $out
    }

    Write-Success "Installed to: $InstallDir"
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  cd `"$InstallDir`""
    Write-Host "  .\\Check-AI-CLI-Versions.ps1"
    Write-Host ""
    Write-Host "Tip:"
    Write-Host "  Set `$env:CHECK_AI_CLI_RAW_BASE to use a mirror in mainland China."
    Write-Host ""

    if ($Run) {
      $mainScript = Join-Path $InstallDir 'Check-AI-CLI-Versions.ps1'
      & $mainScript
    }
  } finally {
    $ProgressPreference = $prevProgress
  }
}

try {
  $targetDir = (Get-Location).Path
  Install-Scripts -InstallDir $targetDir
} catch {
  Write-Fail $_.Exception.Message
  Write-Host ""
  Write-Host "If you are in mainland China, try setting a mirror base first, then rerun:"
  Write-Host "  `$env:CHECK_AI_CLI_RAW_BASE = 'YOUR_MIRROR_BASE'"
  Write-Host "  irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex"
  exit 1
}

