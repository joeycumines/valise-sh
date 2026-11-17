# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise_path: idempotent PATH augmentation.
#
# prepend/append are the core: they move each listed directory to the front or
# back of PATH exactly once, and that is all most use cases need. contains,
# remove, and normalize are the supporting helpers for inspection and cleanup.
#
# Each listed directory ends up in PATH exactly once. With no arguments the
# prepend/append functions normalize PATH in place (duplicates and empty
# components are removed). Empty arguments are skipped; empty PATH components
# are dropped rather than preserved (an empty component means the current
# directory). Directories are added whether or not they already exist, so
# entries can be declared before first install. Only the requested entries
# move; every other component keeps its relative order. Arguments must not
# contain colons: a colon is the PATH separator and cannot appear inside one
# entry.
#
# Implementation notes (kept deliberately): no subshells or command
# substitutions; entries are compared with case patterns only when the
# argument has no pattern metacharacters, otherwise a static colon-stripping
# loop compares byte-exactly with [ ... = ... ]; caller IFS and the noglob
# option are saved and restored; private variables are namespaced
# (_contrib_path_*, _vp_*) and unset afterwards; diagnostics use printf.

# _contrib_path_entry_list <dir>... — print the deduplicated wanted entries as
# a colon list on _contrib_path_wanted (no leading/trailing colon).
_contrib_path_entry_list() {
  _contrib_path_wanted=
  for _contrib_path_item in "$@"; do
    [ -n "$_contrib_path_item" ] || continue
    case "$_contrib_path_item" in
      *:*) continue ;;
    esac
    case ":${_contrib_path_wanted}:" in
      *":${_contrib_path_item}:"*) ;;
      *) _contrib_path_wanted="${_contrib_path_wanted}:${_contrib_path_item}" ;;
    esac
  done
  _contrib_path_wanted=${_contrib_path_wanted#:}
}

# _contrib_path_split_save / _contrib_path_split_restore — preserve caller
# IFS and noglob around word-splitting of ${PATH-}.
_contrib_path_split_save() {
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
}

_contrib_path_split_restore() {
  if [ "$_contrib_path_ifs_was_set" -eq 1 ]; then
    IFS=$_contrib_path_old_ifs
  else
    unset IFS
  fi
  if [ "$_contrib_path_glob_off" -eq 1 ]; then
    set +f
  fi
}

# _contrib_path_kept — split ${PATH-} on colons with globbing off, dropping
# empty components, the wanted entries, and duplicates (first occurrence
# wins), and leave the result in _contrib_path_kept as a colon list.
_contrib_path_kept_build() {
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
  _contrib_path_kept=${_contrib_path_kept#:}
}

_contrib_path_rebuild() {
  # _contrib_path_rebuild <prepend|append> <dir>... — private helper.
  _contrib_path_mode=$1
  shift
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  _contrib_path_entry_list "$@"
  _contrib_path_split_save
  _contrib_path_kept_build
  _contrib_path_split_restore
  if [ "$_contrib_path_mode" = prepend ]; then
    if [ -n "$_contrib_path_wanted" ]; then
      _contrib_path_new="${_contrib_path_wanted}${_contrib_path_kept:+:${_contrib_path_kept}}"
    else
      _contrib_path_new=$_contrib_path_kept
    fi
  else
    if [ -n "$_contrib_path_wanted" ]; then
      _contrib_path_new="${_contrib_path_kept:+${_contrib_path_kept}:}${_contrib_path_wanted}"
    else
      _contrib_path_new=$_contrib_path_kept
    fi
  fi
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

# _vp_has_meta <dir> — true (0) when <dir> contains a POSIX pattern
# metacharacter, in which case case-pattern matching against it is unsafe.
_vp_has_meta() {
  case $1 in
    *\\* | *\** | *\?* | *\[* | *\]*) return 0 ;;
  esac
  return 1
}

valise_path_contains() {
  # Return 0 when $1 is exactly one entry of PATH. Empty or colon-bearing
  # arguments never match.
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  case "${1-}" in
    '' | *:*) return 1 ;;
  esac
  if _vp_has_meta "$1"; then
    _vp_p="${PATH-}${PATH:+:}"
    while [ -n "$_vp_p" ]; do
      if [ "${_vp_p%%:*}" = "$1" ]; then
        unset _vp_p
        return 0
      fi
      _vp_p=${_vp_p#*:}
    done
    unset _vp_p
    return 1
  fi
  case ":${PATH-}:" in
    *":$1:"*) return 0 ;;
  esac
  return 1
}

