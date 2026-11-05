#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Metadata ABI contract tests for shell-profile module discovery.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

assert_eq() {
  _total=$((_total + 1))
  _label="$1"
  _expected="$2"
  _actual="$3"
  if [ "$_expected" = "$_actual" ]; then
    pass "$_label"
  else
    fail "$_label" "expected: $_expected; actual: $_actual"
  fi
}

assert_contains() {
  _total=$((_total + 1))
  _label="$1"
  _haystack="$2"
  _needle="$3"
  case "$_haystack" in
  *"$_needle"*) pass "$_label" ;;
  *) fail "$_label" "missing: $_needle" ;;
  esac
}

assert_not_exists() {
  _total=$((_total + 1))
  _label="$1"
  _path="$2"
  if [ ! -e "$_path" ]; then
    pass "$_label"
  else
    fail "$_label" "unexpected path exists: $_path"
  fi
}

assert_exit() {
  _total=$((_total + 1))
  _label="$1"
  _expected="$2"
  _actual="$3"
  if [ "$_expected" = "$_actual" ]; then
    pass "$_label (exit $_actual)"
  else
    fail "$_label" "expected exit: $_expected; actual exit: $_actual"
  fi
}

run_read() {
  _out=$(sp_metadata_read "$1" 2>&1)
  _status=$?
}

printf '\n=== Metadata ABI library presence ===\n'
_total=$((_total + 1))
if [ -f "$METADATA_SH" ]; then
  pass 'metadata library exists'
  # shellcheck disable=SC1090
  . "$METADATA_SH"
else
  fail 'metadata library exists' "$METADATA_SH"
fi

for _fn in sp_metadata_read sp_metadata_validate_identifier sp_metadata_validate_source_side_effect; do
  _total=$((_total + 1))
  if type "$_fn" >/dev/null 2>&1; then
    pass "metadata function exists: $_fn"
  else
    fail "metadata function exists: $_fn"
  fi
done
unset _fn

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-metadata.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

printf '\n=== Metadata ABI valid record parsing ===\n'
_valid="$_tmp/path_utilities.meta"
cat >"$_valid" <<'META'
# comments and blank lines are ignored

name=path_utilities
requires=core_environment secure_local_bin
optional=osm
shells=posix bash zsh ksh
platforms=any darwin linux bsd
side_effect=path-env
exports=pathcontains pathappend pathprepend
commands=pathcontains
executables=bin/path-report tools/path_audit.sh
tests=tests/path_utilities.sh
load=modules/core/path_utilities.sh
META
run_read "$_valid"
assert_exit 'valid metadata parses' 0 "$_status"
assert_contains 'valid metadata emits module name' "$_out" 'name=path_utilities'
assert_contains 'valid metadata emits dependencies' "$_out" 'requires=core_environment secure_local_bin'
assert_contains 'valid metadata emits shells' "$_out" 'shells=posix bash zsh ksh'
assert_contains 'valid metadata emits side effect class' "$_out" 'side_effect=path-env'
assert_contains 'valid metadata emits published commands' "$_out" 'commands=pathcontains'
assert_contains 'valid metadata emits executables' "$_out" 'executables=bin/path-report tools/path_audit.sh'
assert_contains 'valid metadata emits tests' "$_out" 'tests=tests/path_utilities.sh'
assert_contains 'valid metadata emits load path' "$_out" 'load=modules/core/path_utilities.sh'
assert_contains 'unversioned metadata emits empty version' "$_out" 'version='

printf '\n=== Metadata meta-module records ===\n'
_meta_module="$_tmp/meta_module.meta"
cat >"$_meta_module" <<'META'
name=meta_module
requires=core_environment
optional=
shells=posix
platforms=any
side_effect=read-only
exports=
META
run_read "$_meta_module"
assert_exit 'metadata accepts a dependency-only meta module without a load target' 0 "$_status"
assert_contains 'meta module emits its dependency closure' "$_out" 'requires=core_environment'
assert_contains 'meta module emits an empty load target' "$_out" 'load='

_no_body_no_deps="$_tmp/no_body_no_deps.meta"
cat >"$_no_body_no_deps" <<'META'
name=no_body_no_deps
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=
META
run_read "$_no_body_no_deps"
assert_exit 'metadata rejects a module with no body and no dependencies' 1 "$_status"
assert_contains 'missing load target diagnostic names the alternatives' "$_out" 'load or requires'

