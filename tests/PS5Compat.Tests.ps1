$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\DistributionFiles.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
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

# bin/check-ai-cli.cmd invokes the main script via powershell.exe (Windows
# PowerShell 5.1), not pwsh. PS 7+ syntax (ternary `? :`, null-coalescing `??`,
# null-conditional `?.`, pipeline chain `&&`/`||`) is incompatible with PS 5.1
# and fails the entire file at parse time before any code runs. This test
# parses every distributed .ps1 file with the PS 5.1 language parser so the
# test runner (which prefers pwsh) cannot miss a 5.1-only failure.
Run-Test 'Windows PowerShell 5.1 parses every distributed .ps1 file' {
  $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $powershell) {
    Write-Host '[SKIP] powershell.exe not available on this platform.' -ForegroundColor Yellow
    return
  }

  $parseScript = @'
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($env:CHECK_AI_CLI_PS5_PARSE_TARGET, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
      foreach ($e in $errs) {
        '{0}:{1} {2}' -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message
      }
      exit 2
    }
    exit 0
'@

  $psFiles = @(Get-DistributionFilePaths $repoRoot) | Where-Object { $_ -like '*.ps1' }
  Assert-True ($psFiles.Count -gt 0) 'Expected at least one distributed .ps1 file to validate.'

  foreach ($relPath in $psFiles) {
    $fullPath = Join-Path $repoRoot $relPath
    $env:CHECK_AI_CLI_PS5_PARSE_TARGET = $fullPath
    $output = & $powershell.Source -NoProfile -ExecutionPolicy Bypass -Command $parseScript 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 0) "PS 5.1 parse failure for ${relPath} (exit $exitCode):`n$output"
  }

  Remove-Item Env:\CHECK_AI_CLI_PS5_PARSE_TARGET -ErrorAction SilentlyContinue
}

Write-Host '[PASS] All PS 5.1 compatibility tests passed.' -ForegroundColor Green
