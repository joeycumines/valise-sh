#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Cross-platform end-to-end test for the valise-sh engine.
# Exercises the examples/e2e scenario: build manifest, valise install into
# a quarantined HOME, valise release verify, source the deployed snippet in
# the target shell, verify module exports are available, run install a
# second time and verify idempotency. A host-only tamper lane then proves
# the seal end to end: a tampered release file must be rejected by
# release verify inside this suite, not only in CLI unit tests. A host-only
# composition lane then proves the cross-repo contract: the composed
# release (primary tree plus the pinned shared layer) installs, verifies,
# and loads through VALISE_MODULE_PATH.
#
# Lanes (each runs every shell available in that environment):
#   Host (macOS): sh, bash, zsh, ksh, dash, fish
#   Lima valise-linux-full: sh, bash, zsh, ksh, dash, fish
#   Lima valise-busybox: ash (via busybox)
#   Lima valise-bsd-test: sh, bash, ksh (skipped if instance absent/stopped)

set -u

_pass=0
_fail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); _total=$((_total + 1)); }
fail() { printf '  FAIL: %s\n' "$1" >&2; _fail=$((_fail + 1)); _total=$((_total + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); _total=$((_total + 1)); }

tooling_required() {
  for _e2e_flag in "${VALISE_REQUIRE_TOOLING:-}" "${CI:-}" "${GITHUB_ACTIONS:-}"; do
    case "$_e2e_flag" in
      1|true|TRUE|yes|YES) return 0 ;;
    esac
  done
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
E2E_ROOT="$REPO_ROOT/examples/e2e"
E2E_RELEASE="$E2E_ROOT/build/release"
VALISE="$REPO_ROOT/bin/valise"

# The engine's Fish surface rejects double-slash paths (fail-closed
# canonical-path rule). macOS TMPDIR ends with a slash, so a plain
# "${TMPDIR}/x" template would place every quarantined home behind a
# '//' component. Strip the trailing slash, like the fish-runtime suite.
_e2e_tmpdir=${TMPDIR:-/tmp}
case $_e2e_tmpdir in
  /) ;;
  *) _e2e_tmpdir=${_e2e_tmpdir%/} ;;
esac

# --- Shared POSIX lane body ---
# Arguments: lane_label shell_name shell_binary_path install_runner source_runner
# install_runner: a shell function invoked as `install_runner <cwd> <SHELL> <valise> <env_prefix>`
# source_runner:  invoked as `source_runner <tmp_home> <shell_path> <module_list>`
#
# To keep the harness portable, each lane provides its own runner functions
# that know how to enter the target environment (direct, or limactl shell).

