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
  _gef_home=${_gef_home%/}
  case "${1:-}" in
  # xdg_child keeps a "/" root from producing "//environment.d/...", which POSIX
  # leaves implementation-defined.
  systemd) xdg_child "$VALISE_XDG_CONFIG_ROOT" environment.d/10-valise.conf ;;
  launchd)
    [ -n "$_gef_home" ] || { unset _gef_home; return 1; }
    printf '%s\n' "$_gef_home/Library/LaunchAgents/sh.valise.env.plist"
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
      info "gui_env=systemd but the platform is not Linux; skipping the environment.d bridge"
      unset _gbs_release _gbs_mode
      return 0
    fi
    ;;
  launchd)
    if [ "$(cli_os_name)" != darwin ]; then
      info "gui_env=launchd but the platform is not macOS; skipping the LaunchAgent bridge"
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
  _gui_stage=$(trusted_mktemp_at "$_gbs_parent" file "$_gbs_parent/.valise-gui.XXXXXX") || {
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
    return 1
  }
  if ! env_export_emit "$_gbs_format" "$_gbs_capture" >"$_gui_stage"; then
    _gbs_rm=$(trusted_utility_path rm 2>/dev/null || :)
    [ -z "$_gbs_rm" ] || "$_gbs_rm" -f "$_gui_stage" 2>/dev/null || :
    _gui_stage=
    _gui_mode= _gui_target=
    printf 'valise: error: cannot render the %s GUI env bridge\n' "$_gbs_mode" >&2
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir _gbs_rm
    return 1
  fi
  _gbs_chmod=$(trusted_utility_path chmod) || {
    _gbs_rm=$(trusted_utility_path rm 2>/dev/null || :)
    [ -z "$_gbs_rm" ] || "$_gbs_rm" -f "$_gui_stage" 2>/dev/null || :
    _gui_stage=
    _gui_mode= _gui_target=
    unset _gbs_release _gbs_mode _gbs_shell _gbs_capture _gbs_format _gbs_parent _gbs_mkdir
    return 1
  }
  # The bridge holds values the env plan exports, and the module ABI allows a
  # local-secret module to export a secret read from a protected file. An
  # explicit 0644 would publish that value world-readable over a restrictive
  # umask, so the bridge is owner-only.
  if ! "$_gbs_chmod" 0600 "$_gui_stage"; then
    _gbs_rm=$(trusted_utility_path rm 2>/dev/null || :)
    [ -z "$_gbs_rm" ] || "$_gbs_rm" -f "$_gui_stage" 2>/dev/null || :
    _gui_stage=
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
    remove_gui_env_bridge
    _gbp_rc=$?
    _gui_action=none
    _gui_mode= _gui_target=
    return "$_gbp_rc"
    ;;
  publish)
    _gbp_mv=$(trusted_utility_path mv) || return 1
    _gbp_rc=0
    "$_gbp_mv" -f "$_gui_stage" "$_gui_target" || _gbp_rc=1
    if [ "$_gbp_rc" -eq 0 ]; then
      _gui_stage=
      info "GUI env bridge written ($_gui_mode): $_gui_target"
    fi
    _gui_action=none
    _gbp_mode=$_gui_mode
    _gbp_target=$_gui_target
    _gui_mode= _gui_target=
    unset _gbp_mv
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