_optional_only_no_load="$_tmp/optional_only_no_load.meta"
cat >"$_optional_only_no_load" <<'META'
name=optional_only_no_load
requires=
optional=core_environment
shells=posix
platforms=any
side_effect=read-only
exports=
META
run_read "$_optional_only_no_load"
assert_exit 'metadata rejects an optional-only module without a load target' 1 "$_status"
assert_contains 'optional-only diagnostic names the load-target alternatives' "$_out" 'load or requires'

printf '\n=== Metadata version field ===\n'
_versioned="$_tmp/versioned.meta"
cat >"$_versioned" <<'META'
name=versioned_probe
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=versioned_probe
version=2.1.0-rc1
load=modules/core/versioned_probe.sh
META
run_read "$_versioned"
assert_exit 'versioned metadata parses' 0 "$_status"
assert_contains 'versioned metadata emits version' "$_out" 'version=2.1.0-rc1'
for _bad_version in v1 '1.0 beta' '1.*' '-1' '-rc1'; do
  _bad_version_meta="$_tmp/bad-version.meta"
  cat >"$_bad_version_meta" <<META
name=bad_version
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_version
version=$_bad_version
load=modules/core/bad_version.sh
META
  run_read "$_bad_version_meta"
  assert_exit "metadata rejects version: $_bad_version" 1 "$_status"
  assert_contains "version diagnostic is explicit: $_bad_version" "$_out" 'invalid version'
done
unset _bad_version _bad_version_meta _versioned

printf '\n=== Metadata validators tolerate unset IFS under nounset ===\n'
_out=$(bash -uc '. "$1"; unset IFS; sp_metadata_read "$2"' _ "$METADATA_SH" "$_valid" 2>&1)
_status=$?
assert_exit 'valid metadata parses when caller IFS is unset under nounset' 0 "$_status"
assert_contains 'unset-IFS metadata read emits module name' "$_out" 'name=path_utilities'
_out=$(bash -uc '. "$1"; unset IFS; sp_metadata_validate_identifier_list "dep" dependency; case "${IFS+x}" in x) printf set ;; *) printf unset ;; esac' _ "$METADATA_SH" 2>&1)
_status=$?
assert_exit 'identifier list accepts valid value with unset IFS under nounset' 0 "$_status"
assert_eq 'identifier list restores unset IFS after success' 'unset' "$_out"
_out=$(bash -uc '. "$1"; unset IFS; if sp_metadata_validate_identifier_list "bad/name" dependency >/dev/null 2>&1; then printf unexpected; else case "${IFS+x}" in x) printf set ;; *) printf unset ;; esac; fi' _ "$METADATA_SH" 2>&1)
_status=$?
assert_exit 'identifier list rejects invalid value with unset IFS under nounset' 0 "$_status"
assert_eq 'identifier list restores unset IFS after failure' 'unset' "$_out"
_out=$(bash -uc '. "$1"; unset IFS; sp_metadata_validate_shell_list "sh bash"; case "${IFS+x}" in x) printf set ;; *) printf unset ;; esac' _ "$METADATA_SH" 2>&1)
_status=$?
assert_exit 'shell list accepts valid value with unset IFS under nounset' 0 "$_status"
assert_eq 'shell list restores unset IFS after success' 'unset' "$_out"
_out=$(bash -uc '. "$1"; unset IFS; sp_metadata_validate_platform_list "any darwin"; case "${IFS+x}" in x) printf set ;; *) printf unset ;; esac' _ "$METADATA_SH" 2>&1)
_status=$?
assert_exit 'platform list accepts valid value with unset IFS under nounset' 0 "$_status"
assert_eq 'platform list restores unset IFS after success' 'unset' "$_out"

printf '\n=== Metadata discovery does not execute module body ===\n'
_marker="$_tmp/body-executed"
_module_body="$_tmp/modules/core/no_exec_probe.sh"
mkdir -p "$(dirname "$_module_body")"
cat >"$_module_body" <<BODY
printf 'body executed\n' >'$_marker'
BODY
_no_exec_meta="$_tmp/no_exec_probe.meta"
cat >"$_no_exec_meta" <<META
name=no_exec_probe
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=no_exec_probe
load=modules/core/no_exec_probe.sh
META
_out=$(cd "$_tmp" && sp_metadata_read "$_no_exec_meta" 2>&1)
_status=$?
assert_exit 'metadata read with load path succeeds without sourcing body' 0 "$_status"
assert_not_exists 'metadata discovery does not execute module body' "$_marker"

