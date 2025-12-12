$ErrorActionPreference = 'Stop'

# 中文注释: 命令入口, 用于 PATH 场景下直接运行
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptDir 'Check-AI-CLI-Versions.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
  throw "Main script not found: $mainScript"
}

& $mainScript