# remove_gui_env_bridge: remove every valise-owned bridge file, as one set. The
# two files can coexist (a migrated or shared home), so a removal that fails on
# the second file must not have already deleted the first. Phase 1 renames each
# owned file aside, and a failed rename puts the renamed files back; phase 2
# deletes the set-aside files, and reports any delete that fails with its path.
remove_gui_env_bridge() {
  if ! _rgb_rm=$(trusted_utility_path rm); then
    printf 'valise: error: no trusted rm utility is available to remove the GUI env bridge\n' >&2
    return 1
  fi
  if ! _rgb_mv=$(trusted_utility_path mv); then
    printf 'valise: error: no trusted mv utility is available to remove the GUI env bridge\n' >&2
    unset _rgb_rm
    return 1
  fi
  _rgb_sys=$(gui_env_file systemd 2>/dev/null) || _rgb_sys=
  _rgb_lad=$(gui_env_file launchd 2>/dev/null) || _rgb_lad=
  _rgb_sys_aside=
  _rgb_lad_aside=
  _rgb_rc=0
  if [ -n "$_rgb_sys" ] && _rgb_candidate systemd "$_rgb_sys"; then
    _rgb_sys_aside="$_rgb_sys.valise-remove.$$"
    "$_rgb_mv" -f "$_rgb_sys" "$_rgb_sys_aside" 2>/dev/null || {
      printf 'valise: error: cannot remove the systemd GUI env bridge: %s\n' "$_rgb_sys" >&2
      _rgb_sys_aside=
      _rgb_rc=1
    }
  fi
  if [ "$_rgb_rc" -eq 0 ] && [ -n "$_rgb_lad" ] && _rgb_candidate launchd "$_rgb_lad"; then
    _rgb_lad_aside="$_rgb_lad.valise-remove.$$"
    "$_rgb_mv" -f "$_rgb_lad" "$_rgb_lad_aside" 2>/dev/null || {
      printf 'valise: error: cannot remove the launchd GUI env bridge: %s\n' "$_rgb_lad" >&2
      _rgb_lad_aside=
      _rgb_rc=1
    }
  fi
  if [ "$_rgb_rc" -ne 0 ]; then
    # Phase 1 failed: put back every file already set aside, so no bridge is
    # removed while the other one remains.
    if [ -n "$_rgb_sys_aside" ] && ! "$_rgb_mv" -f "$_rgb_sys_aside" "$_rgb_sys" 2>/dev/null; then
      printf 'valise: error: the systemd GUI env bridge was moved aside and could not be put back: %s\n' "$_rgb_sys_aside" >&2
    fi
    if [ -n "$_rgb_lad_aside" ] && ! "$_rgb_mv" -f "$_rgb_lad_aside" "$_rgb_lad" 2>/dev/null; then
      printf 'valise: error: the launchd GUI env bridge was moved aside and could not be put back: %s\n' "$_rgb_lad_aside" >&2
    fi
    unset _rgb_rm _rgb_mv _rgb_sys _rgb_lad _rgb_sys_aside _rgb_lad_aside _rgb_rc
    return 1
  fi
  # Phase 2: the set is committed. A delete that fails leaves its moved file
  # behind, and that path is named.
  if [ -n "$_rgb_sys_aside" ]; then
    if "$_rgb_rm" -f "$_rgb_sys_aside"; then
      info "removed the systemd bridge: $_rgb_sys"
    else
      printf 'valise: error: cannot remove the systemd GUI env bridge: %s\n' "$_rgb_sys_aside" >&2
      _rgb_rc=1
    fi
  fi
  if [ -n "$_rgb_lad_aside" ]; then
    if "$_rgb_rm" -f "$_rgb_lad_aside"; then
      info "removed the launchd bridge: $_rgb_lad"
    else
      printf 'valise: error: cannot remove the launchd GUI env bridge: %s\n' "$_rgb_lad_aside" >&2
      _rgb_rc=1
    fi
  fi
  unset _rgb_rm _rgb_mv _rgb_sys _rgb_lad _rgb_sys_aside _rgb_lad_aside
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
  _rii_tmp=$(trusted_mktemp_at "$VALISE_XDG_STATE" file "$VALISE_XDG_STATE/.integration.XXXXXX") ||
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
  # Prepare the GUI env bridge BEFORE the active link moves. A capture or render
  # failure then leaves the outgoing release active with its own bridge, instead
  # of switching to a release whose env the GUI session will never see.
  _ra_bridge=0
  if integration_installed; then
    case "$(gui_env_mode "$_ra_dir")" in
    off | systemd | launchd) _ra_bridge=1 ;;
    esac
  fi
  if [ "$_ra_bridge" -eq 1 ] && [ -n "${HOME:-}" ] && [ "$(cli_os_name)" != unknown ]; then
    gui_env_bridge_stage "$_ra_dir" ||
      die "cannot prepare the GUI env bridge for $_ra_id; the active release was not changed"
  fi
  # Remember the outgoing target so a publish failure can undo the switch: with
  # `release use` there is no install transaction to do it.
  _ra_old_target=
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _ra_old_target=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null || :)
  fi
  # The switch rewrites the previous-release record to the outgoing release. If
  # the bridge publish then fails, that record is put back as well as the link.
  _ra_had_previous=0
  _ra_old_previous=
  if _ra_old_previous=$(read_previous_record); then
    _ra_had_previous=1
  fi
  switch_active_link "$_ra_dir"
  if [ "$_ra_bridge" -eq 1 ] && [ -n "${HOME:-}" ] && [ "$(cli_os_name)" != unknown ]; then
    if ! gui_env_bridge_publish; then
      # Put the previous release back, so the link and the bridge always
      # describe the same release.
      _ra_ln=$(trusted_utility_path ln 2>/dev/null || :)
      if [ -n "$_ra_old_target" ] && [ -n "$_ra_ln" ] &&
        "$_ra_ln" -sfn "$_ra_old_target" "$VALISE_ACTIVE_LINK" 2>/dev/null; then
        restore_previous_record "$_ra_had_previous" "$_ra_old_previous"
        die "cannot publish the GUI env bridge for $_ra_id; the active release was left as ${_ra_old_target##*/}"
      fi
      die "cannot publish the GUI env bridge for $_ra_id; the active release was changed but its bridge was not"
    fi
  fi
  # Commands follow the active release only where install published them: a
  # ledger exists once an install ran with integration.
  if [ -f "$(commands_ledger_path)" ]; then
    reconcile_commands "$_ra_dir"
  fi
  release_lock
  unset _ra_id _ra_dir _ra_root _ra_parent _ra_manifest _ra_config_parent _ra_mkdir _ra_bridge _ra_old_target _ra_ln
  unset _ra_had_previous _ra_old_previous
}