printf '\n=== Metadata ABI validation failures ===\n'
_bad_name="$_tmp/bad-name.meta"
cat >"$_bad_name" <<'META'
name=bad/name
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_name
load=modules/core/bad_name.sh
META
run_read "$_bad_name"
assert_exit 'metadata rejects module name with path separator' 1 "$_status"
assert_contains 'invalid module name diagnostic is explicit' "$_out" 'invalid module name'

_bad_dep="$_tmp/bad-dep.meta"
cat >"$_bad_dep" <<'META'
name=bad_dep
requires=core ok/escape 'quoted'
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_dep
load=modules/core/bad_dep.sh
META
run_read "$_bad_dep"
assert_exit 'metadata rejects dependency identifiers with slash or quotes' 1 "$_status"
assert_contains 'invalid dependency diagnostic is explicit' "$_out" 'invalid dependency'

_bad_side="$_tmp/bad-side-effect.meta"
cat >"$_bad_side" <<'META'
name=bad_side_effect
requires=
optional=
shells=posix
platforms=any
side_effect=network
exports=bad_side_effect
load=modules/core/bad_side_effect.sh
META
run_read "$_bad_side"
assert_exit 'metadata rejects unknown side-effect class' 1 "$_status"
assert_contains 'invalid side-effect diagnostic is explicit' "$_out" 'invalid side_effect'

_bad_update="$_tmp/bad-update.meta"
cat >"$_bad_update" <<'META'
name=bad_update
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_update
updates=
load=modules/core/bad_update.sh
META
run_read "$_bad_update"
assert_exit 'metadata rejects the removed updates field' 1 "$_status"
assert_contains 'removed updates diagnostic names the release' "$_out" 'metadata field updates is not supported since valise 0.3.0'

printf '\n=== Metadata duplicate fields and 0.3.0 fields ===\n'
write_field_meta() {
  _wf_target="$_tmp/$1.meta"
  shift
  {
    printf '%s\n' 'name=field_probe' 'requires=' 'optional=' 'shells=posix' 'platforms=any' \
      'side_effect=read-only' 'exports=field_probe field_other' 'load=modules/field_probe.sh'
    for _wf_line do printf '%s\n' "$_wf_line"; done
  } >"$_wf_target"
}
write_field_meta duplicate-key 'exports=field_probe'
run_read "$_wf_target"
assert_exit 'metadata rejects a duplicate field' 1 "$_status"
assert_contains 'duplicate field diagnostic names the field' "$_out" 'duplicate metadata field: exports'
write_field_meta command-not-export 'commands=field_probe not_exported'
run_read "$_wf_target"
assert_exit 'metadata rejects a command that is not an export' 1 "$_status"
assert_contains 'command diagnostic names the command' "$_out" 'command is not a declared export: not_exported'
write_field_meta command-ok 'commands=field_probe field_other'
run_read "$_wf_target"
assert_exit 'metadata accepts commands drawn from exports' 0 "$_status"
for _wf_bad in '/abs/tool' '../tool' 'bin/../tool' './tool' 'bin//tool' 'bin/' 'bin/.' 'bin/-tool' 'bin/t*ol'; do
  write_field_meta bad-executable "executables=$_wf_bad"
  run_read "$_wf_target"
  assert_exit "metadata rejects executable path $_wf_bad" 1 "$_status"
  assert_contains "executable diagnostic for $_wf_bad is explicit" "$_out" 'invalid'
done
for _wf_bad in '/abs/test.sh' '../test.sh' 'tests//t.sh'; do
  write_field_meta bad-test "tests=$_wf_bad"
  run_read "$_wf_target"
  assert_exit "metadata rejects test path $_wf_bad" 1 "$_status"
done
for _wf_shells in 'posix' 'sh' 'sh bash ksh' 'posix fish'; do
  write_field_meta shell-class
  sed "s/^shells=.*/shells=$_wf_shells/" "$_wf_target" >"$_wf_target.tmp" && mv "$_wf_target.tmp" "$_wf_target"
  run_read "$_wf_target"
  assert_exit "metadata accepts shells=$_wf_shells" 0 "$_status"
done
unset _wf_target _wf_line _wf_bad _wf_shells

