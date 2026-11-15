# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: POSIX integration, init, and doctor.
# Sourced by bin/valise; not executable on its own.

# Emit the POSIX integration block for the active release.
#
# It works in every POSIX shell. A release carries plans/<shell>.sh (the env
# plan) and, when the bundle has interactive-phase modules,
# plans/<shell>-interactive.sh; a shell class with no plan loads nothing.
#
# The block is two-stage. Stage 1 sources the env plan at EVERY startup file
# the shell reads, because the env plan is a convergent projection: re-running
# it in a fresh nested shell (a new tmux pane, a new login) is what repairs
# PATH reordering done by /etc/profile or macOS path_helper. The guard is
# keyed by RELEASE ID, not by session: _valise_profile_loaded records the
# release directory name it loaded, so the same shell with the same release
# is a no-op, a switched release forces a reload, and a fresh nested shell
# (new process, guard unset) always re-runs the env plan. It is set only
# after a plan was sourced, so a shell started before the first install, or
# while the release was missing, tries again from the next startup file. A
# plan that failed is not re-run in the same shell; VALISE_RELOAD=1 forces
# another attempt. Stage 2 sources the interactive plan only when the shell
# is interactive (case $- in *i*); it must stay silent too, so ssh host-cmd
# sessions (which read .bashrc non-interactively) are safe. The shell class
# is named by the first of KSH_VERSION, ZSH_VERSION and BASH_VERSION that is
# set; any other shell uses the generic sh plan.
print_posix_integration() {
  _pix_active_literal=$(shell_quote "$VALISE_ACTIVE_LINK") || return 1
  _pix_env_export=''
  case "${SHELL:-}" in
    */ksh|ksh|*/sh|"/bin/sh"|sh) _pix_env_export=1 ;;
  esac
  printf '%s\n' \
    '# BEGIN valise managed block' \
    "_valise_active_link=$_pix_active_literal" \
    'if [ -n "${KSH_VERSION-}" ]; then _valise_plan=ksh; elif [ -n "${ZSH_VERSION-}" ]; then _valise_plan=zsh; elif [ -n "${BASH_VERSION-}" ]; then _valise_plan=bash; else _valise_plan=sh; fi' \
    '_valise_active=$(cd "$_valise_active_link" 2>/dev/null && pwd -P)' \
    'if [ -n "$_valise_active" ]; then' \
    '  _valise_release_id=${_valise_active##*/}' \
    '  if [ -z "${_valise_profile_loaded:-}" ] || [ "${_valise_profile_loaded:-}" != "$_valise_release_id" ] || [ "${VALISE_RELOAD:-}" = 1 ]; then' \
    '    if [ -f "$_valise_active/plans/$_valise_plan.sh" ]; then' \
    '      _valise_profile_loaded=$_valise_release_id' \
    '      VALISE_MODULE_ROOT="$_valise_active"' \
    '      . "$_valise_active/plans/$_valise_plan.sh"' \
    '      unset VALISE_MODULE_ROOT' \
    '    fi' \
    '  fi' \
    '  case $- in *i*)' \
    '    if [ -f "$_valise_active/plans/$_valise_plan-interactive.sh" ]; then' \
    '      VALISE_MODULE_ROOT="$_valise_active"' \
    '      . "$_valise_active/plans/$_valise_plan-interactive.sh"' \
    '      unset VALISE_MODULE_ROOT' \
    '    fi' \
    '    ;;' \
    '  esac' \
    '  unset _valise_release_id' \
    'fi' \
    'unset _valise_active _valise_plan' \
    'unset _valise_active_link'
  # sh/ksh interactive subshells read $ENV on startup; point it at the valise
  # shim so a nested POSIX shell loads valise too. Only set when ENV does not
  # already name an existing user-owned file.
  if [ "$_pix_env_export" = 1 ]; then
    _pix_shim_literal=$(shell_quote "${XDG_CONFIG_HOME:-$HOME/.config}/valise/env.sh") || { unset _pix_active_literal _pix_env_export; return 1; }
    printf '%s\n' \
      "if [ -z \"\${ENV:-}\" ] || [ ! -e \"\$ENV\" ]; then" \
      "  ENV=$_pix_shim_literal" \
      '  export ENV' \
      'fi'
    unset _pix_shim_literal
  fi
  printf '%s\n' '# END valise managed block'
  unset _pix_active_literal _pix_env_export
}

# env_shim_path: the $ENV shim install writes for sh/ksh subshells.
env_shim_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/valise/env.sh"
}

