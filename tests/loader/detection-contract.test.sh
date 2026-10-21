#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Loader detection-contract tests: shell/platform detection frozen semantics.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"
LOADER_SH="$ROOT_DIR/lib/loader.sh"

_pass=0
_fail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _skip=$((_skip + 1)); }

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

find_exec() {
  _find_exec_name=$1
  _find_exec_old_ifs=$IFS
  IFS=:
  for _find_exec_dir in ${MACOS_PROFILE_PARSER_SEARCH_PATH:-${PATH:-}}; do
    [ -n "$_find_exec_dir" ] || _find_exec_dir=.
    if [ -x "$_find_exec_dir/$_find_exec_name" ] && [ ! -d "$_find_exec_dir/$_find_exec_name" ]; then
      printf '%s\n' "$_find_exec_dir/$_find_exec_name"
      IFS="$_find_exec_old_ifs"
      unset _find_exec_name _find_exec_old_ifs _find_exec_dir
      return 0
    fi
  done
  IFS="$_find_exec_old_ifs"
  unset _find_exec_name _find_exec_old_ifs _find_exec_dir
  return 0
}

DASH_BIN=$(find_exec dash)
BUSYBOX_BIN=$(find_exec busybox)

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-detection.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Fixture tree: one sh-clean module per detection dimension.
_fixture_root=$_tmp/fixture
mkdir -p "$_fixture_root/module.d" "$_fixture_root/modules" || exit 1

write_module() {
  _wm_name=$1
  _wm_shells=$2
  _wm_platforms=$3
  cat >"$_fixture_root/module.d/$_wm_name.meta" <<META
name=$_wm_name
requires=
optional=
shells=$_wm_shells
platforms=$_wm_platforms
side_effect=read-only
exports=${_wm_name}_loaded
updates=
load=modules/$_wm_name.sh
META
  cat >"$_fixture_root/modules/$_wm_name.sh" <<MODULE
printf '%s\n' $_wm_name >>"\${SP_LOADER_TEST_TRACE:?}"
${_wm_name}_loaded() { :; }
MODULE
  unset _wm_name _wm_shells _wm_platforms
}

write_module sh_module sh any
write_module bash_module bash any
write_module zsh_module zsh any
write_module ksh_module ksh any
write_module darwin_module sh darwin
write_module any_platform_module sh any

# Runs the loader in a child shell and prints the module trace (body executions).
DETECTION_STATUS=
DETECTION_OUTPUT=
DETECTION_TRACE_VALUE=
DETECTION_SEQ=0

run_detection() {
  _rd_shell=$1
  _rd_wanted=$2
  _rd_trace=$_tmp/trace.$DETECTION_SEQ
  DETECTION_SEQ=$((DETECTION_SEQ + 1))
  : >"$_rd_trace"
  _rd_out=$(
    SP_LOADER_TEST_TRACE="$_rd_trace" \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
    "$_rd_shell" -c '
      . "$METADATA_SH"
      . "$LOADER_SH"
      sp_loader_load_modules "$FIXTURE_ROOT" "$1" strict ordinary
    ' detection "$_rd_wanted" 2>&1
  )
  DETECTION_STATUS=$?
  DETECTION_OUTPUT=$_rd_out
  DETECTION_TRACE_VALUE=$(cat "$_rd_trace")
  unset _rd_shell _rd_wanted _rd_trace _rd_out
}

printf '\n=== Loader detection contract ===\n'

if [ -n "$DASH_BIN" ]; then
  run_detection "$DASH_BIN" sh_module
  assert_eq 'sh-detected shell (dash) loads shells=sh module' 0 "$DETECTION_STATUS"
  assert_eq 'sh-detected shell (dash) executed sh module body' 'sh_module' "$DETECTION_TRACE_VALUE"
  run_detection "$DASH_BIN" bash_module
  assert_eq 'sh-detected shell (dash) rejects shells=bash module' 1 "$DETECTION_STATUS"
  assert_contains 'sh-detected shell (dash) rejection names unsupported shell' "$DETECTION_OUTPUT" 'unsupported shell'

  run_detection "$DASH_BIN" 'sh_module any_platform_module'
  assert_eq 'dash loads sh-clean any-platform closure' 0 "$DETECTION_STATUS"
  assert_eq 'dash executed both module bodies in loader order' $'any_platform_module\nsh_module' "$DETECTION_TRACE_VALUE"
else
  skip 'dash detection clauses (dash unavailable on this host)' \
    'the check release gate fails closed without a dash executor through the multi-root child-shell lanes, so this contract is still only claimed green where a POSIX-sh-classified interpreter actually ran.'
fi

