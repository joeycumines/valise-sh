#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Portable platform capability helpers for shell-profile modules.

sp_cap_error() {
  sp_cap_print_line "capability: $*" >&2
}

sp_cap_print_line() {
  [ "$#" -eq 1 ] || return 1
  if [ -x /usr/bin/printf ]; then
    /usr/bin/printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

sp_cap_physical_dir() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in
  /*) ;;
  *) return 1 ;;
  esac
  [ -d "$1" ] || return 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      CDPATH=
      cd "$1" 2>/dev/null || exit 1
      pwd -P
    ' sh "$1"
  else
    (
      unset -f command cd pwd 2>/dev/null || :
      CDPATH=
      cd "$1" 2>/dev/null && pwd -P
    )
  fi
}

sp_cap_trusted_mktemp_dir() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      umask 077 || exit 1
      command -p mktemp -d "$1"
    ' sh "$1"
  else
    (
      unset -f command mktemp 2>/dev/null || :
      umask 077 || exit 1
      command -p mktemp -d "$1"
    )
  fi
}

sp_cap_trusted_mktemp_file() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      umask 077 || exit 1
      command -p mktemp "$1"
    ' sh "$1"
  else
    (
      unset -f command mktemp 2>/dev/null || :
      umask 077 || exit 1
      command -p mktemp "$1"
    )
  fi
}

sp_cap_group_other_access_paths() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      command -p find "$1" -prune \( \
        -perm -040 -o -perm -020 -o -perm -010 -o \
        -perm -004 -o -perm -002 -o -perm -001 \
      \) -print
    ' sh "$1"
  else
    (
      unset -f command find 2>/dev/null || :
      command -p find "$1" -prune \( \
        -perm -040 -o -perm -020 -o -perm -010 -o \
        -perm -004 -o -perm -002 -o -perm -001 \
      \) -print
    )
  fi
}

sp_cap_remove_tree() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      command -p rm -rf "$1"
    ' sh "$1"
  else
    (
      unset -f command rm 2>/dev/null || :
      command -p rm -rf "$1"
    )
  fi
}

sp_cap_positive_integer() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in
  '' | *[!0123456789]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

sp_cap_unsigned_integer() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in
  '' | *[!0123456789]*) return 1 ;;
  esac
  return 0
}

sp_cap_os() {
  _spc_uname=$(command uname -s 2>/dev/null || command printf '%s\n' unknown)
  case "$_spc_uname" in
  Darwin) _spc_os=darwin ;;
  Linux) _spc_os=linux ;;
  FreeBSD) _spc_os=freebsd ;;
  OpenBSD) _spc_os=openbsd ;;
  NetBSD) _spc_os=netbsd ;;
  *BSD) _spc_os=bsd ;;
  *) _spc_os=unknown ;;
  esac
  command printf '%s\n' "$_spc_os"
  unset _spc_uname _spc_os
}

sp_cap_command_exists() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in */* | -*) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}

sp_cap_command_path() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in */* | -*) return 1 ;; esac
  _spc_command_path=$(command -v "$1" 2>/dev/null) || {
    unset _spc_command_path
    return 1
  }
  case "$_spc_command_path" in
  */*)
    [ -x "$_spc_command_path" ] && [ ! -d "$_spc_command_path" ] || {
      unset _spc_command_path
      return 1
    }
    command printf '%s\n' "$_spc_command_path"
    unset _spc_command_path
    return 0
    ;;
  *)
    unset _spc_command_path
    return 1
    ;;
  esac
}

sp_cap_cpu_count() {
  _spc_count=
  if sp_cap_command_exists getconf; then
    _spc_count=$(command getconf _NPROCESSORS_ONLN 2>/dev/null) || _spc_count=
    if sp_cap_positive_integer "$_spc_count"; then
      command printf '%s\n' "$_spc_count"
      unset _spc_count
      return 0
    fi
  fi
  if sp_cap_command_exists sysctl; then
    _spc_count=$(command sysctl -n hw.ncpu 2>/dev/null) || _spc_count=
    if sp_cap_positive_integer "$_spc_count"; then
      command printf '%s\n' "$_spc_count"
      unset _spc_count
      return 0
    fi
  fi
  if sp_cap_command_exists nproc; then
    _spc_count=$(command nproc 2>/dev/null) || _spc_count=
    if sp_cap_positive_integer "$_spc_count"; then
      command printf '%s\n' "$_spc_count"
      unset _spc_count
      return 0
    fi
  fi
  unset _spc_count
  command printf '%s\n' 1
}

