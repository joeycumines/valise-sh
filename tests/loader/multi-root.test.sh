#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Multi-root namespaced layer contract tests (T07).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"
LOADER_SH="$ROOT_DIR/lib/loader.sh"
T07_TEST_CHILD_SHELL=${T07_TEST_CHILD_SHELL:-/bin/bash}
T07_TEST_CHILD_SHELL_ARGS=${T07_TEST_CHILD_SHELL_ARGS:-}
T07_TEST_CHILD_PATH=${T07_TEST_CHILD_PATH:-${PATH:-}}
[ -x "$T07_TEST_CHILD_SHELL" ] || { printf 'FAIL: T07_TEST_CHILD_SHELL is not executable: %s\n' "$T07_TEST_CHILD_SHELL" >&2; exit 1; }
[ -n "$T07_TEST_CHILD_PATH" ] || { printf 'FAIL: T07_TEST_CHILD_PATH must not be empty\n' >&2; exit 1; }
PRIMARY_ROOT="$ROOT_DIR/tests/fixtures/modules/loader-failure-modes"

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

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

# run_case <name> <env-assignments> <wanted> <mode> — runs the loader in a
# fresh child shell (no cross-case export contamination) and captures status,
# stderr, and the module-body trace.
run_case() {
  _rc_name=$1
  _rc_env=$2
  _rc_wanted=$3
  _rc_mode=$4
  _rc_trace=$_tmp_dir/trace.$_rc_name
  _rc_stderr=$_tmp_dir/stderr.$_rc_name
  : >"$_rc_trace"
  _rc_status=0
  set -- "$T07_TEST_CHILD_SHELL"
  if [ -n "$T07_TEST_CHILD_SHELL_ARGS" ]; then
    set -- "$@" "$T07_TEST_CHILD_SHELL_ARGS"
  fi
  PATH="$T07_TEST_CHILD_PATH" \
  SP_LOADER_TEST_TRACE="$_rc_trace" \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" PRIMARY_ROOT="$PRIMARY_ROOT" \
    LAYER_ROOT="$_tmp_dir/layer" LAYER2_ROOT="$_tmp_dir/layer2" \
    UNREADABLE_ROOT="$_tmp_dir/unreadable" UNSEARCHABLE_ROOT="$_tmp_dir/unsearchable" \
    PRIMARY2_ROOT="$_tmp_dir/primary-extended" \
    HOOK_SRC="$_tmp_dir/hook.sh" \
    CONTROL_ROOT="$_tmp_dir/control
root" \
    "$@" -c "
      $_rc_env
      . \"\$METADATA_SH\"
      . \"\$LOADER_SH\"
      sp_loader_load_modules \"\$PRIMARY_ROOT\" '$_rc_wanted' '$_rc_mode' ordinary
    " 2>"$_rc_stderr"
  _rc_status=$?
  CASE_STATUS=$_rc_status
  CASE_STDERR=$(cat "$_rc_stderr")
  CASE_TRACE=$(cat "$_rc_trace")
  unset _rc_name _rc_env _rc_wanted _rc_mode _rc_trace _rc_stderr _rc_status _rc_shell_args
}

# write_layer_module <name> [requires]
write_layer_module() {
  _wl_name=$1
  _wl_requires=${2:-}
  mkdir -p "$_tmp_dir/layer/module.d" "$_tmp_dir/layer/modules"
  {
    printf 'name=%s\n' "$_wl_name"
    printf 'requires=%s\n' "$_wl_requires"
    printf 'optional=\n'
    printf 'shells=sh\n'
    printf 'platforms=any\n'
    printf 'side_effect=read-only\n'
    printf 'exports=%s_loaded\n' "$_wl_name"
    printf 'updates=\n'
    printf 'load=modules/%s.sh\n' "$_wl_name"
  } >"$_tmp_dir/layer/module.d/$_wl_name.meta"
  {
    printf 'printf "%%s\\n" %s >>"$SP_LOADER_TEST_TRACE"\n' "$_wl_name"
    printf '%s_loaded() { :; }\n' "$_wl_name"
  } >"$_tmp_dir/layer/modules/$_wl_name.sh"
  unset _wl_name _wl_requires
}

