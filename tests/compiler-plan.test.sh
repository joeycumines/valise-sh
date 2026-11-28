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

_bash_bin=$(command -v bash 2>/dev/null || :)
if [ -z "$_bash_bin" ] || [ ! -x "$_bash_bin" ]; then
  if [ "$_require_tooling" -eq 1 ]; then
    fail "compiled-plan Bash runtime (bash is required but unavailable)"
    exit 1
  fi
  skip "compiled-plan Bash runtime (bash is unavailable)"
  exit 0
fi

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
mkdir -p "$_project/module.d" "$_project/modules"
: >"$_project/valise.conf"

_module() {
  _mod_name=$1
  _mod_requires=$2
  _mod_exports=$3
  _mod_platforms=$4
  _mod_side_effect=$5
  _mod_body=$6
  cat >"$_project/module.d/$_mod_name.meta" <<EOF
name=$_mod_name
version=
side_effect=$_mod_side_effect
requires=$_mod_requires
optional=
shells=bash
platforms=$_mod_platforms
exports=$_mod_exports
load=modules/$_mod_name.sh
EOF
  printf '%s\n' "$_mod_body" >"$_project/modules/$_mod_name.sh"
  unset _mod_name _mod_requires _mod_exports _mod_platforms _mod_side_effect _mod_body
}

