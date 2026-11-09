# valise-sh

valise builds your shell profile from modules. Each module is a metadata file
and a shell body; valise reads the metadata as data, compiles a static
startup plan for each shell, and installs the result as a sealed, verified
release. sh, dash, BusyBox ash, bash, zsh, and ksh load the compiled POSIX
plans; Fish has a native loader.

You keep your modules in a valise project. The engine supplies the `valise`
CLI and a few generic modules (`valise_path`, `valise_editor`, and others).

## Quick start

```sh
git clone https://github.com/joeycumines/valise-sh.git
export PATH="$PWD/valise-sh/bin:$PATH"

valise new my-profile
cd my-profile
valise module new hello --exports=hello
$EDITOR modules/hello.sh
valise lint
valise apply
```

`valise apply` builds the project, installs the release, writes a managed
block into your startup files, and verifies the active release. Open a new
login shell to load it. `valise apply --dry-run` shows what would change
first, and `valise uninstall` removes everything install wrote.

To try it without touching your real home directory, point `HOME` and the
XDG directories at a scratch directory:

```sh
(
  set -eu
  demo=$(mktemp -d)
  trap 'chmod -R u+w "$demo"; rm -rf "$demo"' EXIT
  export HOME="$demo/home" XDG_DATA_HOME="$demo/data" \
    XDG_CONFIG_HOME="$demo/config" XDG_STATE_HOME="$demo/state" \
    XDG_BIN_HOME="$demo/bin"
  mkdir -p "$HOME"
  cd valise-sh/examples/profile-project
  valise apply
  bash -l -c greet
)
```

## A project

```
valise.conf      project settings
module.d/        <name>.meta: one metadata file per module
modules/         module bodies
layers/<p>/      modules vendored from another provider (optional)
bundles.tsv      the root modules for each shell
variants.tsv     named sets of modules to leave out (optional)
```

A module's metadata names its dependencies, the shells and platforms it
supports, the functions it exports, and optionally the exports to publish
as commands on `PATH`:

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

## Commands

| Command | Does |
|---|---|
| `new`, `module new\|list\|remove` | Scaffold a project and its modules. |
| `lint`, `test`, `run`, `env` | Check metadata and syntax, run module tests in a clean shell, run a script with modules loaded, print paths. |
| `build`, `apply`, `status` | Build a release, build and install it, compare the active release with the build. |
| `install`, `release list\|use\|rollback\|prune\|verify`, `uninstall` | Manage installed releases. |
| `init`, `doctor` | Print the startup snippet; diagnose the installation. |
| `compile`, `registry`, `explain-bundles`, `explain-variant`, `layer-lint`, `make-manifest` | Inspect and debug a build. |

`valise <command> --help` prints each command's contract.

## Documentation

- [docs/projects.md](docs/projects.md): the project layout, bundles,
  variants, compile, and build.
- [docs/contrib-modules.md](docs/contrib-modules.md): writing, linting, and
  testing modules.
- [docs/module-abi.md](docs/module-abi.md): every metadata field and what
  the plans do with it.
- [docs/installation.md](docs/installation.md): installing the CLI, startup
  files, published commands, the release store, and uninstalling.
- [docs/architecture.md](docs/architecture.md): how the pieces fit and what
  stays in your project.
- [docs/shared-modules.md](docs/shared-modules.md): layers other people
  consume.
- [docs/release-policy.md](docs/release-policy.md): compatibility and the
  release checklist.
- [examples/](examples/README.md): a sample project, a multi-shell test
  project, and a sample provider layer.
- [CHANGELOG.md](CHANGELOG.md)

## Development

```sh
make check-fast  # quick lane; no optional shells required
make check       # every available shell and runtime lane
```

`make check` uses the parsers in `manifests/parser-support.tsv`, the shells
`sh`, `bash`, `zsh`, `ksh`, `dash`, and `fish`, and BusyBox. A missing tool
is a visible skip locally and a failure when `CI=true` or
`GITHUB_ACTIONS=true`; `make VALISE_REQUIRE_TOOLING=1 check` requires them
locally. Machine-local settings go in an untracked `config.mk` (see
`config.mk.example`). Lima VM lanes run only when the instances exist.
