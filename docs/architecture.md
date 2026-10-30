# Architecture and scope

`valise-sh` contains a shell-profile loader, a compiler that turns module
metadata into a static startup plan, a small catalog of reusable modules,
and a CLI for installing and verifying sealed profile releases. It can be
used from a source checkout or vendored by a consuming profile project.

## Components

| Path | Responsibility |
|---|---|
| `entrypoints/profile.sh` | Sourced POSIX entrypoint. Locates the engine and module roots, loads the libraries, then invokes the loader. |
| `lib/metadata.sh` | Parses and validates `module.d/*.meta` as data; it does not execute metadata. |
| `lib/loader.sh` | Resolves dependencies, selects modules by shell/platform/phase, sources bodies, checks declared exports, and cleans up failures. |
| `lib/compiler.awk` | Compiles the preprocessed module graph into a static POSIX startup plan. |
| `lib/capabilities.sh` | Portable OS, command, path, temporary-file, and system-information helpers for modules. |
| `lib/fish/` and `entrypoints/fish/` | Fish-native metadata reader, loader, and adapter. Fish modules are not POSIX shell scripts. |
| `module.d/`, `modules/` | Metadata and module bodies, including generic platform and `contrib_` utilities. |
| `bin/valise` | POSIX shell CLI for integration snippets, sealed release installation and verification, project scaffolding, and the source-tree commands used by consumer projects. |
| `manifests/parser-support.tsv` | Declares parser requirements for shipped shell files. |
| `tests/`, `examples/` | Quarantined tests and runnable examples. |

See [module-abi.md](module-abi.md) for metadata and loader contracts,
[installation.md](installation.md) for CLI and release behavior,
[variants.md](variants.md) for the compile and assemble contract, and
[contrib-modules.md](contrib-modules.md) for authoring modules.

## Two ways to load a profile

A profile can be loaded two ways, and both are supported.

The **loader** reads the metadata at startup, resolves the dependency
graph, and sources the module bodies. It is the general mechanism: it
honours every metadata field, including optional dependencies, and it
works for a source tree that is still being edited.

The **compiled plan** is a single static POSIX script per shell,
generated ahead of time from the same metadata. It is faster to source,
because nothing is parsed or resolved at startup. It carries the
contract that matters for a startup file: platform gating, export
checks, per-module failure reporting, strict and permissive failure
policy, and the capability helpers left available to the modules it
loads.

The two are deliberately close in behavior, so a profile can be compiled
for speed without changing what it does. The compile contract, including
the exact fields the plan honors, is in [variants.md](variants.md).

## Two release shapes

A release directory takes one of two shapes, and the startup snippet
handles both.

An **assembled release** is what `valise assemble` produces. It carries
`generated/installed-modules.<shell>` compiled plans, the capability
prelude under `vendor/shell-profile/lib/`, the module bodies, and no
`entrypoints/`.

An **engine release** carries `entrypoints/profile.sh` and `lib/`, and no
`generated/`. It loads through the loader rather than a compiled plan.

The POSIX integration snippet prefers the compiled plan for the running
shell and falls back to the loader, so a startup file written by either
shape loads the release it is pointed at.

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
Those belong in the consuming repository. `valise new` scaffolds an empty
project so a consumer never has to invent the directory layout by hand, but
the catalog itself is still the consumer's to write.

The CLI splits into two groups by what they need.

Commands that work in a bare checkout: `init`, `install`, `verify-active`,
`doctor`, `variant`, `make-manifest`, `version`, and `new`.

Commands that need a consuming project, because they read or write the
project's source tree: `registry`, `module`, `build`, `apply`, `status`,
`compile`, `assemble`, `explain-variant`, `explain-bundles`, and
`layer-lint`. A project is recognised by `shell/module.d/` or
`shell/release/module-registry.tsv`; the project commands run from the
project root and read their defaults from `shell/release/project.conf`.

## The registry is generated, not authored

`shell/release/module-registry.tsv` is a build artifact. `valise registry`
reads every `.meta` file under `shell/module.d/` and
`shell/layers/<provider>/module.d/` and writes the registry from them, in the
C locale, so repeated generation is byte-identical. `valise registry --check`
compares the file against the metadata without rewriting it, which is what
`valise status` reports as registry freshness. `assemble` and `build`
regenerate the registry before compiling, so a project that contains only
metadata and bodies still builds.

This makes the `.meta` files the single source of truth. A hand-edited
registry is not supported: the next build overwrites it.

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

These targets live in the source repository. The npm package ships the
runtime, the docs, and the examples, not the Makefile or the test suite.
