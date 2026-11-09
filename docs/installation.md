# Installation and releases

`bin/valise` is a `/bin/sh` CLI. It needs the standard POSIX utilities and a
SHA-256 utility (`sha256sum`, `shasum`, or `sha256`); no command needs
Python, Perl, or another runtime.

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

`--no-integration` writes no startup file, no Fish hook, and no command
stubs. `valise apply`
builds, installs, and then uses the same writer.

Each POSIX file receives a managed block between `# BEGIN valise managed
block` and `# END valise managed block`. Existing content is preserved, and
a repeat install replaces the block in place. A new block is appended with
nothing added around it, so removing the block restores the file. When the
file's last line has no newline, install adds one before the block and a note
line inside it, and uninstall removes both. Rows or lines after the block
keep the file's own ending, newline or not, and a repeat install leaves them
alone. A symlinked POSIX startup file is reported and left untouched.

Install checks every startup file, the Fish hook path, and the command
directory before it changes the active release. The command directory is
checked only when the release publishes commands or a command ledger exists.
An unpaired marker, a startup path that is not a regular file, a directory
install cannot write, a command directory it cannot write, or a Fish hook
path that is a symlink or a directory stops the install with nothing changed. If a later step fails
anyway, install puts the previous active release back (or removes the active
link when there was none) and names the files it had already written. Those
files load whichever release is active, so they need no repair.

Install also warns about lines outside a managed block that load valise by
hand: a reference to `valise/active`, a 0.1 `installed-modules.` list, or a
line that sources a compiled plan. Such a line loads the profile a second
time; remove it. `valise doctor` reports the same lines as a failure.

The block detects the running shell class, `ksh`, `zsh`, `bash`, or `sh` for
any other POSIX shell, and sources `plans/<class>.sh` from the active
release. It sets `_valise_profile_loaded` only when the plan succeeds, so a
later startup file in the same session retries after a failure.
`VALISE_RELOAD=1` makes a later block load the profile again.

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

Evaluating `valise init` output at every prompt, as in
`eval "$(valise init)"`, re-runs CLI startup code in every shell and is
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

`valise build` turns a project into a release tree (see
[projects.md](projects.md#valise-build)), and `valise apply` builds and
installs it in one step. `valise install` installs the tree in the current
directory, so a tree built elsewhere installs the same way:

```sh
cd build/release
valise install
valise release verify
```

Install requires `manifest.tsv`, which lists every regular file with its
size and SHA-256 digest, and a `valise-release.conf` declaring `format=2`;
a tree from an older valise must be rebuilt. It copies the tree into
the release store under the manifest's SHA-256, makes the copy read-only,
verifies it, and switches the active link. `release verify` checks the
installed bytes against their manifest again. Fish repeats that check at
every startup; the POSIX block does not, so run `release verify` when you
want a check before a POSIX shell sources the release.

`valise make-manifest <tree> [--output <file>]` writes the manifest for a
tree; `valise build` uses it. Files must have mode `0644` or `0755`;
symlinks, unsupported path characters, and other modes are rejected. An
unchanged tree always produces the same manifest.

## Published commands

A release whose modules declare `commands=` or `executables=` carries a
`bin/` directory (see [the module ABI](module-abi.md#published-commands)).
`valise install` writes a stub for each name into the command directory,
`${VALISE_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}`. A stub is a short
`sh` script that runs the same name under the active release link, so
switching releases never rewrites a stub; install and `valise release use`
add the stubs the new release needs and remove the ones it no longer has.

valise records each stub it writes, with its SHA-256, in
`$XDG_STATE_HOME/valise/commands.tsv` before writing the stub, so an
interrupted install never leaves a stub valise does not know about. It only
touches files listed there, and it refuses a release whose `commands=` holds
a name the build would have rejected:

- A file valise did not write is never replaced. Install reports the
  command as not published, and `valise doctor` reports the collision.
- A stub that was edited after valise wrote it is left in place and
  dropped from the ledger.

`valise install --no-integration` writes no stubs and no ledger, and a later
`valise release use` leaves the command directory alone. Install and
`valise doctor` warn when the command directory is not on PATH.

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
| Command stubs | `~/.local/bin/` | `$VALISE_BIN_DIR`, then `$XDG_BIN_HOME` |

The active path is a symlink to the selected release. The state directory
holds the lock, the previous-release record (`previous`), the command-stub
ledger (`commands.tsv`), and the list of startup files install created
(`startup-created`). Uninstall uses the same locations, including any XDG
overrides.

## Managing installed releases

`valise release list` shows the installed releases and marks the active one.
`valise release use <release-id>` verifies an installed release and points
the active symlink at it. Each time the active release changes, valise
records the one it replaced in `$XDG_STATE_HOME/valise/previous`;
`valise release rollback` verifies that release and makes it active again, so
two rollbacks in a row return to where they started. Both move the command
stubs to the new active release when install published them.

`valise apply --dry-run` builds the project and prints what install would
do: whether the release is installed or active already, and for each startup
file, the Fish hook, and each command stub whether it is current or would be
created, updated, published, skipped, or removed. It writes nothing outside
`build/`.

`valise release prune --keep=<n>` removes old releases. It always keeps the
active release and the `n` newest others, and it never removes a release that
fails verification against its own manifest. A release that cannot be
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

Update a source checkout with Git. To update a package installation, repack
and reinstall the tarball. `valise install` updates the active profile release;
it does not update the CLI itself.

`valise uninstall` removes what install wrote:

- the managed block from `~/.profile`, `~/.bash_profile`, `~/.bash_login`,
  `~/.bashrc`, `~/.zprofile`, and `~/.zshrc`, keeping every other byte and
  the file mode; a file install created is deleted when nothing else is left
  in it
- the Fish hook, when its first line is the valise header
- the command stubs valise owns, except a stub that was edited after valise
  wrote it
- the active link, the previous-release record, and the installed releases

It checks every startup file for paired markers before it changes anything.
A symlinked startup file and lines that load valise outside a managed block
are reported for you to edit. `--keep-releases` keeps the installed releases.
Then remove the CLI:

```sh
# Run only if installed from npm:
npm uninstall -g valise-sh
# For a source install, remove bin/ from PATH and delete any symlink you created.
```
