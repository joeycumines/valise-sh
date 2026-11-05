# Optional machine-local overrides (intentionally git-ignored). GNU Make's
# command-line assignments still take precedence over config.mk and defaults.
-include config.mk

# Missing extended runtimes are skips for local development, but failures in
# CI. Override explicitly with `make VALISE_REQUIRE_TOOLING=1 check` (or =0).
# Supports GitHub Actions and generic CI=true environments.
CI ?= false
VALISE_REQUIRE_TOOLING ?= $(if $(filter true TRUE 1 yes YES,$(CI) $(GITHUB_ACTIONS)),1,0)
comma := ,
VALISE_REQUIRED_PARSERS ?= $(if $(filter 1,$(VALISE_REQUIRE_TOOLING)),sh$(comma)dash$(comma)ksh$(comma)busybox-ash$(comma)bash$(comma)fish,)

VALISE_CLI_LIBS := $(wildcard lib/cli/*.sh)

.PHONY: check syntax test test-runner-quarantine test-parser-support test-metadata-abi test-loader-failure-modes test-loader-process-count test-detection-contract test-detection-contract-busybox test-loader-multi-root test-loader-multi-root-lanes test-entrypoint-runtime test-capabilities test-contrib-modules test-non-macos-runtime test-cli-posix test-cli-gaps test-compile-assemble test-compiler-plan test-registry test-project-ux test-project-layout test-compiler-benchmark benchmark-timing test-fish-syntax test-fish-runtime test-integration test-install test-update test-docs check-fast test-doc-links test-e2e test-consumer-profile clean distclean
.NOTPARALLEL: check test

TEST_ENV_PATH = /usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
TEST_RUNNER = PATH="$(TEST_ENV_PATH)"; _tmp_home=$$(/usr/bin/mktemp -d /tmp/shell-profile-engine-test-home.XXXXXX) && /usr/bin/env -i HOME="$$_tmp_home" TMPDIR=/tmp PATH="$(TEST_ENV_PATH)" VALISE_CONSUMER_PROFILE="$${VALISE_CONSUMER_PROFILE:-}" VALISE_TEST_FORBIDDEN_HOME="$${VALISE_TEST_FORBIDDEN_HOME:-}" VALISE_REQUIRED_PARSERS="$(VALISE_REQUIRED_PARSERS)" MACOS_PROFILE_PARSER_SEARCH_PATH="$${MACOS_PROFILE_PARSER_SEARCH_PATH:-}" T07_TEST_CHILD_SHELL="$${T07_TEST_CHILD_SHELL:-/bin/bash}" T07_TEST_CHILD_SHELL_ARGS="$${T07_TEST_CHILD_SHELL_ARGS:-}" T07_TEST_CHILD_PATH="$${T07_TEST_CHILD_PATH:-}" /bin/bash "$<"; _test_status=$$?; /bin/rm -rf "$$_tmp_home"; [ $$_test_status -eq 0 ]
RUNTIME_TEST_RUNNER = PATH="$(TEST_ENV_PATH)"; _tmp_home=$$(/usr/bin/mktemp -d /tmp/shell-profile-engine-test-home.XXXXXX) && /usr/bin/env -i HOME="$$_tmp_home" TMPDIR=/tmp PATH="$(TEST_ENV_PATH)" VALISE_TEST_FORBIDDEN_HOME="$${VALISE_TEST_FORBIDDEN_HOME:-}" VALISE_LINUX_IMAGE="$${VALISE_LINUX_IMAGE:-}" VALISE_BSD_IMAGE="$${VALISE_BSD_IMAGE:-}" VALISE_RUNTIME_SEARCH_PATH="$${VALISE_RUNTIME_SEARCH_PATH:-}" /bin/bash "$<"; _test_status=$$?; /bin/rm -rf "$$_tmp_home"; [ $$_test_status -eq 0 ]

check: syntax test test-fish-syntax test-docs test-detection-contract-busybox test-loader-multi-root-lanes test-e2e

FISH ?= $(shell PATH="$(TEST_ENV_PATH)" command -v fish 2>/dev/null)

test-fish-syntax: lib/fish/loader.fish lib/fish/metadata.fish
	@if test -z "$(FISH)"; then \
		if test "$(VALISE_REQUIRE_TOOLING)" = 1; then \
			echo "FAIL: fish is required for the native Fish syntax check (VALISE_REQUIRE_TOOLING=1)" >&2; exit 1; \
		else echo "SKIP: fish syntax (install fish or set VALISE_REQUIRE_TOOLING=1 to require it)"; exit 0; fi; \
	fi; \
	"$(FISH)" -n lib/fish/loader.fish && \
	"$(FISH)" -n lib/fish/metadata.fish && \
	if test -f entrypoints/fish/profile.fish; then \
		"$(FISH)" -n entrypoints/fish/profile.fish; \
	fi && \
	if test -f ../../shell/entrypoints/fish/profile.fish; then \
		"$(FISH)" -n ../../shell/entrypoints/fish/profile.fish; \
	fi

syntax: test-parser-support

test-parser-support: tests/parser-support.test.sh manifests/parser-support.tsv
	@$(TEST_RUNNER)

test: test-runner-quarantine
	@test -f README.md
	@test -f AGENTS.md
	@test -f docs/architecture.md
	@test -f manifests/parser-support.tsv
	@test -d lib
	@test -d module.d
	@test -d modules
	@test -d entrypoints
	@test -d manifests
	@test -d helpers
	@test -d install
	@test -d examples/local
	@test -d tests/fixtures
	@$(MAKE) test-metadata-abi
	@$(MAKE) test-loader-failure-modes
	@$(MAKE) test-loader-process-count
	@$(MAKE) test-detection-contract
	@$(MAKE) test-loader-multi-root
	@$(MAKE) test-entrypoint-runtime
	@$(MAKE) test-capabilities
	@$(MAKE) test-contrib-modules
	@$(MAKE) test-non-macos-runtime
	@$(MAKE) test-cli-posix
	@$(MAKE) test-cli-gaps
	@$(MAKE) test-compile-assemble
	@$(MAKE) test-compiler-plan
	@$(MAKE) test-registry
	@$(MAKE) test-project-ux
	@$(MAKE) test-project-layout
	@$(MAKE) test-compiler-benchmark
	@$(MAKE) test-fish-runtime
	@$(MAKE) test-consumer-profile
	@$(MAKE) test-doc-links

test-runner-quarantine: tests/test-runner-quarantine.test.sh
	@echo "=== shell-profile test-runner quarantine ==="
	@_probe_dir=$$(/usr/bin/mktemp -d /tmp/shell-profile-engine-bashenv.XXXXXX); \
	_probe="$$_probe_dir/bashenv"; \
	_marker="$$_probe_dir/marker"; \
	_path_marker="$$_probe_dir/path-marker"; \
	_path_poison="$$_probe_dir/path-poison"; \
	_forbidden_home="$$_probe_dir/forbidden-home"; \
	/bin/mkdir -p "$$_path_poison" "$$_forbidden_home/bin"; \
	for _cmd in mktemp env rm bash; do \
		case "$$_cmd" in \
		mktemp) _abs=/usr/bin/mktemp ;; \
		env) _abs=/usr/bin/env ;; \
		rm) _abs=/bin/rm ;; \
		bash) _abs=/bin/bash ;; \
		esac; \
		printf '#!/bin/bash\nprintf "%%s\\n" "$$0" >> "%s"\nexec "%s" "$$@"\n' "$$_path_marker" "$$_abs" >"$$_path_poison/$$_cmd"; \
		/bin/chmod +x "$$_path_poison/$$_cmd"; \
	done; \
	printf 'printf "BASH_ENV_HOME=%s\\n" "$$HOME" > "$$BASH_ENV_MARKER"\n' >"$$_probe"; \
	PATH="$$_path_poison:$$_forbidden_home:$$_forbidden_home/bin:$(TEST_ENV_PATH)" BASH_ENV="$$_probe" BASH_ENV_MARKER="$$_marker" ENV="$$_probe" ZDOTDIR="$$_forbidden_home" HOME="$$_forbidden_home" VALISE_TEST_FORBIDDEN_HOME="$$_forbidden_home" $(TEST_RUNNER); \
	_status=$$?; \
	if [ -e "$$_marker" ]; then \
		echo "FAIL: TEST_RUNNER sourced inherited BASH_ENV before quarantine" >&2; \
		_status=1; \
	fi; \
	if [ -s "$$_path_marker" ]; then \
		echo "FAIL: TEST_RUNNER resolved commands from inherited PATH before quarantine" >&2; \
		_status=1; \
	fi; \
	/bin/rm -rf "$$_probe_dir"; \
	exit $$_status

test-metadata-abi: tests/loader/metadata-abi.test.sh lib/metadata.sh
	@$(TEST_RUNNER)

test-loader-failure-modes: tests/loader/loader-failure-modes.test.sh lib/metadata.sh lib/loader.sh
	@$(TEST_RUNNER)

test-loader-process-count: tests/loader/process-count.test.sh lib/metadata.sh lib/loader.sh
	@$(TEST_RUNNER)

test-detection-contract: tests/loader/detection-contract.test.sh lib/metadata.sh lib/loader.sh
	@$(TEST_RUNNER)

# Exercise BusyBox ash when available. Absence is a local skip; strict CI
# (or VALISE_REQUIRE_TOOLING=1) requires the runtime.
VALISE_BUSYBOX_LIMA_INSTANCE ?= valise-busybox
VALISE_BUSYBOX_WORKDIR ?= $(CURDIR)

test-detection-contract-busybox: tests/loader/detection-contract.test.sh lib/metadata.sh lib/loader.sh
	@set -eu; \
	if command -v limactl >/dev/null 2>&1 && \
		limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | \
		grep -F -x '$(VALISE_BUSYBOX_LIMA_INSTANCE) Running' >/dev/null 2>&1; then \
		echo "=== BusyBox detection contract ($(VALISE_BUSYBOX_LIMA_INSTANCE)) ==="; \
		limactl shell '$(VALISE_BUSYBOX_LIMA_INSTANCE)' /usr/bin/env -i \
			HOME=/tmp TMPDIR=/tmp PATH=/usr/bin:/bin /bin/bash -c \
			'command -v busybox >/dev/null 2>&1 || { echo "FAIL: BusyBox is absent inside the pinned executor" >&2; exit 1; }; cd "$(VALISE_BUSYBOX_WORKDIR)" && bash tests/loader/detection-contract.test.sh'; \
	elif command -v busybox >/dev/null 2>&1; then \
		_busybox_dir=$$(dirname "$$(command -v busybox)"); \
		_busybox_home=$$(mktemp -d "$${TMPDIR:-/tmp}/shell-profile-busybox-home.XXXXXX"); \
		trap 'rm -rf "$$_busybox_home"' EXIT INT TERM; \
		/usr/bin/env -i HOME="$$_busybox_home" TMPDIR="$${TMPDIR:-/tmp}" \
		PATH="$$_busybox_dir:$(TEST_ENV_PATH)" \
		MACOS_PROFILE_PARSER_SEARCH_PATH="$$_busybox_dir:$(TEST_ENV_PATH)" \
		/bin/bash tests/loader/detection-contract.test.sh; \
	else \
		if test "$(VALISE_REQUIRE_TOOLING)" = 1; then \
			echo 'FAIL: no BusyBox runtime executor (VALISE_REQUIRE_TOOLING=1); start Lima valise-busybox or install busybox' >&2; exit 1; \
		else echo 'SKIP: BusyBox detection lane (install busybox or start Lima valise-busybox; CI requires it)'; fi; \
	fi

test-loader-multi-root: tests/loader/multi-root.test.sh lib/metadata.sh lib/loader.sh tests/fixtures/modules/loader-failure-modes
	@$(TEST_RUNNER)

# Re-run the multi-root child-loader contract under available POSIX child
# shells beyond its default Bash harness, plus BusyBox ash when available.
# Missing extended runtimes skip locally and fail in strict CI.
test-loader-multi-root-lanes: tests/loader/multi-root.test.sh lib/metadata.sh lib/loader.sh tests/fixtures/modules/loader-failure-modes
	@set -eu; \
	for _shell in /bin/sh /bin/dash /bin/ksh; do \
		if test -x "$$_shell"; then \
			echo "=== loader multi-root child-shell lane: $$_shell ==="; \
			T07_TEST_CHILD_SHELL="$$_shell" $(TEST_RUNNER); \
		elif test "$(VALISE_REQUIRE_TOOLING)" = 1; then \
			echo "FAIL: required POSIX child shell is unavailable: $$_shell (VALISE_REQUIRE_TOOLING=1)" >&2; exit 1; \
		else \
			echo "SKIP: loader child-shell lane $$_shell (install it or set VALISE_REQUIRE_TOOLING=1 to require it)"; \
		fi; \
	done; \
	if command -v limactl >/dev/null 2>&1 && \
		limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | \
		grep -F -x '$(VALISE_BUSYBOX_LIMA_INSTANCE) Running' >/dev/null 2>&1; then \
		echo "=== loader multi-root child-shell lane: BusyBox ash ($(VALISE_BUSYBOX_LIMA_INSTANCE)) ==="; \
		limactl shell '$(VALISE_BUSYBOX_LIMA_INSTANCE)' /usr/bin/env -i \
			HOME=/tmp TMPDIR=/tmp PATH=/usr/bin:/bin /bin/bash -c \
			'set -eu && cd "$(VALISE_BUSYBOX_WORKDIR)" && _busybox_bin=$$(command -v busybox) && _busybox_dir=$$(mktemp -d /tmp/shell-profile-t07-busybox.XXXXXX) && trap "rm -rf \"$$_busybox_dir\"" EXIT INT TERM && for _applet in cat cmp grep mkdir mktemp mv printf pwd rm sed sort uname; do ln -s "$$_busybox_bin" "$$_busybox_dir/$$_applet" || exit 1; done && for _applet in cat cmp grep mkdir mktemp mv printf pwd rm sed sort uname; do test -x "$$_busybox_dir/$$_applet" || exit 1; done && T07_TEST_CHILD_SHELL="$$_busybox_bin" T07_TEST_CHILD_SHELL_ARGS=ash T07_TEST_CHILD_PATH="$$_busybox_dir" bash tests/loader/multi-root.test.sh'; \
	elif command -v busybox >/dev/null 2>&1; then \
		_busybox_bin=$$(command -v busybox); \
		_busybox_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/shell-profile-t07-busybox.XXXXXX"); \
		trap 'rm -rf "$$_busybox_dir"' EXIT INT TERM; \
		for _applet in cat cmp grep mkdir mktemp mv printf pwd rm sed sort uname; do ln -s "$$_busybox_bin" "$$_busybox_dir/$$_applet"; done; \
		for _applet in cat cmp grep mkdir mktemp mv printf pwd rm sed sort uname; do test -x "$$_busybox_dir/$$_applet"; done; \
		T07_TEST_CHILD_SHELL="$$_busybox_bin" T07_TEST_CHILD_SHELL_ARGS=ash T07_TEST_CHILD_PATH="$$_busybox_dir" $(TEST_RUNNER); \
	else \
		if test "$(VALISE_REQUIRE_TOOLING)" = 1; then \
			echo 'FAIL: no BusyBox ash executor for T07 multi-root lane (VALISE_REQUIRE_TOOLING=1); start Lima valise-busybox or install busybox' >&2; exit 1; \
		else echo 'SKIP: BusyBox ash multi-root lane (install busybox or start Lima valise-busybox; CI requires it)'; fi; \
	fi

test-entrypoint-runtime: tests/entrypoint-runtime.test.sh entrypoints/profile.sh lib/metadata.sh lib/capabilities.sh lib/loader.sh
	@$(TEST_RUNNER)

test-capabilities: tests/capabilities.test.sh lib/capabilities.sh entrypoints/profile.sh
	@$(TEST_RUNNER)

test-contrib-modules: tests/contrib-modules.test.sh entrypoints/profile.sh lib/metadata.sh lib/capabilities.sh lib/loader.sh module.d/valise_path.meta module.d/valise_editor.meta module.d/valise_pager.meta module.d/valise_xdg.meta module.d/valise_history.meta modules/system/valise_path.sh modules/system/valise_editor.sh modules/system/valise_pager.sh modules/system/valise_xdg.sh modules/system/valise_history.sh
	@$(TEST_RUNNER)

test-non-macos-runtime: tests/non-macos-runtime.test.sh manifests/parser-support.tsv entrypoints/profile.sh lib/capabilities.sh lib/metadata.sh lib/loader.sh module.d/valise_platform_posix.meta module.d/valise_platform_linux.meta module.d/valise_platform_bsd.meta modules/platform/posix.sh modules/platform/linux/capabilities.sh modules/platform/bsd/capabilities.sh
	@$(RUNTIME_TEST_RUNNER)

test-cli-posix: tests/cli-posix.test.sh bin/valise $(VALISE_CLI_LIBS)
	@$(TEST_RUNNER)

test-cli-gaps: tests/cli-gaps.test.sh bin/valise $(VALISE_CLI_LIBS)
	@$(TEST_RUNNER)

test-compile-assemble: tests/compile-assemble.test.sh bin/valise $(VALISE_CLI_LIBS) lib/compiler.awk lib/capabilities.sh
	@$(TEST_RUNNER)

test-compiler-plan: tests/compiler-plan.test.sh bin/valise $(VALISE_CLI_LIBS) lib/compiler.awk lib/capabilities.sh
	@$(TEST_RUNNER)

test-registry: tests/registry.test.sh bin/valise $(VALISE_CLI_LIBS) lib/metadata.sh lib/compiler.awk lib/capabilities.sh
	@$(TEST_RUNNER)

test-project-ux: tests/project-ux.test.sh bin/valise $(VALISE_CLI_LIBS) lib/metadata.sh lib/compiler.awk lib/capabilities.sh
	@$(TEST_RUNNER)

test-project-layout: tests/project-layout.test.sh bin/valise $(VALISE_CLI_LIBS) lib/metadata.sh lib/compiler.awk lib/capabilities.sh
	@$(TEST_RUNNER)

test-compiler-benchmark: tests/compiler-benchmark.test.sh lib/compiler.awk
	@$(TEST_RUNNER)

# Manual diagnosis only: measures wall-clock compiler time and is deliberately
# outside `check` and `test`, because elapsed time reports on host load rather
# than on the compiler. Nothing depends on this target's result.
benchmark-timing: tools/compiler-benchmark-timing.sh lib/compiler.awk
	@echo "=== manual compiler timing diagnosis (non-gating) ==="
	@PATH="$(TEST_ENV_PATH)"; export PATH; sh tools/compiler-benchmark-timing.sh $(MODULES)

test-fish-runtime: tests/fish-runtime.test.sh lib/fish/loader.fish lib/fish/metadata.fish
	@if test -z "$(FISH)"; then \
		if test "$(VALISE_REQUIRE_TOOLING)" = 1; then \
			echo "FAIL: fish is required for the native Fish runtime check (VALISE_REQUIRE_TOOLING=1)" >&2; exit 1; \
		else echo "SKIP: fish runtime (install fish or set VALISE_REQUIRE_TOOLING=1 to require it)"; exit 0; fi; \
	fi; \
	$(TEST_RUNNER)

test-integration test-install test-update: test

test-docs:
	@test -s docs/architecture.md
	@test -s docs/module-abi.md
	@test -s manifests/parser-support.tsv

test-doc-links: tests/docs/doc-links.test.sh README.md AGENTS.md $(wildcard docs/*.md) ## Verify every markdown doc link resolves with exact filename casing.
	@echo "=== shell-profile doc-link case-sensitivity ==="
	@$(TEST_RUNNER)

test-e2e: tests/e2e.test.sh bin/valise $(VALISE_CLI_LIBS) examples/e2e/build-manifest.sh
	@echo "=== valise end-to-end test ==="
	@VALISE_REQUIRE_TOOLING="$(VALISE_REQUIRE_TOOLING)" /bin/bash tests/e2e.test.sh

# VALISE_CONSUMER_PROFILE names a real consumer project (a directory with
# valise.conf). The suite copies it to a temporary directory and works only
# on the copy, so the original tree and the live profile are never touched.
# It skips with a visible message when the variable is unset.
VALISE_CONSUMER_PROFILE ?=
test-consumer-profile: tests/consumer-profile.test.sh bin/valise $(VALISE_CLI_LIBS) lib/compiler.awk lib/capabilities.sh
	@echo "=== valise consumer-profile end-to-end test ==="
	@VALISE_CONSUMER_PROFILE="$(VALISE_CONSUMER_PROFILE)" $(TEST_RUNNER)

clean: ## Delete build products, temporary release trees, and pack tarballs.
	@rm -rf examples/e2e/build examples/profile-project/build *.tgz .valise-* scratch/.valise-* scratch/valise-*

distclean: clean ## Delete all generated files and local build directories.
	@rm -rf build

check-fast: test-runner-quarantine test-parser-support test-metadata-abi test-loader-failure-modes test-loader-process-count test-detection-contract test-loader-multi-root test-entrypoint-runtime test-compiler-plan test-registry test-project-ux test-project-layout test-cli-gaps test-contrib-modules test-consumer-profile test-docs test-doc-links
