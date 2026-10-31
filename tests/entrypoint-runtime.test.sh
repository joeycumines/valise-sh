#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Runtime smoke tests for the portable entrypoint.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Standalone valise-sh: .git is a directory (real clone) or absent (tarball).
# Vendored submodule inside parent: .git is a file (gitdir pointer).
if [ -d "$ROOT_DIR/.git" ] || [ ! -f "$ROOT_DIR/.git" ]; then
  REPO_ROOT="$ROOT_DIR"
else
  REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
fi
# Compute the engine path relative to REPO_ROOT for the relative-source test.
if [ "$REPO_ROOT" = "$ROOT_DIR" ]; then
  ENGINE_REL_PATH="."
else
  ENGINE_REL_PATH="${ROOT_DIR#"$REPO_ROOT"/}"
fi

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

assert_contains() {
  _total=$((_total + 1))
  _label=$1
  _haystack=$2
  _needle=$3
  case "$_haystack" in
  *"$_needle"*) pass "$_label" ;;
  *) fail "$_label" "missing: $_needle; actual: $_haystack" ;;
  esac
}

assert_eq() {
  _total=$((_total + 1))
  _label=$1
  _expected=$2
  _actual=$3
  if [ "$_expected" = "$_actual" ]; then
    pass "$_label"
  else
    fail "$_label" "expected: $_expected; actual: $_actual"
  fi
}

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-entrypoint.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

printf '\n=== Example module loading ===\n'

_example_out=$(
  cd "$REPO_ROOT" || exit 97
  env -u VALISE_ROOT \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR/examples/local" \
    VALISE_MODULES=hello_valise \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh"; _s=$?; printf "status=%s export=%s\n" "$_s" "$(command -v hello_valise_loaded >/dev/null 2>&1 && printf yes || printf no)"'
)
assert_contains 'example module loads through entrypoint under /bin/sh' "$_example_out" 'status=0'
assert_contains 'example module export is available after load' "$_example_out" 'export=yes'

_example_bash_out=$(
  cd "$REPO_ROOT" || exit 97
  env -u VALISE_ROOT \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR/examples/local" \
    VALISE_MODULES=hello_valise \
    VALISE_MODE=strict \
    /bin/bash -c '. "$VALISE_ROOT/entrypoints/profile.sh"; _s=$?; printf "status=%s export=%s\n" "$_s" "$(command -v hello_valise_loaded >/dev/null 2>&1 && printf yes || printf no)"'
)
assert_contains 'example module loads through entrypoint under bash' "$_example_bash_out" 'status=0'
assert_contains 'example module export is available after bash load' "$_example_bash_out" 'export=yes'

printf '\n=== Entry point runtime contract ===\n'

_success_out=$(
  cd "$REPO_ROOT" || exit 97
  env -u VALISE_ROOT \
    ENGINE_REL_PATH="$ENGINE_REL_PATH" \
    VALISE_MODULE_ROOT="$ROOT_DIR/tests/fixtures/modules/loader-failure-modes" \
    VALISE_MODULES=core \
    VALISE_MODE=strict \
    SP_LOADER_TEST_TRACE="$_tmp/source-by-path.trace" \
    /bin/sh -c '. "$ENGINE_REL_PATH/entrypoints/profile.sh"; _s=$?; printf "status=%s trace=%s root=%s search=%s module_root=%s core_export=%s\n" "$_s" "$(cat "$SP_LOADER_TEST_TRACE" 2>/dev/null)" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}" "$(command -v core_loaded >/dev/null 2>&1 && printf yes || printf no)"'
)
assert_contains 'entrypoint sourced by relative path locates shell-profile root without VALISE_ROOT' "$_success_out" 'status=0'
assert_contains 'entrypoint relative source loads requested module' "$_success_out" 'trace=core'
assert_contains 'entrypoint success cleans private root variable' "$_success_out" 'root=unset'
assert_contains 'entrypoint success cleans private search variable' "$_success_out" 'search=unset'
assert_contains 'entrypoint success cleans private module root variable' "$_success_out" 'module_root=unset'
assert_contains 'entrypoint exposes module-declared public function' "$_success_out" 'core_export=yes'

