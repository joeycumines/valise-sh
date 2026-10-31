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
_module platform_edge_blocked '' platform_edge_blocked_loaded "$_other_platform" read-only 'platform_edge_blocked_loaded() { :; }'
_module platform_edge_optional '' platform_edge_optional_loaded any read-only 'platform_edge_optional_loaded() { :; }'
_module platform_edge_bridge platform_edge_blocked platform_edge_bridge_loaded any read-only 'platform_edge_bridge_loaded() { :; }'
_module platform_edge_root platform_edge_bridge platform_edge_root_loaded any read-only 'platform_edge_root_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=platform_edge_blocked/' "$_project/shell/module.d/platform_edge_optional.meta"
_module platform_user platform_other platform_user_loaded any read-only 'platform_user_loaded() { :; }
printf "platform_user body\n" >>"'"$_tmp"'/blocked.trace"'
_module platform_user_user platform_user platform_user_user_loaded any read-only 'platform_user_user_loaded() { :; }
printf "platform_user_user body\n" >>"'"$_tmp"'/blocked.trace"'
_module failed_user first_fail failed_user_loaded any read-only 'failed_user_loaded() { :; }
printf "failed_user body\n" >>"'"$_tmp"'/blocked.trace"'
cat >"$_project/shell/module.d/meta_other.meta" <<EOF
name=meta_other
version=
side_effect=read-only
requires=meta_child
optional=
shells=bash
platforms=$_other_platform
exports=
updates=
load=
EOF
_module meta_other_user meta_other meta_other_user_loaded any read-only 'meta_other_user_loaded() { :; }'
case "$_other_platform" in
linux) _here_platform=darwin ;;
*) _here_platform=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
_module cross_here '' cross_here_loaded "$_here_platform" read-only 'cross_here_loaded() { :; }
CROSS_HERE_RAN=yes'
_module cross_user '' cross_user_loaded any read-only 'cross_user_loaded() { :; }
CROSS_SEEN_HERE=${CROSS_HERE_RAN:-no}'
sed -i.bak 's/^optional=$/optional=cross_here platform_other/' "$_project/shell/module.d/cross_user.meta"
_module opt_fail_user '' opt_fail_user_loaded any read-only 'opt_fail_user_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=first_fail/' "$_project/shell/module.d/opt_fail_user.meta"
_module cycle_a '' cycle_a_loaded any read-only 'cycle_a_loaded() { :; }'
_module cycle_b '' cycle_b_loaded any read-only 'cycle_b_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=cycle_b/' "$_project/shell/module.d/cycle_a.meta"
sed -i.bak 's/^optional=$/optional=cycle_a/' "$_project/shell/module.d/cycle_b.meta"
rm -f "$_project"/shell/module.d/*.bak
mkdir -p "$_project/shell/layers/demo/module.d" "$_project/shell/layers/demo/modules"
cat >"$_project/shell/layers/demo/module.d/contrib_demo_child.meta" <<'EOF'
name=contrib_demo_child
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=contrib_demo_child_loaded
updates=
load=modules/contrib_demo_child.sh
EOF
printf 'contrib_demo_child_loaded() { :; }\n' >"$_project/shell/layers/demo/modules/contrib_demo_child.sh"
cat >"$_project/shell/layers/demo/module.d/contrib_demo_meta.meta" <<'EOF'
name=contrib_demo_meta
version=
side_effect=read-only
requires=contrib_demo_child
optional=
shells=bash
platforms=any
exports=
updates=
load=
EOF
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
_registry_row platform_edge_blocked '' platform_edge_blocked_loaded "$_other_platform" read-only modules/platform_edge_blocked.sh
_registry_row platform_edge_optional '' platform_edge_optional_loaded any read-only modules/platform_edge_optional.sh
_registry_row platform_edge_bridge platform_edge_blocked platform_edge_bridge_loaded any read-only modules/platform_edge_bridge.sh
_registry_row platform_edge_root platform_edge_bridge platform_edge_root_loaded any read-only modules/platform_edge_root.sh
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
_bundle_row blocked-platform 'later_ok platform_user_user'
_bundle_row platform-chain 'platform_user_user'
_bundle_row platform-optional 'platform_edge_optional platform_edge_root'
_bundle_row blocked-failed 'failed_user later_ok'
_bundle_row blocked-meta 'meta_other_user'
_bundle_row optional 'cross_user'
_bundle_row optional-fail 'opt_fail_user'
_bundle_row optional-cycle 'cycle_a'
_bundle_row layer-meta 'contrib_demo_meta@shell/layers/demo/module.d'
_bundle_row capability capability_user
_bundle_row reload reload_probe
_bundle_row unsafe generated_bad
_bundle_row wrapper-ok wrapper_ok
_bundle_row wrapper-missing wrapper_missing
_bundle_row conflict-function conflict_function
_bundle_row conflict-alias conflict_alias
_bundle_row bodyless bodyless_orphan

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
_assemble blocked-platform "$_tmp/release-blocked-platform"
_assemble platform-chain "$_tmp/release-platform-chain"
_assemble platform-optional "$_tmp/release-platform-optional"
_assemble blocked-failed "$_tmp/release-blocked-failed"
_assemble blocked-meta "$_tmp/release-blocked-meta"
_assemble optional "$_tmp/release-optional"
_assemble optional-fail "$_tmp/release-optional-fail"
_assemble optional-cycle "$_tmp/release-optional-cycle"
_assemble layer-meta "$_tmp/release-layer-meta"
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

# Permissive mode reports the failure, continues, and returns success, as the loader does.
if ! VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-behavior" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  command -v first_fail_loaded >/dev/null && printf "first=loaded\n"
  command -v later_ok_loaded >/dev/null && printf "later=loaded\n"
  exit "$_status"
' >"$_tmp/behavior-permissive.out" 2>"$_tmp/behavior-permissive.err"; then
  fail "permissive plan returns success after a failure"
else
  if grep -F 'status=0' "$_tmp/behavior-permissive.out" >/dev/null &&
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

# A root declared for another platform fails strict with a named diagnostic, as
# the loader does, and is skipped in permissive mode.
if VALISE_MODULE_ROOT="$_tmp/release-platform" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
' >"$_tmp/platform.out" 2>"$_tmp/platform.err"; then
  fail "strict plan fails on an unsupported root"
elif grep -F 'module platform_other skipped: unsupported platform' "$_tmp/platform.err" >/dev/null; then
  pass "strict plan fails on an unsupported root and names it"
else
  fail "strict plan fails on an unsupported root and names it"
  cat "$_tmp/platform.err" >&2
fi
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-platform" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "status=%s\n" "$?"
  if command -v platform_other_loaded >/dev/null; then printf "platform=loaded\n"; else printf "platform=skipped\n"; fi
' >"$_tmp/platform.out" 2>"$_tmp/platform.err" &&
  grep -F 'status=0' "$_tmp/platform.out" >/dev/null &&
  grep -F 'platform=skipped' "$_tmp/platform.out" >/dev/null; then
  pass "permissive plan skips a nonmatching module"
else
  fail "permissive plan skips a nonmatching module"
  cat "$_tmp/platform.out" "$_tmp/platform.err" >&2
fi

# The cross-platform form: optional dependencies. Strict mode succeeds on any
# host, the host's module loads first, and the expected absence prints nothing.
if VALISE_MODULE_ROOT="$_tmp/release-optional" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  command -v cross_user_loaded >/dev/null && printf "user=loaded\n"
  command -v cross_here_loaded >/dev/null && printf "here=loaded\n"
  command -v platform_other_loaded >/dev/null && printf "other=loaded\n"
  printf "seen=%s\n" "${CROSS_SEEN_HERE:-no}"
  exit "$_status"
' >"$_tmp/optional.out" 2>"$_tmp/optional.err" &&
  grep -F 'status=0' "$_tmp/optional.out" >/dev/null &&
  grep -F 'user=loaded' "$_tmp/optional.out" >/dev/null &&
  grep -F 'here=loaded' "$_tmp/optional.out" >/dev/null &&
  ! grep -F 'other=loaded' "$_tmp/optional.out" >/dev/null &&
  grep -F 'seen=yes' "$_tmp/optional.out" >/dev/null &&
  [ ! -s "$_tmp/optional.err" ]; then
  pass "optional dependencies make a profile cross-platform in strict mode"
else
  fail "optional dependencies make a profile cross-platform in strict mode"
  cat "$_tmp/optional.out" "$_tmp/optional.err" >&2
fi

# A failing optional dependency is reported and does not fail strict mode.
if VALISE_MODULE_ROOT="$_tmp/release-optional-fail" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  command -v opt_fail_user_loaded >/dev/null
' >"$_tmp/optional-fail.out" 2>"$_tmp/optional-fail.err" &&
  grep -F 'module first_fail failed with status 1' "$_tmp/optional-fail.err" >/dev/null; then
  pass "a failing optional dependency does not fail strict mode"
else
  fail "a failing optional dependency does not fail strict mode"
  cat "$_tmp/optional-fail.err" >&2
fi

# An optional cycle cannot deadlock the plan; a required cycle still fails.
if VALISE_MODULE_ROOT="$_tmp/release-optional-cycle" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  command -v cycle_a_loaded >/dev/null && command -v cycle_b_loaded >/dev/null
' >"$_tmp/optional-cycle.out" 2>"$_tmp/optional-cycle.err"; then
  pass "an optional-only cycle still loads its members"
else
  fail "an optional-only cycle still loads its members"
  cat "$_tmp/optional-cycle.err" >&2
fi

# A platform-unsupported module in the required closure stops a strict plan before
# anything that depends on it runs.
: >"$_tmp/blocked.trace"
if VALISE_MODULE_ROOT="$_tmp/release-blocked-platform" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  _status=$?
  printf "status=%s\n" "$_status"
  exit "$_status"
' >"$_tmp/blocked-strict.out" 2>"$_tmp/blocked-strict.err"; then
  fail "strict plan fails when a required dependency is platform-skipped"
else
  if grep -F 'status=1' "$_tmp/blocked-strict.out" >/dev/null &&
    grep -F 'module platform_other skipped: unsupported platform' "$_tmp/blocked-strict.err" >/dev/null &&
    [ ! -s "$_tmp/blocked.trace" ]; then
    pass "strict plan fails when a required dependency is platform-skipped"
  else
    fail "strict plan fails when a required dependency is platform-skipped"
    cat "$_tmp/blocked-strict.out" "$_tmp/blocked-strict.err" "$_tmp/blocked.trace" >&2
  fi
fi

# Permissive mode skips the whole dependent chain and still loads unrelated modules.
: >"$_tmp/blocked.trace"
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-platform" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "status=%s\n" "$?"
  command -v later_ok_loaded >/dev/null && printf "later=loaded\n"
  set | grep "^_shell_installed_plan_" || printf "leaks=none\n"
' >"$_tmp/blocked-permissive.out" 2>"$_tmp/blocked-permissive.err" &&
  grep -F 'status=0' "$_tmp/blocked-permissive.out" >/dev/null &&
  grep -F 'later=loaded' "$_tmp/blocked-permissive.out" >/dev/null &&
  grep -F 'leaks=none' "$_tmp/blocked-permissive.out" >/dev/null &&
  grep -F 'module platform_user_user skipped: required dependency unavailable: platform_user' "$_tmp/blocked-permissive.err" >/dev/null &&
  [ ! -s "$_tmp/blocked.trace" ]; then
  pass "permissive plan skips a platform-blocked chain and continues"
else
  fail "permissive plan skips a platform-blocked chain and continues"
  cat "$_tmp/blocked-permissive.out" "$_tmp/blocked-permissive.err" "$_tmp/blocked.trace" >&2
fi

# Permissive mode does not run a dependent of a failed module.
: >"$_tmp/blocked.trace"
VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-failed" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  printf "status=%s\n" "$?"
  command -v later_ok_loaded >/dev/null && printf "later=loaded\n"
' >"$_tmp/blocked-failed.out" 2>"$_tmp/blocked-failed.err" || :
if grep -F 'status=0' "$_tmp/blocked-failed.out" >/dev/null &&
  grep -F 'later=loaded' "$_tmp/blocked-failed.out" >/dev/null &&
  grep -F 'module failed_user skipped: required dependency unavailable: first_fail' "$_tmp/blocked-failed.err" >/dev/null &&
  [ ! -s "$_tmp/blocked.trace" ]; then
  pass "permissive plan does not run a dependent of a failed module"
else
  fail "permissive plan does not run a dependent of a failed module"
  cat "$_tmp/blocked-failed.out" "$_tmp/blocked-failed.err" "$_tmp/blocked.trace" >&2
fi

# A meta module's platforms= gates it too, so its dependents are blocked.
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-meta" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
  ! command -v meta_other_user_loaded >/dev/null
' >"$_tmp/blocked-meta.out" 2>"$_tmp/blocked-meta.err" &&
  grep -F 'module meta_other_user skipped: required dependency unavailable: meta_other' "$_tmp/blocked-meta.err" >/dev/null; then
  pass "platform-gated meta module blocks its dependents"
else
  fail "platform-gated meta module blocks its dependents"
  cat "$_tmp/blocked-meta.err" >&2
fi

# A layer meta module has no body, so the plan must not source a directory.
if ! grep -F 'layers/demo/"' "$_tmp/release-layer-meta/generated/installed-modules.bash" >/dev/null &&
  VALISE_MODULE_ROOT="$_tmp/release-layer-meta" /bin/bash -c '
    . "$VALISE_MODULE_ROOT/generated/installed-modules.bash" && command -v contrib_demo_child_loaded >/dev/null
  ' >"$_tmp/layer-meta.out" 2>"$_tmp/layer-meta.err"; then
  pass "layer meta module compiles without a load path"
else
  fail "layer meta module compiles without a load path"
  cat "$_tmp/layer-meta.err" >&2
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

# A module with neither a load path nor dependencies has nothing to load.
# The compiler rejects it by name instead of emitting a plan that silently
# does nothing for that module. The row is appended to the registry because
# assemble regenerates the registry from the metadata, and a malformed module
# has no metadata to generate it from.
_bodyless_saved="$_tmp/module-registry.bodyless.saved"
cp "$_project/shell/release/module-registry.tsv" "$_bodyless_saved"
printf 'bodyless_orphan\t\tread-only\t\t\tbash\tany\t\t\t\tshell/module.d\n' \
  >>"$_project/shell/release/module-registry.tsv"
rm -rf "$_tmp/bodyless-out"
if (cd "$_project" && "$_valise" compile --bundle=bodyless "$_tmp/bodyless-out") \
  >"$_tmp/bodyless.out" 2>"$_tmp/bodyless.err"; then
  fail "bodyless module with no dependencies fails compile"
else
  if grep -F 'module bodyless_orphan has no load path and no dependencies' \
    "$_tmp/bodyless.err" >/dev/null &&
    [ ! -e "$_tmp/bodyless-out" ]; then
    pass "bodyless module with no dependencies fails compile with the module named"
  else
    fail "bodyless module with no dependencies fails compile with the module named"
    cat "$_tmp/bodyless.err" >&2
  fi
fi
cp "$_bodyless_saved" "$_project/shell/release/module-registry.tsv"

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

# The header names the plan format version. A consumer that reads the plan
# must be able to tell which format it is holding, so the marker is pinned.
if grep -F '# shell-profile-installed-modules-v1' \
  "$_tmp/release-reload/generated/installed-modules.bash" >/dev/null; then
  pass "plan header names the plan format version"
else
  fail "plan header names the plan format version"
  head -5 "$_tmp/release-reload/generated/installed-modules.bash" >&2
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


# Loader and plan must reach the same outcome on the same project. Each case
# runs one set of roots through both surfaces and compares the exit status and
# the set of exports that survived, so a change to one engine that drifts from
# the other fails here.
_parity_loader() {
  _pl_mode=$1
  _pl_wanted=$2
  _pl_out=$3
  _pl_err=$4
  PARITY_MODE=$_pl_mode PARITY_WANTED=$_pl_wanted PARITY_PROBES=$_parity_probes PARITY_ROOT=$_project/shell \
    /bin/bash -c '
      . "$1/lib/metadata.sh"
      . "$1/lib/loader.sh"
      _status=0
      sp_loader_load_modules "$PARITY_ROOT" "$PARITY_WANTED" "$PARITY_MODE" ordinary || _status=$?
      printf "status=%s\n" "$_status"
      for _probe in $PARITY_PROBES; do
        if command -v "$_probe" >/dev/null 2>&1; then
          printf "probe_%s=yes\n" "$_probe"
        else
          printf "probe_%s=no\n" "$_probe"
        fi
      done
      exit "$_status"
    ' sh "$_repo" >"$_pl_out" 2>"$_pl_err"
}

_parity_plan() {
  _pp_mode=$1
  _pp_release=$2
  _pp_out=$3
  _pp_err=$4
  VALISE_MODE=$_pp_mode VALISE_MODULE_ROOT=$_pp_release PARITY_PROBES=$_parity_probes \
    /bin/bash -c '
      . "$VALISE_MODULE_ROOT/generated/installed-modules.bash"
      _status=$?
      printf "status=%s\n" "$_status"
      for _probe in $PARITY_PROBES; do
        if command -v "$_probe" >/dev/null 2>&1; then
          printf "probe_%s=yes\n" "$_probe"
        else
          printf "probe_%s=no\n" "$_probe"
        fi
      done
      exit "$_status"
    ' >"$_pp_out" 2>"$_pp_err"
}

_parity_case() {
  _pc_label=$1
  _pc_mode=$2
  _pc_release=$3
  _pc_wanted=$4
  _pc_probes=$5
  _pc_expected=$6
  _parity_probes=$_pc_probes
  _parity_loader_out=$_tmp/parity-loader.out
  _parity_loader_err=$_tmp/parity-loader.err
  _parity_plan_out=$_tmp/parity-plan.out
  _parity_plan_err=$_tmp/parity-plan.err
  _pc_loader_status=0
  _parity_loader "$_pc_mode" "$_pc_wanted" "$_parity_loader_out" "$_parity_loader_err" || _pc_loader_status=$?
  _pc_plan_status=0
  _parity_plan "$_pc_mode" "$_pc_release" "$_parity_plan_out" "$_parity_plan_err" || _pc_plan_status=$?
  if [ "$_pc_loader_status" -eq "$_pc_plan_status" ] &&
    [ "$_pc_loader_status" -eq "$_pc_expected" ] &&
    cmp -s "$_parity_loader_out" "$_parity_plan_out"; then
    pass "$_pc_label: loader and plan agree"
  else
    fail "$_pc_label: loader and plan agree"
    printf 'loader status=%s plan status=%s expected=%s\n' \
      "$_pc_loader_status" "$_pc_plan_status" "$_pc_expected" >&2
    diff -u "$_parity_loader_out" "$_parity_plan_out" >&2 || :
    cat "$_parity_loader_err" "$_parity_plan_err" >&2
  fi
}

_parity_case 'runtime failure' strict "$_tmp/release-behavior" 'first_fail later_ok' 'later_ok_loaded' 1
if grep -F 'first_fail' "$_parity_loader_err" >/dev/null &&
  grep -F 'first_fail' "$_parity_plan_err" >/dev/null; then
  pass 'runtime failure: both engines name the failing module'
else
  fail 'runtime failure: both engines name the failing module'
  cat "$_parity_loader_err" "$_parity_plan_err" >&2
fi

_parity_case 'platform chain' strict "$_tmp/release-platform-chain" 'platform_user_user' \
  'platform_other_loaded platform_user_loaded platform_user_user_loaded' 1
if grep -F 'unsupported platform' "$_parity_loader_err" >/dev/null &&
  grep -F 'unsupported platform' "$_parity_plan_err" >/dev/null; then
  pass 'platform chain: both engines report the platform skip'
else
  fail 'platform chain: both engines report the platform skip'
  cat "$_parity_loader_err" "$_parity_plan_err" >&2
fi

_parity_case 'platform optional-first' strict "$_tmp/release-platform-optional" \
  'platform_edge_optional platform_edge_root' \
  'platform_edge_optional_loaded platform_edge_bridge_loaded platform_edge_root_loaded platform_edge_blocked_loaded' 1
if grep -F 'unsupported platform' "$_parity_loader_err" >/dev/null &&
  grep -F 'unsupported platform' "$_parity_plan_err" >/dev/null; then
  pass 'platform optional-first: both engines report the platform skip'
else
  fail 'platform optional-first: both engines report the platform skip'
  cat "$_parity_loader_err" "$_parity_plan_err" >&2
fi

_parity_case 'optional dependencies' strict "$_tmp/release-optional" 'cross_user' \
  'cross_user_loaded cross_here_loaded platform_other_loaded' 0
if ! grep -F 'unsupported platform' "$_parity_loader_err" >/dev/null &&
  ! grep -F 'unsupported platform' "$_parity_plan_err" >/dev/null; then
  pass 'optional dependencies: the absent optional is silent on both engines'
else
  fail 'optional dependencies: the absent optional is silent on both engines'
  cat "$_parity_loader_err" "$_parity_plan_err" >&2
fi

_parity_case 'optional dependencies permissive' permissive "$_tmp/release-optional" 'cross_user' \
  'cross_user_loaded cross_here_loaded platform_other_loaded' 0

printf '\n=== compiler-plan summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
