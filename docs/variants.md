# The compile and build contract

This document describes how a consuming project turns metadata into an
installed release: what each input file contains, what `valise compile`
produces, what `valise build` packages, and how the two fail.

Two different mechanisms share the word "variant". They compose, but they are
not the same command.

- **Build variants** are exclusion lists decided at compile time inside the
  consuming project. They live in `shell/release/install-variants`.
- **Installed releases** are sealed directories on this machine. They are
  listed, switched, and pruned with `valise release list|use|prune`.

Neither reads the other's file. `release use` never reads `install-variants`;
variant exclusion is decided when the plans are compiled.

## The project layout

A consuming project that uses the CLI has this shape:

```
shell/
  module.d/            primary modules: <name>.meta
  modules/             primary module bodies
  layers/<provider>/   provider layers (optional)
    module.d/          layer modules: <name>.meta
    modules/           layer module bodies
  release/
    bundle-roots       which modules seed each bundle, per shell
    install-variants   build variants and their exclusion lists
    module-registry.tsv  GENERATED from the metadata above
    project.conf       project defaults (optional)
```

`shell/module.d/` and `shell/release/module-registry.tsv` are the two markers
that identify a directory as a valise project. A layer's `<provider>` is a
path component made of letters, digits, `_`, `-`, and `.`; it may not start
with `.` or contain `..`. The registry rejects any other provider name,
because the compiler emits module identities from it as shell source text. The CLI resolves the project
root from the working directory first, then from the engine's own location, so
running `valise compile` from the project root always compiles *that* project
rather than a tree that merely happens to contain the engine.

## Metadata is the source of truth

Module metadata is data: `key=value` lines in a `.meta` file, parsed and
validated, never sourced. See [module-abi.md](module-abi.md) for the full
field list and the grammar each value must satisfy.

The registry is a **generated artifact**, not a second source of truth. The
generator is `valise registry`:

```sh
valise registry                       # write shell/release/module-registry.tsv
valise registry --check               # compare, fail on drift, write nothing
valise registry path/to/registry.tsv  # write somewhere else
```

`valise build` regenerates the registry before it builds, so a project
that only has `.meta` files and bodies builds with no hand-written TSV. The
generator refuses to publish a registry when the metadata is inconsistent:
a `name` that does not match its filename, a missing body, a layer module
without the `contrib_` prefix, a load path that is not representable, or an
export name that is not a shell identifier.

The registry is a tab-separated file with one header row and one row per
module:

| # | Column | Meaning |
|---|---|---|
| 1 | `name` | Module identifier. |
| 2 | `version` | Optional version string; empty means unversioned. |
| 3 | `side_effect` | Startup side-effect class. |
| 4 | `requires` | Space-separated required dependencies. |
| 5 | `optional` | Space-separated optional dependencies. |
| 6 | `shells` | Space-separated shell identifiers. |
| 7 | `platforms` | Space-separated platform identifiers. |
| 8 | `exports` | Space-separated exported identifiers. |
| 9 | `load` | Repository-relative body path, or empty for a meta module. |
| 10 | `updates` | Space-separated update registration identifiers. |
| 11 | `source` | Directory that holds the `.meta`: `shell/module.d` or `shell/layers/<provider>/module.d`. |

Rows come out in a fixed order: the primary modules of `shell/module.d/`
first, then the layer modules of each `shell/layers/<provider>/module.d/`,
each group in C-locale name order. The order does not depend on the caller's
locale, so regenerating an unchanged project produces a byte-identical file.

## Bundles: which modules seed each shell

A bundle names the root modules for each shell. The file is
`shell/release/bundle-roots`, tab-separated:

```
# bundle	shell	roots
default	bash	profile_main
default	zsh	profile_main
default	ksh	profile_main
```

- Column 1 is the bundle name.
- Column 2 is the shell the roots apply to.
- Column 3 is a space-separated list of root module names.

A root may be a bare name (`profile_main`), which resolves against
`shell/module.d/`, or a qualified name (`contrib_tool@shell/layers/vendor/module.d`)
that names its source directory explicitly. Use the qualified form when a
layer module and a primary module share a name.

The first row may be a header (`bundle`, `shell`, `roots`); it is not a bundle
definition.

A bundle names the **starting points**, not the final set. `valise compile`
walks each root's `requires` and `optional` edges, so the installed plan
contains the whole reachable closure. `valise explain-bundles` prints that
closure per shell, which is the fastest way to see what a bundle actually
loads:

```sh
valise explain-bundles
valise explain-bundles --bundle=default
```

It reads `bundle-roots` and the registry directly, and needs no Python. An
unknown `--bundle` name is an error, not an empty report.

## Variants: what to leave out

A build variant is an exclusion list. The file is
`shell/release/install-variants`, tab-separated:

```
variant_name	description	excluded_modules
default	All project modules	
workstation-lean	No editor defaults	contrib_editor
```

- Column 1 is the variant name.
- Column 2 is a human-readable description.
- Column 3 is a space-separated list of excluded modules.

An exclusion is a bare module name (matching a `shell/module.d/` module) or a
qualified name (`<name>@<source>`) that names the source directory
explicitly. Every exclusion must match exactly one registry row; an unknown
or ambiguous exclusion fails the compile rather than silently excluding
nothing.

Exclusion is applied to the whole resolved graph, not just the roots. A module
excluded by name is not loaded, and neither is anything that depends on it.
`valise explain-variant <name>` shows a variant's description, its exclusion
list, and the per-shell impact.

The variant and the bundle compose: the bundle decides the starting points
and the layers they reach, and the variant then removes modules from the
resolved graph.

## `valise compile`

```sh
valise compile [--bundle=<name>] [--variant=<name>] <output-dir>
```

