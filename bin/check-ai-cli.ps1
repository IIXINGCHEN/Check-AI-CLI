$ErrorActionPreference = 'Stop'

# Sanitize Windows PowerShell 5.1 module path before any cmdlet call that
# would trigger module auto-load. When check-ai-cli.cmd is launched from a
# pwsh prompt, the child powershell.exe inherits pwsh's PSModulePath (which
# includes PS 7 module directories). PS 5.1 then ghost-loads the PS 7
# version of Microsoft.PowerShell.Utility at process startup; the ghost has
# zero exported cmdlets, so Get-FileHash and friends are unavailable to the
# official installer scripts we invoke in-process (e.g., claude.ai/install.ps1).
# Pure .NET calls only here — Split-Path / Test-Path / Join-Path come later.
# Skipped entirely under PS 7+ ($PSVersionTable is an automatic variable).
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $psmpToolPath = "$PSScriptRoot\..\tools\PSModulePath.ps1"
  if ([IO.File]::Exists($psmpToolPath)) {
    . $psmpToolPath
    $psmpCleaned = Get-CleanedPS51ModulePath $env:PSModulePath
    if ($psmpCleaned -and ($psmpCleaned -ne $env:PSModulePath)) {
      $env:PSModulePath = $psmpCleaned
      Remove-Module Microsoft.PowerShell.Utility -Force -ErrorAction SilentlyContinue
      Import-Module Microsoft.PowerShell.Utility -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-CurrentUserInstallRoot() {
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Tools\Check-AI-CLI')
  }
  return (Join-Path $localAppData 'Programs\Tools\Check-AI-CLI')
}

function Test-IsUnderProgramFiles([string]$Path) {
  $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($pf) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
  $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  return $candidate.Equals($pf, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-EntrypointLastWriteTimeUtc([string]$Path) {
  try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc } catch { return $null }
}

function Should-ForwardToCurrentUserInstall([string]$CurrentEntrypoint, [string]$UserEntrypoint) {
  if (-not (Test-Path -LiteralPath $UserEntrypoint)) { return $false }
  $currentTime = Get-EntrypointLastWriteTimeUtc $CurrentEntrypoint
  $userTime = Get-EntrypointLastWriteTimeUtc $UserEntrypoint
  if ($null -eq $userTime) { return $false }
  if ($null -eq $currentTime) { return $true }
  return $userTime -ge $currentTime
}

# Entrypoint for PATH usage
$binDir = $PSScriptRoot
if (-not $binDir) {
  $invPath = $MyInvocation.MyCommand.Path
  if ($invPath) { $binDir = Split-Path -Parent $invPath }
}
if (-not $binDir) {
  $invPath2 = $MyInvocation.MyCommand.Path
  throw "Failed to determine bin directory. PSScriptRoot='$PSScriptRoot', MyInvocation.MyCommand.Path='$invPath2'."
}
$installRoot = Split-Path -Parent $binDir
if ($env:CHECK_AI_CLI_TEST_INSTALL_ROOT) {
  $installRoot = $env:CHECK_AI_CLI_TEST_INSTALL_ROOT
  $binDir = Join-Path $installRoot 'bin'
}

$mainScript = Join-Path $installRoot 'scripts\Check-AI-CLI-Versions.ps1'

if (Test-IsUnderProgramFiles $installRoot) {
  $userInstallRoot = Get-CurrentUserInstallRoot
  $userEntrypoint = Join-Path $userInstallRoot 'bin\check-ai-cli.ps1'
  $currentEntrypoint = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { (Join-Path $binDir 'check-ai-cli.ps1') }
  if (($userEntrypoint -ne $currentEntrypoint) -and (Should-ForwardToCurrentUserInstall $currentEntrypoint $userEntrypoint)) {
    if ($env:CHECK_AI_CLI_TEST_MODE -eq '1') {
      $script:ShadowRecoveryAction = 'forward'
      $script:ShadowRecoveryTarget = $userEntrypoint
      return
    }
    & $userEntrypoint @args
    exit $LASTEXITCODE
  }
}

if ($env:CHECK_AI_CLI_TEST_MODE -eq '1') {
  $script:ShadowRecoveryAction = 'local'
  $script:ShadowRecoveryTarget = $mainScript
  return
}

if (-not (Test-Path -LiteralPath $mainScript)) {
  throw "Main script not found: $mainScript"
}

& $mainScript @args
