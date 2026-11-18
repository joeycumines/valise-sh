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
# contains and remove report an empty or colon-bearing argument on stderr,
# because a colon is the PATH separator and cannot appear inside one entry:
# contains returns 1, and remove rejects that argument, leaves PATH untouched
# for it, and returns nonzero. prepend/append skip empty arguments; normalize
# takes no arguments and rewrites PATH in place.
#
# Implementation notes (kept deliberately): no subshells or command
# substitutions. PATH is always walked one colon-delimited component at a time
# with ${var%%:*}/${var#*:}, never with an unquoted word-split. A split is wrong
# twice: zsh does not split unquoted expansions by default, so the whole list
# arrived as one component, and every split field is subject to pathname
# expansion, so an entry like /a*b was replaced by a matching file on disk
# before it was compared (contains then reported a real entry absent, and remove
# deleted a different one). Stripping avoids both and needs no IFS or noglob
# save/restore - which is just as well, because `set -f` means NO_RCS in zsh,
# not noglob, so it is not a portable way to ask for it.
#
# Membership compares with [ ... = ... ], never with a case pattern over the
# entry: `shopt -s nocasematch` makes a case pattern case-insensitive (contains
# /bin then matched /BIN), and a pattern loop that strips with ${var%%pattern}
# agrees with neither under that option - it stops matching and spins forever.
# [ ... = ... ] is byte-exact under nocasematch, so it is the only comparison
# used here. Private variables are namespaced (_contrib_path_*, _vp_*) and unset
# afterwards; diagnostics use printf.

# _vp_list_contains <colon-list> <entry> — 0 when <entry> is exactly one
# component of <colon-list>. Byte-exact; empty components never match a
# non-empty entry.
_vp_list_contains() {
  _vplc_rest=${1-}
  _vplc_entry=${2-}
  _vplc_rc=1
  # The list is walked by stripping one colon-delimited component at a time.
  # Deliberately NOT an unquoted `for ... in $list`: that needs word splitting,
  # which zsh does not do by default, and the split fields are subject to
  # pathname expansion, so a component like `/a*b` was replaced by a matching
  # file on disk before it was ever compared (contains then reported a real
  # entry absent, and remove went on to delete a different one). Stripping with
  # ${var#pattern} does neither, and needs no IFS or noglob save/restore -
  # `set -f` means NO_RCS in zsh, so it is not even a portable way to ask for
  # noglob. The `*:*` test is a literal colon pattern, which nocasematch cannot
  # alter, and `case` never applies pathname expansion to its word.
  if [ -n "$_vplc_entry" ]; then
    while [ -n "$_vplc_rest" ]; do
      case $_vplc_rest in
      *:*)
        _vplc_head=${_vplc_rest%%:*}
        _vplc_rest=${_vplc_rest#*:}
        ;;
      *)
        _vplc_head=$_vplc_rest
        _vplc_rest=
        ;;
      esac
      if [ "$_vplc_head" = "$_vplc_entry" ]; then
        _vplc_rc=0
        break
      fi
    done
  fi
  # Return a literal, not "$_vplc_rc": the module promises every private
  # variable is unset afterwards, and a value can only be returned from a
  # variable that still exists.
  if [ "$_vplc_rc" -eq 0 ]; then
    unset _vplc_rest _vplc_entry _vplc_head _vplc_rc
    return 0
  fi
  unset _vplc_rest _vplc_entry _vplc_head _vplc_rc
  return 1
}

# _contrib_path_entry_list <dir>... — print the deduplicated wanted entries as
# a colon list on _contrib_path_wanted (no leading/trailing colon).
_contrib_path_entry_list() {
  _contrib_path_wanted=
  for _contrib_path_item in "$@"; do
    [ -n "$_contrib_path_item" ] || continue
    case "$_contrib_path_item" in
      *:*) continue ;;
    esac
    if _vp_list_contains "$_contrib_path_wanted" "$_contrib_path_item"; then
      continue
    fi
    _contrib_path_wanted="${_contrib_path_wanted}:${_contrib_path_item}"
  done
  _contrib_path_wanted=${_contrib_path_wanted#:}
}

