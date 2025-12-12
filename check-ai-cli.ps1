$ErrorActionPreference = 'Stop'

# 中文注释: 兼容入口, 实际命令入口在 bin 目录
$target = Join-Path $PSScriptRoot 'bin\check-ai-cli.ps1'
if (-not (Test-Path -LiteralPath $target)) { throw "Entry script not found: $target" }
& $target @args

