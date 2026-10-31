# Changelog

Notable user-facing changes are recorded here. Versions before 1.0 may include
module ABI or CLI changes; see [the release policy](docs/release-policy.md).

## [Unreleased]

## [0.2.0] - 2026-10-31

### Added

- `valise new`, `valise module new`, `valise module list`,
  `valise module remove`, `valise build`, `valise apply`, and
  `valise status`. A new project can be scaffolded, given a module, built,
  installed, and checked without hand-writing a registry or a build script.
  `valise module new` writes the module body and its declared export, and
  wires the module into the seed aggregator. `valise apply` builds, installs,
  writes the managed integration block, and verifies the result; it is
  idempotent. `valise status` reports the project, the active release, the
  integration state, and whether the active release has drifted from the
  build output.
- `valise registry`, which generates `shell/release/module-registry.tsv` from
  the project's metadata. `valise build` and `valise assemble` regenerate and
  validate the registry, so a committed registry is a generated artifact
  rather than a hand-maintained catalog. The row order is fixed: the primary
  modules of `shell/module.d/` first, then the layer modules of each
  `shell/layers/<provider>/module.d/`, each group in C-locale name order.
- `valise doctor`, which checks the active release against its own manifest
  and checks the startup files the running shell actually reads for the
  valise managed block. It exits nonzero when the active release is missing
  or fails verification, and when no startup file carries the managed block.
  `--pre-install` skips the release check and `--no-integration` skips the
  startup-file check.
- `valise variant prune --keep=<n>`, which verifies each candidate release
  before removing it and always keeps the active release. A release that
  cannot be verified against its own manifest is reported and kept rather
  than discarded.
- `valise explain-bundles` and `valise layer-lint`, implemented in POSIX sh
  and awk so neither needs Python 3. `layer-lint` validates a provider
  layer's structure, `contrib_` name prefix, version, load path, symlink
  freedom, file modes, and dependency containment.
- Command-specific `--help` for `compile`, `assemble`, `install`, `init`,
  `new`, `module`, `variant`, `doctor`, and `status`, so each prints its own
  contract rather than the global command list.
- `install --integration=<mode>` with the modes `auto` (the previous
  behavior), `profile` (one shared `~/.profile` snippet), and `none` (no
  startup file). `--no-shell-integration` remains as the equivalent legacy
  spelling.
- Meta modules: metadata with `requires=` and no `load` is a
  dependency-only aggregator and loads successfully without a body. `load`
  and `requires` may be combined.
- `side_effect=local-state`, a source-safe side-effect class for modules
  that write under the XDG state directory.
- `VALISE_RELOAD=1`, which unsets the declared exports of the requested
  closure before loading so a profile can be re-sourced.
- The `sp_cap_*` capability helpers remain available at runtime after a
  compiled plan or a loader load finishes, so a module can call them.
- `examples/profile-project/`, a complete consuming project with two
  modules, a provider layer, two variants, and a bundle, and a README that
  walks from clone to a loaded profile.
- A consumer end-to-end test target that builds the reference consumer
  profile from a temporary copy, runs the consumer's own metadata, shells,
  release, and features suites, installs and verifies the release, and
  proves a second build is byte-identical. The original tree and the live
  profile are never touched.

### Changed

- The loader saves the logical `$PWD` and `$OLDPWD` before sourcing each
  module and restores them afterwards, so a module that changes directory
  during its load leaves the caller's logical directory as it was.
- The loader's export pre-check accepts a name that currently resolves to an
  external command, which is how a deliberate wrapper is exported. It still
  rejects a name already defined as a function, builtin, or alias.
- The loader resolves each metadata record with shell builtins instead of
  repeated `sed`, `grep`, and `cat` processes, so the number of external
  processes a load spawns does not grow with the number of modules.
- Compiled plans reach parity with the loader: they gate modules by
  `platforms=` at runtime, pre-check and post-check declared exports, report
  each failing module by name, continue past a failure in permissive mode
  while returning the first failure from the plan, stop in strict mode, and
  support meta modules with no source line.
- `valise apply` writes the shared `~/.profile` integration plus the
  one-line `~/.zprofile` pointer that zsh needs, because zsh does not read
  `~/.profile` on its own. It does not create `.bash_profile`, whose
  presence would stop bash from reading `~/.profile`.
- The startup integration is written as a managed block between
  `# BEGIN valise managed block` and `# END valise managed block`, so
  repeat installs are idempotent and existing profile content is preserved.
  Install prints which file it wrote and how to remove the integration.
- `valise init` is presented as a one-time snippet generator. Evaluating
  `eval "$(valise init)"` at every prompt is no longer documented as the
  routine path.
- `valise compile` and `valise assemble` find the packaged
  `lib/capabilities.sh` relative to the CLI, so a symlinked or relocated
  install works. A compiled plan rejects a module that has neither a load
  path nor dependencies, and names the module.
- `valise assemble` handles a layer under any `shell/layers/<provider>`
  path rather than only the `contrib` provider, and produces a deterministic
  manifest.

### Fixed

- `valise` with no arguments: under `set -e`, a zero-argument `shift` could
  terminate the CLI before it displayed its help text.
- Fish activation: functions loaded from package paths such as Homebrew are
  authenticated and preserved through the load instead of being rejected or
  lost.
- The primary-root symlink diagnostic was printed on stdout while every
  other loader diagnostic went to stderr.
- `valise compile` reported that a Fish plan requires a Python compiler and
  named a file that does not exist in this repository. Fish plans are not
  generated; a Fish integration uses the native Fish loader.
- `valise apply` skipped the `~/.zprofile` pointer when `HOME` ended in a
  slash, because the integration target was compared against the raw
  `HOME` string rather than against a normalized path. A zsh user with such
  a home received no integration at all.
- The editor-defaults test is independent of host-installed editors by
  supplying a temporary test `vi` executable.

[Unreleased]: https://github.com/joeycumines/valise-sh/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/joeycumines/valise-sh/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joeycumines/valise-sh/releases/tag/v0.1.0
