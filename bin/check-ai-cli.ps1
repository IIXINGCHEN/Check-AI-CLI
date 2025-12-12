$ErrorActionPreference = 'Stop'

# 中文注释: 命令入口, 用于 PATH 场景下直接运行
$binDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installRoot = Split-Path -Parent $binDir
$mainScript = Join-Path $installRoot 'scripts\Check-AI-CLI-Versions.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
  throw "Main script not found: $mainScript"
}

& $mainScript
