# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: POSIX integration, init, and doctor.
# Sourced by bin/valise; not executable on its own.

# Emit the POSIX integration block for the active release.
#
# It works in every POSIX shell and with both release shapes. A built release
# carries plans/<shell>.sh for the shell classes its bundle covers; an engine
# release carries entrypoints/profile.sh and the loader. The guard makes several
# startup files safe: a login shell that reads more than one of them loads the
# profile once. It is set only after a plan was sourced, so a shell started
# before the first install, or while the release was missing, tries again from
# the next startup file. A plan that failed is not re-run in the same shell;
# VALISE_RELOAD=1 forces another attempt. The shell is named by the first of
# KSH_VERSION, ZSH_VERSION and BASH_VERSION that is set; any other shell uses
# the generic sh plan.
print_posix_integration() {
  _pix_active_literal=$(shell_quote "$VALISE_ACTIVE_LINK") || return 1
  printf '%s\n' \
    '# BEGIN valise managed block' \
    "_valise_active_link=$_pix_active_literal" \
    'if [ -z "${_valise_profile_loaded:-}" ] || [ "${VALISE_RELOAD:-}" = 1 ]; then' \
    '  if [ -n "${KSH_VERSION-}" ]; then _valise_plan=ksh; elif [ -n "${ZSH_VERSION-}" ]; then _valise_plan=zsh; elif [ -n "${BASH_VERSION-}" ]; then _valise_plan=bash; else _valise_plan=sh; fi' \
    '  _valise_active=$(cd "$_valise_active_link" 2>/dev/null && pwd -P)' \
    '  if [ -n "$_valise_active" ]; then' \
    '    if [ -f "$_valise_active/plans/$_valise_plan.sh" ]; then' \
    '      _valise_profile_loaded=1' \
    '      VALISE_MODULE_ROOT="$_valise_active"' \
    '      . "$_valise_active/plans/$_valise_plan.sh"' \
    '      unset VALISE_MODULE_ROOT' \
    '    elif [ -f "$_valise_active/entrypoints/profile.sh" ]; then' \
    '      _valise_profile_loaded=1' \
    '      VALISE_ROOT="$_valise_active"' \
    '      . "$_valise_active/entrypoints/profile.sh"' \
    '    fi' \
    '  fi' \
    '  unset _valise_active _valise_plan' \
    'fi' \
    'unset _valise_active_link' \
    '# END valise managed block'
  unset _pix_active_literal
}

# integration_markers_paired <file>
# Succeed when every BEGIN marker of the managed block is followed by an END
# marker before the next BEGIN, and no END appears without a BEGIN.
integration_markers_paired() {
  _imp_awk=$(trusted_utility_path awk) || return 1
  "$_imp_awk" '
    /^# BEGIN valise managed block$/ { if (open) bad = 1; open = 1; next }
    /^# END valise managed block$/ { if (!open) bad = 1; open = 0; next }
    END { exit (bad || open) ? 1 : 0 }
  ' "$1"
}

cmd_init() {
  _shell=""
  _fish_source_tree_mode=0
  for _arg do
    case "$_arg" in
      --source-tree) _fish_source_tree_mode=1 ;;
      --help|-h) usage_init; return 0 ;;
      -*) die "unknown init option: $_arg" ;;
      *)
        [ -z "$_shell" ] || die "usage: valise init [posix|fish] [--source-tree]"
        _shell=$_arg
        ;;
    esac
  done
  if [ -z "$_shell" ]; then
    case "${SHELL:-}" in
      *fish) _shell=fish ;;
      *)     _shell=posix ;;
    esac
  fi
  case "$_shell" in
    posix) print_posix_integration || return 1 ;;
    fish) print_fish_integration ;;
    *) die "unsupported shell family: $_shell (use posix or fish)" ;;
  esac
}

# Report whether a startup file carries valise integration: the POSIX managed
# block, or the header of the Fish hook, which valise owns as a whole file.
integration_has_managed_block() {
  _ihb_awk=$(trusted_utility_path awk) || return 1
  "$_ihb_awk" '
    index($0, "# BEGIN valise managed block") { found = 1; exit }
    index($0, "# valise Fish integration") { found = 1; exit }
    END { exit !found }
  ' "$1" 2>/dev/null
}

