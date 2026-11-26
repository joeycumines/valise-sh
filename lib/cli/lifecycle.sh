# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: lifecycle: the previous-release record and rollback, the install
# transaction, unmanaged integration detection, uninstall, and the install
# preview behind apply --dry-run.
# Sourced by bin/valise; not executable on its own.

_prev_tmp=""
_dry_tmp=""
_un_tmp=""
_transaction_active=0
_transaction_dir=
_transaction_keep=0
_transaction_reported=0
_transaction_restore_tmp=
_txn_changed=""

# The startup files valise may write a managed block into.
VALISE_STARTUP_NAMES='.profile .bash_profile .bash_login .bashrc .zprofile .zshrc .zshenv'

previous_record_path() {
  printf '%s\n' "$VALISE_XDG_STATE/previous"
}

# gui_env_file <mode> [home]: the GUI-session bridge file for a mode.
#   systemd -> $XDG_CONFIG_HOME/environment.d/10-valise.conf
#   launchd -> <home>/Library/LaunchAgents/sh.valise.env.plist
# Both are derived from normalized roots (VALISE_XDG_CONFIG and the caller's
# resolved home), so a relative or trailing-slash XDG_CONFIG_HOME cannot place
# the file somewhere the next run will not look. Passing <home> explicitly lets
# doctor and uninstall report the file for an inspected home rather than the
# caller's.
gui_env_file() {
  _gef_home=${2:-${HOME:-}}
  case "${1:-}" in
  # xdg_child keeps a "/" root from producing "//environment.d/...", which POSIX
  # leaves implementation-defined.
  systemd) xdg_child "$VALISE_XDG_CONFIG_ROOT" environment.d/10-valise.conf ;;
  launchd)
    # Keep a "/" root usable: a trailing slash is only stripped when it does
    # not turn the root into the empty string, and a bare "/" joins with
    # exactly one separator (a leading "//" is implementation-defined).
    while [ "${#_gef_home}" -gt 1 ] && [ "${_gef_home%/}" != "$_gef_home" ]; do
      _gef_home=${_gef_home%/}
    done
    [ -n "$_gef_home" ] || { unset _gef_home; return 1; }
    printf '%s\n' "${_gef_home%/}/Library/LaunchAgents/sh.valise.env.plist"
    ;;
  *) unset _gef_home; return 1 ;;
  esac
  unset _gef_home
}

# bridge_is_valise_owned <mode> <file>: true when the bridge file carries the
# valise ownership marker. Both the write path (before replacing) and the
# uninstall path (before removing) use it, so a user-owned file at the bridge
# path is never overwritten or deleted. The comparison is an exact LINE match
# through the trusted awk: piping head/sed into grep would resolve those from
# the caller's PATH, and a forged one could make uninstall delete a foreign
# file.
bridge_is_valise_owned() {
  [ -f "${2:-}" ] && [ ! -L "${2:-}" ] || return 1
  _bivo_awk=$(trusted_utility_path awk) || return 1
  _bivo_marker=
  case "${1:-}" in
  systemd) _bivo_marker='# written by valise (gui_env=systemd); do not edit' ;;
  launchd) _bivo_marker='<!-- written by valise (gui_env=launchd); do not edit -->' ;;
  *) unset _bivo_awk _bivo_marker; return 1 ;;
  esac
  # The marker is line 1 (environment.d) or line 2 (below the XML declaration).
  # Reading the whole file and comparing exact lines keeps this independent of
  # head/sed, and the early exit keeps it cheap.
  _bivo_marker=$_bivo_marker "$_bivo_awk" '
    NR > 2 { exit }
    $0 == ENVIRON["_bivo_marker"] { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "${2:-}" 2>/dev/null
  _bivo_rc=$?
  unset _bivo_awk _bivo_marker
  return "$_bivo_rc"
}

# gui_env_mode <release-dir>: print the gui_env a release was built with.
# The mode is recorded in valise-release.conf at build time, so a release built
# in one place and installed from another still carries it. A release built
# before the key existed reads as off.
gui_env_mode() {
  _gem_mode=$(release_conf_value "${1:-}" gui_env 2>/dev/null) || _gem_mode=off
  [ -n "$_gem_mode" ] || _gem_mode=off
  printf '%s\n' "$_gem_mode"
  unset _gem_mode
}

# gui_env_bridge_format <mode>
# The env_export_emit format for a configured mode. The configuration calls the
# systemd bridge "systemd"; the renderer's vocabulary is "environment.d".
# Passing the configured value straight to the renderer made EVERY automatic
# systemd bridge fail to render, so install reported a bridge it never wrote.
gui_env_bridge_format() {
  case "${1:-}" in
  systemd) printf '%s\n' environment.d ;;
  launchd) printf '%s\n' launchd ;;
  *) return 1 ;;
  esac
}

# gui_env_bridge_shell: the shell class whose env plan the bridge is built from.
# Every caller must use this one mapping: `valise env export` and the automatic
# bridge used different shells, so a dry run could promise bytes install would
# never write.
gui_env_bridge_shell() {
  case "${SHELL:-}" in
  */zsh | zsh) printf '%s\n' zsh ;;
  */ksh | ksh) printf '%s\n' ksh ;;
  */bash | bash) printf '%s\n' bash ;;
  *) printf '%s\n' sh ;;
  esac
}

# Keep failed-cleanup staging names registered for central EXIT cleanup. These
# files can contain environment secrets and must never be silently forgotten.
gui_env_stage_discard() {
  [ -n "${_gui_stage:-}" ] || return 0
  _gsd_rm=$(trusted_utility_path rm 2>/dev/null || :)
  [ -z "$_gsd_rm" ] || "$_gsd_rm" -f "$_gui_stage" 2>/dev/null || :
  if [ -e "$_gui_stage" ] || [ -L "$_gui_stage" ]; then
    printf 'valise: error: GUI environment staging file preserved at %s\n' "$_gui_stage" >&2
    _cleanup_failed=1
    return 1
  fi
  _gui_stage=
}

