$ErrorActionPreference = 'Stop'

# This script supports "irm ... | iex" one-liner install/update for this repo's files
# Env vars:
# - CHECK_AI_CLI_RAW_BASE: raw base URL (mirror)
# - CHECK_AI_CLI_INSTALL_DIR: install directory (default Program Files)
# - CHECK_AI_CLI_PATH_SCOPE: CurrentUser or Machine (default Machine)
# - CHECK_AI_CLI_RUN: set to 1 to run after install

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Get-AllowUntrustedMirrorFlag() {
  $v = $env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-RequestedRef() {
  $v = $env:CHECK_AI_CLI_REF
  if ([string]::IsNullOrWhiteSpace($v)) { return 'main' }
  return $v.Trim()
}

function Get-GitHubRawBase([string]$Ref) {
  return "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$Ref"
}

function Test-IsTrustedBase([string]$Base) {
  $b = $Base.TrimEnd('/')
  if ($b.StartsWith('https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  if ($b.StartsWith('https://github.com/IIXINGCHEN/Check-AI-CLI/raw/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $false
}

function Require-TrustedBase([string]$Base) {
  if (Test-IsTrustedBase $Base) { return }
  if (Get-AllowUntrustedMirrorFlag) {
    Write-Host ""
    Write-Warn "+-------------------------------------------------------------+"
    Write-Warn "| SECURITY WARNING: Untrusted Mirror Enabled                  |"
    Write-Warn "+-------------------------------------------------------------+"
    Write-Warn "Mirror URL: $Base"
    Write-Warn "You have enabled CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1"
    Write-Warn "Files will be downloaded from an untrusted source."
    Write-Warn "This could expose you to supply chain attacks."
    Write-Host ""
    Start-Sleep -Seconds 3
    return
  }
  throw "Untrusted mirror base. Set CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 to allow: $Base"
}

function Get-BaseUrl() {
  $envBase = $env:CHECK_AI_CLI_RAW_BASE
  if (-not [string]::IsNullOrWhiteSpace($envBase)) {
    $base = $envBase.TrimEnd('/')
    Require-TrustedBase $base
    return $base
  }
  return (Get-GitHubRawBase (Get-RequestedRef))
}

function Get-InstallDir() {
  $envDir = $env:CHECK_AI_CLI_INSTALL_DIR
  if (-not [string]::IsNullOrWhiteSpace($envDir)) { return $envDir }
  if (Test-IsAdmin) { return 'C:\Program Files\Tools\Check-AI-CLI' }
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) { return (Join-Path $env:USERPROFILE 'AppData\Local\Check-AI-CLI') }
  return (Join-Path $localAppData 'Programs\Tools\Check-AI-CLI')
}

function Get-PathScope() {
  $s = $env:CHECK_AI_CLI_PATH_SCOPE
  if ([string]::IsNullOrWhiteSpace($s)) { if (Test-IsAdmin) { return 'Machine' } ; return 'CurrentUser' }
  $t = $s.Trim()
  if ($t -ne 'Machine' -and $t -ne 'CurrentUser') { return 'Machine' }
  return $t
}

function Get-RunFlag() {
  $v = $env:CHECK_AI_CLI_RUN
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Test-IsAdmin() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsUnderProgramFiles([string]$Path) {
  $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
  return $Path.TrimEnd('\').StartsWith($pf, [StringComparison]::OrdinalIgnoreCase)
}

function Require-Admin([string]$Reason) {
  if (Test-IsAdmin) { return }
  throw "Administrator required: $Reason"
}

function Ensure-Directory([string]$Path) {
  if (Test-Path -LiteralPath $Path) { return }
  New-Item -ItemType Directory -Path $Path | Out-Null
}

function Require-WebRequest() {
  $cmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  if ($cmd) { return }
  throw "Invoke-WebRequest not found. Use Windows PowerShell 5.1+ or PowerShell 7+."
}

function Get-RetryCount() {
  $v = $env:CHECK_AI_CLI_RETRY
  if ([string]::IsNullOrWhiteSpace($v)) { return 3 }
  $n = 0
  if (-not [int]::TryParse($v.Trim(), [ref]$n)) { return 3 }
  if ($n -lt 1) { return 1 }
  if ($n -gt 10) { return 10 }
  return $n
}

function Get-TempFilePath([string]$OutFile) {
  return "$OutFile.download"
}

function Test-NonEmptyFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $len = (Get-Item -LiteralPath $Path).Length
  return $len -gt 0
}

function Download-ToFile([string]$Url, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -OutFile $OutFile | Out-Null
}

function Download-FileWithRetry([string]$Url, [string]$OutFile) {
  $tries = Get-RetryCount
  $tmp = Get-TempFilePath $OutFile
  for ($i = 1; $i -le $tries; $i++) {
    try {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      Download-ToFile $Url $tmp
      if (-not (Test-NonEmptyFile $tmp)) { throw "Downloaded file is empty." }
      Move-Item -LiteralPath $tmp -Destination $OutFile -Force
      return
    } catch {
      if ($i -eq $tries) { throw }
      Start-Sleep -Seconds 2
    }
  }
}

function Get-FilesToInstall() {
  return @(
    @{ Remote = 'scripts/Check-AI-CLI-Versions.ps1'; Local = 'scripts\Check-AI-CLI-Versions.ps1' },
    @{ Remote = 'scripts/check-ai-cli-versions.sh'; Local = 'scripts\check-ai-cli-versions.sh' },
    @{ Remote = 'bin/check-ai-cli.ps1'; Local = 'bin\check-ai-cli.ps1' },
    @{ Remote = 'bin/check-ai-cli.cmd'; Local = 'bin\check-ai-cli.cmd' },
    @{ Remote = 'bin/check-ai-cli'; Local = 'bin\check-ai-cli' },
    @{ Remote = 'uninstall.ps1'; Local = 'uninstall.ps1' },
    @{ Remote = 'uninstall.sh'; Local = 'uninstall.sh' }
  )
}

function Get-ManifestRemotePath() { return 'checksums.sha256' }

function Ensure-ParentDirectory([string]$Path) {
  $parent = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($parent)) { return }
  Ensure-Directory $parent
}

function Install-OneFile([string]$Base, [string]$InstallDir, [hashtable]$Entry) {
  $url = "$Base/$($Entry.Remote)"
  $out = Join-Path $InstallDir $Entry.Local
  Ensure-ParentDirectory $out
  Write-Info "Downloading: $($Entry.Remote)"
  Download-FileWithRetry $url $out
}

function Download-Text([string]$Url) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  return (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing).Content
}

function Read-Manifest([string]$Text) {
  $map = @{}
  foreach ($line in @($Text -split "`n")) {
    $t = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    if ($t.StartsWith('#')) { continue }
    $parts = $t -split '\s+'
    if ($parts.Count -lt 2) { continue }
    $hash = $parts[0].Trim().ToLowerInvariant()
    $path = $parts[1].Trim()
    if (-not $map.ContainsKey($path)) { $map[$path] = $hash }
  }
  return $map
}

function Get-ExpectedHash([hashtable]$Manifest, [string]$RemotePath) {
  if ($Manifest.ContainsKey($RemotePath)) { return [string]$Manifest[$RemotePath] }
  return $null
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Verify-FileHash([hashtable]$Manifest, [string]$RemotePath, [string]$LocalPath) {
  $expected = Get-ExpectedHash $Manifest $RemotePath
  if (-not $expected) { throw "Missing checksum for: $RemotePath" }
  $actual = Get-Sha256 $LocalPath
  if ($actual -ne $expected) { throw "Checksum mismatch: $RemotePath" }
}

function New-StagingDir() {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('check-ai-cli\' + [Guid]::NewGuid().ToString('N'))
  Ensure-Directory $root
  return $root
}

function Stage-OneFile([string]$Base, [string]$StageDir, [hashtable]$Entry) {
  $url = "$Base/$($Entry.Remote)"
  $out = Join-Path $StageDir $Entry.Local
  Ensure-ParentDirectory $out
  Download-FileWithRetry $url $out
  return $out
}

function Deploy-OneFile([string]$StageFile, [string]$TargetFile) {
  Ensure-ParentDirectory $TargetFile
  $tmp = "$TargetFile.new"
  Copy-Item -LiteralPath $StageFile -Destination $tmp -Force
  Move-Item -LiteralPath $tmp -Destination $TargetFile -Force
}

function Deploy-All([string]$StageDir, [string]$InstallDir, [object[]]$Entries) {
  foreach ($e in $Entries) {
    $src = Join-Path $StageDir $e.Local
    $dst = Join-Path $InstallDir $e.Local
    Deploy-OneFile $src $dst
  }
}

function Normalize-Dir([string]$Dir) {
  $full = [IO.Path]::GetFullPath($Dir)
  return $full.TrimEnd('\')
}

function Path-ContainsDir([string]$PathValue, [string]$Dir) {
  $needle = (Normalize-Dir $Dir).ToLowerInvariant()
  foreach ($p in @($PathValue -split ';')) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try {
      if ((Normalize-Dir $p).ToLowerInvariant() -eq $needle) { return $true }
    } catch { }
  }
  return $false
}

function Get-EnvRegistryPath([string]$Scope) {
  if ($Scope -eq 'Machine') { return 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
  return 'HKCU:\Environment'
}

function Get-EnvValue([string]$Name, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  try { return [Environment]::GetEnvironmentVariable($Name, $target) } catch {
    $path = Get-EnvRegistryPath $Scope
    $item = Get-ItemProperty -Path $path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return '' }
    return $item.$Name
  }
}

function Set-EnvValue([string]$Name, [string]$Value, [string]$Scope) {
  $target = [EnvironmentVariableTarget]::$Scope
  try { [Environment]::SetEnvironmentVariable($Name, $Value, $target); return } catch {
    $path = Get-EnvRegistryPath $Scope
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $Name -Value $Value
  }
}

function Test-ValidPathEntry([string]$Dir) {
  # Reject paths containing semicolons (PATH injection attempt)
  if ($Dir.Contains(';')) {
    Write-Warn "Invalid path entry (contains semicolon): $Dir"
    return $false
  }
  # Reject paths with suspicious characters
  if ($Dir -match '[<>"|?*]') {
    Write-Warn "Invalid path entry (contains invalid characters): $Dir"
    return $false
  }
  # Reject empty or whitespace-only paths
  if ([string]::IsNullOrWhiteSpace($Dir)) {
    Write-Warn "Invalid path entry (empty or whitespace)"
    return $false
  }
  return $true
}

function Add-ToPath([string]$Dir, [string]$Scope) {
  if (-not (Test-ValidPathEntry $Dir)) {
    throw "Refusing to add invalid path entry to PATH: $Dir"
  }
  $current = Get-EnvValue 'Path' $Scope
  if (Path-ContainsDir $current $Dir) { return }
  $normalized = Normalize-Dir $Dir
  if (-not (Test-ValidPathEntry $normalized)) {
    throw "Refusing to add invalid normalized path entry to PATH: $normalized"
  }
  $newPath = "$current;$normalized"
  Set-EnvValue 'Path' $newPath $Scope
  $env:Path = $newPath
}

function Print-NextSteps([string]$Dir) {
  Write-Host ""
  Write-Host "Next:"
  Write-Host "  check-ai-cli"
  Write-Host "  cd `"$Dir`""
  Write-Host "  .\\bin\\check-ai-cli.cmd"
  Write-Host "  .\\scripts\\Check-AI-CLI-Versions.ps1"
  Write-Host ""
  Write-Host "Uninstall:"
  Write-Host "  .\\uninstall.ps1"
  Write-Host ""
}

function Print-ChinaTip() {
  Write-Host "Tip:"
  Write-Host "  Prefer HTTP_PROXY/HTTPS_PROXY for speed in mainland China."
  Write-Host "  Set `$env:CHECK_AI_CLI_REF to pin a tag/commit for stability."
  Write-Host "  Set `$env:CHECK_AI_CLI_RAW_BASE only if you trust the mirror."
  Write-Host "  Set `$env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR = '1' to bypass mirror check."
  Write-Host "  Set `$ProgressPreference = 'SilentlyContinue' to speed up downloads."
  Write-Host ""
}

function Install-All([string]$Dir, [string]$Scope, [bool]$Run) {
  $base = Get-BaseUrl
  $stage = New-StagingDir
  try {
    $manifestUrl = "$base/$(Get-ManifestRemotePath)"
    $manifestFile = Join-Path $stage 'checksums.sha256'
    Download-FileWithRetry $manifestUrl $manifestFile
    $manifestText = Get-Content -Raw -LiteralPath $manifestFile
    if ([string]::IsNullOrWhiteSpace($manifestText)) { throw "Failed to download checksums.sha256" }
    $manifest = Read-Manifest $manifestText

    $files = @()
    foreach ($remote in ($manifest.Keys | Sort-Object)) {
      $files += @{ Remote = $remote; Local = ($remote -replace '/', '\') }
    }

    foreach ($f in $files) {
      Write-Info "Downloading: $($f.Remote)"
      $staged = Stage-OneFile $base $stage $f
      Verify-FileHash $manifest $f.Remote $staged
    }
    Deploy-All $stage $Dir $files
  } finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }

  $binDir = Join-Path $Dir 'bin'
  Add-ToPath $binDir $Scope
  Write-Success "Installed to: $Dir"
  Print-NextSteps $Dir
  Print-ChinaTip
  if ($Run) { & (Join-Path $Dir 'bin\check-ai-cli.ps1') }
}

function Get-ShowProgress() {
  $v = $env:CHECK_AI_CLI_SHOW_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Set-ProgressMode([string]$Mode) {
  $script:PrevProgressPreference = $ProgressPreference
  $ProgressPreference = $Mode
}

function Restore-Progress() {
  if ($script:PrevProgressPreference) { $ProgressPreference = $script:PrevProgressPreference }
}

function Print-AdminHint() {
  Write-Host ""
  Write-Host "Run PowerShell as Administrator, then rerun:"
  Write-Host "  irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex"
  Write-Host ""
  Write-Host "Or install to CurrentUser without admin:"
  Write-Host "  `$env:CHECK_AI_CLI_PATH_SCOPE = 'CurrentUser'"
  Write-Host "  `$env:CHECK_AI_CLI_INSTALL_DIR = (Join-Path `$env:LOCALAPPDATA 'Programs\\Tools\\Check-AI-CLI')"
  Write-Host "  irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex"
  Write-Host ""
}

try {
  $installDir = Get-InstallDir
  $pathScope = Get-PathScope
  $runAfter = Get-RunFlag

  if (Test-IsUnderProgramFiles $installDir) { Require-Admin "writing to Program Files: $installDir" }
  if ($pathScope -eq 'Machine') { Require-Admin "updating Machine PATH" }

  Require-WebRequest
  if (Get-ShowProgress) {
    Set-ProgressMode 'Continue'
  } else {
    Set-ProgressMode 'SilentlyContinue'
  }
  Ensure-Directory $installDir
  Install-All $installDir $pathScope $runAfter
} catch {
  Write-Fail $_.Exception.Message
  Print-AdminHint
  Print-ChinaTip
  exit 1
} finally {
  Restore-Progress
}