run_lane() {
  _lane=$1
  _shell_name=$2
  _shell_path=$3

  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e.XXXXXX") || {
    skip "$_lane/$_shell_name: cannot create temp home"
    return 0
  }

  # Use env to run commands under a controlled environment. env natively
  # handles VAR=val command syntax, so paths containing single quotes,
  # double quotes, backticks, or dollar signs (e.g. from corporate managed
  # TMPDIR) are passed safely without any escaping concern.
  _env_path="$REPO_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  _run_in_e2e_env() {
    env HOME="$_tmp_home" \
        XDG_DATA_HOME="$_tmp_home/.local/share" \
        XDG_CONFIG_HOME="$_tmp_home/.config" \
        XDG_STATE_HOME="$_tmp_home/.local/state" \
        PATH="$_env_path" \
        "$@"
  }

  # Step 1: install (must run from e2e release root where the manifest lives)
  (cd "$E2E_RELEASE" && _run_in_e2e_env SHELL="$_shell_path" "$VALISE" install) >"$_tmp_home/install1.out" 2>&1
  _install_status=$?
  if [ "$_install_status" -ne 0 ]; then
    fail "$_lane/$_shell_name: valise install failed (exit $_install_status)"
    cat "$_tmp_home/install1.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi
  if grep -Eq 'installing release|already installed' "$_tmp_home/install1.out"; then
    pass "$_lane/$_shell_name: valise install succeeds"
  else
    fail "$_lane/$_shell_name: valise install unexpected output"
    cat "$_tmp_home/install1.out" >&2
  fi

  # Step 2: release verify
  _run_in_e2e_env "$VALISE" release verify >"$_tmp_home/verify.out" 2>&1
  if [ $? -eq 0 ]; then
    pass "$_lane/$_shell_name: valise release verify passes"
  else
    fail "$_lane/$_shell_name: valise release verify failed"
    cat "$_tmp_home/verify.out" >&2
  fi

  # Step 3: source the deployed snippet in the target shell with modules set
  case "$_shell_name" in
    fish) _module_list="e2e_fish_features" ;;
    bash) _module_list="e2e_env_setup e2e_aliases e2e_completions_bash e2e_generated_config e2e_optional_network" ;;
    zsh)  _module_list="e2e_env_setup e2e_aliases e2e_completions_zsh e2e_generated_config e2e_optional_network" ;;
    ksh)  _module_list="e2e_env_setup e2e_ksh_features e2e_generated_config e2e_optional_network" ;;
    *)    _module_list="e2e_env_setup e2e_generated_config e2e_optional_network" ;;
  esac

  # Resolve the deployed snippet path for this shell.
  # Plain sh, dash and ash have no plan and use the same ~/.profile block.
  _snippet=""
  _expect_snippet=1
  case "$_shell_name" in
    bash) _snippet="$_tmp_home/.bashrc" ;;
    zsh)  _snippet="$_tmp_home/.zshrc" ;;
    ksh)  _snippet="$_tmp_home/.profile" ;;
    fish) _snippet="$_tmp_home/.config/fish/conf.d/valise.fish" ;;
    *)    _expect_snippet=0 ;;
  esac

  if [ "$_expect_snippet" -eq 1 ]; then
    if [ ! -f "$_snippet" ]; then
      fail "$_lane/$_shell_name: shell integration snippet missing: $_snippet"
    else
      pass "$_lane/$_shell_name: shell integration snippet deployed"
    fi
  fi

  # Source the deployed snippet with modules set, then verify a key export.
  # Each shell invocation is a fresh non-login non-interactive child; for
  # POSIX shells we source the deployed snippet directly. For Fish we source
  # the conf.d hook. We verify exactly one expected function exists.
  # Skip module loading test for shells that don't get snippet deployment.
  if [ "$_expect_snippet" -eq 0 ]; then
    skip "$_lane/$_shell_name: no snippet deployed, skip module loading test"
  elif [ "$_shell_name" = "fish" ]; then
    # The deployed Fish hook authenticates the active release, sources the
    # release's entrypoints/fish/profile.fish adapter, and loads the
    # requested modules through the native Fish loader. Fish auto-sources
    # conf.d snippets on startup, so the child shell exercises the real
    # deployment path with no manual sourcing.
    HOME="$_tmp_home" \
      XDG_DATA_HOME="$_tmp_home/.local/share" \
      XDG_CONFIG_HOME="$_tmp_home/.config" \
      XDG_STATE_HOME="$_tmp_home/.local/state" \
      VALISE_MODULES="$_module_list" \
      VALISE_MODE=strict \
      "$_shell_path" -c 'builtin functions -q e2e_fish_loaded; and builtin test "$VALISE_FISH_READY" = 1; and builtin test "$E2E_FISH_LOADED" = "true"; and exit 0; exit 1' >"$_tmp_home/fish-source.out" 2>&1
    if [ $? -eq 0 ]; then
      pass "$_lane/$_shell_name: deployed Fish hook loads modules through the sealed release"
    else
      fail "$_lane/$_shell_name: deployed Fish hook failed to load modules"
      cat "$_tmp_home/fish-source.out" >&2
    fi
    # Failure path: an invalid mode must fail closed through the deployed
    # hook — no readiness marker and no module export may survive.
    HOME="$_tmp_home" \
      XDG_DATA_HOME="$_tmp_home/.local/share" \
      XDG_CONFIG_HOME="$_tmp_home/.config" \
      XDG_STATE_HOME="$_tmp_home/.local/state" \
      VALISE_MODULES="$_module_list" \
      VALISE_MODE=not-a-real-mode \
      "$_shell_path" -c 'builtin set -q VALISE_FISH_READY; and exit 1; builtin functions -q e2e_fish_loaded; and exit 1; exit 0' >"$_tmp_home/fish-fail.out" 2>&1
    if [ $? -eq 0 ]; then
      pass "$_lane/$_shell_name: failed Fish activation leaves no readiness marker"
    else
      fail "$_lane/$_shell_name: failed Fish activation leaked readiness"
      cat "$_tmp_home/fish-fail.out" >&2
    fi
  else
    # Pass the snippet path via the environment rather than embedding it in
    # the -c string: _snippet derives from ${TMPDIR:-/tmp}, which may contain
    # a single quote that would break single-quote embedding.
    HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" \
      VALISE_MODULES="$_module_list" VALISE_MODE=strict \
      _E2E_SNIPPET_PATH="$_snippet" \
      "$_shell_path" -c '. "$_E2E_SNIPPET_PATH" >/dev/null 2>&1; type e2e_env_ready' >"$_tmp_home/source.out" 2>&1
    if [ $? -eq 0 ] && grep -qE 'function|is a (shell )?function' "$_tmp_home/source.out"; then
      pass "$_lane/$_shell_name: deployed snippet loads modules"
    else
      fail "$_lane/$_shell_name: deployed snippet failed to expose e2e_env_ready"
      cat "$_tmp_home/source.out" >&2
    fi
  fi

  # Step 4: second install is idempotent
  (cd "$E2E_RELEASE" && _run_in_e2e_env SHELL="$_shell_path" "$VALISE" install) >"$_tmp_home/install2.out" 2>&1 || true
  if grep -q 'already installed' "$_tmp_home/install2.out"; then
    pass "$_lane/$_shell_name: second install is idempotent"
  elif grep -q 'installing release' "$_tmp_home/install2.out"; then
    fail "$_lane/$_shell_name: second install re-installed (not idempotent)"
  else
    fail "$_lane/$_shell_name: second install unexpected output"
  fi

  _cleanup_home "$_tmp_home"
  # POSIX sh has no local function scope; clean up the helper to avoid
  # leaking it into the caller's namespace.
  unset -f _run_in_e2e_env 2>/dev/null || :
}

