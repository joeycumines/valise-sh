#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Project layout and release v2 contract: valise.conf discovery and
# validation, module wiring in multi-root projects, engine modules available
# to every build, closure-only packaging, the POSIX block's retry rule, and
# status reporting what the active release was built with.

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
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-layout.XXXXXX")
_tmp=$(cd "$_tmp" && pwd -P)
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

_home="$_tmp/home"
mkdir -p "$_home"

# _v <project> <args...>: valise against a project with a private home.
_v() {
  _v_project=$1
  shift
  HOME="$_home" XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    "$_valise" -C "$_v_project" "$@"
}

# _meta <file> <name> <requires> <shells> <exports> [load]
_meta() {
  printf '%s\n' "name=$2" 'version=' 'side_effect=read-only' "requires=$3" 'optional=' \
    "shells=$4" 'platforms=any' "exports=$5" "load=${6:-}" >"$1"
}

printf '=== valise project layout and release v2 ===\n'
printf '  scratch: %s\n\n' "$_tmp"

# --- valise.conf validation ---

_cfg="$_tmp/cfg"
mkdir -p "$_cfg/module.d" "$_cfg/modules"
_meta "$_cfg/module.d/main.meta" main '' posix main_ready modules/main.sh
printf 'main_ready() { :; }\n' >"$_cfg/modules/main.sh"
printf 'bundle\tshell\troots\ndefault\tbash\tmain\n' >"$_cfg/bundles.tsv"

printf 'requires_valise=9.0.0\n' >"$_cfg/valise.conf"
if _v "$_cfg" build >/dev/null 2>"$_tmp/req.err"; then
  fail "a project requiring a newer valise is refused"
elif grep -F 'this project requires valise >= 9.0.0' "$_tmp/req.err" >/dev/null &&
  [ ! -e "$_cfg/build" ]; then
  pass "a project requiring a newer valise is refused before building"
else
  fail "a project requiring a newer valise is refused before building"
  cat "$_tmp/req.err" >&2
fi

printf 'requires_valise=0.1\n' >"$_cfg/valise.conf"
if _v "$_cfg" registry >/dev/null 2>&1; then
  pass "a project requiring an older valise is accepted"
else
  fail "a project requiring an older valise is accepted"
fi

printf 'variant=default\nregistry=committed\n' >"$_cfg/valise.conf"
if _v "$_cfg" registry >/dev/null 2>"$_tmp/key.err"; then
  fail "valise.conf rejects an unknown key"
elif grep -F 'valise.conf: unknown key: registry' "$_tmp/key.err" >/dev/null; then
  pass "valise.conf rejects an unknown key by name"
else
  fail "valise.conf rejects an unknown key by name"
  cat "$_tmp/key.err" >&2
fi

printf 'variant=a\nvariant=b\n' >"$_cfg/valise.conf"
if _v "$_cfg" registry >/dev/null 2>"$_tmp/dup.err"; then
  fail "valise.conf rejects a duplicate key"
elif grep -F 'valise.conf: duplicate key: variant' "$_tmp/dup.err" >/dev/null; then
  pass "valise.conf rejects a duplicate key by name"
else
  fail "valise.conf rejects a duplicate key by name"
  cat "$_tmp/dup.err" >&2
fi

# The 0.2 layout is not read: a shell/ tree without valise.conf is no project.
_old="$_tmp/old-layout"
mkdir -p "$_old/shell/module.d" "$_old/shell/release"
cp "$_cfg/module.d/main.meta" "$_old/shell/module.d/"
if (cd "$_old" && HOME="$_home" "$_valise" build) >/dev/null 2>"$_tmp/old.err"; then
  fail "a 0.2 shell/ layout is not accepted as a project"
elif grep -F 'not inside a valise project' "$_tmp/old.err" >/dev/null; then
  pass "a 0.2 shell/ layout is not accepted as a project"
else
  fail "a 0.2 shell/ layout is not accepted as a project"
  cat "$_tmp/old.err" >&2
