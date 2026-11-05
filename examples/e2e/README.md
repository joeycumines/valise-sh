# End-to-end example

This directory is a sample consuming profile. It includes twelve modules
that exercise dependencies, shell and platform selection, exports, optional
dependencies, and composition with the shared provider in `examples/shared/`.

## Modules

| Module | Shells | Platforms | Depends on | Export |
|---|---|---|---|---|
| `e2e_env_setup` | sh bash zsh ksh | any | `valise_platform_posix` | `e2e_env_ready` |
| `e2e_aliases` | sh bash zsh ksh | any | `e2e_env_setup` | `e2e_show_aliases` |
| `e2e_completions_bash` | bash | any | `e2e_aliases` | `e2e_bash_completions_loaded` |
| `e2e_completions_zsh` | zsh | any | `e2e_aliases` | `e2e_zsh_completions_loaded` |
| `e2e_ksh_features` | ksh | any | `e2e_env_setup` | `e2e_ksh_loaded` |
| `e2e_fish_features` | fish | any | optional `e2e_env_setup` | `e2e_fish_loaded` |
| `e2e_platform_tools_darwin` | sh bash zsh ksh | darwin | `valise_platform_macos` | `e2e_darwin_tools_ready` |
| `e2e_platform_tools_linux` | sh bash zsh ksh | linux | `valise_platform_linux` | `e2e_linux_tools_ready` |
| `e2e_platform_tools_bsd` | sh bash zsh ksh | bsd | `valise_platform_bsd` | `e2e_bsd_tools_ready` |
| `e2e_optional_network` | sh bash zsh ksh | any | optional `e2e_env_setup` | `e2e_net_available` |
| `e2e_generated_config` | sh bash zsh ksh | any | `e2e_env_setup` | `e2e_config_loaded` |
| `e2e_layer_probe` | sh bash zsh ksh | any | `e2e_env_setup`, optional `contrib_shared_paths` | `e2e_layer_probe_ok` |

`e2e_layer_probe` depends on a primary-root module and optionally on a
module in the shared layer. It tests dependency resolution in both directions
across the two roots.

## Build, install, and verify

Run these commands from the repository root. Installation writes shell
integration under `HOME`; this example uses a temporary home so it does not
touch your normal startup files.

```sh
export PATH="$PWD/bin:$PATH"
sh examples/e2e/build-manifest.sh

_demo=$(mktemp -d)
mkdir -p "$_demo/home"
export HOME="$_demo/home"
export XDG_DATA_HOME="$_demo/data"
export XDG_CONFIG_HOME="$_demo/config"
export XDG_STATE_HOME="$_demo/state"

(cd examples/e2e/build/release && valise install)
valise release verify
```

The build script copies the engine runtime and shared example into
`examples/e2e/build/release`, then writes `shell/install/profile-release.manifest`
with each file's size and SHA-256 digest using `valise make-manifest`. Generated
release files are isolated in `build/` and can be rebuilt at any time.

Load sample modules in a POSIX shell:

```sh
_active=$(cd "$XDG_CONFIG_HOME/valise/active" && pwd -P)
VALISE_MODULE_ROOT="$_active" \
VALISE_MODULES='e2e_env_setup e2e_aliases e2e_generated_config e2e_optional_network' \
VALISE_MODE=strict \
. "$_active/entrypoints/profile.sh"

e2e_env_ready
e2e_show_aliases
e2e_config_loaded
```

Try the Fish module in a new Fish process. The installed `conf.d` hook loads
the sealed release at startup, so set the module list in the child's
environment before starting Fish:

```sh
VALISE_MODULES=e2e_fish_features VALISE_MODE=strict fish -c \
  'functions -q e2e_fish_loaded; and valise release verify'
```

When finished, stop using the functions and remove the temporary installation:

```sh
chmod -R u+w "$_demo"
rm -rf "$_demo"
```

## Shared provider composition

The build script vendors `examples/shared/` under `layer/shared/` and records
its source revision in `layer/shared/layer-pin.txt`. The release manifest
covers both the profile and provider files. After the build, installation,
and verification above, load the cross-root probe and shared utilities:

```sh
_active=$(cd "$XDG_CONFIG_HOME/valise/active" && pwd -P)
VALISE_MODULE_ROOT="$_active" \
VALISE_MODULE_PATH="$_active/layer/shared" \
VALISE_MODULES='e2e_layer_probe contrib_shared_paths contrib_shared_umask' \
VALISE_MODE=strict \
. "$_active/entrypoints/profile.sh"

e2e_layer_probe_ok
contrib_shared_paths_setup
contrib_shared_umask_secure  # explicitly changes umask to 077
```

The provider modules are POSIX-only; Fish users can load the profile's Fish
modules but not these utilities. To update the provider in a real consuming
project, vendor a reviewed commit, inspect the diff, then rebuild and verify
the release. See [the module ABI](../../docs/module-abi.md) for multi-root
resolution and [the installation guide](../../docs/installation.md) for the
integrity and provenance limits.

`tests/e2e.test.sh` runs the install, verification, tamper, and composition
scenarios in quarantined homes. It also runs available host-shell lanes;
configured Lima Linux, BusyBox, and BSD lanes run when their VMs are present.
