#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# shell-profile module metadata ABI helpers.

sp_metadata_error() {
  printf 'metadata: %s\n' "$*" >&2
}

sp_metadata_validate_identifier() {
  [ "$#" -eq 1 ] || return 1
  _spm_ident=$1
  [ -n "$_spm_ident" ] || {
    unset _spm_ident
    return 1
  }
  case "$_spm_ident" in
  [abcdefghijklmnopqrstuvwxyz_]*) ;;
  *)
    unset _spm_ident
    return 1
    ;;
  esac
  case "$_spm_ident" in
  *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*)
    unset _spm_ident
    return 1
    ;;
  *)
    unset _spm_ident
    return 0
    ;;
  esac
}

sp_metadata_validate_identifier_list() {
  _spm_list=$1
  _spm_label=$2
  if ! sp_metadata_reject_control_characters "$_spm_list" "$_spm_label"; then
    unset _spm_list _spm_label
    return 1
  fi
  if ! sp_metadata_reject_glob_characters "$_spm_list" "$_spm_label"; then
    unset _spm_list _spm_label
    return 1
  fi
  if [ "${IFS+x}" = x ]; then
    _spm_list_ifs_was_set=1
    _spm_list_ifs=${IFS-}
  else
    _spm_list_ifs_was_set=0
    _spm_list_ifs=
  fi
  _spm_list_seen=0
  IFS=' '
  for _spm_word in $_spm_list; do
    _spm_list_seen=1
    if ! sp_metadata_validate_identifier "$_spm_word"; then
      sp_metadata_error "invalid $_spm_label: $_spm_word"
      if [ "$_spm_list_ifs_was_set" -eq 1 ]; then
        IFS=$_spm_list_ifs
      else
        unset IFS
      fi
      unset _spm_list _spm_label _spm_word _spm_list_ifs _spm_list_ifs_was_set _spm_list_seen
      return 1
    fi
  done
  if [ "$_spm_list_ifs_was_set" -eq 1 ]; then
    IFS=$_spm_list_ifs
  else
    unset IFS
  fi
  if [ "$_spm_list_seen" -eq 0 ] && [ -n "$_spm_list" ]; then
    sp_metadata_error "invalid $_spm_label: whitespace-only list"
    unset _spm_list _spm_label _spm_word _spm_list_ifs _spm_list_ifs_was_set _spm_list_seen
    return 1
  fi
  unset _spm_list _spm_label _spm_word _spm_list_ifs _spm_list_ifs_was_set _spm_list_seen
  return 0
}

sp_metadata_reject_glob_characters() {
  _spm_glob_value=$1
  _spm_glob_label=$2
  case "$_spm_glob_value" in
  *'*'* | *'?'* | *'['* | *']'* | *'\'* )
    sp_metadata_error "invalid $_spm_glob_label: contains glob metacharacter"
    unset _spm_glob_value _spm_glob_label
    return 1
    ;;
  esac
  unset _spm_glob_value _spm_glob_label
  return 0
}

sp_metadata_reject_control_characters() {
  _spm_control_value=$1
  _spm_control_label=$2
  case "$_spm_control_value" in
  *[[:cntrl:]]*)
    sp_metadata_error "invalid $_spm_control_label: contains control character"
    unset _spm_control_value _spm_control_label
    return 1
    ;;
  esac
  unset _spm_control_value _spm_control_label
  return 0
}

sp_metadata_validate_shell_list() {
  [ -n "$1" ] || {
    sp_metadata_error 'missing required metadata field: shells'
    return 1
  }
  sp_metadata_reject_control_characters "$1" shell || return 1
  sp_metadata_reject_glob_characters "$1" shell || return 1
  if [ "${IFS+x}" = x ]; then
    _spm_shell_ifs_was_set=1
    _spm_shell_ifs=${IFS-}
  else
    _spm_shell_ifs_was_set=0
    _spm_shell_ifs=
  fi
  _spm_shell_seen=0
  IFS=' '
  for _spm_shell in $1; do
    _spm_shell_seen=1
    case "$_spm_shell" in
    sh | bash | zsh | ksh | fish) ;;
    *)
      sp_metadata_error "invalid shell: $_spm_shell"
      if [ "$_spm_shell_ifs_was_set" -eq 1 ]; then
        IFS=$_spm_shell_ifs
      else
        unset IFS
      fi
      unset _spm_shell _spm_shell_ifs _spm_shell_ifs_was_set _spm_shell_seen
      return 1
      ;;
    esac
  done
  if [ "$_spm_shell_ifs_was_set" -eq 1 ]; then
    IFS=$_spm_shell_ifs
  else
    unset IFS
  fi
  if [ "$_spm_shell_seen" -eq 0 ]; then
    sp_metadata_error 'missing required metadata field: shells'
    unset _spm_shell _spm_shell_ifs _spm_shell_ifs_was_set _spm_shell_seen
    return 1
  fi
  unset _spm_shell _spm_shell_ifs _spm_shell_ifs_was_set _spm_shell_seen
  return 0
}

