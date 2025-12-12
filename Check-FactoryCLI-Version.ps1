$ErrorActionPreference = 'Stop'

# 中文注释: 兼容入口, 实际脚本在 scripts 目录
$target = Join-Path $PSScriptRoot 'scripts\Check-FactoryCLI-Version.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "Main script not found: $target" }
& $target @args