_bundle_row() {
  printf '%s\tbash\t%s\n' "$1" "$2" >>"$_project/bundles.tsv"
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
cat >"$_project/module.d/meta_parent.meta" <<'EOF'
name=meta_parent
version=
side_effect=read-only
requires=meta_child
optional=
shells=bash
platforms=any
exports=
load=
EOF
rm -f "$_project/modules/meta_parent.sh"
_module platform_other '' platform_other_loaded "$_other_platform" read-only 'platform_other_loaded() { :; }'
_module platform_edge_blocked '' platform_edge_blocked_loaded "$_other_platform" read-only 'platform_edge_blocked_loaded() { :; }'
_module platform_edge_optional '' platform_edge_optional_loaded any read-only 'platform_edge_optional_loaded() { :; }'
_module platform_edge_bridge platform_edge_blocked platform_edge_bridge_loaded any read-only 'platform_edge_bridge_loaded() { :; }'
_module platform_edge_root platform_edge_bridge platform_edge_root_loaded any read-only 'platform_edge_root_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=platform_edge_blocked/' "$_project/module.d/platform_edge_optional.meta"
_module platform_user platform_other platform_user_loaded any read-only 'platform_user_loaded() { :; }
printf "platform_user body\n" >>"'"$_tmp"'/blocked.trace"'
_module platform_user_user platform_user platform_user_user_loaded any read-only 'platform_user_user_loaded() { :; }
printf "platform_user_user body\n" >>"'"$_tmp"'/blocked.trace"'
_module failed_user first_fail failed_user_loaded any read-only 'failed_user_loaded() { :; }
printf "failed_user body\n" >>"'"$_tmp"'/blocked.trace"'
cat >"$_project/module.d/meta_other.meta" <<EOF
name=meta_other
version=
side_effect=read-only
requires=meta_child
optional=
shells=bash
platforms=$_other_platform
exports=
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
sed -i.bak 's/^optional=$/optional=cross_here platform_other/' "$_project/module.d/cross_user.meta"
_module opt_fail_user '' opt_fail_user_loaded any read-only 'opt_fail_user_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=first_fail/' "$_project/module.d/opt_fail_user.meta"
_module cycle_a '' cycle_a_loaded any read-only 'cycle_a_loaded() { :; }'
_module cycle_b '' cycle_b_loaded any read-only 'cycle_b_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=cycle_b/' "$_project/module.d/cycle_a.meta"
sed -i.bak 's/^optional=$/optional=cycle_a/' "$_project/module.d/cycle_b.meta"
_module opt_req_cycle_user '' opt_req_cycle_user_loaded any read-only 'opt_req_cycle_user_loaded() { :; }'
_module opt_req_cycle_a opt_req_cycle_b opt_req_cycle_a_loaded any read-only 'opt_req_cycle_a_loaded() { :; }'
_module opt_req_cycle_b opt_req_cycle_a opt_req_cycle_b_loaded any read-only 'opt_req_cycle_b_loaded() { :; }'
sed -i.bak 's/^optional=$/optional=opt_req_cycle_a/' "$_project/module.d/opt_req_cycle_user.meta"
cat >"$_project/module.d/meta_export_bad.meta" <<'EOF'
name=meta_export_bad
version=
side_effect=read-only
requires=meta_child
optional=
shells=bash
platforms=any
exports=meta_export_bad_loaded
load=
EOF
rm -f "$_project"/module.d/*.bak
mkdir -p "$_project/layers/demo/module.d" "$_project/layers/demo/modules"
cat >"$_project/layers/demo/module.d/contrib_demo_child.meta" <<'EOF'
name=contrib_demo_child
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=contrib_demo_child_loaded
load=modules/contrib_demo_child.sh
EOF
printf 'contrib_demo_child_loaded() { :; }\n' >"$_project/layers/demo/modules/contrib_demo_child.sh"
cat >"$_project/layers/demo/module.d/contrib_demo_meta.meta" <<'EOF'
name=contrib_demo_meta
version=
side_effect=read-only
requires=contrib_demo_child
optional=
shells=bash
platforms=any
exports=
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

# Phase modules: one env-phase module and one interactive-phase module, the
# interactive one requiring the env one, so the interactive plan orders the env
# dependency ahead of itself while the env plan must not contain it at all.
# valise_path is required so the fixed-point probe can re-assert PATH through
# the idempotent helper rather than a raw assignment. The env body asserts a
# compiled PATH order through valise_path_prepend so the fixed-point probe can
# verify convergence after a simulated path_helper reorder.
_module phase_env 'valise_path' phase_env_loaded any read-only 'phase_env_loaded() { :; }
valise_path_prepend /usr/local/bin'
_module phase_interactive phase_env phase_interactive_loaded any read-only 'phase_interactive_loaded() { :; }'
printf 'phase=interactive\n' >>"$_project/module.d/phase_interactive.meta"
printf 'commands=phase_interactive_loaded\n' >>"$_project/module.d/phase_interactive.meta"

# Cross-phase availability: an env module that FAILS, and an interactive module
# that REQUIRES it. Partitioning the closure into two plans must not lose the
# dependency contract: the interactive module's body must not run, in strict or
# permissive mode, because its required dependency is unavailable.
# A failing body must not `exit` - that would end the sourcing shell instead of
# returning a status. A shell FUNCTION returning non-zero is the failing status
# the plan records, which is exactly the contract under test.
_module cx_env '' '' any read-only 'printf "CX_ENV_BODY\n"
return 42'
_module cx_int cx_env cx_int_loaded any read-only 'printf "CX_INT_BODY\n"
cx_int_loaded() { :; }'
printf 'phase=interactive\n' >>"$_project/module.d/cx_int.meta"

# Export ownership: a module whose body defines a function the caller also
# defines. Two passes over the plan with VALISE_RELOAD must not silently take
# the caller's function over - the conflict is reported on BOTH passes, because
# valise never installed it.
_module owner_probe '' owner_probe_fn any read-only 'owner_probe_fn() { printf "MODULE\n"; }'

unset _other_platform

{
  printf '# bundle\tshell\troots\n'
} >"$_project/bundles.tsv"
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
_bundle_row optional-required-cycle 'opt_req_cycle_user'
_bundle_row meta-exports 'meta_export_bad'
_bundle_row layer-meta 'contrib_demo_meta@layers/demo/module.d'
_bundle_row capability capability_user
_bundle_row reload reload_probe
_bundle_row unsafe generated_bad
_bundle_row wrapper-ok wrapper_ok
_bundle_row wrapper-missing wrapper_missing
_bundle_row conflict-function conflict_function
_bundle_row conflict-alias conflict_alias
_bundle_row phase 'phase_env phase_interactive'
_bundle_row phase-env-only phase_env
_bundle_row cross-phase 'cx_int'
_bundle_row ownership owner_probe

printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' \
  >"$_project/variants.tsv"

_build() {
  _as_bundle=$1
  _as_out=$2
  rm -rf "$_as_out"
  if (cd "$_project" && "$_valise" build --bundle="$_as_bundle" "$_as_out") \
    >"$_tmp/$_as_bundle.build.out" 2>"$_tmp/$_as_bundle.build.err"; then
    pass "build bundle $_as_bundle"
  else
    fail "build bundle $_as_bundle"
    cat "$_tmp/$_as_bundle.build.err" >&2
  fi
  unset _as_bundle _as_out
}

# _reject_meta <file-name> <needle> <meta-line>...
# Add a module whose metadata is invalid and require compile to fail with the
# metadata diagnostic. The registry is generated from metadata, so metadata
# validation is what keeps unsafe names and values out of the plan source.
_reject_meta() {
  _probe_file="$_project/module.d/$1.meta"
  _probe_needle=$2
  shift 2
  printf '%s\n' "$@" >"$_probe_file"
  rm -rf "$_tmp/registry-probe-out"
  if (cd "$_project" && "$_valise" compile --bundle=reload "$_tmp/registry-probe-out") \
    >"$_tmp/registry-probe.out" 2>"$_tmp/registry-probe.err"; then
    fail "compile rejects metadata: $_probe_needle"
  elif grep -F -- "$_probe_needle" "$_tmp/registry-probe.err" >/dev/null &&
    [ ! -e "$_tmp/registry-probe-out" ]; then
    pass "compile rejects metadata: $_probe_needle"
  else
    fail "compile rejects metadata: $_probe_needle"
    cat "$_tmp/registry-probe.err" >&2
  fi
  rm -f "$_probe_file"
  unset _probe_file _probe_needle
}

printf '=== compiled-plan contract ===\n'

_build behavior "$_tmp/release-behavior"
_build missing "$_tmp/release-missing"
_build meta "$_tmp/release-meta"
_build platform "$_tmp/release-platform"
_build blocked-platform "$_tmp/release-blocked-platform"
_build platform-chain "$_tmp/release-platform-chain"
_build platform-optional "$_tmp/release-platform-optional"
_build blocked-failed "$_tmp/release-blocked-failed"
_build blocked-meta "$_tmp/release-blocked-meta"
_build optional "$_tmp/release-optional"
_build optional-fail "$_tmp/release-optional-fail"
_build optional-cycle "$_tmp/release-optional-cycle"
_build optional-required-cycle "$_tmp/release-optional-required-cycle"
_build layer-meta "$_tmp/release-layer-meta"
_build capability "$_tmp/release-capability"
_build reload "$_tmp/release-reload"
_build wrapper-ok "$_tmp/release-wrapper-ok"
_build wrapper-missing "$_tmp/release-wrapper-missing"
_build conflict-function "$_tmp/release-conflict-function"
_build conflict-alias "$_tmp/release-conflict-alias"
_build phase "$_tmp/release-phase"
_build phase-env-only "$_tmp/release-phase-env-only"
_build cross-phase "$_tmp/release-cross-phase"
_build ownership "$_tmp/release-ownership"

# --- Phase plans ---
# The env plan contains the env module but not the interactive one; the
# interactive plan exists and contains only the interactive module.
if grep -F '# plan=bash phase=env' "$_tmp/release-phase/plans/bash.sh" >/dev/null &&
  grep -F 'phase_env@' "$_tmp/release-phase/plans/bash.sh" >/dev/null &&
  ! grep -F 'phase_interactive@' "$_tmp/release-phase/plans/bash.sh" >/dev/null &&
  ! grep -F 'modules/phase_interactive.sh' "$_tmp/release-phase/plans/bash.sh" >/dev/null; then
  pass "env plan contains only env-phase modules"
else
  fail "env plan contains only env-phase modules"
  head -6 "$_tmp/release-phase/plans/bash.sh" >&2
fi
if [ -f "$_tmp/release-phase/plans/bash-interactive.sh" ] &&
  grep -F '# plan=bash phase=interactive' "$_tmp/release-phase/plans/bash-interactive.sh" >/dev/null &&
  grep -F 'phase_interactive@' "$_tmp/release-phase/plans/bash-interactive.sh" >/dev/null &&
  ! grep -F 'valise_path@valise)' "$_tmp/release-phase/plans/bash-interactive.sh" >/dev/null; then
  pass "interactive plan contains only the interactive module of the closure"
else
  fail "interactive plan contains only the interactive module of the closure"
  head -6 "$_tmp/release-phase/plans/bash-interactive.sh" >&2 2>/dev/null
fi

# A shell whose closure has no interactive modules gets no interactive plan.
# A shell whose closure has no interactive modules gets no interactive plan.
if [ -f "$_tmp/release-phase-env-only/plans/bash.sh" ] &&
  grep -F 'phase_env@' "$_tmp/release-phase-env-only/plans/bash.sh" >/dev/null &&
  { [ ! -e "$_tmp/release-phase-env-only/plans/bash-interactive.sh" ] ||
    ! grep -F '@module.d)' "$_tmp/release-phase-env-only/plans/bash-interactive.sh" >/dev/null; }; then
  pass "no interactive modules land in the env-only shell closure plans"
else
  fail "no interactive modules land in the env-only shell closure plans"
fi

# An interactive module may require an env module (the env plan loads first at
# every entry point), which the phase bundle above already proves. The reverse
# is broken and must be rejected: the env plan never contains the interactive
# dependency, so the env module would load with it permanently absent.
_cross_proj="$_tmp/proj-cross-phase"
cp -R "$_project" "$_cross_proj"
rm -rf "$_cross_proj/build"
# A standalone interactive module: requiring the existing phase_interactive
# would close a cycle instead of exercising the phase rule.
_module_on() {
  _mo_root=$1
  _mo_name=$2
  _mo_phase=$3
  printf '%s\n' \
    "name=$_mo_name" 'requires=' 'optional=' 'shells=posix' 'platforms=any' \
    'side_effect=read-only' "exports=${_mo_name}_loaded" "load=modules/$_mo_name.sh" \
    "phase=$_mo_phase" >"$_mo_root/module.d/$_mo_name.meta"
  printf '%s_loaded() { :; }\n' "$_mo_name" >"$_mo_root/modules/$_mo_name.sh"
  unset _mo_root _mo_name _mo_phase
}
_module_on "$_cross_proj" crossint interactive
sed 's/^requires=.*/requires=crossint/' "$_cross_proj/module.d/phase_env.meta" >"$_tmp/cross.meta" &&
  mv "$_tmp/cross.meta" "$_cross_proj/module.d/phase_env.meta"
printf 'bundle\tshell\troots\ndefault\tbash\tphase_env\n' >"$_cross_proj/bundles.tsv"
if ( cd "$_cross_proj" && "$_valise" build >"$_tmp/cross.out" 2>"$_tmp/cross.err" ); then
  fail "compile rejects an env module that requires an interactive one"
  cat "$_tmp/cross.out" >&2
elif grep -F 'env module phase_env requires interactive module crossint' "$_tmp/cross.err" >/dev/null; then
  pass "compile rejects an env module that requires an interactive one"
else
  fail "compile did not name both modules in the cross-phase diagnostic"
  cat "$_tmp/cross.err" >&2
fi

# A required dependency that FAILED in the env phase must still block its
# interactive dependent. Each plan used to initialise _valise_plan_unavailable
# to empty and the env plan discarded it before returning, so the interactive
# body ran against a missing dependency. _valise_plan_carried now links the two
# plans within one evaluation. Strict stops at the env failure; permissive
# continues but must record the failure and block the dependent.
for _cx_mode in strict permissive; do
  VALISE_MODE=$_cx_mode VALISE_MODULE_ROOT="$_tmp/release-cross-phase" "$_bash_bin" -c '
    # A plan returns (not exits), so it must be sourced inside a function: at
    # the top level of a -c script, `return 42` would end the whole shell.
    _cx_run() {
      . "$VALISE_MODULE_ROOT/plans/bash.sh"
      _env_rc=$?
      if [ -f "$VALISE_MODULE_ROOT/plans/bash-interactive.sh" ]; then
        . "$VALISE_MODULE_ROOT/plans/bash-interactive.sh"
      fi
      printf "env_rc=%s int_loaded=%s\n" "$_env_rc" "${_valise_interactive_loaded:-unset}"
    }
    _cx_run
  ' >"$_tmp/cx-$_cx_mode.out" 2>"$_tmp/cx-$_cx_mode.err" || :
  if grep -F 'CX_INT_BODY' "$_tmp/cx-$_cx_mode.out" >/dev/null; then
    fail "a required env failure blocks its interactive dependent ($_cx_mode)"
    cat "$_tmp/cx-$_cx_mode.out" "$_tmp/cx-$_cx_mode.err" >&2
  elif grep -F 'CX_ENV_BODY' "$_tmp/cx-$_cx_mode.out" >/dev/null; then
    pass "a required env failure blocks its interactive dependent ($_cx_mode)"
  else
    fail "the cross-phase fixture did not run its env module ($_cx_mode)"
    cat "$_tmp/cx-$_cx_mode.out" "$_tmp/cx-$_cx_mode.err" >&2
  fi
done

# The reload prelude clears only exports valise itself installed. A caller
# function that collides with a module export is reported on the FIRST pass and
# again on a reload pass - it is never silently replaced, because valise never
# owned it.
# The diagnostics go to a file both passes append to, so the count covers both.
OWNER_ERR="$_tmp/owner.err" : >"$_tmp/owner.err"
OWNER_ERR="$_tmp/owner.err" VALISE_MODULE_ROOT="$_tmp/release-ownership" "$_bash_bin" -c '
  owner_probe_fn() { printf "USER\n"; }
  printf "before=%s\n" "$(owner_probe_fn)"
  . "$VALISE_MODULE_ROOT/plans/bash.sh" 2>>"$OWNER_ERR"
  printf "first=%s\n" "$(owner_probe_fn)"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh" 2>>"$OWNER_ERR"
  printf "second=%s\n" "$(owner_probe_fn)"
' >"$_tmp/owner.out" 2>/dev/null || :
_owner_conflicts=$(grep -cF 'declared export already exists before load: owner_probe_fn' "$_tmp/owner.err" || :)
case "$_owner_conflicts" in '' | *[!0-9]*) _owner_conflicts=0 ;; esac
if grep -Fx 'before=USER' "$_tmp/owner.out" >/dev/null &&
  grep -Fx 'first=USER' "$_tmp/owner.out" >/dev/null &&
  grep -Fx 'second=USER' "$_tmp/owner.out" >/dev/null &&
  [ "$_owner_conflicts" -eq 2 ]; then
  pass "an automatic reload never takes over a caller-owned function"
