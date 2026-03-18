$ErrorActionPreference = 'Stop'

# This script supports "irm ... | iex" one-liner install/update for this repo's files
# Env vars:
# - CHECK_AI_CLI_REF: pin tag/commit/main; default latest stable release, else latest main commit, fallback main
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

function Get-DefaultRef() { return 'main' }

function Test-HasExplicitRef() {
  return -not [string]::IsNullOrWhiteSpace($env:CHECK_AI_CLI_REF)
}

function Get-RequestedRef() {
  if (-not (Test-HasExplicitRef)) { return (Get-DefaultRef) }
  return $env:CHECK_AI_CLI_REF.Trim()
}

function Get-GitHubRawBase([string]$Ref) {
  return "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$Ref"
}

function Get-LatestReleaseApiUrl() {
  return 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/releases/latest'
}

function Get-LatestMainRefApiUrl() {
  return 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/git/ref/heads/main'
}

function Get-GitHubApiHeaders() {
  return @{ 'User-Agent' = 'check-ai-cli-installer'; 'Accept' = 'application/vnd.github+json' }
}

function Get-LatestStableRef() {
  try {
    $json = Invoke-RestMethod -Uri (Get-LatestReleaseApiUrl) -Headers (Get-GitHubApiHeaders) -ErrorAction Stop
    $tag = [string]$json.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) { return $null }
    return $tag.Trim()
  } catch {
    return $null
  }
}

function Get-LatestMainCommitRef() {
  try {
    $json = Invoke-RestMethod -Uri (Get-LatestMainRefApiUrl) -Headers (Get-GitHubApiHeaders) -ErrorAction Stop
    $sha = [string]$json.object.sha
    if ([string]::IsNullOrWhiteSpace($sha)) { return $null }
    return $sha.Trim()
  } catch {
    return $null
  }
}

