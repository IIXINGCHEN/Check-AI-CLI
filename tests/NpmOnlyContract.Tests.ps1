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
  $allowScripts = @{}
  foreach ($t in $tools) {
    $allowScripts[$t.Id] = @($t.AllowScripts) -join ','
  }
  Assert-True ($allowScripts.claude -eq '@anthropic-ai/claude-code') 'Unexpected Claude lifecycle-script allowlist'
  Assert-True ($allowScripts.codex -eq '') 'Codex must not approve lifecycle scripts it does not use'
  Assert-True ($allowScripts.gemini -eq '@github/keytar,node-pty') 'Unexpected Gemini lifecycle-script allowlist'
  Assert-True ($allowScripts.grok -eq '@xai-official/grok') 'Unexpected Grok lifecycle-script allowlist'
  Assert-True ($allowScripts.opencode -eq 'opencode-ai') 'Unexpected OpenCode lifecycle-script allowlist'
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
  Assert-True ((Compare-Version '1.2.3-beta.1' '1.2.3') -eq -1) 'prerelease older than release'
  Assert-True ((Compare-Version '1.2.3' '1.2.3-beta.1') -eq 1) 'release newer than prerelease'
  Assert-True ((Compare-Version '1.2.3-beta.1' '1.2.3-beta.2') -eq -1) 'beta.1 older than beta.2'
  Assert-True ((Get-SemVer 'v1.2.3-beta') -eq '1.2.3') 'extract semver'
}

