# Examples

- `local/` is the smallest example: one metadata file and one POSIX shell
  module. It demonstrates sourcing a module without installing a release.
- `e2e/` is a sample consumer profile. Its twelve modules cover dependency
  resolution, platform and shell selection, exports, optional dependencies,
  release installation, and shared-module composition.

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
