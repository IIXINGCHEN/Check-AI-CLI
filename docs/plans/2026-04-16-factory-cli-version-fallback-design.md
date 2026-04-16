# Factory CLI latest-version fallback design

## Goal

Make the Windows Factory CLI latest-version check resilient when `https://app.factory.ai/cli/windows` returns `403`, while keeping the official bootstrap install flow unchanged.

## Context

- Current latest-version detection uses `scripts/Check-AI-CLI-Versions.ps1:923-929` and parses `$version` from the Windows bootstrap script body.
- The same bootstrap URL is still the documented Windows install entrypoint in `README.md:57-67` and Factory docs.
- The problem is therefore not clearly a stale URL; it is that metadata lookup currently depends on a bootstrap endpoint that may reject direct reads.
- Existing regression coverage for Factory updater behavior lives in `tests/FactoryUpdateReview.Tests.ps1:113-236`.

## Options considered

### Option 1, recommended
- Keep bootstrap parsing as the primary source.
- Add a fallback source only for latest-version detection.
- Leave `Update-Factory` and verified-binary install flow unchanged.

Why this is best:
- Smallest safe change.
- Preserves the official install path.
- Fixes the specific fragility that produces `Latest version: unknown`.

### Option 2
- Replace bootstrap parsing entirely with another source.

Trade-off:
- Simpler code, but risks drifting away from the source that the installer actually uses.

### Option 3
- Keep current source and only improve warning text.

Trade-off:
- Better UX, but does not solve the inability to determine the latest version.

## Approved design

### Architecture
- Split Factory latest-version resolution into primary and fallback lookups.
- Primary lookup remains bootstrap parsing from `https://app.factory.ai/cli/windows`.
- Fallback lookup should use an official, machine-readable source that is less likely to 403 for metadata fetches.
- `Get-LatestFactoryVersion()` should return the first valid semver from these sources.

### Scope
- Update only Factory latest-version resolution behavior.
- Do not change Factory install/download/checksum logic.
- Do not refactor unrelated tool-version resolution flows.

### Error handling
- Bootstrap fetch failure should not directly force `unknown` if fallback succeeds.
- If both sources fail, preserve current degraded behavior and warning style.

### Testing
- Add a failing regression test first.
- The key scenario: bootstrap lookup fails, fallback returns a valid version, and `Get-LatestFactoryVersion()` returns the fallback version.
- Keep tests in the existing lightweight PowerShell harness style.

## Success criteria

- Factory version check no longer reports `Latest version: unknown` when bootstrap fetch returns `403` but fallback metadata is available.
- Existing Factory updater tests continue to pass.
- No behavior change to the actual Factory bootstrap installer path.
