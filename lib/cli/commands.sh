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

# path_contains_dir <path-value> <dir>: compare PATH entries with the actual
# directory they reach. Resolve symlinks BEFORE "..": lexical normalization
# would make /a/link/../bin match /a/bin even when link points outside /a.
# Physical resolution also accepts distinct symlink aliases for the same dir.
# If a directory cannot be searched, only an identical path spelling matches.
#
# Relative and empty entries use the invocation directory captured before -C.
# Without that context they are skipped, never interpreted in the project.
# An explicitly empty PATH has no entries for this diagnostic; ':' contains
# two current-directory entries. Command lookup does not use this helper.
#
# Run in a subshell so cd, CDPATH, and scratch variables cannot alter the caller.
# Sentinel captures preserve every trailing newline in directory names. PATH
# is split with parameter expansion, without word splitting or glob expansion.
path_contains_dir() (
  [ -n "$1" ] && [ -n "$2" ] || return 1
  _pcd_dir=$2
  CDPATH=
  # A relative target is a library caller's argument; protect it from cd's
  # option parsing. The CLI passes its already absolute command directory.
  case $_pcd_dir in /*) ;; *) _pcd_dir=./$_pcd_dir ;; esac
  _pcd_dir_phys=$(cd -P "$_pcd_dir" 2>/dev/null && pwd -P && printf x) || _pcd_dir_phys=
  _pcd_rem=$1:
  while [ -n "$_pcd_rem" ]; do
    _pcd_candidate=${_pcd_rem%%:*}
    _pcd_rem=${_pcd_rem#*:}
    case $_pcd_candidate in
      /*) ;;
      *)
        [ -n "${VALISE_CALLER_CWD:-}" ] &&
          [ "${_valise_cwd_unavailable:-0}" = 0 ] || continue
        if [ -n "$_pcd_candidate" ]; then
          _pcd_candidate=${VALISE_CALLER_CWD%/}/$_pcd_candidate
        else
          _pcd_candidate=$VALISE_CALLER_CWD
        fi
        ;;
    esac
    [ "$_pcd_candidate" != "$_pcd_dir" ] || return 0
    if [ -n "$_pcd_dir_phys" ] &&
      _pcd_phys=$(cd -P "$_pcd_candidate" 2>/dev/null && pwd -P && printf x) &&
      [ "$_pcd_phys" = "$_pcd_dir_phys" ]; then
      return 0
    fi
  done
  return 1
)

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
# would have rejected, so no caller ever joins such a name to a path. A
# missing optional commands key means zero commands. An unreadable or malformed
# configuration is a hard failure, never an empty command list.
release_commands() {
  if [ ! -f "$1/valise-release.conf" ] || [ -L "$1/valise-release.conf" ] ||
    [ ! -r "$1/valise-release.conf" ]; then
    printf 'valise: error: cannot read the release configuration: %s/valise-release.conf\n' "$1" >&2
    return 1
  fi
  _rcs_awk=$(trusted_utility_path awk) || return 1
  # Read the complete file: release_conf_value deliberately returns nonzero
  # for an absent key and stops at the first match, so it cannot distinguish
  # this optional key from an I/O failure or validate later records.
  if ! _rcs_list=$(LC_ALL=C "$_rcs_awk" '
    /^[[:space:]]*(#|$)/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key = $0; sub(/=.*/, "", key)
      if (seen[key]++) {
        printf "valise: error: duplicate key in release configuration: %s\n", key > "/dev/stderr"
        bad = 1
      }
      if (key == "commands") commands = substr($0, length(key) + 2)
      next
    }
    { printf "valise: error: malformed release configuration record at line %d\n", NR > "/dev/stderr"; bad = 1 }
    END { if (bad) exit 1; print commands }
  ' "$1/valise-release.conf"); then
    printf 'valise: error: cannot read commands from the release configuration: %s/valise-release.conf\n' "$1" >&2
    return 1
  fi
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
  unset _rcs_awk _rcs_list _rcs_seen _rcs_noglob _rcs_name
}

# The ledger is an ownership record, never an indirection. Validate both its
# type and its complete contents before using any row as a deletion authority.
commands_ledger_validate() {
  _clv_path=$1
  [ -e "$_clv_path" ] || [ -L "$_clv_path" ] || return 0
  if [ -L "$_clv_path" ]; then
    printf 'valise: error: command ledger must not be a symlink: %s\n' "$_clv_path" >&2
    return 1
  fi
  if [ ! -f "$_clv_path" ] || [ ! -r "$_clv_path" ]; then
    printf 'valise: error: command ledger must be a readable regular file: %s\n' "$_clv_path" >&2
    return 1
  fi
  _clv_awk=$(trusted_utility_path awk) || return 1
  LC_ALL=C "$_clv_awk" -F '\t' '
    NF != 3 || $1 !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || $2 !~ /^\// ||
    length($3) != 64 || $3 ~ /[^0-9a-fA-F]/ || seen[$2]++ { bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$_clv_path" || {
    printf 'valise: error: cannot read a valid command ledger: %s\n' "$_clv_path" >&2
    return 1
  }
}

