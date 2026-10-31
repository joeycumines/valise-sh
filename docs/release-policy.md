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
minor releases; release notes must identify affected consumers and migration
steps. After 1.0, use semantic versioning: patch for compatible fixes,
minor for backward-compatible features, and major for incompatible changes.

## What changed in 0.2.0

A consumer upgrading from 0.1.0 must account for the following. Each item is
also recorded in [CHANGELOG.md](../CHANGELOG.md).

### The registry is a generated artifact

`shell/release/module-registry.tsv` is generated from the project's metadata
by `valise registry`, and `valise build` regenerates it while `valise registry
--check` validates it. A hand-written registry is no longer the source of truth, and a
project needs no registry file at all to build: only `.meta` files and their
bodies. A committed registry is still accepted for compatibility, but it is
overwritten on the next build.

The row order is fixed and does not depend on the caller's locale: the
primary modules of `shell/module.d/` first, then the layer modules of each
`shell/layers/<provider>/module.d/`, each group in C-locale name order.

### The metadata ABI gained fields and classes

- **Meta modules.** Metadata with `requires=` and neither `load` nor
  `load_hook` is a dependency-only aggregator. It loads successfully without
  a body. Only `load` and `load_hook` are mutually exclusive; `load` and
  `requires` may be combined.
- **`side_effect=local-state`.** A source-safe class for modules that write
  under the XDG state directory. It loads in the ordinary phase where
  `generated-file` still fails.
- **`shells=sh` covers every POSIX shell.** A module that declares `shells=sh`
  loads under `sh`, `dash`, `bash`, `zsh`, and `ksh`, and is skipped under
  Fish unless it is requested directly in strict mode.

### Capabilities are available at runtime

The `sp_cap_*` helpers remain sourced and callable after a compiled plan or a
loader load finishes. A module may call `sp_cap_os` and the other helpers
from its own functions. A plan that removed them at the end of the load left
module functions unusable.

### Startup integration is managed

`valise install` writes a managed startup block for the shells it finds and
takes `--no-integration` to write no startup file and no Fish hook.

`valise apply` writes the managed block to every startup file install
manages, including `~/.zprofile` when zsh is present, because zsh does not
read `~/.profile` on its own. It does not create `.bash_profile`, whose
presence would stop bash from reading `~/.profile`.

The integration is written as a managed block between
`# BEGIN valise managed block` and `# END valise managed block`, so repeat
installs are idempotent and existing profile content is preserved.

### New commands

`valise new`, `valise module`, `valise build`, `valise apply`,
`valise status`, `valise registry`, `valise doctor`, `valise release prune`,
`valise explain-bundles`, and `valise layer-lint` are new in 0.2.0. A
consumer that scripted the 0.1.0 CLI is unaffected by the additions, but
`valise doctor` reports a missing active release as a failure where an
earlier release check reported it as information.

### Migration

A project on 0.1.0 does not have to change anything to upgrade. To adopt the
generated registry, delete the hand-maintained
`shell/release/module-registry.tsv` and run `valise build`; to adopt the
shared-profile integration, run `valise apply` instead of wiring a startup
file by hand.

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
