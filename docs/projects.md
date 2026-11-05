# Projects, bundles, variants, and builds

This document describes a valise project: the files it contains, how
`valise compile` and `valise build` turn them into plans and a release, and
how those commands fail. [module-abi.md](module-abi.md) covers the metadata
format; [installation.md](installation.md) covers what happens to a release
once it is built.

## The project layout

A project is a directory that holds `valise.conf`:

```
valise.conf          project settings
module.d/            primary modules: <name>.meta
modules/             primary module bodies (any layout below modules/)
layers/<provider>/   vendored provider layers (optional)
  module.d/          layer modules: contrib_<name>.meta
  modules/           layer module bodies
bundles.tsv          the root modules of each bundle, per shell
variants.tsv         build variants and what each leaves out (optional)
build/               build output; keep it out of version control
```

`valise new [dir]` writes this layout with a POSIX seed module
`profile_main`, a Fish seed module `profile_main_fish`, a `bundles.tsv` with
`sh`, `bash`, `zsh`, `ksh`, and `fish` rows, `variants.tsv`, and a
`.gitignore` for `build/`.

Project commands find the project by walking up from the working directory to
the first directory that holds `valise.conf`. `valise -C <dir> <command>` runs
a command as if it had been started in `dir`.

`valise.conf` has one `key=value` per line. Blank lines and `#` comments are
ignored; an unknown or repeated key is an error.

| Key | Meaning |
|---|---|
| `bundle` | Default bundle for build, apply, compile, and run (default `default`). |
| `variant` | Default variant (default `default`). |
| `requires_valise` | Oldest valise version that may build the project, such as `0.3.0`. An older valise refuses with `this project requires valise >= ...`. |
| `lint_layer_forbid` | Extended regular expression that must not match anything under `layers/` (case-insensitive). `valise lint` enforces it; use it to keep personal or employer material out of a layer you share. |

A layer's directory name is made of letters, digits, `_`, `-`, and `.`, and
may not start with `.` or contain `..`. Metadata and bodies must be regular
files reached without a symlink.

## Modules and the registry

The `.meta` files are the only source of truth. valise reads them as data,
never by sourcing them. Each build collects three groups of modules:

1. the project's `module.d/`, with source `module.d`;
2. each `layers/<provider>/module.d/`, with source
   `layers/<provider>/module.d`;
3. the engine's own modules, with source `valise`.

The engine modules (`valise_path`, `valise_editor`, `valise_history`,
`valise_pager`, `valise_xdg`, and the `valise_platform_*` modules) are always
available. They ship in a release only when the release loads them. The
`valise_` prefix is reserved for them, and every layer module must use the
`contrib_` prefix.

`valise registry [path]` prints the table valise builds from these files, for
inspection. It is internal: nothing reads a saved copy, so do not commit one.
The table is tab-separated, with one header row and one row per module, in
a fixed order: primary modules, then each layer, then the engine, each in
C-locale name order.

| # | Column | Meaning |
|---|---|---|
| 1 | `name` | Module identifier. |
| 2 | `version` | Version string; empty means unversioned. |
| 3 | `side_effect` | Side-effect class. |
| 4 | `requires` | Required dependencies. |
| 5 | `optional` | Optional dependencies. |
| 6 | `shells` | Shell classes. |
| 7 | `platforms` | Platforms. |
| 8 | `exports` | Exported functions. |
| 9 | `load` | Body path relative to the module's source directory; empty for a meta module. |
| 10 | `commands` | Exports published as commands. |
| 11 | `executables` | Scripts published as commands. |
| 12 | `tests` | Test scripts for `valise test`. |
| 13 | `source` | `module.d`, `layers/<provider>/module.d`, or `valise`. |

Building the table also validates it. A `name` that differs from its file
name, a missing body, executable or test, a symlink, a misplaced prefix, or
invalid metadata stops the command and names the file.

A module reference is a bare name or a qualified `name@source`. A bare
dependency resolves to the module with that name in the same source when
there is one, otherwise to the only module with that name. A bare bundle root
or exclusion resolves to the primary module when there is one, otherwise to
the only module with that name; when several sources define the name, qualify
it.

## Bundles: the root modules for each shell

`bundles.tsv` is tab-separated: bundle, shell, and a space-separated list of
root modules. The first row may be a header.

```
bundle	shell	roots
default	sh	profile_main
default	bash	profile_main profile_bash
default	zsh	profile_main
default	ksh	profile_main
default	fish	profile_main_fish
work	bash	profile_main profile_work
```

The shell column is one of `sh`, `bash`, `zsh`, `ksh`, and `fish`. `sh` is the
plan for any POSIX shell that is not bash, zsh, or ksh, such as dash or
BusyBox ash. A bundle without a row for a shell loads nothing there.

Roots are starting points. The plan loads each root's whole closure of
`requires` and available `optional` dependencies, in dependency order.
`valise explain-bundles [--bundle=<name>] [--variant=<name>]` prints each
bundle's roots and ordered closure per shell, with each module's source.

