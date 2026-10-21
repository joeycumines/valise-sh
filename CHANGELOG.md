# Changelog

Notable user-facing changes are recorded here. Versions before 1.0 may include
module ABI or CLI changes; see [the release policy](docs/release-policy.md).

## Unreleased

- Made the editor-defaults test independent of host-installed editors by
  supplying a temporary test `vi` executable.
- Fixed `valise` with no arguments: under `set -e`, a zero-argument `shift`
  could terminate the CLI before it displayed its help text.
- Fixed Fish activation so functions loaded from package paths (for example,
  Homebrew) are authenticated and preserved through the load instead of being
  rejected or lost.
- Added an isolated sample install walkthrough and documented the release
  checklist.