fi

# Build from a subdirectory finds the project and writes its default output.
: >"$_cfg/valise.conf"
if (cd "$_cfg/modules" && HOME="$_home" "$_valise" build) >/dev/null 2>"$_tmp/subdir.err" &&
  [ -f "$_cfg/build/release/plans/bash.sh" ] && [ ! -e "$_cfg/modules/build" ]; then
  pass "build from a subdirectory builds the enclosing project"
else
  fail "build from a subdirectory builds the enclosing project"
  cat "$_tmp/subdir.err" >&2
fi

# --- module new wiring ---

_multi="$_tmp/multi"
mkdir -p "$_multi/module.d" "$_multi/modules"
: >"$_multi/valise.conf"
_meta "$_multi/module.d/root_a.meta" root_a '' posix root_a_ready modules/root_a.sh
_meta "$_multi/module.d/root_b.meta" root_b '' posix root_b_ready modules/root_b.sh
printf 'root_a_ready() { :; }\n' >"$_multi/modules/root_a.sh"
printf 'root_b_ready() { :; }\n' >"$_multi/modules/root_b.sh"
printf 'bundle\tshell\troots\ndefault\tbash\troot_a\ndefault\tzsh\troot_b\n' >"$_multi/bundles.tsv"
if _v "$_multi" module new extra >/dev/null 2>"$_tmp/multi.err"; then
  fail "module new refuses to guess between several bundle roots"
elif grep -F 'several roots (root_a root_b)' "$_tmp/multi.err" >/dev/null &&
  [ ! -e "$_multi/module.d/extra.meta" ]; then
  pass "module new refuses to guess between several bundle roots and names them"
else
  fail "module new refuses to guess between several bundle roots and names them"
  cat "$_tmp/multi.err" >&2
fi
if _v "$_multi" module new extra --into=root_a,root_b >/dev/null 2>"$_tmp/into.err" &&
  grep -Fx 'requires=extra' "$_multi/module.d/root_a.meta" >/dev/null &&
  grep -Fx 'requires=extra' "$_multi/module.d/root_b.meta" >/dev/null; then
  pass "module new --into wires the module into each named module"
else
  fail "module new --into wires the module into each named module"
  cat "$_tmp/into.err" >&2
fi
cp "$_multi/module.d/root_a.meta" "$_tmp/root_a.before"
if _v "$_multi" module new loose --no-wire >/dev/null 2>&1 &&
  [ -f "$_multi/module.d/loose.meta" ] && cmp -s "$_multi/module.d/root_a.meta" "$_tmp/root_a.before"; then
  pass "module new --no-wire creates the module without touching other metadata"
else
  fail "module new --no-wire creates the module without touching other metadata"
fi
if _v "$_multi" module new valise_mine --no-wire >/dev/null 2>"$_tmp/reserved.err"; then
  fail "module new rejects the reserved valise_ prefix"
elif grep -F 'reserved for engine modules' "$_tmp/reserved.err" >/dev/null; then
  pass "module new rejects the reserved valise_ prefix"
else
  fail "module new rejects the reserved valise_ prefix"
fi

# --- engine modules, closure-only packaging, retry, status ---

_proj="$_tmp/proj"
mkdir -p "$_proj/module.d" "$_proj/modules" "$_proj/layers/work/module.d" "$_proj/layers/work/modules"
printf 'bundle=default\nvariant=full\n' >"$_proj/valise.conf"
_meta "$_proj/module.d/profile_main.meta" profile_main 'valise_path greet' posix ''
_meta "$_proj/module.d/greet.meta" greet '' posix greet modules/greet.sh
printf '%s\n' '_greet_loads=$((${_greet_loads:-0} + 1))' \
  'greet() { printf "%s\n" "hello from greet"; }' >"$_proj/modules/greet.sh"
_meta "$_proj/layers/work/module.d/contrib_work_tool.meta" contrib_work_tool '' posix \
  work_tool modules/contrib_work_tool.sh