_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-multiroot.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp_dir" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

printf '\n=== loader multi-root layer contract ===\n'

# Contract 1: default behavior is unchanged — no search path set means
# single-root resolution exactly as before.
run_case default '' core strict
assert_eq 'unset search path loads primary-root module' 0 "$CASE_STATUS"
assert_eq 'unset search path executes primary module body' 'core' "$CASE_TRACE"

run_case empty_path 'VALISE_MODULE_PATH=' core strict
assert_eq 'empty VALISE_MODULE_PATH loads primary-root module' 0 "$CASE_STATUS"
assert_eq 'empty VALISE_MODULE_PATH executes primary module body' 'core' "$CASE_TRACE"

# Contract 2: a layer root providing a contrib_ module is loaded, and its
# body resolves relative to the layer root. Deterministic loader order is
# sort -u based, so contrib_hello sorts before core.
write_layer_module contrib_hello
run_case contrib_load "VALISE_MODULE_PATH=\$LAYER_ROOT" 'core contrib_hello' strict
assert_eq 'layer contrib module loads alongside primary modules' 0 "$CASE_STATUS"
assert_eq 'layer contrib module body executed from layer root' $'contrib_hello\ncore' "$CASE_TRACE"

# Contract 3: priority — the primary root wins for a name present in both
# roots only when bytes are identical; any byte difference is a hard error
# naming both paths, in every mode.
mkdir -p "$_tmp_dir/layer/module.d" "$_tmp_dir/layer/modules"
cp "$PRIMARY_ROOT/module.d/core.meta" "$_tmp_dir/layer/module.d/core.meta"
printf 'x' >>"$_tmp_dir/layer/module.d/core.meta"
run_case byte_conflict "VALISE_MODULE_PATH=\$LAYER_ROOT" core permissive
assert_eq 'same-name different-bytes module fails closed in permissive mode' 1 "$CASE_STATUS"
assert_contains 'byte-conflict diagnostic names the primary path' "$CASE_STDERR" \
  "$PRIMARY_ROOT/module.d/core.meta"
assert_contains 'byte-conflict diagnostic names the layer path' "$CASE_STDERR" \
  'layer/module.d/core.meta'
assert_eq 'byte-conflict prevents module body execution' '' "$CASE_TRACE"

run_case byte_conflict_strict "VALISE_MODULE_PATH=\$LAYER_ROOT" core strict
assert_eq 'same-name different-bytes module fails closed in strict mode' 1 "$CASE_STATUS"

# Contract 4: byte-identical duplicates across roots are redundant, not
# shadowing, and are rejected fail-closed as well.
mkdir -p "$_tmp_dir/layer/module.d" "$_tmp_dir/layer/modules"
cp "$PRIMARY_ROOT/module.d/core.meta" "$_tmp_dir/layer/module.d/core.meta"
cp "$PRIMARY_ROOT/modules/core.sh" "$_tmp_dir/layer/modules/core.sh"
run_case byte_identical "VALISE_MODULE_PATH=\$LAYER_ROOT" core permissive
assert_eq 'byte-identical meta+body duplicate resolves by priority' 0 "$CASE_STATUS"
assert_eq 'byte-identical duplicate executes the primary body' 'core' "$CASE_TRACE"

# Contract 5: the contrib_ prefix rule — layer modules outside the primary
# root must be contrib_-prefixed.
rm -f "$_tmp_dir/layer/module.d/core.meta" "$_tmp_dir/layer/modules/core.sh"
write_layer_module plain_name
run_case contrib_prefix "VALISE_MODULE_PATH=\$LAYER_ROOT" plain_name permissive
assert_eq 'non-contrib layer module name fails closed' 1 "$CASE_STATUS"
assert_contains 'contrib-prefix diagnostic names the layer' "$CASE_STDERR" \
  'must use the contrib_ name prefix'
assert_eq 'contrib-prefix violation prevents module body execution' '' "$CASE_TRACE"

