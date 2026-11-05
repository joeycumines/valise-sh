# Module ABI

This document defines module metadata and the rules the compiled plans and
the loaders apply to it. Metadata is data: valise never executes a module to
learn its name, dependencies, or supported shells.

## Metadata file format

Module metadata lives in `module.d/*.meta` as UTF-8 text with one `key=value`
field per line. Blank lines and `#` comments are ignored. Values are plain text;
there is no shell quoting, interpolation, command substitution, glob expansion,
or `eval` phase. Each field may appear once: a repeated key is rejected rather
than letting the last value win. An unknown field is rejected, and so is
`updates`, which was removed in 0.3.0.

Required fields:

| Field | Meaning |
| --- | --- |
| `name` | Stable module identifier. |
| `shells` | Space-separated supported shell identifiers. |
| `platforms` | Space-separated supported platform identifiers. |
| `side_effect` | Startup/install/update side-effect class. |
| `load` | Path to the module body, relative to the module's source directory. Absent for a **meta module** (see below). |
| `requires` | Required for a meta module. |

Optional fields:

| Field | Meaning |
| --- | --- |
| `requires` | Space-separated required dependency module identifiers. |
| `optional` | Space-separated optional dependency module identifiers. |
| `exports` | Space-separated exported command/function identifiers. |
| `commands` | Space-separated exports a built release publishes as commands on PATH. |
| `executables` | Space-separated module-relative paths of scripts published as commands. |
| `tests` | Space-separated module-relative test scripts that `valise test` runs. |
| `version` | Optional module version used to reject version skew across roots. |

## Meta modules

A **meta module** declares dependencies and has no body. It is the natural
way to write an aggregator: instead of an empty shell file whose only job is
to name a dependency, the aggregator is metadata alone.

A meta module has `requires=` with at least one entry and **no** `load=`.
The loader and the compiler treat it as a dependency-only
record: the module itself has nothing to source, but its required closure
loads normally and in the right order. A meta module must leave `exports=`
empty; it has no body to define an exported function. Metadata that declares
an export on a meta module is rejected.

```text
name=profile_main
version=1.0.0
side_effect=read-only
requires=valise_path valise_editor
optional=
shells=posix
platforms=any
exports=
```

At least one of `load` or `requires` is required: a module with neither a
body nor dependencies is malformed.

`load` and `requires` are **not** mutually exclusive. A module that declares
both loads its own body *and* its dependencies, in dependency-first order.

## Identifiers and allowed values

Module names, dependency names, and exported shell functions must match
`[a-z_][A-Za-z0-9_]*`. List fields are separated by ASCII space only; tabs,
carriage returns, and other control characters are data errors, not alternate
separators. Optional list fields may be truly empty to mean zero entries, but a
non-empty list containing only whitespace is malformed. Required `shells` and
`platforms` lists must contain at least one parsed value. Empty identifiers,
whitespace inside one identifier, path separators, quotes, shell metacharacters,
glob characters, and control characters are invalid. Invalid identifiers are
rejected before the loader can build function names or source a body.

Accepted `shells` values are `posix`, `sh`, `bash`, `zsh`, `ksh`, and
`fish`. Each running POSIX shell belongs to one class: `bash`, `zsh`, or
`ksh` when the shell can be proven to be that shell, and `sh` for every
other POSIX shell (dash, BusyBox ash, and so on). The values match classes
as follows:

- `posix` matches every POSIX class: `sh`, `bash`, `zsh`, and `ksh`. Use it
  for a body written in portable shell.
- `sh` matches only the `sh` class. Combine it with the shells the body also
  supports: `shells=sh bash ksh` loads in dash, bash, and ksh, and is skipped
  in zsh, for a body that needs word splitting zsh does not do.
- `bash`, `zsh`, and `ksh` match only that class.
- `fish` selects the native Fish runtime. Fish never sources a POSIX body,
  and no POSIX value matches Fish.

A module whose shells do not include the running class is skipped; a bundle
root, or a module a root requires, that does not support its shell is an
error.

In a built release, the native Fish loader resolves the release's Fish roots
(`roots_fish=` in `valise-release.conf`) against the release's `module.d/`,
each `layers/<provider>/module.d/`, and `valise/module.d/`, in that order.
`runtime/fish/profile.fish` is the adapter the Fish hook sources: it sets
`_sp_fish_loader_bootstrap_mode` and `_sp_fish_loader_bootstrap_seeds`,
sources `runtime/fish/loader.fish`, and requires the
`_sp_fish_loader_bootstrap_status` marker the loader publishes, failing
closed when it is absent. Duplicate providers of one name are valid only when
their metadata and Fish bodies are byte-identical.

