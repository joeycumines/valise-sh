# Installation and releases

`bin/valise` is a `/bin/sh` CLI. Its normal install and verification commands
need the platform utilities used by the release manifest and integrity checks
(for example, a SHA-256 utility). Every documented command runs without
Python 3. `explain-bundles` and `layer-lint` read the project's metadata
directly.

## Install the CLI

From a source checkout, put `bin/` on `PATH`:

```sh
git clone https://github.com/joeycumines/valise-sh.git
export PATH="$PWD/valise-sh/bin:$PATH"
valise version
```

Or install a symlink in a directory already on `PATH`:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/valise-sh/bin/valise" "$HOME/.local/bin/valise"
```

The npm package exposes the same executable and includes the runtime, docs,
and examples. From a checkout, build and install its tarball with:

```sh
npm pack
npm install -g ./valise-sh-*.tgz
valise version
```

The package is distributed as a local tarball rather than through the public
npm registry. The package test checks the tarball contents, installs the
packed CLI without a registry, and loads a module from the extracted package.

## Shell integration

`valise install` installs the release described by the manifest in the
current project and deploys shell integration automatically. A managed block
is written to `~/.profile`; to the first of `~/.bash_profile` and
`~/.bash_login` that exists, because it shadows `~/.profile` for bash; to
`~/.bashrc` and `~/.zshrc` when that shell is `$SHELL` or the file exists;
and to `~/.zprofile` when zsh is installed or the file exists. A Fish
`conf.d` hook is written when Fish is installed. `--no-integration` writes
no startup file and no Fish hook.

The POSIX snippet works with either release shape. A compiled release —
one built by `valise build` — carries `generated/installed-modules.<shell>`
plans; an engine release — one that ships `entrypoints/profile.sh` and the
loader — carries the loader instead. The snippet prefers the compiled plan
and falls back to the loader entrypoint, so installing a release never
leaves a startup file that loads nothing.

The Fish hook is
`${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/valise.fish`. Existing POSIX
profile content is preserved; a managed block makes repeat installs
idempotent. Symlinked POSIX profile files are left alone. Install prints
which file was written and how to remove the integration.

Zsh does not read `~/.profile` on its own: zsh login shells read
`.zprofile`, not `~/.profile`. When zsh is present, install writes the same
managed block to `~/.zprofile` as it does to the other startup files, so zsh
needs no separate pointer. Users who integrate by hand paste the block into
`~/.zprofile` themselves.

To print a POSIX integration snippet without editing a startup file, run
`valise init` once and paste its output where you want it:

```sh
valise init            # POSIX snippet for the shell named by $SHELL
valise init fish       # Fish snippet; add `| source` under Fish
```

Evaluating `valise init` output directly at every prompt —
`eval "$(valise init)"` — re-runs CLI startup code in every shell and is
not the routine path; prefer `valise install` or `valise apply`, which
write a managed block once.

The Fish integration verifies the active release before loading it. The
check validates the active pointer, the release manifest, and every listed
file. If verification fails, the hook loads no release code. Fish continues
starting even if a `conf.d` hook fails, so this does not abort the interactive
shell.

`valise doctor` verifies the active release against its own manifest, checks
the startup files the running shell actually reads for the valise managed
block, and warns when a `.bash_profile` would prevent bash from reading
`~/.profile`. It exits nonzero when the active release is missing or fails
verification, and when no startup file carries the managed block.

Two options adjust its scope:

- `--pre-install` skips the active-release check, so doctor can run before the
  first install.
- `--no-integration` skips the startup-file check and reports only the
  release.

`valise release verify` runs the release verification without sourcing shell
code:

```sh
valise release verify
```

The development-only `valise init fish --source-tree` mode skips installed
release verification. Use it only for repository tests; do not use its output
as an installed shell hook.

## Build a release

A release tree contains the engine runtime, module metadata and bodies, and
any profile-specific files. `valise make-manifest` writes a manifest into the
tree:

```sh
valise make-manifest ./mytree
```

By default this creates
`./mytree/shell/install/profile-release.manifest`. Use `--output <file>` to
choose another manifest path. The manifest records each regular file's size
and SHA-256 digest; source and destination paths are the same. The tree must
contain files with mode `0644` or `0755`. Symlinks, unsupported path
characters, and other file modes are rejected. Rebuilding an unchanged tree
produces the same manifest.

Install and verify from the tree root:

```sh
cd mytree
valise install
valise release verify
```

Install stages a sealed, read-only copy under the XDG data directory and
updates the active symlink. `release verify` checks the installed bytes against
their manifest. Fish repeats that check at startup; the POSIX startup snippets
do not, so run `release verify` separately if you need a check before sourcing
in a POSIX shell.

The engine does not build a consuming project's module catalog or release
tree. The included [e2e example](../examples/e2e/README.md) demonstrates a
small complete profile.

## Integrity and provenance

The manifest detects changes to release files after it is created. It does
not prove who created those files: a manifest made from untrusted source also
verifies successfully. The engine does not sign releases or provide an
authenticated package feed or network updater.

For shared provider code, pin the provider revision, review changes before
updating the vendored copy, and distribute the resulting release through a
trusted channel. The release manifest then provides a check against accidental
or subsequent modification; the commit pin and review are the provenance
controls.

## Storage locations

| Purpose | Default | Override |
|---|---|---|
| Releases | `~/.local/share/valise/releases/` | `$XDG_DATA_HOME/valise/releases/` |
| Active release | `~/.config/valise/active` | `$XDG_CONFIG_HOME/valise/active` |
| Lock and state | `~/.local/state/valise/` | `$XDG_STATE_HOME/valise/` |

The active path is a symlink to the selected release.

## Managing installed releases

`valise release list` shows the installed releases and marks the active one.
`valise release use <release-id>` points the active symlink at an existing
release.

`valise release prune --keep=<n>` removes old releases. It always keeps the
active release and the `n` newest others, and it never removes a release that
fails verification against its own manifest — a release that cannot be
verified is reported and kept, so a damaged tree is not silently discarded.
The default is `--keep=3`.

## Command usage

Every command prints its own contract:

```sh
valise compile --help
valise build --help
valise install --help
```

`valise help` prints the global command list.

## Updating and removing

Update a source checkout with Git. To update an npm installation, repack and
reinstall the tarball. `valise install` updates the active profile release;
it does not update the CLI itself.

There is no `valise uninstall` command. Before removing the CLI, remove the
managed integration from every startup file valise wrote: delete only the
block between `# BEGIN valise managed block` and `# END valise managed
block` in `~/.profile` and in any of `~/.bash_profile`, `~/.bash_login`,
`~/.bashrc`, `~/.zshrc`, and `~/.zprofile`. For Fish, remove
`${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/valise.fish` if it is still
the valise-managed hook. Then uninstall the CLI and remove the valise XDG
state. Installed release files are read-only, so make them writable first:

```sh
chmod -R u+w "$HOME/.local/share/valise" 2>/dev/null || :
rm -rf "$HOME/.local/share/valise" "$HOME/.config/valise" "$HOME/.local/state/valise"
# Run only if installed from npm:
npm uninstall -g valise-sh
# For a source install, remove bin/ from PATH and delete any symlink you created.
```

If you use non-default XDG directories, remove the corresponding `valise/`
subdirectories there instead.