# Contract 6: the removed SHELL_PROFILE_MODULE_PATH alias has no effect.
# Setting only the old name must not add a layer root.
write_layer_module contrib_alias
run_case removed_alias "SHELL_PROFILE_MODULE_PATH=\$LAYER_ROOT" contrib_alias strict
assert_eq 'removed SHELL_PROFILE_MODULE_PATH alias adds no layer root' 1 "$CASE_STATUS"
assert_contains 'removed-alias diagnostic names the module as missing' "$CASE_STDERR" \
  'metadata file missing'

# Contract 7: VALISE_MODULE_PATH is the only layer variable; the removed
# old name is ignored even when it points at a missing directory.
write_layer_module contrib_valise
write_layer_module contrib_shellpath
run_case both_vars \
  "VALISE_MODULE_PATH=\$LAYER_ROOT SHELL_PROFILE_MODULE_PATH=\$LAYER_ROOT/missing" \
  contrib_valise strict
assert_eq 'VALISE_MODULE_PATH works while the removed old name is ignored' 0 "$CASE_STATUS"

# Contract 8: the search path is validated fail-closed.
run_case empty_element "VALISE_MODULE_PATH=:" core permissive
assert_eq 'empty search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'empty-element diagnostic explains the requirement' "$CASE_STDERR" \
  'empty path element is forbidden'

run_case leading_empty_element "VALISE_MODULE_PATH=:\$LAYER_ROOT" core permissive
assert_eq 'leading empty search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'leading-empty diagnostic explains the requirement' "$CASE_STDERR" \
  'empty path element is forbidden'

run_case trailing_empty_element "VALISE_MODULE_PATH=\$LAYER_ROOT:" core permissive
assert_eq 'trailing empty search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'trailing-empty diagnostic explains the requirement' "$CASE_STDERR" \
  'empty path element is forbidden'

run_case consecutive_empty_element "VALISE_MODULE_PATH=\$LAYER_ROOT::\$LAYER2_ROOT" core permissive
assert_eq 'consecutive empty search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'consecutive-empty diagnostic explains the requirement' "$CASE_STDERR" \
  'empty path element is forbidden'

run_case missing_dir "VALISE_MODULE_PATH=\$LAYER_ROOT/does-not-exist" core permissive
assert_eq 'missing search-path directory fails closed' 1 "$CASE_STATUS"

# Contract 8b: layer roots and executable artifacts are physical paths. A
# symlink must not redirect metadata or module-body execution outside the root
# selected by VALISE_MODULE_PATH.
ln -s "$PRIMARY_ROOT" "$_tmp_dir/layer2"
run_case symlink_layer_root "VALISE_MODULE_PATH=\$LAYER2_ROOT" core permissive
assert_eq 'symlink layer root fails closed' 1 "$CASE_STATUS"
rm -f "$_tmp_dir/layer2"
ln -s "$PRIMARY_ROOT" "$_tmp_dir/layer2"
run_case symlink_layer_root_trailing "VALISE_MODULE_PATH=\$LAYER2_ROOT/" core permissive
assert_eq 'trailing-slash symlink layer root fails closed' 1 "$CASE_STATUS"
rm -f "$_tmp_dir/layer2"

mkdir -p "$_tmp_dir/ancestor-real" "$_tmp_dir/ancestor-link"
ln -s "$_tmp_dir/ancestor-real" "$_tmp_dir/ancestor-link/real-root"
run_case symlink_layer_ancestor "VALISE_MODULE_PATH=$_tmp_dir/ancestor-link/real-root" core permissive
assert_eq 'symlink ancestor layer root fails closed' 1 "$CASE_STATUS"

mkdir -p "$_tmp_dir/relative-parent/real-root/module.d" "$_tmp_dir/relative-parent/real-root/modules"
cp -R "$PRIMARY_ROOT"/. "$_tmp_dir/relative-parent/real-root/"
ln -s real-root "$_tmp_dir/relative-parent/link"
run_case symlink_relative_ancestor "cd \"\$TMPDIR/relative-parent\"; VALISE_MODULE_PATH=link/real-root" core permissive
assert_eq 'relative symlink ancestor layer root fails closed' 1 "$CASE_STATUS"