else
  fail "an automatic reload replaced a caller-owned function"
  cat "$_tmp/owner.out" "$_tmp/owner.err" >&2
fi
# A module valise DID install is cleared and reinstalled on a reload pass with
# no conflict diagnostic: ownership, not a guess from having attempted a load.
VALISE_MODULE_ROOT="$_tmp/release-reload" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh"
  printf "reload_ok=%s owned=%s\n" "$(command -v reload_probe_loaded >/dev/null && echo yes)" "${_valise_plan_owned:-unset}"
' >"$_tmp/owned-reload.out" 2>"$_tmp/owned-reload.err"
if grep -Fx 'reload_ok=yes owned=reload_probe:reload_probe_loaded' "$_tmp/owned-reload.out" >/dev/null &&
  [ ! -s "$_tmp/owned-reload.err" ]; then
  pass "a reload clears only the exports valise installed, recorded against their provider module, and reports no conflict"
else
  fail "a reload did not record or clear its own exports correctly"
  cat "$_tmp/owned-reload.out" "$_tmp/owned-reload.err" >&2
fi

# A module that FAILS on a reload must take its ownership token with it. The
# prelude unsets the function; if the token survived, the next reload would
# find it and silently unset whatever the caller had since defined under that
# name, instead of reporting the collision.
_stale_src="$_tmp/stale-src"
_stale_rel="$_tmp/stale-rel"
mkdir -p "$_stale_src/module.d" "$_stale_src/modules"
: >"$_stale_src/valise.conf"
printf '%s\n' 'name=stalemod' 'version=' 'side_effect=read-only' 'requires=' 'optional=' \
  'shells=posix' 'platforms=any' 'exports=stale_fn' 'load=modules/stalemod.sh' \
  >"$_stale_src/module.d/stalemod.meta"
printf '%s\n' '[ ! -f "$STALE_FAIL" ] || return 42' 'stale_fn() { printf "OWN\n"; }' \
  >"$_stale_src/modules/stalemod.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tstalemod\n' >"$_stale_src/bundles.tsv"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_stale_src/variants.tsv"
rm -rf "$_stale_rel"
( cd "$_stale_src" && "$_valise" build "$_stale_rel" ) >/dev/null 2>&1
STALE_FAIL="$_tmp/stale-fail" STALE_ERR="$_tmp/stale.err" VALISE_MODULE_ROOT="$_stale_rel" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  printf "first_owned=[%s]\n" "${_valise_plan_owned:-}"
  : >"$STALE_FAIL"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh" 2>/dev/null
  printf "failed_owned=[%s]\n" "${_valise_plan_owned:-}"
  rm -f "$STALE_FAIL"
  stale_fn() { printf "CALLER\n"; }
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh" 2>>"$STALE_ERR"
  printf "final_owned=[%s]\n" "${_valise_plan_owned:-}"
  printf "caller_fn=%s\n" "$(stale_fn)"
' >"$_tmp/stale.out" 2>/dev/null || :
if grep -Fx 'failed_owned=[]' "$_tmp/stale.out" >/dev/null &&
  grep -Fx 'caller_fn=CALLER' "$_tmp/stale.out" >/dev/null &&
  grep -F 'declared export already exists before load: stale_fn' "$_tmp/stale.err" >/dev/null; then
  pass "a failed reload drops the export's ownership token instead of claiming a function valise no longer provides"
else
  fail "a failed reload left a stale ownership token that unset a caller's function"
  cat "$_tmp/stale.out" "$_tmp/stale.err" >&2 2>/dev/null || :
