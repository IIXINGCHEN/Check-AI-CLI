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
    Set-Location $temp
    git init | Out-Null
    Set-Content -Path 'install.ps1' -Value 'old'
    git add install.ps1 tools/Update-Checksums.ps1
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

Write-Host '[PASS] All checksum tool regression tests passed.' -ForegroundColor Green
