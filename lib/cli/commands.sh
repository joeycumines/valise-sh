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

# release_commands <release-dir>: print the commands a release publishes.
release_commands() {
  release_conf_value "$1" commands 2>/dev/null || :
}

# reconcile_commands <release-dir>
# Make the stubs in the command directory match the commands the release
# publishes. Owned stubs for commands the release no longer has are removed;
# a missing stub is written unless the path holds a file valise does not own,
# which is left alone and reported. Call with the store lock held.
reconcile_commands() {
  _rcm_release=$1
  _rcm_want=$(release_commands "$_rcm_release")
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
    # A hard link fails when the name exists, so a file created since the
    # check above is never replaced.
    if "$_rcm_ln" "$_rc_stub" "$_rcm_path" 2>/dev/null; then
      printf '%s\t%s\t%s\n' "$_rcm_name" "$_rcm_path" "$_rcm_sha" >>"$_rc_tmp" ||
        die "cannot write command ledger"
      info "published command: $_rcm_path"
    else
      info "warning: command $_rcm_name not published: cannot create $_rcm_path"
    fi
    "$_rcm_rm" -f "$_rc_stub" || die "cannot remove command stub staging file"
    _rc_stub=""
  done

  "$_rcm_chmod" 0644 "$_rc_tmp" || die "cannot set command ledger mode"
  "$_rcm_mv" -f "$_rc_tmp" "$_rcm_ledger" || die "cannot publish command ledger"
  _rc_tmp=""
  if [ -n "$_rcm_want" ]; then
    case ":${PATH:-}:" in
    *":$_rcm_bin:"*) ;;
    *) info "warning: $_rcm_bin is not on PATH; add it to use the published commands" ;;
    esac
  fi
  unset _rcm_release _rcm_bin _rcm_ledger _rcm_want _rcm_tab _rcm_rm _rcm_mkdir _rcm_chmod _rcm_ln _rcm_mv \
    _rcm_owned _rcm_name _rcm_path _rcm_sha _rcm_keep
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
  _dc_want=$(release_commands "$1")
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
  case ":${PATH:-}:" in
  *":$_dc_bin:"*) printf '  ok: command directory is on PATH: %s\n' "$_dc_bin" ;;
  *) printf '  warn: command directory is not on PATH: %s\n' "$_dc_bin" ;;
  esac
  unset _dc_want _dc_bin _dc_ledger _dc_awk _dc_name _dc_path _dc_sha
}
