# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: lifecycle: the previous-release record and rollback, the install
# transaction, unmanaged integration detection, uninstall, and the install
# preview behind apply --dry-run.
# Sourced by bin/valise; not executable on its own.

_prev_tmp=""
_dry_tmp=""
_un_tmp=""
_install_txn=0
_txn_old_target=""
_txn_had_previous=0
_txn_old_previous=""
_txn_changed=""

# The startup files valise may write a managed block into.
VALISE_STARTUP_NAMES='.profile .bash_profile .bash_login .bashrc .zprofile .zshrc'

previous_record_path() {
  printf '%s\n' "$VALISE_XDG_STATE/previous"
}

# Startup files install created from nothing, one path per line. Uninstall
# deletes such a file when removing the block leaves it empty.
startup_created_path() {
  printf '%s\n' "$VALISE_XDG_STATE/startup-created"
}

fish_hook_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/valise.fish"
}

# release_name_valid <name>: a release directory name valise will act on.
release_name_valid() {
  case "$1" in
  '' | *[!A-Za-z0-9_.-]* | .* | *- | *..*) return 1 ;;
  esac
  return 0
}

# write_previous_record <release-id>
write_previous_record() {
  _wpr_record=$(previous_record_path)
  [ ! -L "$_wpr_record" ] || die "previous-release record must not be a symlink: $_wpr_record"
  _wpr_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_wpr_mkdir" -p "$VALISE_XDG_STATE" || die "cannot create state directory: $VALISE_XDG_STATE"
  _prev_tmp=$(trusted_mktemp_at "$VALISE_XDG_STATE" file "$VALISE_XDG_STATE/.previous.XXXXXX") ||
    die "cannot create previous-release staging file"
  printf '%s\n' "$1" >"$_prev_tmp" || die "cannot write previous-release record"
  _wpr_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_wpr_chmod" 0644 "$_prev_tmp" || die "cannot set previous-release record mode"
  _wpr_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_wpr_mv" -f "$_prev_tmp" "$_wpr_record" || die "cannot publish previous-release record"
  _prev_tmp=""
  unset _wpr_record _wpr_mkdir _wpr_chmod _wpr_mv
}

# read_previous_record: print the recorded previous release, or fail.
read_previous_record() {
  _rpr_record=$(previous_record_path)
  [ -f "$_rpr_record" ] && [ ! -L "$_rpr_record" ] || return 1
  IFS= read -r _rpr_id <"$_rpr_record" || [ -n "${_rpr_id:-}" ] || return 1
  release_name_valid "$_rpr_id" || return 1
  printf '%s\n' "$_rpr_id"
}

# note_switch <old-target> <new-target>
# Record the release the active link named before a switch, when it named an
# installed release and the switch changed it.
note_switch() {
  [ -n "$1" ] && [ "$1" != "$2" ] || return 0
  case "$1" in
  "$VALISE_RELEASES_DIR"/*) _ns_id=${1#"$VALISE_RELEASES_DIR"/} ;;
  *) return 0 ;;
  esac
  case "$_ns_id" in */*) unset _ns_id; return 0 ;; esac
  release_name_valid "$_ns_id" || { unset _ns_id; return 0; }
  write_previous_record "$_ns_id"
  unset _ns_id
}

# release_activate <release-id>
# Verify an installed release, make it active, and move the command stubs to
# it when install published them. Used by release use and release rollback.
release_activate() {
  _ra_id=$1
  release_name_valid "$_ra_id" || die "invalid release name: $_ra_id"
  _ra_dir="$VALISE_RELEASES_DIR/$_ra_id"
  [ -e "$_ra_dir" ] || die "release not found: $_ra_id"
  [ -d "$_ra_dir" ] || die "release target is not a directory: $_ra_id"
  [ ! -L "$_ra_dir" ] || die "release target must not be a symlink: $_ra_id"
  _ra_root=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) || die "release root unavailable"
  _ra_parent=$(cd "$(path_parent "$_ra_dir")" 2>/dev/null && pwd -P) || die "release target parent unavailable"
  case "$_ra_parent/" in
  "$_ra_root/"*) : ;;
  *) die "release target escapes release root: $_ra_id" ;;
  esac
  _ra_manifest="$_ra_dir/.valise-manifest"
  [ -f "$_ra_manifest" ] && [ ! -L "$_ra_manifest" ] ||
    die "release manifest snapshot is missing or not a regular file: $_ra_id"
  prepare_manifest_rows "$_ra_manifest" || die "cannot snapshot the release manifest"
  validate_manifest "$_manifest_rows" || die "invalid release manifest snapshot"
  verify_release_dir "$_ra_dir" "$_manifest_rows" "$_ra_id"
  release_commands "$_ra_dir" >/dev/null || die "release $_ra_id lists an invalid command name"
  _ra_config_parent=$(path_parent "$VALISE_ACTIVE_LINK")
  if [ ! -d "$_ra_config_parent" ]; then
    _ra_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
    "$_ra_mkdir" -p "$_ra_config_parent" || die "cannot create $_ra_config_parent"
  fi
  acquire_lock
  switch_active_link "$_ra_dir"
  # Commands follow the active release only where install published them: a
  # ledger exists once an install ran with integration.
  if [ -f "$(commands_ledger_path)" ]; then
    reconcile_commands "$_ra_dir"
  fi
  release_lock
  unset _ra_id _ra_dir _ra_root _ra_parent _ra_manifest _ra_config_parent _ra_mkdir
}

