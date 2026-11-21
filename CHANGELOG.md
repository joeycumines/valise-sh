# Changelog

Notable user-facing changes are recorded here. Versions before 1.0 may include
module ABI or CLI changes; see [the release policy](docs/release-policy.md).

## [Unreleased]

### Fixed

- The bash-login stage treats any invocation whose basename is `sh` or ends
  in `-sh` as an `sh` invocation, so bash reached through a symlink such as
  `sh-as-sh` (not just a literal `sh`/`-sh`) stays on its env-only stage
  while reading the login file, matching real `sh -l -i` behavior.
- `valise release use`/`release rollback` whose incoming release wants
  `gui_env=off` now restore the outgoing bridge and reconcile stubs on a
  failed switch exactly as the bridge-owning case does, instead of leaving
  the outgoing bridge stranded or reconciling against a dangling active
  link.
- A failed release switch whose command ledger is not a regular file (for
  example a symlink) now runs the same stub rollback as a reconcile failure:
  the outgoing stubs are restored and the ledger is rewritten as an empty
  regular file instead of being skipped or deleted, so command integration
  stays active for later `release use`/`release rollback` runs.
- A signal delivered while a failed release switch is rolling back is recorded
  by masked INT/TERM traps inside the restore and honored only after every
  restore step finished, so the process exits with the signal's status (130 or
  143) instead of dying mid-restore with exit 1; a late signal can no longer
  strand `.valise-outgoing.*` bridge backups or skip the stub restore.
- Rollback distinguishes "outgoing release directory gone" (a dangling active
  link) from "outgoing release directory unknown" (an unreadable link): it
  clears the published stubs only in the first case and never deletes stubs on
  an assumption, and it requires a readable `valise-release.conf` before
  reconciling stubs so an unreadable manifest is reported instead of silently
  deleting every owned stub.

## [0.4.1] - 2026-11-20

0.4.1 hardens phase probing, release-activation transactions, POSIX startup
reloads, compiler export-ownership matching, and GUI environment capture.

### Added

- `VALISE_CALLER_PATH` lets a caller that sanitizes `PATH` before invoking
  valise supply the original for PATH-gap diagnostics. It is consulted by the
  install and doctor warnings, never for command lookup or generated profile
  content; an explicitly empty value means the caller's PATH is empty. PATH
  entries are normalized before matching, so a trailing slash or doubled
  separator is not reported as a gap.

### Fixed

- `valise compile` and `valise build` now abort when interactive-phase probing
  cannot allocate or inspect its scratch files (for example under an unwritable
  or missing `TMPDIR`), instead of publishing a release without interactive
  plans.
- `valise release use` and `valise release rollback` arm transaction rollback
  before moving outgoing GUI bridges aside, pre-validate the active link and
  previous-release record, and abort before switching if backing up an owned
  predecessor bridge fails. Fatal errors and signals during activation now
  restore outgoing bridges and clean up temporary files.
- Activation and install rollback resolve relative active symlinks to their
  canonical release directory before reconciling command stubs, preventing
  rollback from deleting outgoing stubs.
- `remove_gui_env_bridge` separates pre-commit rename failures from post-commit
  backup deletion failures, so a failed delete of an already-committed aside
  file no longer triggers a release rollback after an earlier backup was
  removed.
- Bridge ownership detection requires a regular non-symlink file before
  reading, preventing a foreign FIFO at the bridge path from blocking
  activation or installation.
- The POSIX managed block invalidates `_valise_interactive_loaded` before
  entering another release (including through env-only startup files) and
  before re-running stage 2, so rolling back after a partially failed or
  env-only switch restores the previous release's interactive definitions.
- The runtime `$ENV` stanza and `valise doctor` require the shim path to be a
  regular non-symlink file carrying the exact managed block header, so startup
  never adopts a foreign file or symlink that `valise install` refused.
- A fresh zsh-default home without `.bash_profile`, `.bash_login`, or
  `.bashrc` now writes a `bash-login` stage to `.profile` so `bash --login -i`
  loads interactive modules without changing `sh`/`ksh` startup ordering.
- Compiled plans compare `_valise_plan_owned` tokens byte-for-byte instead of
  using shell `case` patterns, so Bash `shopt -s nocasematch` cannot conflate
  case-distinct provider names across releases.