mkdir -p "$_tmp_dir/layer2/module.d" "$_tmp_dir/layer2/modules"
ln -s "$PRIMARY_ROOT/module.d/core.meta" "$_tmp_dir/layer2/module.d/contrib_symlink_meta.meta"
run_case symlink_metadata "VALISE_MODULE_PATH=\$LAYER2_ROOT" contrib_symlink_meta permissive
rm -rf "$_tmp_dir/layer2"
assert_eq 'symlink layer metadata fails closed' 1 "$CASE_STATUS"
assert_contains 'symlink metadata diagnostic identifies the path' "$CASE_STDERR" \
  'metadata path contains a symlink'

write_layer_module contrib_symlink_body
rm -f "$_tmp_dir/layer/modules/contrib_symlink_body.sh"
ln -s "$PRIMARY_ROOT/modules/core.sh" "$_tmp_dir/layer/modules/contrib_symlink_body.sh"
run_case symlink_body "VALISE_MODULE_PATH=\$LAYER_ROOT" contrib_symlink_body strict
assert_eq 'symlink layer body fails closed' 1 "$CASE_STATUS"
assert_contains 'symlink body diagnostic identifies the path' "$CASE_STDERR" \
  'load path contains a symlink'

mkdir -p "$_tmp_dir/symlink-component/module.d" "$_tmp_dir/symlink-component/modules"
ln -s "$PRIMARY_ROOT/modules" "$_tmp_dir/symlink-component/modules/redirected"
cat >"$_tmp_dir/symlink-component/module.d/contrib_symlink_component.meta" <<'META'
name=contrib_symlink_component
requires=
optional=
shells=sh
platforms=any
side_effect=read-only
exports=contrib_symlink_component_loaded
updates=
load=modules/redirected/core.sh
META
run_case symlink_body_component "VALISE_MODULE_PATH=$_tmp_dir/symlink-component" contrib_symlink_component strict
assert_eq 'symlink body path component fails closed' 1 "$CASE_STATUS"
assert_contains 'symlink body component diagnostic identifies the path' "$CASE_STDERR" \
  'load path contains a symlink'

mkdir -p "$_tmp_dir/layer*"
run_case glob_metachar "VALISE_MODULE_PATH=\$LAYER_ROOT*" core permissive
assert_eq 'glob metacharacter search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'glob-metachar diagnostic explains the requirement' "$CASE_STDERR" \
  'glob metacharacters are forbidden'

_control_root="$_tmp_dir/control
root"
mkdir -p "$_control_root"
run_case control_character 'VALISE_MODULE_PATH="$CONTROL_ROOT"' core permissive
assert_eq 'control-character search-path element fails closed' 1 "$CASE_STATUS"
assert_contains 'newline diagnostic explains the requirement' "$CASE_STDERR" \
  'newlines are forbidden'
unset _control_root

# Contract 9: layer modules may depend on primary-root modules; discovery
# crosses roots and the deterministic dependency order is preserved.
write_layer_module contrib_dep core
run_case cross_root_dep "VALISE_MODULE_PATH=\$LAYER_ROOT" contrib_dep strict
assert_eq 'layer module with primary-root dependency loads' 0 "$CASE_STATUS"
assert_eq 'cross-root dependency executes in dependency order' $'core\ncontrib_dep' "$CASE_TRACE"

# Contract 10: the duplicate-export fail-closed check stays global across
# roots — a layer module may not re-export a primary module's export.
mkdir -p "$_tmp_dir/layer/module.d" "$_tmp_dir/layer/modules"
{
  printf 'name=contrib_clash\nrequires=\noptional=\nshells=sh\nplatforms=any\n'
  printf 'side_effect=read-only\nexports=core_loaded\nupdates=\n'
  printf 'load=modules/contrib_clash.sh\n'
} >"$_tmp_dir/layer/module.d/contrib_clash.meta"
printf 'core_loaded() { :; }\n' >"$_tmp_dir/layer/modules/contrib_clash.sh"
run_case export_clash "VALISE_MODULE_PATH=\$LAYER_ROOT" 'core contrib_clash' strict
assert_eq 'cross-root duplicate export fails closed in strict mode' 1 "$CASE_STATUS"
assert_contains 'duplicate-export diagnostic names the export' "$CASE_STDERR" \
  'declared export already exists before load: core_loaded'

