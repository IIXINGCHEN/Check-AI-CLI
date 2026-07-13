$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$env:CHECK_AI_CLI_SKIP_MAIN = '1'
. (Join-Path $repoRoot 'uninstall.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-ThrowsContains([scriptblock]$Action, [string]$ExpectedSubstring, [string]$Message) {
  try {
    & $Action
  } catch {
    if (($null -eq $_.Exception.Message) -or (-not $_.Exception.Message.Contains($ExpectedSubstring))) {
      throw "$Message`nExpected substring: $ExpectedSubstring`nActual: $($_.Exception.Message)"
    }
    return
  }
  throw "$Message`nExpected exception containing: $ExpectedSubstring"
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

Run-Test 'Require-InstallMarker does not attempt to overwrite read-only $HOME' {
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-uninstall-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  try {
    Set-Content -LiteralPath (Join-Path $tempRoot '.check-ai-cli-installed') -Value "Check-AI-CLI`n" -Encoding ASCII
    # If the old `$home = ...` bug returns, this call throws:
    # "Cannot overwrite variable HOME because it is read-only or constant."
    Require-InstallMarker $tempRoot
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'Require-InstallMarker refuses the user profile directory without assigning $HOME' {
  Assert-ThrowsContains {
    Require-InstallMarker $env:USERPROFILE
  } 'Refusing to remove the user profile directory' 'Expected user-profile guard to remain active.'
}

Run-Test 'Get-ProgramFilesInstallDir points under Program Files\Tools\Check-AI-CLI' {
  $dir = Get-ProgramFilesInstallDir
  $pf = [Environment]::GetFolderPath('ProgramFiles')
  Assert-True ($dir.StartsWith($pf, [StringComparison]::OrdinalIgnoreCase)) 'Expected Program Files install dir under ProgramFiles.'
  Assert-True ($dir.EndsWith('Tools\Check-AI-CLI') -or $dir.EndsWith('Tools/Check-AI-CLI')) 'Expected canonical Tools\Check-AI-CLI suffix.'
}

Run-Test 'Test-UninstallProgramFilesRequested honors CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES=1' {
  $original = $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES
  try {
    $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES = '1'
    Assert-True (Test-UninstallProgramFilesRequested) 'Expected env flag to request Program Files uninstall.'
    $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES = '0'
    # -ProgramFiles switch is bound at script param time; env-only path should be false here.
    Assert-True (-not (Test-UninstallProgramFilesRequested)) 'Expected env flag 0 to disable Program Files uninstall request.'
  } finally {
    if ($null -eq $original) {
      Remove-Item Env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES -ErrorAction SilentlyContinue
    } else {
      $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES = $original
    }
  }
}

Run-Test 'Get-InstallDir with CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES targets Program Files' {
  $originalFlag = $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES
  $originalDir = $env:CHECK_AI_CLI_INSTALL_DIR
  try {
    Remove-Item Env:CHECK_AI_CLI_INSTALL_DIR -ErrorAction SilentlyContinue
    $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES = '1'
    $dir = Get-InstallDir
    Assert-Equal $dir (Get-ProgramFilesInstallDir) 'Expected Program Files uninstall flag to select the machine-wide install dir.'
  } finally {
    if ($null -eq $originalFlag) {
      Remove-Item Env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES -ErrorAction SilentlyContinue
    } else {
      $env:CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES = $originalFlag
    }
    if ($null -eq $originalDir) {
      Remove-Item Env:CHECK_AI_CLI_INSTALL_DIR -ErrorAction SilentlyContinue
    } else {
      $env:CHECK_AI_CLI_INSTALL_DIR = $originalDir
    }
  }
}

Run-Test 'Remove-PathEntry drops only the matching bin directory' {
  $win = $env:SystemRoot
  $tools = Join-Path $env:SystemDrive 'Tools'
  $pfBin = Join-Path (Get-ProgramFilesInstallDir) 'bin'
  $path = ($win + ';' + $pfBin + ';' + $tools)
  $next = Remove-PathEntry $path $pfBin
  Assert-Equal $next ($win + ';' + $tools) 'Expected only the Program Files bin entry to be removed from PATH.'
}

Write-Host '[PASS] All uninstall regression tests passed.' -ForegroundColor Green
