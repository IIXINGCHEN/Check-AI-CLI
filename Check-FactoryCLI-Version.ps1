$ErrorActionPreference = 'Stop'

# Legacy wrapper: real script is in scripts/
$target = Join-Path $PSScriptRoot 'scripts\Check-FactoryCLI-Version.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "Main script not found: $target" }
& $target @args
