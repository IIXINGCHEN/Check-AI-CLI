param(
  [switch]$Auto
)

$ErrorActionPreference = 'Stop'

# Main script lives under scripts/ for clearer structure

# Auto mode: install if missing, update if outdated, no Y/N prompts
function Get-AutoMode() {
  if ($Auto) { return $true }
  $v = $env:CHECK_AI_CLI_AUTO
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

$script:AutoMode = Get-AutoMode

# Consistent output formatting
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Some installer scripts rely on PowerShell progress output (Write-Progress / Invoke-WebRequest).
# If user's $ProgressPreference is set to SilentlyContinue, downloads may look "stuck".
function Get-ShowProgress() {
  $v = $env:CHECK_AI_CLI_SHOW_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-QuietProgressMode() {
  if (Get-ShowProgress) { return $false }
  $v = $env:CHECK_AI_CLI_QUIET_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Invoke-WithTempProgressPreference([string]$Mode, [scriptblock]$Action) {
  $prev = $ProgressPreference
  $ProgressPreference = $Mode
  try { & $Action } finally { $ProgressPreference = $prev }
}

function Require-WebRequest() {
  $cmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  if ($cmd) { return }
  throw "Invoke-WebRequest not found. Use Windows PowerShell 5.1+ or PowerShell 7+."
}

# Fetch text content, return $null on failure
function Get-Text([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    $content = (Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing).Content
    if ($content -is [string]) { return $content }
    if ($content -is [string[]]) { return ($content -join "`n") }
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return ($content | Out-String)
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
  }
}

# Fetch JSON, return $null on failure
function Get-Json([string]$Uri) {
  try {
    $headers = @{ 'User-Agent' = 'ai-cli-version-checker' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
  } catch {
    Write-Warn "Request failed: $Uri ($($_.Exception.Message))"
    return $null
  }
}

# Extract x.y.z from arbitrary text
function Get-SemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
}

# Split version into integer parts for comparison
function Get-VersionParts([string]$Version) {
  $v = Get-SemVer $Version
  if (-not $v) { return $null }
  $p = $v.Split('.')
  return @([int]$p[0], [int]$p[1], [int]$p[2])
}

# Compare versions: returns -1/0/1, or $null if not comparable
function Compare-Version([string]$Current, [string]$Latest) {
  $a = Get-VersionParts $Current
  $b = Get-VersionParts $Latest
  if (-not $a -or -not $b) { return $null }
  for ($i = 0; $i -lt 3; $i++) {
    if ($a[$i] -lt $b[$i]) { return -1 }
    if ($a[$i] -gt $b[$i]) { return 1 }
  }
  return 0
}

# Get local command version, return $null if missing or failed
function Get-LocalCommandVersion([string[]]$CommandNames) {
  foreach ($name in $CommandNames) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try {
      $out = & $name '--version' 2>$null | Out-String
      $v = Get-SemVer $out
      if ($v) { return $v }
      Write-Warn "Failed to parse local version from: $name"
    } catch {
      Write-Warn "Failed to run: $name --version ($($_.Exception.Message))"
    }
  }
  return $null
}

# Extract latest Factory CLI version from its Windows installer script
function Get-LatestFactoryVersion() {
  $text = Get-Text 'https://app.factory.ai/cli/windows'
  if (-not $text) { return $null }
  $m = [regex]::Match($text, '\$version\s*=\s*"([^"]+)"')
  if (-not $m.Success) { return $null }
  return Get-SemVer $m.Groups[1].Value
}

# Get latest Claude Code version from npm registry (fallback source)
function Get-LatestClaudeVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

# Get latest Codex version from GitHub Releases API
function Get-LatestCodexVersion() {
  $json = Get-Json 'https://api.github.com/repos/openai/codex/releases/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.tag_name)
}

# Get latest Gemini CLI version from npm registry
function Get-LatestGeminiVersion() {
  $json = Get-Json 'https://registry.npmjs.org/@google/gemini-cli/latest'
  if (-not $json) { return $null }
  return Get-SemVer ([string]$json.version)
}

function Get-TargetOpenCodeVersion() {
  $v = $env:CHECK_AI_CLI_OPENCODE_VERSION
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return Get-SemVer $v
}

function Get-LatestOpenCodeVersion() {
  $target = Get-TargetOpenCodeVersion
  if ($target) { return $target }

  try {
    $json = Get-Json 'https://api.github.com/repos/anomalyco/opencode/releases/latest'
    if ($json -and $json.tag_name) {
      return Get-SemVer ([string]$json.tag_name)
    }
  } catch {
    Write-Warn "Failed to fetch latest OpenCode version from GitHub: $($_.Exception.Message)"
  }

  Write-Warn "Using fallback OpenCode version: 1.1.21"
  $fallback = Get-SemVer '1.1.21'
  if (-not $fallback) {
    Write-Error "Critical: Failed to parse fallback version. This should never happen."
    throw "Unable to determine OpenCode version"
  }
  return $fallback
}

# Run npm install -g in a way that avoids PowerShell npm.ps1 "-Command" parsing edge cases.
function Invoke-NpmInstallGlobal([string]$PackageSpec) {
  $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
  if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue }
  if ($npmCmd) {
    & $npmCmd.Path install -g $PackageSpec
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    return
  }

  $npmPs1 = Get-Command npm -CommandType ExternalScript -ErrorAction SilentlyContinue
  if (-not $npmPs1) { throw "npm not found. Install Node.js first." }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $npmPs1.Path install -g $PackageSpec
  if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
}

# Standard yes/no confirmation prompt
function Confirm-Yes([string]$Prompt) {
  if ($script:AutoMode) { return $true }
  $ans = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans.Trim().ToUpperInvariant().StartsWith('Y')
}

# Install/update Factory CLI
function Update-Factory() {
  Write-Info "Updating Factory CLI (Droid)..."
  Write-Info "Trying: official bootstrap"
  try {
    $script = Get-Text 'https://app.factory.ai/cli/windows'
    if (-not $script) { throw "Failed to download installer script." }
    $mode = 'Continue'
    if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
    Invoke-WithTempProgressPreference $mode { Invoke-Expression $script }
  } catch {
    throw "Factory CLI installer failed."
  }
}

# Install/update Claude Code via official bootstrap (GCS binary)
function Update-ClaudeViaBootstrap() {
  Write-Info "Trying: official bootstrap"

  # Check for 32-bit Windows
  if (-not [Environment]::Is64BitProcess) {
    throw "Claude Code does not support 32-bit Windows."
  }

  $GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
  $DOWNLOAD_DIR = "$env:USERPROFILE\.claude\downloads"
  $platform = "win32-x64"

  New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

  # Get stable version
  try {
    $version = Invoke-RestMethod -Uri "$GCS_BUCKET/stable" -ErrorAction Stop
  } catch {
    throw "Failed to get stable version: $($_.Exception.Message)"
  }

  # Get manifest and checksum
  try {
    $manifest = Invoke-RestMethod -Uri "$GCS_BUCKET/$version/manifest.json" -ErrorAction Stop
    $checksum = $manifest.platforms.$platform.checksum
    if (-not $checksum) { throw "Platform $platform not found in manifest" }
  } catch {
    throw "Failed to get manifest: $($_.Exception.Message)"
  }

  # Download binary
  $binaryPath = "$DOWNLOAD_DIR\claude-$version-$platform.exe"
  try {
    $mode = 'Continue'
    if (Get-QuietProgressMode) { $mode = 'SilentlyContinue' }
    Invoke-WithTempProgressPreference $mode {
      Invoke-WebRequest -Uri "$GCS_BUCKET/$version/$platform/claude.exe" -OutFile $binaryPath -ErrorAction Stop
    }
  } catch {
    if (Test-Path $binaryPath) { Remove-Item -Force $binaryPath }
    throw "Failed to download binary: $($_.Exception.Message)"
  }

  # Verify checksum
  $actualChecksum = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
  if ($actualChecksum -ne $checksum) {
    Remove-Item -Force $binaryPath
    throw "Checksum verification failed"
  }

  # Run claude install
  try {
    & $binaryPath install
  } finally {
    Start-Sleep -Seconds 1
    try { Remove-Item -Force $binaryPath } catch { Write-Warn "Could not remove temporary file: $binaryPath" }
  }
}

# Install/update Claude Code (npm preferred, bootstrap fallback)
function Update-Claude() {
  Write-Info "Updating Claude Code..."

  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@anthropic-ai/claude-code@latest'
    return
  } catch {
    Write-Warn "npm install failed: $($_.Exception.Message)"
  }

  try {
    Update-ClaudeViaBootstrap
  } catch {
    throw "No installer found. Install curl/wget or Node.js (npm) first."
  }
}

