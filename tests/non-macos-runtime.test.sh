#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Real non-macOS runtime probes for the reusable shell-profile engine.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

_pass=0
_fail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); }

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

assert_positive_integer() {
  _total=$((_total + 1))
  _label=$1
  _value=$2
  case "$_value" in
  '' | *[!0123456789]*) fail "$_label" "not a positive integer: $_value" ;;
  *)
    if [ "$_value" -gt 0 ] 2>/dev/null; then pass "$_label"; else fail "$_label" "not positive: $_value"; fi
    ;;
  esac
}

assert_empty() {
  _total=$((_total + 1))
  _label=$1
  _value=$2
  if [ -z "$_value" ]; then
    pass "$_label"
  else
    fail "$_label" "expected empty output; actual: $_value"
  fi
}

runtime_tmp_parent() {
  _parent=${MACOS_PROFILE_TEST_TMPROOT:-${TMPDIR:-/tmp}}
  [ -d "$_parent" ] || { printf 'FATAL: temp parent does not exist: %s\n' "$_parent" >&2; exit 1; }
  _parent_real=$(cd "$_parent" && pwd -P) || exit 1
  case "$_parent_real/" in
  "$HOME"/*)
    printf 'FATAL: refusing non-macOS runtime tests under live user home: %s\n' "$_parent_real" >&2
    exit 1
    ;;
  esac
  printf '%s\n' "$_parent_real"
  unset _parent _parent_real
}

runtime_command() {
  _command_name=$1
  _search_path=${VALISE_RUNTIME_SEARCH_PATH:-/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
  _had_ifs=0
  _old_ifs=
  if [ "${IFS+x}" = x ]; then
    _had_ifs=1
    _old_ifs=$IFS
  fi
  IFS=:
  for _dir in $_search_path; do
    [ -n "$_dir" ] || continue
    case "$_dir/" in
    "$HOME"/*) continue ;;
    esac
    if [ -x "$_dir/$_command_name" ]; then
      if [ "$_had_ifs" -eq 1 ]; then IFS=$_old_ifs; else unset IFS; fi
      printf '%s\n' "$_dir/$_command_name"
      unset _command_name _search_path _had_ifs _old_ifs _dir
      return 0
    fi
  done
  if [ "$_had_ifs" -eq 1 ]; then IFS=$_old_ifs; else unset IFS; fi
  unset _command_name _search_path _had_ifs _old_ifs _dir
  return 1
}

find_container_image() {
  _kind=$1
  _env_var=$2
  _default_images=$3
  _images=${!_env_var:-$_default_images}
  _checked=
  for _image in $_images; do
    [ -n "$_image" ] || continue
    for _runtime in docker podman; do
      if _runtime_path=$(runtime_command "$_runtime"); then
        _checked="$_checked $_runtime:$_runtime_path:$_image"
        if "$_runtime_path" image inspect "$_image" >/dev/null 2>&1; then
          RUNTIME_CONTAINER=$_runtime
          RUNTIME_CONTAINER_BIN=$_runtime_path
          RUNTIME_IMAGE=$_image
          RUNTIME_CHECKED=$_checked
          unset _kind _env_var _default_images _images _image _runtime _runtime_path _checked
          return 0
        fi
      else
        _checked="$_checked $_runtime:missing-executable"
      fi
    done
  done
  RUNTIME_CONTAINER=
  RUNTIME_CONTAINER_BIN=
  RUNTIME_IMAGE=
  RUNTIME_CHECKED=$_checked
  unset _kind _env_var _default_images _images _image _runtime _runtime_path _checked
  return 1
}

run_engine_direct() {
  _platform=$1
  _module=$2
  _label=$3
  _sandbox=$_tmp_root/direct-$_platform
  _home=$_sandbox/home
  _tmp=$_sandbox/tmp
  mkdir -p "$_home" "$_tmp"
  chmod 700 "$_home" "$_tmp"
  _out=$(/usr/bin/env -i \
    HOME="$_home" TMPDIR="$_tmp" PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    VALISE_ROOT="$ROOT_DIR" VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES="$_module" VALISE_MODE=strict \
    /bin/sh -s <<'PROBE'
set -u
: >"$TMPDIR/mtime-target"
. "$VALISE_ROOT/entrypoints/profile.sh" >"$TMPDIR/source.out" 2>"$TMPDIR/source.err"
_status=$?
_os=$(sp_platform_os 2>/dev/null || printf fail)
_available=no
if [ "$VALISE_MODULES" = valise_platform_linux ]; then
  sp_platform_linux_available >/dev/null 2>&1 && _available=yes
elif [ "$VALISE_MODULES" = valise_platform_bsd ]; then
  sp_platform_bsd_available >/dev/null 2>&1 && _available=yes
fi
_cpu=$(sp_platform_cpu_count 2>/dev/null || printf fail)
_mtime=$(sp_platform_file_mtime "$TMPDIR/mtime-target" 2>/dev/null || printf fail)
_home_entries=$(find "$HOME" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
printf 'status=%s os=%s available=%s cpu=%s mtime=%s home_entries=%s stderr=%s\n' \
  "$_status" "$_os" "$_available" "$_cpu" "$_mtime" "$_home_entries" "$(cat "$TMPDIR/source.err")"
PROBE
  )
  assert_contains "$_label source succeeds" "$_out" 'status=0'
  assert_contains "$_label platform availability" "$_out" 'available=yes'
  _cpu=$(printf '%s\n' "$_out" | sed -n 's/.*cpu=\([^ ]*\).*/\1/p')
  assert_positive_integer "$_label cpu count is positive" "$_cpu"
  _mtime=$(printf '%s\n' "$_out" | sed -n 's/.*mtime=\([^ ]*\).*/\1/p')
  assert_positive_integer "$_label mtime helper returns a numeric value" "$_mtime"
  assert_contains "$_label leaves runtime HOME untouched" "$_out" 'home_entries=0'
  _stderr=${_out#* stderr=}
  assert_empty "$_label source stays quiet" "$_stderr"
  unset _platform _module _label _sandbox _home _tmp _out _cpu _mtime _stderr
}

run_engine_container() {
  _platform=$1
  _module=$2
  _label=$3
  _out=$("$RUNTIME_CONTAINER_BIN" run --rm -i --pull=never --network none \
    -v "$ROOT_DIR:/work/shell-profile:ro" \
    -e VALISE_ROOT=/work/shell-profile \
    -e VALISE_MODULE_ROOT=/work/shell-profile \
    -e VALISE_MODULES="$_module" \
    -e VALISE_MODE=strict \
    "$RUNTIME_IMAGE" /bin/sh -s 2>&1 <<'PROBE'
set -u
HOME=/tmp/shell-profile-runtime-home
TMPDIR=/tmp/shell-profile-runtime-tmp
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME TMPDIR PATH VALISE_ROOT VALISE_MODULE_ROOT VALISE_MODULES VALISE_MODE
rm -rf "$HOME" "$TMPDIR"
mkdir -p "$HOME" "$TMPDIR"
chmod 700 "$HOME" "$TMPDIR"
: >"$TMPDIR/mtime-target"
. "$VALISE_ROOT/entrypoints/profile.sh" >"$TMPDIR/source.out" 2>"$TMPDIR/source.err"
_status=$?
_os=$(sp_platform_os 2>/dev/null || printf fail)
_available=no
if [ "$VALISE_MODULES" = valise_platform_linux ]; then
  sp_platform_linux_available >/dev/null 2>&1 && _available=yes
elif [ "$VALISE_MODULES" = valise_platform_bsd ]; then
  sp_platform_bsd_available >/dev/null 2>&1 && _available=yes
fi
_cpu=$(sp_platform_cpu_count 2>/dev/null || printf fail)
_mtime=$(sp_platform_file_mtime "$TMPDIR/mtime-target" 2>/dev/null || printf fail)
_home_entries=$(find "$HOME" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
printf 'status=%s os=%s available=%s cpu=%s mtime=%s home_entries=%s stderr=%s\n' \
  "$_status" "$_os" "$_available" "$_cpu" "$_mtime" "$_home_entries" "$(cat "$TMPDIR/source.err")"
PROBE
  )
  assert_contains "$_label source succeeds via $RUNTIME_CONTAINER:$RUNTIME_IMAGE" "$_out" 'status=0'
  assert_contains "$_label platform availability via $RUNTIME_CONTAINER:$RUNTIME_IMAGE" "$_out" 'available=yes'
  _cpu=$(printf '%s\n' "$_out" | sed -n 's/.*cpu=\([^ ]*\).*/\1/p')
  assert_positive_integer "$_label cpu count is positive via $RUNTIME_CONTAINER:$RUNTIME_IMAGE" "$_cpu"
  _mtime=$(printf '%s\n' "$_out" | sed -n 's/.*mtime=\([^ ]*\).*/\1/p')
  assert_positive_integer "$_label mtime helper returns a numeric value via $RUNTIME_CONTAINER:$RUNTIME_IMAGE" "$_mtime"
  assert_contains "$_label leaves container HOME untouched" "$_out" 'home_entries=0'
  _stderr=${_out#* stderr=}
  assert_empty "$_label source stays quiet via $RUNTIME_CONTAINER:$RUNTIME_IMAGE" "$_stderr"
  unset _platform _module _label _out _cpu _mtime _stderr
}

printf '\n=== shell-profile non-macOS runtime verification ===\n'

_tmp_parent=$(runtime_tmp_parent)
_tmp_root=$(mktemp -d "$_tmp_parent/shell-profile-non-macos.XXXXXX") || exit 1
trap 'rm -rf -- "$_tmp_root"' EXIT INT TERM

_host_uname=$(uname -s 2>/dev/null || printf unknown)

case "$_host_uname" in
Linux)
  run_engine_direct linux valise_platform_linux 'Linux host shell-profile engine runtime'
  ;;
*)
  if find_container_image linux VALISE_LINUX_IMAGE 'alpine:latest debian:stable-slim debian:latest ubuntu:latest busybox:latest'; then
    run_engine_container linux valise_platform_linux 'Linux container shell-profile engine runtime'
  else
    _total=$((_total + 1))
    skip "Linux runtime unavailable (host uname=$_host_uname; missing local Docker/Podman image or executable; checked:${RUNTIME_CHECKED:- none}; set VALISE_LINUX_IMAGE to a pre-pulled local Linux image)"
  fi
  ;;
esac

case "$_host_uname" in
FreeBSD | OpenBSD | NetBSD | *BSD)
  run_engine_direct bsd valise_platform_bsd 'BSD host shell-profile engine runtime'
  ;;
*)
  if [ -n "${VALISE_BSD_IMAGE:-}" ]; then
    if find_container_image bsd VALISE_BSD_IMAGE "$VALISE_BSD_IMAGE"; then
      run_engine_container bsd valise_platform_bsd 'BSD configured shell-profile engine runtime'
    else
      _total=$((_total + 1))
      skip "BSD runtime unavailable (host uname=$_host_uname; configured VALISE_BSD_IMAGE=$VALISE_BSD_IMAGE; missing local Docker/Podman image or executable; checked:${RUNTIME_CHECKED:- none}; Docker/Podman Linux images are not treated as BSD evidence)"
    fi
  else
    _total=$((_total + 1))
    skip "BSD runtime unavailable (host uname=$_host_uname; VALISE_BSD_IMAGE is not configured; Docker/Podman Linux images are not treated as BSD evidence)"
  fi
  ;;
esac

printf '\n=== shell-profile non-macOS runtime summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"

[ "$_fail" -eq 0 ]
