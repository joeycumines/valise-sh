# Changelog

Notable user-facing changes are recorded here. Versions before 1.0 may include
module ABI or CLI changes; see [the release policy](docs/release-policy.md).

## [Unreleased]

Planned version: **0.4.1**. This release hardens activation recovery, shell
startup and compiled plans, environment capture, and compatibility checks.

### Added

- `VALISE_CALLER_PATH` supplies the original PATH for install and doctor
  diagnostics when a wrapper invokes valise with a sanitized PATH. It never
  participates in command lookup or generated profile content. An explicitly
  empty value reports a PATH gap; relative and empty entries use the physical
  invocation directory recorded before `-C`.
- A native macOS CI job complements the Linux strict gate. Both retain test
  logs; macOS covers system Bash 3.2 and BSD utilities, while Linux also
  requires BusyBox ash. Native zsh is included in the POSIX parser contract.

### Fixed

- Phase probing distinguishes a genuinely empty phase from allocation,
  compilation, inspection, or malformed compiler-output failures. A private
  scratch directory and signal-aware cleanup prevent a failed probe from
  silently publishing a release without interactive plans or leaking scratch.
- Install and release activation share one recovery transaction. Before the
  active link moves, the transaction snapshots the previous record, command
  ledger, verified owned stubs, and owned GUI bridges. Recovery restores saved
  bytes and modes instead of re-reading an outgoing manifest that may have
  disappeared or become unreadable.
- Activation validates the active link and ownership records before mutation.
  Symlinked, non-regular, unreadable, and malformed records fail closed without
  being followed or silently replaced. Relative, dangling, and newline-bearing
  active targets are captured and restored byte-exact (the library's readlink
  captures use the same sentinel as the CLI bootstrap, so command substitution
  cannot strip a target's own trailing newlines). A prior empty command ledger
  stays present; a
  failed first install restores the ledger's prior absence.
- Stub publication journals its staging inode before creating the public hard
  link. Rollback removes only a verified new publication, restores deleted
  outgoing stubs, and preserves user edits and identical foreign collisions.
  Unterminated final ledger records are consumed consistently.
- INT and TERM are recorded through mutation bookkeeping and recovery; a
  second signal cannot terminate restoration midway. The final status is 130
  or 143 as appropriate. The central exit handler performs transaction,
  scratch, and lock cleanup without recursively aborting itself.
- Critical allocation and recovery workers also withstand process-group
  signals. Temporary pathnames are assigned to their cleanup owner before a
  pending signal is honored; a utility cannot create a lock or scratch file
  and lose its ownership record when it is interrupted immediately afterward.
  The signal-shielded wait no longer prints a reaped-PID diagnostic to stderr
  (Bash 3.2 and GNU bash both emit one for an already-collected child), so
  diagnostics captured with `2>&1` stay clean.
- Existing store locks are never reclaimed automatically. The previous
  dead-PID check followed by deletion allowed simultaneous reclaimers to
  delete each other's new lock and enter the store concurrently. A leftover
  lock now requires explicit recovery after all users of that store stop;
  the diagnostic names the lock and its recorded PID when readable.
- Recovery failures preserve private snapshots and report their locations.
  When the active link cannot be restored, old bridge bytes are not published
  under the incoming active release. Post-commit cleanup failures report a
  nonzero result without rolling back a committed activation.
- GUI bridge removal distinguishes failure before commit from failure to
  remove a committed backup. Both bridge directions, including `gui_env=off`,
  participate in activation recovery. Ownership checks refuse symlinks and
  non-regular files before reading, so a foreign FIFO cannot block startup
  integration.
- The POSIX managed block identifies the running interpreter using isolated
  builtin probes, with external lookup disabled. Inherited shell-version
  variables and lookalike `shopt`, `emulate`, `whence`, and `builtin` commands
  no longer select another shell's plans.
- A fresh non-Bash-default home receives a Bash login stage in `.profile`
  without requiring `.bashrc`. Actual Bash-as-`sh` reads the env stage there
  and interactive setup through `$ENV`; a native Bash executable named
  `sh-as-sh`, `SH`, or another custom name still loads its interactive stage
  from the login file. Option checks and invocation-name comparisons remain
  correct with `nocasematch`, `verbose`, or `xtrace` enabled.
- Interactive success markers are invalidated before a release switch and
  before retrying stage 2. Returning to a release after a partial failure or
  an env-only intermediate release restores its interactive definitions.
- Runtime `$ENV` adoption and doctor require a readable regular non-symlink
  shim with the exact managed header. Doctor detects the Bash login marker
  inside its managed block using trusted awk, and reports invalid command
  ledgers as failures rather than disabled integration.
- Compiled module dispatch, dependency availability, platform matching, and
  export ownership use byte-exact identities even with Bash `nocasematch`.
  An external executable or alias cannot satisfy a promised function export.
  Native zsh cleans all declared exports created by a failed module and
  preserves pre-existing caller definitions.
- Environment capture preserves explicit empty caller inputs and uses the
  caller's PATH in both baseline and target evaluations. Binary environment
  records retain their NUL boundaries through comparison and exclusion;
  newline-bearing excluded values cannot fabricate variables or reject
  unrelated valid exports.
- Selected bridge values are checked against the Unicode scalar limits of
  UTF-8, including overlong forms, surrogates, obsolete five/six-byte forms,
  and code points above U+10FFFF. Diagnostics name the offending variable and
  failures emit no partial bridge. `environment.d` additionally rejects TAB,
  DEL, and all Unicode noncharacters; launchd retains XML-compatible UTF-8,
  TAB, and DEL. Capture allocation, scanning, and cleanup failures fail closed.
- `valise run` preserves stdin in clean and `--keep-env` modes for every
  supported interpreter; only the automated test runner receives EOF.
- Native Fish recognizes its own distributed functions in relocated
  installations without trusting mutable Fish path variables. Unrecoverable
  caller-state corruption now terminates the Fish process with status 125;
  `exit` inside a sourced Fish file previously allowed the caller to continue.
- CLI bootstrap resolves package symlinks through fixed trusted `readlink`
  paths and preserves invocation-path newlines in the generated Fish callback.
  Bootstrap and `-C` directory selection ignore `CDPATH`. Physical engine and
  project roots containing TAB or LF are rejected before their line-oriented
  consumers can silently resolve a different pathname.
- PATH diagnostics compare physical directories, preserving symlink/`..`
  semantics and accepting different aliases for the same location. They
  preserve trailing newlines, ignore inherited `CDPATH`, join `/` with one
  separator, and skip relative entries when the invocation directory is
  unavailable. Diagnostic CWD state is never exported to child processes.
- `valise_path_remove` validates every argument before modifying PATH, so a
  mixed valid/invalid call fails without partially applying removals.
- Reserved-word validation patterns parse under Bash 3.2 as well as newer
  POSIX shells. Tests discover supported interpreters from their controlled
  PATH, and strict-tooling requirements survive the test runner's environment
  quarantine.
- File digests are computed from stdin, so SHA-256 utility filename escaping
  cannot introduce a backslash into a command ledger or release digest.

### Documentation

- Documented the transaction's recovery scope, retained recovery material,
  commit boundary, and failure limits; clarified env re-evaluation triggers,
  caller function ownership, capture exclusions, and the explicit npm package
  allowlist.

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

[Unreleased]: https://github.com/joeycumines/valise-sh/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/joeycumines/valise-sh/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/joeycumines/valise-sh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/joeycumines/valise-sh/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joeycumines/valise-sh/releases/tag/v0.1.0