sp_metadata_validate_platform_list() {
  [ -n "$1" ] || {
    sp_metadata_error 'missing required metadata field: platforms'
    return 1
  }
  sp_metadata_reject_control_characters "$1" platform || return 1
  sp_metadata_reject_glob_characters "$1" platform || return 1
  if [ "${IFS+x}" = x ]; then
    _spm_platform_ifs_was_set=1
    _spm_platform_ifs=${IFS-}
  else
    _spm_platform_ifs_was_set=0
    _spm_platform_ifs=
  fi
  _spm_platform_seen=0
  IFS=' '
  for _spm_platform in $1; do
    _spm_platform_seen=1
    case "$_spm_platform" in
    any | darwin | linux | bsd | freebsd | openbsd | netbsd) ;;
    *)
      sp_metadata_error "invalid platform: $_spm_platform"
      if [ "$_spm_platform_ifs_was_set" -eq 1 ]; then
        IFS=$_spm_platform_ifs
      else
        unset IFS
      fi
      unset _spm_platform _spm_platform_ifs _spm_platform_ifs_was_set _spm_platform_seen
      return 1
      ;;
    esac
  done
  if [ "$_spm_platform_ifs_was_set" -eq 1 ]; then
    IFS=$_spm_platform_ifs
  else
    unset IFS
  fi
  if [ "$_spm_platform_seen" -eq 0 ]; then
    sp_metadata_error 'missing required metadata field: platforms'
    unset _spm_platform _spm_platform_ifs _spm_platform_ifs_was_set _spm_platform_seen
    return 1
  fi
  unset _spm_platform _spm_platform_ifs _spm_platform_ifs_was_set _spm_platform_seen
  return 0
}

sp_metadata_validate_version() {
  [ "$#" -eq 1 ] || return 1
  _spm_ver=$1
  if [ -z "$_spm_ver" ]; then
    unset _spm_ver
    return 0
  fi
  case "$_spm_ver" in
  [0123456789]*) ;;
  *)
    sp_metadata_error "invalid version: $_spm_ver"
    unset _spm_ver
    return 1
    ;;
  esac
  case "$_spm_ver" in
  *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*)
    sp_metadata_error "invalid version: $_spm_ver"
    unset _spm_ver
    return 1
    ;;
  esac
  unset _spm_ver
  return 0
}

sp_metadata_validate_side_effect() {
  case "$1" in
  read-only | path-env | generated-file | update-network | install-time | local-secret | local-state | work-only) return 0 ;;
  *)
    sp_metadata_error "invalid side_effect: $1"
    return 1
    ;;
  esac
}

sp_metadata_validate_source_side_effect() {
  sp_metadata_validate_side_effect "$1" || return 1
  case "$1" in
  generated-file | update-network | install-time)
    sp_metadata_error "side_effect not allowed during ordinary source: $1"
    return 1
    ;;
  *) return 0 ;;
  esac
}