fi

# The ownership token must be dropped by the PRELUDE, on every shell, BEFORE the
# module body can re-add it. zsh does not word-split an unquoted expansion, so a
# `for tok in $ledger` implementation silently kept every token there while
# looking correct under bash. Each shell runs the prelude alone, against a
# hand-built ledger, so only the removal is under test.
sed -n '/^if \[ "\${VALISE_RELOAD:-}" = 1 \]; then$/,/^fi$/p' \
  "$_tmp/release-reload/plans/bash.sh" >"$_tmp/prune-prelude.sh"
if [ -s "$_tmp/prune-prelude.sh" ]; then
  for _pr_sh in /bin/sh /bin/dash /bin/bash /bin/zsh /bin/ksh; do
    [ -x "$_pr_sh" ] || continue
    _pr_out=$(
      "$_pr_sh" -c '
        . "$1"
        reload_probe_loaded() { :; }
        _valise_plan_owned="a:b reload_probe:reload_probe_loaded c:d"
        VALISE_RELOAD=1
        . "$1"
        printf "owned=[%s] fn=%s\n" "$_valise_plan_owned" \
          "$(command -v reload_probe_loaded >/dev/null 2>&1 && echo set || echo unset)"
      ' -- "$_tmp/prune-prelude.sh" 2>&1
    )
    if printf '%s\n' "$_pr_out" | grep -Fxq 'owned=[a:b c:d] fn=unset'; then
      pass "the reload prelude drops its ownership token and unsets the function ($_pr_sh)"
    else
      fail "the reload prelude did not drop its ownership token under $_pr_sh"
      printf '%s\n' "$_pr_out" >&2
    fi
  done
else
  fail "could not extract the reload prelude from the compiled plan"
fi

