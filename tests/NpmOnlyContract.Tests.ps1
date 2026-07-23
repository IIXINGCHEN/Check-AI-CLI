$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$main = Join-Path $repoRoot 'scripts\Check-AI-CLI-Versions.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-False([bool]$Condition, [string]$Message) {
  if ($Condition) { throw $Message }
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  & $Body
  Write-Host "[PASS] $Name" -ForegroundColor Green
}

# Dot-source without running main
$oldSkip = $env:CHECK_AI_CLI_SKIP_MAIN
# Main uses InvocationName -ne '.' guard; dot-source is safe.
. $main

Run-Test 'Tool registry is exactly five npm packages' {
  $tools = Get-AiCliTools
  Assert-True ($tools.Count -eq 5) "Expected 5 tools, got $($tools.Count)"
  $ids = @($tools | ForEach-Object { $_.Id }) -join ','
  Assert-True ($ids -eq 'claude,codex,gemini,grok,opencode') "Unexpected ids: $ids"
  $pkgs = @($tools | ForEach-Object { $_.Package })
  Assert-True ($pkgs -contains '@anthropic-ai/claude-code') 'Missing claude package'
  Assert-True ($pkgs -contains '@openai/codex') 'Missing codex package'
  Assert-True ($pkgs -contains '@google/gemini-cli') 'Missing gemini package'
  Assert-True ($pkgs -contains '@xai-official/grok') 'Missing grok package'
  Assert-True ($pkgs -contains 'opencode-ai') 'Missing opencode package'
  foreach ($t in $tools) {
    Assert-True ($t.Spec -like '*@latest') "Spec must be @latest: $($t.Spec)"
    Assert-True ($t.Kind -eq 'npm') "Kind must be npm: $($t.Id)"
  }
}

Run-Test 'No Factory tool in registry' {
  $tools = Get-AiCliTools
  foreach ($t in $tools) {
    Assert-False ($t.Id -eq 'factory') 'Factory must not be registered'
    Assert-False ($t.Package -eq 'droid') 'droid package must not be registered'
  }
}

Run-Test 'Main script source forbids non-npm update channels' {
  $text = [IO.File]::ReadAllText($main)
  $forbidden = @(
    'app.factory.ai',
    'Install-FactoryFromBootstrap',
    'Update-Factory',
    'claude update',
    'claude.ai/install',
    'scoop install',
    'choco install',
    'opencode upgrade',
    'Confirm-RemoteScriptExecution',
    'FactoryOnly'
  )
  foreach ($f in $forbidden) {
    Assert-False ($text.Contains($f)) "Forbidden update-channel remnant: $f"
  }
  Assert-True ($text.Contains('Update-ToolViaNpm')) 'Expected Update-ToolViaNpm'
  Assert-True ($text.Contains('@xai-official/grok')) 'Expected Grok package'
}

Run-Test 'SemVer compare basic ordering' {
  Assert-True ((Compare-Version '1.2.3' '1.2.3') -eq 0) 'equal'
  Assert-True ((Compare-Version '1.2.3' '1.2.4') -eq -1) 'older'
  Assert-True ((Compare-Version '2.0.0' '1.9.9') -eq 1) 'newer'
  Assert-True ((Get-SemVer 'v1.2.3-beta') -eq '1.2.3') 'extract semver'
}

Run-Test 'Installed resolver read does not permanently require PATH mutation API' {
  $oldPath = $env:PATH
  try {
    $tool = Get-AiCliToolById 'claude'
    $null = Get-InstalledToolCandidate $tool.Id $tool.Commands
    Assert-True ($env:PATH -eq $oldPath) 'Expected Get-InstalledToolCandidate to restore PATH'
  } finally {
    $env:PATH = $oldPath
  }
}

Run-Test 'Lifecycle adapter verifies post-update version' {
  $oldAuto = $script:AutoMode
  $script:AutoMode = $true
  $script:UpdateFailed = $false
  $state = @{ Version = '1.0.0'; Updates = 0 }
  try {
    $result = Invoke-ToolLifecycle @{
      Title = 'Fixture Tool'
      GetLatest = { '1.1.0' }
      GetLocal = { $state.Version }
      Update = { $state.Updates++; $state.Version = '1.1.0' }
    }
  } finally {
    $script:AutoMode = $oldAuto
  }
  Assert-True ($result.Updated -eq $true) 'Expected lifecycle to update'
  Assert-True ($state.Updates -eq 1) 'Expected one update call'
  Assert-True ($state.Version -eq '1.1.0') 'Expected version bump'
}

Run-Test 'Factory wrapper exits unsupported' {
  $wrapper = Join-Path $repoRoot 'Check-FactoryCLI-Version.ps1'
  $p = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -Wait -PassThru -NoNewWindow
  Assert-True ($p.ExitCode -eq 2) "Expected exit 2 from Factory wrapper, got $($p.ExitCode)"
}

Write-Host 'All NpmOnlyContract tests passed.' -ForegroundColor Green