# gui_env_bridge_stage <release-dir>
# Prepare the GUI-session bridge the release declares, WITHOUT changing anything
# a user can observe. Sets:
#   _gui_action  publish | remove | none
#   _gui_mode    the configured mode, for the ownership marker
#   _gui_target  the bridge path
#   _gui_stage   the rendered file to publish (publish only)
#
# Returns nonzero when the bridge could not be prepared. The caller runs this
# BEFORE the active link changes, so a capture or render failure leaves the
# outgoing release AND its bridge in place and consistent instead of switching
# the release and silently keeping the old bridge.
gui_env_bridge_stage() {
  gui_env_stage_discard || return 1
  _gbs_release=${1:-}
  _gui_action=none
  _gui_mode=
  _gui_target=
  _gui_stage=
  _gbs_mode=off
  if [ -n "$_gbs_release" ] && [ -d "$_gbs_release" ]; then
    _gbs_mode=$(gui_env_mode "$_gbs_release")
  fi
  case "$_gbs_mode" in
  off)
    # A previous release may have written a bridge; the incoming release wants
    # none, so a valise-owned file must not outlive the switch.
    _gui_action=remove
    unset _gbs_release _gbs_mode
    return 0
    ;;
  systemd)
    if [ "$(cli_os_name)" != linux ]; then
      # A bridge an earlier release wrote must not survive the switch: this
      # platform can never replace it, so the owned file would keep describing
      # the previous release wherever it IS read.
      info "gui_env=systemd but the platform is not Linux; a valise-owned environment.d bridge is removed instead"
      _gui_action=remove
      unset _gbs_release _gbs_mode
      return 0
    fi
    ;;
  launchd)
    if [ "$(cli_os_name)" != darwin ]; then
      info "gui_env=launchd but the platform is not macOS; a valise-owned LaunchAgent bridge is removed instead"
      _gui_action=remove
      unset _gbs_release _gbs_mode
      return 0
    fi
    if [ -z "${HOME:-}" ]; then
      info "gui_env=launchd but HOME is unset; skipping the LaunchAgent bridge"
      unset _gbs_release _gbs_mode
      return 0
    fi
    ;;
  *)
    # An unknown value must never abort an install after the active link has
    # already switched. Report it and change nothing.
    info "warning: gui_env=$_gbs_mode is not off, systemd, or launchd; skipping the GUI env bridge"
    unset _gbs_release _gbs_mode
    return 0
    ;;
  esac
  _gui_mode=$_gbs_mode
  if ! _gui_target=$(gui_env_file "$_gui_mode"); then
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode
    return 1
  fi
  # Never clobber a user-owned file at the bridge path. A symlink is reported
  # and left alone, like every other managed path.
  if [ -L "$_gui_target" ]; then
    info "warning: leaving $_gui_target: it is a symlink"
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode
    return 0
  fi
  if [ -e "$_gui_target" ] && ! bridge_is_valise_owned "$_gui_mode" "$_gui_target"; then
    info "warning: leaving $_gui_target: it is not the valise GUI env bridge"
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode
    return 0
  fi
  _gbs_shell=$(gui_env_bridge_shell)
  if ! _gbs_capture=$(env_export_capture "$_gbs_shell" "$_gbs_release"); then
    printf 'valise: error: cannot capture the env plan for shell %s; the GUI env bridge was not written\n' \
      "$_gbs_shell" >&2
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell
    return 1
  fi
  if ! _gbs_format=$(gui_env_bridge_format "$_gui_mode"); then
    printf 'valise: error: no renderer for gui_env=%s\n' "$_gui_mode" >&2
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture
    return 1
  fi
  _gbs_parent=$(path_parent "$_gui_target")
  if ! _gbs_mkdir=$(trusted_utility_path mkdir); then
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent
    return 1
  fi
  if [ ! -d "$_gbs_parent" ]; then
    # mkdir -p fails when the path exists as a regular file; report it as
    # valise's own diagnostic rather than passing through the tool's message.
    if ! "$_gbs_mkdir" -p "$_gbs_parent" 2>/dev/null; then
      printf 'valise: error: cannot create the GUI env bridge directory: %s\n' "$_gbs_parent" >&2
      _gui_mode= _gui_target=
      unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
      return 1
    fi
  fi
  # Publish into the canonical parent path so a symlinked parent directory
  # cannot strand the staging file, and the mv renames within one filesystem.
  _gbs_parent=$(cd "$_gbs_parent" 2>/dev/null && pwd -P) || {
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
    return 1
  }
  _gui_target="$_gbs_parent/${_gui_target##*/}"
  trusted_mktemp_assign _gui_stage file "$_gbs_parent/.valise-gui.XXXXXX" "$_gbs_parent" || {
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
    return 1
  }
  if ! env_export_emit "$_gbs_format" "$_gbs_capture" >"$_gui_stage"; then
    gui_env_stage_discard || :
    _gui_mode= _gui_target=
    printf 'valise: error: cannot render the %s GUI env bridge\n' "$_gbs_mode" >&2
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir _gbs_rm
    return 1
  fi
  _gbs_chmod=$(trusted_utility_path chmod) || {
    gui_env_stage_discard || :
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
    return 1
  }
  # The bridge holds values the env plan exports, and the module ABI allows a
  # local-secret module to export a secret read from a protected file. An
  # explicit 0644 would publish that value world-readable over a restrictive
  # umask, so the bridge is owner-only.
  if ! "$_gbs_chmod" 0600 "$_gui_stage"; then
    gui_env_stage_discard || :
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir _gbs_chmod _gbs_rm
    return 1
  fi
  _gui_action=publish
  unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir _gbs_chmod _gbs_rm
}

# gui_env_bridge_publish: apply what gui_env_bridge_stage prepared. Runs AFTER
# the active link names the incoming release. Returns nonzero when the bridge
# could not be published, so the caller can roll the activation back instead of
# leaving the active release and the bridge describing different releases.
gui_env_bridge_publish() {
  case "${_gui_action:-none}" in
  none)
    return 0
    ;;
  remove)
    _gbp_rc=0
    remove_gui_env_bridge || _gbp_rc=$?
    _gui_action=none
    _gui_mode= _gui_target=
    unset _gbp_mv _gbp_rm _gbp_mode _gbp_target
    # Exit 2 means Phase 1 removed every public bridge file (committed) and
    # only post-commit deletion of a .valise-remove.* backup failed. Rolling
    # back the active release would be inconsistent because earlier backups
    # may already have been deleted.
    if [ "$_gbp_rc" -eq 2 ]; then _cleanup_failed=1; return 0; fi
    return "$_gbp_rc"
    ;;
  publish)
    _gbp_mv=$(trusted_utility_path mv) || return 1
    _gbp_rc=0
    "$_gbp_mv" -f "$_gui_stage" "$_gui_target" || _gbp_rc=1
    if [ "$_gbp_rc" -eq 0 ]; then
      _gui_stage=
      info "GUI env bridge written ($_gui_mode): $_gui_target"
    else
      # A failed publish must not leave the 0600 staging file (it can hold
      # values read from protected files) in the bridge directory.
      gui_env_stage_discard || :
    fi
    _gui_action=none
    _gui_mode= _gui_target=
    unset _gbp_mv _gbp_rm _gbp_mode _gbp_target
    return "$_gbp_rc"
    ;;
  esac
  _gui_action=none
  return 1
}

# write_gui_env_bridge <release-dir>: stage and publish in one step, for a
# caller that has already established the release should be the active one.
write_gui_env_bridge() {
  gui_env_bridge_stage "${1:-}" || return 1
  gui_env_bridge_publish
}


# _rgb_candidate <mode> <file>: 0 when <file> is a regular, valise-owned bridge
# that may be removed. A symlink or a user-owned file is reported and left alone.
_rgb_candidate() {
  if [ -L "$2" ]; then
    info "warning: leaving $2: it is a symlink"
    return 1
  fi
  [ -f "$2" ] || return 1
  if bridge_is_valise_owned "$1" "$2"; then
    return 0
  fi
  info "warning: leaving $2: it is not the valise GUI env bridge"
  return 1
}

# Restore an aside only when it still contains the owned bytes we moved. A
# failed rename leaves mktemp's empty placeholder, which must never replace the
# original bridge. Every surviving aside is reported explicitly.
_rgb_restore_aside() {
  _rra_path=$1 _rra_aside=$2 _rra_sha=$3
  [ -n "$_rra_aside" ] || return 0
  if commands_file_is "$_rra_aside" "$_rra_sha"; then
    if [ ! -e "$_rra_path" ] && [ ! -L "$_rra_path" ] || commands_file_is "$_rra_path" "$_rra_sha"; then
      "$_rgb_mv" -f "$_rra_aside" "$_rra_path" 2>/dev/null || :
      if commands_file_is "$_rra_path" "$_rra_sha" && [ ! -e "$_rra_aside" ]; then return 0; fi
    fi
  elif [ -f "$_rra_aside" ] && [ ! -L "$_rra_aside" ] && [ ! -s "$_rra_aside" ] &&
    commands_file_is "$_rra_path" "$_rra_sha"; then
    "$_rgb_rm" -f "$_rra_aside" 2>/dev/null || :
    [ -e "$_rra_aside" ] || [ -L "$_rra_aside" ] || return 0
  fi
  printf 'valise: error: GUI bridge recovery file preserved at %s\n' "$_rra_aside" >&2
  _cleanup_failed=1
  return 1
}