# The startup files a shell reads at login and for interactive shells. A login
# bash reads the first of .bash_profile, .bash_login and .profile that exists.
#
# integration_shell_files <shell> <home>
# prints one candidate path per line.
integration_shell_files() {
  case "$1" in
  bash)
    if [ -e "$2/.bash_profile" ]; then
      printf '%s\n' "$2/.bash_profile"
    elif [ -e "$2/.bash_login" ]; then
      printf '%s\n' "$2/.bash_login"
    else
      printf '%s\n' "$2/.profile"
    fi
    printf '%s\n' "$2/.bashrc"
    ;;
  zsh)
    printf '%s\n' "$2/.zprofile" "$2/.zshrc"
    ;;
  fish)
    printf '%s\n' "${XDG_CONFIG_HOME:-$2/.config}/fish/conf.d/valise.fish"
    ;;
  *)
    printf '%s\n' "$2/.profile"
    ;;
  esac
}

# The startup files install manages. ~/.profile is always included: it serves
# sh, ksh and login bash. Files that belong to another shell are only created
# for the user's own shell, except ~/.zprofile, because zsh reads nothing else at
# login. Existing files are always kept current.
#
# posix_startup_targets <home>
# prints one path per line.
posix_startup_targets() {
  printf '%s\n' "$1/.profile"
  if [ -e "$1/.bash_profile" ] || [ -L "$1/.bash_profile" ]; then
    printf '%s\n' "$1/.bash_profile"
  elif [ -e "$1/.bash_login" ] || [ -L "$1/.bash_login" ]; then
    printf '%s\n' "$1/.bash_login"
  fi
  case "${SHELL:-}" in
  */bash | bash) printf '%s\n' "$1/.bashrc" ;;
  *) if [ -e "$1/.bashrc" ] || [ -L "$1/.bashrc" ]; then printf '%s\n' "$1/.bashrc"; fi ;;
  esac
  if [ -e "$1/.zprofile" ] || [ -L "$1/.zprofile" ] || command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$1/.zprofile"
  fi
  case "${SHELL:-}" in
  */zsh | zsh) printf '%s\n' "$1/.zshrc" ;;
  *) if [ -e "$1/.zshrc" ] || [ -L "$1/.zshrc" ]; then printf '%s\n' "$1/.zshrc"; fi ;;
  esac
}

# Write the managed block to every startup file install manages.
write_posix_integration() {
  if [ -z "${HOME:-}" ]; then
    info "warning: HOME is not set; no startup file was written"
    return 0
  fi
  _wpi_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
  _wpi_snippet=$(print_posix_integration) || die "cannot generate integration block"
  _wpi_targets=$(posix_startup_targets "$_wpi_home")
  while IFS= read -r _wpi_target; do
    [ -n "$_wpi_target" ] || continue
    project_write_integration "$_wpi_target" "$_wpi_snippet"
  done <<EOF
$_wpi_targets
EOF
  info "to remove the integration, delete the valise managed block from these files"
  unset _wpi_home _wpi_snippet _wpi_targets _wpi_target
}