# Contract: BASH_VERSION alone (without builtin shopt) does not classify as bash
# in non-bash shells; a real bash classifies as bash.
run_detection /bin/bash bash_module
assert_eq 'bash classifies itself as bash and loads shells=bash module' 0 "$DETECTION_STATUS"
run_detection /bin/bash sh_module
assert_eq 'bash still loads shells=sh module (sh means any POSIX)' 0 "$DETECTION_STATUS"
run_detection /bin/bash zsh_module
assert_eq 'bash rejects shells=zsh module' 1 "$DETECTION_STATUS"

# Contract: last-write-wins — when multiple version variables are present the
# latest detection (ksh > zsh > bash) wins.
_zsh_ksh_probe=$_tmp/zsh-ksh-probe.sh
_ksh_wins_trace=$_tmp/ksh-wins-trace
: >"$_ksh_wins_trace"
cat >"$_zsh_ksh_probe" <<PROBE
export ZSH_VERSION=5.9
export KSH_VERSION="93u+ 2025.1"
. "$METADATA_SH"
. "$LOADER_SH"
sp_loader_load_modules "$_fixture_root" ksh_module strict ordinary
PROBE
_ksh_wins_out=$(SP_LOADER_TEST_TRACE="$_ksh_wins_trace" /bin/bash "$_zsh_ksh_probe" 2>&1)
_ksh_wins_status=$?
_ksh_wins_trace_value=$(cat "$_ksh_wins_trace")
assert_eq 'ksh detection wins when KSH_VERSION and ZSH_VERSION are both set' 0 "$_ksh_wins_status"
assert_eq 'last-write-wins detected ksh and executed ksh module body' 'ksh_module' "$_ksh_wins_trace_value"
unset _zsh_ksh_probe _ksh_wins_trace _ksh_wins_out _ksh_wins_status _ksh_wins_trace_value

# Contract (continued): zsh > bash — a real bash whose environment carries
# ZSH_VERSION is classified zsh, so the zsh module loads (the bash rejection
# under zsh classification is implied by shells=zsh matching alone).
_zsh_probe=$_tmp/zsh-probe.sh
_zsh_wins_trace=$_tmp/zsh-wins-trace
: >"$_zsh_wins_trace"
cat >"$_zsh_probe" <<PROBE
export ZSH_VERSION=5.9
. "$METADATA_SH"
. "$LOADER_SH"
sp_loader_load_modules "$_fixture_root" zsh_module strict ordinary
PROBE
_zsh_wins_out=$(SP_LOADER_TEST_TRACE="$_zsh_wins_trace" /bin/bash "$_zsh_probe" 2>&1)
_zsh_wins_status=$?
_zsh_wins_trace_value=$(cat "$_zsh_wins_trace")
assert_eq 'zsh detection wins when ZSH_VERSION is set inside bash' 0 "$_zsh_wins_status"
assert_eq 'last-write-wins detected zsh over bash and executed zsh module body' 'zsh_module' "$_zsh_wins_trace_value"
unset _zsh_probe _zsh_wins_trace _zsh_wins_out _zsh_wins_status _zsh_wins_trace_value

