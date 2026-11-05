# Architecture and scope

valise-sh is a shell-profile engine. It reads module metadata as data,
compiles a static startup plan for each shell, packages the plans and module
bodies into a sealed release, installs the release, and verifies it. Your
profile lives in a separate valise project; the engine supplies the tools
and a few generic modules.

## Components

| Path | Responsibility |
|---|---|
| `bin/valise` | The CLI. It sources the parts under `lib/cli/` and dispatches commands. |
| `lib/cli/` | CLI parts: `project.sh` (project config, registry, compile, build), `store.sh` (release store, install, `release`), `integration.sh` (startup-file blocks, `doctor`), `fish-hook.sh`, `commands.sh` (published commands), `lifecycle.sh` (rollback, transactions, uninstall, dry runs), `devtools.sh` (`lint`, `test`, `run`, `env`), `usage.sh`, `common.sh`. |
| `lib/metadata.sh` | Parses and validates `.meta` files as data. |
| `lib/compiler.awk` | Turns the resolved module graph into a static POSIX plan. |
| `lib/capabilities.sh` | The `sp_cap_*` helpers. A release carries it as `runtime/capabilities.sh`. |
| `lib/fish/` | The native Fish metadata reader, loader, and adapter. A release carries them under `runtime/fish/`. |
| `lib/loader.sh`, `entrypoints/profile.sh` | The development loader, which resolves and sources modules at load time from a checkout. Installed profiles do not use it. |
| `module.d/`, `modules/` | The engine modules (`valise_*`). |
| `manifests/parser-support.tsv` | The parsers each shipped file class must pass. |
| `tests/`, `examples/` | Quarantined tests and runnable examples. |

[projects.md](projects.md) describes a project and the compile and build
contract, [module-abi.md](module-abi.md) the metadata,
[installation.md](installation.md) installation and the release store, and
[contrib-modules.md](contrib-modules.md) writing and testing modules.

## From metadata to a running shell

1. `valise build` reads every `.meta` file in the project (`module.d/`, each
   `layers/<provider>/module.d/`) and the engine's own `module.d/`, as data,
   into an internal table. `valise registry` prints that table; nothing reads
   a saved copy.
2. For each POSIX shell in the bundle, the compiler resolves the roots'
   closure, applies the variant's exclusions, orders the modules by
   dependency, and writes `plans/<shell>.sh`. A module that publishes
   commands gets its own plan under `plans/commands/`.
3. The build copies the modules some shell loads, the capability prelude,
   and the Fish runtime when the bundle has Fish roots, then writes
   `manifest.tsv`. The release id is the SHA-256 of the manifest.
4. `valise install` copies the tree into the release store, verifies it,
   switches the active link, writes the startup-file blocks and the Fish
   hook, and publishes command stubs. If any step fails, install restores
   the previous state.
5. At startup, the POSIX block picks the plan for the running shell class
   (`bash`, `zsh`, `ksh`, or `sh`) and sources it. The plan contains the
   load order; it reads no metadata. Fish verifies the release, then runs
   the native Fish loader over the release's Fish metadata.

There is one release shape. The plan is generated ahead of time so that
startup does no resolution work and so that you can read exactly what will
run.

## The development loader

`entrypoints/profile.sh` and `lib/loader.sh` load modules straight from a
checkout, resolving dependencies when they are sourced. They are for working
on the engine's own modules and for the loader's tests; installed profiles
and `valise run` use compiled plans. The loader honors the same metadata,
including optional dependencies, platform gating, export checks, and failure
cleanup:

```sh
VALISE_ROOT=/path/to/valise-sh
VALISE_MODULE_ROOT=/path/to/modules
VALISE_MODULES='module_a module_b'
VALISE_MODE=strict
. "$VALISE_ROOT/entrypoints/profile.sh"
```

`VALISE_MODULES` unset means nothing is loaded. Its search path is described
in [module-abi.md](module-abi.md#the-development-loaders-search-path).

## Scope boundaries

The engine does not define your modules, your bundles, your workstation
policy, or wrappers around other tools. Those belong in your project.
`valise new` writes an empty project so you do not have to invent the
layout.

Project commands (`module`, `build`, `apply`, `status`, `lint`, `test`,
`run`, `compile`, `registry`, `explain-variant`, `explain-bundles`) run
inside a directory that holds `valise.conf`, found by walking up from the
working directory. Release commands (`install`, `release`, `uninstall`,
`init`, `doctor`, `make-manifest`) and `new`, `env`, `layer-lint`, and
`version` run anywhere.

Shared modules are vendored copies. You review a provider's changes, copy
them into `layers/<provider>/`, and rebuild. The engine does not fetch
updates, authenticate authors, or sign releases; the manifest detects bytes
that changed after the release was built.

## Verification

Run `make check-fast` while developing and `make check` for the full suite.
Extended runtime lanes run when their tools are installed; missing tools are
visible skips locally and failures in CI. Set `VALISE_REQUIRE_TOOLING=1` to
require them on a developer machine.

The Makefile and the tests live in the source repository. The npm package
ships the runtime, the docs, and the examples.