mkdir -p "$_tmp/hostile-entrypoint-cwd"
: >"$_tmp/hostile-entrypoint-cwd/core"
_entrypoint_glob_err="$_tmp/entrypoint-glob.stderr"
_entrypoint_glob_out=$(
  cd "$_tmp/hostile-entrypoint-cwd" || exit 97
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR/tests/fixtures/modules/loader-failure-modes" \
    VALISE_MODULES='[c]ore' \
    VALISE_MODE=strict \
    SP_LOADER_TEST_TRACE="$_tmp/entrypoint-glob.trace" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    ERR="$_entrypoint_glob_err" \
    /bin/sh -c '. "$ENTRYPOINT" 2>"$ERR"; _s=$?; printf "status=%s trace=%s root=%s search=%s module_root=%s core_export=%s\n" "$_s" "$(cat "$SP_LOADER_TEST_TRACE" 2>/dev/null)" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}" "$(command -v core_loaded >/dev/null 2>&1 && printf yes || printf no)"'
)
_entrypoint_glob_err_out=$(cat "$_entrypoint_glob_err")
assert_eq 'entrypoint rejects globbed requested module in hostile cwd' 'status=1 trace= root=unset search=unset module_root=unset core_export=no' "$_entrypoint_glob_out"
assert_contains 'entrypoint glob rejection diagnostic names wanted module' "$_entrypoint_glob_err_out" 'invalid wanted module'

_outside_root="$_tmp/outside-root"
mkdir -p "$_outside_root"
_outside_root_out=$(
  CWD="$_outside_root" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c 'cd "$CWD" || exit 97; . "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s sp_status=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}" "${_sp_status-unset}"'
)
assert_eq 'entrypoint root-not-found failure cleans all private variables' 'status=1 root=unset search=unset module_root=unset sp_status=unset' "$_outside_root_out"

