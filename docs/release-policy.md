# Release policy

## Current status

`valise-sh` is at **0.1.0**. Before 1.0, the CLI, module ABI, and release
format do not have a backward-compatibility guarantee. Consumers should pin
updates, review release notes, and run their profile's tests before upgrading.

## Compatibility surface

The compatibility contract has three separate parts:

- **CLI:** commands, flags, exit behavior, generated integration snippets,
  install paths, and manifest format.
- **Module ABI:** metadata field names/values, dependency and selection
  semantics, exported function expectations, and POSIX/Fish loader behavior.
- **Release format:** manifest syntax, file/mode constraints, integrity
  verification, and the directory layout expected by deployed hooks.

A change affecting one of these is a compatibility change even if the other
surfaces remain unchanged. Before 1.0, incompatible changes may occur between
minor releases; release notes must identify affected consumers and migration
steps. After 1.0, use semantic versioning: patch for compatible fixes,
minor for backward-compatible features, and major for incompatible changes.

## Release checklist

Before tagging or publishing a release:

1. Update `package.json` and `bin/valise` version together; add a dated entry
   to [CHANGELOG.md](../CHANGELOG.md).
2. Run `make check-fast`, then run `make VALISE_REQUIRE_TOOLING=1 check`
   locally or use the GitHub Actions job. Keep the successful strict run as
   release evidence for every lane, including Fish, zsh, BusyBox, dash, and
   ksh.
3. Run the README isolated quickstart from a clean checkout and verify that
   install, `verify-active`, and example module loading work in the temporary
   home. Confirm cleanup removes the entire demo state.
4. Inspect the result of `npm pack --dry-run` and install/test the packed
   tarball. The CLI's tests currently cover pack contents, installation, and
   module loading.
5. Review the changed CLI, module ABI, release manifest, docs, and examples;
   check `git diff --check` and doc links.
6. Publish only through the chosen distribution channel. The repository
   currently supports source checkout/vendor and local npm tarball
   installation; it does not claim a public npm publication, signed artifact,
   authenticated update service, or provenance attestation.

Do not claim a platform or shell has passed unless its runtime lane actually
ran. An explicit skip is useful development evidence, not release evidence.
