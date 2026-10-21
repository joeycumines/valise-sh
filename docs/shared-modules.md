# Shared modules: governance and index

This policy covers the shared modules shipped here and the requirements for
provider repositories. It defines the layer namespace, review expectations,
and how modules are indexed, deprecated, and removed.

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

Update the index in the same change that adds, renames, deprecates, or
removes a shared module. Provider repositories should maintain a corresponding
index for their own layer modules.

## Review

Every change to a shared module passes the same floor:

1. The engine gate: `make check-fast` during iteration and
   `make VALISE_REQUIRE_TOOLING=1 check` before a release claim (strict
   tooling is automatic when CI sets `CI=true` or `GITHUB_ACTIONS=true`).
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
