param(
  # Uninstall the machine-wide Program Files copy and clean Machine PATH.
  # Leaves a CurrentUser install untouched.
  [switch]$ProgramFiles,

  # Optional explicit install directory override (wins over -ProgramFiles).
  [string]$InstallDir = '',

  # Optional PATH scope override: CurrentUser or Machine.
  [ValidateSet('', 'CurrentUser', 'Machine')]
  [string]$PathScope = ''
)

$ErrorActionPreference = 'Stop'

# Uninstall script: removes a marked Check-AI-CLI install dir and its bin PATH entry.
# Defaults:
# - Admin: Program Files + Machine PATH
# - Non-admin: CurrentUser install + CurrentUser PATH
# Env vars (also accepted for compatibility):
# - CHECK_AI_CLI_INSTALL_DIR
# - CHECK_AI_CLI_PATH_SCOPE: CurrentUser or Machine
# - CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES=1  (same as -ProgramFiles)

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Test-IsAdmin() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin([string]$Reason) {
  if (Test-IsAdmin) { return }
  throw "Administrator required: $Reason"
}

function Get-ProgramFilesInstallDir() {
  return (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI')
}

function Get-CurrentUserInstallDir() {
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Tools\Check-AI-CLI')
  }
  return (Join-Path $localAppData 'Programs\Tools\Check-AI-CLI')
}

function Test-UninstallProgramFilesRequested() {
  if ($ProgramFiles) { return $true }
  $v = $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-InstallDir() {
  if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { return $InstallDir }
  $envDir = $env:CHECK_AI_CLI_INSTALL_DIR
  if (-not [string]::IsNullOrWhiteSpace($envDir)) { return $envDir }
  if (Test-UninstallProgramFilesRequested) { return (Get-ProgramFilesInstallDir) }

  # Safe default matches install.ps1: CurrentUser unless -ProgramFiles / env explicitly
  # requests the machine-wide copy. Ambient admin must not silently retarget PF.
  return (Get-CurrentUserInstallDir)
}

function Get-PathScope() {
  if (-not [string]::IsNullOrWhiteSpace($PathScope)) { return $PathScope }
  $s = $env:CHECK_AI_CLI_PATH_SCOPE
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    $t = $s.Trim()
    if ($t -ne 'Machine' -and $t -ne 'CurrentUser') {
      throw 'CHECK_AI_CLI_PATH_SCOPE must be Machine or CurrentUser.'
    }
    return $t
  }

  # Program Files uninstall always cleans Machine PATH for that bin entry.
  if (Test-UninstallProgramFilesRequested) { return 'Machine' }

  $targetDir = Get-InstallDir
  if (Test-IsUnderProgramFiles $targetDir) { return 'Machine' }
  return 'CurrentUser'
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\')
}

function Test-IsUnderProgramFiles([string]$Path) {
  $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($pf) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
  $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  return $candidate.Equals($pf, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-EnvRegistryPath([string]$Scope) {
  if ($Scope -eq 'Machine') { return 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
  return 'HKCU:\Environment'
}

function Get-EnvValue([string]$Name, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  try { return [Environment]::GetEnvironmentVariable($Name, $target) } catch {
    $path = Get-EnvRegistryPath $Scope
    $item = Get-ItemProperty -Path $path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return '' }
    return $item.$Name
  }
}

function Set-EnvValue([string]$Name, [string]$Value, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  try { [Environment]::SetEnvironmentVariable($Name, $Value, $target); return } catch {
    $path = Get-EnvRegistryPath $Scope
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $Name -Value $Value
  }
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
  $current = Get-EnvValue 'Path' $Scope
  $next = Remove-PathEntry $current $BinDir
  if ($next -eq $current) {
    Write-Info "No $Scope PATH entry found for uninstall target."
    return
  }
  Set-EnvValue 'Path' $next $Scope
  # Refresh process PATH carefully: only drop the removed bin, keep the rest of this session.
  $env:Path = Remove-PathEntry $env:Path $BinDir
  Write-Info "Removed install bin from $Scope PATH."
}

function Confirm-Delete([string]$Dir) {
  Write-Warn "This will permanently remove directory: $Dir"
  Write-Warn 'This operation is irreversible.'
  if (Test-IsUnderProgramFiles $Dir) {
    Write-Info 'Target: machine-wide Program Files install'
    Write-Info 'A CurrentUser install (if present) will be left untouched.'
  }
  $ans = Read-Host "Type DELETE to confirm"
  return $ans.Trim() -eq 'DELETE'
}

function Require-InstallMarker([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
  $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root) {
    throw "Refusing to remove a filesystem root: $Dir"
  }

  # Do NOT assign to $home / $HOME — $HOME is a read-only automatic variable in PowerShell.
  $userProfile = $null
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $userProfile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
  }
  if ($userProfile -and $full.Equals($userProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove the user profile directory: $Dir"
  }

  if (-not (Test-Path -LiteralPath $Dir)) {
    throw "Install directory not found: $Dir"
  }

  $item = Get-Item -LiteralPath $Dir -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse-point directory: $Dir"
  }
  $marker = Join-Path $Dir '.check-ai-cli-installed'
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Refusing to remove an unmarked directory: $Dir"
  }
  if ([IO.File]::ReadAllText($marker).Trim() -ne 'Check-AI-CLI') {
    throw "Invalid Check-AI-CLI installation marker: $Dir"
  }
}

function Invoke-Uninstall() {
  $targetDir = Get-InstallDir
  $scope = Get-PathScope
  $binDir = Join-Path $targetDir 'bin'

  Write-Info "Uninstall target: $targetDir"
  Write-Info "PATH scope: $scope"

  if ($scope -eq 'Machine') { Require-Admin 'updating Machine PATH' }
  if (Test-IsUnderProgramFiles $targetDir) {
    Require-Admin 'removing Program Files directory'
  }

  Require-InstallMarker $targetDir
  if (-not (Confirm-Delete $targetDir)) { Write-Warn 'Canceled.'; return }

  Update-Path $scope $binDir
  if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
  }
  Write-Success "Uninstalled: $targetDir"

  $userDir = Get-CurrentUserInstallDir
  if ((Normalize-Dir $targetDir).ToLowerInvariant() -ne (Normalize-Dir $userDir).ToLowerInvariant()) {
    if (Test-Path -LiteralPath (Join-Path $userDir 'bin\check-ai-cli.cmd')) {
      Write-Info "CurrentUser install still present: $userDir"
      Write-Info "Run: $(Join-Path $userDir 'bin\check-ai-cli.cmd')"
    }
  }
}

if ($env:CHECK_AI_CLI_SKIP_MAIN -eq '1') { return }

try {
  Invoke-Uninstall
} catch {
  Write-Fail $_.Exception.Message
  if ($_.Exception.Message -like 'Administrator required:*') {
    Write-Host ''
    Write-Host 'To uninstall the old Program Files install, open an elevated PowerShell and run:' -ForegroundColor Yellow
    Write-Host '  cd <repo-or-install-root>' -ForegroundColor Yellow
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -ProgramFiles' -ForegroundColor Yellow
  }
  exit 1
}
