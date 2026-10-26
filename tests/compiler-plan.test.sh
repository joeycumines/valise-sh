#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Compiled-plan runtime and compile-time contract tests.

set -eu

_total=0
_pass=0
_fail=0
_skip=0
_require_tooling=${VALISE_REQUIRE_TOOLING:-0}

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); _skip=$((_skip + 1)); printf '  SKIP: %s\n' "$1"; }

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise="$_repo/bin/valise"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-compiler-plan.XXXXXX")
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_tmp" 2>/dev/null || :
  rm -rf -- "$_tmp"
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

_project="$_tmp/project"
mkdir -p "$_project/shell/module.d" "$_project/shell/modules" "$_project/shell/release"

_module() {
  _mod_name=$1
  _mod_requires=$2
  _mod_exports=$3
  _mod_platforms=$4
  _mod_side_effect=$5
  _mod_body=$6
  cat >"$_project/shell/module.d/$_mod_name.meta" <<EOF
name=$_mod_name
version=
side_effect=$_mod_side_effect
requires=$_mod_requires
optional=
shells=bash
platforms=$_mod_platforms
exports=$_mod_exports
updates=
load=modules/$_mod_name.sh
EOF
  printf '%s\n' "$_mod_body" >"$_project/shell/modules/$_mod_name.sh"
  unset _mod_name _mod_requires _mod_exports _mod_platforms _mod_side_effect _mod_body
}

_registry_row() {
  _row_name=$1
  _row_requires=$2
  _row_exports=$3
  _row_platforms=$4
  _row_side_effect=$5
  _row_load=$6
  printf '%s\t\t%s\t%s\t\tbash\t%s\t%s\t%s\t\tshell/module.d\n' \
    "$_row_name" "$_row_side_effect" "$_row_requires" "$_row_platforms" \
    "$_row_exports" "$_row_load" >>"$_project/shell/release/module-registry.tsv"
  unset _row_name _row_requires _row_exports _row_platforms _row_side_effect _row_load
}

_bundle_row() {
  printf '%s\tbash\t%s\n' "$1" "$2" >>"$_project/shell/release/bundle-roots"
}

_current_os=$(uname -s)
case "$_current_os" in
Darwin) _other_platform=linux ;;
Linux) _other_platform=darwin ;;
*) _other_platform=darwin ;;
esac
unset _current_os

_module first_fail '' first_fail_loaded any read-only 'first_fail_loaded() { :; }
return 1'
_module later_ok '' later_ok_loaded any read-only 'later_ok_loaded() { :; }'
_module missing_export '' missing_export_loaded any read-only 'printf "no export\n" >/dev/null'
_module meta_child '' meta_child_loaded any read-only 'meta_child_loaded() { :; }'
cat >"$_project/shell/module.d/meta_parent.meta" <<'EOF'
name=meta_parent
version=
side_effect=read-only
requires=meta_child
optional=
shells=bash
platforms=any
exports=
updates=
load=
EOF
rm -f "$_project/shell/modules/meta_parent.sh"
_module platform_other '' platform_other_loaded "$_other_platform" read-only 'platform_other_loaded() { :; }'
_module capability_user '' capability_user_loaded any read-only 'capability_user_loaded() { sp_cap_os; }'
_module reload_probe '' reload_probe_loaded any read-only 'reload_probe_loaded() { :; }'
_module generated_bad '' generated_bad_loaded any generated-file 'generated_bad_loaded() { :; }'
_module wrapper_ok '' wrapper_probe any read-only 'wrapper_probe() { :; }'
_module wrapper_missing '' wrapper_missing_probe any read-only 'printf "no wrapper\n" >/dev/null'
_module conflict_function '' existing_probe any read-only 'printf "function conflict body\n" >>"'"$_tmp"'/conflict-function.trace"
existing_probe() { :; }'
_module conflict_alias '' existing_alias_probe any read-only 'printf "alias conflict body\n" >>"'"$_tmp"'/conflict-alias.trace"
existing_alias_probe() { :; }'

