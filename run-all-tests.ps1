$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$testsDir = Join-Path $repoRoot 'tests'

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
$powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue

if (-not $pwsh -and -not $powershell) {
  Write-Host "ERROR: Neither pwsh nor powershell.exe found." -ForegroundColor Red
  exit 1
}

$runner = if ($pwsh) { $pwsh.Source } else { $powershell.Source }
$runnerLabel = if ($pwsh) { "pwsh" } else { "powershell" }
Write-Host "Test runner: $runnerLabel ($runner)" -ForegroundColor Cyan

$testFiles = Get-ChildItem -Path $testsDir -Filter '*.Tests.ps1' | Sort-Object Name
Write-Host "Found $($testFiles.Count) PowerShell test file(s).`n" -ForegroundColor Cyan

$failed = @()
$passed = @()

foreach ($testFile in $testFiles) {
  $label = $testFile.Name
  Write-Host "=== $label ===" -ForegroundColor Yellow
  $output = & $runner -NoProfile -ExecutionPolicy Bypass -File $testFile.FullName 2>&1
  $exitCode = $LASTEXITCODE
  if ($output) { Write-Host ($output -join "`n") }
  if ($exitCode -ne 0) {
    Write-Host "FAIL: $label (exit code $exitCode)" -ForegroundColor Red
    $failed += $label
  } else {
    Write-Host "PASS: $label" -ForegroundColor Green
    $passed += $label
  }
  Write-Host ''
}

Write-Host "==========================================="
Write-Host "Results: $($passed.Count) passed, $($failed.Count) failed" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
  Write-Host "`nFailed tests:" -ForegroundColor Red
  foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Red }
  exit 1
}

Write-Host "All tests passed." -ForegroundColor Green