_glob_cwd="$_tmp/glob-cwd"
mkdir -p "$_glob_cwd"
touch "$_glob_cwd/dep" "$_glob_cwd/sh" "$_glob_cwd/any" "$_glob_cwd/export" "$_glob_cwd/upd"
_bad_glob="$_tmp/bad-glob.meta"
cat >"$_bad_glob" <<'META'
name=bad_glob
requires=[d]ep
optional=
shells=[s]h
platforms=[a]ny
side_effect=read-only
exports=[e]xport
commands=[u]pd
load=modules/core/bad_glob.sh
META
_out=$(cd "$_glob_cwd" && sp_metadata_read "$_bad_glob" 2>&1)
_status=$?
assert_exit 'metadata rejects glob metacharacters before pathname expansion' 1 "$_status"
assert_contains 'glob rejection diagnostic is explicit' "$_out" 'invalid dependency'

write_control_meta() {
  _field=$1
  _value=$2
  _target="$_tmp/control-$_field.meta"
  {
    printf '%s\n' 'name=control_probe'
    if [ "$_field" = requires ]; then printf 'requires=%s\n' "$_value"; else printf '%s\n' 'requires='; fi
    if [ "$_field" = optional ]; then printf 'optional=%s\n' "$_value"; else printf '%s\n' 'optional='; fi
    if [ "$_field" = shells ]; then printf 'shells=%s\n' "$_value"; else printf '%s\n' 'shells=posix'; fi
    if [ "$_field" = platforms ]; then printf 'platforms=%s\n' "$_value"; else printf '%s\n' 'platforms=any'; fi
    printf '%s\n' 'side_effect=read-only'
    if [ "$_field" = exports ]; then printf 'exports=%s\n' "$_value"; else printf '%s\n' 'exports=control_probe'; fi
    if [ "$_field" = commands ]; then printf 'commands=%s\n' "$_value"; else printf '%s\n' 'commands='; fi
    printf '%s\n' 'load=modules/core/control_probe.sh'
  } >"$_target"
}

_tab=$(printf '\t')
for _control_field in requires optional shells platforms exports commands; do
  write_control_meta "$_control_field" "ok${_tab}evil"
  run_read "$_target"
  assert_exit "metadata rejects tab control character in $_control_field" 1 "$_status"
  assert_contains "control-character diagnostic names $_control_field" "$_out" "invalid $_control_field"
done
for _space_field in requires optional exports commands; do
  write_control_meta "$_space_field" ' '
  run_read "$_target"
  case "$_space_field" in
  requires) _space_label=dependency ;;
  optional) _space_label=optional_dependency ;;
  exports) _space_label=export ;;
  commands) _space_label=command ;;
  esac
  assert_exit "metadata rejects whitespace-only $_space_field list" 1 "$_status"
  assert_contains "whitespace-only $_space_field diagnostic is explicit" "$_out" "invalid $_space_label"
done
write_control_meta shells ' '
run_read "$_target"
assert_exit 'metadata rejects whitespace-only required shells list' 1 "$_status"
assert_contains 'whitespace-only shells diagnostic is explicit' "$_out" 'missing required metadata field: shells'
write_control_meta platforms ' '
run_read "$_target"
assert_exit 'metadata rejects whitespace-only required platforms list' 1 "$_status"
assert_contains 'whitespace-only platforms diagnostic is explicit' "$_out" 'missing required metadata field: platforms'
unset _control_field _space_field _space_label _tab _field _value _target

_bad_ifs_dep="$_tmp/bad-ifs-dep.meta"
cat >"$_bad_ifs_dep" <<'META'
name=bad_ifs_dep
requires=ok/escape
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_ifs_dep
load=modules/core/bad_ifs_dep.sh
META
_out=$(IFS=/; sp_metadata_read "$_bad_ifs_dep" 2>&1)
_status=$?
assert_exit 'metadata rejects dependency path separator with hostile IFS' 1 "$_status"
assert_contains 'hostile IFS dependency diagnostic is explicit' "$_out" 'invalid dependency'

_bad_ifs_update="$_tmp/bad-ifs-update.meta"
cat >"$_bad_ifs_update" <<'META'
name=bad_ifs_update
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_ifs_update
commands=bad-update
load=modules/core/bad_ifs_update.sh
META
_out=$(IFS=-; sp_metadata_read "$_bad_ifs_update" 2>&1)
_status=$?
assert_exit 'metadata rejects command hyphen with hostile IFS' 1 "$_status"
assert_contains 'hostile IFS command diagnostic is explicit' "$_out" 'invalid command'