- `env_export_capture` preserves the caller's `PATH` as input to both baseline
  and target runs so PATH-dependent exports (such as `valise_editor_defaults`
  and `command -v` probes) match an installed env plan while `PATH` remains
  excluded from bridge output.
- `environment.d` export rejects TAB, DEL, and all Unicode noncharacters by
  variable name so systemd does not corrupt or abort on published values,
  while `launchd` continues to preserve UTF-8, TAB, and DEL.
- `valise_path_remove` validates all arguments before modifying `PATH`, so a
  mixed valid/invalid call fails nonzero and leaves `PATH` untouched.
- Qualified [docs/architecture.md](docs/architecture.md) and
  [docs/module-abi.md](docs/module-abi.md) to state the exact env
  re-evaluation triggers and pre-ownership caller-function protection scope.
- Guarded the `/bin/ksh` probe in `tests/project-ux.test.sh` when `ksh` is
  absent locally.
- PATH-gap diagnostics resolve relative and empty `VALISE_CALLER_PATH` entries
  from the directory where valise was invoked, before `-C` changes to the
  project. A native bash login with inherited shell-version variables or with
  `verbose`/`xtrace` enabled still loads the interactive stage.
- Activation rollback masks `INT`/`TERM` while it restores, so a second signal
  during a rollback is recorded and honored only after every restore step
  finished (the process then exits 130/143) instead of killing the restore
  mid-way.
- Activation rollback clears published command stubs while KEEPING
  `commands.tsv` as an empty regular file when no release was active before or
  the outgoing release directory is gone; deleting the ledger used to disable
  stub publication for every later `release use`/`release rollback` and made
  `doctor` report "installed without integration". An outgoing directory that
  cannot be determined at all is reported, and stubs are never deleted on that
  assumption.
- Activation rollback restores the previous-release record only when the
  active link was actually rolled back (or never moved), so a failed link
  rollback no longer leaves `active=B` and `previous=B`; a symlinked
  previous record is reported and removed instead of silently skipped.
- Activation rollback requires a readable `valise-release.conf` on the outgoing
  release before reconciling its stubs back, and `release_commands` fails
  closed on an unreadable manifest, so an unreadable manifest can no longer
  silently delete every owned stub.
- The POSIX managed block identifies the running shell with shell-specific
  builtin probes (`shopt`, `emulate`, `whence`) instead of inherited
  `KSH_VERSION`/`ZSH_VERSION`/`BASH_VERSION`, so a native bash login that
  inherits `KSH_VERSION`/`ZSH_VERSION` loads the bash plans, and ksh/dash/zsh
  inheriting `BASH_VERSION` are not mistaken for bash. The bash-login stage
  additionally excludes an `sh` invocation name and checks `shopt -q -o posix`
  (falling back to exact `set +o` matching), so bash invoked as `sh` stays on
  its env-only stage while reading the login file.
- `valise doctor` detects the bash-login marker with the trusted awk pass
  scoped to the managed block and the exact generated assignment line, instead
  of an untrusted whole-file `grep` resolved from the caller's `PATH`.
- `bin/valise` unsets `VALISE_CALLER_CWD` before recording it (a pre-exported
  value no longer keeps its export attribute and leaks into child processes),
  captures it with a sentinel so trailing newlines survive, and records an
  unavailable marker when the CWD is gone so `--help`/`--version`/`-C` still
  work; relative and empty caller PATH entries join the invocation directory
  with exactly one separator (no leading `//` from `/`) and are skipped when
  no caller directory is known.

## [0.4.0] - 2026-11-18

0.4.0 adds phase-separated plans, GUI-session environment bridges, and fixes
for startup state, environment capture, and release transactions.

### Added

- Phase-separated plans and a two-stage managed block. Module metadata accepts
  `phase=env|interactive` (default `env`); the compiler emits `plans/<shell>.sh`
  for the env phase and `plans/<shell>-interactive.sh` for interactive modules.
  The managed block sources the env plan at every startup entry point behind a
  release-id-keyed guard. Stage 2 sources the interactive plan only when `$-`
  contains `i`, and is written into the shell's rc-stage file and the bash login
  file. The env plan is written to `~/.zshenv` as well as `~/.zprofile`, and
  `sh`/`ksh` login shells get `ENV` pointed at a valise-owned shim so
  interactive POSIX subshells load valise too. `valise doctor` flags legacy
  single-stage blocks in the rc-stage files as upgradeable.
