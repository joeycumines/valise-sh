# Examples

- `local/` is the smallest example: one metadata file and one POSIX shell
  module. It demonstrates sourcing a module without installing a release.
- `profile-project/` is a small complete project: two modules, a provider
  layer, a bundle, and two variants. It is the shortest path from a clone to
  a loaded profile.
- `e2e/` is the project `tests/e2e.test.sh` builds. Its thirteen modules
  cover dependency resolution, platform and shell selection, exports,
  optional dependencies, a Fish module, and composition with a layer.
- `shared/` is a sample provider whose modules a project vendors as a layer.

## Complete project

`profile-project/` is the one to read if you want to see what a profile
project looks like end to end. Its
[README](profile-project/README.md) walks from a fresh checkout through
`valise build` and `valise apply` to a `greet` function that works in a new
login shell.

## Minimal module

`local/` loads through the development loader, without a project or a
release. From the repository root:

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

[e2e/README.md](e2e/README.md) builds, installs, and verifies that project
in a temporary home, loads it in each shell, and composes the `shared/`
provider as a layer.