{
  printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'
} >"$_project/shell/release/module-registry.tsv"
_registry_row first_fail '' first_fail_loaded any read-only modules/first_fail.sh
_registry_row later_ok '' later_ok_loaded any read-only modules/later_ok.sh
_registry_row missing_export '' missing_export_loaded any read-only modules/missing_export.sh
_registry_row meta_child '' meta_child_loaded any read-only modules/meta_child.sh
_registry_row meta_parent meta_child '' any read-only ''
_registry_row platform_other '' platform_other_loaded "$_other_platform" read-only modules/platform_other.sh
_registry_row capability_user '' capability_user_loaded any read-only modules/capability_user.sh
_registry_row reload_probe '' reload_probe_loaded any read-only modules/reload_probe.sh
_registry_row generated_bad '' generated_bad_loaded any generated-file modules/generated_bad.sh
_registry_row wrapper_ok '' wrapper_probe any read-only modules/wrapper_ok.sh
_registry_row wrapper_missing '' wrapper_missing_probe any read-only modules/wrapper_missing.sh
_registry_row conflict_function '' existing_probe any read-only modules/conflict_function.sh
_registry_row conflict_alias '' existing_alias_probe any read-only modules/conflict_alias.sh
unset _other_platform

{
  printf '# bundle\tshell\troots\n'
} >"$_project/shell/release/bundle-roots"
_bundle_row behavior 'first_fail later_ok'
_bundle_row missing missing_export
_bundle_row meta meta_parent
_bundle_row platform platform_other
_bundle_row capability capability_user
_bundle_row reload reload_probe
_bundle_row unsafe generated_bad
_bundle_row wrapper-ok wrapper_ok
_bundle_row wrapper-missing wrapper_missing
_bundle_row conflict-function conflict_function
_bundle_row conflict-alias conflict_alias

printf 'variant_name\tdescription\texcluded_modules\nworkstation-full\tAll\t\n' \
  >"$_project/shell/release/install-variants"

_assemble() {
  _as_bundle=$1
  _as_out=$2
  rm -rf "$_as_out"
  if (cd "$_project" && "$_valise" assemble --bundle="$_as_bundle" "$_as_out") \
    >"$_tmp/$_as_bundle.assemble.out" 2>"$_tmp/$_as_bundle.assemble.err"; then
    pass "assemble bundle $_as_bundle"
  else
    fail "assemble bundle $_as_bundle"
    cat "$_tmp/$_as_bundle.assemble.err" >&2
  fi
  unset _as_bundle _as_out
}

_reject_registry_row() {
  _probe_row=$1
  _probe_needle=$2
  _probe_saved="$_tmp/module-registry.saved"
  cp "$_project/shell/release/module-registry.tsv" "$_probe_saved"
  printf '%s\n' "$_probe_row" >>"$_project/shell/release/module-registry.tsv"
  rm -rf "$_tmp/registry-probe-out"
  if (cd "$_project" && "$_valise" compile --bundle=reload "$_tmp/registry-probe-out") \
    >"$_tmp/registry-probe.out" 2>"$_tmp/registry-probe.err"; then
    fail "compile rejects registry row: $_probe_needle"
  else
    if grep -F "$_probe_needle" "$_tmp/registry-probe.err" >/dev/null; then
      pass "compile rejects registry row: $_probe_needle"
    else
      fail "compile rejects registry row: $_probe_needle"
      cat "$_tmp/registry-probe.err" >&2
    fi
  fi
  cp "$_probe_saved" "$_project/shell/release/module-registry.tsv"
  unset _probe_row _probe_needle _probe_saved
}

printf '=== compiled-plan contract ===\n'

_assemble behavior "$_tmp/release-behavior"
_assemble missing "$_tmp/release-missing"
_assemble meta "$_tmp/release-meta"
_assemble platform "$_tmp/release-platform"
_assemble capability "$_tmp/release-capability"
_assemble reload "$_tmp/release-reload"
_assemble wrapper-ok "$_tmp/release-wrapper-ok"
_assemble wrapper-missing "$_tmp/release-wrapper-missing"
_assemble conflict-function "$_tmp/release-conflict-function"
_assemble conflict-alias "$_tmp/release-conflict-alias"