Compile resolves the module graph and writes one plan per shell. It does not
copy module bodies; that is `build`'s job.

The steps, in order:

1. Resolve the project root. Fail with `cannot find source tree` when the
   project has no `shell/release/module-registry.tsv`.
2. Validate the variant: the name must appear exactly once in
   `install-variants`, and every exclusion must match exactly one registry
   row.
3. Validate the bundle when `--bundle` is given: the name must exist, and
   its roots must resolve.
4. For each of `bash`, `zsh`, and `ksh`, resolve the
   bundle's roots for that shell, walk the dependency closure, drop the
   variant's exclusions, select each module by `shells=`, emit its
   `platforms=` gate, and emit a plan.
5. Replace the output directory atomically.

The output directory must be empty or absent. Compile stages into a private
sibling directory and publishes only after every plan has compiled, so a
failed compile never leaves a half-written output tree.

### What a plan contains

Each plan is a POSIX shell file at `generated/installed-modules.<shell>`:

```
# shell-profile-installed-modules-v1
# Generated by valise compile; DO NOT EDIT.
# plan=bash
# roots=profile_main
# order=hello profile_main
```

The header names the format, the generator, the shell, the roots, and the
resolved load order. The body then:

- validates `VALISE_MODE` (`strict` or `permissive`; default `strict`);
- probes the platform once and gates each module by `platforms=`;
- sources `vendor/shell-profile/lib/capabilities.sh`, so `sp_cap_*` helpers
  stay available to module functions after the plan finishes;
- checks each module's declared exports before and after loading it;
- does not run a module whose required dependency is unavailable, whether that
  dependency failed or was skipped for this platform, and reports it by name;
- in strict mode, returns nonzero at the first failure in the required closure:
  the bundle's roots and everything they require;
- in permissive mode, reports each failure, continues with the unrelated
  modules, and returns zero;
- treats an optional dependency as best effort: it loads first when it can, and
  its absence never affects the module that declared it. A failure is reported;
  an unsupported platform is expected and prints nothing;
- when `VALISE_RELOAD=1` is set, clears the plan's declared exports first, so
  the plan can be sourced again.

The plan is the compiled equivalent of the loader: same dependency rules,
same export checks, same strict and permissive behavior. The plan is static and fast;
the loader parses metadata at runtime and is the fallback for releases that
ship an `entrypoints/` tree instead of `generated/` plans.

### Failure behavior

Compile fails closed, before writing anything, when:

- the project root cannot be resolved;
- the variant is unknown or ambiguous;
- a variant exclusion matches no registry row, or more than one;
- the bundle is unknown, or its roots do not resolve;
- a module in the closure has a `side_effect` that is not safe to source at
  startup (`generated-file`, `update-network`, `install-time`);
- the capabilities prelude is missing or defines no `sp_cap_*` functions;
- the registry names a module whose source, load path, or export name is not
  representable.

Fish plans are not produced by the POSIX plan generator. `valise compile`
emits POSIX plans only; a Fish integration uses the native Fish loader.

## `valise build`

```sh
valise build [--bundle=<name>] [--variant=<name>] [out]
```

Build a complete, installable release tree. It runs `valise
compile` internally, so everything compile validates is validated here too.

The built tree has this layout:

```
generated/installed-modules.bash      compiled plans
generated/installed-modules.zsh
generated/installed-modules.ksh
module.d/<name>.meta                  primary module metadata
modules/<path>                        primary module bodies
layers/<provider>/module.d/<name>.meta   layer metadata
layers/<provider>/<path>                 layer bodies
vendor/shell-profile/lib/capabilities.sh the capability prelude
shell/release/                        bundle-roots, install-variants, registry
shell/install/profile-release.manifest  the release manifest
```

Build:

1. Runs from the project root — it needs `shell/module.d/`.
2. Regenerates `shell/release/module-registry.tsv` from the metadata.
3. Compiles the plans into a staging directory.
4. Copies the capability prelude from the installed engine. The packaged
   file is the same file the plans were built against.
5. Copies each module's metadata and body to its release path. A primary
   module lands at the release root; a layer module lands at
   `layers/<provider>/`, matching the paths the plan references.
6. Normalizes file modes to `0644` and writes the release manifest.
7. Publishes the tree at the destination.

Like compile, build stages beside the destination and publishes only after
the complete tree and its manifest exist. A failed build never leaves a
partial release. The default destination is `build/release`; an existing
default tree is replaced only after the new tree has compiled and been
manifested. An explicit destination must be empty or absent.

Building the same project twice produces byte-identical output, including
the manifest.

## `valise build` and `valise apply`

`valise build` produces the tree; `valise apply` adds install and shell
integration on top of it:

- `valise build [--variant=<name>] [--bundle=<name>] [out]` builds to
  `build/release` by default, reading the variant and bundle defaults from
  `shell/release/project.conf`.
- `valise apply [--variant=<name>] [--bundle=<name>] [--no-integration]`
  builds, installs the release, writes the managed shell integration,
  verifies the active release, and reports what changed.

Both are idempotent: running them twice leaves the same state.

`shell/release/project.conf` holds the defaults:

```
variant=default
bundle=default
```

## `valise release list`, `use`, and `prune`

These operate on the releases installed on this machine. No source tree is
needed.

```sh
valise release list
valise release use <release-id>
valise release prune --keep=3
```

Release directories are named by the content-derived SHA-256 of their
manifest, and the active one is marked in the list. `release use` verifies
the named release byte-for-byte against its own manifest before switching the
active pointer.

`release prune --keep=N` removes old releases. It keeps the active release
and the `N` newest others, ordered by directory modification time. Before
removing any candidate it verifies the candidate against its own manifest; a
release that fails verification is **kept** and reported, because a release
that cannot be verified may be the only recoverable copy. The default is
`--keep=3`.