# Contract 11: no loader-private state leaks through multi-root loads.
# These two introspection probes intentionally use Bash compgen to inspect
# Bash's private variable/function namespaces. Functional run_case assertions
# above execute under the selected POSIX child shell; these harness-only probes
# remain in the default Bash lane and do not claim cross-shell execution.
_leak_check=$(
  SP_LOADER_TEST_TRACE="$_tmp_dir/leak-trace" \
  METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" PRIMARY_ROOT="$PRIMARY_ROOT" \
  LAYER_ROOT="$_tmp_dir/layer" VALISE_MODULE_PATH="$LAYER_ROOT" \
  /bin/bash -c '
    : >"$SP_LOADER_TEST_TRACE"
    . "$METADATA_SH"
    . "$LOADER_SH"
    sp_loader_load_modules "$PRIMARY_ROOT" contrib_dep strict ordinary >/dev/null 2>&1
    _leaked_spl_vars=$(compgen -A variable _spl_ 2>/dev/null | tr "\n" " ")
    _leaked_internal_funcs=$(compgen -A function _sp_loader_ 2>/dev/null | tr "\n" " ")
    printf "LEAKED=[%s][%s]\n" "$_leaked_spl_vars" "$_leaked_internal_funcs"
  '
)
assert_eq 'no loader-private variables leak after multi-root load' 'LEAKED=[][]' "$_leak_check"

_private_failure_check=$(
  METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" PRIMARY_ROOT="$PRIMARY_ROOT" \
  /bin/bash -c '
    . "$METADATA_SH"
    . "$LOADER_SH"
    sp_loader_load_modules "$PRIMARY_ROOT" core invalid ordinary >/dev/null 2>&1 || :
    _invalid_mode_leak=$(compgen -A function _sp_loader_path_is_physical 2>/dev/null || :)
    sp_loader_load_modules "$PRIMARY_ROOT" core strict invalid >/dev/null 2>&1 || :
    _invalid_phase_leak=$(compgen -A function _sp_loader_path_is_physical 2>/dev/null || :)
    printf "MODE=[%s] PHASE=[%s]\n" "$_invalid_mode_leak" "$_invalid_phase_leak"
  '
)
assert_eq 'loader physical-path helper does not leak on validation failures' \
  'MODE=[] PHASE=[]' "$_private_failure_check"
unset _private_failure_check

# Contract 12: VALISE-only layering — VALISE_MODULE_PATH set-but-empty
# selects single-root behavior, and the removed old alias has no effect.
write_layer_module contrib_strict ''
run_case set_empty_valise "VALISE_MODULE_PATH= SHELL_PROFILE_MODULE_PATH=\$LAYER_ROOT" contrib_strict strict
assert_eq 'set-but-empty VALISE_MODULE_PATH selects single-root behavior' 1 "$CASE_STATUS"
assert_contains 'set-but-empty VALISE diagnostic names the module as missing' "$CASE_STDERR" \
  'metadata file missing'

