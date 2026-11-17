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
# The block is two-stage, and the stage it carries depends on WHERE it is
# written (print_posix_integration <all|env>):
#   stage 1 (every file)  sources the env plan. The env plan is a convergent
#     projection: re-running it in a fresh nested shell (a new tmux pane, a new
#     login) is what repairs PATH reordering done by /etc/profile or macOS
#     path_helper. The guard is keyed by RELEASE ID, not by session, so the same
#     shell with the same release is a no-op, a switched release forces a
#     reload, and a fresh nested shell always re-runs the env plan. It is set
#     only after a plan was sourced successfully, so a shell started before the
#     first install, while the release was missing, or after a plan failed tries
#     again from the next startup file the shell reads.
#   stage 2 (rc-stage files)  sources the interactive plan when the shell is
#     interactive (`case $- in *i*`). It goes in the shell's rc-stage file
#     (.bashrc, .zshrc, or the $ENV shim), and in the one file a login bash
#     reads (.bash_profile, else .bash_login, else .profile), placed last, since
#     a login bash never reads .bashrc. It is NEVER in .zshenv or .zprofile: an
#     interactive zsh already has `i` in `$-` while it reads .zshenv, so a
#     stage 2 there would run interactive setup BEFORE the user's .zshrc - and
#     the release-id guard would then suppress the correct, later run. Checking
#     `$-` proves the shell is interactive; it does not prove the right
#     startup-file stage has been reached.
#
# Three private markers make re-evaluation safe and cheap:
#   _valise_env_tried / _valise_int_tried  the release this process has
#     already attempted in each stage. Neither is exported, so a child process
#     always attempts the plan for itself (functions are not inherited).
#     Whenever the block is about to source a plan for a release this process
#     has already sourced EITHER stage of, it sets VALISE_RELOAD=1 for that
#     source (a plain assignment: the plan reads it as a shell variable, so it
#     must NOT be exported into the caller's children) and restores the
#     caller's exact state afterwards. The reload flag is
#     per RELEASE, not per stage: a module that moves from env to interactive
#     between two releases must still be reloaded, and it would be seen as a
#     "declared export already exists" conflict otherwise.
#   _valise_plan_owned  (written by the compiled plan) the export names valise
#     itself installed in this process. The reload prelude unsets only those, so
#     a caller's function that collided with a module export is reported again
#     instead of being silently replaced on the automatic retry. An attempted
#     load does not establish ownership.
#   _valise_env_repair  a one-shot ticket, armed only by a login shell (case
#     $- in *l*). macOS zsh runs /etc/zprofile's path_helper AFTER ~/.zshenv,
#     so the entry .zshenv prepended ends up last; the ticket forces exactly
#     one more stage-1 pass at the next startup file (~/.zprofile), which
#     restores the compiled PATH, and is then spent.
#
# Stage 2 runs only when stage 1 succeeded for THIS release. The result of the
# last env evaluation for a release is kept in the process (_valise_env_rel,
# _valise_env_ok, _valise_env_carry), so a later startup file whose release
# guard skips the env stage still hands stage 2 the real unavailable-module
# list (`_valise_plan_carried`) and the real success state. A required
# interactive module whose env dependency failed is therefore blocked exactly
# as it would be in one combined plan, in every startup file. A failed env
# evaluation also drops `_valise_profile_loaded`, so a later file re-runs the
# env plan rather than trusting an earlier success. A PATH that differs from
# the one the last successful env evaluation left (a user rc file that resets
# PATH, or macOS path_helper) also re-runs it, so the compiled PATH is
# re-asserted in the shell that actually runs; the module bodies re-run then.
#
# Both stages must stay silent, so ssh host-cmd sessions (which read .bashrc
# non-interactively) are safe. The shell class is named by the first of
# KSH_VERSION, ZSH_VERSION and BASH_VERSION that is set; any other shell uses
# the generic sh plan.
print_posix_integration() {
  _pix_stage=${1:-all}
  _pix_active_literal=$(shell_quote "$VALISE_ACTIVE_LINK") || return 1
  # The $ENV stanza is emitted into every file and decided at RUNTIME from what
  # the shell does, not from the class the plan was chosen by. bash ignores ENV
  # when invoked as bash, and READS it when invoked as `sh` (its POSIX startup
  # file); dash and ksh read it; zsh ignores it natively. So an unconditional
  # stanza is inert in a native bash/zsh session and wires exactly the shells
  # that need it, including a bash binary invoked through an `sh` symlink -
  # which a plan-class test (BASH_VERSION is set) wrongly excluded.
  _pix_shim_literal=
  if _pix_shim=$(env_shim_path); then
    _pix_shim_literal=$(shell_quote "$_pix_shim") || { unset _pix_active_literal _pix_shim; return 1; }
  fi
  unset _pix_shim
  # _valise_seen means this process already installed exports of ours, so the
  # source that follows must clear them first or the compiled plan reports its
  # own earlier definitions as a foreign conflict. It is deliberately NOT "this
  # release was attempted": on the FIRST load of a release nothing is owned yet,
  # so a genuine foreign conflict is still reported, and a second read of the
  # SAME release is skipped by the guard, not reloaded.
  printf '%s\n' \
    '# BEGIN valise managed block' \
    "_valise_active_link=$_pix_active_literal" \
    'if [ -n "${KSH_VERSION-}" ]; then _valise_plan=ksh; elif [ -n "${ZSH_VERSION-}" ]; then _valise_plan=zsh; elif [ -n "${BASH_VERSION-}" ]; then _valise_plan=bash; else _valise_plan=sh; fi' \
    '_valise_active=$(cd "$_valise_active_link" 2>/dev/null && pwd -P)' \
    '_valise_stage1_ok=1' \
    'if [ -n "$_valise_active" ]; then' \
    '  _valise_release_id=${_valise_active##*/}' \
    '  _valise_seen=0' \
    '  _valise_plan_carried=' \
    '  if [ -n "${_valise_plan_owned:-}" ] || [ "${VALISE_RELOAD:-}" = 1 ]; then' \
    '    _valise_seen=1' \
    '  fi' \
    '  _valise_want=0' \
    '  if [ "${_valise_profile_loaded:-}" != "$_valise_release_id" ] ||' \
    '    [ "${VALISE_RELOAD:-}" = 1 ]; then' \
    '    _valise_want=1' \
    '  elif [ "${_valise_env_repair:-}" = armed ] || [ "${_valise_env_tried:-}" != "$_valise_release_id" ]; then' \
    '    _valise_want=1' \
    '  elif [ "${_valise_env_path-}" != "${PATH-}" ]; then' \
    '    _valise_want=1' \
    '  fi' \
    '  if [ "${_valise_env_repair:-}" = armed ]; then _valise_env_repair=done; fi' \
    '  if [ "$_valise_want" -eq 1 ]; then' \
    '    if [ -f "$_valise_active/plans/$_valise_plan.sh" ]; then' \
    '      _valise_had=${VALISE_RELOAD+x}' \
    '      _valise_old=${VALISE_RELOAD-}' \
    '      if [ "$_valise_seen" -eq 1 ]; then' \
    '        VALISE_RELOAD=1' \
    '      fi' \
    '      VALISE_MODULE_ROOT="$_valise_active"' \
    '      . "$_valise_active/plans/$_valise_plan.sh"' \
    '      _valise_rc=$?' \
    '      unset VALISE_MODULE_ROOT' \
    '      if [ -n "$_valise_had" ]; then VALISE_RELOAD=$_valise_old; else unset VALISE_RELOAD; fi' \
    '      _valise_env_tried=$_valise_release_id' \
    '      _valise_env_rel=$_valise_release_id' \
    '      _valise_env_carry=${_valise_plan_carried:-}' \
    '      if [ "$_valise_rc" -eq 0 ]; then' \
    '        _valise_env_ok=1' \
    '        _valise_env_path=$PATH' \
    '        _valise_profile_loaded=$_valise_release_id' \
    '        case $- in' \
    '        *l*) [ -n "${_valise_env_repair:-}" ] || _valise_env_repair=armed ;;' \
    '        esac' \
    '      else' \
    '        _valise_env_ok=0' \
    '        _valise_stage1_ok=0' \
    '        unset _valise_profile_loaded' \
    '      fi' \
    '    else' \
    '      _valise_stage1_ok=0' \
    '      _valise_env_ok=0' \
    '      unset _valise_profile_loaded' \
    '    fi' \
    '  else' \
    '    _valise_plan_carried=${_valise_env_carry:-}' \
    '    if [ "${_valise_env_rel:-}" != "$_valise_release_id" ] || [ "${_valise_env_ok:-0}" != 1 ]; then' \
    '      _valise_stage1_ok=0' \
    '    fi' \
    '  fi'
  if [ "$_pix_stage" = all ]; then
    printf '%s\n' \
      '  if [ "$_valise_stage1_ok" -eq 1 ]; then' \
      '  case $- in *i*)' \
      '    if [ "${_valise_interactive_loaded:-}" != "$_valise_release_id" ] ||' \
      '      [ "${VALISE_RELOAD:-}" = 1 ]; then' \
      '      if [ -f "$_valise_active/plans/$_valise_plan-interactive.sh" ]; then' \
      '        _valise_had=${VALISE_RELOAD+x}' \
      '        _valise_old=${VALISE_RELOAD-}' \
      '        if [ "$_valise_seen" -eq 1 ]; then' \
      '          VALISE_RELOAD=1' \
      '        fi' \
      '        VALISE_MODULE_ROOT="$_valise_active"' \
      '        . "$_valise_active/plans/$_valise_plan-interactive.sh"' \
      '        _valise_rc=$?' \
      '        unset VALISE_MODULE_ROOT' \
      '        if [ -n "$_valise_had" ]; then VALISE_RELOAD=$_valise_old; else unset VALISE_RELOAD; fi' \
      '        if [ "$_valise_rc" -eq 0 ]; then _valise_interactive_loaded=$_valise_release_id; fi' \
      '      else' \
      '        _valise_interactive_loaded=$_valise_release_id' \
      '      fi' \
      '    fi' \
      '    ;;' \
      '  esac' \
      '  fi'
  fi
  printf '%s\n' \
    '  unset _valise_release_id _valise_want _valise_had _valise_old _valise_rc _valise_seen _valise_stage1_ok _valise_int_tried' \
    'fi' \
    'unset _valise_plan_carried'
  if [ -n "$_pix_shim_literal" ]; then
    # A `$`-containing ENV is the shell's own indirection (and ksh tilde-expands
    # a leading `~`), so either spelling is user-owned and never repointed.
    printf '%s\n' \
      'if [ -f '"$_pix_shim_literal"' ]; then' \
      '  case "${ENV:-}" in' \
      "  '') ENV=$_pix_shim_literal; export ENV ;;" \
      '  *"\$"* | "~"*) : ;;' \
      "  *) [ -e \"\$ENV\" ] || [ -L \"\$ENV\" ] || { ENV=$_pix_shim_literal; export ENV; } ;;" \
      '  esac' \
      'fi'
  fi
  printf '%s\n' \
    'unset _valise_active _valise_plan' \
    'unset _valise_active_link' \
    '# END valise managed block'
  unset _pix_active_literal _pix_shim_literal _pix_stage
}