cmd_release_rollback() {
  case "${1:-}" in
  --help | -h) usage_release; return 0 ;;
  '') ;;
  *) die "unknown release rollback option: $1" ;;
  esac
  _rr_id=$(read_previous_record) ||
    die "no previous release is recorded (one is recorded each time the active release changes)"
  release_activate "$_rr_id"
  info "rolled back to release $_rr_id"
  unset _rr_id
}

# --- Install transaction ---

# install_txn_begin: remember what an install may have to restore.
install_txn_begin() {
  _txn_old_target=
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _txn_old_target=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null || :)
  fi
  _txn_had_previous=0
  _txn_old_previous=
  if _txn_old_previous=$(read_previous_record); then
    _txn_had_previous=1
  fi
  _txn_changed=
}

# install_txn_abort: run from the exit and signal handlers while an install
# that has switched the active link is unfinished. Puts the previous active
# release back and says what had already changed. It must not call die.
install_txn_abort() {
  _install_txn=0
  _ita_ln=$(trusted_utility_path ln 2>/dev/null || :)
  _ita_rm=$(trusted_utility_path rm 2>/dev/null || :)
  if [ -n "$_txn_old_target" ]; then
    if [ -n "$_ita_ln" ] && "$_ita_ln" -sfn "$_txn_old_target" "$VALISE_ACTIVE_LINK" 2>/dev/null; then
      printf 'valise: install failed; the active release is back to %s\n' "${_txn_old_target##*/}" >&2
    else
      printf 'valise: install failed and the previous active release could not be restored: %s\n' "$_txn_old_target" >&2
    fi
  else
    if [ -n "$_ita_rm" ] && "$_ita_rm" -f "$VALISE_ACTIVE_LINK" 2>/dev/null; then
      printf 'valise: install failed; no release is active, as before the install\n' >&2
    else
      printf 'valise: install failed and the new active link could not be removed: %s\n' "$VALISE_ACTIVE_LINK" >&2
    fi
  fi
  if [ "$_txn_had_previous" -eq 1 ]; then
    (
      trap '[ -z "${_prev_tmp:-}" ] || [ -z "$_ita_rm" ] || "$_ita_rm" -f "$_prev_tmp"' EXIT
      write_previous_record "$_txn_old_previous"
    ) >/dev/null 2>&1 ||
      printf 'valise: cannot restore the previous-release record\n' >&2
  elif [ -n "$_ita_rm" ]; then
    "$_ita_rm" -f "$(previous_record_path)" 2>/dev/null || :
  fi
  # The subshells remove their own staging files: a die inside them exits
  # the subshell, and this process's lock handler never saw those names.
  if [ -f "$(commands_ledger_path)" ]; then
    if [ -n "$_txn_old_target" ] && [ -d "$_txn_old_target" ]; then
      (
        trap 'for _t in "${_rc_tmp:-}" "${_rc_stub:-}" "${_rc_pub:-}"; do [ -z "$_t" ] || [ -z "$_ita_rm" ] || "$_ita_rm" -f "$_t"; done' EXIT
        reconcile_commands "$_txn_old_target"
      ) >/dev/null 2>&1 ||
        printf 'valise: cannot move the command stubs back to the restored release\n' >&2
    elif [ -z "$_txn_old_target" ]; then
      # No release was active before, so no stub may point at one now.
      (remove_owned_commands) >/dev/null 2>&1 ||
        printf 'valise: cannot remove the command stubs this install published\n' >&2
    fi
  fi
  if [ -n "$_txn_changed" ]; then
    printf 'valise: already updated (they load whichever release is active):%s\n' "$_txn_changed" >&2
  fi
  unset _ita_ln _ita_rm
}