# _contrib_path_kept — walk ${PATH-} one colon-delimited component at a time,
# dropping empty components, the wanted entries, and duplicates (first
# occurrence wins), and leave the result in _contrib_path_kept as a colon list.
# Components are stripped, never word-split: zsh does not split an unquoted
# expansion by default, and a split component is subject to pathname expansion
# (see _vp_list_contains). Stripping needs no IFS or noglob save/restore, which
# is what lets the helpers keep a caller's IFS and shell options untouched
# without ever asking for `set -f` - that means NO_RCS in zsh, not noglob.
_contrib_path_kept_build() {
  _contrib_path_kept=
  _contrib_path_rem=${PATH-}
  while [ -n "$_contrib_path_rem" ]; do
    case $_contrib_path_rem in
    *:*)
      _contrib_path_field=${_contrib_path_rem%%:*}
      _contrib_path_rem=${_contrib_path_rem#*:}
      ;;
    *)
      _contrib_path_field=$_contrib_path_rem
      _contrib_path_rem=
      ;;
    esac
    [ -n "$_contrib_path_field" ] || continue
    if _vp_list_contains "$_contrib_path_wanted" "$_contrib_path_field"; then
      continue
    fi
    if _vp_list_contains "$_contrib_path_kept" "$_contrib_path_field"; then
      continue
    fi
    _contrib_path_kept="${_contrib_path_kept:+${_contrib_path_kept}:}${_contrib_path_field}"
  done
}

_contrib_path_rebuild() {
  # _contrib_path_rebuild <prepend|append> <dir>... — private helper.
  _contrib_path_mode=$1
  shift
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  _contrib_path_entry_list "$@"
  _contrib_path_kept_build
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
  unset _contrib_path_mode _contrib_path_wanted _contrib_path_item _contrib_path_kept _contrib_path_field _contrib_path_new _contrib_path_rem
}

valise_path_prepend() {
  # Move each argument to the front of PATH, preserving argument order, so
  # the first argument ends up first.
  _contrib_path_rebuild prepend "$@"
}

valise_path_append() {
  _contrib_path_rebuild append "$@"
}

valise_path_contains() {
  # Return 0 when $1 is exactly one entry of PATH. Empty or colon-bearing
  # arguments never match and are reported on stderr, because a silent 1 is
  # indistinguishable from "absent".
  case "${ZSH_VERSION-}" in
    ?*) emulate -L sh 2>/dev/null || : ;;
  esac
  case "${1-}" in
    '' | *:*)
      printf "valise_path_contains: invalid entry (empty or contains a colon): '%s'\n" "${1-}" >&2
      return 1
      ;;
  esac
  _vp_list_contains "${PATH-}" "$1"
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
  _vp_changed=0
  for _vp_arg in "$@"; do
    case "$_vp_arg" in
      '' | *:*)
        printf "valise_path_remove: invalid entry (empty or contains a colon): '%s'\n" "$_vp_arg" >&2
        _vp_rc=1
        continue
        ;;
    esac
    _vp_changed=1
    _vp_kept=
    _vp_rem="${PATH-}${PATH:+:}"
    while [ -n "$_vp_rem" ]; do
      _vp_f=${_vp_rem%%:*}
      _vp_rem=${_vp_rem#*:}
      [ -n "$_vp_f" ] || continue
      [ "$_vp_f" = "$_vp_arg" ] && continue
      _vp_kept="${_vp_kept:+${_vp_kept}:}${_vp_f}"
    done
    PATH=$_vp_kept
  done
  # Every argument rejected, or no argument at all: PATH is exactly as the
  # caller had it, including a set-but-empty one. Unsetting it here would
  # contradict the promise that a rejected argument leaves PATH untouched.
  if [ "$_vp_changed" -eq 1 ]; then
    if [ -n "${PATH-}" ]; then
      export PATH
    else
      unset PATH
    fi
  fi
  case "${_vp_rc-}" in
    '' | *[!0-9]*) _vp_rc=0 ;;
  esac
  unset _vp_arg _vp_kept _vp_rem _vp_f _vp_changed
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
    if _vp_list_contains "$_vp_out" "$_vp_f"; then
      continue
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
