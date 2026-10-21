# Architecture and scope

`valise-sh` contains a shell-profile loader, a small catalog of reusable
modules, and a CLI for installing and verifying sealed profile releases. It
can be used from a source checkout or vendored by a consuming profile project.

## Components

| Path | Responsibility |
|---|---|
| `entrypoints/profile.sh` | Sourced POSIX entrypoint. Locates the engine and module roots, loads the libraries, then invokes the loader. |
| `lib/metadata.sh` | Parses and validates `module.d/*.meta` as data; it does not execute metadata. |
| `lib/loader.sh` | Resolves dependencies, selects modules by shell/platform/phase, sources bodies, checks declared exports, and cleans up failures. |
| `lib/capabilities.sh` | Portable OS, command, path, temporary-file, and system-information helpers for modules. |
| `lib/fish/` and `entrypoints/fish/` | Fish-native metadata reader, loader, and adapter. Fish modules are not POSIX shell scripts. |
| `module.d/`, `modules/` | Metadata and module bodies, including generic platform and `contrib_` utilities. |
| `bin/valise` | POSIX shell CLI for integration snippets, sealed release installation and verification, and source-tree commands used by consumer projects. |
| `manifests/parser-support.tsv` | Declares parser requirements for shipped shell files. |
| `tests/`, `examples/` | Quarantined tests and runnable examples. |

See [module-abi.md](module-abi.md) for metadata and loader contracts,
[installation.md](installation.md) for CLI and release behavior, and
[contrib-modules.md](contrib-modules.md) for authoring modules.

## Loading modules

The POSIX entrypoint is sourced, not executed. A caller can select roots,
modules, and failure policy explicitly:

```sh
VALISE_ROOT=/path/to/valise-sh
VALISE_MODULE_ROOT=/path/to/profile
VALISE_MODULES='module_a module_b'
VALISE_MODE=strict
. "$VALISE_ROOT/entrypoints/profile.sh"
```

`VALISE_MODULES` unset means no modules are requested. A consuming profile is
responsible for choosing its default module set and for setting the roots in
its startup integration. Searching upward from the current directory when
`VALISE_ROOT` is omitted is a checkout convenience, not an installed-profile
configuration strategy.

Metadata is validated before module bodies run. Required dependencies load
first; present optional dependencies are also considered. Cycles and invalid
or conflicting records are rejected. Strict mode returns failure for a
requested module's failure; permissive mode reports the affected module and
continues with unrelated requests. The loader has no unload operation.

The Fish adapter uses the native Fish loader and native `.fish` bodies; it
never sources POSIX bodies. Fish startup integration verifies the installed
release before loading it. See [installation.md](installation.md) for the
specific integrity boundary.

## Scope boundaries

The engine does not define a consumer's module catalog, default startup graph,
workstation policy, project wrappers, or project-specific release build.
Those belong in the consuming repository. The `compile`, `explain-variant`,
`explain-bundles`, and `layer-lint` CLI commands therefore need source files
from a consuming project; the rest of the documented bare-checkout commands
are usable without one.

The `updates=` metadata field records identifiers for a consumer's update
manifest. It does not make this engine a network updater. Shared modules are
vendored snapshots: consumers review provider changes, update the snapshot,
and rebuild their release. The engine does not authenticate authors or sign
releases; its manifest check detects changes to bytes after the manifest is
created.

## Verification

Run `make check-fast` while developing and `make check` for the available
suite. Extended runtime lanes run when their tools are installed; missing tools
are visible skips locally and are required in CI. Set
`VALISE_REQUIRE_TOOLING=1` to require them on a developer machine. The GitHub
Actions workflow installs the shell runtimes used by the release check.
