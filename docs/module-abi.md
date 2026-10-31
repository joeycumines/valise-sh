# Shell-profile module ABI

This document defines the metadata consumed by the loader before it sources
module bodies. Metadata is data: discovery does not execute module
implementations to learn their names, dependencies, or supported runtimes.

## Metadata file format

Module metadata lives in `module.d/*.meta` as UTF-8 text with one `key=value`
field per line. Blank lines and `#` comments are ignored. Values are plain text;
there is no shell quoting, interpolation, command substitution, glob expansion,
or `eval` phase.

Required fields:

| Field | Meaning |
| --- | --- |
| `name` | Stable module identifier. |
| `shells` | Space-separated supported shell identifiers. |
| `platforms` | Space-separated supported platform identifiers. |
| `side_effect` | Startup/install/update side-effect class. |
| `load` | Repository-relative path to the module body. |
| `requires` | Required when the module is a **meta module** (see below). |

Optional fields:

| Field | Meaning |
| --- | --- |
| `requires` | Space-separated required dependency module identifiers. |
| `optional` | Space-separated optional dependency module identifiers. |
| `exports` | Space-separated exported command/function identifiers. |
| `updates` | Space-separated update identifiers registered by the consuming project. |
| `version` | Optional module version used to reject version skew across roots. |

## Meta modules

A **meta module** declares dependencies and has no body. It is the natural
way to write an aggregator: instead of an empty shell file whose only job is
to name a dependency, the aggregator is metadata alone.

A meta module has `requires=` with at least one entry and **no** `load=`.
The loader and the compiler treat it as a dependency-only
record: the module itself has nothing to source, but its required closure
loads normally and in the right order.

