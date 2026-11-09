# profile-project: a small valise project

This project has two modules of its own, one module from a provider layer, a
bundle, and two variants. Everything is plain text; `valise` reads the
metadata and generates the rest.

## What is in it

```
valise.conf                          default bundle and variant
module.d/
  profile_main.meta                  the root: requires greeting
  greeting.meta                      defines greet
modules/
  greeting.sh
layers/demo/                         a provider layer
  module.d/contrib_demo_greeting.meta
  modules/shared/contrib_demo_greeting.sh
bundles.tsv                          the roots for bash, zsh, and ksh
variants.tsv                         default and workstation-lean
```

`profile_main` is a meta module: it has `requires=greeting` and no body. It
names what the project loads. `greeting` is an ordinary module with
`shells=posix`.

The layer module is named `contrib_demo_greeting`, following the
`contrib_<owner>_<thing>` convention. A release copies it to
`layers/demo/`, so it cannot collide with the project's own files.

## Build it

From this directory:

```sh
valise build
```

```
build/release/
  valise-release.conf                bundle, variant, roots, modules
  manifest.tsv                       every file with its size and SHA-256
  plans/bash.sh                      the compiled plan for bash
  plans/zsh.sh
  plans/ksh.sh
  runtime/capabilities.sh            the sp_cap_* helpers
  module.d/, modules/                the project's modules
  layers/demo/                       the layer module
```

The plans are plain POSIX shell; read one to see what will run at startup.
`bundles.tsv` has no `sh` row, so dash and other plain `sh` shells load
nothing.

## Load it

Run this in a scratch `HOME` (see the main README) unless you want it in your
real startup files:

```sh
valise apply
bash -l -c greet
# hello from the valise profile project
```

`apply` builds the release, installs it under your XDG data directory, and
writes a managed block into `~/.profile`, `~/.zprofile` when zsh is
installed, and `~/.bashrc` or `~/.zshrc` when that is your shell. It prints
each file it wrote. `valise apply --dry-run` prints what it would change
without changing it.

```sh
valise status
```

```
project: /path/to/profile-project
project default bundle: default
project default variant: default
integration: /home/you/.profile: managed block present
integration: /home/you/.zprofile: managed block present
active release: ad98ea2ba30bb6c6d4f08b6dec59585228cdf855b814543a37f80ee0f0518773
active bundle: default
active variant: default
active built by valise: 0.3.0
build output: /path/to/profile-project/build/release (bundle default, variant default)
drift: active release matches build output
```

Edit a module and run `valise status` again after `valise build`: the drift
line reports that the active release no longer matches the build.

`valise uninstall` removes the managed blocks, the Fish hook, and the
installed releases.

## Try a variant

`workstation-lean` leaves out the layer module:

```sh
valise explain-variant workstation-lean
```

```
Variant: workstation-lean
Description: No provider layer
Excluded modules: contrib_demo_greeting@layers/demo/module.d

Per-shell impact (bundle default):
  bash: 1 of 2 roots, 2 of 3 modules
  zsh: 1 of 2 roots, 2 of 3 modules
  ksh: 1 of 2 roots, 2 of 3 modules
```

Build it with `valise apply --variant=workstation-lean`, or set
`variant=workstation-lean` in `valise.conf`. An exclusion that removes a
module something else still requires fails the build and names both
modules.

## Try a bundle

`bundles.tsv` lists the roots for each shell:

```
default	bash	profile_main contrib_demo_greeting
```

A bare name means the project's own module when there is one, otherwise the
only module with that name. `name@layers/demo/module.d` names the layer's
copy exactly, which you need when two sources define the same name.

```sh
valise explain-bundles
```

## Check it

```sh
valise lint          # metadata, layers, every bundle and variant, syntax
valise layer-lint demo
# layer demo: 1 module(s) validated
```

## Where to go next

- [Projects](../../docs/projects.md): bundles, variants, compile, and build.
- [Writing modules](../../docs/contrib-modules.md): authoring, linting, and
  testing.
- [The module ABI](../../docs/module-abi.md): every metadata field.
- [Shared modules](../../docs/shared-modules.md): how layer modules are
  named and owned.