# env_shim_path: the $ENV shim install writes for sh/ksh subshells. It is
# derived from VALISE_XDG_CONFIG, the normalized configuration root, so a
# relative XDG_CONFIG_HOME or a trailing slash cannot place the shim relative
# to whatever directory the caller happened to be in (the release tree, during
# an install). Without HOME there is no user configuration root, so there is
# no shim either.
env_shim_path() {
  [ -n "${HOME:-}${XDG_CONFIG_HOME:-}" ] || return 1
  printf '%s\n' "$VALISE_XDG_CONFIG/env.sh"
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
# The markers are matched as WHOLE LINES: a file that merely mentions the
# marker text in prose, or a foreign file that happens to carry the string, is
# not valise-owned, and must never be rewritten or deleted because of a
# substring match.
integration_has_managed_block() {
  _ihb_awk=$(trusted_utility_path awk) || return 1
  "$_ihb_awk" '
    $0 == "# BEGIN valise managed block" { found = 1; exit }
    $0 == "# valise Fish integration. Do not edit." { found = 1; exit }
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
    if [ -e "$2/.bash_profile" ] || [ -L "$2/.bash_profile" ]; then
      printf '%s\n' "$2/.bash_profile"
    elif [ -e "$2/.bash_login" ] || [ -L "$2/.bash_login" ]; then
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
# Each line is "<stage>\t<path>", where <stage> selects the block variant:
#   env  stage 1 only. Every file the shell reads before its rc stage gets this,
#        so the env plan applies everywhere and interactive setup cannot run
#        before the rc file it belongs to.
#   all  both stages. The shell's rc-stage file gets this: ~/.bashrc,
#        ~/.zshrc, or the $ENV shim (which sh/ksh interactive subshells read),
#        and the file a login bash reads (see print_posix_integration), so an
#        interactive bash login reaches the interactive stage.
#
# posix_startup_targets <home>
# prints one "<stage>\t<path>" record per line.
posix_startup_targets() {
  # A login bash reads the FIRST of .bash_profile, .bash_login and .profile that
  # exists, and never .bashrc. The file it reads therefore carries the
  # interactive stage whenever bash has an rc chain, placed at its END: a
  # `. ~/.bashrc` the user wrote above the block has already run, and the
  # release-keyed guard keeps the interactive plan from loading twice.
  _pst_bash_rc=0
  case "${SHELL:-}" in
  */bash | bash) _pst_bash_rc=1 ;;
  esac
  if [ -e "$1/.bashrc" ] || [ -L "$1/.bashrc" ]; then _pst_bash_rc=1; fi
  _pst_bash_stage=env
  [ "$_pst_bash_rc" -eq 0 ] || _pst_bash_stage=all
  _pst_bash_login=$1/.profile
  if [ -e "$1/.bash_profile" ] || [ -L "$1/.bash_profile" ]; then
    _pst_bash_login=$1/.bash_profile
  elif [ -e "$1/.bash_login" ] || [ -L "$1/.bash_login" ]; then
    _pst_bash_login=$1/.bash_login
  fi
  # .profile is always written: sh, ksh and dash read it at login. It is the
  # bash login file only when no .bash_profile or .bash_login exists.
  if [ "$_pst_bash_login" != "$1/.profile" ]; then
    printf 'env\t%s\n' "$1/.profile"
  fi
  printf '%s\t%s\n' "$_pst_bash_stage" "$_pst_bash_login"
  unset _pst_bash_rc _pst_bash_stage _pst_bash_login
  case "${SHELL:-}" in
  */bash | bash) printf 'all\t%s\n' "$1/.bashrc" ;;
  *) if [ -e "$1/.bashrc" ] || [ -L "$1/.bashrc" ]; then printf 'all\t%s\n' "$1/.bashrc"; fi ;;
  esac
  if [ -e "$1/.zprofile" ] || [ -L "$1/.zprofile" ] || command -v zsh >/dev/null 2>&1; then
    printf 'env\t%s\n' "$1/.zprofile"
  fi
  case "${SHELL:-}" in
  */zsh | zsh) printf 'all\t%s\n' "$1/.zshrc" ;;
  *) if [ -e "$1/.zshrc" ] || [ -L "$1/.zshrc" ]; then printf 'all\t%s\n' "$1/.zshrc"; fi ;;
  esac
  # zsh reads ~/.zshenv for EVERY invocation (login or not, interactive or
  # not), before /etc/zprofile runs path_helper on macOS, so the managed
  # block there covers 'zsh -c' env and the .zprofile block repairs PATH
  # after path_helper; double evaluation is harmless (release-id guard +
  # convergent env plan). It is an ENV-stage file: an interactive zsh already
  # has 'i' in $- here, and interactive setup belongs in ~/.zshrc.
  if [ -e "$1/.zshenv" ] || [ -L "$1/.zshenv" ] || command -v zsh >/dev/null 2>&1; then
    printf 'env\t%s\n' "$1/.zshenv"
  fi
}

