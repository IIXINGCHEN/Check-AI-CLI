$ErrorActionPreference = 'Stop'

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
$mainScript = Join-Path $installRoot 'scripts\Check-AI-CLI-Versions.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
  throw "Main script not found: $mainScript"
}

& $mainScript @args