# Remove the owned bridge set in two phases. Record every aside before moving
# its file, and defer signals until either all renames are restored or deletion
# is committed. Phase-2 failure returns 2: the public removal remains committed.
remove_gui_env_bridge() {
  _rgb_rm=$(trusted_utility_path rm) || return 1
  _rgb_mv=$(trusted_utility_path mv) || return 1
  _rgb_signals_before=$_signals_deferred
  _signals_deferred=1
  _rgb_sys= _rgb_lad= _rgb_sys_aside= _rgb_lad_aside= _rgb_sys_sha= _rgb_lad_sha=
  _rgb_rc=0
  for _rgb_mode in systemd launchd; do
    _rgb_path=$(gui_env_file "$_rgb_mode" 2>/dev/null) || continue
    _rgb_candidate "$_rgb_mode" "$_rgb_path" || continue
    _rgb_sha=$(file_sha256 "$_rgb_path") || { _rgb_rc=1; break; }
    _rgb_parent=$(path_parent "$_rgb_path")
    trusted_mktemp_assign _rgb_aside file "$_rgb_parent/.valise-remove.XXXXXX" "$_rgb_parent" || {
      printf 'valise: error: cannot create a staging name for the %s GUI env bridge: %s\n' "$_rgb_mode" "$_rgb_path" >&2
      _rgb_rc=1
      break
    }
    case $_rgb_mode in
      systemd) _rgb_sys=$_rgb_path _rgb_sys_aside=$_rgb_aside _rgb_sys_sha=$_rgb_sha ;;
      launchd) _rgb_lad=$_rgb_path _rgb_lad_aside=$_rgb_aside _rgb_lad_sha=$_rgb_sha ;;
    esac
    "$_rgb_mv" -f "$_rgb_path" "$_rgb_aside" 2>/dev/null || :
    if [ -e "$_rgb_path" ] || [ -L "$_rgb_path" ] || ! commands_file_is "$_rgb_aside" "$_rgb_sha"; then
      printf 'valise: error: cannot remove the %s GUI env bridge: %s\n' "$_rgb_mode" "$_rgb_path" >&2
      _rgb_rc=1
      break
    fi
    if [ -n "$_pending_signal" ]; then _rgb_rc=1; break; fi
  done
  if [ "$_rgb_rc" -ne 0 ]; then
    run_ignoring_int_term _rgb_restore_aside "$_rgb_sys" "$_rgb_sys_aside" "$_rgb_sys_sha" || _cleanup_failed=1
    run_ignoring_int_term _rgb_restore_aside "$_rgb_lad" "$_rgb_lad_aside" "$_rgb_lad_sha" || _cleanup_failed=1
  else
    # All public names have gone. Never roll this set back after deleting one
    # of the copies: finish cleanup even if INT/TERM arrives during deletion.
    for _rgb_aside in "$_rgb_sys_aside" "$_rgb_lad_aside"; do
      [ -n "$_rgb_aside" ] || continue
      run_ignoring_int_term "$_rgb_rm" -f "$_rgb_aside" 2>/dev/null || :
      if [ -e "$_rgb_aside" ] || [ -L "$_rgb_aside" ]; then
        printf 'valise: error: GUI bridge cleanup file preserved at %s\n' "$_rgb_aside" >&2
        _rgb_rc=2
      fi
    done
    [ -z "$_rgb_sys" ] || info "removed the systemd bridge: $_rgb_sys"
    [ -z "$_rgb_lad" ] || info "removed the launchd bridge: $_rgb_lad"
  fi
  _signals_deferred=$_rgb_signals_before
  if [ "$_signals_deferred" -eq 0 ] && [ -n "$_pending_signal" ]; then exit "$_pending_signal"; fi
  unset _rgb_rm _rgb_mv _rgb_sys _rgb_lad _rgb_sys_aside _rgb_lad_aside _rgb_sys_sha _rgb_lad_sha \
    _rgb_mode _rgb_path _rgb_sha _rgb_parent _rgb_aside _rgb_signals_before _rra_path _rra_aside _rra_sha
  return "$_rgb_rc"
}


# Startup files install created from nothing, one path per line. Uninstall
# deletes such a file when removing the block leaves it empty.
startup_created_path() {
  printf '%s\n' "$VALISE_XDG_STATE/startup-created"
}

# integration_record_path: written by an install that wrote the shell
# integration. It is the signal `release use`/`rollback` consult before
# refreshing the GUI env bridge: an install with --no-integration promises to
# write no startup file, shim, Fish hook, bridge, or command stubs, and a later
# release switch must not quietly break that promise.
integration_record_path() {
  printf '%s\n' "$VALISE_XDG_STATE/integration"
}

integration_installed() {
  [ -f "$(integration_record_path)" ] && [ ! -L "$(integration_record_path)" ] && return 0
  # An install made before the record existed still wrote the integration, so a
  # managed block in a startup file (or a created-file ledger) is equally valid
  # evidence. Without this an upgrade would silently stop refreshing the bridge.
  _ii_home=
  [ -z "${HOME:-}" ] || _ii_home=$(path_normalize "$HOME" 2>/dev/null || :)
  if [ -n "$_ii_home" ]; then
    for _ii_name in $VALISE_STARTUP_NAMES; do
      if [ -f "$_ii_home/$_ii_name" ] && [ ! -L "$_ii_home/$_ii_name" ] &&
        integration_has_managed_block "$_ii_home/$_ii_name" 2>/dev/null; then
        unset _ii_home _ii_name
        return 0
      fi
    done
    if _ii_shim=$(env_shim_path) && [ -f "$_ii_shim" ] &&
      integration_has_managed_block "$_ii_shim" 2>/dev/null; then
      unset _ii_home _ii_name _ii_shim
      return 0
    fi
  fi
  if [ -f "$(commands_ledger_path)" ]; then
    unset _ii_home _ii_name _ii_shim
    return 0
  fi
  unset _ii_home _ii_name _ii_shim
  return 1
}

# record_integration_installed: mark that an install wrote the shell
# integration, so a later `release use` may refresh the GUI env bridge. Written
# atomically and registered with release_lock.
record_integration_installed() {
  _rii_record=$(integration_record_path)
  [ ! -L "$_rii_record" ] || die "integration record must not be a symlink: $_rii_record"
  _rii_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_rii_mkdir" -p "$VALISE_XDG_STATE" || die "cannot create state directory: $VALISE_XDG_STATE"
  trusted_mktemp_assign _rii_tmp file "$VALISE_XDG_STATE/.integration.XXXXXX" "$VALISE_XDG_STATE" ||
    die "cannot create integration record staging file"
  _rii_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  printf '%s\n' 'valise integration installed' >"$_rii_tmp" &&
    "$_rii_chmod" 0644 "$_rii_tmp" || {
    _rii_rm=$(trusted_utility_path rm 2>/dev/null || :)
    [ -z "$_rii_rm" ] || "$_rii_rm" -f "$_rii_tmp" 2>/dev/null || :
    die "cannot write the integration record"
  }
  _rii_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_rii_mv" -f "$_rii_tmp" "$_rii_record" || die "cannot publish the integration record"
  _rii_tmp=
  unset _rii_record _rii_mkdir _rii_chmod _rii_mv _rii_rm
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
  trusted_mktemp_assign _prev_tmp file "$VALISE_XDG_STATE/.previous.XXXXXX" "$VALISE_XDG_STATE" ||
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
  if [ -L "$_rpr_record" ]; then
    printf 'valise: error: previous-release record must not be a symlink: %s\n' "$_rpr_record" >&2
    return 1
  fi
  [ -f "$_rpr_record" ] && [ -r "$_rpr_record" ] || return 1
  _rpr_cat=$(trusted_utility_path cat) || return 1
  _rpr_id=$("$_rpr_cat" "$_rpr_record" && printf '.') || return 1
  _rpr_id=${_rpr_id%.}
  _rpr_nl='
'
  _rpr_id=${_rpr_id%"$_rpr_nl"}
  release_name_valid "$_rpr_id" || return 1
  printf '%s\n' "$_rpr_id"
}