# Contract: platform detection maps uname -s to the family set and an unknown
# uname blocks every module that is not platforms=any.
_spoof_bin=$_tmp/spoof-bin
mkdir -p "$_spoof_bin" || exit 1
printf '#!/bin/sh\nprintf "%%s\\n" HaikuOS\n' >"$_spoof_bin/uname"
chmod 0755 "$_spoof_bin/uname" || exit 1
_unknown_out=$(SP_LOADER_TEST_TRACE=$_tmp/unknown-trace \
  METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
  PATH="$_spoof_bin:/usr/bin:/bin" \
  /bin/bash -c '
    . "$METADATA_SH"
    . "$LOADER_SH"
    sp_loader_load_modules "$FIXTURE_ROOT" darwin_module strict ordinary
  ' 2>&1)
_unknown_status=$?
assert_eq 'spoofed unknown uname rejects non-any platform module' 1 "$_unknown_status"
assert_contains 'unknown platform rejection names unsupported platform' "$_unknown_out" 'unsupported platform'
assert_eq 'unknown platform rejection prevents module body execution' '' "$(cat "$_tmp/unknown-trace" 2>/dev/null)"

_unknown_any_out=$(SP_LOADER_TEST_TRACE=$_tmp/unknown-any-trace \
  METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
  PATH="$_spoof_bin:/usr/bin:/bin" \
  /bin/bash -c '
    . "$METADATA_SH"
    . "$LOADER_SH"
    sp_loader_load_modules "$FIXTURE_ROOT" any_platform_module strict ordinary
  ' 2>&1)
_unknown_any_status=$?
assert_eq 'spoofed unknown uname still loads platforms=any module' 0 "$_unknown_any_status"
assert_eq 'unknown-platform any-module body executed' 'any_platform_module' "$(cat "$_tmp/unknown-any-trace" 2>/dev/null)"
unset _spoof_bin _unknown_out _unknown_status _unknown_any_out _unknown_any_status

# Contract: BusyBox ash is a POSIX-sh-classified interpreter. It must load
# shells=sh modules and reject shell-specific modules such as shells=bash.
# This is deliberately a negative detection case, not only a coreutils smoke
# test: the loader must not mistake BusyBox ash for Bash.
if [ -n "$BUSYBOX_BIN" ]; then
  _busybox_bin=$_tmp/busybox-bin
  _busybox_layer_root=$_tmp/busybox-layer
  mkdir -p "$_busybox_bin" "$_busybox_layer_root/module.d" "$_busybox_layer_root/modules" || exit 1
  cp "$_fixture_root/module.d/sh_module.meta" "$_busybox_layer_root/module.d/sh_module.meta" || exit 1
  cp "$_fixture_root/modules/sh_module.sh" "$_busybox_layer_root/modules/sh_module.sh" || exit 1
  _busybox_applet_setup_failed=0
  for _busybox_applet in ash mktemp grep sort uname printf rm chmod mkdir cat sed mv cmp; do
    if ! ln -sf "$BUSYBOX_BIN" "$_busybox_bin/$_busybox_applet" 2>/dev/null ||
      [ ! -x "$_busybox_bin/$_busybox_applet" ]; then
      fail "busybox applet available: $_busybox_applet" \
        "could not provision $_busybox_applet from $BUSYBOX_BIN"
      _busybox_applet_setup_failed=1
    fi
  done
  unset _busybox_applet

  if [ "$_busybox_applet_setup_failed" -ne 0 ]; then
    unset _busybox_bin _busybox_applet_setup_failed
  else

  _busybox_sh_trace=$_tmp/busybox-sh-trace
  : >"$_busybox_sh_trace"
  _busybox_sh_out=$(SP_LOADER_TEST_TRACE="$_busybox_sh_trace" \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
    VALISE_MODULE_PATH="$_busybox_layer_root" \
    PATH="$_busybox_bin" \
    "$BUSYBOX_BIN" ash -c '
      . "$METADATA_SH"
      . "$LOADER_SH"
      sp_loader_load_modules "$FIXTURE_ROOT" sh_module strict ordinary
    ' 2>&1)
  _busybox_sh_status=$?
  assert_eq 'busybox ash classifies as sh and loads shells=sh module' 0 "$_busybox_sh_status"
  assert_eq 'busybox ash executed sh module body' sh_module "$(cat "$_busybox_sh_trace" 2>/dev/null)"

  _busybox_bash_trace=$_tmp/busybox-bash-trace
  : >"$_busybox_bash_trace"
  _busybox_bash_out=$(SP_LOADER_TEST_TRACE="$_busybox_bash_trace" \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
    PATH="$_busybox_bin" \
    "$BUSYBOX_BIN" ash -c '
      . "$METADATA_SH"
      . "$LOADER_SH"
      sp_loader_load_modules "$FIXTURE_ROOT" bash_module strict ordinary
    ' 2>&1)
  _busybox_bash_status=$?
  assert_eq 'busybox ash rejects shells=bash module' 1 "$_busybox_bash_status"
  assert_contains 'busybox ash rejection names unsupported shell' "$_busybox_bash_out" 'unsupported shell'
  unset _busybox_sh_trace _busybox_sh_out _busybox_sh_status _busybox_bash_trace _busybox_bash_out _busybox_bash_status

  # BusyBox coreutils (mktemp, grep, sort) also satisfy the loader's private
  # allocation and reserved-utility scanning on the same real applet lane.
  _busybox_out=$(SP_LOADER_TEST_TRACE=$_tmp/busybox-trace \
    METADATA_SH="$METADATA_SH" LOADER_SH="$LOADER_SH" FIXTURE_ROOT="$_fixture_root" \
    VALISE_MODULE_PATH="$_busybox_layer_root" \
    PATH="$_busybox_bin" \
    /bin/bash -c '
      . "$METADATA_SH"
      . "$LOADER_SH"
      sp_loader_load_modules "$FIXTURE_ROOT" sh_module strict ordinary
    ' 2>&1)
  _busybox_status=$?
  assert_eq 'busybox coreutils satisfy strict loader load' 0 "$_busybox_status"
  assert_eq 'busybox lane executed module body' 'sh_module' "$(cat "$_tmp/busybox-trace" 2>/dev/null)"
  unset _busybox_bin _busybox_layer_root _busybox_out _busybox_status _busybox_applet_setup_failed
  fi
else
  skip 'busybox coreutils lane exercised loader allocation' \
    'busybox unavailable on this host. The host-only lane records a documented skip; the enforced test-detection-contract-busybox check supplies the pinned runtime evidence and fails closed when no BusyBox executor is available.'
fi

printf '\n=== loader detection-contract summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"

[ "$_fail" -eq 0 ]
