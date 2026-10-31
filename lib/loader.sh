#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# POSIX shell-profile module loader.

_sp_loader_path_is_physical() {
  _spl_check_root=$1
  _spl_check_path=$2
  case $_spl_check_root in
  /*) ;;
  *) _spl_check_root=$(command pwd)/$_spl_check_root ;;
  esac
  case $_spl_check_path in
  /*) ;;
  *) _spl_check_path=$(command pwd)/$_spl_check_path ;;
  esac
  case $_spl_check_root in
  /) ;;
  */) _spl_check_root=${_spl_check_root%/} ;;
  esac
  case $_spl_check_path in
  /) ;;
  */) _spl_check_path=${_spl_check_path%/} ;;
  esac
  _spl_check_rest=${_spl_check_root#/}
  _spl_check_prefix=/
  while [ -n "$_spl_check_rest" ]; do
    case $_spl_check_rest in
    */*)
      _spl_check_component=${_spl_check_rest%%/*}
      _spl_check_rest=${_spl_check_rest#*/}
      ;;
    *)
      _spl_check_component=$_spl_check_rest
      _spl_check_rest=
      ;;
    esac
    [ "$_spl_check_prefix" = / ] || _spl_check_prefix=$_spl_check_prefix/
    _spl_check_prefix=$_spl_check_prefix$_spl_check_component
    case $_spl_check_prefix in
    /var | /tmp) ;;
    *)
      if [ -L "$_spl_check_prefix" ]; then
        unset _spl_check_root _spl_check_path _spl_check_relative _spl_check_component _spl_check_prefix _spl_check_rest
        return 1
      fi
      ;;
    esac
  done
  unset _spl_check_rest
  case $_spl_check_path in
  "$_spl_check_root")
    unset _spl_check_root _spl_check_path _spl_check_relative _spl_check_component _spl_check_prefix
    return 0
    ;;
  "$_spl_check_root"/*)
    _spl_check_relative=${_spl_check_path#"$_spl_check_root"/}
    ;;
  *)
    unset _spl_check_root _spl_check_path _spl_check_relative _spl_check_component _spl_check_prefix
    return 1
    ;;
  esac
  _spl_check_prefix=$_spl_check_root
  while :; do
    case $_spl_check_relative in
    */*)
      _spl_check_component=${_spl_check_relative%%/*}
      _spl_check_relative=${_spl_check_relative#*/}
      ;;
    *)
      _spl_check_component=$_spl_check_relative
      _spl_check_relative=
      ;;
    esac
    _spl_check_prefix=$_spl_check_prefix/$_spl_check_component
    if [ -L "$_spl_check_prefix" ]; then
      unset _spl_check_root _spl_check_path _spl_check_relative _spl_check_component _spl_check_prefix
      return 1
    fi
    [ -n "$_spl_check_relative" ] || break
  done
  unset _spl_check_root _spl_check_path _spl_check_relative _spl_check_component _spl_check_prefix
  return 0
}

_sp_loader_read_record() {
  _splrr_file=$1
  _splrr_name=
  _splrr_requires=
  _splrr_optional=
  _splrr_shells=
  _splrr_platforms=
  _splrr_side_effect=
  _splrr_exports=
  _splrr_updates=
  _splrr_version=
  _splrr_load=
  _splrr_load_hook=
  while IFS= read -r _splrr_line || [ -n "$_splrr_line" ]; do
    case $_splrr_line in
    '' | '#'* | *=*) ;;
    *) continue ;;
    esac
    _splrr_key=${_splrr_line%%=*}
    _splrr_value=${_splrr_line#*=}
    case $_splrr_key in
    name) _splrr_name=$_splrr_value ;;
    requires) _splrr_requires=$_splrr_value ;;
    optional) _splrr_optional=$_splrr_value ;;
    shells) _splrr_shells=$_splrr_value ;;
    platforms) _splrr_platforms=$_splrr_value ;;
    side_effect) _splrr_side_effect=$_splrr_value ;;
    exports) _splrr_exports=$_splrr_value ;;
    updates) _splrr_updates=$_splrr_value ;;
    version) _splrr_version=$_splrr_value ;;
    load) _splrr_load=$_splrr_value ;;
    load_hook) _splrr_load_hook=$_splrr_value ;;
    esac
  done <"$_splrr_file"
  _spl_record_name=$_splrr_name
  _spl_record_requires=$_splrr_requires
  _spl_record_optional=$_splrr_optional
  _spl_record_shells=$_splrr_shells
  _spl_record_platforms=$_splrr_platforms
  _spl_record_side_effect=$_splrr_side_effect
  _spl_record_exports=$_splrr_exports
  _spl_record_updates=$_splrr_updates
  _spl_record_version=$_splrr_version
  _spl_record_load=$_splrr_load
  _spl_record_load_hook=$_splrr_load_hook
  unset _splrr_file _splrr_line _splrr_key _splrr_value _splrr_name _splrr_requires \
    _splrr_optional _splrr_shells _splrr_platforms _splrr_side_effect _splrr_exports \
    _splrr_updates _splrr_version _splrr_load _splrr_load_hook
}

_sp_loader_reserved_scan() {
  _splrs_file=$1
  _splrs_tab='	'
  _splrs_found=0
  while IFS= read -r _splrs_line || [ -n "$_splrs_line" ]; do
    _splrs_trimmed=$_splrs_line
    while :; do
      case $_splrs_trimmed in
      ' '*) _splrs_trimmed=${_splrs_trimmed# } ;;
      "$_splrs_tab"*) _splrs_trimmed=${_splrs_trimmed#"$_splrs_tab"} ;;
      *) break ;;
      esac
    done
    [ -n "$_splrs_trimmed" ] || continue
    if [ "${IFS+x}" = x ]; then
      _splrs_ifs_was_set=1
      _splrs_old_ifs=${IFS-}
    else
      _splrs_ifs_was_set=0
      _splrs_old_ifs=
    fi
    # Tokens are separated by any blank, as the shell itself treats them. The
    # line is data, so pathname expansion must not run on it.
    IFS=" $_splrs_tab"
    case $- in
    *f*) _splrs_noglob_was_set=1 ;;
    *)
      _splrs_noglob_was_set=0
      set -f
      ;;
    esac
    set -- $_splrs_trimmed
    [ "$_splrs_noglob_was_set" -eq 1 ] || set +f
    if [ "$_splrs_ifs_was_set" -eq 1 ]; then
      IFS=$_splrs_old_ifs
    else
      unset IFS
    fi
    _splrs_first=${1-}
    _splrs_second=${2-}
    _splrs_first=${_splrs_first#\"}
    _splrs_first=${_splrs_first%\"}
    _splrs_first=${_splrs_first#\'}
    _splrs_first=${_splrs_first%\'}
    _splrs_second=${_splrs_second#\"}
    _splrs_second=${_splrs_second%\"}
    _splrs_second=${_splrs_second#\'}
    _splrs_second=${_splrs_second%\'}
    case $_splrs_first in
    command | command'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      command'('*) _splrs_found=1 ;;
      esac
      ;;
    unset | unset'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      unset'('*) _splrs_found=1 ;;
      esac
      ;;
    return | return'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      return'('*) _splrs_found=1 ;;
      esac
      ;;
    eval | eval'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      eval'('*) _splrs_found=1 ;;
      esac
      ;;
    builtin | builtin'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      builtin'('*) _splrs_found=1 ;;
      esac
      ;;
    readonly | readonly'('*)
      case $_splrs_second in
      '('*) _splrs_found=1 ;;
      esac
      case $_splrs_first in
      readonly'('*) _splrs_found=1 ;;
      esac
      shift
      _splrs_seen_f=0
      for _splrs_word in "$@"; do
        _splrs_word=${_splrs_word#\"}
        _splrs_word=${_splrs_word%\"}
        _splrs_word=${_splrs_word#\'}
        _splrs_word=${_splrs_word%\'}
        if [ "$_splrs_word" = -f ]; then
          _splrs_seen_f=1
          continue
        fi
        if [ "$_splrs_seen_f" -eq 1 ]; then
          case $_splrs_word in
          command | command'('*) _splrs_found=1 ;;
          unset | unset'('*) _splrs_found=1 ;;
          return | return'('*) _splrs_found=1 ;;
          eval | eval'('*) _splrs_found=1 ;;
          builtin | builtin'('*) _splrs_found=1 ;;
          esac
        fi
      done
      ;;
    function)
      case $_splrs_second in
      command | command'('*) _splrs_found=1 ;;
      unset | unset'('*) _splrs_found=1 ;;
      readonly | readonly'('*) _splrs_found=1 ;;
      return | return'('*) _splrs_found=1 ;;
      eval | eval'('*) _splrs_found=1 ;;
      builtin | builtin'('*) _splrs_found=1 ;;
      esac
      ;;
    esac
    if [ "$_splrs_found" -ne 0 ]; then
      break
    fi
  done <"$_splrs_file"
  if [ "$_splrs_found" -eq 0 ]; then
    unset _splrs_file _splrs_tab _splrs_found _splrs_line _splrs_trimmed \
      _splrs_first _splrs_second _splrs_seen_f _splrs_word \
      _splrs_ifs_was_set _splrs_old_ifs _splrs_noglob_was_set
    return 0
  fi
  unset _splrs_file _splrs_tab _splrs_found _splrs_line _splrs_trimmed \
    _splrs_first _splrs_second _splrs_seen_f _splrs_word \
    _splrs_ifs_was_set _splrs_old_ifs _splrs_noglob_was_set
  return 1
}

sp_loader_load_modules() {
  if [ "$#" -ne 4 ]; then
    command printf '%s\n' 'loader: usage: sp_loader_load_modules <root> <wanted-list> <mode> <phase>' >&2
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 1
  fi

  _spl_root=$1
  _spl_wanted=$2
  _spl_mode=$3
  _spl_phase=$4
  _spl_return=0
  _spl_strict_error=0
  # Multi-root layer search path (T07): the primary root is $1 and always has
  # priority; VALISE_MODULE_PATH lists additional layer roots in priority
  # order. A set-but-empty VALISE_MODULE_PATH deliberately selects
  # single-root behavior (strict set-test: the variable wins whenever it is
  # set). Unset means today's single-root behavior.
  _spl_search_path=${VALISE_MODULE_PATH:-}
  _spl_current_shell=sh
  if [ -n "${BASH_VERSION:-}" ] && (command builtin shopt >/dev/null 2>&1); then
    _spl_current_shell=bash
  fi
  [ -n "${ZSH_VERSION:-}" ] && _spl_current_shell=zsh
  [ -n "${KSH_VERSION:-}" ] && _spl_current_shell=ksh
  _spl_uname=$(command uname -s 2>/dev/null || command printf unknown)
  case "$_spl_uname" in
  Darwin) _spl_current_platform=darwin ;;
  Linux) _spl_current_platform=linux ;;
  FreeBSD) _spl_current_platform=freebsd ;;
  OpenBSD) _spl_current_platform=openbsd ;;
  NetBSD) _spl_current_platform=netbsd ;;
  *BSD) _spl_current_platform=bsd ;;
  *) _spl_current_platform=unknown ;;
  esac

  case "$_spl_mode" in
  strict | permissive) ;;
  *)
    command printf 'loader: %s\n' "invalid mode: $_spl_mode" >&2
    unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_return _spl_strict_error _spl_current_shell _spl_uname _spl_current_platform _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words _spl_order_words _spl_failed_words
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 1
    ;;
  esac

  case "$_spl_phase" in
  ordinary) ;;
  *)
    command printf 'loader: %s\n' "invalid phase: $_spl_phase" >&2
    unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_return _spl_strict_error _spl_current_shell _spl_uname _spl_current_platform _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words _spl_order_words _spl_failed_words
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 1
    ;;
  esac

  if ! command -v sp_metadata_read >/dev/null 2>&1; then
    command printf '%s\n' 'loader: sp_metadata_read is not available; source lib/metadata.sh first' >&2
    unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_return _spl_strict_error _spl_current_shell _spl_uname _spl_current_platform _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words _spl_order_words _spl_failed_words
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 1
  fi

  _spl_tmp_parent=${TMPDIR:-/tmp}
  _spl_tmp=$(umask 077 && command mktemp -d \
    "$_spl_tmp_parent/shell-profile-loader.XXXXXX") || {
    unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_return _spl_strict_error _spl_current_shell _spl_uname _spl_current_platform _spl_tmp_parent _spl_tmp _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words _spl_order_words _spl_failed_words
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 1
  }
  _spl_cleanup_tmp=$_spl_tmp
  _spl_tmp_sentinel=$_spl_tmp/.shell-profile-loader-owned
  _spl_seen_words=
  _spl_strict_required_words=
  _spl_blocked_words=
  _spl_modules_words=
  _spl_order_words=
  _spl_failed_words=
  : >"$_spl_tmp_sentinel" || _spl_return=1
  command mkdir -p "$_spl_tmp/meta" "$_spl_tmp/deps" "$_spl_tmp/optional" "$_spl_tmp/run" "$_spl_tmp/roots" || _spl_return=1
  : >"$_spl_tmp/queue"
  : >"$_spl_tmp/modules"
  : >"$_spl_tmp/blocked"
  : >"$_spl_tmp/platform_blocked"
  : >"$_spl_tmp/order"
  : >"$_spl_tmp/failed"
  : >"$_spl_tmp/layers"

  # Validate the layer search path fail-closed: every colon-separated element
  # must be a non-empty readable, executable directory. Empty elements,
  # missing, unreadable, or unsearchable directories are data errors, not
  # skips. Identical duplicate elements are
  # deduplicated (priority is first occurrence).
  if [ "$_spl_return" -eq 0 ] && [ -n "$_spl_search_path" ]; then
    if [ "${IFS+x}" = x ]; then
      _spl_layer_ifs_was_set=1
      _spl_layer_old_ifs=${IFS-}
    else
      _spl_layer_ifs_was_set=0
      _spl_layer_old_ifs=
    fi
    case $- in
    *f*) _spl_layer_glob_was_set=1 ;;
    *)
      _spl_layer_glob_was_set=0
      set -f
      ;;
    esac
    # Shell field splitting discards leading/trailing empty fields, so reject
    # empty colon elements before iterating (including a path consisting only
    # of colons). Newlines cannot be represented by the line-oriented
    # temporary file used below.
    case $_spl_search_path in
    *'
