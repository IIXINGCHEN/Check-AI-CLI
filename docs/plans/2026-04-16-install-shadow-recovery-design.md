# Install shadow recovery design

## Goal

Comprehensively improve the Windows experience when an older machine-wide Check-AI-CLI install in `C:\Program Files\Tools\Check-AI-CLI` shadows a newer CurrentUser install under `%LOCALAPPDATA%\Programs\Tools\Check-AI-CLI`.

## Problem

A non-admin reinstall can place a newer copy in the CurrentUser location, but new Windows sessions may still resolve the older Program Files entry first. The current installer only warns. Users then continue running the stale machine-wide copy and cannot tell that the newer user install is being ignored.

## Recommended approach

- Keep install directory and PATH scope rules unchanged.
- Strengthen installer guidance so the recovery path is explicit and actionable.
- Add runtime self-healing in the entrypoint layer: if a Program Files entrypoint starts and a newer CurrentUser install exists, forward execution to the CurrentUser entrypoint instead of continuing with the stale machine-wide copy.
- If forwarding is not possible, print a precise recovery message.

## Why this approach

- It fixes the real user experience without destructive actions.
- It does not require silently editing Machine PATH from a non-admin install.
- It improves both future installs and already-shadowed launch scenarios, as long as the launched entrypoint contains the new forwarding logic.

## Scope

- `install.ps1`: improve shadow warning text and next-step guidance.
- `bin/check-ai-cli.cmd`: add CurrentUser-forwarding logic when launched from Program Files.
- `bin/check-ai-cli.ps1`: mirror the forwarding logic for direct PowerShell invocation.
- `tests/InstallProgress.Tests.ps1`: cover clearer warning guidance.
- Add focused regression coverage for CMD/PowerShell forwarding behavior if needed.

## Non-goals

- Do not delete or modify old Program Files installs automatically.
- Do not force elevation.
- Do not redesign install location defaults.

## Success criteria

- Users receive explicit recovery guidance when a CurrentUser install is shadowed.
- Launching the stale Program Files entrypoint forwards to the newer CurrentUser install when available.
- Existing installation and PATH behavior remains compatible.
- New regression tests prove the forwarding and guidance behavior.