# note_switch <old-target> <new-target>
# Record the release the active link named before a switch, when it named an
# installed release and the switch changed it.
note_switch() {
  [ -n "$1" ] && [ "$1" != "$2" ] || return 0
  _ns_old=$1
  _ns_root=$VALISE_RELEASES_DIR
  if [ "${_transaction_active:-0}" -eq 1 ] && [ "$1" = "$_transaction_old_target" ]; then
    _ns_old=$_transaction_old_dir
    _ns_root=$_transaction_store_dir
  fi
  case "$_ns_old" in
  "$_ns_root"/*) _ns_id=${_ns_old#"$_ns_root"/} ;;
  *) return 0 ;;
  esac
  case "$_ns_id" in */*) unset _ns_id; return 0 ;; esac
  release_name_valid "$_ns_id" || { unset _ns_id; return 0; }
  write_previous_record "$_ns_id"
  unset _ns_id _ns_old _ns_root
}

# A transaction holds copies of the state it may change, not references to the
# outgoing release. An unreadable/deleted outgoing manifest therefore cannot
# turn recovery into an empty command set. Signals are deferred until a complete
# mutation/bookkeeping step, and the one EXIT handler owns final cleanup.
transaction_checkpoint() {
  [ -z "${_pending_signal:-}" ] || exit "$_pending_signal"
}

# Ownership journals are TSV. Reject unrepresentable path fields before any
# live mutation, instead of recording a row that recovery cannot read back.
transaction_record_path_check() {
  _trpc_tab=$(printf '\t')
  _trpc_lf='
'
  case $1 in
    *"$_trpc_tab"*|*"$_trpc_lf"*) die "$2 cannot contain TAB or newline in activation records" ;;
  esac
  unset _trpc_tab _trpc_lf
}

# Use the same physical parent as bridge staging. A lexical alias (for example
# /tmp on macOS) must not make the predecessor and incoming bridge look like
# two different destinations. Preserve newlines so preflight can reject them.
transaction_bridge_path() {
  _tbp_file=$(gui_env_file "$1") || return 1
  _tbp_parent=$(path_parent "$_tbp_file")
  if [ -d "$_tbp_parent" ]; then
    _tbp_parent=$(cd -P "$_tbp_parent" 2>/dev/null && pwd -P && printf '.') || return 1
    _tbp_parent=${_tbp_parent%.}
    _tbp_lf='
'
    _tbp_parent=${_tbp_parent%"$_tbp_lf"}
    _tbp_file=${_tbp_parent%/}/${_tbp_file##*/}
  fi
  printf '%s\n' "$_tbp_file"
}

transaction_preflight() {
  _tp_had_link=0
  _tp_target=
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _tp_had_link=1
    # Keep the literal target, including trailing newlines, for restoration.
    _tp_target=$(readlink_target "$VALISE_ACTIVE_LINK" && printf '.') ||
      die "cannot read active pointer: $VALISE_ACTIVE_LINK"
    _tp_target=${_tp_target%.}
    _tp_nl='
'
    _tp_target=${_tp_target%"$_tp_nl"}
    [ -n "$_tp_target" ] || die "cannot read active pointer: $VALISE_ACTIVE_LINK"
  elif [ -e "$VALISE_ACTIVE_LINK" ]; then
    die "active path exists and is not a symlink: $VALISE_ACTIVE_LINK"
  fi
  _tp_previous=$(previous_record_path)
  if [ -L "$_tp_previous" ]; then
    die "previous-release record must not be a symlink: $_tp_previous"
  elif [ -e "$_tp_previous" ]; then
    [ -f "$_tp_previous" ] && [ -r "$_tp_previous" ] ||
      die "previous-release record must be a readable regular file: $_tp_previous"
    read_previous_record >/dev/null || die "cannot read previous-release record: $_tp_previous"
  fi
  commands_ledger_validate "$(commands_ledger_path)" || die "cannot read command ledger"
  # Inspect the raw setting before commands_bin_dir's printing/capture could
  # strip a trailing newline. Every published stub and staging name shares it.
  transaction_record_path_check "${VALISE_BIN_DIR:-${XDG_BIN_HOME:-${HOME:-}/.local/bin}}" "command directory"
  for _tp_mode in systemd launchd; do
    _tp_bridge=$(transaction_bridge_path "$_tp_mode") || continue
    transaction_record_path_check "$_tp_bridge" "GUI bridge path"
  done
  unset _tp_previous _tp_nl _tp_mode _tp_bridge
}

# transaction_begin <install|release> <commands 0|1> <bridges 0|1>
# Call with the store lock held and the incoming bridge already staged.
transaction_begin() {
  _signals_deferred=1
  transaction_preflight
  _transaction_kind=$1
  _transaction_commands=$2
  _transaction_bridges=$3
  _transaction_had_link=$_tp_had_link
  _transaction_old_target=$_tp_target
  # This identity is only for the successful switch's previous record. Exact
  # rollback uses the literal target even when its directory no longer exists.
  _transaction_old_dir=
  _transaction_store_dir=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) ||
    die "release root unavailable"
  if [ "$_transaction_had_link" -eq 1 ]; then
    _transaction_old_dir=$(cd "$VALISE_ACTIVE_LINK" 2>/dev/null && pwd -P) || _transaction_old_dir=
  fi
  _transaction_commands_started=0
  _transaction_bridge_started=0
  _transaction_keep=0
  _transaction_reported=0
  _transaction_had_previous=0
  _transaction_previous_mode=
  _transaction_ledger_had=0
  _transaction_ledger_mode=
  _txn_changed=
  _tx_cat=$(trusted_utility_path cat) || die "no trusted cat utility available"
  _tx_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _tx_ln=$(trusted_utility_path ln) || die "no trusted ln utility available"
  _tx_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  _tx_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  _tx_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _tx_cmp=$(trusted_utility_path cmp) || die "no trusted cmp utility available"
  trusted_mktemp_assign _transaction_dir dir "$VALISE_XDG_STATE/.transaction.XXXXXX" "$VALISE_XDG_STATE" ||
    die "cannot create activation recovery directory"
  "$_tx_chmod" 0700 "$_transaction_dir" || die "cannot protect activation recovery directory"
  printf '%s' "$_transaction_old_target" >"$_transaction_dir/active-target" || die "cannot snapshot active pointer"
  printf 'kind=%s\nhad_active=%s\n' "$_transaction_kind" "$_transaction_had_link" >"$_transaction_dir/state" ||
    die "cannot snapshot activation state"
  _tb_previous=$(previous_record_path)
  if [ -f "$_tb_previous" ]; then
    _transaction_had_previous=1
    _transaction_previous_mode=$(file_mode "$_tb_previous") || die "cannot read previous-release record mode"
    "$_tx_cat" "$_tb_previous" >"$_transaction_dir/previous" || die "cannot snapshot previous-release record"
  fi
  if [ "$_transaction_commands" -eq 1 ]; then
    commands_txn_snapshot
  fi
  : >"$_transaction_dir/bridges.tsv" || die "cannot snapshot GUI bridges"
  _tb_number=0
  if [ "$_transaction_bridges" -eq 1 ]; then
    for _tb_mode in systemd launchd; do
      _tb_path=$(transaction_bridge_path "$_tb_mode" 2>/dev/null) || continue
      transaction_record_path_check "$_tb_path" "GUI bridge path"
      bridge_is_valise_owned "$_tb_mode" "$_tb_path" || continue
      _tb_number=$((_tb_number + 1))
      _tb_copy=bridge-$_tb_number
      _tb_permissions=$(file_mode "$_tb_path") || die "cannot read GUI bridge mode: $_tb_path"
      _tb_digest=$(file_sha256 "$_tb_path") || die "cannot read GUI bridge: $_tb_path"
      "$_tx_cat" "$_tb_path" >"$_transaction_dir/$_tb_copy" || die "cannot snapshot GUI bridge: $_tb_path"
      [ "$(file_sha256 "$_transaction_dir/$_tb_copy")" = "$_tb_digest" ] ||
        die "GUI bridge changed while being snapshotted: $_tb_path"
      printf '%s\t%s\t%s\t%s\n' "$_tb_path" "$_tb_copy" "$_tb_permissions" "$_tb_digest" >>"$_transaction_dir/bridges.tsv" ||
        die "cannot snapshot GUI bridge ownership"
    done
  fi
  _transaction_gui_target=${_gui_target:-}
  _transaction_gui_digest=
  if [ "${_gui_action:-none}" = publish ]; then
    _transaction_gui_digest=$(file_sha256 "$_gui_stage") || die "cannot read staged GUI bridge"
  fi
  printf 'had_previous=%s\nprevious_mode=%s\nhad_ledger=%s\nledger_mode=%s\n' \
    "$_transaction_had_previous" "$_transaction_previous_mode" "$_transaction_ledger_had" \
    "${_transaction_ledger_mode:-}" >>"$_transaction_dir/state" || die "cannot snapshot activation state"
  transaction_checkpoint
  _transaction_active=1
  unset _tp_had_link _tp_target _tb_previous _tb_number _tb_mode _tb_path _tb_copy _tb_permissions _tb_digest
}