printf 'work_tool() { :; }\n' >"$_proj/layers/work/modules/contrib_work_tool.sh"
printf 'bundle\tshell\troots\ndefault\tsh\tprofile_main contrib_work_tool\ndefault\tbash\tprofile_main contrib_work_tool\ndefault\tzsh\tprofile_main contrib_work_tool\ndefault\tksh\tprofile_main contrib_work_tool\n' \
  >"$_proj/bundles.tsv"
printf 'variant\tdescription\texcluded\nfull\tEverything\t\npersonal\tNo work layer\tcontrib_work_tool\n' \
  >"$_proj/variants.tsv"

if _v "$_proj" build >/dev/null 2>"$_tmp/build-full.err"; then
  pass "a project requiring an engine module builds"
else
  fail "a project requiring an engine module builds"
  cat "$_tmp/build-full.err" >&2
fi
_rel="$_proj/build/release"
if [ -f "$_rel/valise/module.d/valise_path.meta" ] && [ -f "$_rel/valise/modules/system/valise_path.sh" ] &&
  [ ! -e "$_rel/valise/module.d/valise_editor.meta" ] && [ ! -e "$_rel/valise/modules/system/valise_editor.sh" ] &&
  [ ! -e "$_rel/valise/module.d/valise_platform_macos.meta" ]; then
  pass "the release holds the engine modules in the closure and no others"
else
  fail "the release holds the engine modules in the closure and no others"
  (cd "$_rel" && find . -type f | sort) >&2
fi
if VALISE_MODULE_ROOT="$_rel" /bin/sh -c '. "$VALISE_MODULE_ROOT/plans/sh.sh" && command -v valise_path_prepend >/dev/null'; then
  pass "the sh plan defines the engine module's export"
else
  fail "the sh plan defines the engine module's export"
fi
_full_conf=$(cat "$_rel/valise-release.conf")
case "$_full_conf" in
  *"variant=full"*"roots_sh=profile_main@module.d contrib_work_tool@layers/work/module.d"*"modules=contrib_work_tool@layers/work/module.d greet@module.d profile_main@module.d valise_path@valise"*)
    pass "valise-release.conf records the selection, roots, and closure" ;;
  *)
    fail "valise-release.conf records the selection, roots, and closure"
    printf '%s\n' "$_full_conf" >&2 ;;
esac

if _v "$_proj" build --variant=personal "$_tmp/personal" >/dev/null 2>"$_tmp/build-personal.err" &&
  [ ! -e "$_tmp/personal/layers/work" ] &&
  ! grep -F 'contrib_work_tool' "$_tmp/personal/manifest.tsv" >/dev/null &&
  ! grep -F 'contrib_work_tool' "$_tmp/personal/plans/bash.sh" >/dev/null &&
  [ -f "$_tmp/personal/modules/greet.sh" ]; then
  pass "an excluded module ships neither metadata nor body"
else
  fail "an excluded module ships neither metadata nor body"
  cat "$_tmp/build-personal.err" >&2
fi
if grep -qx 'roots_bash=profile_main@module.d' "$_tmp/personal/valise-release.conf"; then
  pass "valise-release.conf records the roots left after the variant's exclusions"
else
  fail "valise-release.conf records the roots left after the variant's exclusions"
  cat "$_tmp/personal/valise-release.conf" >&2
fi

# A failed build leaves the previous default output in place.
cp "$_rel/manifest.tsv" "$_tmp/manifest.before"
_meta "$_proj/module.d/broken.meta" broken '' posix broken_ready modules/broken.sh
printf 'bundle\tshell\troots\ndefault\tbash\tprofile_main broken\n' >"$_tmp/bundles.broken"
cp "$_proj/bundles.tsv" "$_tmp/bundles.good"
cp "$_tmp/bundles.broken" "$_proj/bundles.tsv"
if _v "$_proj" build >/dev/null 2>&1; then
  fail "a failing build keeps the previous release"
