# Shared modules: governance and index

This policy covers the shared modules shipped here and the requirements for
provider repositories. It defines the layer namespace, what belongs in a
layer, review expectations, and how modules are indexed, deprecated, and
removed.

## Namespace and ownership

The loader enforces the layer namespace. This policy assigns ownership and
review responsibility.

- Layer-only modules must use the `contrib_` prefix. The loader rejects
  other layer-only names (see [module-abi.md](module-abi.md)).
- Module names are owned by the tree that ships them. The engine
  repository owns every module under its `module.d/`. A provider
  repository owns every module in its layer tree.
- A module with the same name in multiple roots must have matching metadata
  and body bytes. Different bytes or different `version=` values make the
  load fail with a diagnostic naming the providers. Identical copies resolve
  by root priority; providers should still agree on which tree owns the name.
- A provider repository that wants its modules consumed must document them
  in an index of its own, following this document's shape (name, version,
  exports, source, status). Consumers read the provider's index to
  discover what exists; they read this index to discover what the engine
  ships.

### Use an owner segment

The `contrib_` prefix is the only part the tools enforce. Nothing
mechanically distinguishes one provider from another, so two providers that
both ship `contrib_path_utils` fail closed against each other with a
same-name conflict, and neither can be swapped for the other.

**Use a provider segment after the prefix: `contrib_<owner>_<thing>`.**

```
contrib_acme_widget_setup
contrib_acme_widget_apply
contrib_globex_path_helpers
```

This is a recommendation, not a rule the tools check, but it is what keeps
two providers from colliding. A layer should use one owner segment
consistently across all of its modules, so a consumer can see at a glance
which provider owns what.

If you must ship a module whose name another provider might already use,
prefix it with your owner segment anyway — a name collision between two
vendored providers is otherwise unresolvable without renaming one of them.

## What belongs in a layer

A layer is a vendorable set of modules: something another person can take
unchanged, use, and maintain on their own terms. The practical test is
simple: **could another person vendor this module unchanged and still be
happy with it?**

A layer module must have:

- **No employer material.** No account IDs, hostnames, cloud profiles,
  project names, or anything else tied to one organization.
- **No personal configuration.** No hard-coded home paths, no chosen
  editor, no particular toolchain, model, or theme.
- **No dependency outside the layer**, apart from the engine's own modules.
  A layer module may require an engine module, but it may not require a
  module that lives in the consumer's primary root — that dependency cannot
  be satisfied when someone else vendors the layer.

Everything else stays in the primary root: environment setup, completions,
tool wrappers, work-specific modules, and the aggregators.

`valise layer-lint <layer-name>` enforces the mechanical half of this. It
checks that the layer has a `module.d/` directory, that every metadata file
is a regular file with a safe mode, that every module name carries the
`contrib_` prefix, that the metadata validates as data, that the version is
present, that the load target exists as a regular file, and that every
dependency resolves inside the layer or to an engine module. It needs no
Python.

### 1. Separate generic engines from opinionated presets

A reusable mechanism and the opinionated defaults built on it are different
modules with different audiences, and they belong in different files.

The engine is the part anyone might want. The preset is a list of specific
choices that only some users want. Ship them as two modules so a consumer
can take the engine without the presets.

```
contrib_gitignore_engine   # the matching logic
contrib_gitignore_preset   # one opinionated list of paths
```

A consumer who wants their own path list takes the engine and writes their
own preset. A consumer who wants the shipped defaults takes both. If the
engine and the preset were one module, every consumer would be forced to
either accept the opinionated list or fork the whole thing.

### 2. Avoid grab-bag modules

A module's dependencies and `shells=` are the union of its parts. Splitting
one module into several narrow ones lets each part declare only what it
actually needs.

The failure this avoids is concrete: a helper that used `local` was bundled
into a general-purpose utilities module, and because `local` is not POSIX,
that one function excluded ksh for **every** function in the module. The
module's `shells=` list had to be the union, so one non-portable helper
cost the whole module its ksh support.

Split instead:

```
contrib_owner_cli_quote     # POSIX, no dependencies
contrib_owner_cli_local     # needs a non-POSIX shell
```

Now the first module keeps `shells=sh bash zsh ksh` and the second declares
what it actually needs. The same rule applies to dependencies: a module that
pulls in a heavy dependency should be separate from one that does not.