# transaction_restore_file <snapshot> <destination> <mode> [replace|create]
# Recovery never consumes its only backup. Check the resulting bytes as well as
# the utility status: a signal can interrupt a wait after rename already ran.
transaction_restore_file() {
  _trf_source=$1 _trf_target=$2 _trf_mode=$3 _trf_action=${4:-replace}
  [ ! -L "$_trf_target" ] || return 1
  [ ! -e "$_trf_target" ] || [ -f "$_trf_target" ] || return 1
  if [ -f "$_trf_target" ] && "$_tx_cmp" -s "$_trf_source" "$_trf_target" &&
    [ "$(file_mode "$_trf_target")" = "$_trf_mode" ]; then
    return 0
  fi
  _trf_parent=$(path_parent "$_trf_target")
  trusted_mktemp_assign _transaction_restore_tmp file "$_trf_parent/.valise-restore.XXXXXX" "$_trf_parent" || return 1
  if ! "$_tx_cat" "$_trf_source" >"$_transaction_restore_tmp" ||
    ! "$_tx_chmod" "$_trf_mode" "$_transaction_restore_tmp"; then
    transaction_restore_temp_cleanup
    return 1
  fi
  if [ "$_trf_action" = create ]; then
    "$_tx_ln" "$_transaction_restore_tmp" "$_trf_target" 2>/dev/null || :
  else
    "$_tx_mv" -f "$_transaction_restore_tmp" "$_trf_target" 2>/dev/null || :
  fi
  transaction_restore_temp_cleanup
  [ -f "$_trf_target" ] && [ ! -L "$_trf_target" ] &&
    "$_tx_cmp" -s "$_trf_source" "$_trf_target" && [ "$(file_mode "$_trf_target")" = "$_trf_mode" ]
}

transaction_restore_temp_cleanup() {
  "$_tx_rm" -f "$_transaction_restore_tmp" 2>/dev/null || :
  if [ -e "$_transaction_restore_tmp" ] || [ -L "$_transaction_restore_tmp" ]; then
    printf 'valise: error: recovery staging file preserved at %s\n' "$_transaction_restore_tmp" >&2
    _transaction_keep=1
    _cleanup_failed=1
  fi
  # The path was either removed or explicitly named; the source snapshot is
  # retained whenever cleanup failed, so later restores may use this variable.
  _transaction_restore_tmp=
}

transaction_restore_bridges() {
  _trb_status=0
  _trb_tab=$(printf '\t')
  _trb_had_target=0
  while IFS="$_trb_tab" read -r _trb_path _trb_copy _trb_mode _trb_digest; do
    [ -n "$_trb_path" ] || continue
    [ "$_trb_path" != "$_transaction_gui_target" ] || _trb_had_target=1
    if [ -e "$_trb_path" ] || [ -L "$_trb_path" ]; then
      if ! commands_file_is "$_trb_path" "$_trb_digest" &&
        { [ "$_trb_path" != "$_transaction_gui_target" ] ||
          [ -z "$_transaction_gui_digest" ] || ! commands_file_is "$_trb_path" "$_transaction_gui_digest"; }; then
        printf 'valise: error: GUI bridge changed during activation; leaving it: %s\n' "$_trb_path" >&2
        _trb_status=1
        continue
      fi
    fi
    if ! transaction_restore_file "$_transaction_dir/$_trb_copy" "$_trb_path" "$_trb_mode"; then
      printf 'valise: error: cannot restore GUI bridge: %s\n' "$_trb_path" >&2
      _trb_status=1
    fi
  done <"$_transaction_dir/bridges.tsv" || _trb_status=1
  if [ "$_trb_had_target" -eq 0 ] && [ -n "$_transaction_gui_target" ] &&
    { [ -e "$_transaction_gui_target" ] || [ -L "$_transaction_gui_target" ]; }; then
    if [ -n "$_transaction_gui_digest" ] && commands_file_is "$_transaction_gui_target" "$_transaction_gui_digest"; then
      "$_tx_rm" -f "$_transaction_gui_target" 2>/dev/null || :
      if [ -e "$_transaction_gui_target" ] || [ -L "$_transaction_gui_target" ]; then
        printf 'valise: error: cannot remove the newly published GUI bridge: %s\n' "$_transaction_gui_target" >&2
        _trb_status=1
      fi
    else
      printf 'valise: error: GUI bridge changed during activation; leaving it: %s\n' "$_transaction_gui_target" >&2
      _trb_status=1
    fi
  fi
  return "$_trb_status"
}

# Called only by the central EXIT handler. It records errors and returns; it
# never exits or re-enters cleanup when another signal arrives during restore.
transaction_abort() {
  _signals_deferred=1
  _transaction_active=0
  # Only the parent handles signals and owns final cleanup. The worker and its
  # utilities ignore INT/TERM, including a second process-group signal during
  # recovery. Any worker failure retains the parent's original snapshots.
  while :; do
    _ta_worker_status=0
    run_ignoring_int_term transaction_restore || _ta_worker_status=$?
    case $_ta_worker_status in
      0) break ;;
      # A group signal can kill the worker before its first trap instruction.
      # No recovery operation has started then; retry with the same snapshots.
      130|143) continue ;;
      *) _transaction_keep=1; _cleanup_failed=1; break ;;
    esac
  done
}

transaction_restore() {
  _transaction_rolled=0
  if [ "$_transaction_had_link" -eq 1 ]; then
    _ta_current=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null && printf '.') || _ta_current=
    _ta_nl='