elif cmp -s "$_rel/manifest.tsv" "$_tmp/manifest.before" &&
  ! ls -A "$_proj/build" | grep -F '.valise-' >/dev/null; then
  pass "a failing build keeps the previous release and leaves no staging directory"
else
  fail "a failing build keeps the previous release and leaves no staging directory"
fi
rm -f "$_proj/module.d/broken.meta"
cp "$_tmp/bundles.good" "$_proj/bundles.tsv"

# Apply with a variant; status reports what the active release was built with.
if _v "$_proj" apply --variant=personal >/dev/null 2>"$_tmp/apply.err"; then
  pass "apply --variant installs the variant"
else
  fail "apply --variant installs the variant"
  cat "$_tmp/apply.err" >&2
fi
_status=$(_v "$_proj" status 2>&1)
if printf '%s\n' "$_status" | grep -Fx 'project default variant: full' >/dev/null &&
  printf '%s\n' "$_status" | grep -Fx 'active variant: personal' >/dev/null &&
  printf '%s\n' "$_status" | grep -F 'active built by valise: ' >/dev/null; then
  pass "status separates the project default from the active release's variant"
else
  fail "status separates the project default from the active release's variant"
  printf '%s\n' "$_status" >&2
fi

if [ -x /bin/dash ]; then
  if HOME="$_home" /bin/dash -c '. "$HOME/.profile"; greet' 2>/dev/null | grep -Fx 'hello from greet' >/dev/null; then
    pass "a dash login loads the sh plan through the managed block"
  else
    fail "a dash login loads the sh plan through the managed block"
  fi
elif [ "$_require_tooling" -eq 1 ]; then
  fail "a dash login loads the sh plan through the managed block (/bin/dash unavailable)"
else
  skip "a dash login loads the sh plan through the managed block (/bin/dash unavailable)"
fi

# The guard is set only after a plan was sourced: with no active release the
# first startup file loads nothing and a later one, once the release is back,
# loads the profile. The block always comes from valise init.
_block=$(_v "$_proj" init posix)
_active="$_home/.config/valise/active"
_target=$(readlink "$_active")
if HOME="$_home" _BLOCK=$_block _ACTIVE=$_active _TARGET=$_target /bin/sh -c '
  rm -f "$_ACTIVE"
  eval "$_BLOCK"
  [ -z "${_valise_profile_loaded:-}" ] || exit 2
  command -v greet >/dev/null 2>&1 && exit 3
  ln -s "$_TARGET" "$_ACTIVE"
  eval "$_BLOCK"
  [ "${_valise_profile_loaded:-}" = 1 ] || exit 4
  greet
' >"$_tmp/retry.out" 2>"$_tmp/retry.err" && grep -Fx 'hello from greet' "$_tmp/retry.out" >/dev/null; then
  pass "a startup file read while no release is active does not block a later load"
else
  fail "a startup file read while no release is active does not block a later load"
  cat "$_tmp/retry.err" >&2
fi
[ -L "$_active" ] || ln -s "$_target" "$_active"

# A second block in the same shell does not load twice: the module body,
# which counts its own executions, runs once.
if HOME="$_home" _BLOCK=$_block /bin/sh -c '
  eval "$_BLOCK"
  eval "$_BLOCK"
  [ "${_greet_loads:-0}" -eq 1 ]
' 2>"$_tmp/once.err"; then
  pass "a second managed block in the same shell does not reload the profile"
else
  fail "a second managed block in the same shell does not reload the profile"
  cat "$_tmp/once.err" >&2
fi
if HOME="$_home" VALISE_RELOAD=1 _BLOCK=$_block /bin/sh -c '
  eval "$_BLOCK"
  eval "$_BLOCK"
  [ "${_greet_loads:-0}" -eq 2 ]
' 2>"$_tmp/reload.err"; then
  pass "VALISE_RELOAD=1 makes a later block load the profile again"
else
  fail "VALISE_RELOAD=1 makes a later block load the profile again"
  cat "$_tmp/reload.err" >&2
fi

printf '\n=== project layout summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