sp_cap_file_mtime() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  [ -e "$1" ] || return 1
  _spc_mtime=$(command stat -c %Y "$1" 2>/dev/null) || _spc_mtime=
  if sp_cap_unsigned_integer "$_spc_mtime"; then
    command printf '%s\n' "$_spc_mtime"
    unset _spc_mtime
    return 0
  fi
  _spc_mtime=$(command stat -f %m "$1" 2>/dev/null) || _spc_mtime=
  if sp_cap_unsigned_integer "$_spc_mtime"; then
    command printf '%s\n' "$_spc_mtime"
    unset _spc_mtime
    return 0
  fi
  unset _spc_mtime
  return 1
}

sp_cap_mktemp_dir() {
  [ "$#" -le 2 ] || {
    sp_cap_error 'usage: sp_cap_mktemp_dir [prefix] [parent]'
    return 1
  }
  _spc_prefix=${1:-shell-profile}
  _spc_parent=${2:-${TMPDIR:-/tmp}}
  case "$_spc_prefix" in
  '' | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-]* | *'/'*)
    sp_cap_error "invalid temp prefix: $_spc_prefix"
    unset _spc_prefix _spc_parent
    return 1
    ;;
  esac
  case "$_spc_parent" in
  /*) ;;
  *)
    sp_cap_error 'temporary parent must be absolute'
    unset _spc_prefix _spc_parent
    return 1
    ;;
  esac
  [ -d "$_spc_parent" ] || {
    sp_cap_error "temporary parent is not a real directory: $_spc_parent"
    unset _spc_prefix _spc_parent
    return 1
  }
  _spc_parent_real=$(sp_cap_physical_dir "$_spc_parent") || {
    sp_cap_error "temporary parent cannot be canonicalized: $_spc_parent"
    unset _spc_prefix _spc_parent _spc_parent_real
    return 1
  }
  case "$_spc_parent_real" in
  /*) ;;
  *)
    sp_cap_error "temporary parent canonical path is not absolute: $_spc_parent"
    unset _spc_prefix _spc_parent _spc_parent_real
    return 1
    ;;
  esac
  _spc_parent_dir=${_spc_parent_real%/}
  [ -n "$_spc_parent_dir" ] || _spc_parent_dir=/
  if [ "$_spc_parent_dir" = / ]; then
    _spc_template="/$_spc_prefix.XXXXXX"
    _spc_prefix_path="/$_spc_prefix."
  else
    _spc_template="$_spc_parent_dir/$_spc_prefix.XXXXXX"
    _spc_prefix_path="$_spc_parent_dir/$_spc_prefix."
  fi
  _spc_tmp=$(sp_cap_trusted_mktemp_dir "$_spc_template" 2>/dev/null)
  _spc_status=$?
  if [ "$_spc_status" -ne 0 ] || [ -z "$_spc_tmp" ] || [ ! -d "$_spc_tmp" ] || [ -L "$_spc_tmp" ]; then
    sp_cap_error 'failed to create secure temporary directory'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status
    return 1
  fi
  case "$_spc_tmp" in
  "$_spc_prefix_path"*) ;;
  *)
    sp_cap_error 'temporary directory escaped requested parent or prefix'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status
    return 1
    ;;
  esac
  _spc_tmp_real=$(sp_cap_physical_dir "$_spc_tmp") || {
    sp_cap_error 'temporary directory cannot be canonicalized'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status _spc_tmp_real
    return 1
  }
  case "$_spc_tmp_real" in
  "$_spc_prefix_path"*) ;;
  *)
    sp_cap_error 'temporary directory canonical path escaped requested parent or prefix'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status _spc_tmp_real
    return 1
    ;;
  esac
  _spc_tmp_bad_perms=$(sp_cap_group_other_access_paths "$_spc_tmp" 2>/dev/null) || {
    sp_cap_error 'failed to inspect temporary directory permissions'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
    return 1
  }
  if [ -n "$_spc_tmp_bad_perms" ]; then
    sp_cap_error 'temporary directory is externally accessible'
    unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
    return 1
  fi
  sp_cap_print_line "$_spc_tmp"
  unset _spc_prefix _spc_parent _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_old_umask _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
  return 0
}

sp_cap_mktemp_file() {
  [ "$#" -eq 2 ] || {
    sp_cap_error 'usage: sp_cap_mktemp_file <parent> <prefix>'
    return 1
  }
  _spc_parent=$1
  _spc_prefix=$2
  case "$_spc_parent" in
  /*) ;;
  *)
    sp_cap_error 'temporary file parent must be absolute'
    unset _spc_parent _spc_prefix
    return 1
    ;;
  esac
  case "$_spc_prefix" in
  '' | . | .. | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-]* | *'/'*)
    sp_cap_error "invalid temp file prefix: $_spc_prefix"
    unset _spc_parent _spc_prefix
    return 1
    ;;
  esac
  [ -d "$_spc_parent" ] || {
    sp_cap_error "temporary file parent is not a real directory: $_spc_parent"
    unset _spc_parent _spc_prefix
    return 1
  }
  _spc_parent_real=$(sp_cap_physical_dir "$_spc_parent") || {
    sp_cap_error "temporary file parent cannot be canonicalized: $_spc_parent"
    unset _spc_parent _spc_prefix _spc_parent_real
    return 1
  }
  case "$_spc_parent_real" in
  /*) ;;
  *)
    sp_cap_error "temporary file parent canonical path is not absolute: $_spc_parent"
    unset _spc_parent _spc_prefix _spc_parent_real
    return 1
    ;;
  esac
  _spc_parent_dir=${_spc_parent_real%/}
  [ -n "$_spc_parent_dir" ] || _spc_parent_dir=/
  if [ "$_spc_parent_dir" = / ]; then
    _spc_template="/.$_spc_prefix.XXXXXX"
    _spc_prefix_path="/.$_spc_prefix."
  else
    _spc_template="$_spc_parent_dir/.$_spc_prefix.XXXXXX"
    _spc_prefix_path="$_spc_parent_dir/.$_spc_prefix."
  fi
  _spc_tmp=$(sp_cap_trusted_mktemp_file "$_spc_template" 2>/dev/null)
  _spc_status=$?
  if [ "$_spc_status" -ne 0 ] || [ -z "$_spc_tmp" ]; then
    sp_cap_error 'failed to create secure temporary file'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status
    return 1
  fi
  case "$_spc_tmp" in
  "$_spc_prefix_path"*) ;;
  *)
    sp_cap_error 'temporary file escaped requested parent or prefix'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status
    return 1
    ;;
  esac
  if [ ! -f "$_spc_tmp" ] || [ -L "$_spc_tmp" ]; then
    sp_cap_remove_tree "$_spc_tmp" 2>/dev/null || :
    sp_cap_error 'temporary file is not a safe regular file'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status
    return 1
  fi
  _spc_tmp_real=$(sp_cap_canonical_path "$_spc_tmp") || {
    sp_cap_remove_tree "$_spc_tmp" 2>/dev/null || :
    sp_cap_error 'temporary file cannot be canonicalized'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status _spc_tmp_real
    return 1
  }
  case "$_spc_tmp_real" in
  "$_spc_prefix_path"*) ;;
  *)
    sp_cap_remove_tree "$_spc_tmp" 2>/dev/null || :
    sp_cap_error 'temporary file canonical path escaped requested parent or prefix'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status _spc_tmp_real
    return 1
    ;;
  esac
  _spc_tmp_bad_perms=$(sp_cap_group_other_access_paths "$_spc_tmp" 2>/dev/null) || {
    sp_cap_remove_tree "$_spc_tmp" 2>/dev/null || :
    sp_cap_error 'failed to inspect temporary file permissions'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
    return 1
  }
  if [ -n "$_spc_tmp_bad_perms" ]; then
    sp_cap_remove_tree "$_spc_tmp" 2>/dev/null || :
    sp_cap_error 'temporary file is externally accessible'
    unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
    return 1
  fi
  sp_cap_print_line "$_spc_tmp"
  unset _spc_parent _spc_prefix _spc_parent_real _spc_parent_dir _spc_template _spc_prefix_path _spc_tmp _spc_status _spc_tmp_real _spc_tmp_bad_perms
  return 0
}

sp_cap_canonical_path() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  _spc_path=$1
  case "$_spc_path" in
  /*) ;;
  *)
    unset _spc_path
    return 1
    ;;
  esac
  if [ "$_spc_path" = / ]; then
    unset _spc_path
    sp_cap_print_line /
    return 0
  fi
  while [ "$_spc_path" != / ]; do
    case "$_spc_path" in
    */) _spc_path=${_spc_path%/} ;;
    *) break ;;
    esac
  done
  case "$_spc_path" in
  */../* | */.. | */.)
    unset _spc_path
    return 1
    ;;
  esac
  _spc_dir=${_spc_path%/*}
  _spc_base=${_spc_path##*/}
  [ -n "$_spc_dir" ] || _spc_dir=/
  [ -n "$_spc_base" ] || {
    unset _spc_path _spc_dir _spc_base
    return 1
  }
  _spc_suffix=
  while [ ! -e "$_spc_dir" ]; do
    _spc_component=${_spc_dir##*/}
    [ -n "$_spc_component" ] || {
      unset _spc_path _spc_dir _spc_base _spc_suffix _spc_parent _spc_component
      return 1
    }
    _spc_suffix="/$_spc_component$_spc_suffix"
    _spc_parent=${_spc_dir%/*}
    [ -n "$_spc_parent" ] || _spc_parent=/
    [ "$_spc_parent" != "$_spc_dir" ] || {
      unset _spc_path _spc_dir _spc_base _spc_suffix _spc_parent _spc_component
      return 1
    }
    _spc_dir=$_spc_parent
  done
  [ -d "$_spc_dir" ] || {
    unset _spc_path _spc_dir _spc_base _spc_suffix _spc_parent _spc_component
    return 1
  }
  _spc_real_dir=$(sp_cap_physical_dir "$_spc_dir") || {
    unset _spc_path _spc_dir _spc_base _spc_suffix _spc_parent _spc_component _spc_real_dir
    return 1
  }
  case "$_spc_real_dir:$_spc_suffix" in
  /:)
    sp_cap_print_line "/$_spc_base"
    ;;
  /:*)
    sp_cap_print_line "$_spc_suffix/$_spc_base"
    ;;
  *)
    sp_cap_print_line "$_spc_real_dir$_spc_suffix/$_spc_base"
    ;;
  esac
  unset _spc_path _spc_dir _spc_base _spc_suffix _spc_parent _spc_component _spc_real_dir
}

sp_cap_path_under() {
  [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || return 1
  _spc_base=$1
  _spc_target=$2
  case "$_spc_base" in
  /*) ;;
  *)
    unset _spc_base _spc_target
    return 1
    ;;
  esac
  [ -d "$_spc_base" ] || {
    unset _spc_base _spc_target
    return 1
  }
  _spc_base_real=$(sp_cap_physical_dir "$_spc_base") || {
    unset _spc_base _spc_target _spc_base_real
    return 1
  }
  _spc_target_real=$(sp_cap_canonical_path "$_spc_target") || {
    unset _spc_base _spc_target _spc_base_real _spc_target_real
    return 1
  }
  case "$_spc_base_real" in
  /)
    case "$_spc_target_real" in /*) _spc_under=1 ;; *) _spc_under=0 ;; esac
    ;;
  *)
    case "$_spc_target_real" in "$_spc_base_real" | "$_spc_base_real"/*) _spc_under=1 ;; *) _spc_under=0 ;; esac
    ;;
  esac
  unset _spc_base _spc_target _spc_base_real _spc_target_real
  if [ "$_spc_under" -eq 1 ]; then
    unset _spc_under
    return 0
  fi
  unset _spc_under
  return 1
}

sp_cap_reject_symlink_path() (
  [ "$#" -eq 1 ] && [ -n "$1" ] || exit 1
  _spc_path=$1
  case "$_spc_path" in
  /*) ;;
  *)
    sp_cap_error 'path must be absolute for symlink policy check'
    exit 1
    ;;
  esac
  case $- in
  *f*) _spc_glob_was_set=1 ;;
  *)
    _spc_glob_was_set=0
    set -f
    ;;
  esac
  if [ "${IFS+x}" = x ]; then
    _spc_ifs_was_set=1
    _spc_old_ifs=${IFS-}
  else
    _spc_ifs_was_set=0
    _spc_old_ifs=
  fi
  IFS=/
  _spc_current=
  _spc_missing=0
  _spc_bad=0
  for _spc_part in ${_spc_path#/}; do
    [ -n "$_spc_part" ] || continue
    case "$_spc_part" in
    .) continue ;;
    ..)
      sp_cap_error 'path must not contain .. segments'
      _spc_bad=1
      break
      ;;
    esac
    if [ -z "$_spc_current" ]; then
      _spc_current=/$_spc_part
    else
      _spc_current=$_spc_current/$_spc_part
    fi
    [ "$_spc_missing" -eq 0 ] || continue
    if [ -L "$_spc_current" ]; then
      sp_cap_error "path component is a symlink: $_spc_current"
      _spc_bad=1
      break
    fi
    [ -e "$_spc_current" ] || _spc_missing=1
  done
  if [ "$_spc_ifs_was_set" -eq 1 ]; then
    IFS=$_spc_old_ifs
  else
    unset IFS
  fi
  [ "$_spc_glob_was_set" -eq 1 ] || set +f
  [ "$_spc_bad" -eq 0 ]
)

sp_cap_homebrew_prefix() {
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    case "$HOMEBREW_PREFIX" in
    /*)
      if [ -d "$HOMEBREW_PREFIX" ]; then
        command printf '%s\n' "$HOMEBREW_PREFIX"
        return 0
      fi
      ;;
    esac
  fi
  _spc_brew=$(sp_cap_command_path brew 2>/dev/null) || _spc_brew=
  if [ -n "$_spc_brew" ]; then
    _spc_prefix=$("$_spc_brew" --prefix 2>/dev/null) || _spc_prefix=
    case "$_spc_prefix" in
    /*)
      if [ -d "$_spc_prefix" ]; then
        command printf '%s\n' "$_spc_prefix"
        unset _spc_brew _spc_prefix
        return 0
      fi
      ;;
    esac
  fi
  if [ -d /opt/homebrew ]; then
    unset _spc_brew _spc_prefix
    command printf '%s\n' /opt/homebrew
    return 0
  fi
  if [ -d /usr/local/Homebrew ] || [ -d /usr/local/Cellar ]; then
    unset _spc_brew _spc_prefix
    command printf '%s\n' /usr/local
    return 0
  fi
  unset _spc_brew _spc_prefix
  return 1
}

sp_cap_homebrew_opt_gnubin() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  case "$1" in
  . | .. | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@+-]* | *'/'*) return 1 ;;
  esac
  _spc_prefix=$(sp_cap_homebrew_prefix) || {
    unset _spc_prefix
    return 1
  }
  _spc_path=$_spc_prefix/opt/$1/libexec/gnubin
  if [ -d "$_spc_path" ]; then
    command printf '%s\n' "$_spc_path"
    unset _spc_prefix _spc_path
    return 0
  fi
  unset _spc_prefix _spc_path
  return 1
}

sp_cap_write_compromise_paths() (
  [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || exit 1
  _spc_path=$1
  _spc_scope=$2
  [ -e "$_spc_path" ] || exit 1
  if [ -x /usr/bin/env ] && [ -x /bin/sh ]; then
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
      _spc_path=$1
      _spc_scope=$2
      [ -e "$_spc_path" ] || exit 1
      _spc_uid=$(command -p id -u 2>/dev/null) || exit 1
      _spc_user=$(command -p id -u -n 2>/dev/null || printf "%s\n" "")
      _spc_group=$(command -p id -g -n 2>/dev/null || command -p id -g 2>/dev/null) || exit 1
      _spc_is_upg=0
      [ -n "$_spc_user" ] && [ "$_spc_user" = "$_spc_group" ] && _spc_is_upg=1
      case "$_spc_scope:$_spc_is_upg" in
      self:1)
        command -p find "$_spc_path" -prune \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( \( -perm -020 ! -group "$_spc_group" \) -o -perm -002 \) \) \) -print
        ;;
      self:0)
        command -p find "$_spc_path" -prune \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( -perm -020 -o -perm -002 \) \) \) -print
        ;;
      tree:1)
        command -p find "$_spc_path" \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( \( -perm -020 ! -group "$_spc_group" \) -o -perm -002 \) \) \) -print
        ;;
      tree:0)
        command -p find "$_spc_path" \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( -perm -020 -o -perm -002 \) \) \) -print
        ;;
      *) exit 1 ;;
      esac
    ' sh "$_spc_path" "$_spc_scope"
  else
    unset -f command find id 2>/dev/null || :
    _spc_uid=$(command -p id -u 2>/dev/null) || exit 1
    _spc_user=$(command -p id -u -n 2>/dev/null || printf '%s\n' '')
    _spc_group=$(command -p id -g -n 2>/dev/null || command -p id -g 2>/dev/null) || exit 1
    _spc_is_upg=0
    [ -n "$_spc_user" ] && [ "$_spc_user" = "$_spc_group" ] && _spc_is_upg=1
    case "$_spc_scope:$_spc_is_upg" in
    self:1)
      command -p find "$_spc_path" -prune \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( \( -perm -020 ! -group "$_spc_group" \) -o -perm -002 \) \) \) -print
      ;;
    self:0)
      command -p find "$_spc_path" -prune \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( -perm -020 -o -perm -002 \) \) \) -print
      ;;
    tree:1)
      command -p find "$_spc_path" \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( \( -perm -020 ! -group "$_spc_group" \) -o -perm -002 \) \) \) -print
      ;;
    tree:0)
      command -p find "$_spc_path" \( -type l -o ! -user "$_spc_uid" -o \( ! -type l -a \( -perm -020 -o -perm -002 \) \) \) -print
      ;;
    *) exit 1 ;;
    esac
  fi
)

sp_cap_secure_local_bin_check() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  _spc_home=$1
  case "$_spc_home" in
  /*) ;;
  *)
    sp_cap_error 'HOME is not an absolute path'
    unset _spc_home
    return 1
    ;;
  esac
  [ -d "$_spc_home" ] && [ ! -L "$_spc_home" ] || {
    sp_cap_error "HOME is not a real directory: $_spc_home"
    unset _spc_home
    return 1
  }
  _spc_local_dir=$_spc_home/.local
  _spc_local_bin=$_spc_local_dir/bin
  _spc_home_bad=$(sp_cap_write_compromise_paths "$_spc_home" self) || {
    sp_cap_error "failed to inspect HOME permissions: $_spc_home"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad
    return 1
  }
  if [ -n "$_spc_home_bad" ]; then
    sp_cap_error "HOME violates ownership, symlink, or external-write policy: $_spc_home"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad
    return 1
  fi
  [ -d "$_spc_local_dir" ] && [ ! -L "$_spc_local_dir" ] || {
    sp_cap_error "local directory is not a real directory: $_spc_local_dir"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad
    return 1
  }
  [ -d "$_spc_local_bin" ] && [ ! -L "$_spc_local_bin" ] || {
    sp_cap_error "local bin directory is not a real directory: $_spc_local_bin"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad
    return 1
  }
  _spc_local_bad=$(sp_cap_write_compromise_paths "$_spc_local_dir" self) || {
    sp_cap_error "failed to inspect local directory permissions: $_spc_local_dir"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad _spc_local_bad
    return 1
  }
  if [ -n "$_spc_local_bad" ]; then
    sp_cap_error "local directory violates ownership, symlink, or external-write policy: $_spc_local_dir"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad _spc_local_bad
    return 1
  fi
  _spc_bin_bad=$(sp_cap_write_compromise_paths "$_spc_local_bin" tree) || {
    sp_cap_error "failed to inspect local bin execution chain: $_spc_local_bin"
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad _spc_local_bad _spc_bin_bad
    return 1
  }
  if [ -n "$_spc_bin_bad" ]; then
    sp_cap_error "Compromised execution chain. Writable/unowned files or symlinks found in '$_spc_local_bin'."
    sp_cap_print_line "$_spc_bin_bad" >&2
    unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad _spc_local_bad _spc_bin_bad
    return 1
  fi
  unset _spc_home _spc_local_dir _spc_local_bin _spc_home_bad _spc_local_bad _spc_bin_bad
  return 0
}

sp_cap_background() {
  [ "$#" -gt 0 ] || {
    sp_cap_error 'usage: sp_cap_background <command> [args...]'
    return 1
  }
  "$@" </dev/null >/dev/null 2>&1 &
  _spc_pid=$!
  command printf '%s\n' "$_spc_pid"
  unset _spc_pid
}