_bad_ifs_shell="$_tmp/bad-ifs-shell.meta"
cat >"$_bad_ifs_shell" <<'META'
name=bad_ifs_shell
requires=
optional=
shells=bash-zsh
platforms=any
side_effect=read-only
exports=bad_ifs_shell
load=modules/core/bad_ifs_shell.sh
META
_out=$(IFS=-; sp_metadata_read "$_bad_ifs_shell" 2>&1)
_status=$?
assert_exit 'metadata rejects shell enum with hostile IFS' 1 "$_status"
assert_contains 'hostile IFS shell diagnostic is explicit' "$_out" 'invalid shell'

_missing_required="$_tmp/missing-required.meta"
cat >"$_missing_required" <<'META'
name=missing_required
requires=
optional=
shells=posix
platforms=any
exports=missing_required
load=modules/core/missing_required.sh
META
run_read "$_missing_required"
assert_exit 'metadata rejects missing required fields' 1 "$_status"
assert_contains 'missing required field diagnostic is explicit' "$_out" 'missing required metadata field: side_effect'

_bad_load_hook="$_tmp/bad-load-hook.meta"
cat >"$_bad_load_hook" <<'META'
name=bad_load_hook
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=bad_load_hook
load=
load_hook=bad/hook
META
run_read "$_bad_load_hook"
assert_exit 'metadata rejects the retired load_hook field' 1 "$_status"
assert_contains 'load_hook diagnostic points at load' "$_out" 'metadata field load_hook is not supported; use load'

_ambiguous_load="$_tmp/ambiguous-load.meta"
cat >"$_ambiguous_load" <<'META'
name=ambiguous_load
requires=
optional=
shells=posix
platforms=any
side_effect=read-only
exports=ambiguous_load
load=modules/core/ambiguous_load.sh
load_hook=_shell_module_ambiguous_load
META
run_read "$_ambiguous_load"
assert_exit 'metadata rejects load_hook even beside load' 1 "$_status"
assert_contains 'load_hook beside load diagnostic points at load' "$_out" 'metadata field load_hook is not supported; use load'

for _retired_field in unload failure_policy; do
  _retired_meta="$_tmp/retired-$_retired_field.meta"
  {
    printf '%s\n' 'name=retired_field'
    printf '%s\n' 'requires='
    printf '%s\n' 'optional='
    printf '%s\n' 'shells=posix'
    printf '%s\n' 'platforms=any'
    printf '%s\n' 'side_effect=read-only'
    printf '%s\n' 'exports=retired_field'
    printf '%s\n' 'load=modules/core/retired_field.sh'
    printf '%s=%s\n' "$_retired_field" retired
  } >"$_retired_meta"
  run_read "$_retired_meta"
  assert_exit "metadata rejects retired $_retired_field field" 1 "$_status"
  assert_contains "retired $_retired_field diagnostic is explicit" \
    "$_out" "unknown metadata field: $_retired_field"
done
unset _retired_field _retired_meta

printf '\n=== Source-phase side-effect enforcement ===\n'
_out=$(sp_metadata_validate_source_side_effect read-only 2>&1)
_status=$?
assert_exit 'ordinary source permits read-only side-effect class' 0 "$_status"
_out=$(sp_metadata_validate_source_side_effect path-env 2>&1)
_status=$?
assert_exit 'ordinary source permits path-env side-effect class' 0 "$_status"
_out=$(sp_metadata_validate_source_side_effect local-state 2>&1)
_status=$?
assert_exit 'ordinary source permits local-state side-effect class' 0 "$_status"
_out=$(sp_metadata_validate_source_side_effect generated-file 2>&1)
_status=$?
assert_exit 'ordinary source rejects generated-file side-effect class' 1 "$_status"
assert_contains 'generated-file source rejection diagnostic is explicit' "$_out" 'side_effect not allowed during ordinary source: generated-file'
_out=$(sp_metadata_validate_source_side_effect update-network 2>&1)
_status=$?
assert_exit 'ordinary source rejects update-network side-effect class' 1 "$_status"
assert_contains 'update-network source rejection diagnostic is explicit' "$_out" 'side_effect not allowed during ordinary source: update-network'
_out=$(sp_metadata_validate_source_side_effect install-time 2>&1)
_status=$?
assert_exit 'ordinary source rejects install-time side-effect class' 1 "$_status"
assert_contains 'install-time source rejection diagnostic is explicit' "$_out" 'side_effect not allowed during ordinary source: install-time'

printf '\n=== metadata-abi summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
