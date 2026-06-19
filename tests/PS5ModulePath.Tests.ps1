$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\PSModulePath.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual:   $Actual"
  }
}

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

Run-Test 'Get-CleanedPS51ModulePath strips all known PS 7-only paths' {
  $polluted = @(
    'C:\Users\bob\Documents\PowerShell\Modules',
    'C:\Program Files\PowerShell\Modules',
    'c:\program files\windowsapps\microsoft.powershell_7.6.2.0_x64__8wekyb3d8bbwe\Modules',
    'C:\Program Files\WindowsPowerShell\Modules',
    'C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
  ) -join ';'

  $cleaned = Get-CleanedPS51ModulePath $polluted

  $expected = @(
    'C:\Program Files\WindowsPowerShell\Modules',
    'C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
  ) -join ';'

  Assert-Equal $cleaned $expected 'Polluted PS 7 paths must be removed; PS 5.1 paths must be preserved in order.'
}

Run-Test 'Get-CleanedPS51ModulePath leaves a clean PS 5.1 path untouched' {
  $clean = @(
    'C:\Users\bob\Documents\WindowsPowerShell\Modules',
    'C:\Program Files\WindowsPowerShell\Modules',
    'C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
  ) -join ';'

  $cleaned = Get-CleanedPS51ModulePath $clean

  Assert-Equal $cleaned $clean 'Clean PS 5.1 paths (WindowsPowerShell, not PowerShell) must pass through unchanged.'
}

Run-Test 'Get-CleanedPS51ModulePath collapses an all-PS-7 input to empty' {
  $allPs7 = @(
    'C:\Users\bob\Documents\PowerShell\Modules',
    'C:\Program Files\PowerShell\Modules',
    'c:\program files\windowsapps\microsoft.powershell_7.6.2.0_x64__8wekyb3d8bbwe\Modules'
  ) -join ';'

  $cleaned = Get-CleanedPS51ModulePath $allPs7

  Assert-Equal $cleaned '' 'When every entry is PS 7-only, the result must be empty so the caller can decide to fall back to defaults.'
}

Run-Test 'Get-CleanedPS51ModulePath handles empty and whitespace input' {
  Assert-Equal (Get-CleanedPS51ModulePath '') '' 'Empty input must yield empty output.'
  Assert-Equal (Get-CleanedPS51ModulePath '   ') '' 'Whitespace input must yield empty output.'
}

Run-Test 'Get-CleanedPS51ModulePath preserves custom user module paths' {
  $withCustom = @(
    'C:\Users\bob\Documents\PowerShell\Modules',
    'D:\MyTools\Modules',
    'C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
  ) -join ';'

  $cleaned = Get-CleanedPS51ModulePath $withCustom

  Assert-True ($cleaned -like '*D:\MyTools\Modules*') 'Custom user-added paths must be preserved.'
  Assert-True ($cleaned -notlike '*\Documents\PowerShell\Modules*') 'PS 7 user module path must be stripped.'
}

Run-Test 'Get-CleanedPS51ModulePath strips WindowsApps PS 7 store variants only' {
  $paths = @(
    'c:\program files\windowsapps\microsoft.powershell_7.6.2.0_x64__8wekyb3d8bbwe\Modules',
    'c:\program files\windowsapps\microsoft.powershell.preview_7.7.0.0_x64__8wekyb3d8bbwe\Modules'
  ) -join ';'

  $cleaned = Get-CleanedPS51ModulePath $paths

  Assert-Equal $cleaned '' 'Both stable and preview WindowsApps PS 7 store-app module paths must be stripped.'
}

Run-Test 'Get-CleanedPS51ModulePath survives trailing separators and blanks' {
  $noisy = ';C:\Windows\system32\WindowsPowerShell\v1.0\Modules;;'

  $cleaned = Get-CleanedPS51ModulePath $noisy

  Assert-Equal $cleaned 'C:\Windows\system32\WindowsPowerShell\v1.0\Modules' 'Blanks and trailing separators must be elided without losing real entries.'
}

Write-Host '[PASS] All PS 5.1 module-path sanitization tests passed.' -ForegroundColor Green