A root, and every module it requires, must support the shell and the
platform it runs on: in strict mode an unsupported platform is a failure. A
module that exists only for some platforms belongs behind an optional edge.
Write an aggregator whose `optional=` lists the per-platform modules and use
the aggregator as the root; the module for the running platform loads, and
the others are skipped without a message.

## Variants: what to leave out

`variants.tsv` is tab-separated: variant name, description, and a
space-separated list of excluded modules. Without the file, the only variant
is `default`, which excludes nothing.

```
variant	description	excluded
default	All project modules	
lean	No editor defaults	valise_editor
```

Each exclusion must resolve to exactly one module; an unknown or ambiguous
exclusion is an error. An excluded module is removed from every closure, and
its optional edges are dropped. **If a remaining module requires an excluded
module, the build fails**, naming both; exclude the dependents too. Nothing is
removed silently.

`valise explain-variant [--bundle=<name>] [name]` shows a variant's
description, its exclusions, and how many of the bundle's roots it removes
per shell. The bundle chooses the roots, and the variant then removes
modules from what they reach.

## `valise compile`

```sh
valise compile [--bundle=<name>] [--variant=<name>] <output-dir>
```

Compile writes `<output-dir>/<shell>.sh` for each POSIX shell the bundle has
roots for, and nothing else. The output directory must be empty or absent;
compile stages beside it and publishes only after every plan compiled.

A plan is a POSIX shell file:

```
# valise-plan-v2
# Generated by valise compile; DO NOT EDIT.
# plan=bash
# roots=profile_main
# order=valise_path profile_main
```

The header names the format, the shell, the roots, and the resolved load
order. Sourced with `VALISE_MODULE_ROOT` naming a release, the plan:

- reads `VALISE_MODE` (`strict` or `permissive`; default `strict`);
- probes the platform once and gates each module by `platforms=`;
- sources `runtime/capabilities.sh`, so the `sp_cap_*` helpers stay available
  to module functions afterwards;
- refuses to load a module whose declared export already exists as an alias,
  function, or builtin (an export may shadow a command on PATH), and checks
  after loading that each export is defined;
- skips a module whose required dependency failed or was skipped, and says
  which;
- in strict mode, returns nonzero at the first failure among the roots and
  everything they require;
- in permissive mode, reports each failure, continues with unrelated
  modules, and returns zero;
- loads an optional dependency first when it can; its absence never affects
  the module that declared it;
- with `VALISE_RELOAD=1`, removes the plan's declared exports first, so the
  plan can be sourced again.

Compile fails before writing anything when the variant or bundle is unknown,
an exclusion or root does not resolve, a variant exclusion breaks a required
dependency, a module in a closure has a side-effect class that is not safe at
startup (`generated-file`, `update-network`, or `install-time`), or a module
is not representable as plan source.

## `valise build`

```sh
valise build [--bundle=<name>] [--variant=<name>] [out]
```

Build produces an installable release tree at `build/release`, or at `out`,
which must then be empty or absent. The tree contains:

```
valise-release.conf                   format=2, valise_version, bundle, variant,
                                      roots_<shell>=, modules=, commands=
manifest.tsv                          the release manifest
plans/<shell>.sh                      one plan per POSIX shell with roots
plans/commands/<module>.sh            a plan per module that publishes commands
bin/<command>                         command launchers and executables
runtime/capabilities.sh               the capability prelude
runtime/fish/{metadata,loader,profile}.fish   when the bundle has fish roots
module.d/, modules/...                primary modules some shell loads
layers/<provider>/module.d, ...       layer modules some shell loads
valise/module.d, valise/modules/...   engine modules some shell loads
```

Only modules in some shell's closure are copied, with their metadata. A
module that a variant excludes, or that no root reaches, is absent from the
release, together with its body. The Fish runtime resolves the Fish roots
recorded in `valise-release.conf` against the copied metadata when Fish
starts. See [module-abi.md](module-abi.md#published-commands) for `bin/`.

Directories are `0755`, files `0644`, and `bin/` entries `0755`. Build
stages beside the destination and publishes only after the tree and its
manifest are complete. A previous `build/release` is moved aside first and
put back if publication fails, so a failed build leaves the previous output
in place. Building the same project twice produces byte-identical output.

## `valise apply` and `valise status`

`valise apply [--bundle=<name>] [--variant=<name>] [--no-integration]
[--dry-run]` builds to `build/release`, installs it, writes the shell
integration and command stubs, and verifies the active release. Running it
again changes nothing. `--dry-run` stops after the build and prints what
install would change; see [installation.md](installation.md).

`valise status` reports the project defaults, the integration in each startup
file, the bundle, variant, and valise version the active release was built
with, and whether the active release matches `build/release`.

## Checking a project

`valise lint` and `valise test` check a project without installing it, and
`valise run` loads modules into a throwaway shell; see
[contrib-modules.md](contrib-modules.md#checking-and-testing-modules).