Run-Test 'SemVer prerelease identifiers follow semver 11.4' {
  Assert-True ((Compare-Version '1.2.3-beta.2' '1.2.3-beta.10') -eq -1) 'numeric prerelease identifiers compare numerically'
  Assert-True ((Compare-Version '1.2.3-1' '1.2.3-alpha') -eq -1) 'numeric prerelease identifier is lower than alphanumeric'
  Assert-True ((Compare-Version '1.2.3-beta' '1.2.3-beta.1') -eq -1) 'fewer prerelease identifiers is lower'
  Assert-True ((Compare-Version '1.2.3-alpha.1' '1.2.3-beta.1') -eq -1) 'alphanumeric prerelease identifiers compare in ASCII order'
  Assert-True ((Compare-Version '1.2.3-beta.10' '1.2.3-beta.2') -eq 1) 'numeric prerelease ordering is antisymmetric'
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

Run-Test 'Global npm install arguments use one-shot reviewed script approvals' {
  $withApprovals = @(Get-NpmInstallArguments '@google/gemini-cli@0.57.0' 'https://registry.npmjs.org' @('@github/keytar', 'node-pty'))
  Assert-True (($withApprovals -join '|') -eq 'install|-g|--allow-scripts=@github/keytar,node-pty|@google/gemini-cli@0.57.0|--registry|https://registry.npmjs.org') 'Expected reviewed one-shot --allow-scripts argument'

  $withoutApprovals = @(Get-NpmInstallArguments '@openai/codex@0.149.1' 'https://registry.npmjs.org' @())
  Assert-True (($withoutApprovals -join '|') -eq 'install|-g|@openai/codex@0.149.1|--registry|https://registry.npmjs.org') 'Packages without install scripts must not receive --allow-scripts'
}

Run-Test 'Old npm gets one actionable allow-scripts warning, never a silent flag drop' {
  $oldWarned = $script:NpmMajorVersionWarned
  try {
    $script:NpmMajorVersionWarned = $false
    function Get-NpmMajorVersion() { return 10 }
    Warn-WhenNpmCannotEnforceScriptAllowlist @('@xai-official/grok')
    Assert-True ($script:NpmMajorVersionWarned -eq $true) 'Expected a single warning on npm 10 with approved lifecycle scripts'

    $script:NpmMajorVersionWarned = $false
    Warn-WhenNpmCannotEnforceScriptAllowlist @()
    Assert-True ($script:NpmMajorVersionWarned -eq $false) 'Packages without approved scripts must not warn'

    $script:NpmMajorVersionWarned = $false
    function Get-NpmMajorVersion() { return 11 }
    Warn-WhenNpmCannotEnforceScriptAllowlist @('@xai-official/grok')
    Assert-True ($script:NpmMajorVersionWarned -eq $false) 'npm 11+ must not warn'
  } finally {
    $script:NpmMajorVersionWarned = $oldWarned
  }
}

Run-Test 'Remove-PathEntry preserves unrecognized entries and removes only the target' {
  $base = [IO.Path]::GetTempPath().TrimEnd('\')
  $targetDir = [IO.Path]::Combine($base, 'npm')
  $wildcardEntry = [IO.Path]::Combine($base, 'tools', '?')
  $otherDir = [IO.Path]::Combine($base, 'other')
  $path = "$targetDir;$wildcardEntry;$otherDir;$targetDir"
  $next = Remove-PathEntry $path $targetDir
  Assert-True ($next -eq "$wildcardEntry;$otherDir") "Wildcard entry must survive the rewrite and both target copies must be removed. Got: $next"
}

Run-Test 'Registry candidates automatically fail over between global and China sources' {
  $oldNetworkInfo = $script:NetworkInfo
  $oldBestMirror = $script:BestNpmMirror
  $oldCandidates = $script:NpmRegistryCandidates
  try {
    $script:NetworkInfo = @{
      Region = 'global'
      Connectivity = @{
        NpmjsOK = $false; NpmjsTime = -1
        NpmmirrorOK = $false; NpmmirrorTime = -1
        TencentOK = $true; TencentTime = 20
        HuaweiOK = $false; HuaweiTime = -1
      }
    }
    $script:BestNpmMirror = $null
    $script:NpmRegistryCandidates = $null
    $globalFallback = @(Get-RegistryCandidates)
    Assert-True ($globalFallback[0] -eq $script:NpmMirrors.tencent) 'Reachable China source must lead when the official source is unavailable'
    Assert-True (($globalFallback | Select-Object -Unique).Count -eq 4) 'Expected four unique registry failover candidates'
    Assert-True ($globalFallback -contains $script:NpmMirrors.default) 'Official registry must remain a retry candidate'

    $script:NetworkInfo = @{
      Region = 'china'
      Connectivity = @{
        NpmjsOK = $true; NpmjsTime = 80
        NpmmirrorOK = $true; NpmmirrorTime = 10
        TencentOK = $true; TencentTime = 20
        HuaweiOK = $true; HuaweiTime = 30
      }
    }
    $script:BestNpmMirror = $null
    $script:NpmRegistryCandidates = $null
    $chinaPreferred = @(Get-RegistryCandidates)
    Assert-True ($chinaPreferred[0] -eq $script:NpmMirrors.taobao) 'Fastest reachable China source must lead in China mode'
    Assert-True ($chinaPreferred[-1] -eq $script:NpmMirrors.default) 'Official registry must remain the final China-mode fallback'
  } finally {
    $script:NetworkInfo = $oldNetworkInfo
    $script:BestNpmMirror = $oldBestMirror
    $script:NpmRegistryCandidates = $oldCandidates
  }
}

Run-Test 'Fallback metadata selects the newest reachable mirror version' {
  $oldNetworkInfo = $script:NetworkInfo
  $oldBestMirror = $script:BestNpmMirror
  $oldCandidates = $script:NpmRegistryCandidates
  try {
    $script:NetworkInfo = @{
      Region = 'china'
      Connectivity = @{
        NpmjsOK = $false; NpmjsTime = -1
        NpmmirrorOK = $true; NpmmirrorTime = 10
        TencentOK = $true; TencentTime = 20
        HuaweiOK = $true; HuaweiTime = 30
      }
    }
    $script:BestNpmMirror = $null
    $script:NpmRegistryCandidates = $null
    function Get-NpmVersionFromRegistry([string]$PackageName, [string]$Registry) {
      if ($Registry -eq $script:NpmMirrors.default) { return $null }
      if ($Registry -eq $script:NpmMirrors.taobao) { return '0.1.4' }
      if ($Registry -eq $script:NpmMirrors.tencent) { return '1.0.5' }
      if ($Registry -eq $script:NpmMirrors.huawei) { return '1.0.4' }
      return $null
    }
    Assert-True ((Get-NpmLatestVersion '@xai-official/grok') -eq '1.0.5') 'Expected the newest reachable fallback metadata, not the first stale mirror result'
  } finally {
    $script:NetworkInfo = $oldNetworkInfo
    $script:BestNpmMirror = $oldBestMirror
    $script:NpmRegistryCandidates = $oldCandidates
  }
}

Run-Test 'Only the canonical Grok layout can migrate to npm management' {
  $oldGrokHome = $env:GROK_HOME
  try {
    $env:GROK_HOME = Join-Path $repoRoot 'tests\fixture-grok-home'
    $tool = Get-AiCliToolById 'grok'
    $canonical = Join-Path (Join-Path $env:GROK_HOME 'bin') 'grok.exe'
    Assert-True (Test-GrokNpmMigrationCandidate $tool @{ Source = $canonical; Kind = 'external' }) 'Canonical Grok binary should be migratable'
    Assert-False (Test-GrokNpmMigrationCandidate $tool @{ Source = (Join-Path $repoRoot 'other\grok.exe'); Kind = 'external' }) 'Unknown external Grok binary must remain blocked'
    Assert-False (Test-GrokNpmMigrationCandidate (Get-AiCliToolById 'codex') @{ Source = $canonical; Kind = 'external' }) 'Migration exception must be Grok-only'
  } finally {
    $env:GROK_HOME = $oldGrokHome
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

Run-Test 'Failed update does not trigger a misleading post-update check' {
  $oldAuto = $script:AutoMode
  $oldFailed = $script:UpdateFailed
  $script:AutoMode = $true
  $script:UpdateFailed = $false
  $state = @{ Reads = 0; Updates = 0 }
  try {
    $result = Invoke-ToolLifecycle @{
      Title = 'Blocked Fixture'
      GetLatest = { '1.1.0' }
      GetLocal = { $state.Reads++; '1.0.0' }
      Update = { $state.Updates++; throw 'blocked fixture update' }
    }
    Assert-True ($result.Updated -eq $false) 'Failed update must not be reported as updated'
    Assert-True ($state.Updates -eq 1) 'Expected one blocked update attempt'
    Assert-True ($state.Reads -eq 1) 'Failed update must not trigger a post-update local-version read'
    Assert-True ($script:UpdateFailed -eq $true) 'Expected failed-update status'
  } finally {
    $script:AutoMode = $oldAuto
    $script:UpdateFailed = $oldFailed
  }
}

Run-Test 'Official metadata is authoritative and unknown external installs are blocked' {
  $text = [IO.File]::ReadAllText($main)
  Assert-True ($text.Contains('$version = Get-NpmVersionFromRegistry $PackageName $official')) 'Expected official npm metadata lookup first'
  Assert-True ($text.Contains('stale mirror metadata must never suppress a real update')) 'Expected mirror freshness safety invariant'
  Assert-True ($text.Contains('$installSpec = "$($Tool.Package)@$target"')) 'Expected authoritative target version pin during install'
  Assert-True ($text.Contains("$kind = 'external'")) 'Expected non-npm command classification'
  Assert-True ($text.Contains('Test-GrokNpmMigrationCandidate')) 'Expected canonical Grok npm migration gate'
  Assert-True ($text.Contains('--allow-scripts=')) 'Expected one-shot lifecycle-script approvals'
  Assert-True ($text.Contains('Automatic npm update was blocked to avoid a conflicting installation.')) 'Expected fail-closed mixed-install guard'
}

Run-Test 'Production lifecycle adapters stay in the script runspace' {
  $text = [IO.File]::ReadAllText($main)
  Assert-False ($text.Contains('}.GetNewClosure()')) 'GetNewClosure isolates script helper functions in a dynamic module on Windows PowerShell 5.1'
  Assert-True ($text.Contains('GetLatest = { Get-LatestToolVersion $Tool }')) 'Expected direct latest-version adapter'
  Assert-True ($text.Contains('GetLocal = { Get-LocalToolVersion $Tool }')) 'Expected direct local-version adapter'
  Assert-True ($text.Contains('Update = { Update-ToolViaNpm $Tool }')) 'Expected direct npm-update adapter'
}

Run-Test 'Factory wrapper exits unsupported' {
  $wrapper = Join-Path $repoRoot 'Check-FactoryCLI-Version.ps1'
  $p = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -Wait -PassThru -NoNewWindow
  Assert-True ($p.ExitCode -eq 2) "Expected exit 2 from Factory wrapper, got $($p.ExitCode)"
}

Run-Test 'PATH write failure during local probe must not abort the run' {
  # Function overrides shadow the dot-sourced implementations only inside this
  # test scope, so no explicit restore is needed.
  function Get-NpmGlobalBinDir { return (Join-Path $repoRoot 'tests') }
  function Set-UserPathValue([string]$PathValue) {
    $script:FixturePathWriteThrew = $true
    throw 'registry denied fixture'
  }
  $script:FixturePathWriteThrew = $false
  try {
    $null = Get-LocalToolVersion (Get-AiCliToolById 'claude')
  } catch {
    throw "Get-LocalToolVersion must survive a PATH write failure: $($_.Exception.Message)"
  }
  Assert-True $script:FixturePathWriteThrew 'Fixture PATH write must actually throw for this test to be meaningful.'
}

Write-Host 'All NpmOnlyContract tests passed.' -ForegroundColor Green