# The line a managed block carries when install appended it to a file whose
# last line had no newline.
VALISE_NONL_NOTE='# valise: the line before this block had no trailing newline'

# --- Integration checks ---

# integration_preflight: fail before anything changes when install could not
# write the integration it is about to write.
integration_preflight() {
  if [ -n "${HOME:-}" ]; then
    _ipf_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
    _ipf_targets=$(posix_startup_targets "$_ipf_home")
    while IFS= read -r _ipf_target; do
      [ -n "$_ipf_target" ] || continue
      # A symlinked startup file is left for the user; install only warns.
      [ ! -L "$_ipf_target" ] || continue
      if [ -e "$_ipf_target" ]; then
        [ -f "$_ipf_target" ] || die "startup path is not a regular file: $_ipf_target"
        [ -r "$_ipf_target" ] || die "cannot read startup file: $_ipf_target"
        integration_markers_paired "$_ipf_target" ||
          die "unpaired valise managed block markers in $_ipf_target (restore or remove the BEGIN and END lines, then retry)"
      fi
      _ipf_parent=$(path_parent "$_ipf_target")
      [ -d "$_ipf_parent" ] && [ -w "$_ipf_parent" ] ||
        die "cannot write startup files in $_ipf_parent"
    done <<EOF
$_ipf_targets
EOF
  fi
  if [ -n "$(trusted_utility_path fish 2>/dev/null || :)" ]; then
    _ipf_hook=$(fish_hook_path)
    [ ! -L "$_ipf_hook" ] || die "Fish hook path must not be a symlink: $_ipf_hook"
    [ ! -d "$_ipf_hook" ] || die "Fish hook path is a directory: $_ipf_hook"
    if [ -e "$_ipf_hook" ] && [ ! -f "$_ipf_hook" ]; then
      die "Fish hook path is not a regular file: $_ipf_hook"
    fi
    # The hook directory is created when missing, so the nearest directory
    # that exists must be writable: the hook is staged and renamed there.
    _ipf_dir=$(path_parent "$_ipf_hook")
    while [ ! -e "$_ipf_dir" ] && [ ! -L "$_ipf_dir" ]; do
      _ipf_dir=$(path_parent "$_ipf_dir")
    done
    [ -d "$_ipf_dir" ] || die "Fish hook directory is not a directory: $_ipf_dir"
    [ -w "$_ipf_dir" ] || die "cannot write the Fish hook in $_ipf_dir"
  fi
  unset _ipf_home _ipf_targets _ipf_target _ipf_parent _ipf_hook _ipf_dir
}

# integration_unmanaged_lines <file>
# Print file:line: text for each line outside a managed block that loads a
# valise release by hand: a reference to the active link, a 0.1 generated
# module list, or a line that sources a compiled plan. Comments are skipped.
integration_unmanaged_lines() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  _iul_awk=$(trusted_utility_path awk) || return 1
  "$_iul_awk" '
    /^# BEGIN valise managed block$/ { inside = 1; next }
    /^# END valise managed block$/ { inside = 0; next }
    inside { next }
    /^[[:space:]]*#/ { next }
    index($0, "valise/active") || index($0, "installed-modules.") ||
      ($0 ~ /(^|[;&|[:space:]])(\.|source)[[:space:]]/ && $0 ~ /plans\/(sh|bash|zsh|ksh)\.sh/) {
      printf "%s:%d: %s\n", FILENAME, NR, $0
    }
  ' "$1"
}

# integration_unmanaged_report: print every unmanaged line in the startup
# files valise knows about; succeed when there are none.
integration_unmanaged_report() {
  [ -n "${HOME:-}" ] || return 0
  _iur_home=$(path_normalize "$HOME") || return 0
  _iur_found=0
  for _iur_name in $VALISE_STARTUP_NAMES; do
    _iur_lines=$(integration_unmanaged_lines "$_iur_home/$_iur_name") || _iur_lines=
    [ -n "$_iur_lines" ] || continue
    printf '%s\n' "$_iur_lines"
    _iur_found=1
  done
  _iur_rc=$_iur_found
  unset _iur_home _iur_found _iur_name _iur_lines
  [ "$_iur_rc" -eq 0 ]
}