# Portable GNU/BSD stat spelling for identity, used only to distinguish a hard
# link we published from a colliding file another process created meanwhile.
commands_file_identity() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  _cfi_stat=$(trusted_utility_path stat) || return 1
  _cfi_value=$("$_cfi_stat" -c '%d:%i' "$1" 2>/dev/null || :)
  case "$_cfi_value" in
    ''|*[!0-9:]*|:*|*:|*:*:*) _cfi_value=$("$_cfi_stat" -f '%d:%i' "$1" 2>/dev/null || :) ;;
  esac
  case "$_cfi_value" in ''|*[!0-9:]*|:*|*:|*:*:*) return 1 ;; esac
  case "$_cfi_value" in *:*) printf '%s\n' "$_cfi_value" ;; *) return 1 ;; esac
}

commands_same_file() {
  _csf_a=$(commands_file_identity "$1") && _csf_b=$(commands_file_identity "$2") &&
    [ "$_csf_a" = "$_csf_b" ]
}

# Called before any active/stub/bridge mutation. Keep only verified owned stub
# copies; user edits present before the transaction remain outside our ownership.
commands_txn_snapshot() {
  _cts_ledger=$(commands_ledger_path)
  : >"$_transaction_dir/stubs.tsv" || die "cannot snapshot command ownership"
  : >"$_transaction_dir/published.tsv" || die "cannot create command publication journal"
  _cts_number=0
  if [ -f "$_cts_ledger" ]; then
    _transaction_ledger_had=1
    _transaction_ledger_mode=$(file_mode "$_cts_ledger") || die "cannot read command ledger mode"
    "$_tx_cat" "$_cts_ledger" >"$_transaction_dir/commands.tsv" || die "cannot snapshot command ledger"
    commands_ledger_validate "$_transaction_dir/commands.tsv" || die "cannot snapshot valid command ledger"
    _cts_tab=$(printf '\t')
    while IFS="$_cts_tab" read -r _cts_name _cts_path _cts_sha || [ -n "${_cts_name:-}" ]; do
      [ -n "$_cts_name" ] || continue
      commands_file_is "$_cts_path" "$_cts_sha" || continue
      _cts_number=$((_cts_number + 1))
      _cts_copy=stub-$_cts_number
      _cts_mode=$(file_mode "$_cts_path") || die "cannot read command stub mode: $_cts_path"
      "$_tx_cat" "$_cts_path" >"$_transaction_dir/$_cts_copy" || die "cannot snapshot command stub: $_cts_path"
      [ "$(file_sha256 "$_transaction_dir/$_cts_copy")" = "$_cts_sha" ] ||
        die "command stub changed while being snapshotted: $_cts_path"
      printf '%s\t%s\t%s\t%s\n' "$_cts_path" "$_cts_copy" "$_cts_mode" "$_cts_sha" >>"$_transaction_dir/stubs.tsv" ||
        die "cannot snapshot command ownership"
    done <"$_transaction_dir/commands.tsv"
  fi
  unset _cts_ledger _cts_number _cts_tab _cts_name _cts_path _cts_sha _cts_copy _cts_mode
}

# Keep the staging inode until the transaction ends. The journal precedes ln;
# rollback can prove whether ln published this inode even when a signal changed
# the utility's observed status, without adopting an identical foreign file.
commands_txn_record_publication() {
  [ "${_transaction_active:-0}" -eq 1 ] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$_transaction_dir/published.tsv" ||
    die "cannot record command publication"
}