# Strict mode stops at the first failing module and names it.
if VALISE_MODULE_ROOT="$_tmp/release-behavior" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  command -v first_fail_loaded >/dev/null && printf "first=loaded\n"
  if command -v later_ok_loaded >/dev/null; then printf "later=loaded\n"; else printf "later=skipped\n"; fi
  exit "$_status"
' >"$_tmp/behavior-strict.out" 2>"$_tmp/behavior-strict.err"; then
  fail "strict plan returns failure"
else
  _status=$?
  if grep -F 'status=1' "$_tmp/behavior-strict.out" >/dev/null &&
    grep -F 'first=loaded' "$_tmp/behavior-strict.out" >/dev/null &&
    grep -F 'later=skipped' "$_tmp/behavior-strict.out" >/dev/null &&
    grep -F 'module first_fail failed with status 1' "$_tmp/behavior-strict.err" >/dev/null; then
    pass "strict plan names and stops at the first failure"
  else
    fail "strict plan names and stops at the first failure"
    cat "$_tmp/behavior-strict.out" >&2
    cat "$_tmp/behavior-strict.err" >&2
  fi
fi

# Permissive mode reports the same failure, continues, and returns the first status.
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-behavior" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  command -v first_fail_loaded >/dev/null && printf "first=loaded\n"
  command -v later_ok_loaded >/dev/null && printf "later=loaded\n"
  exit "$_status"
' >"$_tmp/behavior-permissive.out" 2>"$_tmp/behavior-permissive.err"; then
  fail "permissive plan returns the first failure"
else
  if grep -F 'status=1' "$_tmp/behavior-permissive.out" >/dev/null &&
    grep -F 'first=loaded' "$_tmp/behavior-permissive.out" >/dev/null &&
    grep -F 'later=loaded' "$_tmp/behavior-permissive.out" >/dev/null &&
    grep -F 'module first_fail failed with status 1' "$_tmp/behavior-permissive.err" >/dev/null; then
    pass "permissive plan reports failure and continues"
  else
    fail "permissive plan reports failure and continues"
    cat "$_tmp/behavior-permissive.out" >&2
    cat "$_tmp/behavior-permissive.err" >&2
  fi
fi

# A declared but missing export is reported with the module and export names.
if VALISE_MODULE_ROOT="$_tmp/release-missing" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
' >"$_tmp/missing.out" 2>"$_tmp/missing.err"; then
  fail "missing export fails the plan"
else
  if grep -F 'missing_export: declared export missing: missing_export_loaded' "$_tmp/missing.err" >/dev/null &&
    grep -F 'module missing_export failed with status 1' "$_tmp/missing.err" >/dev/null; then
    pass "missing export is reported with module and export names"
  else
    fail "missing export is reported with module and export names"
    cat "$_tmp/missing.err" >&2
  fi
fi

# Dependency-only meta modules compile, order their dependencies, and load no body.
if grep -F '# order=meta_child meta_parent' "$_tmp/release-meta/generated/installed-modules.bash" >/dev/null &&
  VALISE_MODULE_ROOT="$_tmp/release-meta" /bin/bash -c '
    . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
    command -v meta_child_loaded >/dev/null
  ' >"$_tmp/meta.out" 2>"$_tmp/meta.err"; then
  pass "meta module orders its dependency closure without a body"
else
  fail "meta module orders its dependency closure without a body"
  cat "$_tmp/meta.err" >&2
fi

# Platform gating uses one runtime probe and skips nonmatching modules.
if VALISE_MODULE_ROOT="$_tmp/release-platform" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "status=%s\n" "$?"
  if command -v platform_other_loaded >/dev/null; then printf "platform=loaded\n"; else printf "platform=skipped\n"; fi
' >"$_tmp/platform.out" 2>"$_tmp/platform.err"; then
  if grep -F 'status=0' "$_tmp/platform.out" >/dev/null &&
    grep -F 'platform=skipped' "$_tmp/platform.out" >/dev/null; then
    pass "runtime platform gating skips a nonmatching module"
  else
    fail "runtime platform gating skips a nonmatching module"
    cat "$_tmp/platform.out" >&2
  fi
else
  fail "runtime platform gating skips a nonmatching module"
  cat "$_tmp/platform.err" >&2
fi

