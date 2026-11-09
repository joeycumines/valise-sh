#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Future loader failure-mode contract tests.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"
LOADER_SH="$ROOT_DIR/lib/loader.sh"
FIXTURE_ROOT="$ROOT_DIR/tests/fixtures/modules/loader-failure-modes"

_pass=0
_fail=0
_xfail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }
xfail() { printf '  XFAIL: %s\n' "$1"; _xfail=$((_xfail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); }

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

assert_contains() {
  _total=$((_total + 1))
  _label=$1
  _haystack=$2
  _needle=$3
  case "$_haystack" in
  *"$_needle"*) pass "$_label" ;;
  *) fail "$_label" "missing: $_needle" ;;
  esac
}

assert_file() {
  _total=$((_total + 1))
  _label=$1
  _path=$2
  if [ -f "$_path" ]; then
    pass "$_label"
  else
    fail "$_label" "missing file: $_path"
  fi
}

printf '\n=== Loader failure-mode fixture presence ===\n'
for _fixture in \
  module.d/core.meta \
  module.d/aggregator.meta \
  module.d/alpha.meta \
  module.d/beta.meta \
  module.d/cwd_mover.meta \
  module.d/tab_name_hijack.meta \
  module.d/tab_function_hijack.meta \
  module.d/tab_readonly_hijack.meta \
  module.d/cwd_roundtrip.meta \
  module.d/cwd_readonly_builtin.meta \
  module.d/local_state.meta \
  module.d/missing_required_user.meta \
  module.d/missing_optional_user.meta \
  module.d/optional_failed_user.meta \
  module.d/optional_failed_dep.meta \
  module.d/optional_invalid_user.meta \
  module.d/optional_invalid_dep.meta \
  module.d/optional_required_missing_user.meta \
  module.d/optional_required_missing_dep.meta \
  module.d/optional_required_runtime_user.meta \
  module.d/optional_required_runtime_dep.meta \
  module.d/optional_required_runtime_req.meta \
  module.d/optional_required_cycle_user.meta \
  module.d/optional_required_cycle_a.meta \
  module.d/optional_required_cycle_b.meta \
  module.d/optional_cycle_app.meta \
  module.d/optional_cycle_opt.meta \
  module.d/cycle_a.meta \
  module.d/cycle_b.meta \
  module.d/command_hijack_dep.meta \
  module.d/command_hijack_user.meta \
  module.d/readonly_command.meta \
  module.d/unset_command.meta \
  module.d/clobber_utility.meta \
  module.d/clobber_shell_state.meta \
  module.d/clobber_expected.meta \
  module.d/clobber_wrapper_state.meta \
  module.d/clobber_word_state.meta \
  module.d/clobber_state.meta \
  module.d/clobber_search_path.meta \
  module.d/clobber_unset.meta \
  module.d/clobber_private.meta \
  module.d/clobber_cleanup.meta \
  module.d/printf_hijack_dep.meta \
  module.d/printf_hijack_user.meta \
  module.d/invalid_module_name.meta \
  module.d/invalid_dependency.meta \
  module.d/failed_hook.meta \
  module.d/export_missing.meta \
  module.d/preexisting_alias_export.meta \
  module.d/preexisting_export.meta \
  module.d/builtin_hijack.meta \
  module.d/preexisting_function_export.meta \
  module.d/reload_probe.meta \
  module.d/wrapper_export.meta \
  module.d/wrapper_export_missing.meta \
  module.d/duplicate_export_first.meta \
  module.d/duplicate_export_second.meta \
  module.d/generated_writer.meta \
  module.d/fish_only.meta \
  module.d/platform_darwin_only.meta \
  module.d/platform_linux_only.meta \
  module.d/platform_edge_optional_darwin.meta \
  module.d/platform_edge_optional_linux.meta \
  module.d/platform_edge_bridge_darwin.meta \
  module.d/platform_edge_bridge_linux.meta \
  module.d/platform_edge_root_darwin.meta \
  module.d/platform_edge_root_linux.meta \
  module.d/platform_edge_blocked_darwin.meta \
  module.d/platform_edge_blocked_linux.meta \
  module.d/required_edge_optional.meta \
  module.d/required_edge_mid.meta \
  module.d/zzz_required_edge_bridge.meta \
  module.d/required_edge_root.meta \
  module.d/platform_nested_optional_darwin.meta \
  module.d/platform_nested_mid_darwin.meta \
  module.d/platform_nested_root_darwin.meta \
  module.d/zzz_platform_nested_bridge_darwin.meta \
  module.d/platform_nested_optional_linux.meta \
  module.d/platform_nested_mid_linux.meta \
  module.d/platform_nested_root_linux.meta \
  module.d/zzz_platform_nested_bridge_linux.meta \
  modules/core.sh \
  modules/alpha.sh \
  modules/beta.sh \
  modules/cwd_mover.sh \
  modules/readonly_pwd.sh \
  modules/readonly_oldpwd.sh \
  modules/readonly_ifs.sh \
  modules/tab_name_hijack.sh \
  modules/tab_function_hijack.sh \
  modules/tab_readonly_hijack.sh \
  modules/cwd_roundtrip.sh \
  modules/cwd_readonly_builtin.sh \
  modules/local_state.sh \
  modules/missing_required_user.sh \
  modules/missing_optional_user.sh \
  modules/optional_failed_user.sh \
  modules/optional_failed_dep.sh \
  modules/optional_invalid_user.sh \
  modules/optional_invalid_dep.sh \
  modules/optional_required_missing_user.sh \
  modules/optional_required_missing_dep.sh \
  modules/optional_required_runtime_user.sh \
  modules/optional_required_runtime_dep.sh \
  modules/optional_required_runtime_req.sh \
  modules/optional_required_cycle_user.sh \
  modules/optional_required_cycle_a.sh \
  modules/optional_required_cycle_b.sh \
  modules/optional_cycle_app.sh \
  modules/optional_cycle_opt.sh \
  modules/cycle_a.sh \
  modules/cycle_b.sh \
  modules/command_hijack_dep.sh \
  modules/command_hijack_user.sh \
  modules/readonly_command.sh \
  modules/unset_command.sh \
  modules/clobber_utility.sh \
  modules/clobber_shell_state.sh \
  modules/clobber_expected.sh \
  modules/clobber_wrapper_state.sh \
  modules/clobber_word_state.sh \
  modules/clobber_search_path.sh \
  modules/clobber_state.sh \
  modules/clobber_unset.sh \
  modules/clobber_private.sh \
  modules/clobber_cleanup.sh \
  modules/printf_hijack_dep.sh \
  modules/printf_hijack_user.sh \
  modules/invalid_module_name.sh \
  modules/invalid_dependency.sh \
  modules/failed_hook.sh \
  modules/export_missing.sh \
  modules/preexisting_alias_export.sh \
  modules/preexisting_export.sh \
  modules/builtin_hijack.sh \
  modules/preexisting_function_export.sh \
  modules/reload_probe.sh \
  modules/wrapper_export.sh \
  modules/wrapper_export_missing.sh \
  modules/duplicate_export_first.sh \
  modules/duplicate_export_second.sh \
  modules/generated_writer.sh \
  modules/fish_only.sh \
  modules/platform_darwin_only.sh \
  modules/platform_edge_optional_darwin.sh \
  modules/platform_edge_optional_linux.sh \
  modules/platform_edge_bridge_darwin.sh \
  modules/platform_edge_bridge_linux.sh \
  modules/platform_edge_root_darwin.sh \
  modules/platform_edge_root_linux.sh \
  modules/platform_edge_blocked_darwin.sh \
  modules/platform_edge_blocked_linux.sh \
  modules/required_edge_optional.sh \
  modules/required_edge_mid.sh \
  modules/zzz_required_edge_bridge.sh \
  modules/required_edge_root.sh \
  modules/platform_nested_optional_darwin.sh \
  modules/platform_nested_mid_darwin.sh \
  modules/platform_nested_root_darwin.sh \
  modules/zzz_platform_nested_bridge_darwin.sh \
  modules/platform_nested_optional_linux.sh \
  modules/platform_nested_mid_linux.sh \
  modules/platform_nested_root_linux.sh \
  modules/zzz_platform_nested_bridge_linux.sh \
  modules/platform_linux_only.sh; do
  assert_file "fixture exists: $_fixture" "$FIXTURE_ROOT/$_fixture"
