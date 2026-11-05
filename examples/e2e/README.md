# End-to-end example

This directory is a valise project used by `tests/e2e.test.sh`. Its modules
exercise dependencies, shell and platform selection, exports, optional
dependencies, a Fish module, and composition with the shared provider in
`examples/shared/`.

## Modules

| Module | Shells | Platforms | Depends on | Export |
|---|---|---|---|---|
| `e2e_env_setup` | posix | any | `valise_platform_posix` | `e2e_env_ready` |
| `e2e_aliases` | posix | any | `e2e_env_setup` | `e2e_show_aliases` |
| `e2e_completions_bash` | bash | any | `e2e_aliases` | `e2e_bash_completions_loaded` |
| `e2e_completions_zsh` | zsh | any | `e2e_aliases` | `e2e_zsh_completions_loaded` |
| `e2e_ksh_features` | ksh | any | `e2e_env_setup` | `e2e_ksh_loaded` |
| `e2e_fish_features` | fish | any | optional `e2e_env_setup` | `e2e_fish_loaded` |
| `e2e_platform_tools` | posix | any | `e2e_env_setup`, optional the three below | none |
| `e2e_platform_tools_darwin` | posix | darwin | `valise_platform_macos` | `e2e_darwin_tools_ready` |
| `e2e_platform_tools_linux` | posix | linux | `valise_platform_linux` | `e2e_linux_tools_ready` |
| `e2e_platform_tools_bsd` | posix | bsd | `valise_platform_bsd` | `e2e_bsd_tools_ready` |
| `e2e_optional_network` | posix | any | optional `e2e_env_setup` | `e2e_net_available` |
| `e2e_generated_config` | posix | any | `e2e_env_setup` | `e2e_config_loaded` |
| `e2e_layer_probe` | posix | any | `e2e_env_setup`, optional `contrib_shared_paths` | `e2e_layer_probe_ok` |

`bundles.tsv` gives each shell its roots. The POSIX rows name
`e2e_platform_tools`, which lists the per-platform modules as optional
dependencies: a platform module that does not match the running system is
skipped quietly, while naming it as a root would be a strict-mode failure on
every other platform. `variants.tsv` has `default` and `no-network`, which
excludes `e2e_optional_network`.

`e2e_layer_probe` optionally depends on `contrib_shared_paths` from the
shared provider. Without the provider it reports a standalone load; with the
provider vendored as a layer it reports that the layer resolved.

## Build, install, and load

Run these commands from the repository root. Installation writes shell
integration under `HOME`; this example uses a temporary home so it does not
touch your normal startup files.

```sh
export PATH="$PWD/bin:$PATH"
valise -C examples/e2e build

_demo=$(mktemp -d)
mkdir -p "$_demo/home"
export HOME="$_demo/home"
export XDG_DATA_HOME="$_demo/data"
export XDG_CONFIG_HOME="$_demo/config"
export XDG_STATE_HOME="$_demo/state"

(cd examples/e2e/build/release && valise install)
valise release verify
```

`valise build` writes the release to `examples/e2e/build/release`: one plan
per POSIX shell class under `plans/`, the Fish runtime under `runtime/fish/`,
and only the modules some shell loads. `valise install` seals it, makes it
active, and writes the managed block to `~/.profile` (plus `~/.bashrc` or
`~/.zshrc` for those shells) and the Fish hook.

Start a shell through the startup file valise wrote:

```sh
bash -c '. "$HOME/.bashrc"; e2e_env_ready; e2e_show_aliases; e2e_config_loaded'
fish -c 'functions -q e2e_fish_loaded; and valise release verify'
```

When finished, remove the temporary installation:

```sh
chmod -R u+w "$_demo"
rm -rf "$_demo"
```

## Shared provider composition

A project composes a provider by vendoring its tree as `layers/<provider>/`.
To try it, copy this project, vendor `examples/shared/` as `layers/shared/`,
and add the provider's modules to the POSIX roots:

```sh
_proj=$(mktemp -d)
cp -R examples/e2e/valise.conf examples/e2e/variants.tsv \
  examples/e2e/module.d examples/e2e/modules "$_proj/"
mkdir -p "$_proj/layers/shared"
cp -R examples/shared/module.d examples/shared/modules "$_proj/layers/shared/"
awk -F '\t' 'BEGIN { OFS = "\t" } NR > 1 && $2 != "fish" { $3 = $3 " contrib_shared_umask" } { print }' \
  examples/e2e/bundles.tsv >"$_proj/bundles.tsv"
valise -C "$_proj" build
```

The release then carries the provider's modules under `layers/shared/`, and
`e2e_layer_probe_ok` reports that the shared layer resolved. The provider
modules are POSIX-only, so the Fish closure is unchanged. To update a
vendored provider in a real project, copy a reviewed commit, inspect the
diff, then rebuild and verify. See [the module ABI](../../docs/module-abi.md)
for dependency resolution and [the installation guide](../../docs/installation.md)
for the integrity and provenance limits.

`tests/e2e.test.sh` runs these scenarios in quarantined homes: every
available host shell, a tamper lane, and the composition lane. Configured
Lima Linux, BusyBox, and BSD guests run the same install and load checks
when their VMs are present.
