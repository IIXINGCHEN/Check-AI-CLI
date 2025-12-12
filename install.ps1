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

function Get-AllowUntrustedMirrorFlag() {
  $v = $env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-RequestedRef() {
  $v = $env:CHECK_AI_CLI_REF
  if ([string]::IsNullOrWhiteSpace($v)) { return 'main' }
  return $v.Trim()
}

function Get-GitHubRawBase([string]$Ref) {
  return "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$Ref"
}

function Test-IsTrustedBase([string]$Base) {
  $b = $Base.TrimEnd('/')
  if ($b.StartsWith('https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  if ($b.StartsWith('https://github.com/IIXINGCHEN/Check-AI-CLI/raw/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $false
}

function Require-TrustedBase([string]$Base) {
  if (Test-IsTrustedBase $Base) { return }
  if (Get-AllowUntrustedMirrorFlag) { return }
  throw "Untrusted mirror base. Set CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 to allow: $Base"
}

function Get-BaseUrl() {
  $envBase = $env:CHECK_AI_CLI_RAW_BASE
  if (-not [string]::IsNullOrWhiteSpace($envBase)) {
    $base = $envBase.TrimEnd('/')
    Require-TrustedBase $base
    return $base
  }
  return (Get-GitHubRawBase (Get-RequestedRef))
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

function Get-RetryCount() {
  $v = $env:CHECK_AI_CLI_RETRY
  if ([string]::IsNullOrWhiteSpace($v)) { return 3 }
  $n = 0
  if (-not [int]::TryParse($v.Trim(), [ref]$n)) { return 3 }
  if ($n -lt 1) { return 1 }
  if ($n -gt 10) { return 10 }
  return $n
}

function Get-TempFilePath([string]$OutFile) {
  return "$OutFile.download"
}

function Test-NonEmptyFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $len = (Get-Item -LiteralPath $Path).Length
  return $len -gt 0
}

function Download-ToFile([string]$Url, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -OutFile $OutFile | Out-Null
}

function Download-FileWithRetry([string]$Url, [string]$OutFile) {
  $tries = Get-RetryCount
  $tmp = Get-TempFilePath $OutFile
  for ($i = 1; $i -le $tries; $i++) {
    try {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      Download-ToFile $Url $tmp
      if (-not (Test-NonEmptyFile $tmp)) { throw "Downloaded file is empty." }
      Move-Item -LiteralPath $tmp -Destination $OutFile -Force
      return
    } catch {
      if ($i -eq $tries) { throw }
      Start-Sleep -Seconds 2
    }
  }
}

function Get-FilesToInstall() {
  return @(
    @{ Remote = 'scripts/Check-AI-CLI-Versions.ps1'; Local = 'scripts\Check-AI-CLI-Versions.ps1' },
    @{ Remote = 'scripts/Check-FactoryCLI-Version.ps1'; Local = 'scripts\Check-FactoryCLI-Version.ps1' },
    @{ Remote = 'scripts/check-ai-cli-versions.sh'; Local = 'scripts\check-ai-cli-versions.sh' },
    @{ Remote = 'bin/check-ai-cli.ps1'; Local = 'bin\check-ai-cli.ps1' },
    @{ Remote = 'bin/check-ai-cli.cmd'; Local = 'bin\check-ai-cli.cmd' }
  )
}

function Ensure-ParentDirectory([string]$Path) {
  $parent = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($parent)) { return }
  Ensure-Directory $parent
}

function Install-OneFile([string]$Base, [string]$InstallDir, [hashtable]$Entry) {
  $url = "$Base/$($Entry.Remote)"
  $out = Join-Path $InstallDir $Entry.Local
  Ensure-ParentDirectory $out
  Write-Info "Downloading: $($Entry.Remote)"
  Download-FileWithRetry $url $out
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\')
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

function Add-ToPath([string]$Dir, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  $current = [Environment]::GetEnvironmentVariable('Path', $target)
  if (Path-ContainsDir $current $Dir) { return }
  $normalized = Normalize-Dir $Dir
  $newPath = "$current;$normalized"
  [Environment]::SetEnvironmentVariable('Path', $newPath, $target)
  $env:Path = $newPath
}

function Print-NextSteps([string]$Dir) {
  Write-Host ""
  Write-Host "Next:"
  Write-Host "  check-ai-cli"
  Write-Host "  cd `"$Dir`""
  Write-Host "  .\\bin\\check-ai-cli.cmd"
  Write-Host "  .\\scripts\\Check-AI-CLI-Versions.ps1"
  Write-Host ""
}

function Print-ChinaTip() {
  Write-Host "Tip:"
  Write-Host "  Prefer HTTP_PROXY/HTTPS_PROXY for speed in mainland China."
  Write-Host "  Set `$env:CHECK_AI_CLI_REF to pin a tag/commit for stability."
  Write-Host "  Set `$env:CHECK_AI_CLI_RAW_BASE only if you trust the mirror."
  Write-Host "  Set `$env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR = '1' to bypass mirror check."
  Write-Host "  Set `$ProgressPreference = 'SilentlyContinue' to speed up downloads."
  Write-Host ""
}

function Install-All([string]$Dir, [string]$Scope, [bool]$Run) {
  $base = Get-BaseUrl
  $files = Get-FilesToInstall
  foreach ($f in $files) { Install-OneFile $base $Dir $f }
  $binDir = Join-Path $Dir 'bin'
  Add-ToPath $binDir $Scope
  Write-Success "Installed to: $Dir"
  Print-NextSteps $Dir
  Print-ChinaTip
  if ($Run) { & (Join-Path $Dir 'bin\check-ai-cli.ps1') }
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