# Case-distinct provider names across releases must not be conflated when Bash
# has `shopt -s nocasematch` enabled (control: nocasematch off; regression: on).
_nc_a="$_tmp/nc-a"
_nc_b="$_tmp/nc-b"
mkdir -p "$_nc_a/module.d" "$_nc_a/modules" "$_nc_b/module.d" "$_nc_b/modules"
: >"$_nc_a/valise.conf"
: >"$_nc_b/valise.conf"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_nc_a/variants.tsv"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_nc_b/variants.tsv"
printf 'name=caseMod\nversion=\nside_effect=read-only\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=review_common\nload=modules/cm.sh\n' >"$_nc_a/module.d/caseMod.meta"
printf 'review_common() { printf "A\\n"; }\n' >"$_nc_a/modules/cm.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tcaseMod\n' >"$_nc_a/bundles.tsv"
printf 'name=casemod\nversion=\nside_effect=read-only\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=review_common\nload=modules/cm.sh\n' >"$_nc_b/module.d/casemod.meta"
printf 'review_common() { printf "B\\n"; }\n' >"$_nc_b/modules/cm.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tcasemod\n' >"$_nc_b/bundles.tsv"
rm -rf "$_tmp/nc-rel-a" "$_tmp/nc-rel-b"
(cd "$_nc_a" && "$_valise" build "$_tmp/nc-rel-a") >/dev/null 2>&1
(cd "$_nc_b" && "$_valise" build "$_tmp/nc-rel-b") >/dev/null 2>&1
for _nc_mode in off on; do
  _nc_out=$("$_bash_bin" -c '
    if [ "$1" = on ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
    VALISE_MODULE_ROOT="$2"
    . "$VALISE_MODULE_ROOT/plans/bash.sh"
    printf "before=%s ledger=%s\n" "$(review_common)" "${_valise_plan_owned:-}"
    VALISE_MODULE_ROOT="$3"
    VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh" 2>"$4"
    printf "rc=%s after=%s ledger=%s\n" "$?" "$(review_common)" "${_valise_plan_owned:-}"
    shopt -q nocasematch && printf "opt=on\n" || printf "opt=off\n"
  ' -- "$_nc_mode" "$_tmp/nc-rel-a" "$_tmp/nc-rel-b" "$_tmp/nc-$_nc_mode.err" 2>/dev/null || :)
  if printf '%s\n' "$_nc_out" | grep -Fx 'before=A ledger=caseMod:review_common' >/dev/null &&
    printf '%s\n' "$_nc_out" | grep -Fx 'rc=1 after=A ledger=caseMod:review_common' >/dev/null &&
    printf '%s\n' "$_nc_out" | grep -Fx "opt=$_nc_mode" >/dev/null &&
    grep -F 'declared export already exists before load: review_common' "$_tmp/nc-$_nc_mode.err" >/dev/null; then
    pass "provider ownership ledger stays byte-exact with nocasematch $_nc_mode"
  else
    fail "provider ownership ledger conflated case-distinct providers with nocasematch $_nc_mode"
    printf '%s\n' "$_nc_out" >&2
    cat "$_tmp/nc-$_nc_mode.err" >&2 2>/dev/null || :
  fi
done

# Phase migration across a release switch: a module that was env-phase in the
# release this process loaded and is interactive-phase in the next one must be
# reloaded when the block re-sources. The reload decision is per RELEASE, not
# per stage, which is what makes the new interactive plan succeed instead of
# reporting valise's own earlier definition as a foreign conflict.
_mig_env="$_tmp/migrate-a"
_mig_int="$_tmp/migrate-b"
for _mig_pair in "$_mig_env:env" "$_mig_int:interactive"; do
  _mig_dir=${_mig_pair%:*}
  _mig_phase=${_mig_pair#*:}
  mkdir -p "$_mig_dir/module.d" "$_mig_dir/modules"
  : >"$_mig_dir/valise.conf"
  printf '%s\n' 'name=mover' 'version=' 'side_effect=read-only' 'requires=' 'optional=' \
    'shells=posix' 'platforms=any' 'exports=mover_fn' 'load=modules/mover.sh' \
    >"$_mig_dir/module.d/mover.meta"
  [ "$_mig_phase" = env ] || printf 'phase=interactive\n' >>"$_mig_dir/module.d/mover.meta"
  printf 'mover_fn() { printf "IMPL-%s\\n"; }\n' "$_mig_phase" >"$_mig_dir/modules/mover.sh"
  printf '# bundle\tshell\troots\ndefault\tbash\tmover\n' >"$_mig_dir/bundles.tsv"
  printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_mig_dir/variants.tsv"
done
rm -rf "$_tmp/migrate-rel-a" "$_tmp/migrate-rel-b"
( cd "$_mig_env" && "$_valise" build "$_tmp/migrate-rel-a" ) >/dev/null 2>&1
( cd "$_mig_int" && "$_valise" build "$_tmp/migrate-rel-b" ) >/dev/null 2>&1
VALISE_MODULE_ROOT="$_tmp/migrate-rel-a" "$_bash_bin" -c '
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh"
  printf "before=%s\n" "$(mover_fn)"
  VALISE_MODULE_ROOT="'"$_tmp"'/migrate-rel-b"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash-interactive.sh"
  printf "after=%s\n" "$(mover_fn)"
' >"$_tmp/migrate.out" 2>"$_tmp/migrate.err" || :
if grep -Fx 'before=IMPL-env' "$_tmp/migrate.out" >/dev/null &&
  grep -Fx 'after=IMPL-interactive' "$_tmp/migrate.out" >/dev/null &&
  ! grep -F 'already exists before load' "$_tmp/migrate.err" >/dev/null; then
  pass "a module moved from env to interactive phase reloads cleanly"
else
  fail "a module moved from env to interactive phase did not reload"
  cat "$_tmp/migrate.out" "$_tmp/migrate.err" >&2
fi

if [ -f "$_tmp/release-phase/plans/commands/phase_interactive.sh" ] &&
  grep -F '# plan=bash phase=all' "$_tmp/release-phase/plans/commands/phase_interactive.sh" >/dev/null &&
  grep -F 'phase_interactive@' "$_tmp/release-phase/plans/commands/phase_interactive.sh" >/dev/null; then
  pass "a command plan renders the whole closure regardless of phase"
else
  fail "a command plan was filtered by phase"
  head -6 "$_tmp/release-phase/plans/commands/phase_interactive.sh" >&2 2>/dev/null || :
fi

# Runtime proof: the env plan loads env exports only and stays silent; the
# interactive plan loads the interactive export after the env plan.
if VALISE_MODULE_ROOT="$_tmp/release-phase" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  if command -v phase_env_loaded >/dev/null && ! command -v phase_interactive_loaded >/dev/null; then
    printf "env-only=yes\n"
  else
    printf "env-only=no\n"
  fi
' >"$_tmp/phase-env.out" 2>"$_tmp/phase-env.err" &&
  grep -F 'env-only=yes' "$_tmp/phase-env.out" >/dev/null &&
  [ ! -s "$_tmp/phase-env.err" ]; then
  pass "sourcing the env plan loads env modules and stays silent"
else
  fail "sourcing the env plan loads env modules and stays silent"
  cat "$_tmp/phase-env.out" "$_tmp/phase-env.err" >&2
fi
if VALISE_MODULE_ROOT="$_tmp/release-phase" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  . "$VALISE_MODULE_ROOT/plans/bash-interactive.sh"
  if command -v phase_env_loaded >/dev/null && command -v phase_interactive_loaded >/dev/null; then
    printf "both=yes\n"
  else
    printf "both=no\n"
  fi
' >"$_tmp/phase-int.out" 2>"$_tmp/phase-int.err" &&
  grep -F 'both=yes' "$_tmp/phase-int.out" >/dev/null; then
  pass "sourcing the interactive plan after the env plan loads the interactive module"
else
  fail "sourcing the interactive plan after the env plan loads the interactive module"
  cat "$_tmp/phase-int.out" "$_tmp/phase-int.err" >&2
fi

# Fixed-point proof: sourcing the env plan twice in one shell yields a
# byte-identical exported environment, and after a simulated path_helper
# reorder re-sourcing restores the compiled PATH order front-most.
if VALISE_MODULE_ROOT="$_tmp/release-phase" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  env | LC_ALL=C sort >"'"$_tmp"'/fp1.env"
  PATH="/usr/bin:/bin:/reordered/helper:$PATH"
  export PATH
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh"
  env | LC_ALL=C sort >"'"$_tmp"'/fp2.env"
  VALISE_RELOAD=1 . "$VALISE_MODULE_ROOT/plans/bash.sh"
  env | LC_ALL=C sort >"'"$_tmp"'/fp3.env"
  case "$PATH" in
    /usr/local/bin:*) printf "front=yes\n" ;;
    *) printf "front=no path=%s\n" "$PATH" ;;
  esac
' >"$_tmp/phase-fp.out" 2>"$_tmp/phase-fp.err" &&
  for f in fp1 fp2 fp3; do
    grep -av '^PATH=' "$_tmp/$f.env" | LC_ALL=C sort > "$_tmp/$f.rest"
  done

  grep -a '^PATH=' "$_tmp/fp1.env" > "$_tmp/fp1.path" &&
  grep -a '^PATH=' "$_tmp/fp2.env" > "$_tmp/fp2.path" &&
  grep -a '^PATH=' "$_tmp/fp3.env" > "$_tmp/fp3.path" &&
  cmp -s "$_tmp/fp2.path" "$_tmp/fp3.path" &&
  cmp -s "$_tmp/fp2.rest" "$_tmp/fp3.rest" &&
  grep -F 'front=yes' "$_tmp/phase-fp.out" >/dev/null; then
  pass "env plan is a fixed-point projection: double source is byte-identical and re-asserts PATH"
else
  fail "env plan is a fixed-point projection: double source is byte-identical and re-asserts PATH"
  cat "$_tmp/phase-fp.out" "$_tmp/phase-fp.err" >&2
  diff -u "$_tmp/fp2.path" "$_tmp/fp3.path" >&2 || :
fi

# Strict mode stops at the first failing module and names it.
if VALISE_MODULE_ROOT="$_tmp/release-behavior" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  _status=$?
  printf "status=%s\n" "$_status"
  if command -v first_fail_loaded >/dev/null; then printf "first=loaded\n"; else printf "first=absent\n"; fi
  if command -v later_ok_loaded >/dev/null; then printf "later=loaded\n"; else printf "later=skipped\n"; fi
  exit "$_status"
' >"$_tmp/behavior-strict.out" 2>"$_tmp/behavior-strict.err"; then
  fail "strict plan returns failure"
else
  _status=$?
  if grep -F 'status=1' "$_tmp/behavior-strict.out" >/dev/null &&
    grep -F 'first=absent' "$_tmp/behavior-strict.out" >/dev/null &&
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
if ! VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-behavior" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  _status=$?
  printf "status=%s\n" "$_status"
  if command -v first_fail_loaded >/dev/null; then printf "first=loaded\n"; else printf "first=absent\n"; fi
  command -v later_ok_loaded >/dev/null && printf "later=loaded\n"
  exit "$_status"
' >"$_tmp/behavior-permissive.out" 2>"$_tmp/behavior-permissive.err"; then
  fail "permissive plan returns success after a failure"
else
  if grep -F 'status=0' "$_tmp/behavior-permissive.out" >/dev/null &&
    grep -F 'first=absent' "$_tmp/behavior-permissive.out" >/dev/null &&
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
if VALISE_MODULE_ROOT="$_tmp/release-missing" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if grep -F '# order=meta_child meta_parent' "$_tmp/release-meta/plans/bash.sh" >/dev/null &&
  VALISE_MODULE_ROOT="$_tmp/release-meta" "$_bash_bin" -c '
    . "$VALISE_MODULE_ROOT/plans/bash.sh"
    command -v meta_child_loaded >/dev/null
  ' >"$_tmp/meta.out" 2>"$_tmp/meta.err"; then
  pass "meta module orders its dependency closure without a body"
else
  fail "meta module orders its dependency closure without a body"
  cat "$_tmp/meta.err" >&2
fi

# A root declared for another platform fails strict with a named diagnostic, as
# the loader does, and is skipped in permissive mode.
if VALISE_MODULE_ROOT="$_tmp/release-platform" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
' >"$_tmp/platform.out" 2>"$_tmp/platform.err"; then
  fail "strict plan fails on an unsupported root"
elif grep -F 'module platform_other skipped: unsupported platform' "$_tmp/platform.err" >/dev/null; then
  pass "strict plan fails on an unsupported root and names it"
else
  fail "strict plan fails on an unsupported root and names it"
  cat "$_tmp/platform.err" >&2
fi
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-platform" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODULE_ROOT="$_tmp/release-optional" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODULE_ROOT="$_tmp/release-optional-fail" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  command -v opt_fail_user_loaded >/dev/null
' >"$_tmp/optional-fail.out" 2>"$_tmp/optional-fail.err" &&
  grep -F 'module first_fail failed with status 1' "$_tmp/optional-fail.err" >/dev/null; then
  pass "a failing optional dependency does not fail strict mode"
else
  fail "a failing optional dependency does not fail strict mode"
  cat "$_tmp/optional-fail.err" >&2
fi

# An optional cycle cannot deadlock the plan; a required cycle still fails.
if VALISE_MODULE_ROOT="$_tmp/release-optional-cycle" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  command -v cycle_a_loaded >/dev/null && command -v cycle_b_loaded >/dev/null
' >"$_tmp/optional-cycle.out" 2>"$_tmp/optional-cycle.err"; then
  pass "an optional-only cycle still loads its members"
else
  fail "an optional-only cycle still loads its members"
  cat "$_tmp/optional-cycle.err" >&2
fi

# An optional edge into a required cycle is quarantined, as the loader does.
if VALISE_MODULE_ROOT="$_tmp/release-optional-required-cycle" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  command -v opt_req_cycle_user_loaded >/dev/null &&
    ! command -v opt_req_cycle_a_loaded >/dev/null &&
    ! command -v opt_req_cycle_b_loaded >/dev/null
' >"$_tmp/optional-required-cycle.out" 2>"$_tmp/optional-required-cycle.err"; then
  pass "an optional edge into a required cycle does not fail the plan"
else
  fail "an optional edge into a required cycle does not fail the plan"
  cat "$_tmp/optional-required-cycle.err" >&2
fi

# A meta module cannot declare exports: the loader and Fish fail it, so the
# compiled plan must reject it rather than silently ignoring the declaration.
rm -rf "$_tmp/release-meta-exports"
if (cd "$_project" && "$_valise" compile --bundle=meta-exports "$_tmp/release-meta-exports") \
  >"$_tmp/meta-exports.out" 2>"$_tmp/meta-exports.err"; then
  fail "compile rejects a meta module that declares exports"
elif grep -F 'meta module meta_export_bad declares exports without a body' "$_tmp/meta-exports.err" >/dev/null; then
  pass "compile rejects a meta module that declares exports"
else
  fail "compile rejects a meta module that declares exports"
  cat "$_tmp/meta-exports.err" >&2
fi

# A platform-unsupported module in the required closure stops a strict plan before
# anything that depends on it runs.
: >"$_tmp/blocked.trace"
if VALISE_MODULE_ROOT="$_tmp/release-blocked-platform" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-platform" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-failed" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODE=permissive VALISE_MODULE_ROOT="$_tmp/release-blocked-meta" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  ! command -v meta_other_user_loaded >/dev/null
' >"$_tmp/blocked-meta.out" 2>"$_tmp/blocked-meta.err" &&
  grep -F 'module meta_other_user skipped: required dependency unavailable: meta_other' "$_tmp/blocked-meta.err" >/dev/null; then
  pass "platform-gated meta module blocks its dependents"
else
  fail "platform-gated meta module blocks its dependents"
  cat "$_tmp/blocked-meta.err" >&2
fi

# A layer meta module has no body, so the plan must not source a directory.
if ! grep -F 'layers/demo/"' "$_tmp/release-layer-meta/plans/bash.sh" >/dev/null &&
  VALISE_MODULE_ROOT="$_tmp/release-layer-meta" "$_bash_bin" -c '
    . "$VALISE_MODULE_ROOT/plans/bash.sh" && command -v contrib_demo_child_loaded >/dev/null
  ' >"$_tmp/layer-meta.out" 2>"$_tmp/layer-meta.err"; then
  pass "layer meta module compiles without a load path"
else
  fail "layer meta module compiles without a load path"
  cat "$_tmp/layer-meta.err" >&2
fi

# Capability functions remain available after the plan finishes.
if VALISE_MODULE_ROOT="$_tmp/release-capability" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
printf '%s\n' 'bad ((' >"$_tmp/release-prelude-failure/runtime/capabilities.sh"
if VALISE_MODULE_ROOT="$_tmp/release-prelude-failure" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODULE_ROOT="$_tmp/release-reload" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  printf "first=%s\n" "$?"
  VALISE_RELOAD=1
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if PATH="$_tmp/fakebin:$PATH" VALISE_MODULE_ROOT="$_tmp/release-wrapper-ok" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
  [ "$(command -v wrapper_probe)" = wrapper_probe ]
' >"$_tmp/wrapper-ok.out" 2>"$_tmp/wrapper-ok.err"; then
  pass "wrapper export replaces an external command with a function"
else
  fail "wrapper export replaces an external command with a function"
  cat "$_tmp/wrapper-ok.err" >&2
fi
if PATH="$_tmp/fakebin:$PATH" VALISE_MODULE_ROOT="$_tmp/release-wrapper-missing" "$_bash_bin" -c '
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
' >"$_tmp/wrapper-missing.out" 2>"$_tmp/wrapper-missing.err"; then
  fail "unprovided wrapper export fails the plan"
else
  if grep -F 'wrapper_missing: declared export missing: wrapper_missing_probe' \
    "$_tmp/wrapper-missing.err" >/dev/null; then
    pass "unprovided wrapper export is reported"
  else
    fail "unprovided wrapper export is reported"
    cat "$_tmp/wrapper-missing.err" >&2
  fi
fi

# Existing functions and aliases are rejected before the module body runs.
rm -f "$_tmp/conflict-function.trace"
if VALISE_MODULE_ROOT="$_tmp/release-conflict-function" "$_bash_bin" -c '
  existing_probe() { :; }
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
if VALISE_MODULE_ROOT="$_tmp/release-conflict-alias" "$_bash_bin" -c '
  shopt -s expand_aliases
  alias existing_alias_probe=/bin/true
  . "$VALISE_MODULE_ROOT/plans/bash.sh"
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
# Metadata validation already refuses one, so the compiler check is defence in
# depth: feed the compiler a stream that carries such a row and require it to
# reject the module by name instead of emitting a plan that does nothing.
printf 'SEED:bodyless_orphan@module.d\nPRELUDE:sp_cap_os\nMOD:bodyless_orphan@module.d\t\t\tany\tread-only\t\t\n' \
  >"$_tmp/bodyless.stream"
if awk -v target_shell=bash -v plan_name=bash -f "$_repo/lib/compiler.awk" "$_tmp/bodyless.stream" \
  >"$_tmp/bodyless.out" 2>"$_tmp/bodyless.err"; then
  fail "compiler rejects a bodyless module with no dependencies"
elif grep -F 'module bodyless_orphan has no load path and no dependencies' "$_tmp/bodyless.err" >/dev/null; then
  pass "compiler rejects a bodyless module with no dependencies by name"
else
  fail "compiler rejects a bodyless module with no dependencies by name"
  cat "$_tmp/bodyless.err" >&2
fi
_reject_meta bodyless_orphan 'metadata: missing required metadata field: load or requires' \
  name=bodyless_orphan version= side_effect=read-only requires= optional= shells=bash platforms=any exports=

# Values that would change case dispatch or plan source text are rejected up
# front. Unsafe registry sources and layer names are covered by the registry
# contract, where the sources are discovered.
_reject_meta brack 'metadata: invalid module name: brack[1]' \
  'name=brack[1]' version= side_effect=read-only requires= optional= shells=bash platforms=any exports= load=modules/first_fail.sh
_reject_meta missing_platform 'metadata: missing required metadata field: platforms' \
  name=missing_platform version= side_effect=read-only requires= optional= shells=bash exports= load=modules/first_fail.sh
_reject_meta bad_effect 'metadata: invalid side_effect: weird-effect' \
  name=bad_effect version= side_effect=weird-effect requires= optional= shells=bash platforms=any exports= load=modules/first_fail.sh
_reject_meta reserved_export 'metadata: invalid export (reserved word): if' \
  name=reserved_export version= side_effect=read-only requires= optional= shells=bash platforms=any exports=if load=modules/first_fail.sh
_reject_meta bad_exports 'metadata: invalid export: bad_exports$(id)' \
  name=bad_exports version= side_effect=read-only requires= optional= shells=bash platforms=any 'exports=bad_exports$(id)' load=modules/first_fail.sh

# The generated header names valise, and rebuilding is deterministic.
if grep -F '# Generated by valise compile; DO NOT EDIT.' \
  "$_tmp/release-reload/plans/bash.sh" >/dev/null; then
  pass "plan header names valise"
else
  fail "plan header names valise"
fi

# The header names the plan format version. A consumer that reads the plan
# must be able to tell which format it is holding, so the marker is pinned.
if grep -F '# valise-plan-v2' \
  "$_tmp/release-reload/plans/bash.sh" >/dev/null; then
  pass "plan header names the plan format version"
else
  fail "plan header names the plan format version"
  head -5 "$_tmp/release-reload/plans/bash.sh" >&2
fi
rm -rf "$_tmp/release-reload-2"
if (cd "$_project" && "$_valise" build --bundle=reload "$_tmp/release-reload-2") \
  >"$_tmp/reload-2.out" 2>"$_tmp/reload-2.err" &&
  cmp -s "$_tmp/release-reload/manifest.tsv" \
    "$_tmp/release-reload-2/manifest.tsv"; then
  pass "repeated build produces an identical manifest"
else
  fail "repeated build produces an identical manifest"
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
  PARITY_MODE=$_pl_mode PARITY_WANTED=$_pl_wanted PARITY_PROBES=$_parity_probes PARITY_ROOT=$_project \
    "$_bash_bin" -c '
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
    "$_bash_bin" -c '
      . "$VALISE_MODULE_ROOT/plans/bash.sh"
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

# Every POSIX runtime must apply the same export and failure contract. These
# fixtures use only POSIX bodies; loading their compiled bash plans directly
# isolates plan semantics from startup-file selection (tested separately).
_contract="$_tmp/runtime-contract"
mkdir -p "$_contract/module.d" "$_contract/modules" "$_tmp/contract-bin"
: >"$_contract/valise.conf"
printf 'variant\tdescription\texcluded\ndefault\tall\t\n' >"$_contract/variants.tsv"
: >"$_contract/bundles.tsv"
_contract_module() {
  printf '%s\n' "name=$1" 'version=' "requires=$2" "exports=$3" "phase=$4" \
    "optional=$5" "side_effect=$6" 'shells=posix' 'platforms=any' "load=modules/$1.sh" \
    >"$_contract/module.d/$1.meta"
  printf '%s\n' "$7" >"$_contract/modules/$1.sh"
}
_contract_module case_mod '' case_upper env '' read-only 'case_upper() { printf upper; }'
_contract_module case_lower_mod '' case_lower env '' read-only 'case_lower() { printf lower; }'
_contract_module case_dep '' '' env '' read-only 'return 41'
_contract_module case_dep_lower '' case_dep_fn env '' read-only '[ "${FAIL_CASE_DEP:-0}" != 1 ] || return 42
case_dep_fn() { :; }'
_contract_module case_root '' '' env case_dep read-only ':'
_contract_module case_int case_dep_lower case_int_fn interactive '' read-only 'case_int_fn() { printf dependent; }'
_contract_module wrapper '' contract_wrapper env '' read-only '[ "${FAIL_CONTRACT_RELOAD:-0}" != 1 ] || return 42
contract_wrapper() { printf wrapped; }'
_contract_module externalonly '' contract_external env '' read-only ':'
_contract_module pathonly valise_path contract_external env '' path-env 'valise_path_prepend "$CONTRACT_BIN"'
_contract_module aliasonly '' 'contract_one contract_alias' env '' read-only 'contract_one() { :; }
alias contract_alias="printf alias-only"'
_contract_module failpair '' 'contract_one contract_two' env '' read-only 'contract_one() { :; }
contract_two() { :; }
return 42'
_contract_module missingpair '' 'contract_one contract_two' env '' read-only 'contract_one() { :; }'
_contract_module guardfunction '' 'contract_keep contract_new' env '' read-only 'printf body >"$CONTRACT_TRACE"
contract_keep() { :; }
contract_new() { :; }'
_contract_module guardalias '' contract_alias env '' read-only 'printf body >"$CONTRACT_TRACE"
contract_alias() { :; }'
_contract_module guardbuiltin '' true env '' read-only 'printf body >"$CONTRACT_TRACE"
true() { return 99; }'
for _ct_bundle in order dependency wrapper externalonly pathonly aliasonly failpair missingpair guardfunction guardalias guardbuiltin; do
  case "$_ct_bundle" in
  order) _ct_roots='case_mod case_lower_mod' ;;
  dependency) _ct_roots='case_root case_int' ;;
  *) _ct_roots=$_ct_bundle ;;
  esac
  printf '%s\tbash\t%s\n' "$_ct_bundle" "$_ct_roots" >>"$_contract/bundles.tsv"