# Write the managed block to every startup file install manages.
write_posix_integration() {
  if [ -z "${HOME:-}" ]; then
    info "warning: HOME is not set; no startup file was written"
    return 0
  fi
  _wpi_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
  _wpi_targets=$(posix_startup_targets "$_wpi_home")
  while IFS="$(printf '\t')" read -r _wpi_stage _wpi_target; do
    [ -n "$_wpi_target" ] || continue
    # A file can appear once per stage, but never twice: the two variants differ,
    # so the later one would simply replace the earlier one's block.
    _wpi_snippet=$(print_posix_integration "$_wpi_stage") || die "cannot generate integration block"
    project_write_integration "$_wpi_target" "$_wpi_snippet"
  done <<EOF
$_wpi_targets
EOF
  # The $ENV shim for sh/ksh subshells. Its content IS the managed block for
  # the RC STAGE: re-asserting the same ENV from inside the shim is a no-op, so
  # no second-generation variant is needed, and an interactive subshell reading
  # it gets the interactive plan at the stage an rc file would have provided
  # it. It is written and removed as a managed startup file, so every other byte
  # in the file survives and a file install created is deleted only when the
  # created-ledger says so.
  _wpi_shim=$(env_shim_path) || {
    unset _wpi_home _wpi_snippet _wpi_targets _wpi_target _wpi_stage
    return 0
  }
  _wpi_shim_parent=$(path_parent "$_wpi_shim")
  _wpi_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  [ -d "$_wpi_shim_parent" ] || "$_wpi_mkdir" -p "$_wpi_shim_parent" || die "cannot create shim parent: $_wpi_shim_parent"
  if [ -e "$_wpi_shim" ] || [ -L "$_wpi_shim" ]; then
    if [ -L "$_wpi_shim" ] || ! integration_has_managed_block "$_wpi_shim" 2>/dev/null; then
      info "warning: leaving $_wpi_shim: it is not the valise ENV shim"
      unset _wpi_home _wpi_snippet _wpi_targets _wpi_target _wpi_stage _wpi_shim _wpi_shim_parent _wpi_mkdir
      return 0
    fi
  fi
  _wpi_snippet=$(print_posix_integration all) || die "cannot generate integration block"
  project_write_integration "$_wpi_shim" "$_wpi_snippet"
  info "ENV shim deployed: $_wpi_shim"
  unset _wpi_home _wpi_snippet _wpi_targets _wpi_target _wpi_stage _wpi_shim _wpi_shim_parent _wpi_mkdir
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
  _doctor_active_target=
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
      _doctor_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
      # Every startup file valise manages is inspected, not only ~/.profile: an
      # upgrade from a single-stage install may have left a legacy block in
      # .bashrc, .zshrc or .zprofile alone.
      # The file a login bash reads carries the interactive stage when bash has an
      # rc chain (see posix_startup_targets), so it is judged by the gate exactly
      # like the rc-stage files. Every other env-only file is the current shape.
      _doctor_bash_rc=0
      case "${SHELL:-}" in
      */bash | bash) _doctor_bash_rc=1 ;;
      esac
      if [ -e "$HOME/.bashrc" ] || [ -L "$HOME/.bashrc" ]; then _doctor_bash_rc=1; fi
      _doctor_bash_login=.profile
      if [ -e "$HOME/.bash_profile" ] || [ -L "$HOME/.bash_profile" ]; then
        _doctor_bash_login=.bash_profile
      elif [ -e "$HOME/.bash_login" ] || [ -L "$HOME/.bash_login" ]; then
        _doctor_bash_login=.bash_login
      fi
      for _doctor_name in $VALISE_STARTUP_NAMES; do
        _doctor_file="$HOME/$_doctor_name"
        [ -f "$_doctor_file" ] && [ ! -L "$_doctor_file" ] || continue
        integration_has_posix_block "$_doctor_file" || continue
        case "$_doctor_name" in
        .bashrc | .zshrc) ;;
        "$_doctor_bash_login")
          [ "$_doctor_bash_rc" -eq 1 ] || continue
          ;;
        *) continue ;;
        esac
        if ! "$_doctor_awk" '
          /^# BEGIN valise managed block$/ { inblock = 1 }
          inblock && /case \$- in \*i\*\)/ { gate = 1 }
          /^# END valise managed block$/ { inblock = 0 }
          END { exit gate ? 0 : 1 }
        ' "$_doctor_file"; then
          printf '  warn: %s has a legacy single-stage block; run valise install again to upgrade to the two-stage block\n' "$_doctor_file"
        fi
      done
      # $ENV wiring for sh/ksh: unset is as broken as foreign, because an
      # interactive sh/ksh subshell then reads nothing at all.
      #
      # An ENV containing `$` or starting with `~` is USER-OWNED: the block
      # deliberately leaves it alone (the shell expands `$`, and ksh
      # tilde-expands a leading `~` - both verified), so warning about it here
      # would report a file the user chose. Comparisons otherwise use the
      # normalized path so an equivalent spelling does not false-warn;
      # path_normalize does NOT expand `~`, which is exactly why that case is
      # handled by the ownership test rather than by normalization.
      case "${_doctor_shell:-}" in
        ksh|sh|"")
          if _doctor_shim=$(env_shim_path); then
            _doctor_env=${ENV:-}
            if [ -z "$_doctor_env" ]; then
              if [ -f "$_doctor_shim" ]; then
                printf '  warn: $ENV is unset; interactive sh/ksh subshells will not load valise (the shim is at %s)\n' "$_doctor_shim"
              fi
            else
              case "$_doctor_env" in
              *'$'* | '~'*) : ;;
              *)
                if _doctor_env_norm=$(path_normalize "$_doctor_env" 2>/dev/null); then
                  if [ "$_doctor_env_norm" != "$_doctor_shim" ]; then
                    printf '  warn: $ENV points at %s, not the valise shim %s; interactive sh/ksh subshells will not load valise\n' "$_doctor_env" "$_doctor_shim"
                  fi
                fi
                ;;
              esac
            fi
          fi
          ;;
      esac
      # zsh reads ~/.zshenv for every invocation, so its absence is a defect
      # whenever zsh is INSTALLED - install writes the block on zsh presence,
      # not on $SHELL.
      if command -v zsh >/dev/null 2>&1; then
        if [ ! -f "$HOME/.zshenv" ] || ! integration_has_managed_block "$HOME/.zshenv" 2>/dev/null; then
          printf '  warn: no valise managed block in ~/.zshenv; non-login zsh (zsh -c) will not load the env plan\n'
        fi
      fi
      # GUI-session bridge diagnostics: on platforms where GUI apps never read
      # a startup file, only the environment.d (systemd) or LaunchAgent
      # (launchd) bridge can carry the env plan into the session. This is only
      # worth reporting when the ACTIVE RELEASE asked for a bridge: gui_env=off
      # is the deliberate default and must not warn on every such machine. The
      # mode is also platform-gated, exactly like the write path
      # (gui_env_bridge_stage) and the preview: systemd is only written on
      # Linux and launchd only on macOS, so warning about a bridge the platform
      # can never write would send the user to an install that skips it.
      if [ "$_doctor_active_ok" -eq 1 ]; then
        if _doctor_bridge_mode=$(gui_env_mode "$_doctor_active_target" 2>/dev/null); then
          _doctor_bridge_os=
          case "$_doctor_bridge_mode" in
          systemd) _doctor_bridge_os=linux ;;
          launchd) _doctor_bridge_os=darwin ;;
          esac
          if [ -n "$_doctor_bridge_os" ] && [ "$(cli_os_name)" = "$_doctor_bridge_os" ]; then
            case "$_doctor_bridge_mode" in
            systemd)
              if [ ! -f "$(gui_env_file systemd 2>/dev/null)" ]; then
                printf '  warn: the active release sets gui_env=systemd but there is no environment.d/10-valise.conf; run valise install again\n'
              fi
              ;;
            launchd)
              if [ ! -f "$(gui_env_file launchd 2>/dev/null)" ]; then
                printf '  warn: the active release sets gui_env=launchd but there is no ~/Library/LaunchAgents/sh.valise.env.plist; run valise install again\n'
              fi
              ;;
            esac
          fi
        fi
      fi
      unset _doctor_awk _doctor_name _doctor_file _doctor_shim _doctor_env _doctor_env_norm _doctor_bridge_mode _doctor_bridge_os _doctor_bash_rc _doctor_bash_login _doctor_active_target _doctor_active_ok
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