'
    _ta_current=${_ta_current%.}
    _ta_current=${_ta_current%"$_ta_nl"}
    if [ ! -L "$VALISE_ACTIVE_LINK" ] || [ "$_ta_current" != "$_transaction_old_target" ]; then
      if [ ! -e "$VALISE_ACTIVE_LINK" ] || [ -L "$VALISE_ACTIVE_LINK" ]; then
        "$_tx_ln" -sfn "$_transaction_old_target" "$VALISE_ACTIVE_LINK" 2>/dev/null || :
      fi
    fi
    _ta_current=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null && printf '.') || _ta_current=
    _ta_current=${_ta_current%.}
    _ta_current=${_ta_current%"$_ta_nl"}
    if [ -L "$VALISE_ACTIVE_LINK" ] && [ "$_ta_current" = "$_transaction_old_target" ]; then
      _transaction_rolled=1
    fi
  else
    # Only a symlink belongs to the switch; never unlink a foreign regular file.
    if [ -L "$VALISE_ACTIVE_LINK" ]; then "$_tx_rm" -f "$VALISE_ACTIVE_LINK" 2>/dev/null || :; fi
    if [ ! -e "$VALISE_ACTIVE_LINK" ] && [ ! -L "$VALISE_ACTIVE_LINK" ]; then _transaction_rolled=1; fi
  fi
  if [ "$_transaction_rolled" -eq 1 ]; then
    _ta_previous=$(previous_record_path)
    if [ "$_transaction_had_previous" -eq 1 ]; then
      if ! transaction_restore_file "$_transaction_dir/previous" "$_ta_previous" "$_transaction_previous_mode"; then
        printf 'valise: error: cannot restore the previous-release record\n' >&2
        _transaction_keep=1
      fi
    elif [ -L "$_ta_previous" ] || { [ -e "$_ta_previous" ] && [ ! -f "$_ta_previous" ]; }; then
      printf 'valise: error: previous-release record changed type during activation; leaving it: %s\n' "$_ta_previous" >&2
      _transaction_keep=1
    else
      "$_tx_rm" -f "$_ta_previous" 2>/dev/null || :
      if [ -e "$_ta_previous" ]; then
        printf 'valise: error: cannot remove the previous-release record\n' >&2
        _transaction_keep=1
      fi
    fi
    if [ "$_transaction_commands_started" -eq 1 ]; then
      commands_txn_restore || _transaction_keep=1
    fi
    if [ "$_transaction_bridge_started" -eq 1 ]; then
      transaction_restore_bridges || _transaction_keep=1
    fi
    if [ "$_transaction_kind" = install ]; then
      if [ "$_transaction_had_link" -eq 1 ]; then
        printf 'valise: install failed; the active release is back to %s\n' "${_transaction_old_target##*/}" >&2
      else
        printf 'valise: install failed; no release is active, as before the install\n' >&2
      fi
    else
      printf 'valise: error: the active release was restored to %s\n' "${_transaction_old_target:-no release}" >&2
    fi
  else
    # Forward reconciliation may have stopped part-way. Do not publish the old
    # bridge or previous record while the link still names the incoming release.
    printf 'valise: error: cannot restore the active link; previous record, command stubs, and GUI bridges were left in their current state\n' >&2
    _transaction_keep=1
  fi
  if [ "$_transaction_kind" = install ] && [ -n "$_txn_changed" ]; then
    printf 'valise: already updated (they load whichever release is active):%s\n' "$_txn_changed" >&2
  fi
  [ "$_transaction_keep" -eq 0 ] || _cleanup_failed=1
  unset _ta_current _ta_nl _ta_previous
  [ "$_transaction_keep" -eq 0 ]
}

# Release the temporary hard links and recovery copies after a successful
# commit/restore. A recovery error preserves the entire directory for inspection.
transaction_cleanup() {
  [ -n "${_transaction_dir:-}" ] || return 0
  if [ "${_transaction_keep:-0}" -eq 0 ]; then
    run_ignoring_int_term commands_txn_discard || { _transaction_keep=1; _cleanup_failed=1; }
  fi
  if [ "${_transaction_keep:-0}" -eq 0 ]; then
    if run_ignoring_int_term "$_tx_rm" -rf "$_transaction_dir" 2>/dev/null && [ ! -e "$_transaction_dir" ]; then
      _transaction_dir=
      return 0
    fi
    _transaction_keep=1
    _cleanup_failed=1
  fi
  if [ "${_transaction_reported:-0}" -eq 0 ]; then
    printf 'valise: error: activation recovery files preserved at %s\n' "$_transaction_dir" >&2
    _transaction_reported=1
  fi
  return 1
}

transaction_commit() {
  transaction_checkpoint
  _transaction_active=0
  transaction_cleanup || :
  transaction_checkpoint
  _signals_deferred=0
}

# release_activate <release-id>: activation and install use the same snapshots,
# restore order and signal policy. There is no private subshell rollback state.
release_activate() {
  _ra_id=$1
  release_name_valid "$_ra_id" || die "invalid release name: $_ra_id"
  # This also protects allocation/result bookkeeping before the state snapshot
  # is armed, including manifest and GUI staging files.
  _signals_deferred=1
  _ra_dir="$VALISE_RELEASES_DIR/$_ra_id"
  [ -d "$_ra_dir" ] && [ ! -L "$_ra_dir" ] || die "release target is not a regular directory: $_ra_id"
  acquire_lock
  transaction_preflight
  _ra_root=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) || die "release root unavailable"
  _ra_parent=$(cd "$(path_parent "$_ra_dir")" 2>/dev/null && pwd -P) || die "release target parent unavailable"
  [ "$_ra_parent" = "$_ra_root" ] || die "release target escapes release root: $_ra_id"
  _ra_manifest="$_ra_dir/.valise-manifest"
  [ -f "$_ra_manifest" ] && [ ! -L "$_ra_manifest" ] || die "release manifest snapshot is missing or not a regular file: $_ra_id"
  prepare_manifest_rows "$_ra_manifest" || die "cannot snapshot the release manifest"
  validate_manifest "$_manifest_rows" || die "invalid release manifest snapshot"
  verify_release_dir "$_ra_dir" "$_manifest_rows" "$_ra_id"
  release_commands "$_ra_dir" >/dev/null || die "release $_ra_id lists invalid commands"
  _ra_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_ra_mkdir" -p "$VALISE_XDG_CONFIG" || die "cannot create configuration directory"
  _ra_commands=0
  [ ! -f "$(commands_ledger_path)" ] || _ra_commands=1
  _ra_bridge=0
  _gui_action=none
  if integration_installed && [ -n "${HOME:-}" ] && [ "$(cli_os_name)" != unknown ]; then
    gui_env_bridge_stage "$_ra_dir" || die "cannot prepare the GUI env bridge for $_ra_id"
    [ "${_gui_action:-none}" = none ] || _ra_bridge=1
  fi
  transaction_checkpoint
  transaction_begin release "$_ra_commands" "$_ra_bridge"
  switch_active_link "$_ra_dir"
  transaction_checkpoint
  if [ "$_ra_bridge" -eq 1 ]; then
    _transaction_bridge_started=1
    gui_env_bridge_publish || die "cannot publish the GUI env bridge for $_ra_id"
    transaction_checkpoint
  fi
  if [ "$_ra_commands" -eq 1 ]; then
    _transaction_commands_started=1
    reconcile_commands "$_ra_dir"
    transaction_checkpoint
  fi
  transaction_commit
  release_lock
  unset _ra_id _ra_dir _ra_root _ra_parent _ra_manifest _ra_mkdir _ra_commands _ra_bridge
}

cmd_release_rollback() {
  case "${1:-}" in
  --help | -h) usage_release; return 0 ;;
  '') ;;
  *) die "unknown release rollback option: $1" ;;
  esac
  acquire_lock
  _rr_id=$(read_previous_record) ||
    die "no previous release is recorded (one is recorded each time the active release changes)"
  release_activate "$_rr_id"
  info "rolled back to release $_rr_id"
  unset _rr_id
}

# The line a managed block carries when install appended it to a file whose
# last line had no newline.
VALISE_NONL_NOTE='# valise: the line before this block had no trailing newline'

# --- Integration checks ---

# preflight_dir_writable <dir> <what>: fail unless <dir>, or the nearest
# ancestor that exists when <dir> does not, is a writable directory. Install
# creates missing directories and stages files beside their targets.
preflight_dir_writable() {
  _pdw_dir=$1
  while [ ! -e "$_pdw_dir" ] && [ ! -L "$_pdw_dir" ]; do
    _pdw_dir=$(path_parent "$_pdw_dir")
  done
  [ -d "$_pdw_dir" ] || die "$2 directory is not a directory: $_pdw_dir"
  [ -w "$_pdw_dir" ] || die "cannot write the $2 in $_pdw_dir"
  unset _pdw_dir
}