### 3. Use owner namespaces

Covered above: `contrib_<owner>_<thing>`, one segment per provider, used
consistently.

### 4. Runtime capability use is allowed

A layer module **may** call `sp_cap_*` helpers at run time. A compiled plan
sources the capability prelude and leaves it in place, so a function the
module defines can call `sp_cap_os`, `sp_cap_cpu_count`, or any other helper
long after the profile finished loading. The loader behaves the same way.

This is a change from earlier engine behavior, where the helpers were
removed after loading and a module function that called one broke. If you
have a layer that avoided the helpers to work around that, you can now use
them directly.

Prefer the `sp_cap_*` helpers over open-coding platform-specific commands.
See [contrib-modules.md](contrib-modules.md) for the list.

## Index of engine-shipped shared modules

| Module | Version | Exports | Source | Status |
|---|---|---|---|---|
| `contrib_path` | 1.0.0 | `contrib_path_prepend`, `contrib_path_append` | `modules/system/contrib_path.sh` | active |
| `contrib_editor` | 1.0.0 | `contrib_editor_defaults` | `modules/system/contrib_editor.sh` | active |
| `contrib_pager` | 1.0.0 | `contrib_pager_defaults` | `modules/system/contrib_pager.sh` | active |
| `contrib_xdg` | 1.0.0 | `contrib_xdg_defaults` | `modules/system/contrib_xdg.sh` | active |
| `contrib_history` | 1.0.0 | `contrib_history_defaults` | `modules/system/contrib_history.sh` | active |

The example provider tree in this repository
(`examples/shared/`) additionally ships:

| Module | Version | Exports | Source | Status |
|---|---|---|---|---|
| `contrib_shared_paths` | 1.0.0 | `contrib_shared_paths_setup` | `examples/shared/modules/shared/contrib_shared_paths.sh` | active |
| `contrib_shared_umask` | 1.0.0 | `contrib_shared_umask_secure` | `examples/shared/modules/shared/contrib_shared_umask.sh` | active |

These engine-shipped modules predate the owner-segment recommendation and
keep their existing names; renaming them would break every consumer that
already vendors them. New modules should use the owner-segment form.

Update the index in the same change that adds, renames, deprecates, or
removes a shared module. Provider repositories should maintain a corresponding
index for their own layer modules.

## Review

Every change to a shared module passes the same floor:

1. The engine gate: `make check-fast` during iteration and
   `make VALISE_REQUIRE_TOOLING=1 check` before a release claim (strict
   tooling is automatic when CI sets `CI=true` or `GITHUB_ACTIONS=true`).
   These targets live in the source repository; the npm package ships the
   runtime, the docs, and the examples, not the Makefile.
2. The authoring checklist in
   [contrib-modules.md](contrib-modules.md): metadata validates, the
   module loads strict from a clean environment, behavior is idempotent
   and quiet.
3. For engine modules, review happens in this repository's normal commit
   review. For provider modules, review happens in the provider
   repository; the consumer re-applies judgment at re-pin time by
   reviewing the vendored diff (see the update policy in
   [module-abi.md](module-abi.md)).

Breaking changes to behavior require a `version=` bump so the skew rule
can catch mixed-version compositions.

## Deprecation

A deprecated module keeps shipping unchanged — its bytes stay available
to every consumer that already pinned them — but is marked for eventual
removal:

1. Set the module's status to `deprecated` in this index.
2. Freeze its `version=`: no feature work lands; fixes that cannot wait
   follow the normal re-pin policy with the deprecation still visible.
3. State the replacement (another module, or none) in the index row.

A module stays deprecated for at least one release before it may be
removed, so consumers see the deprecation in a re-pin before the
disappearance. The loader continues to load a deprecated module;
deprecation is a signal to consumers, not a gate.

## Removal

Removing a shared module is a release-visible change:

1. Announce the removal in the same change that performs it (commit
   message naming the module and the last release that contained it).
2. Delete the metadata/body pair and the index row together.
3. Rebuild the manifest and install: the content-derived release ID
   changes, making the switch to a post-removal release an explicit,
   reviewed act.
4. Consumers keep working on their already-installed sealed releases —
   each verifies against its own manifest — and notice the removal at
   their next re-pin, when the module is absent from the diff.