Supported `platforms` values are `any`, `darwin`, `linux`, `bsd`, `freebsd`,
`openbsd`, and `netbsd`. `platforms=any` matches every supported platform.
Specific platform values are ORed: `platforms=darwin linux` matches macOS or
Linux, not BSD.

## Layers

A project composes provider modules by vendoring the provider's tree as
`layers/<provider>/` (its `module.d/` and bodies). Every module in a layer
uses the `contrib_` prefix, and the `valise_` prefix belongs to the engine.
Dependencies resolve by name: the same source first, then the only module
with that name; a name defined in several sources must be written as
`name@source` where it is used as a root or an exclusion. A built release
copies the layer modules it loads to `layers/<provider>/`, and one manifest
covers the project, layer, and engine files together.

To update a provider, copy a reviewed revision into `layers/<provider>/`,
review the diff, and rebuild; record the provider revision beside it if you
need to know later which one you have. The manifest proves that the
installed files match the release, not who wrote them.

### The development loader's search path

The POSIX loader in `lib/loader.sh`, used by `entrypoints/profile.sh` from an
engine checkout, resolves modules across a priority-ordered root list
instead: the primary root first, then the colon-separated
`VALISE_MODULE_PATH`. Its rules, enforced by
`tests/loader/multi-root.test.sh`:

- Every element must be a non-empty, readable, searchable directory. An
  empty element, a missing directory, a newline, or any of the glob
  characters `[`, `?`, and `*` is rejected. Duplicate elements are
  deduplicated; the first occurrence keeps its priority.
- A module present in several roots must have identical metadata and body
  bytes. Identical copies resolve to the highest-priority root; any
  difference is an error naming both paths.
- A module provided only by a layer root must carry the `contrib_` prefix.
- Bodies load from the root that provided the metadata. Dependencies resolve
  across roots in both directions, and the duplicate-export check is global.

## Versioning

