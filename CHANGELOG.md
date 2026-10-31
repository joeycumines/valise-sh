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
  writes the shell integration, and verifies the result; it is idempotent.
  `valise status` reports the project, the active release, the integration
  state, and whether the active release has drifted from the build output.
- `valise registry`, which generates `shell/release/module-registry.tsv` from
  the project's metadata. `valise build` regenerates and validates the
  registry, so a committed registry is a generated artifact rather than a
  hand-maintained catalog. The row order is fixed: the primary modules of
  `shell/module.d/` first, then the layer modules of each
  `shell/layers/<provider>/module.d/`, each group in C-locale name order.
- `valise release list`, `valise release use`, `valise release prune`, and
  `valise release verify`. They manage installed releases; source variants
  remain the business of `valise build` and `valise apply`.
- Command-specific `--help` for `build`, `compile`, `install`, `init`, `new`,
  `module`, `release`, `doctor`, and `status`, so each prints its own
  contract rather than the global command list.
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

- `valise build` builds a complete release tree to `build/release` by
  default, reads the variant and bundle defaults from
  `shell/release/project.conf`, and requires an explicit output directory to
  be empty or absent. A failed build preserves the previous build output.
- `valise build` produces no Fish surface: no Fish entrypoint, generated
  plan, or native loader. A built release therefore loads nothing in Fish;
  the Fish hook verifies the active release and stays silent. Only an engine
  release with `entrypoints/fish/profile.fish` uses the native Fish loader.
- `valise install` writes shell integration by default. It always writes
  `~/.profile`; it adds `~/.bash_profile` or `~/.bash_login` when one of
  those exists, because bash reads that file instead of `~/.profile`; it
  writes `~/.bashrc` when bash is the current shell or that file exists; it
  writes `~/.zprofile` when zsh is on `PATH` or that file exists, because zsh
  reads nothing else at login; and it writes `~/.zshrc` when zsh is the
  current shell or that file exists. Existing files are kept current rather
  than replaced. A symlinked startup file is reported and left untouched.
  `--no-integration` installs without writing any startup file. Install also
  writes the Fish `conf.d` hook when it finds Fish in a trusted location;
  `valise apply` runs the same install path.
- The startup integration is a managed block between `# BEGIN valise managed
  block` and `# END valise managed block`. Repeat installs are idempotent and
  existing profile content is preserved. An unpaired marker is refused and
  stops the install. Install prints each path it wrote and how to remove the
  block.
- `valise init` takes `posix` or `fish`; any other argument is rejected.
  It is a one-time snippet generator, not something to evaluate at every
  prompt.
- A project's default variant is `default`. An unknown variant is an error
  in every command that accepts one.
- Compiled plans and the loader now agree on required dependency closure.
  Platform skips are recorded during discovery and reported once the full
  required closure is known; strict mode fails when a required module is
  blocked during ordering; permissive mode continues and returns zero. Fish
  reports a platform-skipped optional dependency silently.
- Compiled plans reach parity with the loader: they gate modules by
  `platforms=` at runtime, pre-check and post-check declared exports, report
  each failing module by name, continue past a failure in permissive mode
  while returning zero, stop in strict mode, and support meta modules with no
  source line.
- The loader saves the logical `$PWD` and `$OLDPWD` before sourcing each
  module and restores them afterwards, so a module that changes directory
  during its load leaves the caller's logical directory as it was.
- The loader's export pre-check accepts a name that currently resolves to an
  external command, which is how a deliberate wrapper is exported. It still
  rejects a name already defined as a function, builtin, or alias.
- The loader resolves each metadata record with shell builtins instead of
  repeated `sed`, `grep`, and `cat` processes, so the number of external
  processes a load spawns does not grow with the number of modules.
- `valise compile` and `valise build` find the packaged
  `lib/capabilities.sh` relative to the CLI, so a symlinked or relocated
  install works. A compiled plan rejects a module that has neither a load
  path nor dependencies, and names the module.
- Layer handling accepts any `shell/layers/<provider>` path rather than only
  the `contrib` provider, and produces a deterministic manifest.
- `valise doctor` reports a missing active release as a failure and reads the
  startup files the running shell actually reads. `--pre-install` skips the
  release and integration checks; `--no-integration` checks only the
  environment and the active release.
- `valise explain-bundles` and `valise layer-lint` are implemented in POSIX sh
  and awk. `layer-lint` validates a provider layer's structure, `contrib_`
  name prefix, version, load path, symlink freedom, file modes, and
  dependency containment.
- The unused Python consumer-release helpers, wrapper lifecycle hooks, and
  the submodule build prelude override are gone. No command requires
  Python 3.

### Removed

- `load_hook` and the compatibility bridge in the POSIX loader, the Fish
  loader, and compiled plans. A module declares `load`, `requires`, or both.
  Metadata naming `load_hook` fails with
  `metadata field load_hook is not supported; use load`.
- `variant list`, `variant use`, and `verify-active`; installed releases are
  managed by `valise release list|use|prune|verify`. `variant` now refers
  only to build variants.
- The per-shell `valise init` arguments `bash`, `zsh`, `ksh`, and `sh`; use
  `valise init posix` or `valise init fish`.

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
- Applying to a home directory with a trailing slash could skip the zsh
  startup file, because the target was compared against the raw `HOME`
  string rather than a normalized path.
- A built release's Fish hook printed an error on every Fish start. It now
  verifies the release quietly and returns when there is no Fish surface to
  load.
- The editor-defaults test is independent of host-installed editors by
  supplying a temporary test `vi` executable.

[Unreleased]: https://github.com/joeycumines/valise-sh/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/joeycumines/valise-sh/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joeycumines/valise-sh/releases/tag/v0.1.0
