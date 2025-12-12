$ErrorActionPreference = 'Stop'

# 中文注释: 卸载脚本, 默认卸载 Program Files 安装目录, 并从 PATH 移除 bin 目录
# 中文注释: 环境变量:
# 中文注释: - CHECK_AI_CLI_INSTALL_DIR: 安装目录(默认 Program Files)
# 中文注释: - CHECK_AI_CLI_PATH_SCOPE: CurrentUser 或 Machine(默认 Machine)

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

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

function Test-IsAdmin() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin([string]$Reason) {
  if (Test-IsAdmin) { return }
  throw "Administrator required: $Reason"
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\')
}

function Remove-PathEntry([string]$PathValue, [string]$Dir) {
  $needle = (Normalize-Dir $Dir).ToLowerInvariant()
  $items = @()
  foreach ($p in @($PathValue -split ';')) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try {
      if ((Normalize-Dir $p).ToLowerInvariant() -ne $needle) { $items += $p }
    } catch { $items += $p }
  }
  return ($items -join ';')
}

function Update-Path([string]$Scope, [string]$BinDir) {
  $target = [EnvironmentVariableTarget]::$Scope
  $current = [Environment]::GetEnvironmentVariable('Path', $target)
  $next = Remove-PathEntry $current $BinDir
  [Environment]::SetEnvironmentVariable('Path', $next, $target)
  $env:Path = $next
}

function Confirm-Delete([string]$Dir) {
  Write-Warn "This will remove directory: $Dir"
  $ans = Read-Host "Type DELETE to confirm"
  return $ans -eq 'DELETE'
}

try {
  $installDir = Get-InstallDir
  $scope = Get-PathScope
  $binDir = Join-Path $installDir 'bin'

  if ($scope -eq 'Machine') { Require-Admin "updating Machine PATH" }
  if ($installDir.StartsWith([Environment]::GetFolderPath('ProgramFiles'), [StringComparison]::OrdinalIgnoreCase)) {
    Require-Admin "removing Program Files directory"
  }

  if (-not (Confirm-Delete $installDir)) { Write-Warn "Canceled."; exit 0 }

  Update-Path $scope $binDir
  if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
  Write-Success "Uninstalled: $installDir"
} catch {
  Write-Fail $_.Exception.Message
  exit 1
}