Shared modules carry an optional `version` field so independent releases
of the same name can be told apart. The value must start with a digit
and contain only digits, letters, `.`, `_`, `-`; an empty value means
unversioned. Providers should bump the version for a breaking change.
Consumers vendor a specific provider snapshot; nothing resolves version
ranges. See [Layers](#layers).

Enforcement, where one name has several providers (the development loader's
roots, or the Fish loader's providers):

- The same name with different valid versions across roots fails closed
  with a version-skew diagnostic naming both versions and both paths,
  directing the consumer to vendor a single version.
- The same name with equal versions (including two unversioned records)
  keeps the byte rule: different bytes are forbidden, byte-identical
  copies resolve by priority. A versioned record against an unversioned
  one counts as different versions and fails with the skew diagnostic.

A versioned record that disagrees with itself is not a version at all:
malformed versions are rejected by `sp_metadata_read` before any body
is sourced.

## Runtime detection contract

The loader classifies the running shell and platform before matching module
metadata. This classification is frozen contract behavior, enforced by
`tests/loader/detection-contract.test.sh`:

- Shell detection is last-write-wins over runtime markers in the fixed order
  `bash` (BASH_VERSION together with a working `builtin shopt`), then `zsh`
  (ZSH_VERSION), then `ksh` (KSH_VERSION). With no marker the shell class is
  `sh`. The `builtin shopt` requirement is load-bearing: a non-bash POSIX shell
  stays class `sh` even when `BASH_VERSION` is forged into its environment,
  because it cannot provide the bash-only `shopt` builtin. Shell matching is by
  class alone, so the class an unmarked POSIX shell receives never grants it a
  `shells=bash` body.
- Platform detection maps `uname -s`: `Darwin` to `darwin`, `Linux` to `linux`,
  `FreeBSD`/`OpenBSD`/`NetBSD` to their identifiers, other `*BSD` to the `bsd`
  umbrella, and anything else to `unknown`. `platforms=any` is the only value
  that matches under `unknown`; every non-`any` module is rejected fail-closed
  with an `unsupported platform` diagnostic and its body never executes.
- Portability posture: the contract is declared to hold when the executing
  shell is dash rather than bash and when the loader's external utilities are
  BusyBox applets. Makefile lanes exercise dash, ksh, Fish, and BusyBox when
  those tools are present. Missing extended runtimes are visible skips on a
  developer machine; they become failures when `CI=true`,
  `GITHUB_ACTIONS=true`, or `VALISE_REQUIRE_TOOLING=1` is set. A skipped lane
  is not evidence for that shell/runtime. See the top-level README for the
  override and `config.mk` behavior.

Supported `side_effect` values are:

- `read-only` — defines functions or reads environment only.
- `path-env` — mutates PATH or exported environment variables.
- `generated-file` — writes managed files such as wrappers.
- `update-network` — performs explicit update/check network behavior.
- `install-time` — belongs only in installer flows.
- `local-secret` — reads local secret references at runtime only.
- `local-state` — creates or caches state under the XDG state directory.
- `work-only` — work/project-specific behavior that must be opt-in.

`requires` dependencies must exist and load before the declaring module. Missing
or failed required dependencies make the declaring module unloadable. `optional`
dependencies load first when available, but absence or failure of an optional
dependency must not make the declaring module fail by itself. Required and
optional lists use the same identifier grammar as `name`.

### Optional-edge ordering

The two loaders resolve optional-edge ordering differently, and both
behaviors are contract, pinned by `tests/loader/loader-failure-modes.test.sh`
and `tests/fish-runtime.test.sh` respectively:

- **POSIX loader — two-pass sort with an optional-relaxed fallback.** The
  first topological pass orders by both `requires` and `optional` edges, so
  a present but not-yet-ordered optional dependency holds its dependent
  back. When a pass makes no progress, a fallback pass retries while
  ignoring `optional` edges entirely, so optional ordering can never
  deadlock the graph — an optional-only cycle still loads its members.
  Only when both passes stall is the remainder diagnosed as a cycle. This
  is a deliberate liveness-over-strictness choice.
- **Native Fish loader — single Kahn pass with quarantine recovery.** A
  single pass holds a dependent back behind every present, loadable
  optional dependency. A stall quarantines the stalled members instead of
  running a second pass: directly-requested or required-closure members
  stalled by the cycle make strict mode fail closed, while permissive mode
  quarantines them and continues. Unlike the POSIX fallback, quarantined
  members are not loaded.

### Writing a cross-platform profile

`requires` means the module cannot work without the dependency, so a
dependency that does not support the host blocks the module and fails strict
mode. Use `optional` for platform-specific modules, so one profile works on
every host:

```text
name=profile_main
requires=common_tools
optional=mac_tools linux_tools
```

Only the module for the running platform loads. The other is skipped without a
message, because its absence is expected. The POSIX loader and compiled plans
follow the same rules.

`exports` lists the public functions the module defines. Plans and loaders use
it for the pre-load conflict check, the post-load check, and failure cleanup.
An exported name
must be defined by the module body before the module is considered
successfully loaded. An export must name a function, so shell reserved words
(`case`, `do`, `done`, `elif`, `else`, `esac`, `fi`, `for`, `if`, `in`,
`then`, `until`, `while`, and `time`) are rejected.

### Published commands

`commands` names exports that should also run as ordinary commands, from any
program and not only from an interactive shell. Every entry must also appear in
`exports`. `executables` names standalone scripts in the module's directory;
each is published under its file name, which must start with a letter, digit,
or underscore and contain only letters, digits, `.`, `_`, and `-`. The
metadata field `updates` was removed in 0.3.0; a metadata file that still sets
it is rejected.

`valise build` turns both into entries under the release's `bin/`:

- For a module with `commands`, it compiles `plans/commands/<module>.sh`, a
  plan whose only root is that module, for the module's command shell: `sh`
  when the module supports `posix` or `sh`, otherwise the first of `bash`,
  `zsh`, and `ksh` it lists. Each command gets a launcher `bin/<command>` that
  runs under that shell, loads the plan in strict mode from the release that
  contains it, restores the caller's `VALISE_MODE`, and calls the function
  with the command's arguments. The function's exit status is the command's.
- Each `executables` path is copied to `bin/<file name>` and keeps its own
  interpreter line.

The plan's closure ships in the release even when no shell bundle loads it.
A Fish-only module cannot declare `commands`; it may declare `executables`.
Two modules that publish the same command name, from either field, fail the
build. `valise-release.conf` lists the published names in `commands=`.
Installation puts a stub for each name on PATH; see
[installation.md](installation.md#published-commands).

## Side-effect phases

The ordinary source phase rejects `generated-file`, `update-network`, and
`install-time` modules before sourcing their bodies. `read-only`, `path-env`,
`local-secret`, `local-state`, and `work-only` are permitted by the engine;
choosing whether to load a `work-only` module is the consuming profile's
responsibility.

`local-state` is the permitted class for a module that creates a cache or
directory under the XDG state directory at source time (`mkdir -p` under
`$XDG_STATE_HOME`). It is the only write class the ordinary source phase
allows. A module that writes anywhere else must declare `generated-file`,
which the source phase rejects.

The enforcement hook is
`sp_metadata_validate_source_side_effect <side_effect>`. The loader calls it
before ordinary source invokes a load path.

## Capability layer available to modules

Every plan sources the capability prelude (`runtime/capabilities.sh` in a
release, `lib/capabilities.sh` in the engine) before any module, and the
development entrypoint does the same before the loader. Module bodies may
therefore call the `sp_cap_*` helpers without sourcing platform files
themselves: CPU count, file mtime, temporary directories and files, command
lookup, OS detection, canonical path containment, symlink-component
rejection, Homebrew discovery, secure local-bin checks, and background
process launch.

**The helpers stay available after the profile loads.** A compiled plan
sources the capability prelude and leaves it in place, so a function defined
by a module can call `sp_cap_os` or any other `sp_cap_*` helper long after
the plan finished loading. The compiled plan and the loader agree on this;
neither cleans the helpers up at the end of a load.

A module that needs a portable operation should call the `sp_cap_*` helper
rather than reaching for a platform-specific command directly. That keeps the
module working on every platform the engine supports, and keeps the
platform-specific code in one reviewed library.

Mutation paths must fail closed when a capability cannot prove safety. Update
destinations must combine canonical containment with symlink-component rejection
before writing, cooldown logic must use the mtime helper instead of raw
platform-specific `stat`, and secure temp creation must verify canonical
parent/prefix containment, non-symlink regular files where applicable, and
group/other permission closure after creation.
Read-only/status paths may degrade only by quietly skipping unsupported details
or by returning a clear nonzero status with a diagnostic from the caller.

Platform modules under `modules/platform/` are thin wrappers around the library.
They expose stable module dependencies (`valise_platform_posix`, `valise_platform_macos`,
`valise_platform_linux`, and `valise_platform_bsd`) while keeping compatibility logic in one
library.

## Load target and loader mode

For file-backed modules, `load` is the shell file sourced after metadata
validation, dependency ordering, shell and platform matching, and the
side-effect checks have passed. The ABI has no unload hook: the loader
does not implement module rollback or unload semantics.

A meta module has no `load`; it has `requires` and no body. Nothing is
sourced for it, but its dependency closure loads and its dependencies'
export checks still apply.

Module bodies must treat `_spl_*`, `_sp_loader_*`, and
`_SP_LOADER_*` names as loader-private reserved namespaces. Native Fish
transactions additionally reserve `_sp_fish_loader_scope_before_*`,
`__sp_fish_loader_scope_before_*`, `_sp_fish_loader_scope_after_*`, and
`__sp_fish_loader_scope_after_*` for verified transaction snapshots.
A module or caller that uses any of these names is outside the public ABI; the
loader clears forged or stale values rather than risking unverified
cleanup. A module that
modifies loader-private state during source is invalid; the loader must fail the
module and must never use module-controlled private state for recursive cleanup.
Modules must also not define shell functions that shadow critical shell control
utilities (`command`, `unset`, `readonly`, `return`, or `eval`) or mark those
functions readonly. Those names are reserved because the loader must recover
control after sourcing a module; direct definitions in module bodies are
rejected before the body is invoked.

After a body runs, the loader restores the caller's physical directory, logical
`PWD` and `OLDPWD`, `IFS`, and the shell options it snapshotted. A body that
makes any of those variables readonly is rejected as caller-state modification:
the loader fails the module without aborting the caller. Cleanup resolves `rm`
from a fixed absolute path, so a module that changes `PATH` cannot prevent it.

Failure handling is selected once by the loader caller with
`VALISE_MODE=strict|permissive`; it is not a per-module metadata promise.
Strict mode returns nonzero when a requested module or required dependency fails.
Permissive mode reports the affected module and continues with unrelated modules.

## Path fields

`load`, `executables`, and `tests` paths are relative to the module's source
directory (the project root, `layers/<provider>/`, or the engine). Absolute
paths, `..` path segments, spaces, quotes, shell metacharacters, and glob
characters are invalid. Reading metadata must not source these paths.

## Validation implementation

`lib/metadata.sh` provides the current metadata parser and validator:

- `sp_metadata_read <metadata-file>` prints normalized fields for a valid record.
- `sp_metadata_validate_identifier <identifier>` validates ABI identifiers.
- `sp_metadata_validate_source_side_effect <side_effect>` rejects phase-unsafe
  classes before ordinary startup can source a module body.

The executable contract is `tests/loader/metadata-abi.test.sh`.