done
unset _fixture

if [ ! -f "$LOADER_SH" ]; then
  _total=$((_total + 1))
  xfail 'lib/loader.sh is intentionally absent until the next blueprint task; failure-mode tests are armed'
  printf '\n=== loader-failure-modes summary ===\n'
  printf 'Total: %d  Pass: %d  XFail: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_xfail" "$_skip" "$_fail"
  [ "$_fail" -eq 0 ]
  exit $?
fi

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-loader.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

run_loader() {
  _case=$1
  _wanted=$2
  _mode=$3
  _phase=$4
  _trace="$_tmp/$_case.trace"
  _stdout="$_tmp/$_case.stdout"
  _stderr="$_tmp/$_case.stderr"
  : >"$_trace"
  (
    SP_LOADER_TEST_TRACE=$_trace
    export SP_LOADER_TEST_TRACE
    # shellcheck disable=SC1090
    . "$METADATA_SH"
    # shellcheck disable=SC1090
    . "$LOADER_SH"
    if [ "$_case" = preexisting_function_export ]; then
      preexisting_function_loaded() { :; }
    fi
    if [ "$_case" = preexisting_alias_export ]; then
      alias preexisting_alias_loaded=/bin/true
    fi
    if [ "$_case" = wrapper_export ] || [ "$_case" = wrapper_export_missing ] || [ "$_case" = clobber_wrapper_state ]; then
      mkdir -p "$_tmp/bin" || exit 97
      printf '%s\n' '#!/bin/sh' 'exit 0' >"$_tmp/bin/mvn" || exit 97
      chmod +x "$_tmp/bin/mvn" || exit 97
      PATH="$_tmp/bin:$PATH"
      export PATH
    fi
    if [ "$_case" = local_state ]; then
      XDG_STATE_HOME="$_tmp/xdg-state"
      export XDG_STATE_HOME
    fi
    if [ "$_case" = cwd_mover ] || [ "$_case" = cwd_roundtrip ] || [ "$_case" = clobber_wrapper_state ] || [ "$_case" = cwd_readonly_builtin ]; then
      SP_LOADER_TEST_STATE_CWD="$_tmp/cwd-mover-target"
      mkdir -p "$SP_LOADER_TEST_STATE_CWD" || exit 97
      export SP_LOADER_TEST_STATE_CWD
      cd /tmp || exit 97
      OLDPWD=/var
      export OLDPWD
    fi
    if [ "$_case" = wanted_glob_invalid ]; then
      mkdir -p "$_tmp/hostile-cwd" || exit 97
      : >"$_tmp/hostile-cwd/core" || exit 97
      cd "$_tmp/hostile-cwd" || exit 97
    fi
    if [ "$_case" = private_tmp_clobber ] || [ "$_case" = private_cleanup_clobber ]; then
      SP_LOADER_TEST_VICTIM="$_tmp/private-clobber-victim"
      SP_LOADER_TEST_VICTIM_PARENT=$_tmp
      mkdir -p "$SP_LOADER_TEST_VICTIM" || exit 97
      export SP_LOADER_TEST_VICTIM
      export SP_LOADER_TEST_VICTIM_PARENT
    fi
    if [ "$_case" = shell_state_clobber ]; then
      SP_LOADER_TEST_STATE_CWD="$_tmp/shell-state-cwd"
      mkdir -p "$SP_LOADER_TEST_STATE_CWD" || exit 97
      export SP_LOADER_TEST_STATE_CWD
    fi
    _loader_cwd_before=$(pwd -P 2>/dev/null || printf unavailable)
    if [ "${IFS+x}" = x ]; then
      _loader_ifs_was_set_before=1
      _loader_ifs_before=${IFS-}
    else
      _loader_ifs_was_set_before=0
      _loader_ifs_before=
    fi
    _loader_options_before=$-
    if [ "$_case" = wanted_noglob_preserve_disabled ]; then
      set -f
    fi
    sp_loader_load_modules "$FIXTURE_ROOT" "$_wanted" "$_mode" "$_phase"
    _loader_status=$?
    if [ "$_case" = printf_utility_hijack ]; then
      SP_LOADER_TEST_SUPPRESS_PRINTF_MARKER=1
      export SP_LOADER_TEST_SUPPRESS_PRINTF_MARKER
    fi
    printf 'LOADER_RETURNED=%s\n' "$_loader_status"
    case "$_case" in
    wanted_glob_invalid | wanted_noglob_preserve_enabled | wanted_noglob_preserve_disabled)
      case $- in
      *f*) printf '%s\n' 'NOGLOB_AFTER=yes' ;;
      *) printf '%s\n' 'NOGLOB_AFTER=no' ;;
      esac
      ;;
    esac
    _leaked_upper_vars=$(compgen -A variable _SP_LOADER_ 2>/dev/null | tr '\n' ' ')
    _leaked_spl_vars=$(compgen -A variable _spl 2>/dev/null | tr '\n' ' ')
    _leaked_lower_vars=$(compgen -A variable _sp_loader_ 2>/dev/null | tr '\n' ' ')
    _leaked_internal_funcs=$(compgen -A function _sp_loader_ 2>/dev/null | tr '\n' ' ')
    if [ -n "$_leaked_upper_vars" ]; then
      printf 'LEAKED_UPPER_VARS=%s\n' "$_leaked_upper_vars"
    fi
    if [ -n "$_leaked_spl_vars" ]; then
      printf 'LEAKED_SPL_VARS=%s\n' "$_leaked_spl_vars"
    fi
    if [ -n "$_leaked_lower_vars" ]; then
      printf 'LEAKED_LOWER_VARS=%s\n' "$_leaked_lower_vars"
    fi
    if [ -n "$_leaked_internal_funcs" ]; then
      printf 'LEAKED_INTERNAL_FUNCS=%s\n' "$_leaked_internal_funcs"
    fi
    for _failed_export in failed_hook_loaded optional_failed_dep_loaded optional_required_runtime_req_loaded command_hijack_dep_loaded readonly_command_loaded unset_command_loaded clobber_utility_loaded clobber_shell_state_loaded clobber_expected_loaded clobber_state_loaded clobber_search_path_loaded clobber_unset_loaded clobber_private_loaded clobber_cleanup_loaded printf_hijack_dep_loaded; do
      if command -v "$_failed_export" >/dev/null 2>&1; then
        printf 'LEAKED_FAILED_EXPORT=%s\n' "$_failed_export"
      fi
    done
    case "$_case" in
    shell_state_clobber)
      _loader_cwd_after=$(pwd -P 2>/dev/null || printf unavailable)
      if [ "$_loader_cwd_after" = "$_loader_cwd_before" ]; then
        printf 'SHELL_STATE_CWD=preserved\n'
      else
        printf 'SHELL_STATE_CWD=changed\n'
      fi
      if [ "${IFS+x}" = x ]; then
        _loader_ifs_was_set_after=1
        _loader_ifs_after=${IFS-}
      else
        _loader_ifs_was_set_after=0
        _loader_ifs_after=
      fi
      if [ "$_loader_ifs_was_set_after" -eq "$_loader_ifs_was_set_before" ] && [ "$_loader_ifs_after" = "$_loader_ifs_before" ]; then
        printf 'SHELL_STATE_IFS=preserved\n'
      else
        printf 'SHELL_STATE_IFS=changed\n'
      fi
      case $- in
      *f*) printf 'SHELL_STATE_NOGLOB=yes\n' ;;
      *) printf 'SHELL_STATE_NOGLOB=no\n' ;;
      esac
      _loader_options_after=$-
      _loader_options_preserved=yes
      for _loader_flag in e f u; do
        case $_loader_options_before in
        *"$_loader_flag"*) _loader_flag_before=yes ;;
        *) _loader_flag_before=no ;;
        esac
        case $_loader_options_after in
        *"$_loader_flag"*) _loader_flag_after=yes ;;
        *) _loader_flag_after=no ;;
        esac
        if [ "$_loader_flag_before" != "$_loader_flag_after" ]; then
          _loader_options_preserved=no
        fi
      done
      if [ "$_loader_options_preserved" = yes ]; then
        printf 'SHELL_STATE_OPTIONS=preserved\n'
      else
        printf 'SHELL_STATE_OPTIONS=changed\n'
      fi
      ;;
    private_tmp_clobber | private_cleanup_clobber)
      if [ -d "$SP_LOADER_TEST_VICTIM" ]; then
        printf 'PRIVATE_CLOBBER_VICTIM=present\n'
      else
        printf 'PRIVATE_CLOBBER_VICTIM=missing\n'
      fi
      ;;
    preexisting_function_export)
      if command -v preexisting_function_loaded >/dev/null 2>&1; then
        printf 'PREEXISTING_EXPORT_PRESENT=yes\n'
      else
        printf 'PREEXISTING_EXPORT_PRESENT=no\n'
      fi
      ;;
    wrapper_export)
      if [ "$(command -v mvn 2>/dev/null)" = mvn ]; then
        printf 'WRAPPER_EXPORT_FUNCTION=yes\n'
      else
        printf 'WRAPPER_EXPORT_FUNCTION=no\n'
      fi
      ;;
    local_state)
      if [ -d "$XDG_STATE_HOME/shell-profile" ]; then
        printf 'LOCAL_STATE_DIR=present\n'
      else
        printf 'LOCAL_STATE_DIR=missing\n'
      fi
      ;;
    cwd_mover | cwd_roundtrip | clobber_wrapper_state | cwd_readonly_builtin)
      printf 'PWD_AFTER=%s\n' "${PWD-}"
      printf 'OLDPWD_AFTER=%s\n' "${OLDPWD-}"
      ;;
    duplicate_export_permissive | duplicate_export_strict)
      if command -v duplicate_shared_loaded >/dev/null 2>&1; then
        printf 'DUPLICATE_EXPORT_PRESENT=yes\n'
      else
        printf 'DUPLICATE_EXPORT_PRESENT=no\n'
      fi
      ;;
    optional_failed_strict | optional_failed_permissive)
      if command -v optional_failed_user_loaded >/dev/null 2>&1; then
        printf 'OPTIONAL_FAILED_USER_PRESENT=yes\n'
      else
        printf 'OPTIONAL_FAILED_USER_PRESENT=no\n'
      fi
      ;;
    optional_invalid_strict | optional_invalid_permissive)
      if command -v optional_invalid_user_loaded >/dev/null 2>&1; then
        printf 'OPTIONAL_INVALID_USER_PRESENT=yes\n'
      else
        printf 'OPTIONAL_INVALID_USER_PRESENT=no\n'
      fi
      ;;
    optional_required_missing_strict | optional_required_missing_permissive)
      if command -v optional_required_missing_user_loaded >/dev/null 2>&1; then
        printf 'OPTIONAL_REQUIRED_MISSING_USER_PRESENT=yes\n'
      else
        printf 'OPTIONAL_REQUIRED_MISSING_USER_PRESENT=no\n'
      fi
      ;;
    optional_required_runtime_strict | optional_required_runtime_permissive)
      if command -v optional_required_runtime_user_loaded >/dev/null 2>&1; then
        printf 'OPTIONAL_REQUIRED_RUNTIME_USER_PRESENT=yes\n'
      else
        printf 'OPTIONAL_REQUIRED_RUNTIME_USER_PRESENT=no\n'
      fi
      ;;
    optional_required_cycle_strict | optional_required_cycle_permissive)
      if command -v optional_required_cycle_user_loaded >/dev/null 2>&1; then
        printf 'OPTIONAL_REQUIRED_CYCLE_USER_PRESENT=yes\n'
      else
        printf 'OPTIONAL_REQUIRED_CYCLE_USER_PRESENT=no\n'
      fi
      ;;
    esac
    exit "$_loader_status"
  ) >"$_stdout" 2>"$_stderr"
  _status=$?
  _out=$(cat "$_stdout")
  _err=$(cat "$_stderr")
  _trace_out=$(cat "$_trace")
}