commands_txn_restore() {
  _ctr_status=0
  _ctr_tab=$(printf '\t')
  : >"$_transaction_dir/changed-stubs" || return 1
  while IFS="$_ctr_tab" read -r _ctr_path _ctr_sha _ctr_stage; do
    [ -n "$_ctr_path" ] || continue
    if commands_same_file "$_ctr_stage" "$_ctr_path"; then
      if commands_file_is "$_ctr_path" "$_ctr_sha"; then
        "$_tx_rm" -f "$_ctr_path" 2>/dev/null || :
        if [ -e "$_ctr_path" ] || [ -L "$_ctr_path" ]; then
          printf 'valise: error: cannot remove newly published command stub: %s\n' "$_ctr_path" >&2
          _ctr_status=1
        fi
      else
        printf 'valise: warning: command stub changed during activation; leaving it: %s\n' "$_ctr_path" >&2
      fi
    fi
  done <"$_transaction_dir/published.tsv" || _ctr_status=1
  while IFS="$_ctr_tab" read -r _ctr_path _ctr_copy _ctr_mode _ctr_sha; do
    [ -n "$_ctr_path" ] || continue
    if [ -e "$_ctr_path" ] || [ -L "$_ctr_path" ]; then
      if ! commands_file_is "$_ctr_path" "$_ctr_sha"; then
        printf 'valise: warning: command stub changed during activation; leaving it: %s\n' "$_ctr_path" >&2
        printf '%s\n' "$_ctr_path" >>"$_transaction_dir/changed-stubs" || _ctr_status=1
        continue
      fi
    elif ! transaction_restore_file "$_transaction_dir/$_ctr_copy" "$_ctr_path" "$_ctr_mode" create; then
      printf 'valise: error: cannot restore command stub: %s\n' "$_ctr_path" >&2
      _ctr_status=1
    fi
  done <"$_transaction_dir/stubs.tsv" || _ctr_status=1
  _ctr_ledger=$(commands_ledger_path)
  if [ -L "$_ctr_ledger" ] || { [ -e "$_ctr_ledger" ] && [ ! -f "$_ctr_ledger" ]; }; then
    printf 'valise: error: command ledger changed type during activation; leaving it: %s\n' "$_ctr_ledger" >&2
    _ctr_status=1
  elif [ "$_transaction_ledger_had" -eq 1 ]; then
    _ctr_source=$_transaction_dir/commands.tsv
    if [ -s "$_transaction_dir/changed-stubs" ]; then
      _ctr_awk=$(trusted_utility_path awk) || return 1
      "$_ctr_awk" -F '\t' 'FILENAME == ARGV[1] { changed[$0] = 1; next } !($2 in changed)' \
        "$_transaction_dir/changed-stubs" "$_ctr_source" >"$_transaction_dir/restored-commands.tsv" || return 1
      _ctr_source=$_transaction_dir/restored-commands.tsv
    fi
    if ! transaction_restore_file "$_ctr_source" "$_ctr_ledger" "$_transaction_ledger_mode"; then
      printf 'valise: error: cannot restore command ledger: %s\n' "$_ctr_ledger" >&2
      _ctr_status=1
    fi
  else
    "$_tx_rm" -f "$_ctr_ledger" 2>/dev/null || :
    if [ -e "$_ctr_ledger" ]; then
      printf 'valise: error: cannot remove newly created command ledger: %s\n' "$_ctr_ledger" >&2
      _ctr_status=1
    fi
  fi
  return "$_ctr_status"
}

commands_txn_discard() {
  [ -f "$_transaction_dir/published.tsv" ] || return 0
  _ctd_status=0
  _ctd_tab=$(printf '\t')
  while IFS="$_ctd_tab" read -r _ctd_path _ctd_sha _ctd_stage; do
    [ -n "$_ctd_stage" ] || continue
    "$_tx_rm" -f "$_ctd_stage" 2>/dev/null || :
    if [ -e "$_ctd_stage" ] || [ -L "$_ctd_stage" ]; then
      printf 'valise: error: command staging file preserved at %s\n' "$_ctd_stage" >&2
      _ctd_status=1
    fi
  done <"$_transaction_dir/published.tsv" || _ctd_status=1
  return "$_ctd_status"
}