_cleanup_home() {
  # Releases are sealed 0444/0555; restore write before rm.
  chmod -R u+w "$1" 2>/dev/null || :
  rm -rf "$1" 2>/dev/null || :
}

# --- Host lanes ---
run_host_lane() {
  _shell_name=$1
  _shell_path=$(command -v "$_shell_name" 2>/dev/null || echo "")
  if [ -z "$_shell_path" ]; then
    if tooling_required; then
      fail "host/$_shell_name: required shell is not available"
    else
      skip "host/$_shell_name: shell not available"
    fi
    return 0
  fi
  run_lane "host" "$_shell_name" "$_shell_path"
}

# --- Lima lanes ---
run_lima_lane() {
  _instance=$1
  _shell_name=$2
  _shell_path=$3

  if ! command -v limactl >/dev/null 2>&1; then
    skip "lima/$_instance/$_shell_name: limactl not available"
    return 0
  fi

  _status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$_instance" '$1 == n { print $2 }')
  if [ -z "$_status" ]; then
    skip "lima/$_instance/$_shell_name: instance not found"
    return 0
  fi
  if [ "$_status" = "Stopped" ]; then
    printf '  Starting Lima instance %s (timeout 120s)...\n' "$_instance" >&2
    # Start with a timeout so we don't block the whole suite on a slow VM.
    # Run limactl directly (not inside a subshell wrapper) so $! is the
    # actual limactl PID — killing it kills limactl, not a reparented child
    # that would leak and hold the VM lock.
    limactl start "$_instance" >/dev/null 2>&1 &
    _limactl_pid=$!
    _waited=0
    while kill -0 "$_limactl_pid" 2>/dev/null && [ "$_waited" -lt 120 ]; do
      sleep 2
      _waited=$((_waited + 2))
    done
    if kill -0 "$_limactl_pid" 2>/dev/null; then
      kill "$_limactl_pid" 2>/dev/null || :
      wait "$_limactl_pid" 2>/dev/null || true
      skip "lima/$_instance/$_shell_name: start timed out"
      return 0
    fi
    wait "$_limactl_pid" 2>/dev/null || true
    _status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$_instance" '$1 == n { print $2 }')
  fi
  if [ "$_status" != "Running" ]; then
    skip "lima/$_instance/$_shell_name: instance is $_status"
    return 0
  fi

  # Verify shell exists inside
  if ! limactl shell "$_instance" command -v "$_shell_name" >/dev/null 2>&1; then
    skip "lima/$_instance/$_shell_name: shell not available inside"
    return 0
  fi

  # Run the whole lane body inside the VM via a single ssh invocation.
  # Inline the lane body as a heredoc passed to /bin/sh inside.
  # Determine the expected snippet path on the host side so we can pass it in.
  _lima_snippet=""
  _lima_expect_snippet=1
  case "$_shell_name" in
    bash) _lima_snippet=".bashrc" ;;
    zsh)  _lima_snippet=".zshrc" ;;
    ksh)  _lima_snippet=".profile" ;;
    fish) _lima_snippet=".config/fish/conf.d/valise.fish" ;;
    *)    _lima_expect_snippet=0 ;;
  esac

  _lima_out=$(limactl shell "$_instance" /bin/sh -s <<LIMA_EOF
set -u
_tmp_home=\$(mktemp -d /tmp/valise-e2e.XXXXXX) || exit 2
_valise="$REPO_ROOT/bin/valise"
_e2e="$REPO_ROOT/examples/e2e/build/release"
_snippet_path="\$_tmp_home/$_lima_snippet"

# Install (manifest is pre-generated on host for read-only VM mounts like BSD)
cd "\$_e2e" && HOME="\$_tmp_home" XDG_DATA_HOME="\$_tmp_home/.local/share" XDG_CONFIG_HOME="\$_tmp_home/.config" XDG_STATE_HOME="\$_tmp_home/.local/state" PATH="$REPO_ROOT/bin:/usr/local/bin:/usr/bin:/bin" SHELL="$_shell_path" "\$_valise" install >"\$_tmp_home/install1.out" 2>&1
if [ \$? -eq 0 ] && grep -Eq 'installing release|already installed' "\$_tmp_home/install1.out"; then
  printf 'INSTALL_OK\n'
else
  printf 'INSTALL_FAIL\n'
  cat "\$_tmp_home/install1.out"
fi

# Release verify
HOME="\$_tmp_home" XDG_DATA_HOME="\$_tmp_home/.local/share" XDG_CONFIG_HOME="\$_tmp_home/.config" XDG_STATE_HOME="\$_tmp_home/.local/state" PATH="$REPO_ROOT/bin:/usr/local/bin:/usr/bin:/bin" "\$_valise" release verify >/dev/null 2>&1
if [ \$? -eq 0 ]; then printf 'VERIFY_OK\n'; else printf 'VERIFY_FAIL\n'; fi

# Check snippet deployed
if [ -f "\$_snippet_path" ]; then printf 'SNIPPET_OK\n'; else printf 'SNIPPET_FAIL\n'; fi

# Idempotency
cd "\$_e2e" && HOME="\$_tmp_home" XDG_DATA_HOME="\$_tmp_home/.local/share" XDG_CONFIG_HOME="\$_tmp_home/.config" XDG_STATE_HOME="\$_tmp_home/.local/state" PATH="$REPO_ROOT/bin:/usr/local/bin:/usr/bin:/bin" SHELL="$_shell_path" "\$_valise" install >"\$_tmp_home/install2.out" 2>&1 || true
if grep -q 'already installed' "\$_tmp_home/install2.out"; then
  printf 'IDEMPOTENT_OK\n'
elif grep -q 'installing release' "\$_tmp_home/install2.out"; then
  printf 'IDEMPOTENT_REINSTALL\n'
else
  printf 'IDEMPOTENT_OTHER\n'
fi

chmod -R u+w "\$_tmp_home" 2>/dev/null
rm -rf "\$_tmp_home"
LIMA_EOF
  ) || _lima_out="LIMA_INVOKE_FAIL"

  case "$_lima_out" in *INSTALL_OK*)   pass "lima/$_instance/$_shell_name: valise install succeeds" ;;
                     *)              fail "lima/$_instance/$_shell_name: valise install failed" ;; esac
  case "$_lima_out" in *VERIFY_OK*)   pass "lima/$_instance/$_shell_name: valise release verify passes" ;;
                     *)              fail "lima/$_instance/$_shell_name: valise release verify failed" ;; esac
  if [ "$_lima_expect_snippet" -eq 1 ]; then
    case "$_lima_out" in *SNIPPET_OK*)  pass "lima/$_instance/$_shell_name: shell integration deployed" ;;
                       *)              fail "lima/$_instance/$_shell_name: shell integration snippet missing" ;; esac
  else
    skip "lima/$_instance/$_shell_name: no snippet deployed for $_shell_name"
  fi
  case "$_lima_out" in *IDEMPOTENT_OK*) pass "lima/$_instance/$_shell_name: second install idempotent" ;;
                     *IDEMPOTENT_REINSTALL*) fail "lima/$_instance/$_shell_name: second install re-installed (not idempotent)" ;;
                     *)              fail "lima/$_instance/$_shell_name: second install unexpected output" ;; esac
}

