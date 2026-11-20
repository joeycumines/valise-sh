# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: published commands: the stubs that put an active release's
# bin/ commands on PATH, and the ledger that records which stubs valise owns.
# Sourced by bin/valise; not executable on its own.
#
# A stub is a tiny sh script in the command directory that execs the same
# name under the active release link, so a release switch never rewrites a
# stub; it only adds and removes them. The ledger lists every stub valise
# wrote as name, path, and SHA-256. A file valise did not write, or a stub
# someone edited, is never overwritten or removed.

_rc_tmp=""
_rc_stub=""
_rc_pub=""

# PATH-gap diagnostics consult VALISE_CALLER_PATH when the caller set it (even
# to an empty value), otherwise the real PATH. Command lookup still uses the
# real PATH. The expansion is used directly at each call site: a helper that
# printed the value would need a subshell, which strips trailing newlines.
# See path_contains_dir below.

# path_contains_dir <path-value> <dir>: succeed when <dir> names one entry of
# <path-value>. Entries and the target are normalized, so a trailing slash or a
# doubled separator (common in $TMPDIR-derived homes) is not a false gap. Empty
# entries denote the current directory; they are skipped when no caller CWD is
# known (the directory valise runs in after -C is not the caller's).
# Relative entries are resolved against VALISE_CALLER_CWD when set: bin/valise
# records the caller's directory before -C changes it, so `.local/bin` means
# the caller's `.local/bin`, and an empty entry means the caller's directory,
# not the project's. Library-only callers (tests and embedded use) leave it
# unset, and path_normalize then uses the current directory as before.
# Each path_normalize capture appends a sentinel (&& printf x): command
# substitution strips trailing newlines, so without the sentinel an entry like
# "/bin/dir<LF>" would normalize to "/bin/dir<LF>\n", lose its newlines in the
# capture, and falsely match "/bin/dir".
path_contains_dir() {
  _pcd_path=$1
  # An explicitly empty PATH value has no entries at all, even though the
  # splitting loop below would otherwise see one empty (CWD) entry.
  [ -n "$_pcd_path" ] || { unset _pcd_path; return 1; }
  if ! _pcd_dir=$(path_normalize "$2" && printf x); then
    unset _pcd_path _pcd_dir
    return 1
  fi
  # Split the path value with POSIX parameter stripping rather than IFS word
  # splitting: zsh does not split unquoted expansions by default, and `set --`
  # here would also clobber the caller's positional parameters. A trailing
  # colon is a final empty entry; it matches the caller's directory when known
  # and is otherwise skipped.
  _pcd_rem=${_pcd_path}:
  while [ -n "$_pcd_rem" ]; do
    _pcd_entry=${_pcd_rem%%:*}
    _pcd_rem=${_pcd_rem#*:}
    _pcd_candidate=$_pcd_entry
    case "$_pcd_candidate" in
    /*) : ;;
    *)
      # An empty entry denotes the caller's current directory when known.
      if [ -n "${VALISE_CALLER_CWD:-}" ]; then
        _pcd_candidate=$VALISE_CALLER_CWD/$_pcd_candidate
      fi
      ;;
    esac
    [ -n "$_pcd_candidate" ] || continue
    if _pcd_norm=$(path_normalize "$_pcd_candidate" && printf x) &&
      [ "$_pcd_norm" = "$_pcd_dir" ]; then
      unset _pcd_path _pcd_dir _pcd_rem _pcd_entry _pcd_candidate _pcd_norm
      return 0
    fi
  done
  unset _pcd_path _pcd_dir _pcd_rem _pcd_entry _pcd_candidate _pcd_norm
  return 1
}

# commands_bin_dir: the directory stubs are written to.
commands_bin_dir() {
  [ -n "${VALISE_BIN_DIR:-}${XDG_BIN_HOME:-}${HOME:-}" ] || return 1
  path_normalize "${VALISE_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
}

commands_ledger_path() {
  printf '%s\n' "$VALISE_XDG_STATE/commands.tsv"
}

# commands_stub <name>: print the stub for one command.
commands_stub() {
  _cs_target=$(shell_quote "$VALISE_ACTIVE_LINK/bin/$1") || return 1
  printf '%s\n' \
    '#!/bin/sh' \
    '# valise command stub; managed by valise; do not edit.' \
    "exec $_cs_target \"\$@\""
  unset _cs_target
}

# commands_stub_digest <name>: print the SHA-256 of the stub for one command.
commands_stub_digest() {
  _csd_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-stub.XXXXXX") || return 1
  if commands_stub "$1" >"$_csd_tmp"; then
    file_sha256 "$_csd_tmp"
    _csd_status=$?
  else
    _csd_status=1
  fi
  _csd_rm=$(trusted_utility_path rm) || return 1
  "$_csd_rm" -f "$_csd_tmp" || _csd_status=1
  return "$_csd_status"
}

# commands_file_is <path> <sha256>: succeed when path is a regular file, not a
# symlink, with the given digest.
commands_file_is() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  _cfi_digest=$(file_sha256 "$1") || return 1
  [ "$_cfi_digest" = "$2" ]
}

# command_name_valid <name>: the build's rule for a published command name.
# It keeps a stub inside the command directory and free of glob characters.
command_name_valid() {
  case $1 in
  '' | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# release_commands <release-dir>: print the commands a release publishes.
# Fails, naming the entry, when an installed release lists a name the build
# would have rejected, so no caller ever joins such a name to a path.
release_commands() {
  _rcs_list=$(release_conf_value "$1" commands 2>/dev/null || :)
  _rcs_seen=" "
  _rcs_noglob=0
  case $- in *f*) _rcs_noglob=1 ;; esac
  set -f
  for _rcs_name in $_rcs_list; do
    if ! command_name_valid "$_rcs_name"; then
      [ "$_rcs_noglob" -eq 1 ] || set +f
      printf 'valise: error: release lists an invalid command name: %s\n' "$_rcs_name" >&2
      unset _rcs_list _rcs_seen _rcs_noglob _rcs_name
      return 1
    fi
    case $_rcs_seen in
    *" $_rcs_name "*) ;;
    *) _rcs_seen="$_rcs_seen$_rcs_name " ;;
    esac
  done
  [ "$_rcs_noglob" -eq 1 ] || set +f
  _rcs_seen=${_rcs_seen# }
  printf '%s\n' "${_rcs_seen% }"
  unset _rcs_list _rcs_seen _rcs_noglob _rcs_name
}

# commands_publish_ledger: publish the staged ledger rows as the ledger.
commands_publish_ledger() {
  _rc_pub=$(trusted_mktemp_at "$VALISE_XDG_STATE" file "$VALISE_XDG_STATE/.commands.XXXXXX") ||
    die "cannot create command ledger staging file"
  "$_rcm_cat" "$_rc_tmp" >"$_rc_pub" || die "cannot write command ledger"
  "$_rcm_chmod" 0644 "$_rc_pub" || die "cannot set command ledger mode"
  "$_rcm_mv" -f "$_rc_pub" "$_rcm_ledger" || die "cannot publish command ledger"
  _rc_pub=""
}

# reconcile_commands <release-dir>
# Make the stubs in the command directory match the commands the release
# publishes. Owned stubs for commands the release no longer has are removed;
# a missing stub is written unless the path holds a file valise does not own,
# which is left alone and reported. Call with the store lock held.
reconcile_commands() {
  _rcm_release=$1
  _rcm_want=$(release_commands "$_rcm_release") || die "refusing to publish the commands of $_rcm_release"
  if ! _rcm_bin=$(commands_bin_dir); then
    [ -z "$_rcm_want" ] || info "warning: HOME is not set; no commands were published"
    unset _rcm_release _rcm_want _rcm_bin
    return 0
  fi
  _rcm_ledger=$(commands_ledger_path)
  _rcm_tab=$(printf '\t')
  _rcm_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _rcm_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _rcm_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  _rcm_ln=$(trusted_utility_path ln) || die "no trusted ln utility available"
  _rcm_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  _rcm_cat=$(trusted_utility_path cat) || die "no trusted cat utility available"
  _rcm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  [ ! -L "$_rcm_ledger" ] || die "command ledger must not be a symlink: $_rcm_ledger"
  "$_rcm_mkdir" -p "$VALISE_XDG_STATE" || die "cannot create state directory: $VALISE_XDG_STATE"
  _rc_tmp=$(trusted_mktemp_at "$VALISE_XDG_STATE" file "$VALISE_XDG_STATE/.commands.XXXXXX") ||
    die "cannot create command ledger staging file"
  _rcm_owned=

  # Drop or keep each stub the ledger records.
  if [ -f "$_rcm_ledger" ]; then
    while IFS="$_rcm_tab" read -r _rcm_name _rcm_path _rcm_sha; do
      [ -n "$_rcm_name" ] || continue
      case " $_rcm_want " in
      *" $_rcm_name "*) _rcm_keep=1 ;;
      *) _rcm_keep=0 ;;
      esac
      [ "$_rcm_path" = "$_rcm_bin/$_rcm_name" ] || _rcm_keep=0
      if [ ! -e "$_rcm_path" ] && [ ! -L "$_rcm_path" ]; then
        # The stub is gone; it is written again below if still wanted.
        continue
      fi
      if ! commands_file_is "$_rcm_path" "$_rcm_sha"; then
        info "warning: command stub was changed outside valise; leaving it and no longer managing it: $_rcm_path"
        continue
      fi
      if [ "$_rcm_keep" -eq 1 ]; then
        printf '%s\t%s\t%s\n' "$_rcm_name" "$_rcm_path" "$_rcm_sha" >>"$_rc_tmp" ||
          die "cannot write command ledger"
        _rcm_owned="$_rcm_owned $_rcm_name"
      else
        "$_rcm_rm" -f "$_rcm_path" || die "cannot remove command stub: $_rcm_path"
        info "removed command: $_rcm_path"
      fi
    done <"$_rcm_ledger"
  elif [ -e "$_rcm_ledger" ]; then
    die "command ledger is not a regular file: $_rcm_ledger"
  fi

  # Write each wanted stub valise does not hold yet.
  for _rcm_name in $_rcm_want; do
    case " $_rcm_owned " in *" $_rcm_name "*) continue ;; esac
    _rcm_path="$_rcm_bin/$_rcm_name"
    if [ -e "$_rcm_path" ] || [ -L "$_rcm_path" ]; then
      info "warning: command $_rcm_name not published: $_rcm_path exists and valise does not own it"
      continue
    fi
    "$_rcm_mkdir" -p "$_rcm_bin" || die "cannot create command directory: $_rcm_bin"
    _rc_stub=$(trusted_mktemp_at "$_rcm_bin" file "$_rcm_bin/.valise-stub.XXXXXX") ||
      die "cannot create command stub staging file"
    commands_stub "$_rcm_name" >"$_rc_stub" || die "cannot write command stub: $_rcm_name"
    "$_rcm_chmod" 0755 "$_rc_stub" || die "cannot set command stub mode"
    _rcm_sha=$(file_sha256 "$_rc_stub") || die "no trusted SHA-256 utility available"
    # The ledger names the stub before the stub exists, so an interrupted run
    # never leaves a stub valise does not know it owns; a recorded stub that
    # is missing is simply written again later.
    printf '%s\t%s\t%s\n' "$_rcm_name" "$_rcm_path" "$_rcm_sha" >>"$_rc_tmp" ||
      die "cannot write command ledger"
    commands_publish_ledger
    # A hard link fails when the name exists, so a file created since the
    # check above is never replaced.
    if "$_rcm_ln" "$_rc_stub" "$_rcm_path" 2>/dev/null; then
      info "published command: $_rcm_path"
    else
      info "warning: command $_rcm_name not published: cannot create $_rcm_path"
      _rc_pub=$(trusted_mktemp_at "$VALISE_XDG_STATE" file "$VALISE_XDG_STATE/.commands.XXXXXX") ||
        die "cannot create command ledger staging file"
      "$_rcm_awk" -F '\t' -v n="$_rcm_name" -v p="$_rcm_path" '!($1 == n && $2 == p)' "$_rc_tmp" >"$_rc_pub" &&
        "$_rcm_mv" -f "$_rc_pub" "$_rc_tmp" || die "cannot write command ledger"
      _rc_pub=""
      commands_publish_ledger
    fi
    "$_rcm_rm" -f "$_rc_stub" || die "cannot remove command stub staging file"
    _rc_stub=""
  done

  "$_rcm_chmod" 0644 "$_rc_tmp" || die "cannot set command ledger mode"
  "$_rcm_mv" -f "$_rc_tmp" "$_rcm_ledger" || die "cannot publish command ledger"
  _rc_tmp=""
  if [ -n "$_rcm_want" ]; then
    if ! path_contains_dir "${VALISE_CALLER_PATH-${PATH:-}}" "$_rcm_bin"; then
      info "warning: $_rcm_bin is not on PATH; add it to use the published commands"
    fi
  fi
  unset _rcm_release _rcm_bin _rcm_ledger _rcm_want _rcm_tab _rcm_rm _rcm_mkdir _rcm_chmod _rcm_ln _rcm_mv \
    _rcm_cat _rcm_awk _rcm_owned _rcm_name _rcm_path _rcm_sha _rcm_keep
}

# remove_owned_commands: remove every stub the ledger records that still has
# the content valise wrote, then the ledger. Call with the store lock held.
remove_owned_commands() {
  _roc_ledger=$(commands_ledger_path)
  [ -e "$_roc_ledger" ] || [ -L "$_roc_ledger" ] || return 0
  [ -f "$_roc_ledger" ] && [ ! -L "$_roc_ledger" ] || die "command ledger is not a regular file: $_roc_ledger"
  _roc_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _roc_tab=$(printf '\t')
  while IFS="$_roc_tab" read -r _roc_name _roc_path _roc_sha; do
    [ -n "$_roc_name" ] || continue
    [ -e "$_roc_path" ] || [ -L "$_roc_path" ] || continue
    if commands_file_is "$_roc_path" "$_roc_sha"; then
      "$_roc_rm" -f "$_roc_path" || die "cannot remove command stub: $_roc_path"
      info "removed command: $_roc_path"
    else
      info "warning: command stub was changed outside valise; leaving it: $_roc_path"
    fi
  done <"$_roc_ledger"
  "$_roc_rm" -f "$_roc_ledger" || die "cannot remove command ledger: $_roc_ledger"
  unset _roc_ledger _roc_rm _roc_tab _roc_name _roc_path _roc_sha
}

# doctor_commands <release-dir>
# Report the state of each command the release publishes. Prints doctor
# lines; sets _status=1 when a published command cannot run.
doctor_commands() {
  if ! _dc_want=$(release_commands "$1"); then
    printf '  FAIL: the active release lists an invalid command name\n'
    _status=1
    return 0
  fi
  [ -n "$_dc_want" ] || return 0
  _dc_bin=$(commands_bin_dir) || {
    printf '  FAIL: cannot resolve the command directory\n'
    _status=1
    return 0
  }
  _dc_ledger=$(commands_ledger_path)
  if [ ! -f "$_dc_ledger" ] || [ -L "$_dc_ledger" ]; then
    printf '  info: release commands are not published (installed without integration): %s\n' "$_dc_want"
    unset _dc_want _dc_bin _dc_ledger
    return 0
  fi
  _dc_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  for _dc_name in $_dc_want; do
    _dc_path="$_dc_bin/$_dc_name"
    _dc_sha=$("$_dc_awk" -F '\t' -v n="$_dc_name" -v p="$_dc_path" '$1 == n && $2 == p { print $3; exit }' "$_dc_ledger")
    if [ -z "$_dc_sha" ]; then
      if [ -e "$_dc_path" ] || [ -L "$_dc_path" ]; then
        printf '  warn: command %s not published: %s exists and valise does not own it\n' "$_dc_name" "$_dc_path"
      else
        printf '  warn: command %s not published (run valise install or valise release use)\n' "$_dc_name"
      fi
    elif commands_file_is "$_dc_path" "$_dc_sha"; then
      printf '  ok: command published: %s\n' "$_dc_path"
    else
      printf '  FAIL: command stub missing or changed: %s\n' "$_dc_path"
      _status=1
    fi
  done
  if path_contains_dir "${VALISE_CALLER_PATH-${PATH:-}}" "$_dc_bin"; then
    printf '  ok: command directory is on PATH: %s\n' "$_dc_bin"
  else
    printf '  warn: command directory is not on PATH: %s\n' "$_dc_bin"
  fi
  unset _dc_want _dc_bin _dc_ledger _dc_awk _dc_name _dc_path _dc_sha
}
