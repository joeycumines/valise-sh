# Release policy

## Current status

`valise-sh` is at **0.2.0**. Before 1.0, the CLI, module ABI, and release
format do not have a backward-compatibility guarantee. Consumers should pin
updates, review release notes, and run their profile's tests before upgrading.

## Compatibility surface

The compatibility contract has three separate parts:

- **CLI:** commands, flags, exit behavior, generated integration snippets,
  install paths, and manifest format.
- **Module ABI:** metadata field names/values, dependency and selection
  semantics, exported function expectations, and POSIX/Fish loader behavior.
- **Release format:** manifest syntax, file/mode constraints, integrity
  verification, and the directory layout expected by deployed hooks.

A change affecting one of these is a compatibility change even if the other
surfaces remain unchanged. Before 1.0, incompatible changes may occur between
minor releases, and release notes must state what consumers have to change.
After 1.0, use semantic versioning: patch for compatible fixes,
minor for backward-compatible features, and major for incompatible changes.

## What changed in 0.2.0

`0.1.0` had no external users, so `0.2.0` provides no migration path for its
CLI or shell integration. The items below describe the 0.2.0 contract; each is
also recorded in [CHANGELOG.md](../CHANGELOG.md).

### The registry is a generated artifact

`shell/release/module-registry.tsv` is generated from the project's metadata
by `valise registry`, and `valise build` regenerates it while `valise registry
--check` validates it. A hand-written registry is no longer the source of truth, and a
project needs no registry file at all to build: it keeps its `.meta` files,
their bodies, the bundle roots, and the variants. A committed registry is
accepted as input, but it is overwritten on the next build.

The row order is fixed and does not depend on the caller's locale: the
primary modules of `shell/module.d/` first, then the layer modules of each
`shell/layers/<provider>/module.d/`, each group in C-locale name order.

### The metadata ABI gained fields and classes

- **Meta modules.** Metadata with `requires=` and no `load` is a
  dependency-only aggregator. It loads successfully without a body. `load`
  and `requires` may be combined.
- **`side_effect=local-state`.** A source-safe class for modules that write
  under the XDG state directory. It loads in the ordinary phase where
  `generated-file` still fails.
- **`shells=sh` covers every POSIX shell.** A module that declares `shells=sh`
  loads under `sh`, `dash`, `bash`, `zsh`, and `ksh`, and is skipped under
  Fish unless it is requested directly in strict mode.

### Compiled plans follow the loader

A compiled plan uses the loader's dependency rules. The required closure is
the bundle's roots plus their transitive `requires`. A module whose required
dependency is unavailable, failed, or skipped for the platform does not run.
Strict mode stops at the first failure in that closure and returns nonzero;
permissive mode reports each failure, continues with unrelated modules, and
returns zero. An optional dependency loads first when it is available for the
shell and variant; its absence never blocks the module that declared it. A
cross-platform profile declares platform-specific modules with `optional=`.

### Capabilities are available at runtime

The `sp_cap_*` helpers remain sourced and callable after a compiled plan or a
loader load finishes. A module may call `sp_cap_os` and the other helpers
from its own functions. A plan that removed them at the end of the load left
module functions unusable.

### Startup integration is managed

`valise install` writes a managed block into `~/.profile` and into each
further startup file it manages: the existing `~/.bash_profile` or
`~/.bash_login`, `~/.bashrc` and `~/.zshrc` when that shell is current or the
file exists, and `~/.zprofile` when zsh is on `PATH` or the file exists. It
does not create `~/.bash_profile` or `~/.bash_login`, because either would
stop bash from reading `~/.profile`. A Fish `conf.d` hook is written when
valise finds a Fish executable in a trusted location. `--no-integration`
writes no startup file and no Fish hook. `valise apply` uses the same writer
after building and installing.

Each POSIX file receives the block between `# BEGIN valise managed block` and
`# END valise managed block`. A repeat install replaces the block in place
and preserves the rest of the file. An unpaired marker is refused and stops
the install; a file already processed keeps its updated block. A symlinked
startup file is reported and left untouched.

### Commands

The command surface has one command per job. `valise init` takes `posix` or
`fish`; with no argument it prints the Fish hook when `$SHELL` names fish and
the POSIX block otherwise. `valise new`, `valise module`, `valise build`,
`valise apply`, `valise status`, and `valise registry` are new. `valise build`
builds a release tree, and `valise apply` builds, installs, writes the shell
integration, and verifies the result.

Installed releases are managed by `valise release list|use|prune|verify`.
`variant list`, `variant use`, and `verify-active` are gone; `variant` now
refers only to a build variant. `valise doctor` gained `--pre-install` and
`--no-integration`; it reads the startup files the running shell actually
reads and exits nonzero when the active release is missing or fails
verification, or when no startup file carries the block. `valise
explain-bundles` and `valise layer-lint` no longer use Python.

## Release checklist

Before tagging or publishing a release:

1. Update `package.json` and `bin/valise` version together; add a dated entry
   to [CHANGELOG.md](../CHANGELOG.md). The CLI's test suite asserts that the
   two versions match, so a bump that updates one and forgets the other
   fails the build.
2. Run `make check-fast`, then run `make VALISE_REQUIRE_TOOLING=1 check`
   locally or use the GitHub Actions job. Keep the successful strict run as
   release evidence for every lane, including Fish, zsh, BusyBox, dash, and
   ksh.
3. Run the README isolated quickstart from a clean checkout and verify that
   install, `release verify`, and example module loading work in the temporary
   home. Confirm cleanup removes the entire demo state.
4. Inspect the result of `npm pack --dry-run` and install/test the packed
   tarball. The CLI's tests currently cover pack contents, installation, and
   module loading.
5. Review the changed CLI, module ABI, release manifest, docs, and examples;
   check `git diff --check` and doc links.
6. Publish only through the chosen distribution channel. The repository
   currently supports source checkout/vendor and local npm tarball
   installation; it does not claim a public npm publication, signed artifact,
   authenticated update service, or provenance attestation.

Do not claim a platform or shell has passed unless its runtime lane actually
ran. An explicit skip is useful development evidence, not release evidence.

## Test isolation

Every suite runs in a quarantined environment: a fresh temporary `HOME`,
controlled `TMPDIR` and `PATH`, and cleared startup hooks. A suite must also
pass when it is run directly rather than through `make`, because the Makefile
pins `TMPDIR=/tmp` and that can hide a defect that a developer's own
environment exposes. macOS sets `TMPDIR` to a path ending in a slash, so a
path comparison in a suite must resolve both sides before comparing them.