# Contract 12b: the same name with different valid versions across roots
# fails closed naming both versions, directing the consumer to vendor a
# single version. Equal versions keep the byte rule.
mkdir -p "$_tmp_dir/layer2/module.d" "$_tmp_dir/layer2/modules"
_skew_meta() {
  printf 'name=contrib_skew\nrequires=\noptional=\nshells=sh\nplatforms=any\nside_effect=read-only\nversion=%s\nexports=contrib_skew_loaded\nupdates=\nload=modules/contrib_skew.sh\n' "$1" >"$2"
}
_skew_meta 1.0.0 "$_tmp_dir/layer/module.d/contrib_skew.meta"
printf 'contrib_skew_loaded() { :; }\n' >"$_tmp_dir/layer/modules/contrib_skew.sh"
_skew_meta 2.0.0 "$_tmp_dir/layer2/module.d/contrib_skew.meta"
printf 'contrib_skew_loaded() { :; }\n' >"$_tmp_dir/layer2/modules/contrib_skew.sh"
run_case version_skew "VALISE_MODULE_PATH=\$LAYER_ROOT:\$LAYER2_ROOT" contrib_skew strict
assert_eq 'same-name different-version modules fail closed' 1 "$CASE_STATUS"
assert_contains 'version-skew diagnostic names the first version' "$CASE_STDERR" 'version 1.0.0'
assert_contains 'version-skew diagnostic names the second version' "$CASE_STDERR" 'version 2.0.0'
assert_contains 'version-skew diagnostic directs vendoring' "$CASE_STDERR" 'vendor a single version'
assert_eq 'version-skew prevents module body execution' '' "$CASE_TRACE"
rm -f "$_tmp_dir/layer/module.d/contrib_skew.meta" "$_tmp_dir/layer/modules/contrib_skew.sh"
rm -f "$_tmp_dir/layer2/module.d/contrib_skew.meta" "$_tmp_dir/layer2/modules/contrib_skew.sh"
unset -f _skew_meta 2>/dev/null || :

# Contract 13: two layer roots — priority order (first occurrence wins) and
# layer-vs-layer byte conflict fail closed naming both layer paths.
# Priority applies only to byte-identical meta+body copies; the layer2 body
# here is byte-identical, so the higher-priority root's body resolves.
_second_layer=$_tmp_dir/layer2
mkdir -p "$_second_layer/module.d" "$_second_layer/modules"
write_layer_module contrib_first ''
cp "$_tmp_dir/layer/module.d/contrib_first.meta" "$_second_layer/module.d/contrib_first.meta"
cp "$_tmp_dir/layer/modules/contrib_first.sh" "$_second_layer/modules/contrib_first.sh"
run_case two_layer_priority "VALISE_MODULE_PATH=\$LAYER_ROOT:\$LAYER2_ROOT" contrib_first strict
assert_eq 'identical meta+body copies across layers resolve without conflict' 0 "$CASE_STATUS"
assert_eq 'no-conflict resolution executes the module body' 'contrib_first' "$CASE_TRACE"

# Identical metadata with a DIFFERENT body is body shadowing and fails closed
# naming both body paths.
printf 'printf "%%s\\n" contrib_second_body >>"$SP_LOADER_TEST_TRACE"\ncontrib_first_loaded() { :; }\n' \
  >"$_second_layer/modules/contrib_first.sh"
run_case body_shadow "VALISE_MODULE_PATH=\$LAYER_ROOT:\$LAYER2_ROOT" contrib_first permissive
assert_eq 'identical metadata with different body fails closed' 1 "$CASE_STATUS"
assert_contains 'body-shadow diagnostic names the conflict' "$CASE_STDERR" \
  'same-name module with different bytes is forbidden'
printf 'printf "%%s\\n" contrib_first >>"$SP_LOADER_TEST_TRACE"\ncontrib_first_loaded() { :; }\n' \
  >"$_second_layer/modules/contrib_first.sh"

printf 'x' >>"$_second_layer/module.d/contrib_first.meta"
run_case layer_layer_conflict "VALISE_MODULE_PATH=\$LAYER_ROOT:\$LAYER2_ROOT" contrib_first permissive
assert_eq 'layer-vs-layer byte conflict fails closed' 1 "$CASE_STATUS"
assert_contains 'layer-vs-layer diagnostic names both layer paths' "$CASE_STDERR" \
  "$_tmp_dir/layer2/module.d/contrib_first.meta"

# Contract 14: duplicate search-path elements are deduplicated (same root
# listed twice does not self-collide).
run_case duplicate_element "VALISE_MODULE_PATH=\$LAYER_ROOT:\$LAYER_ROOT" contrib_dep strict
assert_eq 'duplicate search-path elements resolve without self-collision' 0 "$CASE_STATUS"

