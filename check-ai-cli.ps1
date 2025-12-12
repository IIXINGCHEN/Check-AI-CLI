$ErrorActionPreference = 'Stop'

# Legacy wrapper: real entrypoint is in bin/
$target = Join-Path $PSScriptRoot 'bin\check-ai-cli.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "Entry script not found: $target" }
& $target @args