# startup_created_add <path>: remember that install created this file.
startup_created_add() {
  _sca_ledger=$(startup_created_path)
  [ ! -L "$_sca_ledger" ] || die "startup ledger must not be a symlink: $_sca_ledger"
  if [ -f "$_sca_ledger" ]; then
    while IFS= read -r _sca_line; do
      if [ "$_sca_line" = "$1" ]; then
        unset _sca_ledger _sca_line
        return 0
      fi
    done <"$_sca_ledger"
  fi
  printf '%s\n' "$1" >>"$_sca_ledger" || die "cannot record created startup file"
  unset _sca_ledger _sca_line
}

startup_created_has() {
  _sch_ledger=$(startup_created_path)
  [ -f "$_sch_ledger" ] && [ ! -L "$_sch_ledger" ] || return 1
  while IFS= read -r _sch_line; do
    [ "$_sch_line" != "$1" ] || { unset _sch_ledger _sch_line; return 0; }
  done <"$_sch_ledger"
  unset _sch_ledger _sch_line
  return 1
}

# --- Uninstall ---

# integration_has_posix_block <file>: the file holds a managed block marker.
integration_has_posix_block() {
  _ihpb_awk=$(trusted_utility_path awk) || return 1
  "$_ihpb_awk" '/^# BEGIN valise managed block$/ { found = 1; exit } END { exit !found }' "$1" 2>/dev/null
}

# uninstall_strip_block <file>: remove the managed block from one startup file,
# keeping every other byte and the file mode. A file install created that is
# left empty is deleted.
uninstall_strip_block() {
  _usb_target=$1
  _usb_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _usb_parent=$(path_parent "$_usb_target")
  _un_tmp=$(trusted_mktemp_at "$_usb_parent" file "$_usb_parent/.valise-uninstall.XXXXXX") ||
    die "cannot create uninstall staging file in $_usb_parent"
  # A block carrying the no-newline note was appended to a last line that
  # had no newline; when nothing follows the block, that newline goes too.
  _VALISE_NOTE=$VALISE_NONL_NOTE "$_usb_awk" '
    /^# BEGIN valise managed block$/ { inblock = 1; next }
    inblock && $0 == ENVIRON["_VALISE_NOTE"] { had_note = 1; next }
    inblock && /^# END valise managed block$/ { inblock = 0; closed = 1; next }
    inblock { next }
    { if (closed) after = 1; line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        if (i == n && had_note && !after) printf "%s", line[i]
        else print line[i]
      }
    }
  ' "$_usb_target" >"$_un_tmp" || die "cannot read startup file: $_usb_target"
  _usb_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  if [ ! -s "$_un_tmp" ] && startup_created_has "$_usb_target"; then
    "$_usb_rm" -f "$_usb_target" || die "cannot remove startup file: $_usb_target"
    "$_usb_rm" -f "$_un_tmp" || die "cannot remove uninstall staging file"
    _un_tmp=""
    info "removed startup file valise created: $_usb_target"
  else
    _usb_mode=$(file_mode "$_usb_target")
    [ -n "$_usb_mode" ] || die "cannot read startup file mode: $_usb_target"
    _usb_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
    "$_usb_chmod" "$_usb_mode" "$_un_tmp" || die "cannot set startup file mode"
    _usb_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
    "$_usb_mv" -f "$_un_tmp" "$_usb_target" || die "cannot rewrite startup file: $_usb_target"
    _un_tmp=""
    info "removed the managed block from $_usb_target"
  fi
  unset _usb_target _usb_awk _usb_parent _usb_rm _usb_mode _usb_chmod _usb_mv
}