# restore_previous_record <had 0|1> <release-id>: put the previous-release record
# back to what it was before a switch; remove it when none existed.
restore_previous_record() {
  if [ "$1" -eq 1 ]; then
    write_previous_record "$2"
  else
    _rpr_rm=$(trusted_utility_path rm 2>/dev/null || :)
    [ -z "$_rpr_rm" ] || "$_rpr_rm" -f "$(previous_record_path)" 2>/dev/null || :
    unset _rpr_rm
  fi
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
      [ ! -L "$_ipf_shim" ] || : # a symlinked shim is reported and skipped at write time
      preflight_dir_writable "$(path_parent "$_ipf_shim")" "ENV shim"
    fi
    _ipf_gui_mode=$(gui_env_mode "$1")
    case "$_ipf_gui_mode" in
    systemd | launchd)
      _ipf_gui=$(gui_env_file "$_ipf_gui_mode" 2>/dev/null) || _ipf_gui=
      if [ -n "$_ipf_gui" ]; then
        [ ! -L "$_ipf_gui" ] || :
        preflight_dir_writable "$(path_parent "$_ipf_gui")" "GUI env bridge"
      fi
      ;;
    esac
  fi
  unset _ipf_home _ipf_targets _ipf_target _ipf_stage _ipf_parent _ipf_hook _ipf_bin _ipf_shim _ipf_gui_mode _ipf_gui
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
  _un_tmp=$(trusted_mktemp_at "$_usb_parent" file "$_usb_parent/.valise-uninstall.XXXXXX") ||
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
    # user-owned file at the bridge path is never deleted.
    remove_gui_env_bridge
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
  info "valise integration removed; the valise CLI itself is still installed"
  unset _un_keep _un_arg _un_rm _un_rmdir _un_mkdir _un_home _un_name _un_file _un_hook _un_first \
    _un_lines _un_record _un_shim _un_shim_check
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
  # The $ENV shim is a managed startup file, so a dry run must report it too.
  if [ -n "${HOME:-}" ] && _ip_shim=$(env_shim_path); then
    if _ip_snippet=$(print_posix_integration all); then
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
    printf '  none (gui_env=off)\n'
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
      printf '  skipped (gui_env=%s is not supported on %s)\n' "$_ip_gui_mode" "$(cli_os_name)"
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
    _ip_lines _ip_want _ip_bin _ip_ledger _ip_awk _ip_name _ip_path _ip_sha _ip_any _ip_shim _ip_gui_mode \
    _ip_gui _ip_gui_capture _ip_stage
}