# --- Composition lane (host only) ---
# Proves the cross-repo contract end to end: the composed release (primary
# e2e tree plus the pinned shared layer under layer/shared/) installs,
# verifies, and loads through VALISE_MODULE_PATH in every available POSIX
# shell. The entrypoint is sourced directly because deployed login snippets
# only carry the primary root; the layer path is a consumer setting.
run_composition_lane() {
  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e-compose.XXXXXX") || {
    skip "compose: cannot create temp home"
    return 0
  }

  _compose_env() {
    env HOME="$_tmp_home" \
        XDG_DATA_HOME="$_tmp_home/.local/share" \
        XDG_CONFIG_HOME="$_tmp_home/.config" \
        XDG_STATE_HOME="$_tmp_home/.local/state" \
        PATH="$REPO_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
  }

  (cd "$E2E_RELEASE" && _compose_env SHELL=/bin/sh "$VALISE" install) >"$_tmp_home/compose-install.out" 2>&1
  if [ $? -ne 0 ]; then
    fail "compose: valise install failed"
    cat "$_tmp_home/compose-install.out" >&2
    _cleanup_home "$_tmp_home"
    unset -f _compose_env 2>/dev/null || :
    return 0
  fi
  pass "compose: composed release installs"

  _compose_env "$VALISE" release verify >"$_tmp_home/compose-verify.out" 2>&1
  if [ $? -ne 0 ]; then
    fail "compose: valise release verify failed"
    cat "$_tmp_home/compose-verify.out" >&2
    _cleanup_home "$_tmp_home"
    unset -f _compose_env 2>/dev/null || :
    return 0
  fi
  pass "compose: composed release verifies"

  _compose_active=$(cd "$_tmp_home/.config/valise/active" 2>/dev/null && pwd -P) || _compose_active=""
  if [ -z "$_compose_active" ]; then
    fail "compose: cannot resolve active release"
    _cleanup_home "$_tmp_home"
    unset -f _compose_env 2>/dev/null || :
    return 0
  fi
  if [ -f "$_compose_active/layer/shared/layer-pin.txt" ]; then
    pass "compose: layer pin recorded"
  else
    fail "compose: layer pin missing"
  fi

  for _sh in sh bash zsh ksh; do
    _shell_path=$(command -v "$_sh" 2>/dev/null || echo "")
    if [ -z "$_shell_path" ]; then
      skip "compose/$_sh: shell not available"
      continue
    fi
    VALISE_MODULE_ROOT="$_compose_active" \
      VALISE_MODULE_PATH="$_compose_active/layer/shared" \
      VALISE_MODULES='e2e_layer_probe contrib_shared_umask' \
      VALISE_MODE=strict \
      "$_shell_path" -c '. "$VALISE_MODULE_ROOT/entrypoints/profile.sh" || exit 99; e2e_layer_probe_ok; contrib_shared_paths_setup; printf "composed-paths=%s\n" "$PATH"; contrib_shared_umask_secure; printf "composed-umask="; umask' >"$_tmp_home/compose-$_sh.out" 2>"$_tmp_home/compose-$_sh.err"
    if [ $? -ne 0 ]; then
      fail "compose/$_sh: composed load failed"
      cat "$_tmp_home/compose-$_sh.out" "$_tmp_home/compose-$_sh.err" >&2
      continue
    fi
    if grep -q 'layer probe: shared layer resolved' "$_tmp_home/compose-$_sh.out"; then
      pass "compose/$_sh: optional cross-root dependency resolved"
    else
      fail "compose/$_sh: shared layer did not resolve"
    fi
    if grep -q '\.local/bin' "$_tmp_home/compose-$_sh.out"; then
      pass "compose/$_sh: layer module augments PATH"
    else
      fail "compose/$_sh: layer module PATH augmentation missing"
    fi
    if grep -q 'composed-umask=.*077' "$_tmp_home/compose-$_sh.out" && [ ! -s "$_tmp_home/compose-$_sh.err" ]; then
      pass "compose/$_sh: work-only module applies quietly"
    else
      fail "compose/$_sh: work-only module behaved unexpectedly"
    fi
  done

  # Fish leg of the composition: the same composed release must verify and
  # load under Fish. release verify runs from inside the Fish process, and
  # the release's Fish-native module loads through the deployed conf.d
  # hook. The shared layer's modules are POSIX-scoped by their shells=
  # metadata (Fish never sources POSIX bodies); the seal covers the whole
  # composed closure regardless of shell.
  _compose_fish=$(command -v fish 2>/dev/null || echo "")
  if [ -z "$_compose_fish" ]; then
    skip "compose/fish: fish not available"
  else
    HOME="$_tmp_home" \
      XDG_DATA_HOME="$_tmp_home/.local/share" \
      XDG_CONFIG_HOME="$_tmp_home/.config" \
      XDG_STATE_HOME="$_tmp_home/.local/state" \
      PATH="$REPO_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      VALISE_MODULES='e2e_fish_features' \
      VALISE_MODE=strict \
      _COMPOSE_VALISE="$VALISE" \
      "$_compose_fish" -c 'builtin printf "fish-version=%s cd-source=%s\\n" $version (builtin functions --details cd); builtin functions -q e2e_fish_loaded; or exit 1; builtin test "$VALISE_FISH_READY" = 1; or exit 1; "$_COMPOSE_VALISE" release verify >/dev/null 2>&1; or exit 1; exit 0' >"$_tmp_home/compose-fish.out" 2>&1
    if [ $? -eq 0 ]; then
      pass "compose/fish: composed release verifies and loads through Fish"
    else
      fail "compose/fish: composed release failed to verify or load through Fish"
      cat "$_tmp_home/compose-fish.out" >&2
    fi
  fi

  _cleanup_home "$_tmp_home"
  unset -f _compose_env 2>/dev/null || :
}

