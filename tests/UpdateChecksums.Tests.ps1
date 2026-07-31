$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hostExe = (Get-Process -Id $PID).Path

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
  if (-not $Text.Contains($Expected)) {
    throw "$Message`nExpected substring: $Expected`nActual: $Text"
  }
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    Write-Host "[PASS] $Name" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    throw
  }
}

function New-ChecksumFixture() {
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-checksum-test-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $temp 'tools') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/Update-Checksums.ps1') -Destination (Join-Path $temp 'tools/Update-Checksums.ps1')
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/DistributionFiles.ps1') -Destination (Join-Path $temp 'tools/DistributionFiles.ps1')
  Set-Location $temp
  git init | Out-Null
  # Disable text normalization so the index blob bytes stay identical to worktree bytes.
  [IO.File]::WriteAllText((Join-Path $temp '.gitattributes'), "* -text`n")
  [IO.File]::WriteAllText((Join-Path $temp 'distribution-files.txt'), "distribution-files.txt`ninstall.ps1`n")
  # Mixed line endings guard byte-exact hashing on every platform.
  [IO.File]::WriteAllText((Join-Path $temp 'install.ps1'), "line-crlf`r`nline-lf`nno-trailing-eol")
  git add .gitattributes distribution-files.txt install.ps1 tools/DistributionFiles.ps1 tools/Update-Checksums.ps1
  return $temp
}

function Invoke-ChecksumTool([string[]]$ToolArgs) {
  # Windows PowerShell 5.1 turns redirected native stderr into terminating errors
  # under EAP Stop; relax it around the child invocation only.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File './tools/Update-Checksums.ps1' @ToolArgs 2>&1
    return @{ ExitCode = $LASTEXITCODE; Text = ($output | Out-String) }
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

Run-Test 'Generate writes index-based manifest matching worktree bytes' {
  $temp = New-ChecksumFixture
  try {
    $result = Invoke-ChecksumTool @()
    Assert-True ($result.ExitCode -eq 0) "Expected generator to succeed.`n$($result.Text)"
    $manifest = [IO.File]::ReadAllText((Join-Path $temp 'checksums.sha256'))
    $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $temp 'install.ps1')).Hash.ToLowerInvariant()
    Assert-Contains $manifest "$expected  install.ps1" 'Manifest hash must equal the staged blob bytes.'

    $check = Invoke-ChecksumTool @('-Check')
    Assert-True ($check.ExitCode -eq 0) "Expected -Check to pass on a fresh manifest.`n$($check.Text)"
  } finally {
    Set-Location $repoRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Run-Test 'Check fails when staged payload changed after manifest generation' {
  $temp = New-ChecksumFixture
  try {
    $result = Invoke-ChecksumTool @()
    Assert-True ($result.ExitCode -eq 0) "Expected generator to succeed.`n$($result.Text)"
    [IO.File]::WriteAllText((Join-Path $temp 'install.ps1'), "tampered`n")
    git add install.ps1
    $check = Invoke-ChecksumTool @('-Check')
    Assert-True ($check.ExitCode -ne 0) "Expected -Check to fail after payload change.`n$($check.Text)"
    Assert-Contains $check.Text 'checksums.sha256 mismatch' 'Expected mismatch diagnostics.'
  } finally {
    Set-Location $repoRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Run-Test 'Update-Checksums fails when target files have unstaged changes' {
  $temp = New-ChecksumFixture
  try {
    [IO.File]::WriteAllText((Join-Path $temp 'install.ps1'), "unstaged-change`n")
    $result = Invoke-ChecksumTool @()
    Assert-True ($result.ExitCode -ne 0) "Expected Update-Checksums.ps1 to fail for unstaged target changes.`n$($result.Text)"
    Assert-Contains $result.Text 'Target files have unstaged changes: install.ps1' 'Expected checksum tool to explain stale-index risk.'
  } finally {
    Set-Location $repoRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host '[PASS] All checksum tool regression tests passed.' -ForegroundColor Green
