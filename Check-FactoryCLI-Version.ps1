$ErrorActionPreference = 'Stop'

# Legacy wrapper: route to unified main script
$target = Join-Path $PSScriptRoot 'scripts\Check-AI-CLI-Versions.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "Main script not found: $target" }
& $target -FactoryOnly @args
