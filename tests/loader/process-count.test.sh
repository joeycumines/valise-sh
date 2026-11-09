#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Loader hot-path process-count contract.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"
LOADER_SH="$ROOT_DIR/lib/loader.sh"

if [ ! -f "$METADATA_SH" ] || [ ! -f "$LOADER_SH" ]; then
  printf 'FAIL: loader libraries are missing\n' >&2
  exit 1
fi

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/loader-process-count.XXXXXX") || exit 1
cleanup() {
  rm -rf "$_tmp" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

_root="$_tmp/root"
_bin="$_tmp/bin"
_runtime_tmp="$_tmp/runtime"
mkdir -p "$_root/module.d" "$_root/modules" "$_bin" "$_runtime_tmp" || exit 1

_real_sed=$(command -v sed)
_real_grep=$(command -v grep)
_real_cat=$(command -v cat)
_real_cmp=$(command -v cmp)

for _tool in sed grep cat cmp; do
  case "$_tool" in
  sed) _real=$_real_sed ;;
  grep) _real=$_real_grep ;;
  cat) _real=$_real_cat ;;
  cmp) _real=$_real_cmp ;;
  esac
  _counter_var="VALISE_LOADER_$(printf '%s' "$_tool" | tr '[:lower:]' '[:upper:]')_COUNT"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' "printf '%s\\n' '$_tool' >>\"\${${_counter_var}:?}\""
    printf '%s\n' "exec '$_real' \"\$@\""
  } >"$_bin/$_tool"
  chmod +x "$_bin/$_tool"
done
unset _tool _real _counter_var

i=1
while [ "$i" -le 40 ]; do
  _name=$(printf 'm%02d' "$i")
  if [ "$i" -eq 1 ]; then
    _requires=
  else
    _requires=$(printf 'm%02d' "$((i - 1))")
  fi
  {
    printf 'name=%s\n' "$_name"
    printf 'requires=%s\n' "$_requires"
    printf 'optional=\n'
    printf 'shells=posix\n'
    printf 'platforms=any\n'
    printf 'side_effect=read-only\n'
    printf 'exports=%s_loaded\n' "$_name"
    printf ''
    printf 'load=modules/%s.sh\n' "$_name"
  } >"$_root/module.d/$_name.meta"
  printf '%s_loaded() { :; }\n' "$_name" >"$_root/modules/$_name.sh"
  i=$((i + 1))
done
unset i _name _requires

_wanted_4='m01 m02 m03 m04'
_wanted_40='m01 m02 m03 m04'
i=5
while [ "$i" -le 40 ]; do
  _wanted_40="$_wanted_40 $(printf 'm%02d' "$i")"
  i=$((i + 1))
done
unset i

_count_file_value() {
  wc -l <"$1" | tr -d ' '
}

run_loader_case() {
  _case_wanted=$1
  _case_tmp="$2"
  mkdir -p "$_case_tmp" || return 1
  : >"$_case_tmp/sed.count"
  : >"$_case_tmp/grep.count"
  : >"$_case_tmp/cat.count"
  : >"$_case_tmp/cmp.count"
  (
    export TMPDIR="$_runtime_tmp"
    export VALISE_LOADER_SED_COUNT="$_case_tmp/sed.count"
    export VALISE_LOADER_GREP_COUNT="$_case_tmp/grep.count"
    export VALISE_LOADER_CAT_COUNT="$_case_tmp/cat.count"
    export VALISE_LOADER_CMP_COUNT="$_case_tmp/cmp.count"
    export PATH="$_bin:$PATH"
    # shellcheck disable=SC1090
    . "$METADATA_SH"
    # shellcheck disable=SC1090
    . "$LOADER_SH"
    sp_loader_load_modules "$_root" "$_case_wanted" strict ordinary
  )
}

if ! run_loader_case "$_wanted_4" "$_tmp/case4"; then
  printf 'FAIL: 4-module load failed\n' >&2
  exit 1
fi
if ! run_loader_case "$_wanted_40" "$_tmp/case40"; then
  printf 'FAIL: 40-module load failed\n' >&2
  exit 1
fi

_status=0
for _tool in sed grep cat cmp; do
  _count4=$(_count_file_value "$_tmp/case4/${_tool}.count")
  _count40=$(_count_file_value "$_tmp/case40/${_tool}.count")
  if [ "$_count4" -ne "$_count40" ]; then
    printf 'FAIL: %s call count grew with module count: 4=%s 40=%s\n' \
      "$_tool" "$_count4" "$_count40" >&2
    _status=1
  else
    printf 'PASS: %s calls are constant across module counts (%s)\n' \
      "$_tool" "$_count40"
  fi
done
unset _tool _count4 _count40

if [ "$_status" -ne 0 ]; then
  exit 1
fi
printf 'OK: loader per-module external calls are constant\n'