assert_no_loader_leaks() {
  assert_no_loader_leaks_with_output "$1" "LOADER_RETURNED=$_status"
}

assert_no_loader_leaks_with_output() {
  assert_eq "$1 returns control and leaves no loader runtime variables or internal functions" "$2" "$_out"
}

printf '\n=== Loader failure-mode executable contract ===\n'

run_loader wanted_glob_invalid '[c]ore' strict ordinary
assert_eq 'invalid wanted module glob fails closed in hostile cwd' 1 "$_status"
assert_contains 'invalid wanted module glob diagnostic is explicit' "$_err" 'invalid wanted module'
assert_eq 'invalid wanted module glob does not load matched cwd path' '' "$_trace_out"
assert_no_loader_leaks_with_output 'invalid wanted module glob failure preserves caller globbing' "$(printf 'LOADER_RETURNED=%s\nNOGLOB_AFTER=no' "$_status")"

run_loader wanted_noglob_preserve_enabled core strict ordinary
assert_eq 'wanted-list splitting preserves caller globbing-enabled state' 0 "$_status"
assert_eq 'wanted-list globbing-enabled state case loads core' 'core' "$_trace_out"
assert_no_loader_leaks_with_output 'wanted-list globbing-enabled state' "$(printf 'LOADER_RETURNED=%s\nNOGLOB_AFTER=no' "$_status")"

