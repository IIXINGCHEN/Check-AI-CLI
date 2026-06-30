param(
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DistributionFiles.ps1')

# Auto-generate checksums.sha256 to avoid manual mistakes
# Usage:
# - Generate and write file: .\tools\Update-Checksums.ps1
# - Check only: .\tools\Update-Checksums.ps1 -Check

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Test-GitAvailable() {
  return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Get-RepoRoot() {
  $packageRoot = Split-Path -Parent $PSScriptRoot
  if (Test-GitAvailable) {
    $root = (git rev-parse --show-toplevel 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($root)) {
      $gitRoot = $root.Trim()
      # Release payloads may be unpacked inside a parent git repository. Only use
      # git-index hashing when this script's package root is the actual repo root.
      if ([IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/') -eq [IO.Path]::GetFullPath($packageRoot).TrimEnd('\','/')) {
        $script:UseGitIndexForChecksums = $true
        return $gitRoot
      }
    }
  }
  $script:UseGitIndexForChecksums = $false
  return $packageRoot
}

function Get-TargetPaths() {
  return @(Get-ChecksumTargetPaths)
}

function Get-UnstagedTargetChanges([string[]]$Paths) {
  if (-not $Paths -or $Paths.Count -eq 0) { return @() }
  $changed = (& git diff --name-only -- @Paths 2>$null)
  return @($changed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Assert-NoUnstagedTargetChanges([string[]]$Paths) {
  $changed = Get-UnstagedTargetChanges $Paths
  if ($changed.Count -eq 0) { return }
  $list = ($changed -join ', ')
  throw "Target files have unstaged changes: $list. Run git add for changed target files before updating checksums."
}

function Get-BlobSha([string]$Path) {
  $sha = (git rev-parse ":$Path" 2>$null)
  if ([string]::IsNullOrWhiteSpace($sha)) { throw "Missing in index: $Path" }
  return $sha.Trim()
}

function Write-BlobToFile([string]$Sha, [string]$OutFile) {
  $outDir = Split-Path -Parent $OutFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
  $cmd = "git cat-file -p $Sha > `"$OutFile`""
  cmd /c $cmd | Out-Null
}

function Get-Sha256FromFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Missing file: $Path" }
  $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($getFileHash) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
  $out = certutil -hashfile $Path SHA256
  $hash = ($out | Select-Object -Skip 1 -First 1) -replace '\s',''
  if ([string]::IsNullOrWhiteSpace($hash)) { throw "Failed to hash: $Path" }
  return $hash.ToLowerInvariant()
}

function Get-Sha256FromIndex([string]$Path) {
  $sha = Get-BlobSha $Path
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-" + [Guid]::NewGuid().ToString('N') + ".tmp")
  try {
    Write-BlobToFile $sha $tmp
    return Get-Sha256FromFile $tmp
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Get-Sha256ForTarget([string]$Path) {
  if ($script:UseGitIndexForChecksums) { return Get-Sha256FromIndex $Path }
  return Get-Sha256FromFile (Join-Path (Get-Location) $Path)
}

function Render-Manifest([string[]]$Paths) {
  $lines = @()
  $lines += "# SHA256 checksums for Check-AI-CLI"
  $lines += "# Format: <sha256>  <relative-path>"
  foreach ($p in $Paths) {
    $hash = Get-Sha256ForTarget $p
    $lines += "$hash  $p"
  }
  return ($lines -join "`n") + "`n"
}

function Write-Utf8NoBomLf([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Read-FileText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return [IO.File]::ReadAllText($Path)
}

function Main() {
  $root = Get-RepoRoot
  Set-Location $root

  $paths = Get-TargetPaths
  if (-not $paths -or $paths.Count -eq 0) { throw "No target files found." }
  if ($script:UseGitIndexForChecksums) { Assert-NoUnstagedTargetChanges $paths }

  $content = Render-Manifest $paths
  $outFile = Join-Path $root 'checksums.sha256'

  if ($Check) {
    $current = Read-FileText $outFile
    if ($current -eq $content) { Write-Success "checksums.sha256 OK"; return }
    Write-Fail "checksums.sha256 mismatch. Run: .\\tools\\Update-Checksums.ps1"
    exit 1
  }

  Write-Info "Writing: checksums.sha256"
  Write-Utf8NoBomLf $outFile $content
  Write-Success "Updated: checksums.sha256"
  Write-Host "Next: git add checksums.sha256"
}

Main
