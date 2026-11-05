# Release policy

## Current status

`valise-sh` is at **0.3.0**. Before 1.0, the CLI, module ABI, and release
format do not have a backward-compatibility guarantee. Pin the version you
use, read the release notes, and run `valise lint` and `valise test` on your
project before upgrading. A project can set `requires_valise=` in
`valise.conf` so an older valise refuses to build it.

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

## What changed in 0.3.0

0.3.0 changes the project layout, the metadata, the release format, and the
startup block. A 0.2 project does not build until it is moved to the new
layout, and a 0.2 release cannot be installed; rebuild it. Every change is
also in [CHANGELOG.md](../CHANGELOG.md).

### Moving a 0.2 project

| 0.2 | 0.3 |
|---|---|
| `shell/module.d/`, `shell/modules/` | `module.d/`, `modules/` at the project root |
| `shell/layers/<p>/` | `layers/<p>/` |
| `shell/release/bundle-roots` | `bundles.tsv` (bundle, shell, roots) |
| `shell/release/install-variants` | `variants.tsv` (variant, description, excluded) |
| `shell/release/project.conf` | `valise.conf` (`bundle=`, `variant=`, `requires_valise=`, `lint_layer_forbid=`) |
| `shell/release/module-registry.tsv` | nothing: the registry is internal; delete the file |
| `valise registry --check` | nothing: `valise lint` checks the metadata |
| `@shell/layers/<p>/module.d` in a qualified name | `@layers/<p>/module.d` |

valise does not read the `shell/` layout: until `valise.conf` exists,
project commands report that they are not inside a valise project.

### Metadata

- `shells=posix` means every POSIX shell. `shells=sh` now means only the
  generic class (dash, BusyBox ash, and other plain `sh`), so a module that
  used `shells=sh` for "all POSIX shells" must change to `shells=posix`.
- `updates=` is rejected. Remove it.
- A repeated field is rejected.
- The engine modules moved into the reserved `valise_` namespace:
  `contrib_path` is now `valise_path` (exports `valise_path_prepend` and
  `valise_path_append`), `contrib_editor`, `contrib_history`,
  `contrib_pager`, and `contrib_xdg` are `valise_editor`, `valise_history`,
  `valise_pager`, and `valise_xdg`, and `platform_<os>` is
  `valise_platform_<os>`. Update `requires=` and the calls to their
  exports.
- New fields: `commands=` publishes exports as commands on `PATH`,
  `executables=` publishes scripts, and `tests=` names the scripts
  `valise test` runs.

### Releases and startup

- A release has one shape: `plans/<shell>.sh`, `runtime/`, `bin/`,
  `valise-release.conf` with `format=2`, and `manifest.tsv`. It contains
  only the modules some plan loads. The `generated/`, `vendor/`,
  `shell/install/`, and engine-release (`entrypoints/`) shapes are gone, and
  install refuses a tree without `format=2`.
- The POSIX block picks a plan for `ksh`, `zsh`, `bash`, or `sh` and has no
  loader fallback. Run `valise apply` once to rewrite the block in each
  startup file. Install warns about any line outside a managed block that
  still loads a 0.2 release.
- A bundle's `fish` rows build the native Fish runtime into the release.

### New commands

`valise lint`, `test`, `run`, `env`, `uninstall`, `release rollback`, and
`apply --dry-run`. Install is transactional: a failure puts the previous
active release back.

## Release checklist

Before tagging or publishing a release:

1. Update the `package.json` version and `VALISE_VERSION` in `bin/valise`
   together; add a dated entry to [CHANGELOG.md](../CHANGELOG.md). The CLI's test suite asserts that the
   two versions match, so a bump that updates one and forgets the other
   fails the build.
2. Run `make check-fast`, then run `make VALISE_REQUIRE_TOOLING=1 check`
   locally or use the GitHub Actions job. Keep the successful strict run as
   release evidence for every lane, including Fish, zsh, BusyBox, dash, and
   ksh.
3. Run the README's scratch-home example from a clean checkout and check
   that `greet` runs and the cleanup removes the scratch directory.
4. Inspect the result of `npm pack --dry-run` and install/test the packed
   tarball. The CLI's tests currently cover pack contents, installation, and
   module loading. The probe in `tests/cli-posix.test.sh` builds a tree from
   the real `files` whitelist, plants build directories at more than one
   depth under `examples/`, and requires the tarball to exclude every one of
   them while keeping the surrounding example sources. `package.json` keeps
   them out with `!examples/**/build/`, because npm applies `files` without
   consulting `.gitignore` and `valise apply` writes build output into
   `examples/profile-project/`. The `**` is load-bearing: a single `*` still
   packs a build directory nested one level deeper.
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