# commands_publish_ledger: publish the staged ledger rows as the ledger.
commands_publish_ledger() {
  trusted_mktemp_assign _rc_pub file "$VALISE_XDG_STATE/.commands.XXXXXX" "$VALISE_XDG_STATE" ||
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
  commands_ledger_validate "$(commands_ledger_path)" || die "cannot read command ledger"
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
  trusted_mktemp_assign _rc_tmp file "$VALISE_XDG_STATE/.commands.XXXXXX" "$VALISE_XDG_STATE" ||
    die "cannot create command ledger staging file"
  _rcm_owned=

  # Drop or keep each stub the ledger records. A non-regular (e.g. symlinked)
  # ledger cannot be read safely; report it instead of treating it as empty,
  # which would silently delete every owned stub.
  if [ -L "$_rcm_ledger" ]; then
    die "command ledger must not be a symlink: $_rcm_ledger"
  elif [ -e "$_rcm_ledger" ] && [ ! -f "$_rcm_ledger" ]; then
    die "command ledger is not a regular file: $_rcm_ledger"
  fi
  if [ -f "$_rcm_ledger" ]; then
    while IFS="$_rcm_tab" read -r _rcm_name _rcm_path _rcm_sha || [ -n "${_rcm_name:-}" ]; do
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
        transaction_checkpoint
      fi
    done <"$_rcm_ledger"
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
    trusted_mktemp_assign _rc_stub file "$_rcm_bin/.valise-stub.XXXXXX" "$_rcm_bin" ||
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
    _rcm_stage=$_rc_stub
    commands_txn_record_publication "$_rcm_path" "$_rcm_sha" "$_rcm_stage"
    # From here the journal owns this inode, including a failed recovery that
    # must preserve it. Generic EXIT scratch cleanup must not unlink it.
    [ "${_transaction_active:-0}" -ne 1 ] || _rc_stub=
    # A hard link fails when the name exists, so a file created since the
    # check above is never replaced.
    if "$_rcm_ln" "$_rcm_stage" "$_rcm_path" 2>/dev/null || commands_same_file "$_rcm_stage" "$_rcm_path"; then
      info "published command: $_rcm_path"
    else
      info "warning: command $_rcm_name not published: cannot create $_rcm_path"
      trusted_mktemp_assign _rc_pub file "$VALISE_XDG_STATE/.commands.XXXXXX" "$VALISE_XDG_STATE" ||
        die "cannot create command ledger staging file"
      VALISE_LEDGER_NAME="$_rcm_name" VALISE_LEDGER_PATH="$_rcm_path" "$_rcm_awk" -F '\t' \
        '!($1 == ENVIRON["VALISE_LEDGER_NAME"] && $2 == ENVIRON["VALISE_LEDGER_PATH"])' "$_rc_tmp" >"$_rc_pub" &&
        "$_rcm_mv" -f "$_rc_pub" "$_rc_tmp" || die "cannot write command ledger"
      _rc_pub=""
      commands_publish_ledger
    fi
    if [ "${_transaction_active:-0}" -eq 0 ]; then
      "$_rcm_rm" -f "$_rcm_stage" || die "cannot remove command stub staging file"
    fi
    _rc_stub=""
    transaction_checkpoint
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
    _rcm_cat _rcm_awk _rcm_owned _rcm_name _rcm_path _rcm_sha _rcm_keep _rcm_stage
}

# remove_owned_commands: remove every stub the ledger records that still has
# the content valise wrote, then the ledger. Call with the store lock held.
remove_owned_commands() {
  _roc_ledger=$(commands_ledger_path)
  [ -e "$_roc_ledger" ] || [ -L "$_roc_ledger" ] || return 0
  commands_ledger_validate "$_roc_ledger" || die "cannot read command ledger"
  [ -f "$_roc_ledger" ] && [ ! -L "$_roc_ledger" ] || die "command ledger is not a regular file: $_roc_ledger"
  _roc_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _roc_tab=$(printf '\t')
  while IFS="$_roc_tab" read -r _roc_name _roc_path _roc_sha || [ -n "${_roc_name:-}" ]; do
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
  _dc_ledger=$(commands_ledger_path)
  if ! commands_ledger_validate "$_dc_ledger"; then
    printf '  FAIL: invalid command ledger: %s\n' "$_dc_ledger"
    _status=1
    return 0
  fi
  if ! _dc_want=$(release_commands "$1"); then
    printf '  FAIL: cannot read valid command declarations from the active release\n'
    _status=1
    return 0
  fi
  [ -n "$_dc_want" ] || return 0
  _dc_bin=$(commands_bin_dir) || {
    printf '  FAIL: cannot resolve the command directory\n'
    _status=1
    return 0
  }
  if [ ! -e "$_dc_ledger" ]; then
    printf '  info: release commands are not published (installed without integration): %s\n' "$_dc_want"
    unset _dc_want _dc_bin _dc_ledger
    return 0
  fi
  _dc_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  for _dc_name in $_dc_want; do
    _dc_path="$_dc_bin/$_dc_name"
    # The path goes through the environment, not -v: an awk -v assignment is
    # a string literal in the program text, so a command directory whose name
    # contains a newline would be a syntax error ("newline in string").
    _dc_sha=$(VALISE_LEDGER_NAME="$_dc_name" VALISE_LEDGER_PATH="$_dc_path" "$_dc_awk" -F '\t' \
      '$1 == ENVIRON["VALISE_LEDGER_NAME"] && $2 == ENVIRON["VALISE_LEDGER_PATH"] { print $3; exit }' "$_dc_ledger")
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
