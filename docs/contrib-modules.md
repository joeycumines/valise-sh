# Contributing Modules

This guide covers modules loaded by the valise-sh engine. A module is
usually a metadata file and a shell body; consumer projects may add their
own naming, review, and release rules.

## Module structure

A file-backed module has a metadata file and a body. POSIX bodies usually
end in `.sh`; Fish bodies end in `.fish`:

```
module.d/<name>.meta
modules/<area>/<name>.sh
```

The metadata file is read by the engine before any body is sourced. It uses
one `key=value` field per line:

```text
name=example_tool
requires=
optional=
shells=sh bash zsh ksh
platforms=any
side_effect=read-only
exports=example_tool_loaded
updates=
version=1.0.0
load=modules/system/example_tool.sh
```

### Metadata fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Stable identifier matching `[a-z_][A-Za-z0-9_]*` |
| `requires` | No | Space-separated hard dependencies (loaded first) |
| `optional` | No | Space-separated best-effort dependencies |
| `shells` | Yes | Supported shells: `sh`, `bash`, `zsh`, `ksh`, `fish`. `sh` means every POSIX shell (sh, bash, zsh, ksh, dash) |
| `platforms` | Yes | `any`, `darwin`, `linux`, or BSD family values |
| `side_effect` | Yes | One of: `read-only`, `path-env`, `generated-file`, `update-network`, `install-time`, `local-secret`, `local-state`, `work-only` |
| `exports` | No | Public functions this module declares |
| `updates` | No | Update registration identifiers mapped in the project update manifest |
| `version` | No | Module version (digit-first, digits/letters/`.`/`_`/`-`); different versions of one name across roots fail closed with a skew diagnostic |
| `load` | Conditionally | Repository-relative path to the module body |

