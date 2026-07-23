# AI CLI Version Checking

This context defines the language for discovering, updating, and verifying locally installed AI command-line tools across Windows and POSIX environments.

## Tools and releases

**AI CLI Tool**:
An externally installed command-line tool tracked by this project: Claude Code, OpenAI Codex, Gemini CLI, Grok Build, or OpenCode.
_Avoid_: Factory CLI, Droid, application, package manager product

**Npm Package Spec**:
The only install unit for an AI CLI Tool, always of the form `name@latest` (for example `@anthropic-ai/claude-code@latest`).
_Avoid_: bootstrap script, native updater, brew formula

**Release Target**:
The semver from the npm registry `latest` dist-tag for the tool package, resolved with the same registry policy used for install.
_Avoid_: GitHub release-only target, GCS stable channel as install target

**Release Source**:
npm registry only (regional mirror and/or `https://registry.npmjs.org`).
_Avoid_: mirror as a non-npm HTTP file host, remote install script, scoop/choco/brew

**Installed Candidate**:
A locally discoverable executable (prefer npm global bin) and its parsed version.
_Avoid_: standalone install preferred over npm when both exist

## Checking and updating

**Update Lifecycle**:
Discover npm latest → read installed candidate → compare → `npm install -g` → repair PATH preference for npm global bin → re-read version.
_Avoid_: multi-channel fallback graphs

**Network Route**:
Proxy route or direct route used for registry HTTP and for child `npm` processes.
_Avoid_: transport mode as a product feature

**Verified Payload** (Check-AI-CLI self-install only):
An installation file for this repository accepted after trusted source + checksum match.
_Avoid_: applying the same term to third-party npm packages

**Update Result**:
Observable outcome of an npm update attempt, including success/failure and post-install version.
_Avoid_: success when local version cannot be verified
