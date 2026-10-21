# Example shared-module provider

This directory represents a separate repository that publishes modules for
consumers to vendor. It is kept in-tree so the example composition can be
run from a fresh `valise-sh` checkout. In a real setup, the provider would
be pinned to a reviewed commit in the consuming project.

## Modules

| Module | Version | Export | Behavior |
|---|---|---|---|
| `contrib_shared_paths` | 1.0.0 | `contrib_shared_paths_setup` | Adds `$HOME/.local/bin` and `$HOME/.go/bin` using `contrib_path_prepend`. |
| `contrib_shared_umask` | 1.0.0 | `contrib_shared_umask_secure` | Sets `umask 077` when explicitly called. |

The modules and their metadata are under `modules/shared/` and
`module.d/`. Layer-only modules use the `contrib_` prefix. The paths module
requires the engine's `contrib_path` module; this exercises dependency
resolution from a layer into the primary module root.

## Use in the sample profile

From the repository root, build the sample release and install it from the
e2e directory. Installation adds an integration hook under `HOME`; use a
temporary home to avoid changing your own shell startup files (see the top
level README).

```sh
sh examples/e2e/build-manifest.sh
cd examples/e2e
valise install
valise verify-active
```

Then load the shared modules from a POSIX shell. The active release path
below uses the default XDG locations; if you set `XDG_CONFIG_HOME`, use that
instead.

```sh
_active=$(cd "$HOME/.config/valise/active" && pwd -P)
VALISE_MODULE_ROOT="$_active" \
VALISE_MODULE_PATH="$_active/layer/shared" \
VALISE_MODULES='e2e_layer_probe contrib_shared_umask' \
VALISE_MODE=strict \
. "$_active/entrypoints/profile.sh"
```

For a Fish example and details about provider pinning, see
[the end-to-end walkthrough](../e2e/README.md) and the
[module ABI](../../docs/module-abi.md).