'*)
      command printf 'loader: %s\n' \
        'invalid VALISE_MODULE_PATH element: newlines are forbidden' >&2
      _spl_return=1
      _spl_strict_error=1
      ;;
    esac
    case $_spl_search_path in
    *'['* | *'?'* | *'*'*)
      command printf 'loader: %s\n' \
        'invalid VALISE_MODULE_PATH element: glob metacharacters are forbidden' >&2
      _spl_return=1
      _spl_strict_error=1
      ;;
    esac
    case $_spl_search_path in
    :* | *: | *::* )
      # Preserve empty-element rejection despite POSIX field splitting eliding
      # null fields at the boundaries and between adjacent delimiters.
      _spl_layer=
      command printf 'loader: %s\n' \
        'invalid VALISE_MODULE_PATH element: empty path element is forbidden' >&2
      _spl_return=1
      _spl_strict_error=1
      ;;
    esac
    IFS=:
    for _spl_layer in $_spl_search_path; do
        if [ -z "$_spl_layer" ] || ! _sp_loader_path_is_physical "$_spl_layer" "$_spl_layer" || [ ! -d "$_spl_layer" ] || [ ! -r "$_spl_layer" ] || [ ! -x "$_spl_layer" ]; then
        command printf 'loader: %s\n' \
          "invalid VALISE_MODULE_PATH element: $_spl_layer (must be a non-empty readable, executable directory)" >&2
        _spl_return=1
        _spl_strict_error=1
        break
      fi
      if [ -n "$(command grep -Fx -- "$_spl_layer" "$_spl_tmp/layers" 2>/dev/null)" ]; then
        continue
      fi
      command printf '%s\n' "$_spl_layer" >>"$_spl_tmp/layers"
    done
    [ "$_spl_layer_glob_was_set" -eq 1 ] || set +f
    if [ "$_spl_layer_ifs_was_set" -eq 1 ]; then
      IFS=$_spl_layer_old_ifs
    else
      unset IFS
    fi
    unset _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_layer_glob_was_set _spl_newline
  fi

  if [ "$_spl_return" -eq 0 ]; then
    if ! sp_metadata_validate_identifier_list "$_spl_wanted" 'wanted module'; then
      _spl_return=1
      _spl_strict_error=1
    fi
  fi

  if [ "$_spl_return" -eq 0 ]; then
    if [ "${IFS+x}" = x ]; then
      _spl_ifs_was_set=1
      _spl_old_ifs=${IFS-}
    else
      _spl_ifs_was_set=0
      _spl_old_ifs=
    fi
    case $- in
    *f*) _spl_glob_was_set=1 ;;
    *)
      _spl_glob_was_set=0
      set -f
      ;;
    esac
    IFS=' '
    for _spl_word in $_spl_wanted; do
      if sp_metadata_validate_identifier "$_spl_word"; then
        command printf '%s\n' "$_spl_word" >>"$_spl_tmp/queue"
        _spl_strict_required_words="$_spl_strict_required_words $_spl_word"
      else
        command printf 'loader: %s\n' "invalid wanted module: $_spl_word" >&2
        _spl_return=1
        _spl_strict_error=1
      fi
    done
    [ "$_spl_glob_was_set" -eq 1 ] || set +f
    if [ "$_spl_ifs_was_set" -eq 1 ]; then
      IFS=$_spl_old_ifs
    else
      unset IFS
    fi
  fi

  while [ "$_spl_return" -eq 0 ] && [ -s "$_spl_tmp/queue" ]; do
    command sort -u "$_spl_tmp/queue" >"$_spl_tmp/queue.next"
    command mv "$_spl_tmp/queue.next" "$_spl_tmp/queue"
    : >"$_spl_tmp/newqueue"
    while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
      [ -n "$_spl_mod" ] || continue
      case " $_spl_seen_words " in
      *" $_spl_mod "*) continue ;;
      esac
      _spl_seen_words="$_spl_seen_words $_spl_mod"
      # Multi-root resolution (T07): search the primary root then each layer
      # root in priority order. First hit wins; a second hit whose metadata
      # or body differs by even one byte is a hard error naming both paths
      # (never shadowing). When both records carry valid versions and the
      # versions differ, the error names the versions so the consumer knows
      # to vendor a single version; equal versions (including two
      # unversioned records) keep the byte rule. A byte-identical meta+body
      # copy in a lower layer is redundant but harmless and resolves to the
      # higher-priority root. A same-name layer module must carry the
      # contrib_ prefix.
      _spl_meta_file=
      _spl_meta_root=
      if [ -L "$_spl_root/module.d/$_spl_mod.meta" ] || { [ -e "$_spl_root/module.d/$_spl_mod.meta" ] && ! _sp_loader_path_is_physical "$_spl_root" "$_spl_root/module.d/$_spl_mod.meta"; }; then
        command printf 'loader: %s\n' "$_spl_mod: metadata path contains a symlink" >&2
        _spl_return=1
        _spl_strict_error=1
      elif [ -f "$_spl_root/module.d/$_spl_mod.meta" ]; then
        _spl_meta_file=$_spl_root/module.d/$_spl_mod.meta
        _spl_meta_root=$_spl_root
      fi
      if [ -s "$_spl_tmp/layers" ]; then
        while IFS= read -r _spl_layer || [ -n "$_spl_layer" ]; do
          [ -n "$_spl_layer" ] || continue
          if [ -L "$_spl_layer/module.d/$_spl_mod.meta" ] || { [ -e "$_spl_layer/module.d/$_spl_mod.meta" ] && ! _sp_loader_path_is_physical "$_spl_layer" "$_spl_layer/module.d/$_spl_mod.meta"; }; then
            command printf 'loader: %s\n' "$_spl_mod: metadata path contains a symlink: $_spl_layer/module.d/$_spl_mod.meta" >&2
            _spl_return=1
            _spl_strict_error=1
            break
          elif [ -f "$_spl_layer/module.d/$_spl_mod.meta" ]; then
            if [ -n "$_spl_meta_file" ]; then
              _spl_conflict=0
              if ! command cmp -s "$_spl_meta_file" "$_spl_layer/module.d/$_spl_mod.meta"; then
                _sp_loader_read_record "$_spl_meta_file"
                _spl_existing_version=$_spl_record_version
                _sp_loader_read_record "$_spl_layer/module.d/$_spl_mod.meta"
                _spl_layer_version=$_spl_record_version
                if sp_metadata_validate_version "$_spl_existing_version" 2>/dev/null &&
                  sp_metadata_validate_version "$_spl_layer_version" 2>/dev/null &&
                  [ "$_spl_existing_version" != "$_spl_layer_version" ]; then
                  if [ -z "$_spl_existing_version" ]; then
                    _spl_existing_version_display=unversioned
                  else
                    _spl_existing_version_display=$_spl_existing_version
                  fi
                  if [ -z "$_spl_layer_version" ]; then
                    _spl_layer_version_display=unversioned
                  else
                    _spl_layer_version_display=$_spl_layer_version
                  fi
                  command printf 'loader: %s\n' \
                    "$_spl_mod: conflicting versions are forbidden: version $_spl_existing_version_display at $_spl_meta_file vs version $_spl_layer_version_display at $_spl_layer/module.d/$_spl_mod.meta (vendor a single version)" >&2
                  _spl_return=1
                  _spl_strict_error=1
                  break
                fi
                _spl_conflict=1
              else
                _sp_loader_read_record "$_spl_meta_file"
                _spl_existing_load=$_spl_record_load
                _sp_loader_read_record "$_spl_layer/module.d/$_spl_mod.meta"
                _spl_layer_load=$_spl_record_load
                if [ -n "$_spl_existing_load" ] && [ -n "$_spl_layer_load" ]; then
                  if ! _sp_loader_path_is_physical "$_spl_meta_root" "$_spl_meta_root/$_spl_existing_load" ||
                     ! _sp_loader_path_is_physical "$_spl_layer" "$_spl_layer/$_spl_layer_load"; then
                    command printf 'loader: %s\n' "$_spl_mod: load path contains a symlink" >&2
                    _spl_return=1
                    _spl_strict_error=1
                    break
                  elif ! command cmp -s "$_spl_meta_root/$_spl_existing_load" \
                    "$_spl_layer/$_spl_layer_load"; then
                    _spl_conflict=1
                  fi
                elif [ -n "$_spl_existing_load" ] || [ -n "$_spl_layer_load" ]; then
                  _spl_conflict=1
                fi
              fi
              if [ "$_spl_conflict" -ne 0 ]; then
                command printf 'loader: %s\n' \
                  "$_spl_mod: same-name module with different bytes is forbidden: $_spl_meta_file and $_spl_layer/module.d/$_spl_mod.meta (never shadowing; one must be renamed)" >&2
                _spl_return=1
                _spl_strict_error=1
                break
              fi
              continue
            fi
            case $_spl_mod in
            contrib_*) ;;
            *)
              command printf 'loader: %s\n' \
                "$_spl_mod: layer modules outside the primary root must use the contrib_ name prefix (found in layer $_spl_layer)" >&2
              _spl_return=1
              _spl_strict_error=1
              break
              ;;
            esac
            _spl_meta_file=$_spl_layer/module.d/$_spl_mod.meta
            _spl_meta_root=$_spl_layer
          fi
        done <"$_spl_tmp/layers"
        if [ "$_spl_return" -ne 0 ]; then
          command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
          _spl_blocked_words="$_spl_blocked_words $_spl_mod"
          continue
        fi
      fi
      if [ -z "$_spl_meta_file" ]; then
        command printf 'loader: %s\n' "$_spl_mod: metadata file missing" >&2
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      command printf '%s\n' "$_spl_meta_root" >>"$_spl_tmp/roots/$_spl_mod"
      _spl_record=$_spl_tmp/meta/$_spl_mod
      if ! sp_metadata_read "$_spl_meta_file" >"$_spl_record"; then
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      _sp_loader_read_record "$_spl_record"
      command printf 'load=%s\nload_hook=%s\nexports=%s\n' \
        "$_spl_record_load" "$_spl_record_load_hook" "$_spl_record_exports" \
        >"$_spl_tmp/run/$_spl_mod"
      if [ "$_spl_record_name" != "$_spl_mod" ]; then
        command printf 'loader: %s\n' "$_spl_mod: metadata name mismatch: $_spl_record_name" >&2
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      if [ "$_spl_phase" = ordinary ] && ! sp_metadata_validate_source_side_effect "$_spl_record_side_effect"; then
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      _spl_shell_match=0
      _spl_platform_match=0
      if [ "${IFS+x}" = x ]; then
        _spl_match_ifs_was_set=1
        _spl_match_old_ifs=${IFS-}
      else
        _spl_match_ifs_was_set=0
        _spl_match_old_ifs=
      fi
      IFS=' '
      for _spl_value in $_spl_record_shells; do
        [ "$_spl_value" = sh ] && _spl_shell_match=1
        [ "$_spl_value" = "$_spl_current_shell" ] && _spl_shell_match=1
      done
      for _spl_value in $_spl_record_platforms; do
        [ "$_spl_value" = any ] && _spl_platform_match=1
        [ "$_spl_value" = "$_spl_current_platform" ] && _spl_platform_match=1
        [ "$_spl_value" = bsd ] && case "$_spl_current_platform" in bsd | freebsd | openbsd | netbsd) _spl_platform_match=1 ;; esac
      done
      if [ "$_spl_match_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_match_old_ifs
      else
        unset IFS
      fi
      if [ "$_spl_shell_match" -ne 1 ]; then
        command printf 'loader: %s\n' "$_spl_mod: unsupported shell for $_spl_current_shell" >&2
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      if [ "$_spl_platform_match" -ne 1 ]; then
        # Record the skip; whether to report it depends on the complete
        # required closure, which is only known after discovery. A module
        # reached only as an optional dependency is expected to be absent on
        # some hosts, and reporting it would print at every shell startup.
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/platform_blocked"
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
        _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        continue
      fi
      command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/modules"
      _spl_modules_words="$_spl_modules_words $_spl_mod"
      command printf '%s\n' "$_spl_record_requires" >"$_spl_tmp/deps/$_spl_mod"
      command printf '%s\n' "$_spl_record_optional" >"$_spl_tmp/optional/$_spl_mod"

      if [ "${IFS+x}" = x ]; then
        _spl_dep_ifs_was_set=1
        _spl_dep_old_ifs=${IFS-}
      else
        _spl_dep_ifs_was_set=0
        _spl_dep_old_ifs=
      fi
      IFS=' '
      for _spl_dep in $_spl_record_requires; do
        case " $_spl_strict_required_words " in
        *" $_spl_mod "*)
          _spl_strict_required_words="$_spl_strict_required_words $_spl_dep"
          ;;
        esac
        _spl_dep_exists=0
        if [ -f "$_spl_root/module.d/$_spl_dep.meta" ]; then
          _spl_dep_exists=1
        else
          if [ -s "$_spl_tmp/layers" ]; then
            while IFS= read -r _spl_layer || [ -n "$_spl_layer" ]; do
              [ -n "$_spl_layer" ] || continue
              if [ -f "$_spl_layer/module.d/$_spl_dep.meta" ]; then
                _spl_dep_exists=1
                break
              fi
            done <"$_spl_tmp/layers"
          fi
        fi
        if [ "$_spl_dep_exists" -eq 1 ]; then
          case " $_spl_seen_words " in
          *" $_spl_dep "*) ;;
          *)
            command printf '%s\n' "$_spl_dep" >>"$_spl_tmp/newqueue"
            ;;
          esac
        else
          command printf 'loader: %s\n' "$_spl_mod: missing required dependency $_spl_dep" >&2
          command printf '%s\n' "$_spl_dep" >>"$_spl_tmp/blocked"
          _spl_blocked_words="$_spl_blocked_words $_spl_dep"
          [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
        fi
      done
      for _spl_dep in $_spl_record_optional; do
        _spl_dep_exists=0
        if [ -f "$_spl_root/module.d/$_spl_dep.meta" ]; then
          _spl_dep_exists=1
        else
          if [ -s "$_spl_tmp/layers" ]; then
            while IFS= read -r _spl_layer || [ -n "$_spl_layer" ]; do
              [ -n "$_spl_layer" ] || continue
              if [ -f "$_spl_layer/module.d/$_spl_dep.meta" ]; then
                _spl_dep_exists=1
                break
              fi
            done <"$_spl_tmp/layers"
          fi
        fi
        if [ "$_spl_dep_exists" -eq 1 ]; then
          case " $_spl_seen_words " in
          *" $_spl_dep "*) ;;
          *)
            command printf '%s\n' "$_spl_dep" >>"$_spl_tmp/newqueue"
            ;;
          esac
        fi
      done
      unset _spl_record_name _spl_record_requires _spl_record_optional _spl_record_shells \
        _spl_record_platforms _spl_record_side_effect _spl_record_exports _spl_record_updates \
        _spl_record_version _spl_record_load _spl_record_load_hook
      if [ "$_spl_dep_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_dep_old_ifs
      else
        unset IFS
      fi
    done <"$_spl_tmp/queue"
    command mv "$_spl_tmp/newqueue" "$_spl_tmp/queue"
  done

  # Discovery can reach a module through an optional edge before a required
  # edge promotes its parent. Re-walk the requires graph to a fixpoint so the
  # required closure does not depend on discovery order.
  if [ "$_spl_return" -eq 0 ]; then
    if [ "${IFS+x}" = x ]; then
      _spl_ifs_was_set=1
      _spl_old_ifs=${IFS-}
    else
      _spl_ifs_was_set=0
      _spl_old_ifs=
    fi
    IFS=' '
    _spl_progress=1
    while [ "$_spl_progress" -ne 0 ]; do
      _spl_progress=0
      for _spl_mod in $_spl_strict_required_words; do
        [ -f "$_spl_tmp/deps/$_spl_mod" ] || continue
        IFS= read -r _spl_requires <"$_spl_tmp/deps/$_spl_mod" || :
        for _spl_dep in $_spl_requires; do
          case " $_spl_strict_required_words " in
          *" $_spl_dep "*) ;;
          *)
            _spl_strict_required_words="$_spl_strict_required_words $_spl_dep"
            _spl_progress=1
            ;;
          esac
        done
      done
    done
    if [ "$_spl_ifs_was_set" -eq 1 ]; then
      IFS=$_spl_old_ifs
    else
      unset IFS
    fi
    unset _spl_mod _spl_requires _spl_dep
  fi

  # A platform skip is reported only when the module belongs to the required
  # closure. Discovery can reach a module through an optional edge before a
  # required edge (or through a required edge that is itself discovered
  # later), so the decision waits until every edge has been walked.
  if [ "$_spl_return" -eq 0 ] && [ -s "$_spl_tmp/platform_blocked" ]; then
    while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
      [ -n "$_spl_mod" ] || continue
      case " $_spl_strict_required_words " in
      *" $_spl_mod "*)
        command printf 'loader: %s\n' "$_spl_mod: unsupported platform for $_spl_current_platform" >&2
        [ "$_spl_mode" = strict ] && _spl_strict_error=1
        ;;
      esac
    done <"$_spl_tmp/platform_blocked"
    unset _spl_mod
  fi

  if [ "$_spl_return" -eq 0 ]; then
    command sort -u "$_spl_tmp/modules" >"$_spl_tmp/remaining"
    command sort -u "$_spl_tmp/blocked" >"$_spl_tmp/blocked.sorted"
    command mv "$_spl_tmp/blocked.sorted" "$_spl_tmp/blocked"

    while [ -s "$_spl_tmp/remaining" ]; do
      _spl_progress=0
      : >"$_spl_tmp/next_remaining"
      while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
        [ -n "$_spl_mod" ] || continue
        case " $_spl_blocked_words " in
        *" $_spl_mod "*)
          _spl_progress=1
          continue
          ;;
        esac
        _spl_ready=1
        _spl_blocked_by=
        _spl_requires=
        [ -f "$_spl_tmp/deps/$_spl_mod" ] && {
          IFS= read -r _spl_requires <"$_spl_tmp/deps/$_spl_mod" || :
        }
        _spl_optional=
        [ -f "$_spl_tmp/optional/$_spl_mod" ] && {
          IFS= read -r _spl_optional <"$_spl_tmp/optional/$_spl_mod" || :
        }
        if [ "${IFS+x}" = x ]; then
          _spl_topo_ifs_was_set=1
          _spl_topo_old_ifs=${IFS-}
        else
          _spl_topo_ifs_was_set=0
          _spl_topo_old_ifs=
        fi
        IFS=' '
        for _spl_dep in $_spl_requires; do
          case " $_spl_blocked_words " in
          *" $_spl_dep "*)
            _spl_ready=0
            _spl_blocked_by=$_spl_dep
            ;;
          esac
          case " $_spl_order_words " in
          *" $_spl_dep "*) ;;
          *)
            _spl_ready=0
            ;;
          esac
        done
        if [ "$_spl_ready" -eq 1 ]; then
          for _spl_dep in $_spl_optional; do
            case " $_spl_modules_words " in
            *" $_spl_dep "*)
              case " $_spl_blocked_words " in
              *" $_spl_dep "*) ;;
              *)
                case " $_spl_order_words " in
                *" $_spl_dep "*) ;;
                *)
                  _spl_ready=0
                  ;;
                esac
                ;;
              esac
              ;;
            esac
          done
        fi
        if [ "$_spl_topo_ifs_was_set" -eq 1 ]; then
          IFS=$_spl_topo_old_ifs
        else
          unset IFS
        fi
        if [ -n "$_spl_blocked_by" ]; then
          command printf 'loader: %s\n' "$_spl_mod: required dependency unavailable: $_spl_blocked_by" >&2
          command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
          _spl_blocked_words="$_spl_blocked_words $_spl_mod"
          command sort -u "$_spl_tmp/blocked" >"$_spl_tmp/blocked.sorted"
          command mv "$_spl_tmp/blocked.sorted" "$_spl_tmp/blocked"
          [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_strict_error=1 ;; esac
          _spl_progress=1
          continue
        fi
        if [ "$_spl_ready" -eq 1 ]; then
          command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/order"
          _spl_order_words="$_spl_order_words $_spl_mod"
          _spl_progress=1
        else
          command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/next_remaining"
        fi
      done <"$_spl_tmp/remaining"
      if [ "$_spl_progress" -eq 0 ]; then
        : >"$_spl_tmp/next_remaining.optional"
        while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
          [ -n "$_spl_mod" ] || continue
          case " $_spl_blocked_words " in
          *" $_spl_mod "*)
            _spl_progress=1
            continue
            ;;
          esac
          _spl_ready=1
          _spl_blocked_by=
          _spl_requires=
          [ -f "$_spl_tmp/deps/$_spl_mod" ] && {
            IFS= read -r _spl_requires <"$_spl_tmp/deps/$_spl_mod" || :
          }
          if [ "${IFS+x}" = x ]; then
            _spl_topo_ifs_was_set=1
            _spl_topo_old_ifs=${IFS-}
          else
            _spl_topo_ifs_was_set=0
            _spl_topo_old_ifs=
          fi
          IFS=' '
          for _spl_dep in $_spl_requires; do
            case " $_spl_blocked_words " in
            *" $_spl_dep "*)
              _spl_ready=0
              _spl_blocked_by=$_spl_dep
              ;;
            esac
            case " $_spl_order_words " in
            *" $_spl_dep "*) ;;
            *)
              _spl_ready=0
              ;;
            esac
          done
          if [ "$_spl_topo_ifs_was_set" -eq 1 ]; then
            IFS=$_spl_topo_old_ifs
          else
            unset IFS
          fi
          if [ -n "$_spl_blocked_by" ]; then
            command printf 'loader: %s\n' "$_spl_mod: required dependency unavailable: $_spl_blocked_by" >&2
            command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
            _spl_blocked_words="$_spl_blocked_words $_spl_mod"
            command sort -u "$_spl_tmp/blocked" >"$_spl_tmp/blocked.sorted"
            command mv "$_spl_tmp/blocked.sorted" "$_spl_tmp/blocked"
            _spl_progress=1
            continue
          fi
          if [ "$_spl_ready" -eq 1 ]; then
            command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/order"
            _spl_order_words="$_spl_order_words $_spl_mod"
            _spl_progress=1
          else
            command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/next_remaining.optional"
          fi
        done <"$_spl_tmp/remaining"
        command mv "$_spl_tmp/next_remaining.optional" "$_spl_tmp/next_remaining"
      fi
      if [ "$_spl_progress" -eq 0 ]; then
        command printf '%s\n' 'loader: cycle detected in module dependencies' >&2
        while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
          [ -n "$_spl_mod" ] || continue
          command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/blocked"
          _spl_blocked_words="$_spl_blocked_words $_spl_mod"
        done <"$_spl_tmp/remaining"
        command sort -u "$_spl_tmp/blocked" >"$_spl_tmp/blocked.sorted"
        command mv "$_spl_tmp/blocked.sorted" "$_spl_tmp/blocked"
        if [ "$_spl_mode" = strict ]; then
          while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
            case " $_spl_strict_required_words " in
            *" $_spl_mod "*) _spl_strict_error=1 ;;
            esac
          done <"$_spl_tmp/remaining"
        fi
        : >"$_spl_tmp/remaining"
      else
        command sort -u "$_spl_tmp/next_remaining" >"$_spl_tmp/remaining"
      fi
    done
  fi

  if [ "$_spl_return" -eq 0 ] && [ "$_spl_mode" = strict ] && [ "$_spl_strict_error" -ne 0 ]; then
    _spl_return=1
  fi

  if [ "$_spl_return" -eq 0 ] && [ "${VALISE_RELOAD:-}" = 1 ]; then
    while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
      [ -n "$_spl_mod" ] || continue
      _spl_exports=
      while IFS= read -r _spl_run_line || [ -n "$_spl_run_line" ]; do
        case $_spl_run_line in
        exports=*) _spl_exports=${_spl_run_line#exports=} ;;
        esac
      done <"$_spl_tmp/run/$_spl_mod"
      unset _spl_run_line
      if [ "${IFS+x}" = x ]; then
        _spl_reload_ifs_was_set=1
        _spl_reload_old_ifs=${IFS-}
      else
        _spl_reload_ifs_was_set=0
        _spl_reload_old_ifs=
      fi
      IFS=' '
      for _spl_export in $_spl_exports; do
        unset -f "$_spl_export" 2>/dev/null || :
      done
      if [ "$_spl_reload_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_reload_old_ifs
      else
        unset IFS
      fi
    done <"$_spl_tmp/order"
  fi

  if [ "$_spl_return" -eq 0 ]; then
    while IFS= read -r _spl_mod || [ -n "$_spl_mod" ]; do
      [ -n "$_spl_mod" ] || continue
      case " $_spl_blocked_words " in
      *" $_spl_mod "*) continue ;;
      esac
      _spl_runtime_skip=0
      _spl_requires=
      [ -f "$_spl_tmp/deps/$_spl_mod" ] && {
        IFS= read -r _spl_requires <"$_spl_tmp/deps/$_spl_mod" || :
      }
      if [ "${IFS+x}" = x ]; then
        _spl_run_ifs_was_set=1
        _spl_run_old_ifs=${IFS-}
      else
        _spl_run_ifs_was_set=0
        _spl_run_old_ifs=
      fi
      IFS=' '
      for _spl_dep in $_spl_requires; do
        case " $_spl_failed_words " in
        *" $_spl_dep "*)
          command printf 'loader: %s\n' "$_spl_mod: required dependency failed: $_spl_dep" >&2
          _spl_runtime_skip=1
          ;;
        esac
      done
      if [ "$_spl_run_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_run_old_ifs
      else
        unset IFS
      fi
      if [ "$_spl_runtime_skip" -ne 0 ]; then
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/failed"
        _spl_failed_words="$_spl_failed_words $_spl_mod"
        [ "$_spl_mode" = strict ] && case " $_spl_strict_required_words " in *" $_spl_mod "*) _spl_return=1 && break ;; esac
        continue
      fi
      _spl_record=$_spl_tmp/meta/$_spl_mod
      _spl_load=
      _spl_load_hook=
      _spl_exports=
      while IFS= read -r _spl_run_line || [ -n "$_spl_run_line" ]; do
        case $_spl_run_line in
        load=*) _spl_load=${_spl_run_line#load=} ;;
        load_hook=*) _spl_load_hook=${_spl_run_line#load_hook=} ;;
        exports=*) _spl_exports=${_spl_run_line#exports=} ;;
        esac
      done <"$_spl_tmp/run/$_spl_mod"
      unset _spl_run_line
      _spl_exports_to_cleanup=
      _spl_wrapper_exports=
      _spl_load_status=0
      if [ "${IFS+x}" = x ]; then
        _spl_export_ifs_was_set=1
        _spl_export_old_ifs=${IFS-}
      else
        _spl_export_ifs_was_set=0
        _spl_export_old_ifs=
      fi
      IFS=' '
      for _spl_export in $_spl_exports; do
        _spl_export_conflict=0
        if command alias "$_spl_export" >/dev/null 2>&1; then
          _spl_export_conflict=1
        fi
        if _spl_export_lookup=$(command -v "$_spl_export" 2>/dev/null); then
          case $_spl_export_lookup in
          alias\ *) _spl_export_conflict=1 ;;
          */*) _spl_wrapper_exports=${_spl_wrapper_exports:+$_spl_wrapper_exports }$_spl_export ;;
          *) _spl_export_conflict=1 ;;
          esac
        else
          _spl_export_lookup=
        fi
        if [ "$_spl_export_conflict" -ne 0 ]; then
          command printf 'loader: %s\n' "$_spl_mod: declared export already exists before load: $_spl_export" >&2
          _spl_load_status=1
        else
          _spl_exports_to_cleanup=${_spl_exports_to_cleanup:+$_spl_exports_to_cleanup }$_spl_export
        fi
      done
      if [ "$_spl_export_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_export_old_ifs
      else
        unset IFS
      fi
      _spl_expected_tmp=$_spl_tmp
      _spl_expected_cleanup_tmp=$_spl_cleanup_tmp
      _spl_expected_tmp_parent=$_spl_tmp_parent
      _spl_expected_tmp_sentinel=$_spl_tmp_sentinel
      _spl_expected_root=$_spl_root
      _spl_expected_search_path=${_spl_search_path-}
      _spl_expected_meta_file=${_spl_meta_file-}
      _spl_expected_meta_root=${_spl_meta_root-}
      _spl_expected_layer=${_spl_layer-}
      _spl_expected_dep_exists=${_spl_dep_exists-}
      _spl_expected_wanted=$_spl_wanted
      _spl_expected_mode=$_spl_mode
      _spl_expected_phase=$_spl_phase
      _spl_expected_return=$_spl_return
      _spl_expected_strict_error=$_spl_strict_error
      _spl_expected_current_shell=$_spl_current_shell
      _spl_expected_current_platform=$_spl_current_platform
      _spl_expected_mod=$_spl_mod
      _spl_expected_record=$_spl_record
      _spl_expected_load=$_spl_load
      _spl_expected_load_hook=$_spl_load_hook
      _spl_expected_exports=$_spl_exports
      _spl_expected_exports_to_cleanup=$_spl_exports_to_cleanup
      _spl_guard_tmp=$_spl_expected_tmp
      _spl_guard_cleanup_tmp=$_spl_expected_cleanup_tmp
      _spl_guard_tmp_parent=$_spl_expected_tmp_parent
      _spl_guard_tmp_sentinel=$_spl_expected_tmp_sentinel
      _spl_guard_root=$_spl_expected_root
      _spl_guard_search_path=$_spl_expected_search_path
      _spl_guard_meta_file=$_spl_expected_meta_file
      _spl_guard_meta_root=$_spl_expected_meta_root
      _spl_guard_layer=$_spl_expected_layer
      _spl_guard_dep_exists=$_spl_expected_dep_exists
      _spl_guard_wanted=$_spl_expected_wanted
      _spl_guard_mode=$_spl_expected_mode
      _spl_guard_phase=$_spl_expected_phase
      _spl_guard_return=$_spl_expected_return
      _spl_guard_strict_error=$_spl_expected_strict_error
      _spl_guard_current_shell=$_spl_expected_current_shell
      _spl_guard_current_platform=$_spl_expected_current_platform
      _spl_guard_mod=$_spl_expected_mod
      _spl_guard_record=$_spl_expected_record
      _spl_guard_load=$_spl_expected_load
      _spl_guard_load_hook=$_spl_expected_load_hook
      _spl_guard_exports=$_spl_expected_exports
      _spl_guard_exports_to_cleanup=$_spl_expected_exports_to_cleanup
      _spl_guard_wrapper_exports=$_spl_wrapper_exports
      _spl_guard_seen_words=$_spl_seen_words
      _spl_guard_strict_required_words=$_spl_strict_required_words
      _spl_guard_blocked_words=$_spl_blocked_words
      _spl_guard_modules_words=$_spl_modules_words
      _spl_guard_order_words=$_spl_order_words
      _spl_guard_failed_words=$_spl_failed_words
      _spl_expected_pwd_was_set=0
      _spl_expected_pwd=
      if [ "${PWD+x}" = x ]; then
        _spl_expected_pwd_was_set=1
        _spl_expected_pwd=${PWD-}
      fi
      _spl_expected_oldpwd_was_set=0
      _spl_expected_oldpwd=
      if [ "${OLDPWD+x}" = x ]; then
        _spl_expected_oldpwd_was_set=1
        _spl_expected_oldpwd=${OLDPWD-}
      fi
      _spl_expected_pwd_physical=$(command pwd -P 2>/dev/null)
      _spl_expected_pwd_status=$?
      _spl_guard_expected_pwd_was_set=$_spl_expected_pwd_was_set
      _spl_guard_expected_pwd=$_spl_expected_pwd
      _spl_guard_expected_oldpwd_was_set=$_spl_expected_oldpwd_was_set
      _spl_guard_expected_oldpwd=$_spl_expected_oldpwd
      _spl_guard_expected_pwd_physical=$_spl_expected_pwd_physical
      _spl_guard_expected_pwd_status=$_spl_expected_pwd_status
      if [ "${IFS+x}" = x ]; then
        _spl_expected_ifs_was_set=1
        _spl_expected_ifs=${IFS-}
      else
        _spl_expected_ifs_was_set=0
        _spl_expected_ifs=
      fi
      case $- in
      *a*) _spl_expected_allexport_was_set=1 ;;
      *) _spl_expected_allexport_was_set=0 ;;
      esac
      case $- in
      *C*) _spl_expected_noclobber_was_set=1 ;;
      *) _spl_expected_noclobber_was_set=0 ;;
      esac
      case $- in
      *e*) _spl_expected_errexit_was_set=1 ;;
      *) _spl_expected_errexit_was_set=0 ;;
      esac
      case $- in
      *f*) _spl_expected_glob_was_set=1 ;;
      *) _spl_expected_glob_was_set=0 ;;
      esac
      case $- in
      *u*) _spl_expected_nounset_was_set=1 ;;
      *) _spl_expected_nounset_was_set=0 ;;
      esac
      case $- in
      *v*) _spl_expected_verbose_was_set=1 ;;
      *) _spl_expected_verbose_was_set=0 ;;
      esac
      case $- in
      *x*) _spl_expected_xtrace_was_set=1 ;;
      *) _spl_expected_xtrace_was_set=0 ;;
      esac
      if [ "$_spl_load_status" -eq 0 ] && [ -n "$_spl_load_hook" ]; then
        if command -v "$_spl_load_hook" >/dev/null 2>&1; then
          _spl_hook_body=$_spl_tmp/hook-body
          : >"$_spl_hook_body"
          case $_spl_current_shell in
          bash) command declare -f "$_spl_load_hook" >"$_spl_hook_body" 2>/dev/null || : ;;
          zsh) functions "$_spl_load_hook" >"$_spl_hook_body" 2>/dev/null || : ;;
          ksh) command typeset -f "$_spl_load_hook" >"$_spl_hook_body" 2>/dev/null || : ;;
          esac
          if [ -s "$_spl_hook_body" ] && ! _sp_loader_reserved_scan "$_spl_hook_body"; then
            command printf 'loader: %s\n' "$_spl_mod: load hook defines reserved shell utility" >&2
            _spl_load_status=126
          else
            "$_spl_load_hook" || _spl_load_status=$?
          fi
        else
          command printf 'loader: %s\n' "$_spl_mod: load hook not found: $_spl_load_hook" >&2
          _spl_load_status=127
        fi
      elif [ "$_spl_load_status" -eq 0 ] && [ -n "$_spl_load" ]; then
        if [ ! -f "$_spl_tmp/roots/$_spl_mod" ]; then
          command printf 'loader: %s\n' "$_spl_mod: providing module root was not recorded during discovery" >&2
          _spl_load_status=126
        else
          _spl_module_root=
          IFS= read -r _spl_module_root <"$_spl_tmp/roots/$_spl_mod" || :
          _spl_load_path=$_spl_module_root/$_spl_load
          if ! _sp_loader_path_is_physical "$_spl_module_root" "$_spl_load_path"; then
            command printf 'loader: %s\n' "$_spl_mod: load path contains a symlink: $_spl_load" >&2
            _spl_load_status=126
            unset _spl_module_root
          else
            unset _spl_module_root
            if [ -r "$_spl_load_path" ]; then
              if ! _sp_loader_reserved_scan "$_spl_load_path"; then
                command printf 'loader: %s\n' "$_spl_mod: load path defines reserved shell utility" >&2
                _spl_load_status=126
              else
                . "$_spl_load_path" || _spl_load_status=$?
              fi
            else
              command printf 'loader: %s\n' "$_spl_mod: load path is not readable: $_spl_load" >&2
              _spl_load_status=126
            fi
          fi
        fi
      fi
      unset -f command builtin 2>/dev/null || :
      case $- in
      *u*)
        _spl_after_nounset_was_set=1
        set +u
        ;;
      *) _spl_after_nounset_was_set=0 ;;
      esac
      _spl_private_modified=0
      if [ "${_spl_expected_tmp-}" != "${_spl_guard_tmp-}" ] || [ "${_spl_expected_cleanup_tmp-}" != "${_spl_guard_cleanup_tmp-}" ] || [ "${_spl_expected_tmp_parent-}" != "${_spl_guard_tmp_parent-}" ] || [ "${_spl_expected_tmp_sentinel-}" != "${_spl_guard_tmp_sentinel-}" ] || [ "${_spl_expected_root-}" != "${_spl_guard_root-}" ] || [ "${_spl_expected_wanted-}" != "${_spl_guard_wanted-}" ] || [ "${_spl_expected_mode-}" != "${_spl_guard_mode-}" ] || [ "${_spl_expected_phase-}" != "${_spl_guard_phase-}" ] || [ "${_spl_expected_return-}" != "${_spl_guard_return-}" ] || [ "${_spl_expected_strict_error-}" != "${_spl_guard_strict_error-}" ] || [ "${_spl_expected_current_shell-}" != "${_spl_guard_current_shell-}" ] || [ "${_spl_expected_current_platform-}" != "${_spl_guard_current_platform-}" ] || [ "${_spl_expected_mod-}" != "${_spl_guard_mod-}" ] || [ "${_spl_expected_record-}" != "${_spl_guard_record-}" ] || [ "${_spl_expected_load-}" != "${_spl_guard_load-}" ] || [ "${_spl_expected_load_hook-}" != "${_spl_guard_load_hook-}" ] || [ "${_spl_expected_exports-}" != "${_spl_guard_exports-}" ] || [ "${_spl_expected_exports_to_cleanup-}" != "${_spl_guard_exports_to_cleanup-}" ] || [ "${_spl_wrapper_exports-}" != "${_spl_guard_wrapper_exports-}" ] || [ "${_spl_seen_words-}" != "${_spl_guard_seen_words-}" ] || [ "${_spl_strict_required_words-}" != "${_spl_guard_strict_required_words-}" ] || [ "${_spl_blocked_words-}" != "${_spl_guard_blocked_words-}" ] || [ "${_spl_modules_words-}" != "${_spl_guard_modules_words-}" ] || [ "${_spl_order_words-}" != "${_spl_guard_order_words-}" ] || [ "${_spl_failed_words-}" != "${_spl_guard_failed_words-}" ] || [ "${_spl_expected_pwd_was_set-}" != "${_spl_guard_expected_pwd_was_set-}" ] || [ "${_spl_expected_pwd-}" != "${_spl_guard_expected_pwd-}" ] || [ "${_spl_expected_oldpwd_was_set-}" != "${_spl_guard_expected_oldpwd_was_set-}" ] || [ "${_spl_expected_oldpwd-}" != "${_spl_guard_expected_oldpwd-}" ] || [ "${_spl_expected_pwd_physical-}" != "${_spl_guard_expected_pwd_physical-}" ] || [ "${_spl_expected_pwd_status-}" != "${_spl_guard_expected_pwd_status-}" ] || [ "${_spl_expected_search_path-}" != "${_spl_guard_search_path-}" ] || [ "${_spl_expected_meta_file-}" != "${_spl_guard_meta_file-}" ] || [ "${_spl_expected_meta_root-}" != "${_spl_guard_meta_root-}" ] || [ "${_spl_expected_layer-}" != "${_spl_guard_layer-}" ] || [ "${_spl_expected_dep_exists-}" != "${_spl_guard_dep_exists-}" ]; then
        _spl_private_modified=1
        _spl_expected_tmp=$_spl_guard_tmp
        _spl_expected_cleanup_tmp=$_spl_guard_cleanup_tmp
        _spl_expected_tmp_parent=$_spl_guard_tmp_parent
        _spl_expected_tmp_sentinel=$_spl_guard_tmp_sentinel
        _spl_expected_root=$_spl_guard_root
        _spl_expected_wanted=$_spl_guard_wanted
        _spl_expected_search_path=$_spl_guard_search_path
        _spl_expected_meta_file=$_spl_guard_meta_file
        _spl_expected_meta_root=$_spl_guard_meta_root
        _spl_expected_layer=$_spl_guard_layer
        _spl_expected_dep_exists=$_spl_guard_dep_exists
        _spl_expected_mode=$_spl_guard_mode
        _spl_expected_phase=$_spl_guard_phase
        _spl_expected_return=$_spl_guard_return
        _spl_expected_strict_error=$_spl_guard_strict_error
        _spl_expected_current_shell=$_spl_guard_current_shell
        _spl_expected_current_platform=$_spl_guard_current_platform
        _spl_expected_mod=$_spl_guard_mod
        _spl_expected_record=$_spl_guard_record
        _spl_expected_load=$_spl_guard_load
        _spl_expected_load_hook=$_spl_guard_load_hook
        _spl_expected_exports=$_spl_guard_exports
        _spl_expected_exports_to_cleanup=$_spl_guard_exports_to_cleanup
        _spl_wrapper_exports=$_spl_guard_wrapper_exports
        _spl_seen_words=$_spl_guard_seen_words
        _spl_strict_required_words=$_spl_guard_strict_required_words
        _spl_blocked_words=$_spl_guard_blocked_words
        _spl_modules_words=$_spl_guard_modules_words
        _spl_order_words=$_spl_guard_order_words
        _spl_failed_words=$_spl_guard_failed_words
        _spl_expected_pwd_was_set=$_spl_guard_expected_pwd_was_set
        _spl_expected_pwd=$_spl_guard_expected_pwd
        _spl_expected_oldpwd_was_set=$_spl_guard_expected_oldpwd_was_set
        _spl_expected_oldpwd=$_spl_guard_expected_oldpwd
        _spl_expected_pwd_physical=$_spl_guard_expected_pwd_physical
        _spl_expected_pwd_status=$_spl_guard_expected_pwd_status
      fi
      if [ "$_spl_tmp" != "$_spl_expected_tmp" ] || [ "$_spl_cleanup_tmp" != "$_spl_expected_cleanup_tmp" ] || [ "$_spl_tmp_parent" != "$_spl_expected_tmp_parent" ] || [ "$_spl_tmp_sentinel" != "$_spl_expected_tmp_sentinel" ] || [ "$_spl_root" != "$_spl_expected_root" ] || [ "$_spl_wanted" != "$_spl_expected_wanted" ] || [ "$_spl_mode" != "$_spl_expected_mode" ] || [ "$_spl_phase" != "$_spl_expected_phase" ] || [ "$_spl_return" != "$_spl_expected_return" ] || [ "$_spl_strict_error" != "$_spl_expected_strict_error" ] || [ "$_spl_current_shell" != "$_spl_expected_current_shell" ] || [ "$_spl_current_platform" != "$_spl_expected_current_platform" ] || [ "$_spl_mod" != "$_spl_expected_mod" ] || [ "$_spl_record" != "$_spl_expected_record" ] || [ "$_spl_load" != "$_spl_expected_load" ] || [ "$_spl_load_hook" != "$_spl_expected_load_hook" ] || [ "$_spl_exports" != "$_spl_expected_exports" ] || [ "$_spl_exports_to_cleanup" != "$_spl_expected_exports_to_cleanup" ] || [ "${_spl_search_path-}" != "${_spl_expected_search_path-}" ] || [ "${_spl_meta_file-}" != "${_spl_expected_meta_file-}" ] || [ "${_spl_meta_root-}" != "${_spl_expected_meta_root-}" ] || [ "${_spl_layer-}" != "${_spl_expected_layer-}" ] || [ "${_spl_dep_exists-}" != "${_spl_expected_dep_exists-}" ]; then
        _spl_private_modified=1
        _spl_tmp=$_spl_expected_tmp
        _spl_cleanup_tmp=$_spl_expected_cleanup_tmp
        _spl_tmp_parent=$_spl_expected_tmp_parent
        _spl_tmp_sentinel=$_spl_expected_tmp_sentinel
        _spl_root=$_spl_expected_root
        _spl_search_path=$_spl_expected_search_path
        _spl_meta_file=$_spl_expected_meta_file
        _spl_meta_root=$_spl_expected_meta_root
        _spl_layer=$_spl_expected_layer
        _spl_dep_exists=$_spl_expected_dep_exists
        _spl_wanted=$_spl_expected_wanted
        _spl_mode=$_spl_expected_mode
        _spl_phase=$_spl_expected_phase
        _spl_return=$_spl_expected_return
        _spl_strict_error=$_spl_expected_strict_error
        _spl_current_shell=$_spl_expected_current_shell
        _spl_current_platform=$_spl_expected_current_platform
        _spl_mod=$_spl_expected_mod
        _spl_record=$_spl_expected_record
        _spl_load=$_spl_expected_load
        _spl_load_hook=$_spl_expected_load_hook
        _spl_exports=$_spl_expected_exports
        _spl_exports_to_cleanup=$_spl_expected_exports_to_cleanup
      fi
      _spl_shell_state_modified=0
      _spl_after_pwd_physical=$(command pwd -P 2>/dev/null)
      _spl_after_pwd_physical_status=$?
      if [ "$_spl_expected_pwd_status" -eq 0 ]; then
        if [ "$_spl_after_pwd_physical_status" -ne 0 ] || [ "$_spl_after_pwd_physical" != "$_spl_expected_pwd_physical" ]; then
          _spl_shell_state_modified=1
        fi
      fi
      # A module may change directory and come back; that leaves the physical
      # cwd intact and only moves the logical PWD and OLDPWD, which are restored
      # below. The logical values are evidence of a move only when the physical
      # cwd could not be read before the module ran.
      if [ "$_spl_expected_pwd_status" -ne 0 ]; then
        if [ "${PWD+x}" = x ]; then
          _spl_after_pwd_was_set=1
        else
          _spl_after_pwd_was_set=0
        fi
        if [ "$_spl_after_pwd_was_set" -ne "$_spl_expected_pwd_was_set" ]; then
          _spl_shell_state_modified=1
        elif [ "$_spl_expected_pwd_was_set" -eq 1 ] && [ "${PWD-}" != "$_spl_expected_pwd" ]; then
          _spl_shell_state_modified=1
        fi
        if [ "${OLDPWD+x}" = x ]; then
          _spl_after_oldpwd_was_set=1
        else
          _spl_after_oldpwd_was_set=0
        fi
        if [ "$_spl_after_oldpwd_was_set" -ne "$_spl_expected_oldpwd_was_set" ]; then
          _spl_shell_state_modified=1
        elif [ "$_spl_expected_oldpwd_was_set" -eq 1 ] && [ "${OLDPWD-}" != "$_spl_expected_oldpwd" ]; then
          _spl_shell_state_modified=1
        fi
      fi
      _spl_pwd_cwd_restored=1
      if [ "$_spl_expected_pwd_status" -eq 0 ]; then
        if [ "$_spl_after_pwd_physical_status" -ne 0 ] || [ "$_spl_after_pwd_physical" != "$_spl_expected_pwd_physical" ]; then
          _spl_cwd_restore_attempt=0
          if [ "$_spl_current_shell" = zsh ]; then
            if (\builtin cd . >/dev/null 2>&1); then
              CDPATH= \builtin cd "$_spl_expected_pwd_physical" 2>/dev/null && _spl_cwd_restore_attempt=1
            fi
          else
            CDPATH= command cd "$_spl_expected_pwd_physical" 2>/dev/null && _spl_cwd_restore_attempt=1
          fi
          _spl_restored_pwd_physical=$(command pwd -P 2>/dev/null)
          _spl_restored_pwd_status=$?
          if [ "$_spl_cwd_restore_attempt" -eq 0 ] || [ "$_spl_restored_pwd_status" -ne 0 ] || [ "$_spl_restored_pwd_physical" != "$_spl_expected_pwd_physical" ]; then
            _spl_cwd_restore_attempt=0
            if [ "$_spl_current_shell" != zsh ] && (\builtin cd . >/dev/null 2>&1); then
              CDPATH= \builtin cd "$_spl_expected_pwd_physical" 2>/dev/null && _spl_cwd_restore_attempt=1
            fi
            _spl_restored_pwd_physical=$(command pwd -P 2>/dev/null)
            _spl_restored_pwd_status=$?
          fi
          if [ "$_spl_cwd_restore_attempt" -eq 0 ] || [ "$_spl_restored_pwd_status" -ne 0 ] || [ "$_spl_restored_pwd_physical" != "$_spl_expected_pwd_physical" ]; then
            _spl_shell_state_modified=1
            _spl_pwd_cwd_restored=0
          fi
        fi
      else
        _spl_pwd_cwd_restored=0
      fi
      if [ "$_spl_pwd_cwd_restored" -eq 1 ]; then
        if [ "$_spl_expected_pwd_was_set" -eq 1 ]; then
          PWD=$_spl_expected_pwd
        else
          unset PWD
        fi
        if [ "$_spl_expected_oldpwd_was_set" -eq 1 ]; then
          OLDPWD=$_spl_expected_oldpwd
        else
          unset OLDPWD
        fi
      fi
      if [ "${IFS+x}" = x ]; then
        _spl_after_ifs_was_set=1
      else
        _spl_after_ifs_was_set=0
      fi
      if [ "$_spl_after_ifs_was_set" -ne "$_spl_expected_ifs_was_set" ]; then
        _spl_shell_state_modified=1
      elif [ "$_spl_expected_ifs_was_set" -eq 1 ] && [ "${IFS-}" != "$_spl_expected_ifs" ]; then
        _spl_shell_state_modified=1
      fi
      if [ "$_spl_expected_ifs_was_set" -eq 1 ]; then
        IFS=$_spl_expected_ifs
      else
        unset IFS
      fi
      case $- in *a*) _spl_after_allexport_was_set=1 ;; *) _spl_after_allexport_was_set=0 ;; esac
      case $- in *C*) _spl_after_noclobber_was_set=1 ;; *) _spl_after_noclobber_was_set=0 ;; esac
      case $- in *e*) _spl_after_errexit_was_set=1 ;; *) _spl_after_errexit_was_set=0 ;; esac
      case $- in *f*) _spl_after_glob_was_set=1 ;; *) _spl_after_glob_was_set=0 ;; esac
      case $- in *v*) _spl_after_verbose_was_set=1 ;; *) _spl_after_verbose_was_set=0 ;; esac
      case $- in *x*) _spl_after_xtrace_was_set=1 ;; *) _spl_after_xtrace_was_set=0 ;; esac
      if [ "$_spl_after_allexport_was_set" -ne "$_spl_expected_allexport_was_set" ] || [ "$_spl_after_noclobber_was_set" -ne "$_spl_expected_noclobber_was_set" ] || [ "$_spl_after_errexit_was_set" -ne "$_spl_expected_errexit_was_set" ] || [ "$_spl_after_nounset_was_set" -ne "$_spl_expected_nounset_was_set" ] || [ "$_spl_after_verbose_was_set" -ne "$_spl_expected_verbose_was_set" ] || [ "$_spl_after_xtrace_was_set" -ne "$_spl_expected_xtrace_was_set" ]; then
        _spl_shell_state_modified=1
      fi
      if [ "$_spl_after_glob_was_set" -ne "$_spl_expected_glob_was_set" ]; then
        _spl_shell_state_modified=1
      fi
      if [ "$_spl_expected_allexport_was_set" -eq 1 ]; then set -a; else set +a; fi
      if [ "$_spl_expected_noclobber_was_set" -eq 1 ]; then set -C; else set +C; fi
      if [ "$_spl_expected_errexit_was_set" -eq 1 ]; then set -e; else set +e; fi
      if [ "$_spl_expected_glob_was_set" -eq 1 ]; then
        set -f
      else
        set +f
      fi
      if [ "$_spl_expected_nounset_was_set" -eq 1 ]; then set -u; else set +u; fi
      if [ "$_spl_expected_verbose_was_set" -eq 1 ]; then set -v; else set +v; fi
      if [ "$_spl_expected_xtrace_was_set" -eq 1 ]; then set -x; else set +x; fi
      if [ "$_spl_private_modified" -ne 0 ]; then
        command printf 'loader: %s\n' "$_spl_expected_mod: loader private namespace modified" >&2
        _spl_load_status=1
      fi
      if [ "$_spl_shell_state_modified" -ne 0 ]; then
        command printf 'loader: %s\n' "$_spl_expected_mod: caller shell state modified" >&2
        _spl_load_status=1
      fi
      if [ "$_spl_load_status" -eq 0 ]; then
        if [ "${IFS+x}" = x ]; then
          _spl_export_ifs_was_set=1
          _spl_export_old_ifs=${IFS-}
        else
          _spl_export_ifs_was_set=0
          _spl_export_old_ifs=
        fi
        IFS=' '
        for _spl_export in $_spl_exports; do
          if ! _spl_export_lookup=$(command -v "$_spl_export" 2>/dev/null); then
            command printf 'loader: %s\n' "$_spl_mod: declared export missing: $_spl_export" >&2
            _spl_load_status=1
          else
            case " $_spl_wrapper_exports " in
            *" $_spl_export "*)
              case $_spl_export_lookup in
              */*)
                command printf 'loader: %s\n' "$_spl_mod: declared export was not provided by module: $_spl_export" >&2
                _spl_load_status=1
                ;;
              esac
              ;;
            esac
          fi
        done
        if [ "$_spl_export_ifs_was_set" -eq 1 ]; then
          IFS=$_spl_export_old_ifs
        else
          unset IFS
        fi
      fi
      if [ "$_spl_load_status" -ne 0 ]; then
        if [ "${IFS+x}" = x ]; then
          _spl_export_ifs_was_set=1
          _spl_export_old_ifs=${IFS-}
        else
          _spl_export_ifs_was_set=0
          _spl_export_old_ifs=
        fi
        IFS=' '
        for _spl_export in $_spl_exports_to_cleanup; do
          unset -f "$_spl_export" 2>/dev/null || :
        done
        if [ "$_spl_export_ifs_was_set" -eq 1 ]; then
          IFS=$_spl_export_old_ifs
        else
          unset IFS
        fi
        command printf 'loader: %s\n' "$_spl_mod: load failed with status $_spl_load_status" >&2
        command printf '%s\n' "$_spl_mod" >>"$_spl_tmp/failed"
        _spl_failed_words="$_spl_failed_words $_spl_mod"
        if [ "$_spl_mode" = strict ]; then
          case " $_spl_strict_required_words " in
          *" $_spl_mod "*)
            _spl_return=1
            break
            ;;
          esac
        fi
      fi
    done <"$_spl_tmp/order"
  fi

  if [ -n "${_spl_cleanup_tmp:-}" ]; then
    case $_spl_cleanup_tmp in
    "$_spl_tmp_parent"/shell-profile-loader.*)
      if [ -f "$_spl_cleanup_tmp/.shell-profile-loader-owned" ]; then
        command rm -rf "$_spl_cleanup_tmp" 2>/dev/null || :
      fi
      ;;
    esac
  fi
  if [ "$_spl_return" -eq 0 ]; then
    unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_strict_error _spl_return \
      _spl_current_shell _spl_uname _spl_current_platform \
      _spl_tmp_parent _spl_tmp _spl_cleanup_tmp _spl_tmp_sentinel \
      _spl_expected_tmp _spl_expected_cleanup_tmp _spl_expected_tmp_parent _spl_expected_tmp_sentinel \
      _spl_expected_root _spl_expected_wanted _spl_expected_mode _spl_expected_phase \
      _spl_expected_search_path _spl_expected_meta_file _spl_expected_meta_root _spl_expected_layer _spl_expected_dep_exists \
      _spl_expected_return _spl_expected_strict_error _spl_expected_current_shell _spl_expected_current_platform \
      _spl_expected_mod _spl_expected_record _spl_expected_load _spl_expected_load_hook \
      _spl_expected_exports _spl_expected_exports_to_cleanup \
      _spl_guard_tmp _spl_guard_cleanup_tmp _spl_guard_tmp_parent _spl_guard_tmp_sentinel \
      _spl_guard_root _spl_guard_wanted _spl_guard_mode _spl_guard_phase \
      _spl_guard_search_path _spl_guard_meta_file _spl_guard_meta_root _spl_guard_layer _spl_guard_dep_exists \
      _spl_guard_return _spl_guard_strict_error _spl_guard_current_shell _spl_guard_current_platform \
      _spl_guard_mod _spl_guard_record _spl_guard_load _spl_guard_load_hook \
      _spl_guard_exports _spl_guard_exports_to_cleanup _spl_guard_wrapper_exports \
      _spl_guard_expected_pwd_was_set _spl_guard_expected_pwd \
      _spl_guard_expected_oldpwd_was_set _spl_guard_expected_oldpwd \
      _spl_guard_expected_pwd_physical _spl_guard_expected_pwd_status \
      _spl_expected_pwd _spl_expected_pwd_status _spl_expected_pwd_physical _spl_expected_pwd_was_set \
      _spl_expected_oldpwd _spl_expected_oldpwd_was_set _spl_after_pwd_physical _spl_after_pwd_physical_status \
      _spl_after_pwd_was_set _spl_after_oldpwd_was_set _spl_pwd_cwd_restored \
    _spl_cwd_restore_attempt _spl_restored_pwd_physical _spl_restored_pwd_status \
    _spl_expected_ifs_was_set _spl_expected_ifs _spl_after_ifs_was_set \
      _spl_expected_allexport_was_set _spl_expected_noclobber_was_set _spl_expected_errexit_was_set \
      _spl_expected_glob_was_set _spl_expected_nounset_was_set _spl_expected_verbose_was_set _spl_expected_xtrace_was_set \
      _spl_after_allexport_was_set _spl_after_noclobber_was_set _spl_after_errexit_was_set \
      _spl_after_glob_was_set _spl_after_nounset_was_set _spl_after_verbose_was_set _spl_after_xtrace_was_set \
      _spl_private_modified _spl_shell_state_modified \
      _spl_word _spl_ifs_was_set _spl_old_ifs _spl_glob_was_set _spl_mod _spl_meta_file \
      _spl_record _spl_record_name _spl_side_effect _spl_shells _spl_platforms \
      _spl_shell_match _spl_platform_match _spl_match_ifs_was_set _spl_match_old_ifs \
      _spl_value _spl_requires _spl_optional \
      _spl_dep_ifs_was_set _spl_dep_old_ifs _spl_dep _spl_progress _spl_ready \
      _spl_blocked_by _spl_topo_ifs_was_set _spl_topo_old_ifs _spl_runtime_skip \
      _spl_run_ifs_was_set _spl_run_old_ifs _spl_load _spl_load_hook \
      _spl_exports _spl_exports_to_cleanup _spl_wrapper_exports _spl_export_ifs_was_set _spl_export_old_ifs _spl_export \
      _spl_export_lookup _spl_export_conflict _spl_reload_ifs_was_set _spl_reload_old_ifs \
      _spl_load_status _spl_load_path _spl_hook_body \
      _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_layer_glob_was_set
    unset _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words \
      _spl_order_words _spl_failed_words _spl_guard_seen_words _spl_guard_strict_required_words \
      _spl_guard_blocked_words _spl_guard_modules_words _spl_guard_order_words _spl_guard_failed_words \
      _spl_record_name _spl_record_requires _spl_record_optional _spl_record_shells \
      _spl_record_platforms _spl_record_side_effect _spl_record_exports _spl_record_updates \
      _spl_record_version _spl_record_load _spl_record_load_hook _spl_run_line _spl_module_root
    unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
    return 0
  fi
  unset _spl_root _spl_wanted _spl_mode _spl_phase _spl_strict_error _spl_return \
    _spl_current_shell _spl_uname _spl_current_platform \
    _spl_tmp_parent _spl_tmp _spl_cleanup_tmp _spl_tmp_sentinel \
    _spl_expected_tmp _spl_expected_cleanup_tmp _spl_expected_tmp_parent _spl_expected_tmp_sentinel \
    _spl_expected_root _spl_expected_wanted _spl_expected_mode _spl_expected_phase \
      _spl_expected_search_path _spl_expected_meta_file _spl_expected_meta_root _spl_expected_layer _spl_expected_dep_exists \
    _spl_expected_return _spl_expected_strict_error _spl_expected_current_shell _spl_expected_current_platform \
    _spl_expected_mod _spl_expected_record _spl_expected_load _spl_expected_load_hook \
    _spl_expected_exports _spl_expected_exports_to_cleanup \
    _spl_guard_tmp _spl_guard_cleanup_tmp _spl_guard_tmp_parent _spl_guard_tmp_sentinel \
    _spl_guard_root _spl_guard_wanted _spl_guard_mode _spl_guard_phase \
      _spl_guard_search_path _spl_guard_meta_file _spl_guard_meta_root _spl_guard_layer _spl_guard_dep_exists \
    _spl_guard_return _spl_guard_strict_error _spl_guard_current_shell _spl_guard_current_platform \
    _spl_guard_mod _spl_guard_record _spl_guard_load _spl_guard_load_hook \
    _spl_guard_exports _spl_guard_exports_to_cleanup _spl_guard_wrapper_exports \
    _spl_guard_expected_pwd_was_set _spl_guard_expected_pwd \
    _spl_guard_expected_oldpwd_was_set _spl_guard_expected_oldpwd \
    _spl_guard_expected_pwd_physical _spl_guard_expected_pwd_status \
    _spl_expected_pwd _spl_expected_pwd_status _spl_expected_pwd_physical _spl_expected_pwd_was_set \
      _spl_expected_oldpwd _spl_expected_oldpwd_was_set _spl_after_pwd_physical _spl_after_pwd_physical_status \
      _spl_after_pwd_was_set _spl_after_oldpwd_was_set _spl_pwd_cwd_restored \
    _spl_cwd_restore_attempt _spl_restored_pwd_physical _spl_restored_pwd_status \
    _spl_expected_ifs_was_set _spl_expected_ifs _spl_after_ifs_was_set \
    _spl_expected_allexport_was_set _spl_expected_noclobber_was_set _spl_expected_errexit_was_set \
    _spl_expected_glob_was_set _spl_expected_nounset_was_set _spl_expected_verbose_was_set _spl_expected_xtrace_was_set \
    _spl_after_allexport_was_set _spl_after_noclobber_was_set _spl_after_errexit_was_set \
    _spl_after_glob_was_set _spl_after_nounset_was_set _spl_after_verbose_was_set _spl_after_xtrace_was_set \
    _spl_private_modified _spl_shell_state_modified \
    _spl_word _spl_ifs_was_set _spl_old_ifs _spl_glob_was_set _spl_mod _spl_meta_file \
    _spl_record _spl_record_name _spl_side_effect _spl_shells _spl_platforms \
    _spl_shell_match _spl_platform_match _spl_match_ifs_was_set _spl_match_old_ifs \
    _spl_value _spl_requires _spl_optional \
    _spl_dep_ifs_was_set _spl_dep_old_ifs _spl_dep _spl_progress _spl_ready \
    _spl_blocked_by _spl_topo_ifs_was_set _spl_topo_old_ifs _spl_runtime_skip \
    _spl_run_ifs_was_set _spl_run_old_ifs _spl_load _spl_load_hook \
    _spl_exports _spl_exports_to_cleanup _spl_wrapper_exports _spl_export_ifs_was_set _spl_export_old_ifs _spl_export \
      _spl_export_lookup _spl_export_conflict _spl_reload_ifs_was_set _spl_reload_old_ifs \
    _spl_load_status _spl_load_path _spl_hook_body \
      _spl_search_path _spl_layer _spl_meta_file _spl_meta_root _spl_dep_exists _spl_existing_load _spl_layer_load _spl_conflict _spl_layer_ifs_was_set _spl_layer_old_ifs _spl_existing_version _spl_layer_version _spl_existing_version_display _spl_layer_version_display _spl_layer_glob_was_set
  unset _spl_seen_words _spl_strict_required_words _spl_blocked_words _spl_modules_words \
    _spl_order_words _spl_failed_words _spl_guard_seen_words _spl_guard_strict_required_words \
    _spl_guard_blocked_words _spl_guard_modules_words _spl_guard_order_words _spl_guard_failed_words \
    _spl_record_name _spl_record_requires _spl_record_optional _spl_record_shells \
    _spl_record_platforms _spl_record_side_effect _spl_record_exports _spl_record_updates \
    _spl_record_version _spl_record_load _spl_record_load_hook _spl_run_line _spl_module_root
  unset -f _sp_loader_path_is_physical _sp_loader_read_record _sp_loader_reserved_scan 2>/dev/null || :
  return 1
}
