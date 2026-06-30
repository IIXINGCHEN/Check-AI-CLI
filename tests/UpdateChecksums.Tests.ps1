$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

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

Run-Test 'Update-Checksums fails when target files have unstaged changes' {
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-checksum-test-" + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $temp 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/Update-Checksums.ps1') -Destination (Join-Path $temp 'tools/Update-Checksums.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/DistributionFiles.ps1') -Destination (Join-Path $temp 'tools/DistributionFiles.ps1')
    Set-Location $temp
    git init | Out-Null
    Set-Content -Path 'distribution-files.txt' -Value @('distribution-files.txt', 'install.ps1')
    Set-Content -Path 'install.ps1' -Value 'old'
    git add distribution-files.txt install.ps1 tools/DistributionFiles.ps1 tools/Update-Checksums.ps1
    Set-Content -Path 'install.ps1' -Value 'new'

    $output = & $pwsh -NoProfile -File './tools/Update-Checksums.ps1' 2>&1
    $text = ($output | Out-String)

    if ($LASTEXITCODE -eq 0) { throw "Expected Update-Checksums.ps1 to fail for unstaged target changes.`n$text" }
    Assert-Contains $text 'Target files have unstaged changes: install.ps1' 'Expected checksum tool to explain stale-index risk.'
  } finally {
    Set-Location $repoRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}



Run-Test 'Update-Checksums -Check works outside a git repository' {
  $parent = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-checksum-parent-git-test-" + [Guid]::NewGuid().ToString('N'))
  $temp = Join-Path $parent 'payload'
  try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    Set-Location $parent
    git init | Out-Null
    Set-Location $temp
    New-Item -ItemType Directory -Path (Join-Path $temp 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/Update-Checksums.ps1') -Destination (Join-Path $temp 'tools/Update-Checksums.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/DistributionFiles.ps1') -Destination (Join-Path $temp 'tools/DistributionFiles.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'distribution-files.txt') -Destination (Join-Path $temp 'distribution-files.txt')
    foreach ($path in @('install.ps1','install.sh','uninstall.ps1','uninstall.sh')) {
      Copy-Item -LiteralPath (Join-Path $repoRoot $path) -Destination (Join-Path $temp $path)
    }
    New-Item -ItemType Directory -Path (Join-Path $temp 'bin') | Out-Null
    foreach ($path in @('bin/check-ai-cli','bin/check-ai-cli.cmd','bin/check-ai-cli.ps1')) {
      Copy-Item -LiteralPath (Join-Path $repoRoot $path) -Destination (Join-Path $temp $path)
    }
    New-Item -ItemType Directory -Path (Join-Path $temp 'scripts') | Out-Null
    foreach ($path in @('scripts/Check-AI-CLI-Versions.ps1','scripts/check-ai-cli-versions.sh')) {
      Copy-Item -LiteralPath (Join-Path $repoRoot $path) -Destination (Join-Path $temp $path)
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools/PSModulePath.ps1') -Destination (Join-Path $temp 'tools/PSModulePath.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'checksums.sha256') -Destination (Join-Path $temp 'checksums.sha256')

    $output = & $pwsh -NoProfile -File './tools/Update-Checksums.ps1' -Check 2>&1
    $text = ($output | Out-String)

    if ($LASTEXITCODE -ne 0) { throw "Expected Update-Checksums.ps1 -Check to work outside git, even inside a parent git repository.`n$text" }
    Assert-Contains $text 'checksums.sha256 OK' 'Expected non-git checksum check to validate the release payload.'
  } finally {
    Set-Location $repoRoot
    Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host '[PASS] All checksum tool regression tests passed.' -ForegroundColor Green
