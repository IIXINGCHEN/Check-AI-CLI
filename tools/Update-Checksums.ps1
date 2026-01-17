param(
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

# Auto-generate checksums.sha256 to avoid manual mistakes
# Usage:
# - Generate and write file: .\tools\Update-Checksums.ps1
# - Check only: .\tools\Update-Checksums.ps1 -Check

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Require-Git() {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { throw "git not found." }
}

function Get-RepoRoot() {
  $root = (git rev-parse --show-toplevel 2>$null)
  if ([string]::IsNullOrWhiteSpace($root)) { throw "Not a git repository." }
  return $root.Trim()
}

function Get-TargetPaths() {
  $paths = @()
  $paths += (git ls-files scripts bin uninstall.ps1 uninstall.sh 2>$null)
  $paths = $paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  return $paths | Sort-Object
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

function Get-Sha256FromIndex([string]$Path) {
  $sha = Get-BlobSha $Path
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-" + [Guid]::NewGuid().ToString('N') + ".tmp")
  try {
    Write-BlobToFile $sha $tmp
    $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
    if ($getFileHash) {
      return (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
    }
    $out = certutil -hashfile $tmp SHA256
    $hash = ($out | Select-Object -Skip 1 -First 1) -replace '\s',''
    if ([string]::IsNullOrWhiteSpace($hash)) { throw "Failed to hash: $Path" }
    return $hash.ToLowerInvariant()
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Render-Manifest([string[]]$Paths) {
  $lines = @()
  $lines += "# SHA256 checksums for Check-AI-CLI"
  $lines += "# Format: <sha256>  <relative-path>"
  foreach ($p in $Paths) {
    $hash = Get-Sha256FromIndex $p
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
  Require-Git
  $root = Get-RepoRoot
  Set-Location $root

  $paths = Get-TargetPaths
  if (-not $paths -or $paths.Count -eq 0) { throw "No target files found." }

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
