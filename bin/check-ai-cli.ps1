$ErrorActionPreference = 'Stop'

function Get-CurrentUserInstallRoot() {
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Tools\Check-AI-CLI')
  }
  return (Join-Path $localAppData 'Programs\Tools\Check-AI-CLI')
}

function Test-IsUnderProgramFiles([string]$Path) {
  $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
  return $Path.TrimEnd('\').StartsWith($pf, [StringComparison]::OrdinalIgnoreCase)
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

if (Test-IsUnderProgramFiles $installRoot) {
  $userInstallRoot = Get-CurrentUserInstallRoot
  $userEntrypoint = Join-Path $userInstallRoot 'bin\check-ai-cli.ps1'
  $currentEntrypoint = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { (Join-Path $binDir 'check-ai-cli.ps1') }
  if ((Test-Path -LiteralPath $userEntrypoint) -and ($userEntrypoint -ne $currentEntrypoint)) {
    if ($env:CHECK_AI_CLI_TEST_MODE -eq '1') {
      $script:ShadowRecoveryAction = 'forward'
      $script:ShadowRecoveryTarget = $userEntrypoint
      return
    }
    & $userEntrypoint @args
    exit $LASTEXITCODE
  }
}

$mainScript = Join-Path $installRoot 'scripts\Check-AI-CLI-Versions.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
  throw "Main script not found: $mainScript"
}

& $mainScript @args