run_loader wanted_noglob_preserve_disabled core strict ordinary
assert_eq 'wanted-list splitting preserves caller noglob state' 0 "$_status"
assert_eq 'wanted-list noglob state case loads core' 'core' "$_trace_out"
assert_no_loader_leaks_with_output 'wanted-list noglob state' "$(printf 'LOADER_RETURNED=%s\nNOGLOB_AFTER=yes' "$_status")"

run_loader strict_missing_required missing_required_user strict ordinary
assert_eq 'strict mode fails on missing required dependency' 1 "$_status"
assert_contains 'strict missing dependency diagnostic names module' "$_err" 'missing_required_user'
assert_contains 'strict missing dependency diagnostic names dependency' "$_err" 'missing_dep'
assert_eq 'strict missing dependency loads nothing' '' "$_trace_out"
assert_no_loader_leaks 'strict missing dependency failure'

run_loader permissive_missing_required 'core missing_required_user' permissive ordinary
assert_eq 'permissive mode continues after missing dependency' 0 "$_status"
assert_contains 'permissive missing dependency warning names dependency' "$_err" 'missing_dep'
assert_eq 'permissive missing dependency loads unrelated module only' 'core' "$_trace_out"
assert_no_loader_leaks 'permissive missing dependency'

run_loader missing_optional missing_optional_user strict ordinary
assert_eq 'missing optional dependency does not block strict load' 0 "$_status"
assert_eq 'missing optional dependency still loads required dependency then module' $'core\nmissing_optional_user' "$_trace_out"
assert_no_loader_leaks 'missing optional dependency success'

run_loader optional_failed_strict optional_failed_user strict ordinary
assert_eq 'strict optional dependency runtime failure does not block declaring module' 0 "$_status"
assert_contains 'strict optional dependency runtime failure diagnostic names optional module' "$_err" 'optional_failed_dep'
assert_eq 'strict optional dependency runtime failure loads declaring module after failed optional attempt' $'optional_failed_dep_started\noptional_failed_user' "$_trace_out"
assert_no_loader_leaks_with_output 'strict optional dependency runtime failure cleans failed optional export and preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_FAILED_USER_PRESENT=yes' "$_status")"

run_loader optional_failed_permissive optional_failed_user permissive ordinary
assert_eq 'permissive optional dependency runtime failure does not block declaring module' 0 "$_status"
assert_contains 'permissive optional dependency runtime failure diagnostic names optional module' "$_err" 'optional_failed_dep'
assert_eq 'permissive optional dependency runtime failure loads declaring module after failed optional attempt' $'optional_failed_dep_started\noptional_failed_user' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive optional dependency runtime failure cleans failed optional export and preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_FAILED_USER_PRESENT=yes' "$_status")"

run_loader optional_invalid_strict optional_invalid_user strict ordinary
assert_eq 'strict optional dependency metadata/source failure does not block declaring module' 0 "$_status"
assert_contains 'strict optional invalid metadata diagnostic names generated-file' "$_err" 'generated-file'
assert_eq 'strict optional invalid metadata blocks optional body only' 'optional_invalid_user' "$_trace_out"
assert_no_loader_leaks_with_output 'strict optional invalid metadata preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_INVALID_USER_PRESENT=yes' "$_status")"

run_loader optional_invalid_permissive optional_invalid_user permissive ordinary
assert_eq 'permissive optional dependency metadata/source failure does not block declaring module' 0 "$_status"
assert_contains 'permissive optional invalid metadata diagnostic names generated-file' "$_err" 'generated-file'
assert_eq 'permissive optional invalid metadata blocks optional body only' 'optional_invalid_user' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive optional invalid metadata preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_INVALID_USER_PRESENT=yes' "$_status")"

run_loader optional_required_missing_strict optional_required_missing_user strict ordinary
assert_eq 'strict optional dependency with missing required child does not block declaring module' 0 "$_status"
assert_contains 'strict optional required-missing diagnostic names missing child' "$_err" 'optional_required_missing_leaf'
assert_eq 'strict optional required-missing chain blocks optional body only' 'optional_required_missing_user' "$_trace_out"
assert_no_loader_leaks_with_output 'strict optional required-missing chain preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_MISSING_USER_PRESENT=yes' "$_status")"

run_loader optional_required_missing_permissive optional_required_missing_user permissive ordinary
assert_eq 'permissive optional dependency with missing required child does not block declaring module' 0 "$_status"
assert_contains 'permissive optional required-missing diagnostic names missing child' "$_err" 'optional_required_missing_leaf'
assert_eq 'permissive optional required-missing chain blocks optional body only' 'optional_required_missing_user' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive optional required-missing chain preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_MISSING_USER_PRESENT=yes' "$_status")"

run_loader optional_required_runtime_strict optional_required_runtime_user strict ordinary
assert_eq 'strict optional dependency with failing required child does not block declaring module' 0 "$_status"
assert_contains 'strict optional required-runtime diagnostic names failed child' "$_err" 'optional_required_runtime_req'
assert_eq 'strict optional required-runtime chain attempts child then loads declaring module' $'optional_required_runtime_req_started\noptional_required_runtime_user' "$_trace_out"
assert_no_loader_leaks_with_output 'strict optional required-runtime chain cleans failed child and preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_RUNTIME_USER_PRESENT=yes' "$_status")"