cmd_doctor() {
  _status=0
  _doctor_pre_install=0
  _doctor_check_integration=1
  for _doctor_arg do
    case "$_doctor_arg" in
      --pre-install) _doctor_pre_install=1; _doctor_check_integration=0 ;;
      --no-integration) _doctor_check_integration=0 ;;
      --help|-h) usage_doctor; return 0 ;;
      *) die "unknown doctor option: $_doctor_arg (usage: valise doctor [--pre-install] [--no-integration])" ;;
    esac
  done

  info "checking environment..."

  # Check POSIX utilities
  for _cmd in mkdir rm cp mv ln cat sha256sum shasum stat cmp find; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      printf '  ok: %s\n' "$_cmd"
    else
      case "$_cmd" in
        sha256sum|shasum)
          # Need at least one
          if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
            printf '  FAIL: no SHA-256 utility (need sha256sum or shasum)\n'
            _status=1
          else
            printf '  ok: sha256 (via %s)\n' "$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null)"
          fi
          ;;
        *)
          printf '  FAIL: missing required utility: %s\n' "$_cmd"
          _status=1
          ;;
      esac
    fi
  done

  # Check XDG directories
  for _dir in "$VALISE_XDG_DATA" "$VALISE_XDG_CONFIG" "$VALISE_XDG_STATE"; do
    if [ -d "$_dir" ]; then
      printf '  ok: directory exists: %s\n' "$_dir"
    else
      printf '  warn: directory missing (will create on install): %s\n' "$_dir"
    fi
  done

  # Check active symlink
  _doctor_active_ok=0
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _target=$(active_release_dir 2>/dev/null || :)
    if [ -n "$_target" ]; then
      printf '  ok: active release: %s\n' "$_target"
      _doctor_active_target=$_target
      _doctor_active_ok=1
    else
      printf '  FAIL: active symlink does not resolve to a release directory\n'
      _status=1
    fi
  elif [ -e "$VALISE_ACTIVE_LINK" ]; then
    printf '  FAIL: active pointer is not a symlink: %s\n' "$VALISE_ACTIVE_LINK"
    _status=1
  elif [ "$_doctor_pre_install" -eq 1 ]; then
    printf '  info: no active release configured\n'
  else
    # With no release there is nothing for a shell to load, so doctor reports
    # the missing release as a failure. --pre-install is the explicit
    # opt-out for a machine that has not installed a release yet.
    printf '  FAIL: no active release configured\n'
    _status=1
  fi

  # The active release must verify against its own manifest. A release that
  # fails verification is not usable, so doctor reports it as a failure.
  if [ "$_doctor_active_ok" -eq 1 ] && [ "$_doctor_pre_install" -eq 0 ]; then
    _doctor_active_manifest="$_doctor_active_target/.valise-manifest"
    if [ -f "$_doctor_active_manifest" ] && [ ! -L "$_doctor_active_manifest" ]; then
      _doctor_active_id=${_doctor_active_target##*/}
      if prepare_manifest_rows "$_doctor_active_manifest" &&
         validate_manifest "$_manifest_rows"; then
        _verify_quiet=1
        if verify_release_dir "$_doctor_active_target" "$_manifest_rows" "$_doctor_active_id"; then
          _verify_quiet=0
          printf '  ok: active release verifies: %s\n' "$_doctor_active_id"
        else
          _verify_quiet=0
          printf '  FAIL: active release does not verify: %s\n' "$_doctor_active_id"
          _status=1
        fi
      else
        printf '  FAIL: active release manifest is invalid: %s\n' "$_doctor_active_manifest"
        _status=1
      fi
    else
      printf '  FAIL: active release manifest is missing: %s\n' "$_doctor_active_manifest"
      _status=1
    fi
  elif [ "$_doctor_pre_install" -eq 1 ]; then
    printf '  info: skipping the active release check (--pre-install)\n'
  fi

  if [ -n "${HOME:-}" ]; then
    # Check the startup files the running shell actually reads. The shell is
    # taken from $SHELL, which is the same signal install uses to pick its
    # per-shell startup file.
    if [ "$_doctor_check_integration" -eq 1 ]; then
      _doctor_shell=""
      case "${SHELL:-}" in
      */bash|bash) _doctor_shell=bash ;;
      */zsh|zsh) _doctor_shell=zsh ;;
      */ksh|ksh) _doctor_shell=ksh ;;
      */fish|fish) _doctor_shell=fish ;;
      esac
      if [ -n "$_doctor_shell" ]; then
        printf '  integration shell: %s\n' "$_doctor_shell"
      else
        printf '  integration shell: unknown (using ~/.profile)\n'
      fi
      _doctor_found=0
      _doctor_candidates=""
      # The candidate paths are read one per line. Word splitting on $(...)
      # would break a home directory containing whitespace, so the list goes
      # through a staging file instead.
      _doctor_cand_file=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-doctor-candidates.XXXXXX") ||
        die "cannot create doctor candidate staging file"
      integration_shell_files "$_doctor_shell" "$HOME" >"$_doctor_cand_file"
      while IFS= read -r _doctor_candidate; do
        [ -n "$_doctor_candidate" ] || continue
        _doctor_candidates="$_doctor_candidates $_doctor_candidate"
        if [ -L "$_doctor_candidate" ]; then
          printf '  warn: startup file is a symlink: %s\n' "$_doctor_candidate"
          continue
        fi
        if [ ! -f "$_doctor_candidate" ]; then
          printf '  info: startup file is not present: %s\n' "$_doctor_candidate"
          continue
        fi
        if integration_has_managed_block "$_doctor_candidate"; then
          printf '  ok: startup file contains the valise managed block: %s\n' "$_doctor_candidate"
          _doctor_found=1
        else
          printf '  warn: startup file exists but has no valise managed block: %s\n' "$_doctor_candidate"
        fi
      done <"$_doctor_cand_file"
      _doctor_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
      "$_doctor_rm" -f "$_doctor_cand_file" || die "cannot remove doctor candidate staging file"
      if [ "$_doctor_found" -eq 0 ]; then
        printf '  FAIL: no valise integration found for %s (checked:%s)\n' \
          "${_doctor_shell:-the current shell}" "$_doctor_candidates"
        _status=1
      fi
    else
      printf '  info: skipping the shell integration check\n'
    fi
  fi

  # Platform check (informational only; install and release use are portable
  # POSIX and not gated on any particular uname).
  _uname=$(uname -s 2>/dev/null || echo unknown)
  printf '  platform: %s\n' "$_uname"

  if [ "$_status" -eq 0 ]; then
    info "all checks passed"
  else
    die "some checks failed"
  fi
}
