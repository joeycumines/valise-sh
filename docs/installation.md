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
current project and deploys shell integration. The mode is selected with
`--integration=<mode>`:

- `auto` (the default) deploys a POSIX snippet for bash, zsh, or ksh when
  that shell is named by `$SHELL`, and a Fish `conf.d` hook when it finds
  Fish in a trusted system path. On macOS the POSIX snippet goes to
  `.bash_profile`, `.zprofile`, or `.kshrc`; on other systems it goes to
  `.bashrc`, `.zshrc`, or `.kshrc`.
- `profile` deploys one shared snippet to `~/.profile` and nothing else.
  `~/.profile` is read by several shells — bash reads it for login shells
  when no `.bash_profile` or `.bash_login` exists, and ksh reads it too —
  so it is the recommended target for a multi-shell POSIX setup. The
  snippet detects the running shell when it runs and loads nothing for
  shells without a plan. Creating `.bash_profile` stops bash from reading
  `~/.profile`, so do not create one just to hold valise integration.
- `none` writes no startup file. `--no-shell-integration` is the
  equivalent legacy spelling.

The POSIX snippet works with either release shape. A compiled release —
one built by `valise assemble` — carries `generated/installed-modules.<shell>`
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
`.zprofile`, not `~/.profile`. The project command `valise apply` therefore
also writes a one-line managed pointer `~/.zprofile` that sources
`~/.profile` whenever it writes the `~/.profile` integration and zsh is
present. Users who integrate by hand add the same line themselves.

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

`valise doctor` reports the integration file (`~/.profile`), whether it
contains the valise managed block, and warns when a `.bash_profile` would
prevent bash from reading it.

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
managed integration from your shell startup file: in `~/.profile` (and the
`~/.zprofile` pointer written by `valise apply`), delete only the block
between `# BEGIN valise managed block` and `# END valise managed block`; in
the shell-specific file written by `install --integration=auto`, delete the
lines beginning `# valise shell integration — managed by valise install`;
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