run_loader optional_required_runtime_permissive optional_required_runtime_user permissive ordinary
assert_eq 'permissive optional dependency with failing required child does not block declaring module' 0 "$_status"
assert_contains 'permissive optional required-runtime diagnostic names failed child' "$_err" 'optional_required_runtime_req'
assert_eq 'permissive optional required-runtime chain attempts child then loads declaring module' $'optional_required_runtime_req_started\noptional_required_runtime_user' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive optional required-runtime chain cleans failed child and preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_RUNTIME_USER_PRESENT=yes' "$_status")"

run_loader optional_required_cycle_strict optional_required_cycle_user strict ordinary
assert_eq 'strict optional dependency with required cycle does not block declaring module' 0 "$_status"
assert_contains 'strict optional required-cycle diagnostic is visible' "$_err" 'cycle'
assert_eq 'strict optional required-cycle chain loads declaring module only' 'optional_required_cycle_user' "$_trace_out"
assert_no_loader_leaks_with_output 'strict optional required-cycle chain preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_CYCLE_USER_PRESENT=yes' "$_status")"

run_loader optional_required_cycle_permissive optional_required_cycle_user permissive ordinary
assert_eq 'permissive optional dependency with required cycle does not block declaring module' 0 "$_status"
assert_contains 'permissive optional required-cycle diagnostic is visible' "$_err" 'cycle'
assert_eq 'permissive optional required-cycle chain loads declaring module only' 'optional_required_cycle_user' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive optional required-cycle chain preserves declaring module' "$(printf 'LOADER_RETURNED=%s\nOPTIONAL_REQUIRED_CYCLE_USER_PRESENT=yes' "$_status")"

run_loader permissive_optional_cycle optional_cycle_app permissive ordinary
assert_eq 'permissive optional dependency cycle remains non-fatal' 0 "$_status"
assert_eq 'optional dependency cycle still loads declaring module and optional extension' $'optional_cycle_app\noptional_cycle_opt' "$_trace_out"
assert_no_loader_leaks 'permissive optional dependency cycle'

run_loader strict_optional_cycle optional_cycle_app strict ordinary
assert_eq 'strict optional dependency cycle does not fail declaring module' 0 "$_status"
assert_eq 'strict optional dependency cycle orders required edge after declaring module fallback' $'optional_cycle_app\noptional_cycle_opt' "$_trace_out"
assert_no_loader_leaks 'strict optional dependency cycle'

run_loader permissive_cycle 'core cycle_a' permissive ordinary
assert_eq 'permissive cycle remains non-fatal for unrelated modules' 0 "$_status"
assert_contains 'cycle diagnostic is visible' "$_err" 'cycle'
assert_eq 'cycle skips affected modules only' 'core' "$_trace_out"
assert_no_loader_leaks 'permissive cycle'

run_loader strict_cycle cycle_a strict ordinary
assert_eq 'strict cycle fails closed' 1 "$_status"
assert_contains 'strict cycle diagnostic is visible' "$_err" 'cycle'
assert_eq 'strict cycle executes no cyclic module bodies' '' "$_trace_out"
assert_no_loader_leaks 'strict cycle failure'

run_loader shell_state_clobber clobber_shell_state strict ordinary
assert_eq 'module clobbering caller shell state fails closed' 1 "$_status"
assert_contains 'shell-state clobber diagnostic names caller shell state' "$_err" 'caller shell state modified'
assert_eq 'shell-state clobber attempts module body before detection' 'clobber_shell_state_started' "$_trace_out"
assert_no_loader_leaks_with_output 'shell-state clobber restores cwd ifs options and cleans failed export' "$(printf 'LOADER_RETURNED=%s\nSHELL_STATE_CWD=preserved\nSHELL_STATE_IFS=preserved\nSHELL_STATE_NOGLOB=no\nSHELL_STATE_OPTIONS=preserved' "$_status")"

run_loader utility_clobber clobber_utility strict ordinary
assert_eq 'module clobbering loader utility names fails closed' 1 "$_status"
assert_contains 'utility clobber diagnostic names failed module' "$_err" 'clobber_utility'
assert_eq 'utility clobber cannot hijack loader grep or cleanup rm' 'clobber_utility_started' "$_trace_out"
assert_no_loader_leaks 'utility clobber cleans failed export without trusting shell functions'

run_loader command_utility_hijack command_hijack_user permissive ordinary
assert_eq 'module clobbering command cannot hide permissive required dependency failure' 0 "$_status"
assert_contains 'command hijack diagnostic names failed dependency' "$_err" 'command_hijack_dep'
assert_contains 'command hijack diagnostic reports required dependency failure' "$_err" 'required dependency failed'
assert_contains 'command hijack rejects reserved command definition before source' "$_err" 'reserved shell utility'
assert_eq 'command hijack cannot execute reserved command definition body' '' "$_trace_out"
assert_no_loader_leaks 'command hijack cleans failed export and skips dependent module'

run_loader readonly_command_hijack readonly_command strict ordinary
assert_eq 'readonly command hijack is rejected before source' 1 "$_status"
assert_contains 'readonly command hijack diagnostic names reserved shell utility' "$_err" 'reserved shell utility'
assert_eq 'readonly command hijack body never executes' '' "$_trace_out"
assert_no_loader_leaks 'readonly command hijack leaves no command function or failed export'

run_loader unset_command_hijack unset_command strict ordinary
assert_eq 'unset plus command hijack is rejected before source' 1 "$_status"
assert_contains 'unset plus command hijack diagnostic names reserved shell utility' "$_err" 'reserved shell utility'
assert_eq 'unset plus command hijack body never executes' '' "$_trace_out"
assert_no_loader_leaks 'unset plus command hijack leaves no utility functions or failed export'

run_loader printf_utility_hijack printf_hijack_user permissive ordinary
assert_eq 'module clobbering printf cannot hide permissive required dependency failure' 0 "$_status"
assert_contains 'printf hijack diagnostic names failed dependency' "$_err" 'printf_hijack_dep'
assert_contains 'printf hijack diagnostic reports required dependency failure' "$_err" 'required dependency failed'
assert_eq 'printf hijack cannot intercept loader diagnostics or failed-module bookkeeping' 'printf_hijack_dep_started' "$_trace_out"
assert_no_loader_leaks 'printf hijack cleans failed export and skips dependent module'

run_loader private_expected_clobber clobber_expected strict ordinary
assert_eq 'module clobbering loader expected-state snapshots fails closed' 1 "$_status"
assert_contains 'expected-state clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'expected-state clobber attempts module body before detection' 'clobber_expected_started' "$_trace_out"
assert_no_loader_leaks 'expected-state clobber restores strict mode and failed-export cleanup'

