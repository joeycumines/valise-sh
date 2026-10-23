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

run_bridge() {
  _out=$(sp_metadata_legacy_bridge "$@" 2>&1)
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

for _fn in sp_metadata_read sp_metadata_legacy_bridge sp_metadata_validate_identifier sp_metadata_validate_source_side_effect; do
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
shells=sh bash zsh ksh
platforms=any darwin linux bsd
side_effect=path-env
exports=pathcontains pathappend pathprepend
updates=get_toml_table_value git_file_log_extractor
load=modules/core/path_utilities.sh
META
run_read "$_valid"
assert_exit 'valid metadata parses' 0 "$_status"
assert_contains 'valid metadata emits module name' "$_out" 'name=path_utilities'
assert_contains 'valid metadata emits dependencies' "$_out" 'requires=core_environment secure_local_bin'
assert_contains 'valid metadata emits shells' "$_out" 'shells=sh bash zsh ksh'
assert_contains 'valid metadata emits side effect class' "$_out" 'side_effect=path-env'
assert_contains 'valid metadata emits update registrations' "$_out" 'updates=get_toml_table_value git_file_log_extractor'
assert_contains 'valid metadata emits load path' "$_out" 'load=modules/core/path_utilities.sh'
assert_contains 'unversioned metadata emits empty version' "$_out" 'version='

printf '\n=== Metadata meta-module records ===\n'
_meta_module="$_tmp/meta_module.meta"
cat >"$_meta_module" <<'META'
name=meta_module
requires=core_environment
optional=
shells=sh
platforms=any
side_effect=read-only
exports=
updates=
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
shells=sh
platforms=any
side_effect=read-only
exports=
updates=
META
run_read "$_no_body_no_deps"
assert_exit 'metadata rejects a module with no body and no dependencies' 1 "$_status"
assert_contains 'missing load target diagnostic names the alternatives' "$_out" 'load, load_hook, or requires'

_optional_only_no_load="$_tmp/optional_only_no_load.meta"
cat >"$_optional_only_no_load" <<'META'
name=optional_only_no_load
requires=
optional=core_environment
shells=sh
platforms=any
side_effect=read-only
exports=
updates=
META
run_read "$_optional_only_no_load"
assert_exit 'metadata rejects an optional-only module without a load target' 1 "$_status"
assert_contains 'optional-only diagnostic names the load-target alternatives' "$_out" 'load, load_hook, or requires'

printf '\n=== Metadata version field ===\n'
_versioned="$_tmp/versioned.meta"
cat >"$_versioned" <<'META'
name=versioned_probe
requires=
optional=
shells=sh
platforms=any
side_effect=read-only
exports=versioned_probe
updates=
version=2.1.0-rc1
load=modules/core/versioned_probe.sh
META
run_read "$_versioned"
assert_exit 'versioned metadata parses' 0 "$_status"
assert_contains 'versioned metadata emits version' "$_out" 'version=2.1.0-rc1'
run_bridge versioned_bridge dep read-only versioned_bridge
assert_exit 'legacy bridge serializes' 0 "$_status"
assert_contains 'legacy bridge emits empty version' "$_out" 'version='
for _bad_version in v1 '1.0 beta' '1.*' '-1' '-rc1'; do
  _bad_version_meta="$_tmp/bad-version.meta"
  cat >"$_bad_version_meta" <<META
name=bad_version
requires=
optional=
shells=sh
platforms=any
side_effect=read-only
exports=bad_version
updates=
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
_out=$(bash -uc '. "$1"; unset IFS; sp_metadata_legacy_bridge bridge_probe dep read-only bridge_probe' _ "$METADATA_SH" 2>&1)
_status=$?
assert_exit 'legacy bridge serializes when caller IFS is unset under nounset' 0 "$_status"
assert_contains 'unset-IFS legacy bridge emits load hook' "$_out" 'load_hook=_shell_module_bridge_probe'
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
shells=sh
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
shells=sh
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
shells=sh
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
shells=sh
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
shells=sh
platforms=any
side_effect=read-only
exports=bad_update
updates=ok_update ../escape
load=modules/core/bad_update.sh
META
run_read "$_bad_update"
assert_exit 'metadata rejects unsafe update registration identifiers' 1 "$_status"
assert_contains 'invalid update registration diagnostic is explicit' "$_out" 'invalid update_registration'

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
updates=[u]pd
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
    if [ "$_field" = shells ]; then printf 'shells=%s\n' "$_value"; else printf '%s\n' 'shells=sh'; fi
    if [ "$_field" = platforms ]; then printf 'platforms=%s\n' "$_value"; else printf '%s\n' 'platforms=any'; fi
    printf '%s\n' 'side_effect=read-only'
    if [ "$_field" = exports ]; then printf 'exports=%s\n' "$_value"; else printf '%s\n' 'exports=control_probe'; fi
    if [ "$_field" = updates ]; then printf 'updates=%s\n' "$_value"; else printf '%s\n' 'updates='; fi
    printf '%s\n' 'load=modules/core/control_probe.sh'
  } >"$_target"
}