# Capability functions remain available after the plan finishes.
if VALISE_MODULE_ROOT="$_tmp/release-capability" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  capability_user_loaded >/dev/null
  command -v sp_cap_os >/dev/null
' >"$_tmp/capability.out" 2>"$_tmp/capability.err"; then
  pass "module functions can call sp_cap_os after the plan finishes"
else
  fail "module functions can call sp_cap_os after the plan finishes"
  cat "$_tmp/capability.err" >&2
fi

# A capability-prelude failure must fail the whole plan and skip module bodies.
rm -rf "$_tmp/release-prelude-failure"
cp -R "$_tmp/release-capability" "$_tmp/release-prelude-failure"
printf '%s\n' 'bad ((' >"$_tmp/release-prelude-failure/vendor/shell-profile/lib/capabilities.sh"
if VALISE_MODULE_ROOT="$_tmp/release-prelude-failure" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  if command -v capability_user_loaded >/dev/null; then printf "module=loaded\n"; else printf "module=skipped\n"; fi
  exit "$_status"
' >"$_tmp/prelude-failure.out" 2>"$_tmp/prelude-failure.err"; then
  fail "capability prelude failure fails the plan"
else
  if grep -F 'status=' "$_tmp/prelude-failure.out" >/dev/null &&
    ! grep -F 'status=0' "$_tmp/prelude-failure.out" >/dev/null &&
    grep -F 'module=skipped' "$_tmp/prelude-failure.out" >/dev/null; then
    pass "capability prelude failure fails closed and skips modules"
  else
    fail "capability prelude failure fails closed and skips modules"
    cat "$_tmp/prelude-failure.out" >&2
    cat "$_tmp/prelude-failure.err" >&2
  fi
fi

# Re-sourcing with VALISE_RELOAD=1 clears the plan's declared exports.
if VALISE_MODULE_ROOT="$_tmp/release-reload" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "first=%s\n" "$?"
  VALISE_RELOAD=1
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "second=%s\n" "$?"
  command -v reload_probe_loaded >/dev/null
' >"$_tmp/reload.out" 2>"$_tmp/reload.err"; then
  if grep -F 'first=0' "$_tmp/reload.out" >/dev/null &&
    grep -F 'second=0' "$_tmp/reload.out" >/dev/null; then
    pass "VALISE_RELOAD=1 re-sources the plan successfully"
  else
    fail "VALISE_RELOAD=1 re-sources the plan successfully"
    cat "$_tmp/reload.out" >&2
  fi
else
  fail "VALISE_RELOAD=1 re-sources the plan successfully"
  cat "$_tmp/reload.err" >&2
fi

# A wrapper export may replace an external command and must not remain external.
mkdir -p "$_tmp/fakebin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$_tmp/fakebin/wrapper_probe"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$_tmp/fakebin/wrapper_missing_probe"
chmod +x "$_tmp/fakebin/wrapper_probe" "$_tmp/fakebin/wrapper_missing_probe"
if PATH="$_tmp/fakebin:$PATH" VALISE_MODULE_ROOT="$_tmp/release-wrapper-ok" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  [ "$(command -v wrapper_probe)" = wrapper_probe ]
' >"$_tmp/wrapper-ok.out" 2>"$_tmp/wrapper-ok.err"; then
  pass "wrapper export replaces an external command with a function"
else
  fail "wrapper export replaces an external command with a function"
  cat "$_tmp/wrapper-ok.err" >&2
fi
if PATH="$_tmp/fakebin:$PATH" VALISE_MODULE_ROOT="$_tmp/release-wrapper-missing" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
' >"$_tmp/wrapper-missing.out" 2>"$_tmp/wrapper-missing.err"; then
  fail "unprovided wrapper export fails the plan"
else
  if grep -F 'wrapper_missing: declared export was not provided by module: wrapper_missing_probe' \
    "$_tmp/wrapper-missing.err" >/dev/null; then
    pass "unprovided wrapper export is reported"
  else
    fail "unprovided wrapper export is reported"
    cat "$_tmp/wrapper-missing.err" >&2
  fi
fi