run_loader clobber_wrapper_state clobber_wrapper_state strict ordinary
assert_eq 'module clobbering wrapper and cwd trust state fails closed' 1 "$_status"
assert_contains 'wrapper/cwd guard clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'wrapper/cwd guard clobber attempts module body before detection' 'clobber_wrapper_state_started' "$_trace_out"
assert_no_loader_leaks_with_output 'wrapper/cwd guard clobber restores trusted state and caller cwd' "$(printf 'LOADER_RETURNED=%s\nPWD_AFTER=/tmp\nOLDPWD_AFTER=/var' "$_status")"

run_loader clobber_word_state clobber_word_state strict ordinary
assert_eq 'module clobbering loader word-state membership fails closed' 1 "$_status"
assert_contains 'word-state clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'word-state clobber attempts module body before detection' 'clobber_word_state_started' "$_trace_out"
assert_no_loader_leaks 'word-state clobber restores loader membership words'

run_loader private_state_clobber clobber_state strict ordinary
assert_eq 'module clobbering loader non-cleanup private state fails closed' 1 "$_status"
assert_contains 'state clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'state clobber attempts module body before detection' 'clobber_state_started' "$_trace_out"
assert_no_loader_leaks 'state clobber restores strict mode and cleans failed export'

run_loader search_path_clobber clobber_search_path strict ordinary
assert_eq 'strict private search-path clobber fails closed' 1 "$_status"
assert_contains 'search-path clobber diagnostic names the private namespace' "$_err" 'loader private namespace modified'
assert_eq 'search-path clobber prevents module completion' 'clobber_search_path_started' "$_trace_out"
assert_no_loader_leaks 'search-path clobber'

run_loader private_unset_nounset_clobber clobber_unset strict ordinary
assert_eq 'module unsetting loader private state under nounset fails closed without aborting caller' 1 "$_status"
assert_contains 'private unset diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'private unset attempts module body before detection' 'clobber_unset_started' "$_trace_out"
assert_no_loader_leaks 'private unset restores nounset-sensitive loader state and cleans failed export'

run_loader private_tmp_clobber clobber_private strict ordinary
assert_eq 'module clobbering loader temp variable fails closed' 1 "$_status"
assert_contains 'private clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'private clobber attempts module body before detection' 'clobber_private_started' "$_trace_out"
assert_no_loader_leaks_with_output 'private clobber preserves cleanup target and cleans failed export' "$(printf 'LOADER_RETURNED=%s\nPRIVATE_CLOBBER_VICTIM=present' "$_status")"

run_loader private_cleanup_clobber clobber_cleanup strict ordinary
assert_eq 'module clobbering loader cleanup variables fails closed' 1 "$_status"
assert_contains 'cleanup clobber diagnostic names loader namespace' "$_err" 'loader private namespace modified'
assert_eq 'cleanup clobber attempts module body before detection' 'clobber_cleanup_started' "$_trace_out"
assert_no_loader_leaks_with_output 'cleanup clobber ignores module-controlled cleanup target and cleans failed export' "$(printf 'LOADER_RETURNED=%s\nPRIVATE_CLOBBER_VICTIM=present' "$_status")"

run_loader invalid_module_name invalid_module_name strict ordinary
assert_eq 'invalid module-name metadata fails closed' 1 "$_status"
assert_contains 'invalid module-name diagnostic is visible' "$_err" 'invalid module name'
assert_eq 'invalid module-name metadata never loads module body' '' "$_trace_out"
assert_no_loader_leaks 'invalid module-name failure'

run_loader invalid_dependency invalid_dependency strict ordinary
assert_eq 'invalid dependency metadata fails closed' 1 "$_status"
assert_contains 'invalid dependency diagnostic is visible' "$_err" 'invalid dependency'
assert_eq 'invalid dependency never loads module body' '' "$_trace_out"
assert_no_loader_leaks 'invalid dependency failure'

run_loader failed_hook 'core failed_hook' permissive ordinary
assert_eq 'permissive failed file-backed import remains non-fatal for unrelated modules' 0 "$_status"
assert_contains 'failed file-backed import diagnostic names module' "$_err" 'failed_hook'
assert_eq 'failed import attempts only dependency and failing body' $'core\nfailed_hook_started' "$_trace_out"
assert_no_loader_leaks 'permissive failed file-backed import'

run_loader strict_failed_file_import 'core failed_hook' strict ordinary
assert_eq 'strict file-backed import failure returns failure' 1 "$_status"
assert_contains 'strict file-backed import diagnostic names module' "$_err" 'failed_hook'
assert_eq 'strict file-backed import records dependency and failed body only' $'core\nfailed_hook_started' "$_trace_out"
assert_no_loader_leaks 'strict file-backed import failure'

run_loader deterministic_order 'beta alpha' strict ordinary
assert_eq 'independent wanted modules load in deterministic alphabetical order' 0 "$_status"
assert_eq 'deterministic load order is alphabetic' $'alpha\nbeta' "$_trace_out"
assert_no_loader_leaks 'successful deterministic load'

run_loader missing_declared_export export_missing strict ordinary
assert_eq 'strict module with missing declared export fails closed' 1 "$_status"
assert_contains 'missing declared export diagnostic names export' "$_err" 'declared_missing'
assert_eq 'missing declared export still records attempted module body' 'export_missing' "$_trace_out"
assert_no_loader_leaks 'missing declared export failure'

run_loader preexisting_declared_export preexisting_export strict ordinary
assert_eq 'strict module with pre-existing declared export fails closed' 1 "$_status"
assert_contains 'pre-existing declared export diagnostic names export' "$_err" 'printf'
assert_eq 'pre-existing declared export prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'pre-existing declared export failure'

run_loader preexisting_function_export preexisting_function_export strict ordinary
assert_eq 'strict module with pre-existing shell-function export fails closed' 1 "$_status"
assert_contains 'pre-existing shell-function export diagnostic names export' "$_err" 'preexisting_function_loaded'
assert_eq 'pre-existing shell-function export prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks_with_output 'pre-existing shell-function export failure preserves caller function' "$(printf 'LOADER_RETURNED=%s\nPREEXISTING_EXPORT_PRESENT=yes' "$_status")"

run_loader preexisting_alias_export preexisting_alias_export strict ordinary
assert_eq 'strict module with pre-existing alias export fails closed' 1 "$_status"
assert_contains 'pre-existing alias export diagnostic names export' "$_err" 'preexisting_alias_loaded'
assert_eq 'pre-existing alias export prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'pre-existing alias export failure'

run_loader wrapper_export wrapper_export strict ordinary
assert_eq 'strict module may wrap an existing external command export' 0 "$_status"
assert_eq 'external-command wrapper module body executes' 'wrapper_export' "$_trace_out"
assert_no_loader_leaks_with_output 'external-command wrapper replaces PATH resolution with a function' "$(printf 'LOADER_RETURNED=%s\nWRAPPER_EXPORT_FUNCTION=yes' "$_status")"

