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
    if [ "$_spm_label" = export ]; then
      # Exports become function definitions. A shell reserved word is a valid
      # identifier but not a valid function name.
      case "$_spm_word" in
      case|do|done|elif|else|esac|fi|for|if|in|then|until|while|time)
        sp_metadata_error "invalid export (reserved word): $_spm_word"
        if [ "$_spm_list_ifs_was_set" -eq 1 ]; then
          IFS=$_spm_list_ifs
        else
          unset IFS
        fi
        unset _spm_list _spm_label _spm_word _spm_list_ifs _spm_list_ifs_was_set _spm_list_seen
        return 1
        ;;
      esac
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
    posix | sh | bash | zsh | ksh | fish) ;;
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

# sp_metadata_validate_path_list <list> <label>
# Validate space-separated module-relative file paths: each must be a
# relative path with no empty, "." or ".." segment and no trailing slash.
sp_metadata_validate_path_list() {
  _spm_plist=$1
  _spm_plabel=$2
  sp_metadata_reject_glob_characters "$_spm_plist" "$_spm_plabel" || {
    unset _spm_plist _spm_plabel
    return 1
  }
  if [ "${IFS+x}" = x ]; then
    _spm_plist_ifs_was_set=1
    _spm_plist_ifs=${IFS-}
  else
    _spm_plist_ifs_was_set=0
    _spm_plist_ifs=
  fi
  _spm_plist_status=0
  IFS=' '
  for _spm_pword in $_spm_plist; do
    case "$_spm_pword" in
    . | ./* | */. | */./* | *//* | */)
      sp_metadata_error "invalid $_spm_plabel path: $_spm_pword"
      _spm_plist_status=1
      break
      ;;
    esac
    if ! sp_metadata_validate_relative_path "$_spm_pword"; then
      _spm_plist_status=1
      break
    fi
    if [ "$_spm_plabel" = executable ]; then
      _spm_pbase=${_spm_pword##*/}
      case "$_spm_pbase" in
      [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) ;;
      *)
        sp_metadata_error "invalid executable name: $_spm_pbase"
        _spm_plist_status=1
        break
        ;;
      esac
    fi
  done
  if [ "$_spm_plist_ifs_was_set" -eq 1 ]; then
    IFS=$_spm_plist_ifs
  else
    unset IFS
  fi
  _spm_plist_rc=$_spm_plist_status
  unset _spm_plist _spm_plabel _spm_pword _spm_pbase _spm_plist_ifs _spm_plist_ifs_was_set _spm_plist_status
  return "$_spm_plist_rc"
}

# sp_metadata_validate_commands <commands> <exports>
# Every published command must be one of the module's declared exports.
sp_metadata_validate_commands() {
  sp_metadata_validate_identifier_list "$1" command || return 1
  if [ "${IFS+x}" = x ]; then
    _spm_cmd_ifs_was_set=1
    _spm_cmd_ifs=${IFS-}
  else
    _spm_cmd_ifs_was_set=0
    _spm_cmd_ifs=
  fi
  _spm_cmd_status=0
  IFS=' '
  for _spm_cmd in $1; do
    case " $2 " in
    *" $_spm_cmd "*) ;;
    *)
      sp_metadata_error "command is not a declared export: $_spm_cmd"
      _spm_cmd_status=1
      break
      ;;
    esac
  done
  if [ "$_spm_cmd_ifs_was_set" -eq 1 ]; then
    IFS=$_spm_cmd_ifs
  else
    unset IFS
  fi
  _spm_cmd_rc=$_spm_cmd_status
  unset _spm_cmd _spm_cmd_ifs _spm_cmd_ifs_was_set _spm_cmd_status
  return "$_spm_cmd_rc"
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
  _spm_commands=
  _spm_executables=
  _spm_tests=
  _spm_version=
  _spm_load=
  _spm_seen=' '

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
    case "$_spm_seen" in
    *" $_spm_key "*)
      sp_metadata_error "duplicate metadata field: $_spm_key"
      return 1
      ;;
    esac
    _spm_seen="$_spm_seen$_spm_key "
    case "$_spm_key" in
    name) _spm_name=$_spm_value ;;
    requires) _spm_requires=$_spm_value ;;
    optional) _spm_optional=$_spm_value ;;
    shells) _spm_shells=$_spm_value ;;
    platforms) _spm_platforms=$_spm_value ;;
    side_effect) _spm_side_effect=$_spm_value ;;
    exports) _spm_exports=$_spm_value ;;
    commands) _spm_commands=$_spm_value ;;
    executables) _spm_executables=$_spm_value ;;
    tests) _spm_tests=$_spm_value ;;
    updates)
      sp_metadata_error 'metadata field updates is not supported since valise 0.3.0; publish commands with commands= or executables='
      return 1
      ;;
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
  sp_metadata_validate_commands "$_spm_commands" "$_spm_exports" || return 1
  sp_metadata_validate_path_list "$_spm_executables" executable || return 1
  sp_metadata_validate_path_list "$_spm_tests" test || return 1
  sp_metadata_validate_version "$_spm_version" || return 1
  sp_metadata_validate_relative_path "$_spm_load" || return 1

  printf 'name=%s\n' "$_spm_name"
  printf 'requires=%s\n' "$_spm_requires"
  printf 'optional=%s\n' "$_spm_optional"
  printf 'shells=%s\n' "$_spm_shells"
  printf 'platforms=%s\n' "$_spm_platforms"
  printf 'side_effect=%s\n' "$_spm_side_effect"
  printf 'exports=%s\n' "$_spm_exports"
  printf 'commands=%s\n' "$_spm_commands"
  printf 'executables=%s\n' "$_spm_executables"
  printf 'tests=%s\n' "$_spm_tests"
  printf 'version=%s\n' "$_spm_version"
  printf 'load=%s\n' "$_spm_load"
)