# Contract 15: an unreadable layer directory fails closed with the validation
# diagnostic.
mkdir -p "$_tmp_dir/unreadable" "$_tmp_dir/unsearchable"
chmod 000 "$_tmp_dir/unreadable"
chmod 444 "$_tmp_dir/unsearchable"
run_case unreadable_dir "VALISE_MODULE_PATH=\$UNREADABLE_ROOT" core permissive
assert_eq 'unreadable layer directory fails closed' 1 "$CASE_STATUS"
assert_contains 'unreadable-dir diagnostic explains the requirement' "$CASE_STDERR" \
  'must be a non-empty readable, executable directory'
chmod 755 "$_tmp_dir/unreadable"
chmod 444 "$_tmp_dir/unsearchable"

run_case unsearchable_dir "VALISE_MODULE_PATH=\$UNSEARCHABLE_ROOT" core permissive

chmod 755 "$_tmp_dir/unsearchable"
assert_eq 'unsearchable layer directory fails closed' 1 "$CASE_STATUS"
assert_contains 'unsearchable-dir diagnostic explains the requirement' "$CASE_STDERR" \
  'must be a non-empty readable, executable directory'

# Contract 16: a layer module using load_hook loads through the hook.
write_layer_module contrib_hooked ''
{
  printf 'name=contrib_hooked\nrequires=\noptional=\nshells=sh\nplatforms=any\n'
  printf 'side_effect=read-only\nexports=contrib_hooked_loaded\nupdates=\n'
  printf 'load_hook=_shell_module_contrib_hooked\n'
} >"$_tmp_dir/layer/module.d/contrib_hooked.meta"
rm -f "$_tmp_dir/layer/modules/contrib_hooked.sh"
HOOK_SRC=$_tmp_dir/hook.sh
cat >"$HOOK_SRC" <<'HOOK'
_shell_module_contrib_hooked() {
  printf '%s\n' contrib_hooked >>"${SP_LOADER_TEST_TRACE:?}"
  contrib_hooked_loaded() { :; }
}
HOOK
run_case layer_hook "VALISE_MODULE_PATH=\$LAYER_ROOT
HOOK_SRC=\$HOOK_SRC
. \"\$HOOK_SRC\"" contrib_hooked strict
assert_eq 'layer load_hook module loads through the hook' 0 "$CASE_STATUS"
assert_eq 'layer load_hook executed the hook body' 'contrib_hooked' "$CASE_TRACE"

# Contract 17: a primary module whose requires= names a layer contrib module
# discovers it across roots (primary -> layer direction).
cat >"$_tmp_dir/layer/module.d/contrib_up.meta" <<'META'
name=contrib_up
requires=
optional=
shells=sh
platforms=any
side_effect=read-only
exports=contrib_up_loaded
updates=
load=modules/contrib_up.sh
META
printf 'printf "%%s\\n" contrib_up >>"$SP_LOADER_TEST_TRACE"\ncontrib_up_loaded() { :; }\n' \
  >"$_tmp_dir/layer/modules/contrib_up.sh"
PRIMARY2_ROOT=$_tmp_dir/primary-extended
mkdir -p "$PRIMARY2_ROOT/module.d" "$PRIMARY2_ROOT/modules"
cp -R "$PRIMARY_ROOT"/. "$PRIMARY2_ROOT/"
cat >"$_tmp_dir/primary-extended/module.d/primary_needs_layer.meta" <<'META'
name=primary_needs_layer
requires=contrib_up
optional=
shells=sh
platforms=any
side_effect=read-only
exports=primary_needs_layer_loaded
updates=
load=modules/primary_needs_layer.sh
META
printf 'printf "%%s\\n" primary_needs_layer >>"$SP_LOADER_TEST_TRACE"\nprimary_needs_layer_loaded() { :; }\n' \
  >"$_tmp_dir/primary-extended/modules/primary_needs_layer.sh"
run_case primary_to_layer "VALISE_MODULE_PATH=\$LAYER_ROOT PRIMARY_ROOT=\$PRIMARY2_ROOT" primary_needs_layer strict
assert_eq 'primary module discovers layer dependency' 0 "$CASE_STATUS"
assert_eq 'primary-to-layer dependency executes in dependency order' \
  $'contrib_up\nprimary_needs_layer' "$CASE_TRACE"

printf '\n=== loader multi-root summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
