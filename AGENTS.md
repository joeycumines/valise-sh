# AGENTS.md

This repository contains the reusable valise-sh shell-profile engine. Read
[architecture.md](docs/architecture.md) for scope and
[module-abi.md](docs/module-abi.md) before changing metadata or loader behavior.

- Keep project-specific modules, providers, wrappers, and release policy in the
  consuming project.
- Metadata is data: do not source it to discover modules or dependencies.
- Preserve deterministic dependency loading, export checks, failure cleanup,
  and the declared POSIX/Fish parser boundaries.
- Use `sp_cap_*` helpers for portable platform operations.
- Run tests with their controlled environment. Never source or modify a live
  user profile as part of testing.
- Run the narrowest relevant target, then `make check`. Missing extended
  runtimes skip locally; CI requires them. See the README for overrides.

## Reference

- [Installation and releases](docs/installation.md)
- [Module ABI](docs/module-abi.md)
- [Architecture and scope](docs/architecture.md)
- [Module authoring](docs/contrib-modules.md)
- [Shared-module policy](docs/shared-modules.md)
- [Release policy](docs/release-policy.md)
- [Changelog](CHANGELOG.md)