done
for _ct_bundle in order dependency wrapper externalonly pathonly aliasonly failpair missingpair guardfunction guardalias guardbuiltin; do
  if ! "$_valise" -C "$_contract" build --bundle="$_ct_bundle" "$_tmp/contract-$_ct_bundle" \
    >"$_tmp/contract-build.out" 2>&1; then
    fail "build runtime contract fixture $_ct_bundle"
    cat "$_tmp/contract-build.out" >&2
    exit 1
  fi
done
for _ct_cmd in contract_wrapper contract_external; do
  printf '#!/bin/sh\nprintf external\n' >"$_tmp/contract-bin/$_ct_cmd"
  chmod 0755 "$_tmp/contract-bin/$_ct_cmd"
done
cat >"$_tmp/contract-runner.sh" <<'EOF'
if [ -n "${BASH_VERSION-}" ]; then
  if [ "$CONTRACT_NOCASE" = on ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
fi
_ct_options=$(set +o)
_ct_bash_options=${BASHOPTS-}
_ct_path=$PATH
_ct_load() { . "$VALISE_MODULE_ROOT/plans/bash.sh"; }
_ct_unowned() {
  case " ${_valise_plan_owned:-} " in *" $1:"*) return 1 ;; esac
}
_ct_absent() {
  ! (PATH=/dev/null; command -v "$1") >/dev/null 2>&1
}
case "$CONTRACT_CASE" in
order)
  _ct_load || exit 11
  [ "$(case_upper):$(case_lower)" = upper:lower ] || exit 12
  [ "${_valise_plan_owned:-}" = 'case_lower_mod:case_lower case_mod:case_upper' ] || exit 13
  ;;