# --- Tamper lane (host only) ---
# The seal must fail closed inside the end-to-end suite, not only in the
# CLI unit tests: after a real install, flipping one byte of a sealed
# release file must make release verify fail, and restoring the exact
# bytes must make it pass again.
run_tamper_lane() {
  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e-tamper.XXXXXX") || {
    skip "tamper: cannot create temp home"
    return 0
  }

  _tamper_env() {
    env HOME="$_tmp_home" \
        XDG_DATA_HOME="$_tmp_home/.local/share" \
        XDG_CONFIG_HOME="$_tmp_home/.config" \
        XDG_STATE_HOME="$_tmp_home/.local/state" \
        PATH="$REPO_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
  }

  (cd "$E2E_RELEASE" && _tamper_env SHELL=/bin/sh "$VALISE" install) >"$_tmp_home/tamper-install.out" 2>&1
  if [ $? -ne 0 ]; then
    fail "tamper: valise install failed"
    cat "$_tmp_home/tamper-install.out" >&2
    _cleanup_home "$_tmp_home"
    unset -f _tamper_env 2>/dev/null || :
    return 0
  fi
  pass "tamper: release installed"

  _tamper_env "$VALISE" release verify >"$_tmp_home/tamper-verify1.out" 2>&1
  if [ $? -eq 0 ]; then
    pass "tamper: release verify passes on the untampered release"
  else
    fail "tamper: release verify failed before tampering"
    cat "$_tmp_home/tamper-verify1.out" >&2
    _cleanup_home "$_tmp_home"
    unset -f _tamper_env 2>/dev/null || :
    return 0
  fi

  _tamper_active=$(cd "$_tmp_home/.config/valise/active" 2>/dev/null && pwd -P)
  _tamper_file="$_tamper_active/lib/metadata.sh"
  if [ -z "$_tamper_active" ] || [ ! -f "$_tamper_file" ]; then
    fail "tamper: cannot resolve a release file to tamper with"
    _cleanup_home "$_tmp_home"
    unset -f _tamper_env 2>/dev/null || :
    return 0
  fi
  _tamper_save="$_tmp_home/metadata.sh.orig"
  cp -p "$_tamper_file" "$_tamper_save"
  chmod u+w "$_tamper_file"
  printf '%s\n' tampered >>"$_tamper_file"
  chmod u-w "$_tamper_file"
  _tamper_env "$VALISE" release verify >"$_tmp_home/tamper-verify2.out" 2>&1
  if [ $? -ne 0 ]; then
    pass "tamper: release verify rejects the tampered release"
  else
    fail "tamper: release verify accepted a tampered release"
    cat "$_tmp_home/tamper-verify2.out" >&2
  fi

  # Restore the exact sealed bytes and prove the release verifies again,
  # so the lane leaves no poisoned state behind it.
  chmod u+w "$_tamper_file"
  cat "$_tamper_save" >"$_tamper_file"
  chmod 0444 "$_tamper_file"
  _tamper_env "$VALISE" release verify >"$_tmp_home/tamper-verify3.out" 2>&1
  if [ $? -eq 0 ]; then
    pass "tamper: release verify passes after byte restoration"
  else
    fail "tamper: release verify failed after restoring the sealed bytes"
    cat "$_tmp_home/tamper-verify3.out" >&2
  fi

  _cleanup_home "$_tmp_home"
  unset -f _tamper_env 2>/dev/null || :
}

