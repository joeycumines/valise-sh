# Writing modules

A module is a metadata file and, usually, a shell body. This guide covers
writing one in a valise project, checking and testing it, and deciding
whether it belongs in a shareable layer. [module-abi.md](module-abi.md) is
the full metadata contract; [projects.md](projects.md) covers bundles,
variants, and builds.

## Create a module

```sh
valise new demo
cd demo
valise module new hello --exports=hello
```

`valise module new` writes `module.d/hello.meta` and `modules/hello.sh` and
adds `hello` to the `requires=` of the bundle's POSIX root, so a build
loads it. When the default bundle has several POSIX roots, name the ones to
change with `--into=<module>[,<module>...]`, or pass `--no-wire` to wire
the module yourself. Edit the body, then:

```sh
valise lint     # check metadata, bundles, variants, and syntax
valise apply    # build, install, write the integration, verify
```

A module's metadata looks like this:

```text
name=hello
version=1.0.0
side_effect=read-only
requires=valise_path
optional=
shells=posix
platforms=any
exports=hello
commands=hello
tests=tests/hello.sh
load=modules/hello.sh
```

Choose `shells` by what the body needs:

- `posix` for a body that runs in every POSIX shell: dash, BusyBox ash,
  bash, zsh, and ksh.
- `sh` for a body that runs only in the generic class (dash, ash, and other
  plain `sh` implementations), listed together with the explicit shells it
  also supports: `shells=sh bash ksh` loads in dash, bash, and ksh, and not
  in zsh.
- `bash`, `zsh`, or `ksh` for a body that uses that shell's features.
- `fish` for a native Fish body (`.fish`). A Fish module never runs a POSIX
  body, so a feature that needs both shells is two modules.

Zsh runs module functions with the user's options. A body that relies on
word splitting of unquoted expansions behaves differently in zsh, where it
is off by default; quote expansions, split explicitly, or leave zsh out of
`shells`.

`side_effect` says what the body does when sourced. Startup modules use
`read-only`, `path-env`, `local-state` (writes under the XDG state
directory), `local-secret` (reads secrets that live on this machine), or
`work-only`. A build refuses `generated-file`, `update-network`, and
`install-time` in a startup closure.

List every public function in `exports`. The plan refuses to load a module
whose export already exists, checks that each export is defined after the
body runs, and removes them again when the module fails. List exports that
should also run from scripts and other programs in `commands`; see
[module-abi.md](module-abi.md#published-commands).

Use the `sp_cap_*` helpers from the capability prelude instead of
platform-specific commands. They stay defined after the profile loads, so
your functions can call them later:

- `sp_cap_os`, `sp_cap_cpu_count`, `sp_cap_homebrew_prefix`
- `sp_cap_command_exists <name>`, `sp_cap_command_path <name>`
- `sp_cap_canonical_path <path>`, `sp_cap_path_under <base> <target>`
- `sp_cap_file_mtime <path>`
- `sp_cap_mktemp_dir [prefix] [parent]`, `sp_cap_mktemp_file <parent> <prefix>`

The engine also ships modules a project can require: `valise_path`
(`valise_path_prepend` and `valise_path_append`), `valise_editor`,
`valise_history`, `valise_pager`, `valise_xdg`, and the `valise_platform_*`
modules. [shared-modules.md](shared-modules.md) lists them.

## Checking and testing modules

`valise lint [--require-parsers] [module...]` checks the project and reports
every problem it finds:

- each metadata record, its name, its prefix, and the files it names;
- each layer: `contrib_` names, `version=`, safe file modes, and
  dependencies that stay inside the layer or the engine;
- the `lint_layer_forbid` pattern from `valise.conf`, if set;
- every bundle compiled for every variant and shell, which catches unknown
  roots and exclusions, missing dependencies, and exclusions that break a
  remaining module;
- the syntax of each body and test, with the parser of every shell the module
  declares (`dash` or a plain `sh`, `bash -n`, `zsh -n`, `ksh -n`, and
  `fish --no-execute`). A missing parser is reported as a skip, or as a
  failure with `--require-parsers`.

`valise test [--shell=<class>] [--require-shells] [module...]` runs each
module's `tests=` scripts. For every shell class the module declares whose
interpreter is installed, it builds a release with the module as its only
root, starts the shell with `env -i` and a fresh `HOME`, `TMPDIR`, and XDG
tree, loads the module in strict mode, and runs the test. `PATH` is
`${VALISE_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}` plus the interpreter's
directory. A test passes when it exits 0:

```sh
# tests/hello.sh
[ "$(hello world)" = 'hello world' ] || { echo "got: $(hello world)"; exit 1; }
```

The output names each run (`ok hello [bash] tests/hello.sh`), shows a
failing test's output, and ends with a count; any failure makes the command
fail. A test that needs a file before the module loads (a secret, a config
file) writes it and calls `valise_test_reload`, which loads the module again.
Tests see `VALISE_TEST_ROOT` (the scratch directory, which holds `HOME`),
`VALISE_TEST_MODULE`, `VALISE_TEST_MODULE_DIR`, `VALISE_TEST_SHELL`, and
`VALISE_PROJECT_ROOT`. Fish tests (`.fish`) run only in Fish; other tests
run only in POSIX shells.

`valise run [--shell=<class>] [--module=<m>]... [--bundle=<b>]
[--variant=<v>] [--keep-env] -- <script> [args...]` loads modules into a
shell and runs a script there, for quick checks:

```sh
valise run --shell=zsh --module=hello -- 'hello "$@"' a b
valise run --bundle=work -- 'command -v my_work_function'
```

Its environment is quarantined like `valise test` unless `--keep-env` is
given, and its exit status is the script's.

None of these commands installs anything or reads your startup files. To
check a layer tree outside a project, run `valise layer-lint <path>`.

## What belongs in a layer

A layer under `layers/<provider>/` is a set of modules another person could
vendor unchanged. Before moving a module into a layer, check:

- **No employer material**: no account IDs, hostnames, cloud profiles,
  internal project names, or anything else tied to one organization.
- **No personal configuration**: no home-directory paths, chosen editor,
  toolchain, model, or theme.
- **No dependency outside the layer** other than engine modules. A
  dependency on one of your primary modules cannot be satisfied in someone
  else's project.
- **Mechanism, not preset.** Keep a reusable engine (a git helper, a path
  function) separate from the presets that configure it for one person. Ship
  the engine in the layer and keep presets in the primary modules, or in a
  separate layer module that requires the engine.
- **One purpose per module.** A grab-bag module forces a consumer to take
  everything or nothing.
- **An owner segment**: name modules `contrib_<owner>_<thing>`, so two
  providers do not collide on a name.
- **A version.** Every layer module needs `version=`; bump it on an
  incompatible change.

Set `lint_layer_forbid` in `valise.conf` to a pattern for the identifiers
that must never reach the layer, such as an employer name, and `valise lint`
will fail when one appears. [shared-modules.md](shared-modules.md) covers
ownership, review, and deprecation for layers other people consume.

## Modules in the engine repository

The engine's own modules live in this repository's `module.d/` and
`modules/` and use the `valise_` prefix. `manifests/parser-support.tsv`
declares which parsers must accept each file class; it ships in the package,
and `make test-parser-support` checks it in the source repository. Load an
engine module from a checkout without installing anything through the
development entrypoint:

```sh
env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin /bin/sh -c '
  VALISE_MODULE_ROOT="$PWD" VALISE_MODULES="valise_path" VALISE_MODE=strict
  . ./entrypoints/profile.sh && command -v valise_path_prepend'
```

Run `make check-fast` while working and `make check` before committing.
