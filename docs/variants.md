# Build Variants and Installed Releases

Two different mechanisms share the word "variant". They compose, but they
are not the same command. This document describes both and says which
repository each one needs.

## Installed releases: `variant list` and `variant use`

These subcommands operate on the releases already installed on this
machine. No source tree is required.

```sh
valise variant list
```

This lists the installed sealed releases by directory name. Release
directories are named by the content-derived SHA-256 of their manifest,
and the active release is marked.

```sh
valise variant use <sha>
```

This verifies the named release byte-for-byte against its manifest and
switches the active pointer to it. The target must be an existing
release directory under the releases root; anything else fails closed.

## Build variants: exclusion lists in the consuming project

Separately, a consuming project can define named build variants as
exclusion lists: a variant names modules to leave out of an installed
plan so different machines share one release while loading different
subsets. This mechanism lives in the consuming project, not in this
repository:

- The variant file (`shell/release/install-variants`, tab-separated
  `variant_name`, description, excluded modules) belongs to the
  consuming project.
- `valise compile [--bundle=<name>] [--variant=<name>] <output-dir>`
  resolves the module graph from seeds, removes the active variant's
  exclusion set, and writes installed plans. It requires the consuming
  project's `shell/release/module-registry.tsv`,
  `shell/release/profile-release.json`,
  `hack/compile-shell-profile-release.py`, and `install-variants`
  files, and fails closed with "cannot find source tree" without them.
- `valise explain-variant <name>` shows the root count and exclusion
  count per shell for a variant in `install-variants`. It requires the
  same consuming-project files.

`valise variant list` / `valise variant use` never read
`install-variants`. Variant exclusion is decided at compile time in
the consuming project; release switching happens at install time with
`variant use`.

## Bundles vs variants

Bundles select which layer roots are active per shell (for example,
core+private vs core+private+contrib). They are defined in the consuming
project's `shell/release/bundles.json` and selected with `valise compile
--bundle=<name>`. Variants select which modules within those layers to
exclude. They compose: first a bundle determines the layer set, then a
variant prunes specific modules from the resolved graph. Both files and
both flags belong to the consuming-project compile path.