# --- Main ---
printf '=== valise end-to-end test ===\n'
printf '  repo: %s\n' "$REPO_ROOT"
printf '  e2e:  %s\n\n' "$E2E_RELEASE"

# Ensure manifest is current (always rebuild to pick up engine changes)
printf '%s\n' '  Building manifest...'
sh "$E2E_ROOT/build-manifest.sh" "$E2E_RELEASE" >/dev/null 2>&1 || {
  printf '%s\n' 'FAIL: build-manifest.sh failed' >&2
  exit 1
}

printf '%s\n' '--- Host lanes ---'
for _sh in sh bash zsh ksh dash fish; do
  run_host_lane "$_sh"
done

printf '\n%s\n' '--- Tamper lane ---'
run_tamper_lane

printf '\n%s\n' '--- Composition lane ---'
run_composition_lane

printf '\n%s\n' '--- Lima valise-linux-full lanes ---'
for _sh in sh bash zsh ksh dash fish; do
  case "$_sh" in
    sh)   _p=/bin/sh ;;
    bash) _p=/bin/bash ;;
    zsh)  _p=/usr/bin/zsh ;;
    ksh)  _p=/bin/ksh ;;
    dash) _p=/bin/dash ;;
    fish) _p=/usr/bin/fish ;;
  esac
  run_lima_lane "valise-linux-full" "$_sh" "$_p"
done

printf '\n%s\n' '--- Lima valise-busybox lanes ---'
run_lima_lane "valise-busybox" "busybox" "/bin/busybox"

printf '\n%s\n' '--- Lima valise-bsd-test lanes ---'
for _sh in sh bash ksh; do
  case "$_sh" in
    sh)   _p=/bin/sh ;;
    bash) _p=/usr/local/bin/bash ;;
    ksh)  _p=/bin/ksh ;;
  esac
  run_lima_lane "valise-bsd-test" "$_sh" "$_p"
done

printf '\n=== valise end-to-end summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"

[ "$_fail" -eq 0 ]
