param(
  [ValidateSet('Assets','Intro')]
  [string]$Mode = 'Assets',
  [string]$Tag = 'unreleased',
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DistributionFiles.ps1')

function Get-ReleaseIntroText([string]$ReleaseTag) {
  return @(
    "# Check-AI-CLI $ReleaseTag",
    '',
    'This release publishes the installer, entrypoint, and main check/update scripts for Windows and macOS/Linux.',
    '',
    'Included assets:',
    '- `checksums.sha256` for integrity verification',
    '- `distribution-files.txt` as the canonical install/release file list',
    '- install and uninstall scripts',
    '- PATH entrypoint scripts under `bin/`',
    '- main scripts under `scripts/`',
    '',
    'GitHub generated release notes are appended below.'
  ) -join "`n"
}

function Write-Utf8NoBomLf([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Main() {
  $content = if ($Mode -eq 'Intro') {
    (Get-ReleaseIntroText $Tag) + "`n"
  } else {
    ((Get-ReleaseAssetPaths) -join "`n") + "`n"
  }

  if ($OutputPath) {
    $full = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
    Write-Utf8NoBomLf $full $content
    return
  }

  Write-Output $content.TrimEnd("`r", "`n")
}

if ($MyInvocation.InvocationName -ne '.') {
  Main
}
