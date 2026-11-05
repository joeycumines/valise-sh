# Installation and releases

`bin/valise` is a `/bin/sh` CLI. Its normal install and verification commands
need the platform utilities used by the release manifest and integrity checks
(for example, a SHA-256 utility). Every documented command runs without
Python 3. `explain-bundles` reads the generated registry and the bundle
roots; `layer-lint` reads layer metadata directly.

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
current directory and writes shell integration by default. It always writes
`~/.profile`, which login `sh`, `ksh`, and bash sessions read when no other
file shadows it. It then adds the files each shell reads instead:

- `~/.bash_profile` or `~/.bash_login` when one exists, because login bash
  reads the first of those instead of `~/.profile`. valise never creates
  either file.
- `~/.bashrc` when bash is `$SHELL` or the file already exists.
- `~/.zprofile` when zsh is on `PATH` or the file already exists. It is the
  login file zsh reads instead of `~/.profile`.
- `~/.zshrc` when zsh is `$SHELL` or the file already exists.
- `${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/valise.fish` when valise
  finds a Fish executable in a trusted location.

`--no-integration` writes no startup file and no Fish hook. `valise apply`
builds, installs, and then uses the same writer.

Each POSIX file receives a managed block between `# BEGIN valise managed
block` and `# END valise managed block`. Existing content is preserved, and
a repeat install replaces the block in place. An unpaired marker is refused
and stops the install; a file already processed keeps its updated block. A
symlinked POSIX startup file is reported and left untouched. If the Fish
hook path is a symlink or a directory, install fails rather than write
through it. Install prints every path it wrote and how to remove the
integration.

The POSIX snippet adapts to the release shape:

- A project release built by `valise build` carries
  `generated/installed-modules.<shell>` for each shell its bundle seeds
  (`bash`, `zsh`, and `ksh` for the scaffold and the example). The snippet
  sources the plan for the running shell.
- An engine release carries `entrypoints/profile.sh` and the loader. The
  snippet sources that entrypoint.
- If the release has neither a plan for the running shell nor the loader,
  the snippet leaves the session alone. This is the result for a login
  `dash` session with a built release: `dash` has no plan, and a built
  release has no loader.

`valise install` writes `~/.profile`, which ksh reads at login. A non-login
interactive ksh reads the file named by `$ENV` when that variable is set.
valise does not choose or edit that file; to cover non-login ksh, put the
POSIX block in the file `$ENV` names.

Zsh does not read `~/.profile` on its own: zsh login shells read
`.zprofile`, not `~/.profile`. Install writes the same managed block to
`~/.zprofile`, so zsh needs no separate pointer.

When the bundle has `fish` rows, the release carries `runtime/fish/`: the
native Fish metadata reader and loader and `runtime/fish/profile.fish`, which
loads the bundle's Fish roots recorded in `valise-release.conf`. A release
whose bundle has no Fish rows has no `runtime/fish/`; the Fish hook then loads
nothing and prints nothing.

The Fish hook verifies the active release before loading it. The check
validates the active pointer, the release manifest, and every listed file.
If verification fails, the hook loads no release code and reports
`active release authentication failed`. Fish continues starting even if a
`conf.d` hook fails, so this does not abort the interactive shell.

The Fish hook is several hundred lines while the POSIX block is about twenty.
The difference is deliberate. The POSIX block sources a plan and trusts the
release on disk, as any startup file does. The Fish hook does more because
it must not trust release code before that code is verified, and Fish gives a
sourced file the caller's global functions and variables. The hook therefore
carries its own verification and cleanup, written before any release file
runs: it authenticates the release through `valise release verify`, saves the
caller's `SHELL_PROJECT_ROOT` and `VALISE_MODULE_ROOT` in every scope, records
every caller function so a release cannot silently replace one, sources
`runtime/fish/profile.fish` inside that transaction, and on any failure
removes what the release defined and restores the saved state. None of this
can live in the release, because a tampered release would carry tampered
checks. `valise apply` compares the generated hook with the installed one
byte for byte and reports `Fish hook current` without rewriting an identical
hook.

To write integration by hand, print it once and paste or save it:

```sh
valise init            # POSIX block, or the Fish hook when $SHELL is fish
valise init posix      # POSIX managed block
valise init fish       # Fish conf.d hook; save it as fish/conf.d/valise.fish
```

Evaluating `valise init` output directly at every prompt —
`eval "$(valise init)"` — re-runs CLI startup code in every shell and is
not the routine path; prefer `valise install` or `valise apply`, which
write the files once.

`valise doctor` verifies the active release against its own manifest, checks
the startup files the running shell actually reads for valise integration,
including the `.bash_profile` or `.bash_login` that bash reads instead of
`~/.profile`. It exits nonzero when the active release is missing or fails
verification, and when no startup file carries the integration.

Two options adjust its scope:

- `--pre-install` skips the active-release and startup-file checks, so doctor
  can run before the first install.
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

`valise build` builds a consuming project's release tree: the module
registry, the per-shell plans, every module body, and the manifest inputs.
The engine itself ships as an engine release rather than a built project
release; it carries `entrypoints/profile.sh` and `lib/`, not `generated/`.
The included [e2e example](../examples/e2e/README.md) demonstrates a small
complete profile.

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
