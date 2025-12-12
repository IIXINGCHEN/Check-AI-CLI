$ErrorActionPreference = 'Stop'

# 中文注释: 这个脚本用于支持 `irm ... | iex` 一行命令安装/更新本仓库脚本文件
# 中文注释: 可用环境变量控制:
# 中文注释: - CHECK_AI_CLI_RAW_BASE: raw 文件基础地址(用于镜像加速)
# 中文注释: - CHECK_AI_CLI_INSTALL_DIR: 安装目录(默认 Program Files)
# 中文注释: - CHECK_AI_CLI_PATH_SCOPE: CurrentUser 或 Machine(默认 Machine)
# 中文注释: - CHECK_AI_CLI_RUN: 1 表示安装后立即运行

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Get-BaseUrl() {
  $envBase = $env:CHECK_AI_CLI_RAW_BASE
  if (-not [string]::IsNullOrWhiteSpace($envBase)) { return $envBase.TrimEnd('/') }
  return 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main'
}

function Get-InstallDir() {
  $envDir = $env:CHECK_AI_CLI_INSTALL_DIR
  if (-not [string]::IsNullOrWhiteSpace($envDir)) { return $envDir }
  return 'C:\Program Files\Tools\Check-AI-CLI'
}

function Get-PathScope() {
  $s = $env:CHECK_AI_CLI_PATH_SCOPE
  if ([string]::IsNullOrWhiteSpace($s)) { return 'Machine' }
  $t = $s.Trim()
  if ($t -ne 'Machine' -and $t -ne 'CurrentUser') { return 'Machine' }
  return $t
}

function Get-RunFlag() {
  $v = $env:CHECK_AI_CLI_RUN
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Test-IsAdmin() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsUnderProgramFiles([string]$Path) {
  $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
  return $Path.TrimEnd('\').StartsWith($pf, [StringComparison]::OrdinalIgnoreCase)
}

function Require-Admin([string]$Reason) {
  if (Test-IsAdmin) { return }
  throw "Administrator required: $Reason"
}

function Ensure-Directory([string]$Path) {
  if (Test-Path -LiteralPath $Path) { return }
  New-Item -ItemType Directory -Path $Path | Out-Null
}

function Download-File([string]$Url, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -OutFile $OutFile | Out-Null
}

function Get-FilesToInstall() {
  return @(
    'Check-AI-CLI-Versions.ps1',
    'Check-FactoryCLI-Version.ps1',
    'check-ai-cli.ps1',
    'check-ai-cli.cmd',
    'check-ai-cli-versions.sh'
  )
}

function Install-OneFile([string]$Base, [string]$Dir, [string]$File) {
  $url = "$Base/$File"
  $out = Join-Path $Dir $File
  Write-Info "Downloading: $File"
  Download-File $url $out
}

function Add-ToPath([string]$Dir, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  $current = [Environment]::GetEnvironmentVariable('Path', $target)
  $items = @($current -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  if ($items -contains $Dir) { return }
  $newPath = ($items + $Dir) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $newPath, $target)
  $env:Path = $newPath
}

function Print-NextSteps([string]$Dir) {
  Write-Host ""
  Write-Host "Next:"
  Write-Host "  check-ai-cli"
  Write-Host "  check-ai-cli.ps1"
  Write-Host "  cd `"$Dir`""
  Write-Host "  .\\Check-AI-CLI-Versions.ps1"
  Write-Host ""
}

function Print-ChinaTip() {
  Write-Host "Tip:"
  Write-Host "  Set `$env:CHECK_AI_CLI_RAW_BASE to use a mirror base."
  Write-Host "  Set `$ProgressPreference = 'SilentlyContinue' to speed up downloads."
  Write-Host ""
}

function Install-All([string]$Dir, [string]$Scope, [bool]$Run) {
  $base = Get-BaseUrl
  $files = Get-FilesToInstall
  foreach ($f in $files) { Install-OneFile $base $Dir $f }
  Add-ToPath $Dir $Scope
  Write-Success "Installed to: $Dir"
  Print-NextSteps $Dir
  Print-ChinaTip
  if ($Run) { & (Join-Path $Dir 'check-ai-cli.ps1') }
}

function Set-QuietProgress([string]$Mode) {
  $script:PrevProgressPreference = $ProgressPreference
  $ProgressPreference = $Mode
}

function Restore-Progress() {
  if ($script:PrevProgressPreference) { $ProgressPreference = $script:PrevProgressPreference }
}

function Print-AdminHint() {
  Write-Host ""
  Write-Host "Run PowerShell as Administrator, then rerun:"
  Write-Host "  irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex"
  Write-Host ""
}

try {
  $installDir = Get-InstallDir
  $pathScope = Get-PathScope
  $runAfter = Get-RunFlag

  if (Test-IsUnderProgramFiles $installDir) { Require-Admin "writing to Program Files: $installDir" }
  if ($pathScope -eq 'Machine') { Require-Admin "updating Machine PATH" }

  Set-QuietProgress 'SilentlyContinue'
  Ensure-Directory $installDir
  Install-All $installDir $pathScope $runAfter
} catch {
  Write-Fail $_.Exception.Message
  Print-AdminHint
  Print-ChinaTip
  exit 1
} finally {
  Restore-Progress
}
