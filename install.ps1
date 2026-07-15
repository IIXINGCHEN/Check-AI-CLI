param(
  # Explicit machine-wide install: Program Files + Machine PATH.
  # Never the default. If the current process is not elevated, local install.ps1
  # may re-launch itself once via UAC (-Verb RunAs). irm|iex mode will not
  # auto-elevate; it prints an admin command instead.
  [switch]$Machine,

  # Explicit current-user install (default). Useful to force user scope even in
  # an already-elevated shell.
  [switch]$CurrentUser
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 on older Windows may not negotiate TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# This script supports "irm ... | iex" one-liner install/update for this repo's files
# Defaults (safe):
# - Install dir: %LOCALAPPDATA%\Programs\Tools\Check-AI-CLI
# - PATH scope: CurrentUser
# - No automatic admin elevation
# Machine-wide install is opt-in only: -Machine or CHECK_AI_CLI_PATH_SCOPE=Machine
# Env vars:
# - CHECK_AI_CLI_REF: pin tag/commit/main; default latest stable release, else latest main commit, fallback main
# - CHECK_AI_CLI_RAW_BASE: raw base URL (mirror)
# - CHECK_AI_CLI_INSTALL_DIR: install directory override
# - CHECK_AI_CLI_PATH_SCOPE: CurrentUser or Machine
# - CHECK_AI_CLI_RUN: set to 1 to run after install
# - CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256: optional out-of-band manifest pin
# - CHECK_AI_CLI_ELEVATION_DONE: internal re-entry marker after UAC

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
    if (-not (Test-IsReleaseTag $tag)) { return $null }
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

function Test-IsCommitSha([string]$Ref) {
  return (-not [string]::IsNullOrWhiteSpace($Ref)) -and ($Ref -match '^[a-fA-F0-9]{40}$')
}

function Test-IsReleaseTag([string]$Ref) {
  return (-not [string]::IsNullOrWhiteSpace($Ref)) -and ($Ref -match '^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$')
}

function Get-ResolvedRef() {
  if (Test-HasExplicitRef) {
    $requested = Get-RequestedRef
    if (Test-IsCommitSha $requested) { return $requested.ToLowerInvariant() }
    if (Test-IsReleaseTag $requested) { return $requested }
    if ($requested -eq 'main') {
      $mainCommit = Get-LatestMainCommitRef
      if (-not [string]::IsNullOrWhiteSpace($mainCommit)) { return $mainCommit }
      throw 'Failed to resolve CHECK_AI_CLI_REF=main to an immutable commit SHA.'
    }
    throw "CHECK_AI_CLI_REF must be a semantic-version tag, a 40-character commit SHA, or main: $requested"
  }

  $stable = Get-LatestStableRef
  if (-not [string]::IsNullOrWhiteSpace($stable)) { return $stable }
  $mainCommit = Get-LatestMainCommitRef
  if (-not [string]::IsNullOrWhiteSpace($mainCommit)) { return $mainCommit }
  throw 'Failed to resolve an immutable release tag or main commit. Refusing mutable main fallback.'
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

function Get-CurrentUserInstallDir() {
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Tools\Check-AI-CLI')
  }
  return (Join-Path $localAppData 'Programs\Tools\Check-AI-CLI')
}

function Get-MachineInstallDir() {
  return (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tools\Check-AI-CLI')
}

function Test-MachineInstallRequested() {
  # Explicit -CurrentUser always wins over ambient admin privileges.
  if ($CurrentUser) { return $false }
  if ($Machine) { return $true }

  $scope = $env:CHECK_AI_CLI_PATH_SCOPE
  if (-not [string]::IsNullOrWhiteSpace($scope) -and $scope.Trim() -eq 'Machine') { return $true }

  $installScope = $env:CHECK_AI_CLI_INSTALL_SCOPE
  if (-not [string]::IsNullOrWhiteSpace($installScope) -and $installScope.Trim() -eq 'Machine') { return $true }

  # Explicit Program Files install dir counts as machine-wide intent.
  $envDir = $env:CHECK_AI_CLI_INSTALL_DIR
  if (-not [string]::IsNullOrWhiteSpace($envDir) -and (Test-IsUnderProgramFiles $envDir)) { return $true }

  return $false
}

function Get-InstallDir() {
  $envDir = $env:CHECK_AI_CLI_INSTALL_DIR
  if (-not [string]::IsNullOrWhiteSpace($envDir)) { return $envDir }

  # Safe default: CurrentUser even when the shell is already elevated.
  # Machine-wide Program Files install is opt-in only (-Machine / env scope).
  if (Test-MachineInstallRequested) { return (Get-MachineInstallDir) }
  return (Get-CurrentUserInstallDir)
}

function Get-PathScope() {
  $installDir = Get-InstallDir
  # Program Files payload always owns Machine PATH. Reject mixed intent where
  # files go under PF but PATH_SCOPE is CurrentUser.
  if (Test-IsUnderProgramFiles $installDir) {
    if ($CurrentUser) {
      throw 'Cannot combine a Program Files install directory with -CurrentUser. Use -Machine or a CurrentUser install directory.'
    }
    $s = $env:CHECK_AI_CLI_PATH_SCOPE
    if (-not [string]::IsNullOrWhiteSpace($s) -and $s.Trim() -eq 'CurrentUser') {
      throw 'Cannot combine CHECK_AI_CLI_INSTALL_DIR under Program Files with CHECK_AI_CLI_PATH_SCOPE=CurrentUser. Use Machine scope or a user install directory.'
    }
    return 'Machine'
  }

  # Explicit switches win over ambient env/admin state.
  if ($CurrentUser) { return 'CurrentUser' }
  if ($Machine) { return 'Machine' }

  $s = $env:CHECK_AI_CLI_PATH_SCOPE
  if (-not [string]::IsNullOrWhiteSpace($s)) {
    $t = $s.Trim()
    if ($t -ne 'Machine' -and $t -ne 'CurrentUser') {
      throw 'CHECK_AI_CLI_PATH_SCOPE must be Machine or CurrentUser.'
    }
    return $t
  }

  if (Test-MachineInstallRequested) { return 'Machine' }
  return 'CurrentUser'
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
  if ([string]::IsNullOrWhiteSpace($pf) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
  $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  return $candidate.Equals($pf, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Require-Admin([string]$Reason) {
  if (Test-IsAdmin) { return }
  throw "Administrator required: $Reason"
}

function Test-NeedsAdminForInstall([string]$Dir, [string]$Scope) {
  if ($Scope -eq 'Machine') { return $true }
  if (Test-IsUnderProgramFiles $Dir) { return $true }
  return $false
}

function Test-ElevationAlreadyAttempted() {
  $v = $env:CHECK_AI_CLI_ELEVATION_DONE
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Get-ElevationPreservedEnvNames() {
  return @(
    'CHECK_AI_CLI_REF',
    'CHECK_AI_CLI_RAW_BASE',
    'CHECK_AI_CLI_INSTALL_DIR',
    'CHECK_AI_CLI_PATH_SCOPE',
    'CHECK_AI_CLI_INSTALL_SCOPE',
    'CHECK_AI_CLI_RUN',
    'CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256',
    'CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'NO_PROXY'
  )
}

function Test-SafeElevationEnvValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  # Reject values that would break a single-quoted PowerShell assignment across lines.
  if ($Value.Contains([char]10) -or $Value.Contains([char]13)) { return $false }
  return $true
}

# Build a temp -File bootstrap instead of a single -Command string. Joining
# env assignments with ';' breaks when proxy/base values contain ';'.
function New-ElevatedInstallBootstrap([string]$ScriptPath) {
  $bootstrap = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-elevate-" + [Guid]::NewGuid().ToString('N') + '.ps1')
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("`$ErrorActionPreference = 'Stop'")
  $lines.Add("`$env:CHECK_AI_CLI_ELEVATION_DONE = '1'")

  # Force machine scope in the elevated re-entry even if the caller only used -Machine.
  if ([string]::IsNullOrWhiteSpace($env:CHECK_AI_CLI_PATH_SCOPE)) {
    $lines.Add("`$env:CHECK_AI_CLI_PATH_SCOPE = 'Machine'")
  }

  foreach ($name in (Get-ElevationPreservedEnvNames)) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not (Test-SafeElevationEnvValue $value)) { continue }
    $escaped = $value.Replace("'", "''")
    $lines.Add("`$env:$name = '$escaped'")
  }

  $scriptEscaped = $ScriptPath.Replace("'", "''")
  $lines.Add("& '$scriptEscaped' -Machine")
  $lines.Add('exit $LASTEXITCODE')

  $enc = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($bootstrap, (($lines -join "`r`n") + "`r`n"), $enc)
  return $bootstrap
}

function Request-ElevatedInstall([string]$Reason) {
  if (Test-ElevationAlreadyAttempted) {
    throw "Administrator required after elevation re-entry: $Reason"
  }

  # irm|iex has no durable script path. Refuse silent elevation there so users
  # consciously start an elevated shell instead of approving a temp payload.
  if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw "Administrator required: $Reason. Re-run in elevated PowerShell with -Machine, or run a local install.ps1 -Machine from a cloned/extracted payload."
  }

  $scriptPath = Join-Path $PSScriptRoot 'install.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Administrator required: $Reason. install.ps1 not found for elevation: $scriptPath"
  }

  Write-Warn "Administrator privileges required: $Reason"
  Write-Info 'Requesting elevation via UAC for machine-wide install only...'
  Write-Info 'Default CurrentUser installs never auto-elevate.'

  $bootstrap = New-ElevatedInstallBootstrap $scriptPath
  try {
    $hostExe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    $proc = Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap) -Wait -PassThru
    if ($null -eq $proc.ExitCode) { exit 1 }
    exit $proc.ExitCode
  } finally {
    if (Test-Path -LiteralPath $bootstrap) {
      Remove-Item -LiteralPath $bootstrap -Force -ErrorAction SilentlyContinue
    }
  }
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

function Invoke-WithTempProgressPreference([string]$Mode, [scriptblock]$Action) {
  $prev = $ProgressPreference
  $ProgressPreference = $Mode
  try { & $Action } finally { $ProgressPreference = $prev }
}

function Download-ToFile([string]$Url, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'check-ai-cli-installer' }
  # Let PowerShell render its native Write-Progress while downloading.
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

function Get-ManifestRemotePath() { return 'checksums.sha256' }

function Get-DistributionListRemotePath() { return 'distribution-files.txt' }

function Get-ExpectedManifestSha256() {
  $value = $env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  $normalized = $value.Trim().ToLowerInvariant()
  if ($normalized -notmatch '^[a-f0-9]{64}$') {
    throw 'CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 must contain exactly 64 hexadecimal characters.'
  }
  return $normalized
}

function Assert-ManifestAnchor([string]$ManifestFile) {
  $expected = Get-ExpectedManifestSha256
  if (-not $expected) { return }
  $actual = Get-Sha256 $ManifestFile
  if ($actual -ne $expected) { throw 'checksums.sha256 does not match CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256.' }
  Write-Success 'Manifest SHA-256 pin verified.'
}

function Assert-SafeDistributionPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Distribution path is empty.' }
  if ([IO.Path]::IsPathRooted($Path) -or $Path.Contains('\') -or $Path.Contains(':')) {
    throw "Invalid distribution path: $Path"
  }
  foreach ($segment in @($Path -split '/')) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
      throw "Invalid distribution path: $Path"
    }
  }
  return $Path
}

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
  $response = $null
  Invoke-WithTempProgressPreference 'SilentlyContinue' {
    $response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing
  }
  return $response.Content
}

