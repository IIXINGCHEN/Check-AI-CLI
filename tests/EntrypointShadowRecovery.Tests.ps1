$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
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

function Invoke-PwshSnippet([string]$Script) {
  $output = & pwsh -NoProfile -Command $Script 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($output | Out-String).Trim()
    throw "Snippet failed:`n$text"
  }
  return (($output | Out-String).TrimEnd())
}

function New-ShadowFixture {
  $root = Join-Path ([IO.Path]::GetTempPath()) ("check-ai-cli-shadow-" + [Guid]::NewGuid().ToString('N'))
  $pfRoot = Join-Path $root 'ProgramFiles\Tools\Check-AI-CLI'
  $userRoot = Join-Path $root 'LocalAppData\Programs\Tools\Check-AI-CLI'
  $localAppData = Join-Path $root 'LocalAppData'

  foreach ($dir in @(
    (Join-Path $pfRoot 'bin'),
    (Join-Path $pfRoot 'scripts'),
    (Join-Path $userRoot 'bin'),
    (Join-Path $userRoot 'scripts')
  )) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  Copy-Item -LiteralPath (Join-Path $repoRoot 'bin\check-ai-cli.ps1') -Destination (Join-Path $pfRoot 'bin\check-ai-cli.ps1') -Force
  Set-Content -LiteralPath (Join-Path $userRoot 'bin\check-ai-cli.ps1') -Value "# user entrypoint fixture`r`n" -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $pfRoot 'scripts\Check-AI-CLI-Versions.ps1') -Value "# pf main`r`n" -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $userRoot 'scripts\Check-AI-CLI-Versions.ps1') -Value "# user main`r`n" -Encoding ASCII

  return @{
    Root = $root
    ProgramFilesRoot = $pfRoot
    UserRoot = $userRoot
    LocalAppData = $localAppData
    PfMain = (Join-Path $pfRoot 'scripts\Check-AI-CLI-Versions.ps1')
    UserMain = (Join-Path $userRoot 'scripts\Check-AI-CLI-Versions.ps1')
    UserEntry = (Join-Path $userRoot 'bin\check-ai-cli.ps1')
  }
}

function Invoke-ShadowEntrypoint([hashtable]$Fixture) {
  $script = @"
`$env:CHECK_AI_CLI_TEST_MODE = '1'
`$env:CHECK_AI_CLI_TEST_INSTALL_ROOT = '$($Fixture.ProgramFilesRoot.Replace("'", "''"))'
`$env:LOCALAPPDATA = '$($Fixture.LocalAppData.Replace("'", "''"))'
. '$($Fixture.ProgramFilesRoot.Replace("'", "''"))\bin\check-ai-cli.ps1'
'{0}|{1}' -f `$script:ShadowRecoveryAction, `$script:ShadowRecoveryTarget
"@
  return (Invoke-PwshSnippet $script)
}

Run-Test 'bin/check-ai-cli.ps1 forwards Program Files launch to a fresher CurrentUser install' {
  $fixture = New-ShadowFixture
  try {
    $older = (Get-Date).ToUniversalTime().AddDays(-2)
    $newer = (Get-Date).ToUniversalTime().AddDays(-1)
    [IO.File]::SetLastWriteTimeUtc($fixture.PfMain, $older)
    [IO.File]::SetLastWriteTimeUtc($fixture.UserMain, $newer)

    $result = Invoke-ShadowEntrypoint $fixture

    Assert-Equal $result ("forward|" + $fixture.UserEntry) 'Expected Program Files launch to forward when the CurrentUser main script is strictly newer.'
  } finally {
    if (Test-Path -LiteralPath $fixture.Root) {
      Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'bin/check-ai-cli.ps1 keeps Program Files when CurrentUser install is stale' {
  $fixture = New-ShadowFixture
  try {
    $older = (Get-Date).ToUniversalTime().AddDays(-3)
    $newer = (Get-Date).ToUniversalTime().AddDays(-1)
    [IO.File]::SetLastWriteTimeUtc($fixture.UserMain, $older)
    [IO.File]::SetLastWriteTimeUtc($fixture.PfMain, $newer)

    $result = Invoke-ShadowEntrypoint $fixture

    Assert-Equal $result ("keep-program-files|" + $fixture.PfMain) 'Expected a stale CurrentUser install not to shadow a newer Program Files payload.'
  } finally {
    if (Test-Path -LiteralPath $fixture.Root) {
      Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'bin/check-ai-cli.ps1 keeps Program Files when main-script mtimes are equal' {
  $fixture = New-ShadowFixture
  try {
    # Different content but identical timestamps must fail closed toward PF.
    Set-Content -LiteralPath $fixture.PfMain -Value "# pf main equal-mtime`r`n" -Encoding ASCII
    Set-Content -LiteralPath $fixture.UserMain -Value "# user main equal-mtime different body`r`n" -Encoding ASCII
    $same = (Get-Date).ToUniversalTime().AddHours(-3)
    [IO.File]::SetLastWriteTimeUtc($fixture.PfMain, $same)
    [IO.File]::SetLastWriteTimeUtc($fixture.UserMain, $same)

    $result = Invoke-ShadowEntrypoint $fixture

    Assert-Equal $result ("keep-program-files|" + $fixture.PfMain) 'Expected equal mtimes to keep Program Files instead of forwarding to CurrentUser.'
  } finally {
    if (Test-Path -LiteralPath $fixture.Root) {
      Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'bin/check-ai-cli.ps1 keeps Program Files when main scripts have identical content' {
  $fixture = New-ShadowFixture
  try {
    $body = "# same payload`r`n"
    Set-Content -LiteralPath $fixture.PfMain -Value $body -Encoding ASCII
    Set-Content -LiteralPath $fixture.UserMain -Value $body -Encoding ASCII
    $older = (Get-Date).ToUniversalTime().AddDays(-2)
    $newer = (Get-Date).ToUniversalTime().AddDays(-1)
    [IO.File]::SetLastWriteTimeUtc($fixture.PfMain, $older)
    [IO.File]::SetLastWriteTimeUtc($fixture.UserMain, $newer)

    $result = Invoke-ShadowEntrypoint $fixture

    Assert-equal $result ("keep-program-files|" + $fixture.PfMain) 'Expected identical main-script content to keep Program Files even if user mtime is newer.'
  } finally {
    if (Test-Path -LiteralPath $fixture.Root) {
      Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Run-Test 'bin/check-ai-cli.cmd no longer hard-forwards to CurrentUser before PowerShell freshness checks' {
  $cmdPath = Join-Path $repoRoot 'bin\check-ai-cli.cmd'
  $text = Get-Content -LiteralPath $cmdPath -Raw
  if ($text -match 'USER_ENTRY=') {
    throw 'Expected CMD entrypoint to stop hard-forwarding to CurrentUser before the PowerShell freshness check.'
  }
  if ($text -notmatch 'check-ai-cli\.ps1') {
    throw 'Expected CMD entrypoint to hand off to the sibling PowerShell entrypoint.'
  }
}

Write-Host '[PASS] All entrypoint shadow recovery regression tests passed.' -ForegroundColor Green