valise_path_remove() {
  # Remove every occurrence of each argument from PATH and drop empty
  # components. An empty or colon-bearing argument is rejected with a
  # diagnostic and leaves PATH untouched for that argument; the return status
  # is nonzero when any argument was rejected.
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  _vp_rc=0
  for _vp_arg in "$@"; do
    case "$_vp_arg" in
      '' | *:*)
        printf "valise_path_remove: invalid entry (empty or contains a colon): '%s'\n" "$_vp_arg" >&2
        _vp_rc=1
        continue
        ;;
    esac
    if _vp_has_meta "$_vp_arg"; then
      _vp_kept=
      _vp_rem="${PATH-}${PATH:+:}"
      while [ -n "$_vp_rem" ]; do
        _vp_f=${_vp_rem%%:*}
        _vp_rem=${_vp_rem#*:}
        [ -n "$_vp_f" ] || continue
        if [ "$_vp_f" = "$_vp_arg" ]; then
          :
        else
          _vp_kept="${_vp_kept:+${_vp_kept}:}${_vp_f}"
        fi
      done
      PATH=$_vp_kept
    else
      _vp_p=":${PATH-}:"
      _vp_kept=
      while :; do
        case $_vp_p in
          *":$_vp_arg:"*)
            _vp_p="${_vp_p%%":$_vp_arg:"*}:${_vp_p#*":$_vp_arg:"}"
            ;;
          *) break ;;
        esac
      done
      # Split the surviving entries, dropping empty components.
      _vp_rem=${_vp_p#:}
      _vp_rem=${_vp_rem%:}
      _vp_rem=${_vp_rem:+${_vp_rem}:}
      while [ -n "$_vp_rem" ]; do
        _vp_f=${_vp_rem%%:*}
        _vp_rem=${_vp_rem#*:}
        [ -n "$_vp_f" ] || continue
        _vp_kept="${_vp_kept:+${_vp_kept}:}${_vp_f}"
      done
      PATH=$_vp_kept
    fi
  done
  if [ -n "${PATH-}" ]; then
    export PATH
  else
    unset PATH
  fi
  case "${_vp_rc-}" in
    '' | *[!0-9]*) _vp_rc=0 ;;
  esac
  unset _vp_arg _vp_p _vp_kept _vp_rem _vp_f
  if [ "$_vp_rc" -ne 0 ]; then
    unset _vp_rc
    return 1
  fi
  unset _vp_rc
  return 0
}

valise_path_normalize() {
  # Drop empty components and duplicate entries from PATH in place; the first
  # occurrence of an entry wins.
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  _vp_out=
  _vp_rem="${PATH-}${PATH:+:}"
  while [ -n "$_vp_rem" ]; do
    _vp_f=${_vp_rem%%:*}
    _vp_rem=${_vp_rem#*:}
    [ -n "$_vp_f" ] || continue
    if _vp_has_meta "$_vp_f"; then
      case ":${_vp_out}:" in
        *":${_vp_f}:"*) continue ;;
      esac
    else
      case ":${_vp_out}:" in
        *":${_vp_f}:"*) continue ;;
      esac
    fi
    _vp_out="${_vp_out:+${_vp_out}:}${_vp_f}"
  done
  if [ -n "$_vp_out" ]; then
    PATH=$_vp_out
    export PATH
  else
    unset PATH
  fi
  unset _vp_out _vp_rem _vp_f
}