_deleted_cwd="$_tmp/deleted-cwd"
mkdir -p "$_deleted_cwd"
_deleted_cwd_out=$(
  BAD_CWD="$_deleted_cwd" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c 'cd "$BAD_CWD" || exit 97; rmdir "$BAD_CWD" || exit 98; . "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_eq 'entrypoint failed cwd root inference cleans private variables' 'status=1 root=unset search=unset module_root=unset' "$_deleted_cwd_out"

_failure_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULES=missing_module \
    VALISE_MODE=strict \
    SP_LOADER_TEST_TRACE="$_tmp/strict-failure.trace" \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint strict loader failure propagates nonzero status' "$_failure_out" 'status=1'
assert_contains 'entrypoint failure cleans private root variable' "$_failure_out" 'root=unset'
assert_contains 'entrypoint failure cleans private search variable' "$_failure_out" 'search=unset'
assert_contains 'entrypoint failure cleans private module root variable' "$_failure_out" 'module_root=unset'

mkdir -p "$_tmp/failing-metadata/lib" "$_tmp/failing-loader/lib" "$_tmp/missing-capabilities/lib"
mkdir -p "$_tmp/missing-metadata/lib" "$_tmp/missing-loader/lib"
printf '%s\n' 'return 1' >"$_tmp/failing-metadata/lib/metadata.sh"
printf '%s\n' 'return 0' >"$_tmp/failing-metadata/lib/loader.sh"
printf '%s\n' 'return 0' >"$_tmp/failing-loader/lib/metadata.sh"
printf '%s\n' 'return 0' >"$_tmp/failing-loader/lib/capabilities.sh"
printf '%s\n' 'return 1' >"$_tmp/failing-loader/lib/loader.sh"
printf '%s\n' 'return 0' >"$_tmp/missing-capabilities/lib/metadata.sh"
printf '%s\n' 'return 0' >"$_tmp/missing-capabilities/lib/loader.sh"
printf '%s\n' 'return 0' >"$_tmp/missing-loader/lib/metadata.sh"
printf '%s\n' 'return 0' >"$_tmp/missing-loader/lib/capabilities.sh"

_missing_metadata_out=$(
  VALISE_ROOT="$_tmp/missing-metadata" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c '. "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint missing metadata library returns controlled failure' "$_missing_metadata_out" 'status=1'
assert_contains 'entrypoint missing metadata library cleans private root variable' "$_missing_metadata_out" 'root=unset'
assert_contains 'entrypoint missing metadata library cleans private search variable' "$_missing_metadata_out" 'search=unset'
assert_contains 'entrypoint missing metadata library cleans private module root variable' "$_missing_metadata_out" 'module_root=unset'

_missing_capabilities_out=$(
  VALISE_ROOT="$_tmp/missing-capabilities" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c '. "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint missing capability library returns controlled failure' "$_missing_capabilities_out" 'status=1'
assert_contains 'entrypoint missing capability library cleans private root variable' "$_missing_capabilities_out" 'root=unset'
assert_contains 'entrypoint missing capability library cleans private search variable' "$_missing_capabilities_out" 'search=unset'
assert_contains 'entrypoint missing capability library cleans private module root variable' "$_missing_capabilities_out" 'module_root=unset'

_missing_loader_out=$(
  VALISE_ROOT="$_tmp/missing-loader" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c '. "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint missing loader library returns controlled failure' "$_missing_loader_out" 'status=1'
assert_contains 'entrypoint missing loader library cleans private root variable' "$_missing_loader_out" 'root=unset'
assert_contains 'entrypoint missing loader library cleans private search variable' "$_missing_loader_out" 'search=unset'
assert_contains 'entrypoint missing loader library cleans private module root variable' "$_missing_loader_out" 'module_root=unset'

_metadata_failure_out=$(
  VALISE_ROOT="$_tmp/failing-metadata" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c '. "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint metadata source failure propagates nonzero status' "$_metadata_failure_out" 'status=1'
assert_contains 'entrypoint metadata source failure cleans private root variable' "$_metadata_failure_out" 'root=unset'
assert_contains 'entrypoint metadata source failure cleans private search variable' "$_metadata_failure_out" 'search=unset'
assert_contains 'entrypoint metadata source failure cleans private module root variable' "$_metadata_failure_out" 'module_root=unset'

_loader_failure_out=$(
  VALISE_ROOT="$_tmp/failing-loader" \
    ENTRYPOINT="$ROOT_DIR/entrypoints/profile.sh" \
    /bin/sh -c '. "$ENTRYPOINT" >/dev/null 2>/dev/null; _s=$?; printf "status=%s root=%s search=%s module_root=%s\n" "$_s" "${_sp_root-unset}" "${_sp_search_dir-unset}" "${_sp_module_root-unset}"'
)
assert_contains 'entrypoint loader source failure propagates nonzero status' "$_loader_failure_out" 'status=1'
assert_contains 'entrypoint loader source failure cleans private root variable' "$_loader_failure_out" 'root=unset'
assert_contains 'entrypoint loader source failure cleans private search variable' "$_loader_failure_out" 'search=unset'
assert_contains 'entrypoint loader source failure cleans private module root variable' "$_loader_failure_out" 'module_root=unset'

printf '\n=== zsh reserved-name scan through the entrypoint ===\n'

# The reserved-utility scanner relies on word splitting. zsh splits words
# only when shwordsplit is on, and the entrypoint enables it; probe the real
# entrypoint to prove a tab-named function still fails closed there.
if command -v zsh >/dev/null 2>&1; then
  _zsh_tab_trace="$_tmp/zsh-tab.trace"
  _zsh_tab_out=$(
    VALISE_ROOT="$ROOT_DIR" \
      VALISE_MODULE_ROOT="$ROOT_DIR/tests/fixtures/modules/loader-failure-modes" \
      VALISE_MODULES=tab_name_hijack \
      VALISE_MODE=strict \
      SP_LOADER_TEST_TRACE="$_zsh_tab_trace" \
      zsh -c '. "$VALISE_ROOT/entrypoints/profile.sh" 2>"'"$_tmp"'/zsh-tab.stderr"; _s=$?; printf "status=%s trace=%s export=%s\n" "$_s" "$(cat "$SP_LOADER_TEST_TRACE" 2>/dev/null)" "$(command -v tab_name_hijack_loaded >/dev/null 2>&1 && printf yes || printf no)"'
  )
  assert_eq 'zsh entrypoint fails closed on a tab-named reserved function' 'status=1 trace= export=no' "$_zsh_tab_out"
  assert_contains 'zsh reserved-scan diagnostic is explicit' "$(cat "$_tmp/zsh-tab.stderr")" 'reserved shell utility'
else
  printf '  SKIP: zsh reserved-name lane (zsh unavailable)\n'
fi

printf '\n=== Entrypoint execute-vs-source guard ===\n'

_exec_out=$(/bin/sh "$ROOT_DIR/entrypoints/profile.sh" 2>&1)
_exec_status=$?
_total=$((_total + 1))
case "$_exec_out" in
*'must be sourced, not executed'*) pass 'executing the entrypoint prints source guidance' ;;
*) fail 'executing the entrypoint prints source guidance' "actual: $_exec_out" ;;
esac
_total=$((_total + 1))
if [ "$_exec_status" -ne 0 ]; then
  pass 'executing the entrypoint fails closed'
else
  fail 'executing the entrypoint fails closed'
fi
for _guard_shell in /bin/bash /bin/zsh /bin/ksh; do
  if [ ! -x "$_guard_shell" ]; then
    printf '  SKIP: entrypoint guard lane under %s (shell unavailable)\n' "$_guard_shell"
    continue
  fi
  _guard_out=$("$_guard_shell" "$ROOT_DIR/entrypoints/profile.sh" 2>&1)
  _total=$((_total + 1))
  case "$_guard_out" in
  *'must be sourced, not executed'*) pass "executing the entrypoint under $(basename "$_guard_shell") fails with guidance" ;;
  *) fail "executing the entrypoint under $(basename "$_guard_shell") fails with guidance" "actual: $_guard_out" ;;
  esac
  _guard_sourced_ok=$(
    VALISE_ROOT="$ROOT_DIR" \
      VALISE_MODULE_ROOT="$ROOT_DIR/examples/local" \
      VALISE_MODULES=hello_valise \
      VALISE_MODE=strict \
      "$_guard_shell" -c '. "$0/entrypoints/profile.sh"; printf "%s\n" "$?"' "$ROOT_DIR" 2>&1
  )
  _total=$((_total + 1))
  if [ "$_guard_sourced_ok" = "0" ]; then
    pass "sourcing the entrypoint under $(basename "$_guard_shell") is unaffected by the guard"
  else
    fail "sourcing the entrypoint under $(basename "$_guard_shell") is unaffected by the guard" "actual: $_guard_sourced_ok"
  fi
done
unset _guard_shell _guard_out _guard_sourced_ok

# The guard keys on this file's identity: a differently-named copy that is
# executed does not trip it (it proceeds to the pre-existing late-return
# error instead), so same-named caller scripts sourcing the entrypoint
# cannot be blocked by the guard.
_source_probe="$_tmp/named-profile.sh"
cp "$ROOT_DIR/entrypoints/profile.sh" "$_source_probe"
_named_out=$(
  cd "$REPO_ROOT" || exit 97
  VALISE_MODULE_ROOT="$ROOT_DIR/examples/local" \
    VALISE_MODULES=hello_valise \
    VALISE_MODE=strict \
    /bin/sh "$_source_probe" 2>&1
)
_total=$((_total + 1))
case "$_named_out" in
*'must be sourced, not executed'*)
  fail 'differently-named copy does not trip the entrypoint guard' "actual: $_named_out" ;;
*)
  pass 'differently-named copy does not trip the entrypoint guard' ;;
esac
rm -f "$_source_probe"

printf '\n=== entrypoint-runtime summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
