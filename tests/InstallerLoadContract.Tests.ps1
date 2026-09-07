$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hostExe = (Get-Process -Id $PID).Path
$installer = Join-Path $repoRoot 'install.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-False([bool]$Condition, [string]$Message) {
  if ($Condition) { throw $Message }
}

function Run-Test([string]$Name, [scriptblock]$Body) {
  & $Body
  Write-Host "[PASS] $Name" -ForegroundColor Green
}

# Regression guard for a3aaff7, which removed live installer functions
# (Download-FileWithRetry and friends) as "dead code". CI had no loadability
# coverage for install.ps1, so the runtime break reached main silently.
# These functions must exist (plus their transitive dependencies) after the
# installer script loads without running its main.
$requiredFunctions = @(
  'Download-ToFile',
  'Download-FileWithRetry',
  'Get-ManifestRemotePath',
  'Get-DistributionListRemotePath',
  'Get-ExpectedManifestSha256',
  'Assert-ManifestAnchor',
  'Assert-SafeDistributionPath',
  'Ensure-ParentDirectory',
  'Get-RetryCount',
  'Get-TempFilePath',
  'Test-NonEmptyFile',
  'Get-Sha256',
  'Ensure-Directory'
)

Run-Test 'Installer dot-sources cleanly and defines every referenced helper' {
  $installerPath = $installer.Replace("'", "''")
  $commandList = ($requiredFunctions | ForEach-Object { "'$_'" }) -join ','
  $probe = "`$env:CHECK_AI_CLI_SKIP_MAIN = '1'; " +
    ". '$installerPath'; " +
    "`$missing = @($commandList) | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) }; " +
    "if (`$missing) { Write-Output ('MISSING=' + (`$missing -join ',')); exit 1 } " +
    "Write-Output 'ALL_PRESENT'; exit 0"
  # Windows PowerShell 5.1 turns redirected native stderr into terminating
  # errors under EAP Stop; relax it around the child capture only.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -Command $probe 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }
  $text = ($output | Out-String)
  Assert-True ($exitCode -eq 0) "Expected installer load probe to succeed (exit $exitCode).`n$text"
  Assert-True ($text.Contains('ALL_PRESENT')) "Expected all functions present.`n$text"
}

Run-Test 'Installer main guard honors CHECK_AI_CLI_SKIP_MAIN' {
  # The installer must not execute Invoke-InstallerMain when the skip flag is
  # set (test harnesses and tools dot-source it); prove no install attempt runs.
  $env:CHECK_AI_CLI_SKIP_MAIN = '1'
  try {
    # Same PS 5.1 redirected-stderr hazard as above.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prevEap
    }
    $text = ($output | Out-String)
    Assert-True ($exitCode -eq 0) "Expected installer to exit 0 under SKIP_MAIN (exit $exitCode).`n$text"
    Assert-False ($text -match 'Install mode') "Installer main must not run under SKIP_MAIN.`n$text"
  } finally {
    Remove-Item Env:\CHECK_AI_CLI_SKIP_MAIN -ErrorAction SilentlyContinue
  }
}

Run-Test 'Installer network calls carry socket timeouts' {
  # Stalled sockets must fail into the retry/fail-closed paths instead of
  # freezing the install (parity with the bash installers' --max-time 30).
  $text = [IO.File]::ReadAllText($installer)
  Assert-True ($text.Contains('TimeoutSec 30 -ErrorAction Stop')) 'Expected metadata Invoke-RestMethod calls to be bounded by -TimeoutSec 30'
  Assert-True ($text.Contains('-TimeoutSec 30 -OutFile')) 'Expected payload Invoke-WebRequest download to be bounded by -TimeoutSec 30'
}

Write-Host 'All InstallerLoadContract tests passed.' -ForegroundColor Green
