# Installation and releases

`bin/valise` is a `/bin/sh` CLI. Its normal install and verification commands
need the platform utilities used by the release manifest and integrity checks
(for example, a SHA-256 utility). The consuming-project commands `compile`,
`explain-variant`, `explain-bundles`, and `layer-lint` also require Python 3.

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
current project and deploys shell integration. It adds a POSIX snippet for
bash, zsh, or ksh when that shell is named by `$SHELL`, and a Fish `conf.d`
hook when it finds Fish in a trusted system path. On macOS the POSIX snippet
goes to `.bash_profile`, `.zprofile`, or `.kshrc`; on other systems it goes to
`.bashrc`, `.zshrc`, or `.kshrc`. The Fish hook is
`${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/valise.fish`. Existing POSIX
profile content is preserved; a marker makes repeat installs idempotent.
Symlinked POSIX profile files are left alone.

To print a POSIX integration snippet without editing a startup file:

```sh
eval "$(valise init)"
```

For Fish, source the generated integration in `~/.config/fish/config.fish`:

```fish
valise init fish | source
```

The Fish integration verifies the active release before loading it. The
check validates the active pointer, the release manifest, and every listed
file. If verification fails, the hook loads no release code. Fish continues
starting even if a `conf.d` hook fails, so this does not abort the interactive
shell.

`valise verify-active` runs the release verification without sourcing shell
code:

```sh
valise verify-active
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
valise verify-active
```

Install stages a sealed, read-only copy under the XDG data directory and
updates the active symlink. `verify-active` checks the installed bytes against
their manifest. Fish repeats that check at startup; the POSIX startup snippets
do not, so run `verify-active` separately if you need a check before sourcing
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

## Updating and removing

Update a source checkout with Git. To update an npm installation, repack and
reinstall the tarball. `valise install` updates the active profile release;
it does not update the CLI itself.

There is no `valise uninstall` command. Before removing the CLI, remove the
managed integration from your shell startup file: in POSIX files, delete only
the block beginning `# valise shell integration — managed by valise install`;
for Fish, remove
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