```text
name=profile_main
version=1.0.0
side_effect=read-only
requires=contrib_path contrib_editor
optional=
shells=bash zsh ksh
platforms=any
exports=
updates=
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

Accepted `shells` values are `sh`, `bash`, `zsh`, `ksh`, and `fish`.
`shells=sh` means the module body is POSIX-shell syntax, and it is loaded by
**every POSIX shell** — `sh`, `bash`, `zsh`, `ksh`, and dash — because those
shells all run POSIX syntax. The engine classifies a running shell as `bash`,
`zsh`, or `ksh` when it can prove it, and as `sh` otherwise (dash, BusyBox
ash, and any other POSIX shell); `shells=sh` matches both the `sh` class and
the specific classes, so a `shells=sh` module loads in all of them. Write
portable bodies for `shells=sh` and you cover every POSIX shell at once.

`fish` is the exception: it selects the native Fish surface under
`lib/fish/`, and the Fish loader never sources POSIX shell bodies. A module
whose `shells=` list does not contain `fish` is skipped under Fish rather
than failed — a directly requested module fails closed in strict mode.

The engine ships a generic Fish adapter at `entrypoints/fish/profile.fish` as
the reference implementation of this handshake: it sets
`_sp_fish_loader_bootstrap_mode` and `_sp_fish_loader_bootstrap_seeds`, then sources `loader.fish`. The loader
consumes and clears that request and publishes a fresh
`_sp_fish_loader_bootstrap_status`; callers must fail closed when the marker is
absent. Fish provider precedence is project-native, engine-native, engine
generic, and project generic. Duplicate providers are valid only when their
metadata and native bodies are byte-identical; conflicting metadata or bodies
is rejected before any body is sourced. Public adapters must not execute the
generated Fish plan directly.

Supported `platforms` values are `any`, `darwin`, `linux`, `bsd`, `freebsd`,
`openbsd`, and `netbsd`. `platforms=any` matches every supported platform.
Specific platform values are ORed: `platforms=darwin linux` matches macOS or
Linux, not BSD.

## Multi-root layer search path

The loader resolves modules across a priority-ordered root list. The primary
root is the `sp_loader_load_modules <root> ...` argument and always wins for
metadata it provides. `VALISE_MODULE_PATH` lists additional layer roots as a
colon-separated path, searched in priority order after the primary root.
With it unset the behavior is exactly the historical single-root
behavior.

Semantics, enforced by `tests/loader/multi-root.test.sh`:

- Every search-path element must be a non-empty readable, executable directory; empty
  elements, missing, unreadable, or unsearchable directories are fail-closed
  data errors (element validation runs with globbing disabled, so
  glob-metacharacter elements are not expanded and must name a real readable,
  executable directory). Identical duplicate elements are deduplicated
  at validation; priority belongs to the first occurrence.
- A module name present in multiple roots must have identical metadata and
  body bytes. Identical copies resolve to the highest-priority root; any
  difference is an error naming both paths. A layer cannot silently replace
  a module from the primary root or an earlier layer.
- A module provided only by a layer root must carry the `contrib_` name
  prefix. Non-prefixed layer-only modules fail closed with a diagnostic
  naming the layer.
- Module bodies load from the root that provided the metadata; cross-root
  dependency discovery works in both directions (layer modules may require
  primary modules), and deterministic `sort -u` + topological ordering is
  preserved across roots.
- The duplicate-export fail-closed check is global across roots: a layer
  module may not re-export an identifier already declared by a loaded module.
- No loader-private state leaks after multi-root loads.

## Versioning

Shared modules carry an optional `version` field so independent releases
of the same name can be told apart. The value must start with a digit
and contain only digits, letters, `.`, `_`, `-`; an empty value means
unversioned. Providers should bump the version for a breaking change.
Consumers vendor a specific provider snapshot; the loader does not resolve
version ranges. See [Cross-repo composition](#cross-repo-composition).

Enforcement, in both the POSIX loader and the native Fish loader:

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

## Cross-repo composition

The supported composition is a primary consumer root plus one
version-pinned layer root per provider.
The provider tree is vendored under `layer/<name>/` of the release
(preserving its internal `module.d/` + `modules/` layout), and a single
manifest covers the whole closure, so `release verify` checks consumer
and provider bytes together before anything is sourced.

- Pinning: record the provider source and revision beside the vendored
  bytes (the e2e example writes `layer/shared/layer-pin.txt` from
  `git rev-parse HEAD` at vendor time). Re-pinning means copying the
  provider at a new revision, reviewing the diff, and rebuilding the
  manifest. Pin by git SHA and review the diff; the seal proves the
  release matches its manifest, not who authored it.
- Loading: the consumer sets `VALISE_MODULE_ROOT` to the release and
  `VALISE_MODULE_PATH` to the layer directory inside it. Deployed login
  snippets carry only the primary root; the layer path is a consumer
  setting applied when sourcing the entrypoint.
- Naming: layer-only modules must carry the `contrib_` prefix, and
  same-name modules across roots must be byte-identical or the load
  fails closed naming both paths. Dependencies resolve across the
  boundary in both directions: layer modules may require primary
  modules, and primary modules may follow optional dependencies into
  the layer.

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

`exports` lists public commands or shell functions the module declares. The loader
uses this list for post-load export checks and failure cleanup; project catalogs
and wrapper manifests use it for documentation and registration. An exported name
must be defined by the module body before the module is considered
successfully loaded.

`updates` lists update registrations declared by the module. Each value is an ABI
identifier that maps one-to-one to a row in the project update manifest. The
project validator rejects missing, duplicate, or unowned registrations. URL,
destination, digest, trust policy, and rollback state belong in that manifest;
module metadata states registration only and does not execute update lifecycle work.

## Update channel for shared modules

Shared modules are vendored snapshots. `valise` does not fetch provider
updates. To update a provider, vendor a reviewed revision and rebuild the
release manifest. Bump `version=` when making an incompatible module change;
the loader rejects conflicting versions of the same module across roots.
The manifest detects changes to installed files but does not authenticate
their author; see [installation.md](installation.md). The `updates=` field
is registration for a consuming project's separate update manifest, not an
engine update mechanism.

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

The POSIX entrypoint sources `lib/capabilities.sh` before it calls the loader.
Portable module bodies may therefore depend on `sp_cap_*` helpers without
sourcing OS-specific files themselves. This is the ABI boundary for behavior that
varied in the flat monolith: CPU count, file mtime, temp directories/files, command
lookup, OS detection, canonical path containment, symlink-component rejection,
Homebrew path discovery, secure local-bin permission checks, and background
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
They expose stable module dependencies (`platform_posix`, `platform_macos`,
`platform_linux`, and `platform_bsd`) while keeping compatibility logic in one
library.

## Load target and loader mode

For file-backed modules, `load` is the repository-relative shell file sourced by
the loader after metadata validation, dependency sorting, shell/platform matching,
and phase side-effect checks have passed. The ABI has no unload hook: the loader
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

Failure handling is selected once by the loader caller with
`VALISE_MODE=strict|permissive`; it is not a per-module metadata promise.
Strict mode returns nonzero when a requested module or required dependency fails.
Permissive mode reports the affected module and continues with unrelated modules.

## Path fields

`load` paths are repository-relative implementation paths. Absolute
paths, `..` path segments, spaces, quotes, shell metacharacters, and glob
characters are invalid. Reading metadata must not source these paths.

## Validation implementation

`lib/metadata.sh` provides the current metadata parser and validator:

- `sp_metadata_read <metadata-file>` prints normalized fields for a valid record.
- `sp_metadata_validate_identifier <identifier>` validates ABI identifiers.
- `sp_metadata_validate_source_side_effect <side_effect>` rejects phase-unsafe
  classes before ordinary startup can source a module body.

The executable contract is `tests/loader/metadata-abi.test.sh`.