- `valise env export <environment.d|launchd|wsl>` renders the active release's
  env plan as GUI-session bridge content: `environment.d` `KEY=VALUE` lines,
  a `launchctl setenv` LaunchAgent plist, or WSL `WSLENV` flag lines. The
  `valise.conf` key `gui_env=off|systemd|launchd` (default `off`) makes
  `valise apply`/`install` write that bridge file itself
  (`environment.d/10-valise.conf` on Linux with a systemd user session,
  `~/Library/LaunchAgents/sh.valise.env.plist` on macOS), and `valise uninstall`
  removes it. The mode is recorded in the release, and `valise doctor` warns
  when the platform has a GUI session but no bridge file.
- `sp_cap_is_interactive` and `sp_cap_is_tty` in the capability library.
- The `valise_path` module (version 1.1.0) adds `valise_path_contains`,
  `valise_path_remove`, and `valise_path_normalize` beside the existing
  `valise_path_prepend` / `valise_path_append`. Prepend and append remain the
  core: they add a directory to the front or back of PATH exactly once, which
  is all most use cases need. The new helpers cover inspection and cleanup:
  `valise_path_contains` tests whether a directory is exactly one PATH entry,
  `valise_path_remove` removes every occurrence of the named entries and drops
  empty components, and `valise_path_normalize` drops empty components and
  duplicates in place. All five are idempotent, safe under `set -u` with an
  unset `PATH`, and leave the caller's `IFS` and shell options alone: they walk
  PATH one colon-delimited component at a time instead of word-splitting it, so
  nothing has to be saved, restored, or switched off. Every comparison is
  byte-exact, so a metacharacter entry never matches a lookalike and a
  case-distinct entry survives even under `shopt -s nocasematch`. Entries that
  contain a glob character are compared literally, never expanded against the
  filesystem.
  `valise_path_contains` and `valise_path_remove` reject an empty or
  colon-bearing argument with a diagnostic on stderr, and `valise_path_remove`
  also returns nonzero and leaves `PATH` exactly as it found it.
  `valise_path_prepend` and `valise_path_append` skip empty arguments.

### Changed

- The `$ENV` stanza is emitted into every managed block and decided at runtime
  by what the shell does, not by the plan class: bash ignores `ENV` as `bash`
  and reads it as `sh`, and dash and ksh read it, so an unconditional stanza
  wires exactly the shells that need it. A `$` value or a value starting with
  `~` stays user-owned. The shim carries both stages and is a managed startup
  file: `valise uninstall` strips the block and keeps any lines you added, and
  ownership is an exact-line marker match rather than a substring.
- The env-plan capture keeps your real `HOME`, `XDG` roots and `TMPDIR`, and
  isolates only the startup-file surface, so a variable derived from any of them
  carries the real path. It uses `/bin/sh` for the `sh` class, so it works on a
  host without dash. It names the variable and fails before the active release
  changes when a value cannot be represented (a newline, a control byte outside
  XML 1.0, U+FFFE or U+FFFF, or an empty value for `environment.d`), when the
  interpreter is unavailable, or when the plan fails to load. The module
  interpreters for bash, zsh and ksh come from PATH, like the shells they
  describe.
- `launchd` values are shell-quoted before XML-escaping, so a value containing
  a space, `;`, `$`, a backtick or a quote reaches `launchctl setenv` intact.
  `environment.d` doubles `$` to `$$` (systemd expands it even in quotes).
  `wsl` emits one colon-joined `WSLENV=` line with spec-correct flags derived
  from the value shape (`/l` for a colon-delimited path list, `/p` for a
  single absolute path, no flag for a scalar). Bridge files are written mode
  `0600` because they can carry values read from protected files.
- `valise apply --dry-run` reports the ENV shim and the GUI bridge without
  running module bodies. It reports a bridge mode for another platform as
  skipped, and reports ownership of an existing bridge file. It no longer
  treats an unknown `gui_env` value as a silent skip.
- A release built elsewhere and installed directly still writes its bridge.
  `valise release use`/`rollback` re-render the bridge for the release they
  activate and remove a valise-owned bridge when that release wants none.
- `valise test` and `valise run` load both phase plans, so a module under test
  is present whatever phase it declares; a command plan renders the whole
  closure, so a published command of an `interactive` module works.