dependency-present|dependency-missing)
  FAIL_CASE_DEP=0
  [ "$CONTRACT_CASE" != dependency-missing ] || FAIL_CASE_DEP=1
  _ct_env=0
  _ct_load || _ct_env=$?
  _ct_int=0
  . "$VALISE_MODULE_ROOT/plans/bash-interactive.sh" || _ct_int=$?
  if [ "$FAIL_CASE_DEP" -eq 0 ]; then
    [ "$_ct_env:$_ct_int:$(case_int_fn)" = 0:0:dependent ] || exit 21
  else
    [ "$_ct_env:$_ct_int" = 42:1 ] && _ct_absent case_int_fn || exit 22
  fi
  ;;
wrapper)
  [ "$(command contract_wrapper)" = external ] || exit 31
  _ct_load || exit 32
  [ "$(contract_wrapper)" = wrapped ] || exit 33
  [ "${_valise_plan_owned:-}" = wrapper:contract_wrapper ] || exit 34
  ;;
reload|reload-failure)
  _ct_load || exit 35
  VALISE_RELOAD=1
  if [ "$CONTRACT_CASE" = reload ]; then
    contract_wrapper() { printf caller-replacement; }
    _ct_load || exit 36
    [ "$(contract_wrapper)" = wrapped ] &&
      [ "${_valise_plan_owned:-}" = wrapper:contract_wrapper ] || exit 37
  else
    FAIL_CONTRACT_RELOAD=1
    _ct_rc=0
    _ct_load || _ct_rc=$?
    [ "$_ct_rc" -eq 42 ] && _ct_absent contract_wrapper && _ct_unowned wrapper || exit 38
    FAIL_CONTRACT_RELOAD=0
    contract_wrapper() { printf caller; }
    _ct_rc=0
    _ct_load || _ct_rc=$?
    [ "$_ct_rc" -eq 1 ] && [ "$(contract_wrapper)" = caller ] && _ct_unowned wrapper || exit 39
  fi
  ;;