# Existing functions and aliases are rejected before the module body runs.
rm -f "$_tmp/conflict-function.trace"
if VALISE_MODULE_ROOT="$_tmp/release-conflict-function" /bin/bash -c '
  existing_probe() { :; }
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
' >"$_tmp/conflict-function.out" 2>"$_tmp/conflict-function.err"; then
  fail "existing function export fails the plan"
else
  if grep -F 'conflict_function: declared export already exists before load: existing_probe' \
    "$_tmp/conflict-function.err" >/dev/null &&
    [ ! -f "$_tmp/conflict-function.trace" ]; then
    pass "existing function export is rejected before the body"
  else
    fail "existing function export is rejected before the body"
    cat "$_tmp/conflict-function.err" >&2
  fi
fi
rm -f "$_tmp/conflict-alias.trace"
if VALISE_MODULE_ROOT="$_tmp/release-conflict-alias" /bin/bash -c '
  shopt -s expand_aliases
  alias existing_alias_probe=/bin/true
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
' >"$_tmp/conflict-alias.out" 2>"$_tmp/conflict-alias.err"; then
  fail "existing alias export fails the plan"
else
  if grep -F 'conflict_alias: declared export already exists before load: existing_alias_probe' \
    "$_tmp/conflict-alias.err" >/dev/null &&
    [ ! -f "$_tmp/conflict-alias.trace" ]; then
    pass "existing alias export is rejected before the body"
  else
    fail "existing alias export is rejected before the body"
    cat "$_tmp/conflict-alias.err" >&2
  fi
fi

# Unsafe side effects are a compile-time error naming the module.
rm -rf "$_tmp/unsafe-out"
if (cd "$_project" && "$_valise" compile --bundle=unsafe "$_tmp/unsafe-out") \
  >"$_tmp/unsafe.out" 2>"$_tmp/unsafe.err"; then
  fail "generated-file module fails compile"
else
  if grep -F 'module generated_bad has unsafe side_effect for compile: generated-file' \
    "$_tmp/unsafe.err" >/dev/null &&
    [ ! -e "$_tmp/unsafe-out" ]; then
    pass "generated-file module fails compile with the module named"
  else
    fail "generated-file module fails compile with the module named"
    cat "$_tmp/unsafe.err" >&2
  fi
fi

# Registry rows that would silently change case dispatch are rejected up front.
_reject_registry_row \
  'brack[1]		read-only			bash	any	brack_loaded	modules/first_fail.sh		shell/module.d' \
  'invalid module name in registry: brack[1]'
_reject_registry_row \
  'missing_platform		read-only			bash		missing_platform_loaded	modules/first_fail.sh		shell/module.d' \
  'missing platforms for registry module: missing_platform'
_reject_registry_row \
  'bad_effect		weird-effect			bash	any	bad_effect_loaded	modules/first_fail.sh		shell/module.d' \
  'invalid side_effect for registry module bad_effect: weird-effect'
_reject_registry_row \
  'bad_source		read-only			bash	any	bad_source_loaded	modules/first_fail.sh		shell/mod*' \
  'invalid registry source for module bad_source: shell/mod*'
_reject_registry_row \
  'bad_exports		read-only			bash	any	bad_exports$(id)	modules/first_fail.sh		shell/module.d' \
  'invalid export for registry module bad_exports: bad_exports$(id)'

# The generated header names valise, and rebuilding is deterministic.
if grep -F '# Generated by valise compile; DO NOT EDIT.' \
  "$_tmp/release-reload/generated/installed-modules.bash" >/dev/null; then
  pass "plan header names valise"
else
  fail "plan header names valise"
fi
rm -rf "$_tmp/release-reload-2"
if (cd "$_project" && "$_valise" assemble --bundle=reload "$_tmp/release-reload-2") \
  >"$_tmp/reload-2.out" 2>"$_tmp/reload-2.err" &&
  cmp -s "$_tmp/release-reload/shell/install/profile-release.manifest" \
    "$_tmp/release-reload-2/shell/install/profile-release.manifest"; then
  pass "repeated assemble produces an identical manifest"
else
  fail "repeated assemble produces an identical manifest"
  cat "$_tmp/reload-2.err" >&2
fi

printf '\n=== compiler-plan summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