- Raw `PATH=` assignments are lint-rejected in every phase (comments and
  `*.fish` bodies excepted). A later startup file that changes `PATH`
  re-asserts the env plan, so a `valise_path_prepend` entry survives a user rc
  file that resets PATH. `valise doctor` warns when `$ENV` is unset as well as
  foreign, checks `~/.zshenv` whenever zsh is installed, and only warns about a
  GUI bridge the active release actually asked for.
- Compile rejects an `env`-phase module that requires an `interactive` one, and
  fails when interactive-phase probing fails, instead of omitting the
  interactive plan. The plan header is `# plan=<shell> phase=<phase>`: a reader
  that parsed it by splitting on `=` must take the shell name as the first word
  of the value.
- The GUI bridge is prepared before the release changes and published after
  it. Bridge removal moves every owned file aside before deleting any of them,
  and a failed publish restores the active link and the previous-release
  record. The bridge is a file, not an effect: environment.d applies at
  user-manager start, the LaunchAgent at login. See
  [GUI-session environment](docs/installation.md#gui-session-environment).

### Fixed

- A required env dependency that failed in one startup file no longer lets its
  interactive dependent run in a later file, including after a zsh login repair
  pass. A missing env plan or a failed evaluation no longer counts as success.
- An interactive bash login shell reaches the interactive plan through its
  login file, placed last, so `bash --login -i` loads it. An interactive zsh
  runs the stage from `.zshrc`, not from `.zshenv`.
- Switching A to B to A in one shell restores A's interactive definitions,
  including when B has no interactive plan. A module's export is replaced only
  by the same module on reload; a different module exporting the same name, or
  a caller's function, is reported instead of silently replaced.
- The env capture keeps TMPDIR and XDG roots exactly as set or unset, so a
  derived export and its `:=` default match a real session. It resolves the
  dump utility by absolute path before the plan runs and reports the plan's own
  stderr instead of only a failure. Injected NUL or newline bytes can no longer
  fabricate a variable or truncate a value.
- `valise_test_reload` starts with fresh availability, so a repaired dependency
  and its dependent load on the next pass.
- `gui_env=off` removes the owned bridge files as one set: a failed removal
  leaves every file in place. A failed bridge publish during `release use`
  restores the previous-release record, so `release rollback` does not select
  the active release.
- `valise lint` no longer aborts with `Bad substitution` under a `#!/bin/sh`
  that is dash; the suite runs the CLI under a non-bash `sh`.
- The developer-command suite again removes its scratch directory on a normal
  exit.
- `valise uninstall` no longer deletes user content from a damaged `$ENV` shim;
  the shim uses the paired-marker pre-check and refuses an unpaired file.
- `gui_env=systemd` now renders through `environment.d`, so an automatic
  systemd bridge works and a render failure fails the install instead of
  reporting success.
- `release use`/`rollback` no longer write a bridge for an install that used
  `--no-integration`. `valise doctor` no longer reports a fresh install's
  env-only startup blocks as legacy.
- Joined XDG paths no longer produce `//valise` when `XDG_CONFIG_HOME=/`.
  `make check` no longer requires the removed empty `helpers/` and `install/`
  directories. The end-to-end suite filters bash's `cannot set terminal
  process group` warning alongside `no job control in this shell`.
- A failed GUI-bridge publish no longer leaves a mode-0600 `.valise-gui.*`
  staging file in the bridge directory, and an aborted install removes one it
  had staged.
- Bridge removal now uses an unpredictable mktemp aside name instead of a
  PID-suffixed one, so it cannot clobber a user file at that path.
- `valise uninstall` no longer aborts mid-way when the GUI-bridge removal
  fails: it finishes the remaining cleanup and exits nonzero with a warning.
- `valise release use` rolls the active link and the previous-release record
  back also when no release was active before, and rolls both back when
  command-stub reconciliation fails.
- `apply --dry-run` reports `would remove: <path>` for a valise-owned bridge
  that `gui_env=off` would delete, and reports a foreign or symlinked bridge
  as left alone.
- `integration_preflight` checks the GUI-bridge directory only on the
  platform that actually writes that bridge mode.
- The env capture treats a failed `tr`/`wc` count as a refusal instead of
  coercing it to zero, pins `LC_ALL=C` on every awk step, replays a plan
  diagnostic whose final line has no newline, and no longer passes an unused
  `EEC_ROOT` to the probe.
- `valise test`/`valise run` no longer leave `VALISE_MODULE_ROOT` or
  `_valise_plan_carried` set once the module body has loaded: both are cleared
  before the test callback and before a `run` script executes (and again after
  `valise_test_reload`), so a test can catch a module that reads them at
  runtime instead of at load time.
- The managed block tolerates an unset `PATH` under `set -u`, leaves a
  dangling `$ENV` symlink alone (a symlink belongs to whoever created it, the
  same rule `valise install` follows for a symlinked shim), and clears the env
  success markers when the env plan file disappears mid-startup.
- Compile rejects two modules that share a display name in one closure (the
  export-ownership ledger names providers by display name).

## [0.3.0] - 2026-11-06

0.3.0 changes the project layout, the metadata, and the release format. A
0.2 project must be moved to the new layout and its releases rebuilt; see
[What changed in 0.3.0](docs/release-policy.md#what-changed-in-030).

### Added

- Published commands. Metadata `commands=` names exports to publish and
  `executables=` names scripts. `valise build` writes a command plan per
  module under `plans/commands/` and a launcher per name under `bin/`, and
  install writes a stub for each into
  `${VALISE_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}`. valise records
  the stubs it writes in `$XDG_STATE_HOME/valise/commands.tsv` and never
  replaces or removes a file it did not write. `valise doctor` reports
  collisions and a command directory missing from `PATH`.
- `valise lint [--require-parsers] [module...]` checks metadata, layers,
  every bundle compiled for every variant and shell, and the syntax of each
  body and test with the parser of every shell the module declares. The
  `valise.conf` key `lint_layer_forbid` makes lint reject a pattern, such as
  an employer name, anywhere under `layers/`.
- `valise test [--shell=<class>] [--require-shells] [module...]` runs each
  module's `tests=` scripts in every declared shell that is installed, in
  an `env -i` environment with a fresh `HOME` and XDG tree.
  `valise_test_reload` lets a test write fixtures and load the module again.
- `valise run [--shell=<class>] [--module=<m>]... [--bundle=<b>]
  [--variant=<v>] [--keep-env] -- <script>` loads modules into a shell and
  runs a script there.
- `valise env` prints the engine, project, and storage paths as shell-quoted
  `KEY=value` lines.
- `valise test` and `valise run` export `VALISE_TEST_RELEASE` and
  `VALISE_TEST_PLAN`, so a test can load the same modules in a child shell.
- `valise uninstall [--keep-releases]` removes the managed blocks (keeping
  every other byte and the file mode), the startup files install created
  that are left empty, the Fish hook, the owned command stubs, the active
  link, and the installed releases.
- `valise release rollback` makes the previously active release active
  again. Every switch records the release it replaced in
  `$XDG_STATE_HOME/valise/previous`.
- `valise apply --dry-run` builds the project and prints what install would
  change in the release store, the startup files, the Fish hook, and the
  command directory, without writing outside `build/`.
- A bundle's `fish` rows build the native Fish runtime into the release
  under `runtime/fish/`, and the Fish hook loads the bundle's Fish roots
  from it. `valise new` scaffolds a Fish seed module.
- `valise -C <dir>` runs a command as if started in `dir`. Project commands
  find the project from any subdirectory.
- `valise.conf` key `requires_valise`: an older valise refuses to build the
  project.
- `valise module new --into=<module>[,...]` and `--no-wire` for projects
  whose default bundle has several POSIX roots.
- Metadata `tests=` names the test scripts of a module.
- `shells=posix` names every POSIX shell.
- `docs/projects.md` describes the project layout, bundles, variants,
  compile, and build.

### Changed

- A project is the directory holding `valise.conf`, with `module.d/`,
  `modules/`, `layers/<provider>/`, `bundles.tsv`, and `variants.tsv` at its
  root. `valise.conf` replaces `shell/release/project.conf`, `bundles.tsv`
  replaces `shell/release/bundle-roots`, and `variants.tsv` replaces
  `shell/release/install-variants`. The `shell/` layout is not read.
- The registry is internal: `valise build` generates it on demand from the
  metadata, and `valise registry` prints it. It has columns for `commands`,
  `executables`, and `tests` and a `source` of `module.d`,
  `layers/<provider>/module.d`, or `valise`.
- The engine modules are renamed into the reserved `valise_` namespace
  (`valise_path`, `valise_editor`, `valise_history`, `valise_pager`,
  `valise_xdg`, `valise_platform_posix`, `valise_platform_macos`,
  `valise_platform_linux`, `valise_platform_bsd`), with exports renamed to
  match, such as `valise_path_prepend`. They are available to every
  project without vendoring. A project or layer module may not use the
  `valise_` prefix, and layer modules must use `contrib_`.
- `shells=sh` names only the generic POSIX class (dash, BusyBox ash, and
  other plain `sh`), so `shells=sh bash ksh` loads in dash, bash, and ksh
  and not in zsh. Use `shells=posix` for every POSIX shell.
- Release format 2. A release holds `plans/<shell>.sh` for `sh`, `bash`,
  `zsh`, and `ksh`, `runtime/capabilities.sh`, `valise-release.conf`
  (`format=2`, the bundle, the variant, the roots per shell, the modules,
  and the commands), and `manifest.tsv`. It contains only the modules some
  plan loads, so a module a variant excludes is absent with its body.
  Install refuses a tree without `format=2`.
- The POSIX managed block picks the plan for `ksh`, `zsh`, `bash`, or `sh`
  and sets its guard only after the plan loaded, so a later startup file
  retries after a failure.
- Install is transactional. It checks every startup file, the Fish hook
  path, and (when commands are published or already tracked) the command
  directory before changing the active release and, if a later step fails,
  restores the previous active release, the previous-release record, and
  the command stubs, and names the files it already wrote. A new managed
  block is appended with nothing around it, so uninstall restores the file
  exactly. Text after a block keeps the file's ending, with or without a
  final newline, and a repeat install rewrites nothing.
- Install warns, and `valise doctor` fails, on a line outside a managed block
  that loads valise by hand.
- `valise build` moves the previous `build/release` aside and restores it if
  publication fails.
- An identical installed Fish hook is left in place, and apply reports
  `Fish hook current`.
- `valise status` reports the bundle, variant, and valise version the active
  release was built with, separately from the project defaults.
- `valise explain-variant` counts the roots and modules a variant keeps per
  shell, resolving qualified names.
- `bin/valise` is a dispatcher over the parts in `lib/cli/`.
- The package `files` list names every shipped file, so packing a local tree
  ships only the runtime, the docs, and the example sources, not stray local
  files. A test fails when a tracked file is missing from the list.

### Removed

- The `shell/` project layout, `registry --check`, and the committed
  registry.
- Metadata `updates=`. Metadata naming it fails with a message naming
  0.3.0.
- The engine release shape: `entrypoints/fish/profile.fish`, the POSIX
  block's loader fallback, and the Fish hook's `generated/`, `vendor/`, and
  entrypoint routes.
- `examples/e2e/build-manifest.sh`; `examples/e2e` is a valise project built
  with `valise build`.
- `docs/variants.md`, replaced by `docs/projects.md`.

### Fixed

- `sp_cap_secure_local_bin_check` accepts `allow-owned-symlinks`. The default
  still rejects every symlink in `~/.local/bin`; the option accepts a symlink
  whose link entry is owned by the current user, which is how pipx and uv
  publish commands, while still rejecting unowned entries and group- or
  other-writable regular files.
- A repeated metadata field was silently overwritten by the last value; the
  POSIX and Fish readers now reject it.
- The Fish loader rejected caller aliases, because `functions --copy` drops
  `--wraps`.
- Fish 3 lists autoloadable but undefined functions in `functions --all
  --names`, and that list grows as the loader introspects it. The Fish loader
  and the generated hook now take their "created by this activation" baseline
  after that introspection, so Fish's own system functions are no longer
  attributed to a module or an entrypoint and published in an ownership
  ledger whose `/usr/share/fish` source can never be authenticated.
- A body that replaced `cd` on Fish 3, where `cd` is a file-backed system
  function rather than an embedded one, was reported as a generic loader-state
  mutation. It now fails closed as a mutated critical Fish function, matching
  Fish 4.
- A module body that sourced a Fish completion or function file, or ran
  completions, materialized Fish's own system functions. Those entered the
  ownership ledger, so the next activation failed closed before its cleanup
  erased real Fish functions. Fish system functions are no longer recorded as
  module- or entrypoint-owned, on Fish 3 (file paths) and Fish 4 (embedded
  paths) alike.
- `valise doctor` did not accept FreeBSD's `sha256`.
- `valise module new` assumed the seed module was `profile_main`.

## [0.2.0] - 2026-10-31

### Added

- `valise new`, `valise module new`, `valise module list`,
  `valise module remove`, `valise build`, `valise apply`, and
  `valise status`. A new project can be scaffolded, given a module, built,
  installed, and checked without hand-writing a registry or a build script.
  `valise module new` writes the module body and its declared export, and
  wires the module into the seed aggregator. `valise apply` builds, installs,
  writes the shell integration, and verifies the result; it is idempotent.
  `valise status` reports the project, the active release, the integration
  state, and whether the active release has drifted from the build output.
- `valise registry`, which generates `shell/release/module-registry.tsv` from
  the project's metadata. `valise build` regenerates and validates the
  registry, so a committed registry is a generated artifact rather than a
  hand-maintained catalog. The row order is fixed: the primary modules of
  `shell/module.d/` first, then the layer modules of each
  `shell/layers/<provider>/module.d/`, each group in C-locale name order.
- `valise release list`, `valise release use`, `valise release prune`, and
  `valise release verify`. They manage installed releases; source variants
  remain the business of `valise build` and `valise apply`.
- Command-specific `--help` for `build`, `compile`, `install`, `init`, `new`,
  `module`, `release`, `doctor`, and `status`, so each prints its own
  contract rather than the global command list.
- Meta modules: metadata with `requires=` and no `load` is a
  dependency-only aggregator and loads successfully without a body. `load`
  and `requires` may be combined.
- `side_effect=local-state`, a source-safe side-effect class for modules
  that write under the XDG state directory.
- `VALISE_RELOAD=1`, which unsets the declared exports of the requested
  closure before loading so a profile can be re-sourced.
- The `sp_cap_*` capability helpers remain available at runtime after a
  compiled plan or a loader load finishes, so a module can call them.
- `examples/profile-project/`, a complete consuming project with two
  modules, a provider layer, two variants, and a bundle, and a README that
  walks from clone to a loaded profile.
- A consumer end-to-end test target that builds the reference consumer
  profile from a temporary copy, runs the consumer's own metadata, shells,
  release, and features suites, installs and verifies the release, and
  proves a second build is byte-identical. The original tree and the live
  profile are never touched.

### Changed

- `valise build` builds a complete release tree to `build/release` by
  default, reads the variant and bundle defaults from
  `shell/release/project.conf`, and requires an explicit output directory to
  be empty or absent. A failed build preserves the previous build output.
- `valise build` produces no Fish surface: no Fish entrypoint, generated
  plan, or native loader. A built release therefore loads nothing in Fish;
  the Fish hook verifies the active release and stays silent. Only an engine
  release with `entrypoints/fish/profile.fish` uses the native Fish loader.
- `valise install` writes shell integration by default. It always writes
  `~/.profile`; it adds `~/.bash_profile` or `~/.bash_login` when one of
  those exists, because bash reads that file instead of `~/.profile`; it
  writes `~/.bashrc` when bash is the current shell or that file exists; it
  writes `~/.zprofile` when zsh is on `PATH` or that file exists, because zsh
  reads nothing else at login; and it writes `~/.zshrc` when zsh is the
  current shell or that file exists. Existing files are kept current rather
  than replaced. A symlinked startup file is reported and left untouched.
  `--no-integration` installs without writing any startup file. Install also
  writes the Fish `conf.d` hook when it finds Fish in a trusted location;
  `valise apply` runs the same install path.
- The startup integration is a managed block between `# BEGIN valise managed
  block` and `# END valise managed block`. Repeat installs are idempotent and
  existing profile content is preserved. An unpaired marker is refused and
  stops the install. Install prints each path it wrote and how to remove the
  block.
- `valise init` takes `posix` or `fish`; any other argument is rejected.
  It is a one-time snippet generator, not something to evaluate at every
  prompt.
- A project's default variant is `default`. An unknown variant is an error
  in every command that accepts one.
- Compiled plans and the loader now agree on required dependency closure.
  Platform skips are recorded during discovery and reported once the full
  required closure is known; strict mode fails when a required module is
  blocked during ordering; permissive mode continues and returns zero. Fish
  reports a platform-skipped optional dependency silently.
- Compiled plans reach parity with the loader: they gate modules by
  `platforms=` at runtime, pre-check and post-check declared exports, report
  each failing module by name, continue past a failure in permissive mode
  while returning zero, stop in strict mode, and support meta modules with no
  source line.
- The loader saves the logical `$PWD` and `$OLDPWD` before sourcing each
  module and restores them afterwards, so a module that changes directory
  during its load leaves the caller's logical directory as it was.
- The loader's export pre-check accepts a name that currently resolves to an
  external command, which is how a deliberate wrapper is exported. It still
  rejects a name already defined as a function, builtin, or alias.
- The loader resolves each metadata record with shell builtins instead of
  repeated `sed`, `grep`, and `cat` processes, so the number of external
  processes a load spawns does not grow with the number of modules.
- `valise compile` and `valise build` find the packaged
  `lib/capabilities.sh` relative to the CLI, so a symlinked or relocated
  install works. A compiled plan rejects a module that has neither a load
  path nor dependencies, and names the module.
- Layer handling accepts any `shell/layers/<provider>` path rather than only
  the `contrib` provider, and produces a deterministic manifest.
- `valise doctor` reports a missing active release as a failure and reads the
  startup files the running shell actually reads. `--pre-install` skips the
  release and integration checks; `--no-integration` checks only the
  environment and the active release.
- `valise explain-bundles` and `valise layer-lint` are implemented in POSIX sh
  and awk. `layer-lint` validates a provider layer's structure, `contrib_`
  name prefix, version, load path, symlink freedom, file modes, and
  dependency containment.
- The unused Python consumer-release helpers, wrapper lifecycle hooks, and
  the submodule build prelude override are gone. No command requires
  Python 3.

### Removed

- `load_hook` and the compatibility bridge in the POSIX loader, the Fish
  loader, and compiled plans. A module declares `load`, `requires`, or both.
  Metadata naming `load_hook` fails with
  `metadata field load_hook is not supported; use load`.
- `variant list`, `variant use`, and `verify-active`; installed releases are
  managed by `valise release list|use|prune|verify`. `variant` now refers
  only to build variants.
- The per-shell `valise init` arguments `bash`, `zsh`, `ksh`, and `sh`; use
  `valise init posix` or `valise init fish`.

### Fixed

- `valise` with no arguments: under `set -e`, a zero-argument `shift` could
  terminate the CLI before it displayed its help text.
- Fish activation: functions loaded from package paths such as Homebrew are
  authenticated and preserved through the load instead of being rejected or
  lost.
- The primary-root symlink diagnostic was printed on stdout while every
  other loader diagnostic went to stderr.
- `valise compile` reported that a Fish plan requires a Python compiler and
  named a file that does not exist in this repository. Fish plans are not
  generated; a Fish integration uses the native Fish loader.
- Applying to a home directory with a trailing slash could skip the zsh
  startup file, because the target was compared against the raw `HOME`
  string rather than a normalized path.
- A built release's Fish hook printed an error on every Fish start. It now
  verifies the release quietly and returns when there is no Fish surface to
  load.
- A module that makes `PWD`, `OLDPWD`, or `IFS` readonly no longer aborts the
  loader mid-transaction. The module fails as caller-state modification, and
  the loader's cleanup still runs.
- Loader temp-directory cleanup resolves `rm` from a fixed absolute path, so a
  module that changes `PATH` cannot leave its metadata scratch directory
  behind.
- Compiled plans remove a failed module's declared exports, like the loader.
  A meta module that declares exports is rejected at compile time, and an
  optional-only cycle inside a required graph is quarantined instead of
  failing the whole plan.
- The compiler rejects an unsafe layer directory name and a reserved-word
  export instead of emitting an unparseable or misleading plan.
- `release list`, `release use`, `release prune`, `doctor`, and `status`
  identify the active release by its canonical directory name, so a trailing
  slash or an alias symlink cannot hide it from the list or make prune delete
  it.
- `module remove` keeps a body that another module still loads, and checks
  every directory it will rewrite before changing anything. `module new`
  checks the seed metadata before writing and rejects reserved-word exports.
- `make-manifest` rejects a directory or symlink as its output, and a
  normalized in-tree output path is excluded from its own manifest.
- `valise install` holds its lock through the Fish and POSIX integration
  writes, so concurrent installs cannot interleave them.
- The editor-defaults test is independent of host-installed editors by
  supplying a temporary test `vi` executable.

[Unreleased]: https://github.com/joeycumines/valise-sh/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/joeycumines/valise-sh/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/joeycumines/valise-sh/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/joeycumines/valise-sh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/joeycumines/valise-sh/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joeycumines/valise-sh/releases/tag/v0.1.0