cmd_uninstall() {
  _un_keep=0
  for _un_arg do
    case "$_un_arg" in
    --keep-releases) _un_keep=1 ;;
    --help | -h) usage_uninstall; return 0 ;;
    *) die "unknown uninstall option: $_un_arg (usage: valise uninstall [--keep-releases])" ;;
    esac
  done
  _un_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _un_rmdir=$(trusted_utility_path rmdir) || die "no trusted rmdir utility available"
  _un_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_un_mkdir" -p "$VALISE_XDG_STATE" || die "cannot create state directory: $VALISE_XDG_STATE"
  acquire_lock

  _un_home=
  if [ -n "${HOME:-}" ]; then
    _un_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
    # Check every file before changing any, so a damaged block stops the
    # uninstall with nothing removed.
    for _un_name in $VALISE_STARTUP_NAMES; do
      _un_file="$_un_home/$_un_name"
      [ -f "$_un_file" ] && [ ! -L "$_un_file" ] || continue
      integration_markers_paired "$_un_file" ||
        die "unpaired valise managed block markers in $_un_file (restore or remove the BEGIN and END lines, then retry)"
    done
    for _un_name in $VALISE_STARTUP_NAMES; do
      _un_file="$_un_home/$_un_name"
      if [ -L "$_un_file" ]; then
        if [ -f "$_un_file" ] && integration_has_posix_block "$_un_file"; then
          info "warning: $_un_file is a symlink; remove the valise managed block from it yourself"
        fi
        continue
      fi
      [ -f "$_un_file" ] || continue
      integration_has_posix_block "$_un_file" || continue
      uninstall_strip_block "$_un_file"
    done
    _un_hook=$(fish_hook_path)
    if [ -f "$_un_hook" ] && [ ! -L "$_un_hook" ]; then
      IFS= read -r _un_first <"$_un_hook" || :
      if [ "${_un_first:-}" = '# valise Fish integration. Do not edit.' ]; then
        "$_un_rm" -f "$_un_hook" || die "cannot remove the Fish hook: $_un_hook"
        info "removed the Fish hook: $_un_hook"
      else
        info "warning: leaving $_un_hook: it is not the valise Fish hook"
      fi
    elif [ -e "$_un_hook" ] || [ -L "$_un_hook" ]; then
      info "warning: leaving $_un_hook: it is not a regular file"
    fi
    _un_lines=$(integration_unmanaged_report) || {
      info "warning: these lines load valise outside a managed block; remove them yourself:"
      printf '%s\n' "$_un_lines"
    }
  else
    info "warning: HOME is not set; startup files were not checked"
  fi

  remove_owned_commands

  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    "$_un_rm" -f "$VALISE_ACTIVE_LINK" || die "cannot remove the active link: $VALISE_ACTIVE_LINK"
    info "removed the active release link"
  elif [ -e "$VALISE_ACTIVE_LINK" ]; then
    info "warning: leaving $VALISE_ACTIVE_LINK: it is not a symlink"
  fi
  for _un_record in "$(previous_record_path)" "$(startup_created_path)"; do
    if [ -f "$_un_record" ] || [ -L "$_un_record" ]; then
      "$_un_rm" -f "$_un_record" || die "cannot remove $_un_record"
    fi
  done
  if [ "$_un_keep" -eq 0 ]; then
    if [ -d "$VALISE_RELEASES_DIR" ] && [ ! -L "$VALISE_RELEASES_DIR" ]; then
      remove_tree "$VALISE_RELEASES_DIR" || die "cannot remove installed releases: $VALISE_RELEASES_DIR"
      info "removed installed releases"
    fi
    "$_un_rmdir" "$VALISE_XDG_DATA" 2>/dev/null || :
  else
    info "kept installed releases in $VALISE_RELEASES_DIR"
  fi
  "$_un_rmdir" "$VALISE_XDG_CONFIG" 2>/dev/null || :
  release_lock
  "$_un_rmdir" "$VALISE_XDG_STATE" 2>/dev/null || :
  info "valise integration removed; the valise CLI itself is still installed"
  unset _un_keep _un_arg _un_rm _un_rmdir _un_mkdir _un_home _un_name _un_file _un_hook _un_first \
    _un_lines _un_record
}

# --- Install preview ---

# _dry_render_compare <target> <render-command...>
# Print how install would treat one file: current, update, or create.
_dry_render_compare() {
  _drc_target=$1
  shift
  _dry_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-dry-run.XXXXXX") || die "cannot create preview file"
  "$@" >"$_dry_tmp" || die "cannot render $_drc_target"
  _drc_cmp=$(trusted_utility_path cmp) || die "no trusted cmp utility available"
  if [ -f "$_drc_target" ] && "$_drc_cmp" -s "$_dry_tmp" "$_drc_target"; then
    printf '  current: %s\n' "$_drc_target"
  elif [ -e "$_drc_target" ]; then
    printf '  would update: %s\n' "$_drc_target"
  else
    printf '  would create: %s\n' "$_drc_target"
  fi
  _drc_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  "$_drc_rm" -f "$_dry_tmp" || die "cannot remove preview file"
  _dry_tmp=""
  unset _drc_target _drc_cmp _drc_rm
}

