# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise_path: idempotent PATH augmentation.
#
# Each listed directory ends up in PATH exactly once. With no arguments the
# functions normalize PATH in place (duplicates and empty components are
# removed). Empty arguments are skipped; empty PATH components are dropped
# rather than preserved (an empty component means the current directory).
# Directories are added whether or not they already exist, so entries can be
# declared before first install. Only the requested entries move; every other
# component keeps its relative order. Arguments must not contain colons:
# a colon is the PATH separator and cannot appear inside one entry.

_contrib_path_rebuild() {
  # _contrib_path_rebuild <prepend|append> <dir>... — private helper.
  _contrib_path_mode=$1
  shift
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  _contrib_path_wanted=
  for _contrib_path_item in "$@"; do
    [ -n "$_contrib_path_item" ] || continue
    case ":${_contrib_path_wanted}:" in
      *":${_contrib_path_item}:"*) ;;
      *) _contrib_path_wanted="${_contrib_path_wanted}:${_contrib_path_item}" ;;
    esac
  done
  if [ "${IFS+x}" = x ]; then
    _contrib_path_old_ifs=${IFS-}
    _contrib_path_ifs_was_set=1
  else
    _contrib_path_old_ifs=
    _contrib_path_ifs_was_set=0
  fi
  _contrib_path_glob_off=0
  case $- in
    *f*) ;;
    *) set -f; _contrib_path_glob_off=1 ;;
  esac
  _contrib_path_kept=
  IFS=':'
  # shellcheck disable=SC2086
  for _contrib_path_field in ${PATH-}; do
    [ -n "$_contrib_path_field" ] || continue
    case ":${_contrib_path_wanted}:" in
      *":${_contrib_path_field}:"*) continue ;;
    esac
    case ":${_contrib_path_kept}:" in
      *":${_contrib_path_field}:"*) continue ;;
    esac
    _contrib_path_kept="${_contrib_path_kept}:${_contrib_path_field}"
  done
  if [ "$_contrib_path_ifs_was_set" -eq 1 ]; then
    IFS=$_contrib_path_old_ifs
  else
    unset IFS
  fi
  if [ "$_contrib_path_glob_off" -eq 1 ]; then
    set +f
  fi
  if [ "$_contrib_path_mode" = prepend ]; then
    _contrib_path_new="${_contrib_path_wanted}${_contrib_path_kept}"
  else
    _contrib_path_new="${_contrib_path_kept}${_contrib_path_wanted}"
  fi
  _contrib_path_new=${_contrib_path_new#:}
  if [ -n "$_contrib_path_new" ]; then
    PATH=$_contrib_path_new
    export PATH
  fi
  unset _contrib_path_mode _contrib_path_wanted _contrib_path_item _contrib_path_kept _contrib_path_field _contrib_path_new _contrib_path_old_ifs _contrib_path_ifs_was_set _contrib_path_glob_off
}

valise_path_prepend() {
  # Move each argument to the front of PATH, preserving argument order, so
  # the first argument ends up first.
  _contrib_path_rebuild prepend "$@"
}

valise_path_append() {
  _contrib_path_rebuild append "$@"
}