At least one of `load` or `requires` must be present. `load` and `requires`
are not mutually exclusive — a module
may declare both and will load its dependencies first, then its own body. A
module with `requires` and no load target is a **meta module**: it names
dependencies and has no body. See
[module-abi.md](module-abi.md#meta-modules).

### Naming

Modules that live only in a layer root (see
[module-abi.md](module-abi.md) multi-root search path) must carry the
`contrib_` name prefix; the loader rejects unprefixed layer-only modules
fail closed. Modules in the primary root have no prefix requirement.
Same-name modules across roots must be byte-identical or the load fails
closed naming both paths.

## Engine capabilities

Use `sp_cap_*` functions from `lib/capabilities.sh` instead of open-coding
platform-specific commands. The POSIX entrypoint sources the capability
library before the loader, so module bodies can call these directly.

**The helpers stay available after the profile loads.** A compiled plan
sources the capability prelude and leaves it in place, so a function your
module defines can call `sp_cap_os` or any other helper long after the plan
finished loading. Both the compiled plan and the loader keep the helpers
available at runtime.

Available capabilities include:

- `sp_cap_canonical_path <path>` — resolve absolute path through symlinks
- `sp_cap_path_under <base> <target>` — check if target is under base
- `sp_cap_file_mtime <path>` — portable modification time (epoch seconds)
- `sp_cap_mktemp_dir [prefix] [parent]` — secure temporary directory
- `sp_cap_mktemp_file <parent> <prefix>` — secure temporary file
- `sp_cap_homebrew_prefix` — locate Homebrew installation
- `sp_cap_command_exists <name>` — portable command existence check
- `sp_cap_command_path <name>` — resolve command to absolute path
- `sp_cap_os` — print normalized OS name
- `sp_cap_cpu_count` — print available CPU count

See [module-abi.md](module-abi.md) for the full capability contract and
[architecture.md](architecture.md) for scope. Shared modules — the ones
other people consume — carry additional governance: namespace ownership,
review, deprecation, and removal are policy questions, and the written
policy plus the curated index lives in
[shared-modules.md](shared-modules.md).

## Authoring workflow

### In a consuming project

Inside a project that uses the CLI, the CLI creates the files for you:

```sh
valise new demo                 # scaffold a project
cd demo
valise module new hello --exports=hello
```

`valise module new` writes `shell/module.d/hello.meta` and
`shell/modules/hello.sh`, and wires `hello` into the seed aggregator's
`requires=` so the module is actually reachable. It refuses a duplicate
export name. Edit the body, then:

```sh
valise build                    # build to build/release
valise apply                    # build, install, integrate, verify
```

You never hand-write the registry: `valise build` and `valise apply`
regenerate `shell/release/module-registry.tsv` from the metadata.

### In the engine repository

1. Write the two files. Start from an existing pair — `module.d/valise_pager.meta`
   plus `modules/system/valise_pager.sh` is the smallest real example.
2. Validate the metadata as data:

   ```sh
   . ./lib/metadata.sh
   sp_metadata_read module.d/example_tool.meta
   ```

   The reader prints the normalized record or a precise diagnostic
   (`invalid side_effect`, `unknown metadata field`, and so on). It never
   sources the body.
3. Load it through the entrypoint and call the export:

   ```sh
   VALISE_MODULE_ROOT="$PWD" \
   VALISE_MODULES='example_tool' \
   VALISE_MODE=strict \
   . ./entrypoints/profile.sh
   example_tool_loaded
   ```

   Strict mode fails closed on any problem: missing dependency, a declared
   export missing after the body runs, an export that already exists,
   reserved-utility shadowing, shell/platform mismatch. The loader checks
   what `exports=` declares; it does not reject a body that defines extra
   private functions, so list everything you consider public. Under zsh
   the entrypoint handles word-splitting itself; source it the same way.
4. Check parser coverage. `manifests/parser-support.tsv` declares which
   POSIX shells must parse each file class. Place portable bodies under a
   path pattern the table already covers (for example `modules/system/*.sh`)
   or add a row for your pattern, then run the gate:

   ```sh
   make test-parser-support
   ```

   This target belongs to the engine's source repository. The npm package
   ships the runtime and the docs, not the Makefile or the parser table, so
   a package consumer checks parser coverage by hand: run every POSIX shell
   you claim to support over the body (`sh -n`, `bash -n`, `zsh -n`,
   `ksh -n`) and confirm each one accepts it.

5. Publish a release containing your module tree and prove the whole
   path end to end (make-manifest, install, release verify):

   ```sh
   valise make-manifest ./mytree
   cd mytree && valise install && valise release verify
   ```

   See [installation.md](installation.md) for release integrity and
   provenance.

## Shipped modules

The reusable `contrib_` modules are listed in
[shared-modules.md](shared-modules.md). For example, load PATH and editor
defaults from a checkout with:

```sh
VALISE_MODULE_ROOT="$PWD" \
VALISE_MODULES='valise_path valise_editor' \
VALISE_MODE=strict \
. ./entrypoints/profile.sh
```
## Testing checklist

For every new module, run each step and confirm the named behavior. The
commands in steps 1 to 3 work from a checkout of this repository or from an
npm-installed package; the `make` targets belong to the source repository
only.

1. `sp_metadata_read module.d/<name>.meta` prints the normalized record
   (step 2 above) and the load path is covered by a
   `manifests/parser-support.tsv` row (`make test-parser-support` in the
   source repository).
2. Source the module in a clean environment — the body prints nothing when
   its prerequisites are absent and defines every name in `exports=`:

   ```sh
   env -i HOME="$PWD/.fresh-home" PATH=/usr/bin:/bin \
     VALISE_MODULE_ROOT="$PWD" VALISE_MODULES='<name>' VALISE_MODE=strict \
     /bin/sh -c '. ./entrypoints/profile.sh'
   ```

   (Create `./.fresh-home` first or point `HOME` at any empty directory;
   never source against your live profile.)
3. Source it twice in one strict session or call the entrypoint repeatedly:
   the second load must fail closed with `declared export already exists`
   (the loader forbids double-definition), and calling an idempotent
   function twice must leave the same state.
4. The body performs no writes at source time: `side_effect` is
   `read-only`, `path-env`, or `local-state`, and `generated-file`/
   `update-network`/`install-time` bodies are rejected during ordinary
   source.
5. Every public function appears in `exports=` — the loader verifies each
   declared export exists after the body runs, and cleans them up on
   failure.
6. Tests run in quarantined homes: this repository's suites already use
   fresh temporary `HOME`, controlled `TMPDIR` and `PATH`, and cleared
   startup hooks (`make check-fast` to confirm the engine gate). Stub
   network and secrets in your own tests; never read a live profile.

Run the engine's own fast gate while authoring:

```sh
make check-fast
```

and the full matrix (`make VALISE_REQUIRE_TOOLING=1 check`) before claiming
release readiness. The extended-runtime lanes are strict in CI and can be
required locally with the same override. Both targets live in the source
repository; the npm package ships the runtime and docs, not the Makefile.

`valise layer-lint <layer-name>` validates a contribution layer's
structure, namespace compliance, file permissions, metadata integrity, and
dependency closure. It needs no Python, but it does need a layer tree: a
provider directory under a consuming project's `shell/layers/`, or a path to
a layer tree containing `module.d/`. In a consuming project:

```sh
valise layer-lint <provider-name>
```