# print_env_shim: the contents of the $ENV shim. It is the same two-stage
# managed block, minus the ENV export (a shim must not re-point ENV).
print_env_shim() {
  _pes_saved_shell=${SHELL:-}
  SHELL=/bin/sh
  print_posix_integration | awk '
    /^# BEGIN valise managed block$/ { inblock = 1; print; next }
    /^# END valise managed block$/   { inblock = 0; print; next }
    inblock && /^if \[ -z "\$\{ENV:-\}" \]/ { skip = 1; next }
    skip && /^fi$/ { skip = 0; next }
    skip { next }
    { print }
  '
  SHELL=$_pes_saved_shell
  unset _pes_saved_shell
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
    printf '%s\n' "$2/.zshenv" "$2/.zprofile" "$2/.zshrc"
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
  # zsh reads ~/.zshenv for EVERY invocation (login or not, interactive or
  # not), before /etc/zprofile runs path_helper on macOS, so the managed
  # block there covers 'zsh -c' env and the .zprofile block repairs PATH
  # after path_helper; double evaluation is harmless (release-id guard +
  # convergent env plan).
  if [ -e "$1/.zshenv" ] || [ -L "$1/.zshenv" ] || command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$1/.zshenv"
  fi
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
  # The $ENV shim for sh/ksh subshells: the same two-stage block, minus the
  # ENV export. Never overwrite a user-owned shim.
  _wpi_shim=$(env_shim_path)
  _wpi_shim_parent=$(path_parent "$_wpi_shim")
  _wpi_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  [ -d "$_wpi_shim_parent" ] || "$_wpi_mkdir" -p "$_wpi_shim_parent" || die "cannot create shim parent: $_wpi_shim_parent"
  if [ -e "$_wpi_shim" ] || [ -L "$_wpi_shim" ]; then
    if [ -L "$_wpi_shim" ] || ! integration_has_managed_block "$_wpi_shim" 2>/dev/null; then
      info "warning: leaving $_wpi_shim: it is not the valise ENV shim"
      unset _wpi_home _wpi_snippet _wpi_targets _wpi_target _wpi_shim _wpi_shim_parent _wpi_mkdir
      return 0
    fi
  fi
  _wpi_shim_tmp=$(trusted_mktemp_at "$_wpi_shim_parent" file "$_wpi_shim_parent/.valise-env.XXXXXX") ||
    die "cannot create shim staging file"
  if ! print_env_shim >"$_wpi_shim_tmp"; then
    _wpi_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_wpi_rm" -f "$_wpi_shim_tmp"
    die "cannot generate the ENV shim"
  fi
  _wpi_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  _wpi_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_wpi_chmod" 0644 "$_wpi_shim_tmp" && "$_wpi_mv" -f "$_wpi_shim_tmp" "$_wpi_shim" ||
    { "$_wpi_rm" -f "$_wpi_shim_tmp" 2>/dev/null || :; die "cannot publish the ENV shim: $_wpi_shim"; }
  info "ENV shim deployed: $_wpi_shim"
  unset _wpi_home _wpi_snippet _wpi_targets _wpi_target _wpi_shim _wpi_shim_parent _wpi_mkdir _wpi_shim_tmp _wpi_chmod _wpi_mv _wpi_rm
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
  for _cmd in mkdir rm cp mv ln cat stat cmp find; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      printf '  ok: %s\n' "$_cmd"
    else
      printf '  FAIL: missing required utility: %s\n' "$_cmd"
      _status=1
    fi
  done
  # file_sha256 accepts any one of these, found in a trusted location.
  _doctor_sha=
  for _cmd in sha256sum shasum sha256; do
    _doctor_sha=$(trusted_utility_path "$_cmd" 2>/dev/null || :)
    [ -z "$_doctor_sha" ] || break
  done
  if [ -n "$_doctor_sha" ]; then
    printf '  ok: sha256 (via %s)\n' "$_doctor_sha"
  else
    printf '  FAIL: no SHA-256 utility (need sha256sum, shasum, or sha256)\n'
    _status=1
  fi

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
  if [ "$_doctor_active_ok" -eq 1 ] && [ "$_doctor_check_integration" -eq 1 ]; then
    doctor_commands "$_doctor_active_target"
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
      if ! _doctor_unmanaged=$(integration_unmanaged_report); then
        printf '  FAIL: valise is loaded outside a managed block (it may load twice):\n'
        printf '    %s\n' "$_doctor_unmanaged"
        _status=1
      fi
      if [ "$_doctor_found" -eq 0 ]; then
        printf '  FAIL: no valise integration found for %s (checked:%s)\n' \
          "${_doctor_shell:-the current shell}" "$_doctor_candidates"
        _status=1
      fi
      # Archetype diagnostics: a legacy single-stage block (no $- gate inside
      # the markers) is upgradeable; an sh/ksh login shell whose ENV does not
      # point at the valise shim misses interactive subshells; zsh without a
      # .zshenv block misses non-login 'zsh -c' env.
      if [ -f "$HOME/.profile" ] && [ ! -L "$HOME/.profile" ]; then
        if integration_has_managed_block "$HOME/.profile" &&
          ! awk '/^# BEGIN valise managed block$/ { inblock = 1 } inblock && /case \$- in \*i\*\)/ { gate = 1 } /^# END valise managed block$/ { inblock = 0 } END { exit gate ? 0 : 1 }' "$HOME/.profile"; then
          printf '  warn: ~/.profile has a legacy single-stage block; run valise install again to upgrade to the two-stage block\n'
        fi
      fi
      case "${_doctor_shell:-}" in
        ksh|sh|"")
          if [ -n "${ENV:-}" ] && [ -e "$ENV" ] && [ "$ENV" != "$(env_shim_path)" ]; then
            printf '  warn: $ENV points at %s, not the valise shim %s; interactive sh/ksh subshells will not load valise\n' "$ENV" "$(env_shim_path)"
          fi
          ;;
      esac
      if [ "$_doctor_shell" = zsh ] && command -v zsh >/dev/null 2>&1; then
        if [ ! -f "$HOME/.zshenv" ] || ! integration_has_managed_block "$HOME/.zshenv" 2>/dev/null; then
          printf '  warn: no valise managed block in ~/.zshenv; non-login zsh (zsh -c) will not load the env plan\n'
        fi
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
