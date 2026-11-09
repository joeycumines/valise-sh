# Example shared-module provider

This directory represents a separate repository that publishes modules for
consumers to vendor. It is kept in-tree so the example composition can be
run from a fresh `valise-sh` checkout. In a real setup, the provider would
be pinned to a reviewed commit in the consuming project.

## Modules

| Module | Version | Export | Behavior |
|---|---|---|---|
| `contrib_shared_paths` | 1.0.0 | `contrib_shared_paths_setup` | Adds `$HOME/.local/bin` and `$HOME/.go/bin` using `valise_path_prepend`. |
| `contrib_shared_umask` | 1.0.0 | `contrib_shared_umask_secure` | Sets `umask 077` when explicitly called. |

The modules and their metadata are under `modules/shared/` and
`module.d/`. Layer-only modules use the `contrib_` prefix. The paths module
requires the engine's `valise_path` module; this exercises dependency
resolution from a layer into the engine's modules.

## Use in a project

A consuming project vendors this directory as `layers/<provider>/`, for
example `layers/shared/`, and names the modules it wants in `bundles.tsv` or
in the `requires=` and `optional=` fields of its own modules. `valise build`
then copies only the provider modules some plan loads into the release under
`layers/shared/`. [The end-to-end walkthrough](../e2e/README.md) shows the
steps against the sample project; see the [module ABI](../../docs/module-abi.md)
for dependency resolution across a project and its layers.