run_loader wrapper_export_missing wrapper_export_missing strict ordinary
assert_eq 'external-command export not provided by the module fails closed' 1 "$_status"
assert_contains 'unprovided wrapper export diagnostic names the export' "$_err" 'declared export was not provided by module: mvn'
assert_eq 'unprovided wrapper export still attempts the module body' 'wrapper_export_missing' "$_trace_out"
assert_no_loader_leaks 'unprovided wrapper export failure'

run_loader builtin_hijack builtin_hijack strict ordinary
assert_eq 'module defining the builtin utility fails closed' 1 "$_status"
assert_contains 'builtin utility hijack diagnostic is explicit' "$_err" 'reserved shell utility'
assert_eq 'builtin utility hijack prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'builtin utility hijack failure'

run_loader aggregator aggregator strict ordinary
assert_eq 'meta module with only dependencies loads successfully' 0 "$_status"
assert_eq 'meta module loads its dependency closure without a body' 'core' "$_trace_out"
assert_eq 'meta module emits no diagnostic' '' "$_err"
assert_no_loader_leaks 'meta module success'

run_loader local_state local_state strict ordinary
assert_eq 'ordinary source permits local-state module' 0 "$_status"
assert_eq 'local-state module body executes' 'local_state_started' "$_trace_out"
assert_no_loader_leaks_with_output 'local-state module creates its state directory' "$(printf 'LOADER_RETURNED=%s\nLOCAL_STATE_DIR=present' "$_status")"

run_loader cwd_mover cwd_mover strict ordinary
assert_eq 'module changing cwd fails closed' 1 "$_status"
assert_contains 'cwd change diagnostic names caller shell state' "$_err" 'caller shell state modified'
assert_eq 'cwd change attempts module body before detection' 'cwd_mover_started' "$_trace_out"
assert_no_loader_leaks_with_output 'cwd change preserves logical PWD and OLDPWD' "$(printf 'LOADER_RETURNED=%s\nPWD_AFTER=/tmp\nOLDPWD_AFTER=/var' "$_status")"

for _readonly_case in readonly_pwd readonly_oldpwd readonly_ifs; do
  run_loader "$_readonly_case" "$_readonly_case" strict ordinary
  assert_eq "$_readonly_case fails closed" 1 "$_status"
  assert_contains "$_readonly_case diagnostic names caller shell state" "$_err" 'caller shell state modified'
  assert_no_loader_leaks "$_readonly_case leaves no loader runtime state"
done

run_loader cwd_roundtrip cwd_roundtrip strict ordinary
assert_eq 'module returning to its starting directory loads' 0 "$_status"
assert_eq 'cwd round trip reports no diagnostic' '' "$_err"
assert_eq 'cwd round trip runs the module body' 'cwd_roundtrip_started' "$_trace_out"
assert_no_loader_leaks_with_output 'cwd round trip restores logical PWD and OLDPWD' "$(printf 'LOADER_RETURNED=%s\nPWD_AFTER=/tmp\nOLDPWD_AFTER=/var' "$_status")"

for _tab_case in tab_name_hijack tab_function_hijack tab_readonly_hijack; do
  run_loader "$_tab_case" "$_tab_case" strict ordinary
  assert_eq "$_tab_case: tab-separated reserved definition fails closed" 1 "$_status"
  assert_contains "$_tab_case: diagnostic names the reserved utility" "$_err" 'load path defines reserved shell utility'
  assert_eq "$_tab_case: module body is never sourced" '' "$_trace_out"
done
unset _tab_case

run_loader cwd_readonly_builtin cwd_readonly_builtin strict ordinary
assert_eq 'dynamic readonly builtin hijack fails closed' 1 "$_status"
assert_contains 'dynamic readonly builtin diagnostic names caller shell state' "$_err" 'caller shell state modified'
assert_eq 'dynamic readonly builtin attempts module body before detection' 'cwd_readonly_builtin_started' "$_trace_out"
assert_no_loader_leaks_with_output 'dynamic readonly builtin cannot prevent physical cwd restoration' "$(printf 'LOADER_RETURNED=%s\nPWD_AFTER=/tmp\nOLDPWD_AFTER=/var' "$_status")"

run_loader duplicate_export_permissive 'duplicate_export_first duplicate_export_second' permissive ordinary
assert_eq 'permissive duplicate export skips second module without failing' 0 "$_status"
assert_contains 'permissive duplicate export diagnostic names second module' "$_err" 'duplicate_export_second'
assert_eq 'permissive duplicate export keeps first module only' 'duplicate_export_first' "$_trace_out"
assert_no_loader_leaks_with_output 'permissive duplicate export preserves first module export' "$(printf 'LOADER_RETURNED=%s\nDUPLICATE_EXPORT_PRESENT=yes' "$_status")"

run_loader duplicate_export_strict 'duplicate_export_first duplicate_export_second' strict ordinary
assert_eq 'strict duplicate export fails on second module' 1 "$_status"
assert_contains 'strict duplicate export diagnostic names second module' "$_err" 'duplicate_export_second'
assert_eq 'strict duplicate export keeps first module only' 'duplicate_export_first' "$_trace_out"
assert_no_loader_leaks_with_output 'strict duplicate export preserves first module export' "$(printf 'LOADER_RETURNED=%s\nDUPLICATE_EXPORT_PRESENT=yes' "$_status")"

run_loader source_side_effect generated_writer strict ordinary
assert_eq 'ordinary source rejects generated-file module before load' 1 "$_status"
assert_contains 'source side-effect diagnostic names generated-file' "$_err" 'generated-file'
assert_eq 'source side-effect rejection prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'source side-effect rejection'

run_loader unsupported_shell fish_only strict ordinary
assert_eq 'strict unsupported shell metadata fails closed' 1 "$_status"
assert_contains 'unsupported shell diagnostic is visible' "$_err" 'unsupported shell'
assert_eq 'unsupported shell rejection prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'unsupported shell rejection'

