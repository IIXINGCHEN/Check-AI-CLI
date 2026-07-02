$ErrorActionPreference = 'Stop'

# Filters PS 7-only module directories out of a PSModulePath string so that
# Windows PowerShell 5.1 does not ghost-load PS 7 module manifests (which
# fail to load and leave core cmdlets like Get-FileHash unavailable).
#
# Pure function: takes a path string, returns a path string. Does not touch
# $env:PSModulePath or any module state. Callers are responsible for the
# side effects (set $env:PSModulePath, then Remove-Module / Import-Module
# -Force to drop the ghost and reload from the cleaned path).
#
# Patterns stripped:
#   *\WindowsApps\Microsoft.PowerShell*\Modules      (PS 7 Microsoft Store / winget, stable and preview)
#   *\Documents\PowerShell\Modules                  (PS 7 per-user)
#   *\Program Files\PowerShell\Modules              (PS 7 all-users)
# The 5.1 equivalents use `WindowsPowerShell` and are preserved.
function Get-CleanedPS51ModulePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $kept = @()
  foreach ($p in ($Path -split ';')) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $trimmed = $p.Trim()
    if ($trimmed -match 'WindowsApps\\Microsoft\.PowerShell') { continue }
    if ($trimmed -match '\\Documents\\PowerShell\\Modules$') { continue }
    if ($trimmed -match '\\Program Files\\PowerShell\\Modules$') { continue }
    $kept += $p
  }
  return ($kept -join ';')
}
