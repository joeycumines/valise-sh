# Examples

- `local/` is the smallest example: one metadata file and one POSIX shell
  module. It demonstrates sourcing a module without installing a release.
- `profile-project/` is a complete consuming project: metadata-driven
  modules, a provider layer, a bundle, a variant, and project defaults.
  It is the shortest path from a clone to a loaded profile.
- `e2e/` is a sample consumer profile. Its twelve modules cover dependency
  resolution, platform and shell selection, exports, optional dependencies,
  release installation, and shared-module composition.

## Complete project

`profile-project/` is the one to read if you want to see what a profile
project looks like end to end. Its
[README](profile-project/README.md) walks from a fresh checkout through
`valise build` and `valise apply` to a `greet` function that works in a new
login shell.

## Minimal module

From the repository root, load the example with:

```sh
VALISE_MODULE_ROOT="$PWD/examples/local" \
VALISE_MODULES=hello_valise \
VALISE_MODE=strict \
. ./entrypoints/profile.sh

hello_valise_loaded
# hello from valise-sh
```

The metadata is in `examples/local/module.d/hello_valise.meta`; the body is
`examples/local/modules/hello_valise.sh`. See
[the module ABI](../docs/module-abi.md) and
[the authoring guide](../docs/contrib-modules.md) for the format.

## Sample consumer profile

`e2e/README.md` describes how to build its release manifest, install and
verify the release, load its modules, and compose the `examples/shared/`
provider. The example installer writes shell integration under `HOME`, so
use a temporary home if you do not want to change your normal startup files.