sp_metadata_validate_relative_path() {
  [ -n "$1" ] || return 0
  _spm_path=$1
  case "$_spm_path" in
  /* | .. | ../* | */.. | */../*)
    sp_metadata_error "invalid relative path: $_spm_path"
    unset _spm_path
    return 1
    ;;
  esac
  case "$_spm_path" in
  *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-]*)
    sp_metadata_error "invalid relative path: $_spm_path"
    unset _spm_path
    return 1
    ;;
  esac
  unset _spm_path
  return 0
}

sp_metadata_validate_load_target() {
  _spm_target_load=$1
  _spm_target_requires=${2-}
  if [ -z "$_spm_target_load" ] && [ -z "$_spm_target_requires" ]; then
    sp_metadata_error 'missing required metadata field: load or requires'
    unset _spm_target_load _spm_target_requires
    return 1
  fi
  unset _spm_target_load _spm_target_requires
  return 0
}

sp_metadata_require_field() {
  _spm_field=$1
  _spm_value=$2
  if [ -z "$_spm_value" ]; then
    sp_metadata_error "missing required metadata field: $_spm_field"
    unset _spm_field _spm_value
    return 1
  fi
  unset _spm_field _spm_value
  return 0
}

sp_metadata_read() (
  [ "$#" -eq 1 ] || {
    sp_metadata_error 'usage: sp_metadata_read <metadata-file>'
    return 1
  }
  _spm_file=$1
  [ -r "$_spm_file" ] || {
    sp_metadata_error "metadata file is not readable: $_spm_file"
    return 1
  }

  _spm_name=
  _spm_requires=
  _spm_optional=
  _spm_shells=
  _spm_platforms=
  _spm_side_effect=
  _spm_exports=
  _spm_updates=
  _spm_version=
  _spm_load=

  while IFS= read -r _spm_line || [ -n "$_spm_line" ]; do
    case "$_spm_line" in
    '' | \#*) continue ;;
    *=*) ;;
    *)
      sp_metadata_error "invalid metadata line: $_spm_line"
      return 1
      ;;
    esac
    _spm_key=${_spm_line%%=*}
    _spm_value=${_spm_line#*=}
    sp_metadata_reject_control_characters "$_spm_value" "$_spm_key" || return 1
    case "$_spm_key" in
    name) _spm_name=$_spm_value ;;
    requires) _spm_requires=$_spm_value ;;
    optional) _spm_optional=$_spm_value ;;
    shells) _spm_shells=$_spm_value ;;
    platforms) _spm_platforms=$_spm_value ;;
    side_effect) _spm_side_effect=$_spm_value ;;
    exports) _spm_exports=$_spm_value ;;
    updates) _spm_updates=$_spm_value ;;
    version) _spm_version=$_spm_value ;;
    load) _spm_load=$_spm_value ;;
    load_hook)
      sp_metadata_error 'metadata field load_hook is not supported; use load'
      return 1
      ;;
    *)
      sp_metadata_error "unknown metadata field: $_spm_key"
      return 1
      ;;
    esac
  done <"$_spm_file"

  sp_metadata_require_field name "$_spm_name" || return 1
  sp_metadata_require_field shells "$_spm_shells" || return 1
  sp_metadata_require_field platforms "$_spm_platforms" || return 1
  sp_metadata_require_field side_effect "$_spm_side_effect" || return 1

  if ! sp_metadata_validate_identifier "$_spm_name"; then
    sp_metadata_error "invalid module name: $_spm_name"
    return 1
  fi
  sp_metadata_validate_identifier_list "$_spm_requires" dependency || return 1
  sp_metadata_validate_identifier_list "$_spm_optional" optional_dependency || return 1
  sp_metadata_validate_load_target "$_spm_load" "$_spm_requires" || return 1
  sp_metadata_validate_shell_list "$_spm_shells" || return 1
  sp_metadata_validate_platform_list "$_spm_platforms" || return 1
  sp_metadata_validate_side_effect "$_spm_side_effect" || return 1
  sp_metadata_validate_identifier_list "$_spm_exports" export || return 1
  sp_metadata_validate_identifier_list "$_spm_updates" update_registration || return 1
  sp_metadata_validate_version "$_spm_version" || return 1
  sp_metadata_validate_relative_path "$_spm_load" || return 1

  printf 'name=%s\n' "$_spm_name"
  printf 'requires=%s\n' "$_spm_requires"
  printf 'optional=%s\n' "$_spm_optional"
  printf 'shells=%s\n' "$_spm_shells"
  printf 'platforms=%s\n' "$_spm_platforms"
  printf 'side_effect=%s\n' "$_spm_side_effect"
  printf 'exports=%s\n' "$_spm_exports"
  printf 'updates=%s\n' "$_spm_updates"
  printf 'version=%s\n' "$_spm_version"
  printf 'load=%s\n' "$_spm_load"
)