# integration_preflight <release-dir>: fail before anything changes when
# install could not write the integration or command stubs it is about to
# write.
integration_preflight() {
  if [ -n "${HOME:-}" ]; then
    _ipf_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
    _ipf_targets=$(posix_startup_targets "$_ipf_home")
    while IFS="$(printf '\t')" read -r _ipf_stage _ipf_target; do
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
    preflight_dir_writable "$(path_parent "$_ipf_hook")" "Fish hook"
  fi
  # Stubs are written when the release publishes commands and removed when a
  # ledger lists stubs this release no longer provides.
  if [ -n "$(release_commands "$1")" ] || [ -f "$(commands_ledger_path)" ]; then
    _ipf_bin=$(commands_bin_dir) || die "cannot resolve the command directory: set HOME or VALISE_BIN_DIR"
    preflight_dir_writable "$_ipf_bin" "command stubs"
  fi
  # The $ENV shim and the GUI env bridge are written into the user's HOME too;
  # a failure there would abort the install after the active link switched, so
  # check them up front with everything else.
  if [ -n "${HOME:-}" ]; then
    if _ipf_shim=$(env_shim_path); then
      # The shim is a managed startup file: install leaves a symlink or a file
      # carrying someone else's content alone and rewrites anything else. So a
      # symlink or a foreign shim can never abort the install, but a regular
      # valise shim must be readable, marker-paired and writable - otherwise
      # the install would abort AFTER the active link moved.
      #
      # The TYPE and READABILITY tests decide FIRST. Testing the block marker
      # first would run awk on the shim and short-circuit on an unreadable file
      # or a directory, making these two checks dead code and letting an
      # unreadable valise shim through to be misreported later as foreign.
      _ipf_shim_writable=0
      if [ -e "$_ipf_shim" ] && [ ! -L "$_ipf_shim" ]; then
        [ -f "$_ipf_shim" ] || die "ENV shim is not a regular file: $_ipf_shim"
        [ -r "$_ipf_shim" ] || die "cannot read the ENV shim: $_ipf_shim"
        # A shim that is not valise's is left alone, so writing it is not
        # attempted and its parent directory need not be writable.
        if integration_has_posix_block "$_ipf_shim" 2>/dev/null; then
          integration_markers_paired "$_ipf_shim" ||
            die "unpaired valise managed block markers in $_ipf_shim (restore or remove the BEGIN and END lines, then retry)"
          _ipf_shim_writable=1
        fi
      else
        # Absent, or a symlink: install will write a fresh file there.
        _ipf_shim_writable=1
      fi
      if [ "$_ipf_shim_writable" -eq 1 ]; then
        preflight_dir_writable "$(path_parent "$_ipf_shim")" "ENV shim"
      fi
    fi
    _ipf_gui_mode=$(gui_env_mode "$1")
    case "$_ipf_gui_mode" in
    systemd | launchd)
      _ipf_gui=$(gui_env_file "$_ipf_gui_mode" 2>/dev/null) || _ipf_gui=
      # The write path (gui_env_bridge_stage) writes systemd only on Linux
      # and launchd only on macOS, so preflight checks the bridge directory
      # only on the platform that will actually write it.
      _ipf_gui_os=
      case "$_ipf_gui_mode" in
      systemd) _ipf_gui_os=linux ;;
      launchd) _ipf_gui_os=darwin ;;
      esac
      if [ -n "$_ipf_gui" ] && [ "$(cli_os_name)" = "$_ipf_gui_os" ]; then
        [ ! -L "$_ipf_gui" ] || :
        preflight_dir_writable "$(path_parent "$_ipf_gui")" "GUI env bridge"
      fi
      ;;
    esac
  fi
  unset _ipf_home _ipf_targets _ipf_target _ipf_stage _ipf_parent _ipf_hook _ipf_bin _ipf_shim _ipf_gui_mode _ipf_gui _ipf_gui_os
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
      ($0 ~ /(^|[;&|[:space:]])(\.|source)[[:space:]]/ && $0 ~ /plans\/(sh|bash|zsh|ksh)(-interactive)?\.sh/) {
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
#
# The file must carry PAIRED markers. The awk below drops everything between a
# BEGIN and the next END, so an unpaired BEGIN would delete every following
# line - a hand-edited or truncated file would lose user content and, because
# the emptied file is often one install created, be removed entirely. cmd_uninstall
# pre-checks the startup files, but the check belongs here too: this function is
# reachable for the ENV shim, and a future caller must not have to know.
uninstall_strip_block() {
  _usb_target=$1
  integration_markers_paired "$_usb_target" ||
    die "unpaired valise managed block markers in $_usb_target (restore or remove the BEGIN and END lines, then retry)"
  _usb_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _usb_parent=$(path_parent "$_usb_target")
  trusted_mktemp_assign _un_tmp file "$_usb_parent/.valise-uninstall.XXXXXX" "$_usb_parent" ||
    die "cannot create uninstall staging file in $_usb_parent"
  # A block carrying the no-newline note was appended to a last line that
  # had no newline; when nothing follows the block, that newline goes too.
  # Text after the block keeps the file's own ending (nonl: no final newline).
  _usb_tail=$(trusted_utility_path tail) || die "no trusted tail utility available"
  _usb_nonl=0
  [ ! -s "$_usb_target" ] || [ -z "$("$_usb_tail" -c 1 "$_usb_target")" ] || _usb_nonl=1
  _VALISE_NOTE=$VALISE_NONL_NOTE "$_usb_awk" -v nonl="$_usb_nonl" '
    /^# BEGIN valise managed block$/ { inblock = 1; next }
    inblock && $0 == ENVIRON["_VALISE_NOTE"] { had_note = 1; next }
    inblock && /^# END valise managed block$/ { inblock = 0; closed = 1; next }
    inblock { next }
    { if (closed) after = 1; line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        if (i == n && ((had_note && !after) || (nonl && after))) printf "%s", line[i]
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
  unset _usb_target _usb_awk _usb_tail _usb_nonl _usb_parent _usb_rm _usb_mode _usb_chmod _usb_mv
}

cmd_uninstall() {
  _un_keep=0
  _un_status=0
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
    # uninstall with nothing removed. The $ENV shim is a managed startup file
    # too, so it belongs in this pre-check: validating it only at strip time
    # would let earlier startup files be rewritten before the damaged shim was
    # discovered, which is exactly the all-or-nothing promise this loop makes.
    for _un_name in $VALISE_STARTUP_NAMES; do
      _un_file="$_un_home/$_un_name"
      [ -f "$_un_file" ] && [ ! -L "$_un_file" ] || continue
      integration_markers_paired "$_un_file" ||
        die "unpaired valise managed block markers in $_un_file (restore or remove the BEGIN and END lines, then retry)"
    done
    if _un_shim_check=$(env_shim_path) &&
      [ -f "$_un_shim_check" ] && [ ! -L "$_un_shim_check" ] &&
      integration_has_posix_block "$_un_shim_check"; then
      # Only a file that carries a BEGIN marker is one uninstall will strip; a
      # foreign shim is reported and left alone below, so it must not be able to
      # abort the uninstall over marker text valise does not own.
      integration_markers_paired "$_un_shim_check" ||
        die "unpaired valise managed block markers in $_un_shim_check (restore or remove the BEGIN and END lines, then retry)"
    fi
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
    # Remove the $ENV shim only when valise owns it. The shim is a managed
    # startup file, so uninstall strips the block and keeps any other bytes the
    # user put there; a shim install created from nothing is deleted when the
    # created-ledger records it.
    if _un_shim=$(env_shim_path); then
      if [ -f "$_un_shim" ] && [ ! -L "$_un_shim" ] &&
        integration_has_posix_block "$_un_shim"; then
        uninstall_strip_block "$_un_shim"
      elif [ -e "$_un_shim" ] || [ -L "$_un_shim" ]; then
        info "warning: leaving $_un_shim: it is not the valise ENV shim"
      fi
    fi
    # Remove the GUI env bridge (environment.d / LaunchAgent) valise wrote.
    # Ownership is the same exact-line marker the write path checks, so a
    # user-owned file at the bridge path is never deleted. A removal failure
    # is reported and does not abort the rest of the uninstall: the startup
    # files are already stripped, and the remaining steps (commands, active
    # link, records, releases) must still run.
    if ! remove_gui_env_bridge; then
      info "warning: the GUI env bridge could not be removed completely; see the errors above"
      _un_status=1
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
  for _un_record in "$(previous_record_path)" "$(startup_created_path)" "$(integration_record_path)"; do
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
  if [ "$_un_status" -ne 0 ]; then
    info "valise integration removed, but not completely; see the warnings above"
    unset _un_keep _un_arg _un_rm _un_rmdir _un_mkdir _un_home _un_name _un_file _un_hook _un_first \
      _un_lines _un_record _un_shim _un_shim_check _un_status
    return 1
  fi
  info "valise integration removed; the valise CLI itself is still installed"
  unset _un_keep _un_arg _un_rm _un_rmdir _un_mkdir _un_home _un_name _un_file _un_hook _un_first \
    _un_lines _un_record _un_shim _un_shim_check _un_status
}

# --- Install preview ---

# _dry_render_compare <target> <render-command...>
# Print how install would treat one file: current, update, or create.
_dry_render_compare() {
  _drc_target=$1
  shift
  trusted_mktemp_assign _dry_tmp file "${TMPDIR:-/tmp}/valise-dry-run.XXXXXX" || die "cannot create preview file"
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
    _ip_targets=$(posix_startup_targets "$_ip_home")
    while IFS="$(printf '\t')" read -r _ip_stage _ip_target; do
      [ -n "$_ip_target" ] || continue
      if [ -L "$_ip_target" ]; then
        printf '  left alone (symlink): %s\n' "$_ip_target"
      elif [ -e "$_ip_target" ] && ! integration_markers_paired "$_ip_target"; then
        printf '  would fail (unpaired markers): %s\n' "$_ip_target"
      elif _ip_snippet=$(print_posix_integration "$_ip_stage"); then
        _dry_render_compare "$_ip_target" integration_render "$_ip_target" "$_ip_snippet"
      else
        printf '  would fail (cannot generate the block): %s\n' "$_ip_target"
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
  # The $ENV shim is a managed startup file, so a dry run must report it too,
  # applying the same rules the write path does: a symlink is left alone, a
  # file without a valise block is left alone, and an unpaired block fails.
  if [ -n "${HOME:-}" ] && _ip_shim=$(env_shim_path); then
    if [ -L "$_ip_shim" ]; then
      printf '  left alone (symlink): %s\n' "$_ip_shim"
    elif [ -e "$_ip_shim" ] && ! integration_has_posix_block "$_ip_shim" 2>/dev/null; then
      printf '  left alone (not the valise ENV shim): %s\n' "$_ip_shim"
    elif [ -e "$_ip_shim" ] && ! integration_markers_paired "$_ip_shim"; then
      printf '  would fail (unpaired markers): %s\n' "$_ip_shim"
    elif _ip_snippet=$(print_posix_integration all); then
      _dry_render_compare "$_ip_shim" integration_render "$_ip_shim" "$_ip_snippet"
    else
      printf '  would fail (cannot generate the block): %s\n' "$_ip_shim"
    fi
  fi
  # The GUI env bridge is derived from the release's gui_env, so a dry run must
  # report whether it would be created, updated, or left alone.
  printf 'gui env bridge\n'
  _ip_gui_mode=$(gui_env_mode "$_ip_root")
  case "$_ip_gui_mode" in
  off)
    # gui_env=off still removes a valise-owned bridge an earlier release wrote,
    # so the preview reports each candidate the removal would delete, and
    # reports a symlink or foreign file at the bridge path as left alone.
    _ip_removed=0
    _ip_sys=$(gui_env_file systemd 2>/dev/null) || _ip_sys=
    _ip_lad=$(gui_env_file launchd 2>/dev/null) || _ip_lad=
    if [ -n "$_ip_sys" ]; then
      if [ -L "$_ip_sys" ]; then
        printf '  left alone (symlink): %s\n' "$_ip_sys"
        _ip_removed=1
      elif [ -f "$_ip_sys" ] && bridge_is_valise_owned systemd "$_ip_sys"; then
        printf '  would remove: %s\n' "$_ip_sys"
        _ip_removed=1
      elif [ -e "$_ip_sys" ]; then
        printf '  left alone (not the valise bridge): %s\n' "$_ip_sys"
        _ip_removed=1
      fi
    fi
    if [ -n "$_ip_lad" ]; then
      if [ -L "$_ip_lad" ]; then
        printf '  left alone (symlink): %s\n' "$_ip_lad"
        _ip_removed=1
      elif [ -f "$_ip_lad" ] && bridge_is_valise_owned launchd "$_ip_lad"; then
        printf '  would remove: %s\n' "$_ip_lad"
        _ip_removed=1
      elif [ -e "$_ip_lad" ]; then
        printf '  left alone (not the valise bridge): %s\n' "$_ip_lad"
        _ip_removed=1
      fi
    fi
    [ "$_ip_removed" -eq 1 ] || printf '  none (gui_env=off)\n'
    ;;
  systemd | launchd)
    # The write path (gui_env_bridge_stage) writes systemd only on Linux and
    # launchd only on macOS; the preview must promise exactly that.
    _ip_need=
    case "$_ip_gui_mode" in
    systemd) _ip_need=linux ;;
    launchd) _ip_need=darwin ;;
    esac
    _ip_gui=
    if [ "$(cli_os_name)" != "$_ip_need" ]; then
      # The write path removes owned bridges when the platform cannot replace
      # the incoming mode, so the preview reports the same removal instead of
      # promising a skip that would strand the previous release's bridge.
      _ip_removed=0
      for _ip_other in systemd launchd; do
        _ip_other_path=$(gui_env_file "$_ip_other" 2>/dev/null) || continue
        [ -n "$_ip_other_path" ] || continue
        if [ -L "$_ip_other_path" ]; then
          printf '  left alone (symlink): %s\n' "$_ip_other_path"
          _ip_removed=1
        elif [ -f "$_ip_other_path" ] && bridge_is_valise_owned "$_ip_other" "$_ip_other_path"; then
          printf '  would remove: %s\n' "$_ip_other_path"
          _ip_removed=1
        elif [ -e "$_ip_other_path" ]; then
          printf '  left alone (not the valise bridge): %s\n' "$_ip_other_path"
          _ip_removed=1
        fi
      done
      if [ "$_ip_removed" -eq 0 ]; then
        printf '  skipped (gui_env=%s is not supported on %s)\n' "$_ip_gui_mode" "$(cli_os_name)"
      fi
    elif ! _ip_gui=$(gui_env_file "$_ip_gui_mode" 2>/dev/null) || [ -z "$_ip_gui" ]; then
      printf '  skipped (no bridge path for gui_env=%s)\n' "$_ip_gui_mode"
    elif [ -L "$_ip_gui" ]; then
      printf '  left alone (symlink): %s\n' "$_ip_gui"
    elif [ -e "$_ip_gui" ] && ! bridge_is_valise_owned "$_ip_gui_mode" "$_ip_gui"; then
      printf '  left alone (not the valise bridge): %s\n' "$_ip_gui"
    else
      # A dry run must not execute module bodies: a side_effect=local-state
      # module (permitted by the ABI) creates directories under $XDG_STATE_HOME,
      # so calling env_export_capture here would write into the real home while
      # promising "nothing outside build/ is written". Report the action
      # without computing the bytes.
      if [ -f "$_ip_gui" ]; then
        printf '  would regenerate: %s\n' "$_ip_gui"
      else
        printf '  would create: %s\n' "$_ip_gui"
      fi
    fi
    ;;
  *)
    printf '  skipped (unknown gui_env: %s)\n' "$_ip_gui_mode"
    ;;
  esac
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
        _ip_sha=$(VALISE_LEDGER_NAME="$_ip_name" VALISE_LEDGER_PATH="$_ip_path" "$_ip_awk" -F '\t' \
          '$1 == ENVIRON["VALISE_LEDGER_NAME"] && $2 == ENVIRON["VALISE_LEDGER_PATH"] { print $3; exit }' "$_ip_ledger")
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
    _ip_lines _ip_want _ip_bin _ip_ledger _ip_awk _ip_name _ip_path _ip_sha _ip_any _ip_shim _ip_gui_mode \
    _ip_gui _ip_gui_capture _ip_stage _ip_removed _ip_sys _ip_lad _ip_need _ip_other _ip_other_path
}