_spoof_root=$_tmp/spoof-shell
mkdir -p "$_spoof_root/module.d" "$_spoof_root/modules"
cat >"$_spoof_root/module.d/bash_only.meta" <<'SPOOF_META'
name=bash_only
requires=
optional=
shells=bash
platforms=any
side_effect=read-only
exports=bash_only_loaded
load=modules/bash_only.sh
SPOOF_META
cat >"$_spoof_root/modules/bash_only.sh" <<'SPOOF_MODULE'
printf '%s\n' bash_only_executed >>"${SP_LOADER_TEST_TRACE:?}"
bash_only_loaded() { :; }
SPOOF_MODULE
_spoof_trace=$_spoof_root/trace
: >"$_spoof_trace"
if [ -x /bin/dash ]; then
  _spoof_out=$(/usr/bin/env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    PATH=/usr/bin:/bin BASH_VERSION=spoof SP_LOADER_TEST_TRACE="$_spoof_trace" \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" SPOOF_ROOT="$_spoof_root" \
    /bin/dash -c '
      . "$METADATA_SH"
      . "$LOADER_SH"
      sp_loader_load_modules "$SPOOF_ROOT" bash_only strict ordinary
    ' 2>&1)
  _spoof_status=$?
  assert_eq 'forged BASH_VERSION does not classify POSIX sh as Bash' 1 "$_spoof_status"
  assert_contains 'forged BASH_VERSION shell rejection is explicit' "$_spoof_out" 'unsupported shell'
  assert_eq 'forged BASH_VERSION cannot execute Bash-only module' '' "$(cat "$_spoof_trace")"
else
  skip 'forged BASH_VERSION rejection lane (dash unavailable; the check gate enforces a dash executor through the multi-root lanes)'
fi
unset _spoof_root _spoof_trace _spoof_out _spoof_status

case "$(uname -s 2>/dev/null || printf unknown)" in
Darwin) _unsupported_platform_module=platform_linux_only ;;
*) _unsupported_platform_module=platform_darwin_only ;;
esac
run_loader unsupported_platform "$_unsupported_platform_module" strict ordinary
assert_eq 'strict unsupported platform metadata fails closed' 1 "$_status"
assert_contains 'unsupported platform diagnostic is visible' "$_err" 'unsupported platform'
assert_eq 'unsupported platform rejection prevents module body execution' '' "$_trace_out"
assert_no_loader_leaks 'unsupported platform rejection'
unset _unsupported_platform_module

# A platform-skipped module can be reached through an optional edge first and
# a required edge later. The required-closure decision must use every edge,
# not the discovery order: strict fails with the platform diagnostic, and the
# optional-only case stays silent.
case "$(uname -s 2>/dev/null || printf unknown)" in
Darwin) _edge_suffix=darwin; _edge_blocked_suffix=linux ;;
*) _edge_suffix=linux; _edge_blocked_suffix=darwin ;;
esac

run_loader platform_edge_optional "platform_edge_optional_$_edge_suffix" strict ordinary
assert_eq 'a platform-skipped optional dependency is silent in strict mode' 0 "$_status"
assert_eq 'a platform-skipped optional dependency writes no diagnostic' '' "$_err"
assert_eq 'a platform-skipped optional dependency still loads its declaring module' "platform_edge_optional_$_edge_suffix" "$_trace_out"
assert_no_loader_leaks 'platform-skipped optional dependency'

run_loader platform_edge_required "platform_edge_optional_$_edge_suffix platform_edge_root_$_edge_suffix" strict ordinary
assert_eq 'strict fails when a platform skip is required through a later edge' 1 "$_status"
assert_contains 'required platform skip diagnostic names the skipped module' "$_err" "platform_edge_blocked_$_edge_blocked_suffix: unsupported platform"
assert_eq 'strict required platform skip runs no module bodies' '' "$_trace_out"
assert_no_loader_leaks 'strict required platform skip failure'

run_loader platform_edge_required_permissive "platform_edge_optional_$_edge_suffix platform_edge_root_$_edge_suffix" permissive ordinary
assert_eq 'permissive platform-required skip continues' 0 "$_status"
assert_contains 'permissive required platform skip still names the skipped module' "$_err" "platform_edge_blocked_$_edge_blocked_suffix: unsupported platform"
assert_eq 'permissive required platform skip loads the independent module only' "platform_edge_optional_$_edge_suffix" "$_trace_out"
assert_no_loader_leaks 'permissive required platform skip'

# A module discovered through an optional edge keeps its own required child
# when a later edge makes the module required. The topological failure must
# fail strict mode even though the child was walked before that promotion.
run_loader required_edge_missing "required_edge_optional required_edge_root" strict ordinary
assert_eq 'strict fails when a required edge is discovered after an optional one' 1 "$_status"
assert_contains 'required-edge failure names the missing leaf' "$_err" 'missing_edge_leaf'
assert_eq 'strict required-edge failure runs no module bodies' '' "$_trace_out"
assert_no_loader_leaks 'strict required-edge failure'

# The fixpoint matters one level deeper: the required module's own required
# child was walked while the parent was still optional, so the closure must
# re-walk it before deciding whether the platform skip is reportable.
run_loader platform_nested "platform_nested_optional_$_edge_suffix platform_nested_root_$_edge_suffix" strict ordinary
assert_eq 'strict fails for a platform skip under a promoted required module' 1 "$_status"
assert_contains 'nested platform skip diagnostic names the skipped module' "$_err" "platform_edge_blocked_$_edge_blocked_suffix: unsupported platform"
assert_eq 'strict nested platform skip runs no module bodies' '' "$_trace_out"
assert_no_loader_leaks 'strict nested platform skip'

printf '\n=== Loader reload contract ===\n'
_reload_trace="$_tmp/reload.trace"
: >"$_reload_trace"
_reload_out=$(
  . "$METADATA_SH" || exit 91
  . "$LOADER_SH" || exit 92
  SP_LOADER_TEST_TRACE=$_reload_trace
  SP_LOADER_TEST_RELOAD_STAGE=first
  export SP_LOADER_TEST_TRACE SP_LOADER_TEST_RELOAD_STAGE
  sp_loader_load_modules "$FIXTURE_ROOT" 'core reload_probe' strict ordinary || exit 1
  _reload_first=$(reload_probe_loaded 2>/dev/null) || _reload_first=missing
  SP_LOADER_TEST_RELOAD_STAGE=second
  export SP_LOADER_TEST_RELOAD_STAGE
  VALISE_RELOAD=1
  export VALISE_RELOAD
  . "$LOADER_SH" || exit 2
  sp_loader_load_modules "$FIXTURE_ROOT" 'core reload_probe' strict ordinary || exit 3
  _reload_second=$(reload_probe_loaded 2>/dev/null) || _reload_second=missing
  printf 'RELOAD_FIRST=%s\nRELOAD_SECOND=%s\n' "$_reload_first" "$_reload_second"
) 2>"$_tmp/reload.stderr"
_reload_status=$?
_reload_err=$(cat "$_tmp/reload.stderr")
assert_eq 'VALISE_RELOAD=1 re-sources an already loaded closure' 0 "$_reload_status"
assert_eq 'VALISE_RELOAD=1 replaces declared exports from the closure' \
  $'RELOAD_FIRST=first\nRELOAD_SECOND=second' "$_reload_out"
assert_eq 'VALISE_RELOAD=1 re-load emits no diagnostic' '' "$_reload_err"
unset _reload_trace _reload_out _reload_status _reload_err

printf '\n=== loader-failure-modes summary ===\n'
printf 'Total: %d  Pass: %d  XFail: %d  Fail: %d\n' "$_total" "$_pass" "$_xfail" "$_fail"

[ "$_fail" -eq 0 ]