# Install/update OpenAI Codex (Windows defaults to npm)
function Update-Codex() {
  Write-Info "Updating OpenAI Codex..."
  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@openai/codex'
  } catch {
    throw "No installer found. Install Node.js (npm) first."
  }
}

# Install/update Gemini CLI (prefers npm)
function Update-Gemini() {
  Write-Info "Updating Gemini CLI..."
  try {
    Write-Info "Trying: npm install"
    Invoke-NpmInstallGlobal '@google/gemini-cli@latest'
  } catch {
    throw "No installer found. Install Node.js (npm) first."
  }
}

function Get-OpenCodeUserInstallPath() {
  $dir = Join-Path $env:USERPROFILE '.opencode\bin'
  foreach ($name in @('opencode.exe','opencode')) {
    $p = Join-Path $dir $name
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Report-OpenCodeResolutionMismatch() {
  $user = Get-OpenCodeUserInstallPath
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $user -or -not $cmd -or -not $cmd.Source) { return }
  if ($cmd.Source -eq $user) { return }
  Write-Warn "PowerShell resolves opencode to: $($cmd.Source)"
  Write-Warn "OpenCode user install path: $user"
  Write-Warn "Tip: current session: Set-Alias opencode `"$user`""
  Write-Warn 'Tip: permanent: add the same line into $PROFILE'
}

function Get-OpenCodeCommandPath() {
  $user = Get-OpenCodeUserInstallPath
  if ($user) { return $user }
  $cmds = Get-Command opencode -All -ErrorAction SilentlyContinue
  if (-not $cmds) { return $null }
  $exe = $cmds | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.exe$' } | Select-Object -First 1
  if ($exe) { return $exe.Source }
  $app = $cmds | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
  if ($app) { return $app.Source }
  return $cmds[0].Source
}

function Invoke-OpenCodeVersionProbe() {
  $path = Get-OpenCodeCommandPath
  if (-not $path) { return @{ Version = $null; Output = '' } }
  try {
    $out = & $path '--version' 2>&1 | Out-String
    return @{ Version = (Get-SemVer $out); Output = $out }
  } catch {
    return @{ Version = $null; Output = $_.Exception.Message }
  }
}

function Get-OpenCodeNpmExePath() {
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) { return $null }
  $baseDir = Split-Path -Parent $cmd.Source
  $glob = Join-Path $baseDir 'node_modules\opencode-ai\node_modules\opencode-*\bin\opencode.exe'
  $hit = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Get-LocalOpenCodeVersion() {
  $probe = Invoke-OpenCodeVersionProbe
  if ($probe.Version) { return $probe.Version }
  $exe = Get-OpenCodeNpmExePath
  if (-not $exe) { return $null }
  try { return Get-SemVer ((& $exe '--version' 2>&1 | Out-String)) } catch { return $null }
}

function Try-FixOpenCodeNpmShim([string]$ExePath) {
  if ([string]::IsNullOrWhiteSpace($ExePath)) { return $false }
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $cmd -or $cmd.CommandType -ne 'ExternalScript') { return $false }
  if (-not (Test-Path -LiteralPath $cmd.Source)) { return $false }
  $text = [IO.File]::ReadAllText($cmd.Source)
  if (-not $text.Contains('/bin/sh')) { return $false }
  $repl = "& `"$ExePath`" `$args"
  $newText = [regex]::Replace($text, '&\s+\"/bin/sh\$exe\"[^\r\n]*', $repl)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($cmd.Source, $newText, $enc)
  return $true
}

function Test-OpenCodeRunnable() {
  return [bool]((Invoke-OpenCodeVersionProbe).Version)
}

function Try-RepairOpenCodeNpmShim() {
  $exe = Get-OpenCodeNpmExePath
  if (-not $exe) { return $false }
  return Try-FixOpenCodeNpmShim $exe
}

function Get-OpenCodeMissingRuntimePackageName([string]$Text) {
  if ($Text -match '\"(opencode-(?:win32|windows)-[a-z0-9-]+)\"') { return $Matches[1] }
  return $null
}

function Try-InstallOpenCodeRuntimePackage([string]$TargetVersion) {
  $probe = Invoke-OpenCodeVersionProbe
  $pkg = Get-OpenCodeMissingRuntimePackageName $probe.Output
  if (-not $pkg) { return $false }
  Write-Warn "Trying npm install for missing runtime package: $pkg"
  try { Invoke-NpmInstallGlobal $pkg } catch { return $false }
  return (Test-OpenCodeRunnable)
}

function Try-OpenCodeSelfUpgrade([string]$TargetVersion) {
  $path = Get-OpenCodeCommandPath
  if (-not $path) { return $false }
  $arg = $null
  if ($TargetVersion) { $arg = "v$TargetVersion" }
  try {
    if ($arg) { & $path upgrade $arg } else { & $path upgrade }
    if ($LASTEXITCODE -ne 0) { throw "opencode upgrade failed with exit code $LASTEXITCODE" }
    return $true
  } catch {
    Write-Warn "opencode upgrade failed: $($_.Exception.Message)"
    return $false
  }
}

function Get-BashCommandPath() {
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\bash.exe"
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  return $null
}

function Test-BashUsable([string]$BashPath) {
  if ([string]::IsNullOrWhiteSpace($BashPath)) { return $false }
  try {
    $out = & $BashPath -lc 'echo __bash_ok__' 2>$null | Out-String
    return $LASTEXITCODE -eq 0 -and $out.Trim() -eq '__bash_ok__'
  } catch {
    return $false
  }
}

function Try-InstallOpenCodeWithCurl([string]$TargetVersion) {
  $bash = Get-BashCommandPath
  if (-not $bash) { return $false }
  if (-not (Test-BashUsable $bash)) {
    Write-Warn "bash found but not usable. Skipping curl install. Tip: install Git for Windows (Git Bash) or a WSL distro."
    return $false
  }
  $v = Get-SemVer $TargetVersion
  $cmd = 'curl -fsSL https://opencode.ai/install | bash'
  if ($v) { $cmd = "curl -fsSL https://opencode.ai/install | bash -s -- --version $v" }
  try {
    & $bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { Write-Warn "curl install failed with exit code $LASTEXITCODE" ; return $false }
    return $true
  } catch {
    Write-Warn "curl install failed: $($_.Exception.Message)"
    return $false
  }
}

function Test-OpenCodeAtLeast([string]$TargetVersion) {
  $v = Get-LocalOpenCodeVersion
  if (-not $v) { return $false }
  if (-not $TargetVersion) { return $true }
  $cmp = Compare-Version $v $TargetVersion
  return ($cmp -eq 0 -or $cmp -eq 1)
}

function Try-InstallOpenCodeWithScoop() {
  $cmd = Get-Command scoop -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  & scoop install extras/opencode
  if ($LASTEXITCODE -eq 0) { return $true }
  & scoop bucket add extras 2>$null | Out-Null
  & scoop install extras/opencode
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "scoop install failed with exit code $LASTEXITCODE"
    return $false
  }
  return $true
}

function Try-InstallOpenCodeWithChoco() {
  $cmd = Get-Command choco -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  & choco upgrade opencode -y
  if ($LASTEXITCODE -eq 0) { return $true }
  & choco install opencode -y
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "choco install failed with exit code $LASTEXITCODE"
    return $false
  }
  return $true
}

function Try-InstallOpenCodeWithNpm([string]$TargetVersion) {
  try {
    Invoke-NpmInstallGlobal 'opencode-ai@latest'
    if (Test-OpenCodeRunnable) { return $true }
    if (Try-RepairOpenCodeNpmShim -and (Test-OpenCodeRunnable)) { return $true }
    if (Try-InstallOpenCodeRuntimePackage $TargetVersion -and (Test-OpenCodeRunnable)) { return $true }
    Write-Warn "opencode installed but still not runnable. Prefer scoop/choco, or run the bundled exe under npm node_modules."
    return $false
  } catch {
    Write-Warn "npm install failed: $($_.Exception.Message)"
    return $false
  }
}

function Update-OpenCode() {
  Write-Info "Updating OpenCode..."
  $target = Get-TargetOpenCodeVersion
  if ($target) { Write-Info "Target OpenCode version: v$target" }
  Write-Info "Trying: curl/wget install"
  if (Try-InstallOpenCodeWithCurl $target -and (Test-OpenCodeAtLeast $target)) { return }
  $installed = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
  if ($installed) {
    Write-Info "Trying: opencode upgrade"
    Try-OpenCodeSelfUpgrade $target | Out-Null
    if (Test-OpenCodeAtLeast $target) { return }
  }
  Write-Info "Trying: scoop install"
  if (Try-InstallOpenCodeWithScoop) { Try-OpenCodeSelfUpgrade $target | Out-Null ; if (Test-OpenCodeAtLeast $target) { return } }
  Write-Info "Trying: choco install"
  if (Try-InstallOpenCodeWithChoco) { Try-OpenCodeSelfUpgrade $target | Out-Null ; if (Test-OpenCodeAtLeast $target) { return } }
  Write-Info "Trying: npm install"
  if (Try-InstallOpenCodeWithNpm $target -and (Test-OpenCodeAtLeast $target)) { return }
  throw "No installer found. Install Git Bash (for curl), scoop/choco, or Node.js (npm) first."
}

function Write-ToolHeader([string]$Title) {
  Write-Host ""
  Write-Host $Title
  Write-Host ('=' * $Title.Length)
}

function Get-AndPrintLatest([scriptblock]$GetLatest) {
  Write-Info "Fetching latest version..."
  $latest = & $GetLatest
  if ($latest) { Write-Success "Latest version: v$latest" } else { Write-Warn "Latest version: unknown" }
  return $latest
}

function Get-AndPrintLocal([scriptblock]$GetLocal) {
  $local = & $GetLocal
  if ($local) { Write-Success "Local version: v$local" } else { Write-Warn "Local version: not installed" }
  return $local
}

function Try-Update([scriptblock]$DoUpdate) {
  try { & $DoUpdate } catch { Write-Fail $_.Exception.Message }
}

function Handle-UpdateFlow([string]$Latest, [string]$Local, [scriptblock]$DoUpdate) {
  if (-not $Local) {
  if (-not $Latest) { Write-Warn "Latest version unknown. Installing anyway." }
  if (Confirm-Yes "Install now? (Y/N): ") { Try-Update $DoUpdate ; return $true }

    return $false
  }
  if (-not $Latest) { Write-Warn "Latest version unknown. Skipping update check." ; return $false }
  $cmp = Compare-Version $Local $Latest
  if ($cmp -eq 0) { Write-Success "Already up to date." ; return $false }
  if ($cmp -eq 1) { Write-Warn "Local version is newer than latest source." ; return $false }
  if ($cmp -eq -1 -and (Confirm-Yes "Update now? (Y/N): ")) { Try-Update $DoUpdate ; return $true }
  return $false
}

function Report-PostUpdate([string]$Title, [string]$Latest, [scriptblock]$GetLocal) {
  Write-Info "Re-checking local version..."
  $newLocal = Get-AndPrintLocal $GetLocal
  if (-not $newLocal) { Write-Warn "Update may not have installed correctly." ; return }
  if ($Title -eq 'OpenCode') { Report-OpenCodeResolutionMismatch }
  if (-not $Latest) { return }
  $cmp = Compare-Version $newLocal $Latest
  if ($cmp -eq -1) {
    Write-Warn "Update may have failed (still older than latest)."
    if ($Title -eq 'Claude Code') { Write-Warn "Tip: try npm install -g @anthropic-ai/claude-code@latest" }
    if ($Title -eq 'OpenCode') {
      if ($Latest) { Write-Warn "Tip: try opencode upgrade v$Latest" } else { Write-Warn "Tip: try opencode upgrade" }
      Write-Warn "Tip: override target via CHECK_AI_CLI_OPENCODE_VERSION"
      Write-Warn "Tip: Windows recommend scoop/choco: scoop install extras/opencode OR choco install opencode -y"
    }
  }
}

function Check-OneTool([string]$Title, [scriptblock]$GetLatest, [scriptblock]$GetLocal, [scriptblock]$DoUpdate) {
  Write-ToolHeader $Title
  $latest = Get-AndPrintLatest $GetLatest
  $local = Get-AndPrintLocal $GetLocal
  if ($Title -eq 'OpenCode') { Report-OpenCodeResolutionMismatch }
  $didUpdate = Handle-UpdateFlow $latest $local $DoUpdate
  if ($didUpdate) { Report-PostUpdate $Title $latest $GetLocal }
}

function Show-Banner() {
  Write-Host ""
  Write-Host "==============================================="
  Write-Host " AI CLI Version Checker"
  Write-Host " Factory CLI (Droid) | Claude Code | OpenAI Codex | Gemini CLI | OpenCode"
  Write-Host "==============================================="
  Write-Host ""
}

function Ask-Selection() {
  Write-Host "Select tools to check:"
  Write-Host "  [1] Factory CLI (Droid)"
  Write-Host "  [2] Claude Code"
  Write-Host "  [3] OpenAI Codex"
  Write-Host "  [4] Gemini CLI"
  Write-Host "  [5] OpenCode"
  Write-Host "  [A] Check all (default)"
  Write-Host "  [Q] Quit"
  $s = Read-Host "Enter choice (1/2/3/4/5/A/Q)"
  if ([string]::IsNullOrWhiteSpace($s)) { return 'A' }
  return $s.Trim().ToUpperInvariant()
}

Require-WebRequest
Show-Banner
$sel = Ask-Selection
if ($sel -eq 'Q') { exit 0 }

if ($sel -eq '1' -or $sel -eq 'A') {
  Check-OneTool "Factory CLI (Droid)" { Get-LatestFactoryVersion } { Get-LocalCommandVersion @('factory','droid') } { Update-Factory }
}
if ($sel -eq '2' -or $sel -eq 'A') {
  Check-OneTool "Claude Code" { Get-LatestClaudeVersion } { Get-LocalCommandVersion @('claude','claude-code') } { Update-Claude }
}
if ($sel -eq '3' -or $sel -eq 'A') {
  Check-OneTool "OpenAI Codex" { Get-LatestCodexVersion } { Get-LocalCommandVersion @('codex') } { Update-Codex }
}
if ($sel -eq '4' -or $sel -eq 'A') {
  Check-OneTool "Gemini CLI" { Get-LatestGeminiVersion } { Get-LocalCommandVersion @('gemini') } { Update-Gemini }
}
if ($sel -eq '5' -or $sel -eq 'A') {
  Check-OneTool "OpenCode" { Get-LatestOpenCodeVersion } { Get-LocalOpenCodeVersion } { Update-OpenCode }
}
