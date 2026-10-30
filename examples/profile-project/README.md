# profile-project: a complete valise project

This is a small but complete consuming project. It shows every piece a
profile project needs: metadata that describes the modules, module bodies,
a provider layer contributed by somebody else, a bundle that says which
roots load, a variant that says what to leave out, and project defaults.

Everything here is plain text. There is no build script and no hand-written
registry. `valise` reads the metadata and generates what it needs.

## What is in it

```
shell/
  module.d/                          the project's own modules
    profile_main.meta                the entry module
    greeting.meta                    a dependency of profile_main
  modules/                           the bodies of those modules
    greeting.sh
  layers/demo/                       a provider layer
    module.d/contrib_demo_greeting.meta
    modules/shared/contrib_demo_greeting.sh
  release/
    bundle-roots                     which roots load, per shell
    install-variants                 named exclusion sets
    project.conf                     defaults for build and apply
```

`profile_main` is a meta module: it has `requires=greeting` and no body of
its own, so there is no `modules/profile_main.sh`. It exists only to name
what the project loads. `greeting` is an ordinary module that defines
`greet`.

The layer under `shell/layers/demo/` is a provider layer. Its module is
named `contrib_demo_greeting`, following the `contrib_<owner>_<thing>`
convention, and its body lives under `layers/demo/` in the installed
release, so it never collides with the project's own modules.

## Build it

From this directory:

```sh
valise build
```

That compiles a plan for each supported shell and writes a release under
`build/release/`. The release contains:

```
build/release/
  generated/installed-modules.bash    compiled plan for bash
  generated/installed-modules.zsh     compiled plan for zsh
  generated/installed-modules.ksh     compiled plan for ksh
  vendor/shell-profile/lib/capabilities.sh
  module.d/                          the project's metadata
  modules/                           the project's bodies
  layers/demo/module.d/              the layer's metadata
  layers/demo/modules/shared/        the layer's bodies
  shell/release/                     bundle, variants, project defaults
  shell/install/profile-release.manifest
```

The plans are plain POSIX shell. You can read one to see exactly what will
run.

## Load it

```sh
valise apply
```

`apply` builds the release, installs it under your XDG data directory, and
writes a managed block into `~/.profile`. It prints what it changed and
where.

The managed block is guarded by a source-once variable, so your login shell
loads the profile exactly once. It prefers the compiled plan for your shell
and falls back to the loader if the release has no compiled plan.

zsh does not read `~/.profile` on its own, so when zsh is present `apply`
also writes a one-line `~/.zprofile` that sources `~/.profile`. bash reads
`~/.profile` only when no `~/.bash_profile` exists; `apply` never creates
one, so it does not shadow your `~/.profile`.

Now open a new login shell:

```sh
bash -l
greet
# hello from the valise profile project
```

The same works in zsh and ksh. It does not work in dash: the plans are
compiled for bash, zsh and ksh, and dash is not one of them.

To undo it, remove the managed block from `~/.profile` (and `~/.zprofile`).

To check the current state:

```sh
valise status
```

```
project: /path/to/profile-project
variant: workstation-full
bundle: default
integration target: /home/you/.profile
integration state: managed block present
registry: up to date
active release: 0a723dcb0860bcae3ea259c631aaa76ce8e0b4e6991448979018c1d08fc35802
build output: /path/to/profile-project/build/release
drift: active release matches build output
```

`status` reports the active release, the integration file, and whether the
installed release still matches what the project would build. If you edit a
module and re-apply, the release changes and the drift line tells you the
active release is no longer the one you built.

## Try a variant

The project ships two variants. `workstation-full` loads everything;
`workstation-lean` leaves out the provider layer:

```sh
valise explain-variant workstation-lean
```

To use the lean variant, set it in `shell/release/project.conf`:

```sh
variant=workstation-lean
```

Then re-apply. The `contrib_demo_greeting` module disappears from the plan
and the rest still loads.

An exclusion that removes a module something else still depends on is an
error, not a silent surprise:

```
ERROR: variant exclusion breaks a required dependency: profile_main requires contrib_demo_greeting
```

## Try a bundle

`shell/release/bundle-roots` says which roots load for each shell:

```
default	bash	profile_main contrib_demo_greeting@shell/layers/demo/module.d
```

The first root is a bare name, meaning a module from the project's own
`shell/module.d/`. The second is qualified with its source, so it is
unambiguous even though it lives in a layer.

```sh
valise explain-bundles
```

## Check the layer

A provider layer has rules: the `contrib_` prefix, a version, a body that
exists, and no dependency that escapes the layer.

```sh
valise layer-lint demo
# layer demo: 1 module(s) validated
```

## Where to go next

- [The module ABI](../../docs/module-abi.md) — every metadata field.
- [The authoring guide](../../docs/contrib-modules.md) — writing modules.
- [The compile and assemble contract](../../docs/variants.md) — the registry,
  bundles, variants, and what a compiled plan contains.
- [Shared modules](../../docs/shared-modules.md) — how layer modules are
  named and owned.