function Read-Manifest([string]$Text) {
  $map = @{}
  foreach ($line in @($Text -split "`n")) {
    $t = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    if ($t.StartsWith('#')) { continue }
    $parts = $t -split '\s+', 2
    if ($parts.Count -ne 2) { throw "Malformed checksum manifest line: $t" }
    $hash = $parts[0].Trim().ToLowerInvariant()
    $path = $parts[1].Trim()
    if ($hash -notmatch '^[a-f0-9]{64}$') { throw "Invalid SHA-256 in checksum manifest: $path" }
    [void](Assert-SafeDistributionPath $path)
    if ($map.ContainsKey($path)) {
      if ($map[$path] -ne $hash) { throw "Conflicting checksum entries for: $path" }
      throw "Duplicate checksum entry for: $path"
    }
    $map[$path] = $hash
  }
  if ($map.Count -eq 0) { throw 'Checksum manifest has no entries.' }
  return $map
}

function Read-DistributionFileList([string]$Text) {
  $paths = @()
  $seen = @{}
  foreach ($line in @($Text -split "`n")) {
    $t = ($line -replace '#.*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    [void](Assert-SafeDistributionPath $t)
    if ($seen.ContainsKey($t)) { throw "Duplicate distribution path: $t" }
    $seen[$t] = $true
    $paths += $t
  }
  return $paths
}

function Get-InstallEntries([string[]]$Paths) {
  $files = @()
  foreach ($remote in $Paths) {
    $files += @{
      Remote = $remote
      Local = ($remote -replace '/', '\')
      Size = 0L
    }
  }
  return $files
}

function Get-LocalPayloadRoot() {
  # When install.ps1 is executed from an extracted release ZIP, install from the
  # local, already-downloaded payload instead of fetching main/latest from
  # GitHub. In irm|iex mode $PSScriptRoot is empty, so this returns $null and the
  # normal remote installer path is used.
  if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $null }
  $root = $PSScriptRoot
  $manifest = Join-Path $root (Get-ManifestRemotePath)
  $distribution = Join-Path $root (Get-DistributionListRemotePath)
  if (-not (Test-Path -LiteralPath $manifest)) { return $null }
  if (-not (Test-Path -LiteralPath $distribution)) { return $null }
  return $root
}

function Test-LocalPayloadComplete([string]$Root, [object[]]$Entries) {
  foreach ($e in $Entries) {
    $p = Join-Path $Root $e.Local
    if (-not (Test-Path -LiteralPath $p)) { return $false }
  }
  return $true
}

function Install-AllFromLocalPayload([string]$PayloadRoot, [string]$Dir, [string]$Scope, [bool]$Run) {
  Write-Info "Installing from local payload: $PayloadRoot"

  $manifestFile = Join-Path $PayloadRoot (Get-ManifestRemotePath)
  Assert-ManifestAnchor $manifestFile
  $manifestText = Get-Content -Raw -LiteralPath $manifestFile
  if ([string]::IsNullOrWhiteSpace($manifestText)) { throw "Local checksums.sha256 is empty" }
  $manifest = Read-Manifest $manifestText

  $listRemote = Get-DistributionListRemotePath
  $listFile = Join-Path $PayloadRoot ($listRemote -replace '/', '\')
  Verify-FileHash $manifest $listRemote $listFile
  $distributionText = Get-Content -Raw -LiteralPath $listFile
  $files = Get-InstallEntries (Read-DistributionFileList $distributionText)

  if (-not (Test-LocalPayloadComplete $PayloadRoot $files)) {
    throw 'Local release payload is incomplete. Re-extract the ZIP or use the remote installer.'
  }

  foreach ($f in $files) {
    $localFile = Join-Path $PayloadRoot $f.Local
    Verify-FileHash $manifest $f.Remote $localFile
  }

  Write-InstallMarker $Dir
  Deploy-All $PayloadRoot $Dir $files
  $binDir = Join-Path $Dir 'bin'
  Add-ToPath $binDir $Scope
  Write-Success "Installed to: $Dir"
  Print-NextSteps $Dir
  Warn-ShadowedCurrentUserInstall $Dir $Scope
  Print-ChinaTip
  if ($Run) { & (Join-Path $Dir 'bin\check-ai-cli.ps1') }
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
  try {
    Copy-Item -LiteralPath $StageFile -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $TargetFile -Force
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Write-InstallMarker([string]$Dir) {
  $marker = Join-Path $Dir '.check-ai-cli-installed'
  [IO.File]::WriteAllText($marker, "Check-AI-CLI`n", [Text.Encoding]::ASCII)
}

function Deploy-All([string]$StageDir, [string]$InstallDir, [object[]]$Entries) {
  $rollbackDir = New-StagingDir
  $records = @()
  try {
    foreach ($e in $Entries) {
      $src = Join-Path $StageDir $e.Local
      $dst = Join-Path $InstallDir $e.Local
      $exists = Test-Path -LiteralPath $dst
      $backup = Join-Path $rollbackDir ([Guid]::NewGuid().ToString('N'))
      $records += @{ Target = $dst; Exists = $exists; Backup = $backup }
      if ($exists) { Copy-Item -LiteralPath $dst -Destination $backup -Force -ErrorAction Stop }
      Deploy-OneFile $src $dst
    }
  } catch {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      $record = $records[$i]
      try {
        if ($record.Exists) {
          Copy-Item -LiteralPath $record.Backup -Destination $record.Target -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $record.Target) {
          Remove-Item -LiteralPath $record.Target -Force -ErrorAction SilentlyContinue
        }
      } catch { }
    }
    throw
  } finally {
    if (Test-Path -LiteralPath $rollbackDir) { Remove-Item -LiteralPath $rollbackDir -Recurse -Force -ErrorAction SilentlyContinue }
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
  if ($Dir.Contains(';') -or $Dir -match '[\r\n]') {
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
  $newPath = if ([string]::IsNullOrWhiteSpace($current)) { $normalized } else { "$current;$normalized" }
  Set-EnvValue 'Path' $newPath $Scope
  $env:Path = $newPath
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
  $cmdPath = Join-Path $Dir 'bin\check-ai-cli.cmd'
  $uninstallCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -ProgramFiles'
  Write-Warn "Detected another Check-AI-CLI install at: $machineDir"
  Write-Warn 'New PowerShell sessions may still launch the older Program Files copy before this CurrentUser install.'
  Write-Warn "Recovery option 1: run $cmdPath directly"
  Write-Warn 'Recovery option 2: rerun install.ps1 as Administrator to update the machine-wide copy'
  Write-Warn "Recovery option 3: in elevated PowerShell, uninstall only the Program Files copy with: $uninstallCmd"
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
  Write-Host "  Set `$env:CHECK_AI_CLI_REF to pin a tag/commit; main is resolved to a commit SHA."
  Write-Host "  Set `$env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 for out-of-band manifest pinning."
  Write-Host "  Set `$env:CHECK_AI_CLI_RAW_BASE only if you trust the mirror."
  Write-Host "  Set `$env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR = '1' to bypass mirror check."
  Write-Host ""
}

function Get-InstallProgressPercent([int]$Index, [int]$Total) {
  # Outer-bar percent before file $Index downloads; the -1 keeps it below 100 until the set completes.
  return [int](($Index - 1) * 100 / [Math]::Max(1, $Total))
}

function Install-All([string]$Dir, [string]$Scope, [bool]$Run) {
  $localPayloadRoot = Get-LocalPayloadRoot
  if ($localPayloadRoot) {
    Install-AllFromLocalPayload $localPayloadRoot $Dir $Scope $Run
    return
  }

  $base = Get-BaseUrl
  Write-Info "Using immutable release source: $base"
  $stage = New-StagingDir
  try {
    $manifestUrl = "$base/$(Get-ManifestRemotePath)"
    $manifestFile = Join-Path $stage 'checksums.sha256'
    Download-FileWithRetry $manifestUrl $manifestFile
    Assert-ManifestAnchor $manifestFile
    $manifestText = Get-Content -Raw -LiteralPath $manifestFile
    if ([string]::IsNullOrWhiteSpace($manifestText)) { throw "Failed to download checksums.sha256" }
    $manifest = Read-Manifest $manifestText
    $listRemote = Get-DistributionListRemotePath
    $listFile = Join-Path $stage ($listRemote -replace '/', '\')
    Download-FileWithRetry "$base/$listRemote" $listFile
    Verify-FileHash $manifest $listRemote $listFile
    $distributionText = Get-Content -Raw -LiteralPath $listFile
    $files = Get-InstallEntries (Read-DistributionFileList $distributionText)

    $total = $files.Count
    $index = 0
    foreach ($f in $files) {
      $index++
      Write-Progress -Activity 'Installing Check-AI-CLI' `
        -Status "Downloading $($f.Remote) ($index/$total)" `
        -PercentComplete (Get-InstallProgressPercent $index $total)
      $staged = Stage-OneFile $base $stage $f
      Verify-FileHash $manifest $f.Remote $staged
    }
    Write-Progress -Activity 'Installing Check-AI-CLI' -Status 'Deploying' -PercentComplete 100
    Write-InstallMarker $Dir
    Deploy-All $stage $Dir $files
    Write-Progress -Activity 'Installing Check-AI-CLI' -Completed
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

function Get-SkipMain() {
  $v = $env:CHECK_AI_CLI_SKIP_MAIN
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  return $v.Trim() -eq '1'
}

function Print-AdminHint() {
  Write-Host ""
  Write-Host "Safe default (no admin): CurrentUser install"
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
  Write-Host ""
  Write-Host "Machine-wide install (Program Files + Machine PATH):"
  Write-Host "  # local payload / clone"
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Machine"
  Write-Host "  # already elevated shell + remote one-liner"
  Write-Host "  `$env:CHECK_AI_CLI_PATH_SCOPE = 'Machine'"
  Write-Host "  irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex"
  Write-Host ""
  Write-Host "Uninstall machine-wide copy only:"
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -ProgramFiles"
  Write-Host ""
}

function Invoke-InstallerMain() {
  if ($Machine -and $CurrentUser) {
    throw 'Specify only one of -Machine or -CurrentUser.'
  }

  $installDir = Get-InstallDir
  $pathScope = Get-PathScope
  $runAfter = Get-RunFlag

  Write-Info "Install mode: $(if (Test-MachineInstallRequested) { 'Machine' } else { 'CurrentUser' })"
  Write-Info "Install directory: $installDir"
  Write-Info "PATH scope: $pathScope"

  try {
    if ((Test-NeedsAdminForInstall $installDir $pathScope) -and -not (Test-IsAdmin)) {
      # Only machine-wide installs may prompt for elevation. CurrentUser never does.
      Request-ElevatedInstall "writing to '$installDir' and/or updating $pathScope PATH"
      return
    }

    if (Test-IsUnderProgramFiles $installDir) { Require-Admin "writing to Program Files: $installDir" }
    if ($pathScope -eq 'Machine') { Require-Admin "updating Machine PATH" }

    Require-WebRequest
    Ensure-Directory $installDir
    Install-All $installDir $pathScope $runAfter
  } catch {
    Write-Progress -Activity 'Installing Check-AI-CLI' -Completed
    $message = $_.Exception.Message
    Write-Fail $message
    if ($message -like 'Checksum mismatch:*' -or $message -like 'Missing checksum for:*' -or $message -like 'Local release payload is incomplete*') {
      Write-Host ''
      Write-Host 'Local payload integrity verification failed.'
      Write-Host 'Re-extract a trusted release ZIP; do not bypass checksum verification.'
      Write-Host ''
    } else {
      Print-AdminHint
      Print-ChinaTip
    }
    exit 1
  }
}

if (-not (Get-SkipMain)) {
  Invoke-InstallerMain
}
