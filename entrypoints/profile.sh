#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Portable shell-profile entrypoint.

# Executing this file (`sh entrypoints/profile.sh`) instead of sourcing it
# fails late and cryptically ("return: can only 'return' from a function or
# sourced script"). When executed under POSIX shells or bash, $0 is this
# file's path; when sourced it belongs to the caller. zsh is the exception:
# it sets $0 to the sourced path too, so $0 alone cannot decide there —
# but zsh sets ZSH_SCRIPT only when this file is executed as a script.
# grep then confirms the $0 candidate actually is this entrypoint, so a
# caller script that merely shares the name can still source us. Residual
# case: a caller whose own path ends in entrypoints/profile.sh and whose
# text carries this header comment trips the guard with the guidance
# message — loud misidentification, never a silent wrong behavior.
case "$0" in
*entrypoints/profile.sh)
  if { [ -z "${ZSH_VERSION:-}" ] || [ -n "${ZSH_SCRIPT:-}" ]; } &&
    command grep -q 'Portable shell-profile entrypoint' "$0" 2>/dev/null; then
    printf '%s\n' "shell-profile: entrypoints/profile.sh must be sourced, not executed (try: . $0)" >&2
    exit 1
  fi
  ;;
esac

if [ -n "${VALISE_ROOT:-}" ]; then
  _sp_root=$VALISE_ROOT
else
  _sp_root=
  _sp_search_dir=$(pwd -P 2>/dev/null)
  _sp_status=$?
  if [ "$_sp_status" -ne 0 ]; then
    printf '%s\n' 'shell-profile: unable to locate shell-profile root; set VALISE_ROOT' >&2
    unset _sp_search_dir _sp_root _sp_module_root _sp_status
    return 1
  fi
  while :; do
    if [ -f "$_sp_search_dir/lib/metadata.sh" ] && [ -f "$_sp_search_dir/lib/loader.sh" ]; then
      _sp_root=$_sp_search_dir
      break
    fi
    if [ -f "$_sp_search_dir/submodule/valise-sh/lib/metadata.sh" ] && [ -f "$_sp_search_dir/submodule/valise-sh/lib/loader.sh" ]; then
      _sp_root=$_sp_search_dir/submodule/valise-sh
      break
    fi
    [ "$_sp_search_dir" = / ] && break
    _sp_search_dir=$(CDPATH= cd "$_sp_search_dir/.." 2>/dev/null && pwd -P) || break
  done
  if [ -z "$_sp_root" ]; then
    printf '%s\n' 'shell-profile: unable to locate shell-profile root; set VALISE_ROOT' >&2
    unset _sp_search_dir _sp_root _sp_module_root _sp_status
    return 1
  fi
fi

# shellcheck disable=SC1091
if [ ! -r "$_sp_root/lib/metadata.sh" ]; then
  printf 'shell-profile: %s\n' "metadata library is not readable: $_sp_root/lib/metadata.sh" >&2
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi
. "$_sp_root/lib/metadata.sh"
_sp_status=$?
if [ "$_sp_status" -ne 0 ]; then
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi
# shellcheck disable=SC1091
if [ ! -r "$_sp_root/lib/capabilities.sh" ]; then
  printf 'shell-profile: %s\n' "capability library is not readable: $_sp_root/lib/capabilities.sh" >&2
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi
. "$_sp_root/lib/capabilities.sh"
_sp_status=$?
if [ "$_sp_status" -ne 0 ]; then
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi
# shellcheck disable=SC1091
if [ ! -r "$_sp_root/lib/loader.sh" ]; then
  printf 'shell-profile: %s\n' "loader library is not readable: $_sp_root/lib/loader.sh" >&2
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi
. "$_sp_root/lib/loader.sh"
_sp_status=$?
if [ "$_sp_status" -ne 0 ]; then
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 1
fi

_sp_module_root=${VALISE_MODULE_ROOT:-$_sp_root}

# Zsh's default is noshwordsplit, which makes an unquoted variable expansion
# produce a single word rather than splitting on IFS. The loader's
# `for _spl_word in $_spl_wanted` depends on POSIX splitting, so invoke it
# through a wrapper that enables shwordsplit locally when running under zsh.
# `emulate -L sh` scopes the option change to the function and does not
# leak into the caller's interactive shell.
_sp_invoke_loader() {
  case "${ZSH_VERSION:-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  sp_loader_load_modules "$1" "$2" "$3" "$4"
}

if [ -n "${VALISE_MODULES:-}" ]; then
  _sp_invoke_loader "$_sp_module_root" "$VALISE_MODULES" "${VALISE_MODE:-permissive}" ordinary
  _sp_status=$?
else
  _sp_status=0
fi
unset -f _sp_invoke_loader 2>/dev/null || :

if [ "$_sp_status" -eq 0 ]; then
  unset _sp_search_dir _sp_root _sp_module_root _sp_status
  return 0
fi
unset _sp_search_dir _sp_root _sp_module_root _sp_status
return 1