function Get-ResolvedRef() {
  if (Test-HasExplicitRef) { return (Get-RequestedRef) }
  $stable = Get-LatestStableRef
  if (-not [string]::IsNullOrWhiteSpace($stable)) { return $stable }
  $mainCommit = Get-LatestMainCommitRef
  if (-not [string]::IsNullOrWhiteSpace($mainCommit)) { return $mainCommit }
  $fallback = Get-DefaultRef
  Write-Warn "Latest stable release ref unavailable. Falling back to $fallback."
  return $fallback
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
  return (Get-GitHubRawBase (Get-ResolvedRef))
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

function Convert-ToPositiveInt64([object]$Value) {
  $result = 0L
  if ($null -eq $Value) { return 0L }
  if (-not [long]::TryParse(([string]$Value).Trim(), [ref]$result)) { return 0L }
  if ($result -lt 1) { return 0L }
  return $result
}

function Get-ContentLengthHeader($Headers) {
  if ($null -eq $Headers) { return 0L }
  $value = $Headers['Content-Length']
  if ($null -eq $value) { $value = $Headers.'Content-Length' }
  if ($value -is [array]) { $value = $value[-1] }
  return (Convert-ToPositiveInt64 $value)
}

function Get-RemoteFileSize([string]$Url) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  $response = $null
  try {
    $response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -Method Head
  } catch {
    $response = $null
  }
  $size = Get-ContentLengthHeader $response.Headers
  if ($size -gt 0) { return $size }
  try {
    $response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -Method Get
  } catch {
    return 0L
  }
  $size = Convert-ToPositiveInt64 $response.RawContentLength
  if ($size -gt 0) { return $size }
  return (Get-ContentLengthHeader $response.Headers)
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

function Get-FileSize([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0L }
  return (Get-Item -LiteralPath $Path).Length
}

function New-ByteProgressState([long]$TotalBytes, [int]$Width = 20) {
  return @{
    TotalBytes = [Math]::Max(1L, $TotalBytes)
    CurrentBytes = 0L
    Width = [Math]::Max(1, $Width)
    Visible = $false
  }
}

function Get-ByteProgressPercent([hashtable]$State) {
  $value = [int](($State.CurrentBytes * 100) / $State.TotalBytes)
  if ($value -lt 0) { return 0 }
  if ($value -gt 100) { return 100 }
  return $value
}

function Get-ByteProgressFill([hashtable]$State) {
  $fill = [int](([double](Get-ByteProgressPercent $State) / 100) * $State.Width)
  if ($fill -lt 0) { return 0 }
  if ($fill -gt $State.Width) { return $State.Width }
  return $fill
}

function New-BarText([string]$Character, [int]$Count) {
  if ($Count -le 0) { return '' }
  return ($Character * $Count)
}

function Get-ByteProgressLine([hashtable]$State) {
  $fill = Get-ByteProgressFill $State
  $rest = $State.Width - $fill
  $bar = (New-BarText '#' $fill) + (New-BarText '.' $rest)
  return "[{0}] {1}%" -f $bar, (Get-ByteProgressPercent $State)
}

function Add-ByteProgress([hashtable]$State, [long]$Bytes) {
  $next = $State.CurrentBytes + [Math]::Max(0L, $Bytes)
  if ($next -gt $State.TotalBytes) { $next = $State.TotalBytes }
  $State.CurrentBytes = $next
  return $State
}

function Test-ProgressOutputEnabled() {
  if (-not (Get-ShowProgress)) { return $false }
  try { $null = $Host.UI.RawUI; return $true } catch { return $false }
}

function Write-ByteProgress([hashtable]$State) {
  if (-not $script:UseByteProgress) { return }
  Write-Host "`r$(Get-ByteProgressLine $State)" -NoNewline
  $State.Visible = $true
}

function Close-ByteProgress([hashtable]$State) {
  if (-not $script:UseByteProgress) { return }
  if (-not $State.Visible) { return }
  Write-Host ""
  $State.Visible = $false
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

function Get-InstallEntries([hashtable]$Manifest) {
  $files = @()
  foreach ($remote in ($Manifest.Keys | Sort-Object)) {
    $files += @{
      Remote = $remote
      Local = ($remote -replace '/', '\')
      Size = 0L
    }
  }
  return $files
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

function Resolve-EntrySizes([string]$Base, [object[]]$Entries) {
  foreach ($entry in $Entries) {
    $entry.Size = Get-RemoteFileSize "$Base/$($entry.Remote)"
    if ($entry.Size -lt 1) { return $false }
  }
  return $true
}

function Get-DownloadTotalBytes([long]$ManifestSize, [object[]]$Entries) {
  $total = $ManifestSize
  foreach ($entry in $Entries) { $total += $entry.Size }
  return $total
}

function Start-ByteProgress([string]$Base, [string]$ManifestFile, [object[]]$Entries) {
  if (-not $script:UseByteProgress) { return $null }
  $manifestSize = Get-FileSize $ManifestFile
  if ($manifestSize -lt 1) { return $null }
  if (-not (Resolve-EntrySizes $Base $Entries)) {
    $script:UseByteProgress = $false
    Write-Warn 'Progress disabled: could not resolve remote content lengths.'
    return $null
  }
  $state = New-ByteProgressState (Get-DownloadTotalBytes $manifestSize $Entries)
  Write-ByteProgress $state
  Add-ByteProgress $state $manifestSize | Out-Null
  Write-ByteProgress $state
  return $state
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

function Get-MachineInstallDir() {
  return (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI')
}

function Get-InstallCommandCandidates() {
  return @('check-ai-cli.ps1', 'check-ai-cli.cmd', 'check-ai-cli')
}

function Test-InstallHasCommand([string]$Dir) {
  $binDir = Join-Path $Dir 'bin'
  foreach ($name in (Get-InstallCommandCandidates)) {
    if (Test-Path -LiteralPath (Join-Path $binDir $name)) { return $true }
  }
  return $false
}

function Warn-ShadowedCurrentUserInstall([string]$Dir, [string]$Scope) {
  if ($Scope -ne 'CurrentUser') { return }
  if (Test-IsUnderProgramFiles $Dir) { return }
  $machineDir = Get-MachineInstallDir
  if ((Normalize-Dir $machineDir).ToLowerInvariant() -eq (Normalize-Dir $Dir).ToLowerInvariant()) { return }
  if (-not (Test-InstallHasCommand $machineDir)) { return }
  Write-Warn "Detected another Check-AI-CLI install at: $machineDir"
  Write-Warn 'A machine-wide install may still resolve before this CurrentUser install in new PowerShell sessions.'
  Write-Warn 'Fix: rerun the installer as Administrator to update the machine-wide copy, or uninstall the older Program Files install.'
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
  Write-Host "  Set `$env:CHECK_AI_CLI_SHOW_PROGRESS = '1' to view byte progress."
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
    $files = Get-InstallEntries $manifest
    $progress = Start-ByteProgress $base $manifestFile $files

    foreach ($f in $files) {
      if (-not $progress) { Write-Info "Downloading: $($f.Remote)" }
      $staged = Stage-OneFile $base $stage $f
      Verify-FileHash $manifest $f.Remote $staged
      if ($progress) {
        Add-ByteProgress $progress (Get-FileSize $staged) | Out-Null
        Write-ByteProgress $progress
      }
    }
    if ($progress) { Close-ByteProgress $progress }
    Deploy-All $stage $Dir $files
  } finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }

  $binDir = Join-Path $Dir 'bin'
  Add-ToPath $binDir $Scope
  Write-Success "Installed to: $Dir"
  Print-NextSteps $Dir
  Warn-ShadowedCurrentUserInstall $Dir $Scope
  Print-ChinaTip
  if ($Run) { & (Join-Path $Dir 'bin\check-ai-cli.ps1') }
}

function Get-ShowProgress() {
  $v = $env:CHECK_AI_CLI_SHOW_PROGRESS
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-SkipMain() {
  $v = $env:CHECK_AI_CLI_SKIP_MAIN
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

function Invoke-InstallerMain() {
  $installDir = Get-InstallDir
  $pathScope = Get-PathScope
  $runAfter = Get-RunFlag

  try {
    if (Test-IsUnderProgramFiles $installDir) { Require-Admin "writing to Program Files: $installDir" }
    if ($pathScope -eq 'Machine') { Require-Admin "updating Machine PATH" }

    Require-WebRequest
    $script:UseByteProgress = Test-ProgressOutputEnabled
    Set-ProgressMode 'SilentlyContinue'
    Ensure-Directory $installDir
    Install-All $installDir $pathScope $runAfter
  } catch {
    if ($script:UseByteProgress) { Write-Host "" }
    Write-Fail $_.Exception.Message
    Print-AdminHint
    Print-ChinaTip
    exit 1
  } finally {
    Restore-Progress
  }
}

if (-not (Get-SkipMain)) {
  Invoke-InstallerMain
}
