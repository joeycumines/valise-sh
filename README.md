# valise-sh

valise-sh is a POSIX shell-profile engine. It loads shell configuration from
modules described by declarative metadata files. The metadata is parsed as
data and never executed; the loader resolves the dependency graph and sources
module bodies in deterministic order. The POSIX core runs under `sh`, `dash`,
`ksh`, and `bash`; Fish is supported through a native loader in `lib/fish/`.
The repository also includes the `valise` CLI, which installs sealed
shell-profile releases and verifies them before use.

A consuming project can split its shell configuration into modules with
declared dependencies, then test and select those modules explicitly. The
engine is designed to be vendored by that project, for example as a Git
submodule; the consumer owns its profile and release contents.

## Try a sample release

This walkthrough builds and installs the included sample profile in an
isolated temporary home. `valise install` deploys its normal shell
integration there, so your real home directory and startup files are left
untouched.

```sh
git clone https://github.com/joeycumines/valise-sh.git
cd valise-sh
export PATH="$PWD/bin:$PATH"

# Isolate HOME and XDG state; the trap also removes read-only release files.
(
  set -eu
  _demo_state=$(mktemp -d)
  cleanup_demo() {
    chmod -R u+w "$_demo_state" 2>/dev/null || :
    rm -rf "$_demo_state"
  }
  trap cleanup_demo EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p "$_demo_state/home"
  export HOME="$_demo_state/home"
  export XDG_DATA_HOME="$_demo_state/data"
  export XDG_CONFIG_HOME="$_demo_state/config"
  export XDG_STATE_HOME="$_demo_state/state"

  # Build, install, and apply the sample profile project.
  (cd examples/profile-project && valise apply)

  # Run the greeting function exposed by the active profile.
  bash -l -c 'greet'
)
```

For the multi-shell test fixture and verification scenarios, see
[examples/e2e/README.md](examples/e2e/README.md). For the smallest possible
loader example without installation, use `examples/local/` as described in
[examples/README.md](examples/README.md).

## Build your own profile

The sample above loads modules from an example profile. To build your own,
start from the project scaffold:

```sh
export PATH="$PWD/bin:$PATH"
valise new my-profile
cd my-profile
```

That writes a project with a metadata directory, a module body, bundle
roots, variants, and `project.conf`. Add modules with `valise module new`,
then build and install:

```sh
valise build   # build a release under build/release/
valise apply   # install it and write the managed shell integration
```

`examples/profile-project/` is a worked version of this: it has two modules,
a provider layer, two variants, and a bundle. Its
[README](examples/profile-project/README.md) walks through each step and
explains what the generated release contains.

## Repository layout

- `entrypoints/profile.sh` — the portable entrypoint. It is sourced, not
  executed: it resolves the engine root, sources the three libraries, and
  calls the loader with the requested modules.
- `lib/metadata.sh` — parses `module.d/*.meta` files as data and validates
  identifiers, lists, paths, shells, platforms, and side-effect classes.
- `lib/loader.sh` — resolves the dependency closure, selects modules by
  shell/platform/phase, sources bodies, checks declared exports, and cleans
  up on failure.
- `lib/capabilities.sh` — portable helpers (`sp_cap_*`) that modules call
  instead of platform-specific commands.
- `lib/fish/` — native Fish loader and metadata reader. The Fish path never
  sources POSIX shell bodies.
- `bin/valise` — the CLI: init, install, release, doctor, make-manifest,
  registry, new, module, build, apply, status, compile, explain-variant,
  explain-bundles, layer-lint, version.
  `init`, `install`, `release`, `doctor`, `make-manifest`, `new`, and
  `version` run from a bare checkout. `registry`, `module`, `build`, `apply`,
  `status`, `compile`, `explain-variant`,
  `explain-bundles`, and `layer-lint` require the consuming project's source
  tree (see [docs/variants.md](docs/variants.md) and
  [docs/contrib-modules.md](docs/contrib-modules.md)). No command requires
  Python 3.
- `module.d/` and `modules/platform/` — generic platform modules
  (`platform_posix`, `platform_macos`, `platform_linux`, `platform_bsd`).
- `manifests/parser-support.tsv` — declares the shell parsers used to check
  each source-file class.
- `tests/` — the test suite. Every test runs in a quarantined environment:
  fresh temporary HOME, controlled TMPDIR and PATH, cleared startup hooks.
- `examples/local/` — a minimal runnable module demonstrating the metadata
  contract.
- `examples/profile-project/` — a complete consuming project: metadata,
  bodies, a provider layer, bundles, variants, and project defaults. Its
  [README](examples/profile-project/README.md) walks from clone to a loaded
  profile.

Product-specific modules, adapters, release packaging, and installer
transactions belong in the consuming project, not here. See
[docs/architecture.md](docs/architecture.md) for the scope.

## Documentation

- [docs/installation.md](docs/installation.md) — install paths, shell
  integration, XDG layout, publishing, and the integrity and provenance limits.
- [docs/module-abi.md](docs/module-abi.md) — the metadata contract: fields,
  allowed values, multi-root search path, runtime detection, side-effect
  phases, and the capability layer.
- [docs/architecture.md](docs/architecture.md) — what this repository
  provides and what stays in the consuming project.
- [docs/variants.md](docs/variants.md) — build variant selection and
  exclusion lists.
- [docs/contrib-modules.md](docs/contrib-modules.md) — module authoring
  reference.
- [docs/shared-modules.md](docs/shared-modules.md) — governance and index
  for shared modules: namespace ownership, review, deprecation, removal.
- [docs/release-policy.md](docs/release-policy.md) — compatibility surfaces,
  current pre-1.0 status, and the release checklist.
- [CHANGELOG.md](CHANGELOG.md) — user-facing changes.

## Running the tests

The Makefile and the test suite live in the source repository. The npm
package ships the runtime, the docs, and the examples, not the Makefile.

```sh
make check-fast  # quick contributor lane; no optional shells required
make check       # available shell/runtime checks, CLI and end-to-end tests
```

Strict mode requires the parsers declared in
`manifests/parser-support.tsv`, the host shells used by the end-to-end lanes
(`sh`, `bash`, `zsh`, `ksh`, `dash`, and `fish`), and a BusyBox executor.
Missing tools skip with a visible message in an ordinary local run;
`CI=true` or `GITHUB_ACTIONS=true` makes them fail. Lima VM lanes are optional
and run only when the relevant instance is configured.
To require the standard runtime set locally, run:

```sh
make VALISE_REQUIRE_TOOLING=1 check
```

To intentionally use non-strict behavior in CI, or require tools on a local
machine, the GNU Make command-line override takes precedence. The Makefile
also includes an optional untracked `config.mk` before its defaults, so
machine-local preferences can be set there; use `VALISE_REQUIRE_TOOLING ?= 1`
for a default that a command-line assignment can still override. The release
checklist is in [docs/release-policy.md](docs/release-policy.md).