_tab=$(printf '\t')
for _control_field in requires optional shells platforms exports updates; do
  write_control_meta "$_control_field" "ok${_tab}evil"
  run_read "$_target"
  assert_exit "metadata rejects tab control character in $_control_field" 1 "$_status"
  assert_contains "control-character diagnostic names $_control_field" "$_out" "invalid $_control_field"
done
for _space_field in requires optional exports updates; do
  write_control_meta "$_space_field" ' '
  run_read "$_target"
  case "$_space_field" in
  requires) _space_label=dependency ;;
  optional) _space_label=optional_dependency ;;
  exports) _space_label=export ;;
  updates) _space_label=update_registration ;;
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
shells=sh
platforms=any
side_effect=read-only
exports=bad_ifs_dep
updates=
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
shells=sh
platforms=any
side_effect=read-only
exports=bad_ifs_update
updates=bad-update
load=modules/core/bad_ifs_update.sh
META
_out=$(IFS=-; sp_metadata_read "$_bad_ifs_update" 2>&1)
_status=$?
assert_exit 'metadata rejects update hyphen with hostile IFS' 1 "$_status"
assert_contains 'hostile IFS update diagnostic is explicit' "$_out" 'invalid update_registration'

_bad_ifs_shell="$_tmp/bad-ifs-shell.meta"
cat >"$_bad_ifs_shell" <<'META'
name=bad_ifs_shell
requires=
optional=
shells=bash-zsh
platforms=any
side_effect=read-only
exports=bad_ifs_shell
updates=
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
shells=sh
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
shells=sh
platforms=any
side_effect=read-only
exports=bad_load_hook
load=
load_hook=bad/hook
META
run_read "$_bad_load_hook"
assert_exit 'metadata rejects unsafe load_hook identifiers' 1 "$_status"
assert_contains 'invalid load_hook diagnostic is explicit' "$_out" 'invalid load_hook'

_ambiguous_load="$_tmp/ambiguous-load.meta"
cat >"$_ambiguous_load" <<'META'
name=ambiguous_load
requires=
optional=
shells=sh
platforms=any
side_effect=read-only
exports=ambiguous_load
load=modules/core/ambiguous_load.sh
load_hook=_shell_module_ambiguous_load
META
run_read "$_ambiguous_load"
assert_exit 'metadata rejects simultaneous load and load_hook targets' 1 "$_status"
assert_contains 'ambiguous load target diagnostic is explicit' "$_out" 'load and load_hook are mutually exclusive'

for _retired_field in unload failure_policy; do
  _retired_meta="$_tmp/retired-$_retired_field.meta"
  {
    printf '%s\n' 'name=retired_field'
    printf '%s\n' 'requires='
    printf '%s\n' 'optional='
    printf '%s\n' 'shells=sh'
    printf '%s\n' 'platforms=any'
    printf '%s\n' 'side_effect=read-only'
    printf '%s\n' 'exports=retired_field'
    printf '%s\n' 'updates='
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

printf '\n=== Legacy compatibility bridge serialization ===\n'
run_bridge remote_script_manager 'secure_local_bin' update-network 'remote_script_fetch remote_script_update remote_script_update_all remote_script_check remote_script_status'
assert_exit 'legacy bridge serializes existing module metadata' 0 "$_status"
assert_contains 'legacy bridge emits module name' "$_out" 'name=remote_script_manager'
assert_contains 'legacy bridge emits dependencies' "$_out" 'requires=secure_local_bin'
assert_contains 'legacy bridge emits side-effect class' "$_out" 'side_effect=update-network'
assert_contains 'legacy bridge emits legacy load hook' "$_out" 'load_hook=_shell_module_remote_script_manager'
assert_contains 'legacy bridge emits exported commands' "$_out" 'exports=remote_script_fetch remote_script_update remote_script_update_all remote_script_check remote_script_status'
_bridge_meta="$_tmp/bridge.meta"
printf '%s\n' "$_out" >"$_bridge_meta"
run_read "$_bridge_meta"
assert_exit 'legacy bridge output round-trips through metadata reader' 0 "$_status"
assert_contains 'round-tripped bridge keeps load hook' "$_out" 'load_hook=_shell_module_remote_script_manager'
_tab=$(printf '\t')
run_bridge bridge_probe "dep${_tab}evil" read-only bridge_probe
assert_exit 'legacy bridge rejects tab control character in dependencies' 1 "$_status"
assert_contains 'legacy bridge dependency control diagnostic is explicit' "$_out" 'invalid dependency'
run_bridge bridge_probe dep read-only "export${_tab}evil"
assert_exit 'legacy bridge rejects tab control character in exports' 1 "$_status"
assert_contains 'legacy bridge export control diagnostic is explicit' "$_out" 'invalid export'
_out=$(IFS=/; sp_metadata_legacy_bridge bridge_probe 'ok/escape' read-only bridge_probe 2>&1)
_status=$?
assert_exit 'legacy bridge rejects dependency path separator with hostile IFS' 1 "$_status"
assert_contains 'legacy bridge hostile IFS dependency diagnostic is explicit' "$_out" 'invalid dependency'
unset _tab

printf '\n=== metadata-abi summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
