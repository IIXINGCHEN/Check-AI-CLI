$ErrorActionPreference = 'Stop'

# Factory CLI / Droid support was removed. Check-AI-CLI is npm-only for:
#   @anthropic-ai/claude-code, @openai/codex, @google/gemini-cli,
#   @xai-official/grok, opencode-ai
Write-Host '[ERROR] Factory CLI (Droid) is no longer supported by Check-AI-CLI.' -ForegroundColor Red
Write-Host '[INFO] Supported updates are only: npm i -g <package>@latest for Claude/Codex/Gemini/Grok/OpenCode.' -ForegroundColor Cyan
Write-Host '[INFO] Run: check-ai-cli' -ForegroundColor Cyan
exit 2