# install_preview <integration>
# Describe what valise install would do with the release tree in the current
# directory, writing nothing outside the temporary directory.
install_preview() {
  _ip_integration=$1
  _ip_source=$(locate_manifest) || die "cannot find manifest.tsv in the current directory"
  _ip_root=$(cd "$(path_parent "$_ip_source")" && pwd -P) || die "cannot resolve manifest source root"
  prepare_manifest_rows "$_ip_source" || die "cannot normalize manifest.tsv"
  validate_manifest "$_manifest_rows" || die "invalid manifest.tsv schema or row"
  _ip_id=$(file_sha256 "$_manifest_rows") || die "no trusted SHA-256 utility available"
  printf 'release %s\n' "$_ip_id"
  if [ -d "$VALISE_RELEASES_DIR/$_ip_id" ]; then
    printf '  already installed\n'
  else
    printf '  would install to %s\n' "$VALISE_RELEASES_DIR/$_ip_id"
  fi
  _ip_active=$(active_release_id 2>/dev/null || :)
  if [ "$_ip_active" = "$_ip_id" ]; then
    printf '  already active\n'
  else
    printf '  would become active (now: %s)\n' "${_ip_active:-none}"
  fi
  if [ "$_ip_integration" -eq 0 ]; then
    printf 'integration: skipped (--no-integration)\n'
    unset _ip_integration _ip_source _ip_root _ip_id _ip_active
    return 0
  fi
  printf 'startup files\n'
  if [ -n "${HOME:-}" ]; then
    _ip_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
    _ip_snippet=$(print_posix_integration) || die "cannot generate integration block"
    _ip_targets=$(posix_startup_targets "$_ip_home")
    while IFS= read -r _ip_target; do
      [ -n "$_ip_target" ] || continue
      if [ -L "$_ip_target" ]; then
        printf '  left alone (symlink): %s\n' "$_ip_target"
      elif [ -e "$_ip_target" ] && ! integration_markers_paired "$_ip_target"; then
        printf '  would fail (unpaired markers): %s\n' "$_ip_target"
      else
        _dry_render_compare "$_ip_target" integration_render "$_ip_target" "$_ip_snippet"
      fi
    done <<EOF
$_ip_targets
EOF
    _ip_lines=$(integration_unmanaged_report) ||
      printf '  warning: valise loaded outside a managed block:\n%s\n' "$_ip_lines"
  else
    printf '  none (HOME is not set)\n'
  fi
  if [ -n "$(trusted_utility_path fish 2>/dev/null || :)" ]; then
    _dry_render_compare "$(fish_hook_path)" print_fish_integration
  fi
  printf 'commands\n'
  _ip_any=0
  _ip_want=$(release_commands "$_ip_root") || die "the release lists an invalid command name"
  if _ip_bin=$(commands_bin_dir); then
    _ip_ledger=$(commands_ledger_path)
    _ip_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    if [ -f "$_ip_ledger" ]; then
      while IFS="$(printf '\t')" read -r _ip_name _ip_path _ip_sha; do
        [ -n "$_ip_name" ] || continue
        case " $_ip_want " in *" $_ip_name "*) [ "$_ip_path" != "$_ip_bin/$_ip_name" ] || continue ;; esac
        printf '  would remove: %s\n' "$_ip_path"
        _ip_any=1
      done <"$_ip_ledger"
    fi
    for _ip_name in $_ip_want; do
      _ip_path="$_ip_bin/$_ip_name"
      _ip_sha=
      [ ! -f "$_ip_ledger" ] ||
        _ip_sha=$("$_ip_awk" -F '\t' -v n="$_ip_name" -v p="$_ip_path" '$1 == n && $2 == p { print $3; exit }' "$_ip_ledger")
      if [ -n "$_ip_sha" ] && commands_file_is "$_ip_path" "$_ip_sha"; then
        printf '  current: %s\n' "$_ip_path"
        _ip_any=1
      elif [ -e "$_ip_path" ] || [ -L "$_ip_path" ]; then
        printf '  would skip (exists, not owned by valise): %s\n' "$_ip_path"
        _ip_any=1
      else
        printf '  would publish: %s\n' "$_ip_path"
        _ip_any=1
      fi
    done
  else
    [ -z "$_ip_want" ] || { printf '  none (HOME is not set)\n'; _ip_any=1; }
  fi
  [ "$_ip_any" -eq 1 ] || printf '  none\n'
  unset _ip_integration _ip_source _ip_root _ip_id _ip_active _ip_home _ip_snippet _ip_targets _ip_target \
    _ip_lines _ip_want _ip_bin _ip_ledger _ip_awk _ip_name _ip_path _ip_sha _ip_any
}
