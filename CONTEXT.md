# AI CLI Version Checking

This context defines the language for discovering, updating, and verifying locally installed AI command-line tools across Windows and POSIX environments.

## Tools and releases

**AI CLI Tool**:
An externally installed command-line tool tracked by this project, such as Factory CLI, Claude Code, OpenAI Codex, Gemini CLI, or OpenCode.
_Avoid_: application, package

**Release Target**:
The version a tool should reach, selected from the trusted release sources available for that tool and platform.
_Avoid_: desired version, latest string

**Release Source**:
A trusted channel that supplies a tool version or installation payload, such as an official bootstrap, package registry, or native package manager.
_Avoid_: mirror, feed

**Installed Candidate**:
A locally discoverable executable and its parsed version, together with the source kind and path used to identify it.
_Avoid_: local tool, binary candidate

## Checking and updating

**Update Lifecycle**:
The sequence that discovers a release target, reads an installed candidate, compares versions, performs an update, and verifies the resulting installed candidate.
_Avoid_: update flow, check flow

**Network Route**:
The selected path for a request or download, including a proxy route or a direct route.
_Avoid_: connection mode, transport mode

**Verified Payload**:
An installation file accepted only after its source is trusted and its checksum matches the expected release metadata.
_Avoid_: downloaded file, installer file

**Update Result**:
The observable outcome of an update attempt, including success or failure, the resulting installed candidate, and relevant release-source diagnostics.
_Avoid_: status string, update message