externalonly|pathonly)
  if [ "$CONTRACT_CASE" = pathonly ]; then
    command -v contract_external >/dev/null 2>&1 && exit 41
  else
    [ "$(command contract_external)" = external ] || exit 42
  fi
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq 1 ] && _ct_unowned "$CONTRACT_CASE" && _ct_absent contract_external || exit 43
  [ "$(command contract_external)" = external ] || exit 44
  if [ "$CONTRACT_CASE" = pathonly ]; then _ct_path=$CONTRACT_BIN:$_ct_path; fi
  ;;
aliasonly)
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq 1 ] && _ct_unowned aliasonly && _ct_absent contract_one || exit 51
  ;;
failpair|missingpair)
  _ct_want=42
  [ "$CONTRACT_CASE" != missingpair ] || _ct_want=1
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq "$_ct_want" ] && _ct_unowned "$CONTRACT_CASE" &&
    _ct_absent contract_one && _ct_absent contract_two || exit 61
  ;;
guardfunction)
  contract_keep() { printf caller; }
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq 1 ] && [ ! -e "$CONTRACT_TRACE" ] &&
    [ "$(contract_keep)" = caller ] && _ct_absent contract_new && _ct_unowned guardfunction || exit 71
  ;;
guardalias)
  alias contract_alias='printf caller-alias'
  _ct_alias=$(alias contract_alias)
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq 1 ] && [ ! -e "$CONTRACT_TRACE" ] &&
    [ "$(alias contract_alias)" = "$_ct_alias" ] && _ct_unowned guardalias || exit 72
  ;;
guardbuiltin)
  _ct_rc=0
  _ct_load || _ct_rc=$?
  [ "$_ct_rc" -eq 1 ] && [ ! -e "$CONTRACT_TRACE" ] && true && _ct_unowned guardbuiltin || exit 73
  ;;
invalid-mode)
  for VALISE_MODE in STRICT PERMISSIVE; do
    _ct_rc=0
    _ct_load || _ct_rc=$?
    [ "$_ct_rc" -eq 1 ] && _ct_absent case_upper && _ct_unowned case_mod || exit 81
  done
  ;;
*) exit 91 ;;
esac
[ "$PATH" = "$_ct_path" ] || exit 92
[ "$(set +o)" = "$_ct_options" ] || exit 93
[ "${BASHOPTS-}" = "$_ct_bash_options" ] || exit 94
printf '%s:ok\n' "$CONTRACT_CASE"
EOF
for _ct_name in sh dash bash zsh ksh busybox; do
  _ct_shell=$(command -v "$_ct_name" 2>/dev/null || :)
  _ct_arg=
  _ct_label=$_ct_name
  if [ "$_ct_name" = busybox ]; then _ct_arg=ash; _ct_label=busybox-ash; fi
  if [ -z "$_ct_shell" ] || [ ! -x "$_ct_shell" ]; then
    case ",${VALISE_REQUIRED_PARSERS:-}," in
    *",$_ct_label,"*) fail "compiled-plan runtime $_ct_label is required but unavailable" ;;
    *) skip "compiled-plan runtime $_ct_label is unavailable" ;;
    esac
    continue
  fi
  for _ct_case in order dependency-present dependency-missing wrapper reload reload-failure externalonly pathonly aliasonly failpair missingpair guardfunction guardalias guardbuiltin invalid-mode; do
    case "$_ct_case" in
    dependency-*) _ct_bundle=dependency ;;
    reload*) _ct_bundle=wrapper ;;
    invalid-mode) _ct_bundle=order ;;
    *) _ct_bundle=$_ct_case ;;
    esac
    _ct_path=/usr/bin:/bin
    case "$_ct_case" in wrapper|externalonly) _ct_path=.:$_ct_path ;; esac
    # A relative PATH component is deliberate: some command -v implementations
    # return a bare filename for it, which used to look like a shell function.
    _ct_rc=0
    (cd "$_tmp/contract-bin" && env -i PATH="$_ct_path" HOME="$_tmp" \
      CONTRACT_BIN="$_tmp/contract-bin" CONTRACT_TRACE="$_tmp/contract-body.trace" \
      CONTRACT_CASE="$_ct_case" CONTRACT_NOCASE=on VALISE_MODULE_ROOT="$_tmp/contract-$_ct_bundle" \
      "$_ct_shell" ${_ct_arg:+"$_ct_arg"} "$_tmp/contract-runner.sh") \
      >"$_tmp/contract.out" 2>"$_tmp/contract.err" || _ct_rc=$?
    if [ "$_ct_rc" -eq 0 ] && grep -Fx "$_ct_case:ok" "$_tmp/contract.out" >/dev/null; then
      pass "compiled-plan $_ct_case preserves state and contract under $_ct_label"
    else
      fail "compiled-plan $_ct_case under $_ct_label (status $_ct_rc)"
      cat "$_tmp/contract.out" "$_tmp/contract.err" >&2
    fi
    rm -f "$_tmp/contract-body.trace"
  done
done
# The case-sensitive Bash baseline proves the on-option lanes use the same
# fixtures, rather than depending on the option itself to make them valid.
for _ct_case in order dependency-present dependency-missing invalid-mode; do
  case "$_ct_case" in dependency-*) _ct_bundle=dependency ;; *) _ct_bundle=order ;; esac
  if env -i PATH=/usr/bin:/bin HOME="$_tmp" CONTRACT_CASE="$_ct_case" CONTRACT_NOCASE=off \
    VALISE_MODULE_ROOT="$_tmp/contract-$_ct_bundle" "$_bash_bin" "$_tmp/contract-runner.sh" \
    >"$_tmp/contract.out" 2>"$_tmp/contract.err" &&
    grep -Fx "$_ct_case:ok" "$_tmp/contract.out" >/dev/null; then
    pass "compiled-plan $_ct_case with Bash nocasematch off"
  else
    fail "compiled-plan $_ct_case with Bash nocasematch off"
    cat "$_tmp/contract.out" "$_tmp/contract.err" >&2
  fi
done

printf '\n=== compiler-plan summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
