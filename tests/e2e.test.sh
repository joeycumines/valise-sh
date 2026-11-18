#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Cross-platform end-to-end test for the valise-sh engine.
#
# examples/e2e is a valise project. This suite builds it with `valise build`,
# then in a quarantined HOME per shell: installs the release with
# `valise install`, runs `valise release verify`, starts the shell through
# the startup file valise wrote (the managed block for POSIX shells, the
# conf.d hook for Fish), checks that exactly the bundle's modules for that
# shell and platform are loaded with no diagnostics, and installs a second
# time to prove idempotency. A host-only tamper lane proves the seal end to
# end. A host-only composition lane vendors examples/shared into a staged
# copy of the project as layers/shared, the way a consuming project composes
# a provider, and proves the layer's modules resolve, ship, and load.
#
# Lanes (each runs every shell available in that environment):
#   Host (macOS): sh, bash, zsh, ksh, dash, fish
#   Lima valise-linux-full: sh, bash, zsh, ksh, dash, fish
#   Lima valise-busybox: ash (via busybox)
#   Lima valise-bsd-test: sh, bash, ksh (skipped if instance absent/stopped)

set -u

_pass=0
_fail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); _total=$((_total + 1)); }
fail() { printf '  FAIL: %s\n' "$1" >&2; _fail=$((_fail + 1)); _total=$((_total + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); _total=$((_total + 1)); }

tooling_required() {
  for _e2e_flag in "${VALISE_REQUIRE_TOOLING:-}" "${CI:-}" "${GITHUB_ACTIONS:-}"; do
    case "$_e2e_flag" in
      1|true|TRUE|yes|YES) return 0 ;;
    esac
  done
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
E2E_ROOT="$REPO_ROOT/examples/e2e"
E2E_RELEASE="$E2E_ROOT/build/release"
VALISE="$REPO_ROOT/bin/valise"

# The engine's Fish surface rejects double-slash paths (fail-closed
# canonical-path rule). macOS TMPDIR ends with a slash, so a plain
# "${TMPDIR}/x" template would place every quarantined home behind a
# '//' component. Strip the trailing slash, like the fish-runtime suite.
_e2e_tmpdir=${TMPDIR:-/tmp}
case $_e2e_tmpdir in
  /) ;;
  *) _e2e_tmpdir=${_e2e_tmpdir%/} ;;
esac

# The startup file valise writes for a shell when SHELL names it: bash reads
# ~/.bashrc, zsh ~/.zshrc, Fish its conf.d hook, and every other POSIX shell
# (sh, dash, ksh, busybox ash) the managed block in ~/.profile.
startup_file_for() {
  case "$1" in
    bash) printf '%s\n' .bashrc ;;
    zsh) printf '%s\n' .zshrc ;;
    fish) printf '%s\n' .config/fish/conf.d/valise.fish ;;
    *) printf '%s\n' .profile ;;
  esac
}

# _e2e_filter_shell_noise: drop only the SHELL'S OWN diagnostics for an
# interactive invocation without a controlling terminal, so a module's real
# stderr stays fatal.
#   bash  'no job control in this shell'
#         'cannot set terminal process group (...): Inappropriate ioctl ...'
#   ksh93 a bare newline (verified: emitted for any -i with non-tty stdin)
# Anything else passes through and fails the silence assertion it belongs to.
_e2e_filter_shell_noise() {
  # Diagnostic lines a HOST emits when an interactive shell is started with no
  # terminal. None of them is valise output:
  #   - job control notices come from the shell's own tty setup;
  #   - "not interactive and can't open terminal" is a zsh string (present in
  #     the binary as a literal) emitted when zle cannot attach;
  #   - the compinit pair comes from Debian/Ubuntu's /etc/zsh/zshrc, which runs
  #     compinit unless the user sets skip_global_compinit, and compinit aborts
  #     when it cannot probe the terminal.
  # Filtering them keeps each assertion about valise's own silence instead of
  # about the distro's interactive defaults. The tests still fail on any line
  # valise itself writes.
  sed -e '/no job control in this shell$/d' \
    -e '/cannot set terminal process group/d' \
    -e "/^not interactive and can't open terminal$/d" \
    -e '/^compinit: initialization aborted$/d' \
    -e '/^$/d'
}

# _e2e_rc_file_for <lane-shell> <home>: the startup file that carries the
# INTERACTIVE stage for a POSIX shell.
#
# The PLAN is chosen by the class the shell reports (macOS /bin/sh is bash and
# uses the bash plan), but the STARTUP FILE is chosen by how the shell is
# INVOKED - which is what the lane name records:
#   bash lane -> ~/.bashrc          zsh lane -> ~/.zshrc
#   sh/dash/ksh/busybox -> the $ENV shim: no rc file exists for those
#     invocations, and an interactive one reads the file $ENV names. That stays
#     true for macOS /bin/sh, which is bash invoked as `sh`.
_e2e_rc_file_for() {
  case "$1" in
    bash) printf '%s\n' "$2/.bashrc" ;;
    zsh) printf '%s\n' "$2/.zshrc" ;;
    *) printf '%s\n' "$2/.config/valise/env.sh" ;;
  esac
}

# _e2e_stage1_only_file <class> <home>: a startup file for the shell that must
# carry stage 1 but NEVER the interactive stage. ~/.profile is read by every
# POSIX shell, so it is the strongest witness for bash and ksh; zsh never reads
# it, so zsh's witness is ~/.zshenv.
_e2e_stage1_only_file() {
  case "$1" in
    zsh) printf '%s\n' "$2/.zshenv" ;;
    *) printf '%s\n' "$2/.profile" ;;
  esac
}

# The exports the default bundle loads in a shell on a platform (uname -s),
# and the exports it must not load there. Printed as two lines:
# "expect <names...>" and "absent <names...>".
#
# The non-interactive probe sources the startup file with shell -c, so the
# interactive-phase modules (aliases, completions, ksh features) must be
# ABSENT there; the interactive probe (shell -i -c) expects them PRESENT.
# expected_exports_for therefore takes an interactivity flag.
expected_exports_for() {
  _eef_shell=$1
  _eef_os=$2
  _eef_interactive=${3:-0}
  case "$_eef_shell" in
    fish)
      printf '%s\n' 'expect e2e_fish_loaded' 'absent e2e_env_ready'
      return 0
      ;;
  esac
  _eef_expect='e2e_env_ready e2e_config_loaded e2e_net_available e2e_layer_probe_ok e2e_bin_dir'
  _eef_absent='e2e_fish_loaded'
  case "$_eef_shell" in
    bash) _eef_int='e2e_show_aliases e2e_bash_completions_loaded'
      _eef_absent="$_eef_absent e2e_zsh_completions_loaded e2e_ksh_loaded" ;;
    zsh) _eef_int='e2e_show_aliases e2e_zsh_completions_loaded'
      _eef_absent="$_eef_absent e2e_bash_completions_loaded e2e_ksh_loaded" ;;
    ksh) _eef_int='e2e_ksh_loaded'
      _eef_absent="$_eef_absent e2e_show_aliases e2e_bash_completions_loaded e2e_zsh_completions_loaded" ;;
    *) _eef_int='e2e_show_aliases e2e_bash_completions_loaded e2e_zsh_completions_loaded e2e_ksh_loaded'
      _eef_absent="$_eef_absent $_eef_int" ;;
  esac
  if [ "$_eef_interactive" = 1 ]; then
    _eef_expect="$_eef_expect $_eef_int"
  else
    _eef_absent="$_eef_absent $_eef_int"
  fi
  case "$_eef_os" in
    Darwin) _eef_expect="$_eef_expect e2e_darwin_tools_ready"
      _eef_absent="$_eef_absent e2e_linux_tools_ready e2e_bsd_tools_ready" ;;
    Linux) _eef_expect="$_eef_expect e2e_linux_tools_ready"
      _eef_absent="$_eef_absent e2e_darwin_tools_ready e2e_bsd_tools_ready" ;;
    *BSD) _eef_expect="$_eef_expect e2e_bsd_tools_ready"
      _eef_absent="$_eef_absent e2e_darwin_tools_ready e2e_linux_tools_ready" ;;
  esac
  printf 'expect %s\nabsent %s\n' "$_eef_expect" "$_eef_absent"
}

# The plan class the managed block selects in a shell: the first of
# KSH_VERSION, ZSH_VERSION and BASH_VERSION that is set, else sh. A shell
# binary named sh may be another shell (macOS /bin/sh is bash), so the class
# is asked of the shell itself.
_class_probe='if [ -n "${KSH_VERSION-}" ]; then echo ksh; elif [ -n "${ZSH_VERSION-}" ]; then echo zsh; elif [ -n "${BASH_VERSION-}" ]; then echo bash; else echo sh; fi'

# A POSIX probe that sources a startup file and reports each name as
# "has <name>" or "lacks <name>", for names given as arguments. It is passed
# to the shell as a -c script so the startup-file path travels in argv.
_posix_probe='_f=$1; shift; . "$_f"; for _n do if command -v "$_n" >/dev/null 2>&1; then printf "has %s\n" "$_n"; else printf "lacks %s\n" "$_n"; fi; done'
_fish_probe='for _n in $argv; if functions -q $_n; printf "has %s\n" $_n; else; printf "lacks %s\n" $_n; end; end; test "$VALISE_FISH_READY" = 1; and printf "ready\n"'

# check_load <label> <probe-output-file> <expect-line> <absent-line> <stderr-file>
check_load() {
  _cl_label=$1
  _cl_missing=
  _cl_extra=
  for _cl_name in ${3#expect }; do
    grep -qx "has $_cl_name" "$2" || _cl_missing="$_cl_missing $_cl_name"
  done
  for _cl_name in ${4#absent }; do
    grep -qx "lacks $_cl_name" "$2" || _cl_extra="$_cl_extra $_cl_name"
  done
  if [ -z "$_cl_missing" ] && [ -z "$_cl_extra" ] && [ ! -s "$5" ]; then
    pass "$_cl_label: the startup file loads exactly the bundle's modules, silently"
  else
    fail "$_cl_label: startup file load (missing:${_cl_missing:- none}; unexpected:${_cl_extra:- none})"
    cat "$2" "$5" >&2
  fi
}

_cleanup_home() {
  # Releases are sealed 0444/0555; restore write before rm.
  chmod -R u+w "$1" 2>/dev/null || :
  rm -rf "$1" 2>/dev/null || :
}

# _home_env <home> <command...>: run a command with HOME and XDG roots inside
# the quarantined home and a fixed PATH.
_home_env() {
  _he_home=$1
  shift
  env HOME="$_he_home" \
    XDG_DATA_HOME="$_he_home/.local/share" \
    XDG_CONFIG_HOME="$_he_home/.config" \
    XDG_STATE_HOME="$_he_home/.local/state" \
    PATH="$REPO_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# _probe_term: a usable TERM for a child shell. Fish treats an unset or
# "unknown" terminal as unusable; a real session never does, and autoloading a
# stock Fish function that runs tput would otherwise write terminal errors to
# stderr that valise did not produce.
_probe_term() {
  case "${TERM:-}" in
    ''|unknown|dumb) printf '%s\n' xterm ;;
    *) printf '%s\n' "$TERM" ;;
  esac
}

# --- Host lanes ---
run_lane() {
  _lane=$1
  _shell_name=$2
  _shell_path=$3

  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e.XXXXXX") || {
    skip "$_lane/$_shell_name: cannot create temp home"
    return 0
  }

  (cd "$E2E_RELEASE" && _home_env "$_tmp_home" SHELL="$_shell_path" "$VALISE" install) >"$_tmp_home/install1.out" 2>&1
  _install_status=$?
  if [ "$_install_status" -ne 0 ]; then
    fail "$_lane/$_shell_name: valise install failed (exit $_install_status)"
    cat "$_tmp_home/install1.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi
  if grep -q 'installing release' "$_tmp_home/install1.out"; then
    pass "$_lane/$_shell_name: valise install succeeds"
  else
    fail "$_lane/$_shell_name: valise install unexpected output"
    cat "$_tmp_home/install1.out" >&2
  fi

  if _home_env "$_tmp_home" "$VALISE" release verify >"$_tmp_home/verify.out" 2>&1; then
    pass "$_lane/$_shell_name: valise release verify passes"
  else
    fail "$_lane/$_shell_name: valise release verify failed"
    cat "$_tmp_home/verify.out" >&2
  fi

  _snippet="$_tmp_home/$(startup_file_for "$_shell_name")"
  if [ -f "$_snippet" ]; then
    pass "$_lane/$_shell_name: shell integration written to $(startup_file_for "$_shell_name")"
  else
    fail "$_lane/$_shell_name: shell integration missing: $_snippet"
  fi

  _class=$_shell_name
  [ "$_shell_name" = fish ] || _class=$("$_shell_path" -c "$_class_probe" 2>/dev/null) || _class=$_shell_name
  # The bundle's interactive-phase modules (aliases, completions, ksh
  # features) ship in plans/<class>-interactive.sh and must load only in an
  # interactive shell; the env plan must not contain them. The sh lane runs
  # on /bin/sh, which on macOS is bash, so its detected class is bash and the
  # class plans are what the managed block selects there.
  if [ "$_shell_name" != fish ]; then
    _int_plan="$E2E_RELEASE/plans/$_class-interactive.sh"
    if [ -f "$_int_plan" ]; then
      # The interactive plan's # order= lists only interactive modules; env
      # modules may appear only as dependency names inside the unavailable-
      # module diagnostics, never as case labels or load paths.
      if grep -q 'phase=interactive' "$_int_plan" &&
        ! grep -qE '^[[:space:]]*(e2e_env_setup|e2e_generated_config|e2e_optional_network|e2e_layer_probe|e2e_platform_tools)@' "$_int_plan" &&
        ! grep -q 'modules/e2e/env_setup.sh\|modules/e2e/generated_config.sh' "$_int_plan"; then
        pass "$_lane/$_shell_name: the interactive plan carries only interactive-phase modules"
      else
        fail "$_lane/$_shell_name: the interactive plan is not phase-pure"
        head -6 "$_int_plan" >&2
      fi
    else
      case "$_class" in
        bash|zsh|ksh)
          fail "$_lane/$_shell_name: no interactive plan for a bundle that has interactive modules"
          ;;
        *)
          pass "$_lane/$_shell_name: no interactive plan when the closure has no interactive modules"
          ;;
      esac
    fi
    if ! grep -q 'e2e_aliases@\|e2e_completions_bash@\|e2e_completions_zsh@\|e2e_ksh_features@' "$E2E_RELEASE/plans/$_class.sh" 2>/dev/null; then
      pass "$_lane/$_shell_name: the env plan contains no interactive-phase module"
    else
      fail "$_lane/$_shell_name: the env plan leaks an interactive-phase module"
      grep -n 'e2e_aliases@\|e2e_completions_bash@\|e2e_completions_zsh@\|e2e_ksh_features@' "$E2E_RELEASE/plans/$_class.sh" >&2
    fi
  fi
  # The main load probe is non-interactive (shell -c), so interactive-phase
  # exports are expected absent there.
  _expected=$(expected_exports_for "$_class" "$(uname -s)" 0)
  _expect_line=$(printf '%s\n' "$_expected" | sed -n 1p)
  _absent_line=$(printf '%s\n' "$_expected" | sed -n 2p)
  if [ "$_shell_name" = fish ]; then
    # Fish reads its conf.d hook at startup: the hook authenticates the
    # active release and sources the release's runtime/fish/profile.fish.
    # A real Fish session always has a usable TERM; without one Fish reports
    # "unknown", and autoloading a stock function that runs tput (for example
    # __fish_cancel_commandline, whose definition clears to end of line) then
    # writes "tput: unknown terminal" to stderr. That is Fish's own startup
    # noise, not valise output, so give the probe a terminal like a user's.
    # shellcheck disable=SC2086
    _home_env "$_tmp_home" TERM="$(_probe_term)" "$_shell_path" -c "$_fish_probe" ${_expect_line#expect } ${_absent_line#absent } \
      >"$_tmp_home/load.out" 2>"$_tmp_home/load.err"
    check_load "$_lane/$_shell_name" "$_tmp_home/load.out" "$_expect_line" "$_absent_line" "$_tmp_home/load.err"
    if grep -qx ready "$_tmp_home/load.out"; then
      pass "$_lane/$_shell_name: the Fish hook publishes readiness"
    else
      fail "$_lane/$_shell_name: the Fish hook did not publish readiness"
    fi
    # An invalid mode must fail closed through the deployed hook: no
    # readiness marker and no module export may survive.
    _home_env "$_tmp_home" VALISE_MODE=not-a-real-mode "$_shell_path" \
      -c 'builtin set -q VALISE_FISH_READY; and exit 1; builtin functions -q e2e_fish_loaded; and exit 1; exit 0' \
      >"$_tmp_home/fish-fail.out" 2>&1
    if [ $? -eq 0 ]; then
      pass "$_lane/$_shell_name: failed Fish activation leaves no readiness marker"
    else
      fail "$_lane/$_shell_name: failed Fish activation leaked readiness"
      cat "$_tmp_home/fish-fail.out" >&2
    fi
  else
    # shellcheck disable=SC2086
    env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
      "$_shell_path" -c "$_posix_probe" probe "$_snippet" ${_expect_line#expect } ${_absent_line#absent } \
      >"$_tmp_home/load.out" 2>"$_tmp_home/load.err"
    check_load "$_lane/$_shell_name" "$_tmp_home/load.out" "$_expect_line" "$_absent_line" "$_tmp_home/load.err"
  fi

  (cd "$E2E_RELEASE" && _home_env "$_tmp_home" SHELL="$_shell_path" "$VALISE" install) >"$_tmp_home/install2.out" 2>&1 || true
  if grep -q 'already installed' "$_tmp_home/install2.out"; then
    pass "$_lane/$_shell_name: second install is idempotent"
  else
    fail "$_lane/$_shell_name: second install was not idempotent"
    cat "$_tmp_home/install2.out" >&2
  fi

  # Two-stage block behavior, host lanes only (POSIX shells): a
  # non-interactive read of the startup file (as ssh host-cmd does) loads
  # the env plan, loads no interactive module, and prints nothing; an
  # interactive shell loads both. Re-reading the startup file in the same
  # shell is a no-op for the env plan (release-id guard), and a nested
  # shell re-runs the env plan, repairing a simulated path_helper reorder.
  # For zsh the non-login env path is ~/.zshenv (read by every zsh), so the
  # non-interactive probe sources .zshenv instead of the rc file; for sh/ksh
  # the interactive subshell path is $ENV, asserted separately below.
  if [ "$_shell_name" != fish ]; then
    _snippet="$_tmp_home/$(startup_file_for "$_shell_name")"
    _ni_snippet=$_snippet
    [ "$_class" = zsh ] && _ni_snippet="$_tmp_home/.zshenv"
    # Stage placement: the env stage is in every file; the INTERACTIVE stage is
    # only in the shell's rc-stage file. In an interactive zsh 'i' is already in
    # $- while .zshenv runs, so a stage 2 there would run interactive setup
    # before the user's .zshrc and the release guard would suppress the right,
    # later run.
    _stage2_file=$(_e2e_rc_file_for "$_shell_name" "$_tmp_home")
    _stage1_only=$(_e2e_stage1_only_file "$_class" "$_tmp_home")
    if [ "$_class" = bash ] && [ "$_shell_name" = bash ]; then
      # A login bash reads ONLY its login file (never .bashrc), so that file is
      # the one place a login shell can reach the interactive stage. In a fresh
      # home it is .profile, and it carries the interactive stage at its end;
      # .bashrc carries it too for non-login interactive shells.
      if grep -q 'case \$- in \*i\*)' "$_tmp_home/.profile" 2>/dev/null &&
        grep -q 'case \$- in \*i\*)' "$_tmp_home/.bashrc" 2>/dev/null; then
        pass "$_lane/$_shell_name: the bash login file and .bashrc both carry the interactive stage"
      else
        fail "$_lane/$_shell_name: the bash login file does not carry the interactive stage"
      fi
    elif [ "$_stage1_only" = "$_stage2_file" ]; then
      :
    elif grep -q 'case \$- in \*i\*)' "$_stage1_only" 2>/dev/null; then
      fail "$_lane/$_shell_name: $_stage1_only carries the interactive stage"
    elif grep -q 'case \$- in \*i\*)' "$_stage2_file" 2>/dev/null; then
      pass "$_lane/$_shell_name: the interactive stage lives only in the rc-stage file"
    else
      fail "$_lane/$_shell_name: the interactive stage is missing from the rc-stage file"
      grep -c 'case \$- in \*i\*)' "$_stage2_file" >&2 2>/dev/null || :
    fi
    _int_names=''
    case "$_class" in
      bash) _int_names='e2e_show_aliases e2e_bash_completions_loaded' ;;
      zsh)  _int_names='e2e_show_aliases e2e_zsh_completions_loaded' ;;
      ksh)  _int_names='e2e_ksh_loaded' ;;
    esac
    # zsh reads ~/.zshenv for EVERY invocation, so the block must exist there
    # (covering non-login 'zsh -c') in addition to the rc/login files.
    if [ "$_class" = zsh ]; then
      if [ -f "$_tmp_home/.zshenv" ] && grep -q '# BEGIN valise managed block' "$_tmp_home/.zshenv" &&
        grep -q 'plans/$_valise_plan.sh' "$_tmp_home/.zshenv"; then
        pass "$_lane/$_shell_name: the managed block is written to ~/.zshenv"
      else
        fail "$_lane/$_shell_name: ~/.zshenv lacks the managed block"
      fi
    fi
    # sh/ksh interactive subshells read $ENV. The .profile block wires ENV to
    # the valise shim unconditionally (bash ignores ENV as bash and reads it as
    # `sh`; dash and ksh read it), the shim is the RC-STAGE entry point for those
    # shells - so it carries BOTH stages - and .profile itself carries stage 1
    # only, exactly like every other env-stage file.
    case $_class in
      sh|ksh)
        _shim="$_tmp_home/.config/valise/env.sh"
        if grep -qF "ENV='$_shim'" "$_tmp_home/.profile" &&
          ! grep -q 'case \$- in \*i\*)' "$_tmp_home/.profile" &&
          [ -f "$_shim" ] &&
          grep -q '# BEGIN valise managed block' "$_shim" &&
          grep -q 'case \$- in \*i\*)' "$_shim"; then
          pass "$_lane/$_shell_name: .profile wires ENV at the shim, which carries the interactive stage"
        else
          fail "$_lane/$_shell_name: the ENV shim wiring is incomplete"
          ls -l "$_tmp_home/.profile" "$_shim" >&2 2>/dev/null || :
          grep -n 'ENV' "$_tmp_home/.profile" >&2 2>/dev/null || :
        fi
        ;;
    esac
    if [ -n "$_int_names" ]; then
      # shellcheck disable=SC2086
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c ". '$_ni_snippet'; if command -v e2e_env_ready >/dev/null; then printf 'env=yes'; else printf 'env=no'; fi; for _n in $_int_names; do command -v \"\$_n\" >/dev/null 2>&1 && printf ' int=%s' \"\$_n\"; done; printf '\n'" \
        >"$_tmp_home/ni.out" 2>"$_tmp_home/ni.err"
      if grep -q 'env=yes' "$_tmp_home/ni.out" && \
        ! grep -q 'int=' "$_tmp_home/ni.out" && \
        [ ! -s "$_tmp_home/ni.err" ]; then
        pass "$_lane/$_shell_name: non-interactive startup load is env-only and silent"
      else
        fail "$_lane/$_shell_name: non-interactive startup load is not env-only/silent"
        cat "$_tmp_home/ni.out" "$_tmp_home/ni.err" >&2
      fi
      # A bash binary invoked as `sh` READS $ENV for an interactive subshell
      # (bash's POSIX startup file), even though BASH_VERSION marks its plan
      # class as bash. The ENV stanza is therefore emitted unconditionally and
      # decided by the runtime, not by the plan class: a class test wrongly
      # excluded exactly this case. The probe must NOT pre-set ENV - that would
      # test nothing but its own fixture.
      if [ "$_class" = bash ] && [ -f "$E2E_RELEASE/plans/bash-interactive.sh" ]; then
        _as_sh_dir="$_tmp_home/as-sh"
        mkdir -p "$_as_sh_dir" 2>/dev/null || :
        if ln -sf "$_shell_path" "$_as_sh_dir/sh" 2>/dev/null; then
          env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
            "$_as_sh_dir/sh" -c '. "$HOME/.profile"; printf "ENV=%s\n" "${ENV:-unset}"' \
            >"$_tmp_home/assh.out" 2>/dev/null
          _as_sh_shim="$_tmp_home/.config/valise/env.sh"
          if grep -Fx "ENV=$_as_sh_shim" "$_tmp_home/assh.out" >/dev/null; then
            # The wiring is what makes the session work: an interactive child
            # inheriting that ENV must load both plans.
            env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
              "ENV=$_as_sh_shim" "$_as_sh_dir/sh" -i -c 'if command -v e2e_env_ready >/dev/null; then printf "env=yes"; fi; if command -v e2e_show_aliases >/dev/null 2>&1 || command -v e2e_bash_completions_loaded >/dev/null 2>&1; then printf " int=yes"; fi; printf "\n"' \
              >"$_tmp_home/assh-int.out" 2>/dev/null </dev/null
            if grep -q 'env=yes' "$_tmp_home/assh-int.out" &&
              grep -q 'int=yes' "$_tmp_home/assh-int.out"; then
              pass "$_lane/$_shell_name: a bash invoked as sh wires ENV and loads both plans"
            else
              fail "$_lane/$_shell_name: a bash invoked as sh wired ENV but did not load both plans"
              cat "$_tmp_home/assh-int.out" >&2 2>/dev/null || :
            fi
          else
            fail "$_lane/$_shell_name: a bash invoked as sh does not wire ENV"
            cat "$_tmp_home/assh.out" >&2 2>/dev/null || :
          fi
        else
          skip "$_lane/$_shell_name: a bash invoked as sh wires ENV (cannot create the symlink)"
        fi
      fi
      # zsh non-login env: 'zsh -c' reads only ~/.zshenv (plus /etc/zshenv);
      # with the block there, the env plan applies and the interactive plan
      # does not, with zero stderr.
      if [ "$_class" = zsh ]; then
        env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
          "$_shell_path" -c 'if command -v e2e_env_ready >/dev/null; then printf "zenv=yes"; else printf "zenv=no"; fi; if command -v e2e_show_aliases >/dev/null 2>&1; then printf " zint=yes"; fi; printf "\n"' \
          >"$_tmp_home/zc.out" 2>"$_tmp_home/zc.err"
        if grep -q 'zenv=yes' "$_tmp_home/zc.out" && \
          ! grep -q 'zint=' "$_tmp_home/zc.out" && \
          [ ! -s "$_tmp_home/zc.err" ]; then
          pass "$_lane/$_shell_name: zsh -c loads the env plan via ~/.zshenv, silently, no interactive plan"
        else
          fail "$_lane/$_shell_name: zsh -c did not load env-only via ~/.zshenv"
          cat "$_tmp_home/zc.out" "$_tmp_home/zc.err" >&2
        fi
      fi
      # shellcheck disable=SC2086
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -i -c ". '$_stage2_file'; _ok=1; for _n in $_int_names; do command -v \"\$_n\" >/dev/null 2>&1 || _ok=0; done; [ \"\$_ok\" -eq 1 ] && command -v e2e_env_ready >/dev/null && printf 'both=yes\n'" \
        >"$_tmp_home/int.out" 2>"$_tmp_home/int.err" </dev/null
      _e2e_filter_shell_noise <"$_tmp_home/int.err" >"$_tmp_home/int.err.filtered"
      if grep -q 'both=yes' "$_tmp_home/int.out" && [ ! -s "$_tmp_home/int.err.filtered" ]; then
        pass "$_lane/$_shell_name: interactive startup loads env and interactive plans, silently"
      else
        fail "$_lane/$_shell_name: interactive startup did not load the interactive plan silently"
        cat "$_tmp_home/int.out" "$_tmp_home/int.err" >&2
      fi
      # A login that reads more than one startup file (zsh: .zshenv, .zprofile,
      # .zshrc; bash with a .bash_profile that sources .bashrc; sh/ksh with
      # $ENV) must run each plan ONCE and stay silent. This is the defect the
      # release-id guard on stage 2 exists to prevent: a second source of the
      # interactive plan trips the compiler's export pre-check.
      _double_snippet=$_snippet
      [ "$_class" = zsh ] && _double_snippet="$_tmp_home/.zshenv"
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -i -c ". '$_double_snippet'; . '$_double_snippet'; . '$_double_snippet'; printf 'twice=done\n'" \
        >"$_tmp_home/twice.out" 2>"$_tmp_home/twice.err" </dev/null
      _e2e_filter_shell_noise <"$_tmp_home/twice.err" >"$_tmp_home/twice.err.filtered"
      if grep -q 'twice=done' "$_tmp_home/twice.out" && [ ! -s "$_tmp_home/twice.err.filtered" ]; then
        pass "$_lane/$_shell_name: sourcing the block repeatedly in one interactive shell is silent"
      else
        fail "$_lane/$_shell_name: repeated block sourcing produced diagnostics"
        cat "$_tmp_home/twice.out" "$_tmp_home/twice.err" >&2
      fi
      # The reload flag is an implementation detail. When the BLOCK reloads
      # (a second read of the same release), it must leave VALISE_RELOAD
      # exactly as it found it - unset, and never exported into the caller's
      # children - because the plan it sources reads a shell variable, not an
      # exported one. Setting it through a prefix assignment on `.` would test
      # dash/bash special-builtin semantics instead of the block.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c '. "'"$_stage2_file"'"; . "'"$_stage2_file"'"; if env | grep -q "^VALISE_RELOAD="; then printf "leaked\n"; else printf "sealed=%s\n" "${VALISE_RELOAD-unset}"; fi' \
        >"$_tmp_home/attr.out" 2>/dev/null
      if grep -Fx 'sealed=unset' "$_tmp_home/attr.out" >/dev/null; then
        pass "$_lane/$_shell_name: a block reload neither exports VALISE_RELOAD nor leaves it set"
      else
        fail "$_lane/$_shell_name: a block reload leaked or left VALISE_RELOAD set"
        cat "$_tmp_home/attr.out" >&2 2>/dev/null || :
      fi
      # The B5 case: a caller who set VALISE_RELOAD=1 (UNEXPORTED) to force a
      # reload must get exactly that back. The block force-reloads when it sees
      # VALISE_RELOAD=1, so this exercises the real reload path; assigning the
      # flag (never exporting it) is what keeps the caller's attribute, and an
      # assignment alone cannot REMOVE an attribute the block had added.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c 'VALISE_RELOAD=1; . "'"$_stage2_file"'"; if env | grep -q "^VALISE_RELOAD="; then printf "leaked-attr\n"; else printf "sealed=%s\n" "${VALISE_RELOAD-unset}"; fi' \
        >"$_tmp_home/attr3.out" 2>/dev/null
      if grep -Fx 'sealed=1' "$_tmp_home/attr3.out" >/dev/null; then
        pass "$_lane/$_shell_name: a forced reload restores a set-but-unexported VALISE_RELOAD"
      else
        fail "$_lane/$_shell_name: a forced reload left VALISE_RELOAD exported or changed"
        cat "$_tmp_home/attr3.out" >&2 2>/dev/null || :
      fi
      # A caller who set VALISE_RELOAD themselves keeps their value and their
      # export status: the block restores both.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c 'VALISE_RELOAD=9; export VALISE_RELOAD; . "'"$_stage2_file"'"; if env | grep -qx "VALISE_RELOAD=9"; then printf "preserved=%s\n" "$VALISE_RELOAD"; else printf "lost\n"; fi' \
        >"$_tmp_home/attr2.out" 2>/dev/null
      if grep -Fx 'preserved=9' "$_tmp_home/attr2.out" >/dev/null; then
        pass "$_lane/$_shell_name: a block reload restores a caller's exported VALISE_RELOAD"
      else
        fail "$_lane/$_shell_name: a block reload did not restore a caller's exported VALISE_RELOAD"
        cat "$_tmp_home/attr2.out" >&2 2>/dev/null || :
      fi
      # A release switch inside a live shell re-sources the plan over the
      # previous load. That must not report the plan's own earlier exports as
      # a foreign conflict.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c "_valise_profile_loaded=stale-release-id; . '$_double_snippet'; printf 'switch=done\n'" \
        >"$_tmp_home/switch.out" 2>"$_tmp_home/switch.err"
      if grep -q 'switch=done' "$_tmp_home/switch.out" && [ ! -s "$_tmp_home/switch.err" ]; then
        pass "$_lane/$_shell_name: reloading after a release switch is silent"
      else
        fail "$_lane/$_shell_name: reloading after a release switch produced diagnostics"
        cat "$_tmp_home/switch.out" "$_tmp_home/switch.err" >&2
      fi
      # sh/ksh: an interactive subshell reads $ENV (exported by the .profile
      # block), so 'sh -i' with ENV set must load both plans; a
      # non-interactive child reads no ENV and loads nothing extra.
      case $_class in
        sh|ksh)
          _shim="$_tmp_home/.config/valise/env.sh"
          env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin "ENV=$_shim" \
            "$_shell_path" -i -c 'if command -v e2e_env_ready >/dev/null; then printf "subenv=yes"; else printf "subenv=no"; fi; if command -v e2e_ksh_loaded >/dev/null 2>&1 || command -v e2e_show_aliases >/dev/null 2>&1; then printf " subint=yes"; fi; printf "\n"' \
            >"$_tmp_home/sub.out" 2>/dev/null </dev/null
          if grep -q 'subenv=yes' "$_tmp_home/sub.out" && grep -q 'subint=yes' "$_tmp_home/sub.out"; then
            pass "$_lane/$_shell_name: interactive subshell via the \$ENV shim loads both plans"
          else
            fail "$_lane/$_shell_name: interactive subshell via the \$ENV shim did not load valise"
            cat "$_tmp_home/sub.out" >&2
          fi
          env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin "ENV=$_shim" \
            "$_shell_path" -c 'if command -v e2e_env_ready >/dev/null; then printf "cenv=yes"; else printf "cenv=no"; fi; printf "\n"' \
            >"$_tmp_home/child.out" 2>"$_tmp_home/child.err"
          if grep -q 'cenv=no' "$_tmp_home/child.out"; then
            pass "$_lane/$_shell_name: non-interactive child reads no \$ENV"
          else
            fail "$_lane/$_shell_name: non-interactive child unexpectedly read \$ENV"
            cat "$_tmp_home/child.out" "$_tmp_home/child.err" >&2
          fi
          ;;
      esac
      # Same shell, second read: the env plan must not re-run (guard holds
      # the release id), proven by a load-counting probe through VALISE_RELOAD.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c ". '$_snippet'; _g1=\${_valise_profile_loaded:-}; . '$_snippet'; [ -n \"\$_g1\" ] && [ \"\$_g1\" = \"\${_valise_profile_loaded:-}\" ] && printf 'guard=yes\n'" \
        >"$_tmp_home/guard.out" 2>"$_tmp_home/guard.err"
      if grep -q 'guard=yes' "$_tmp_home/guard.out"; then
        pass "$_lane/$_shell_name: same-shell re-read keeps the release-id guard"
      else
        fail "$_lane/$_shell_name: same-shell re-read lost the release-id guard"
        cat "$_tmp_home/guard.out" "$_tmp_home/guard.err" >&2
      fi
      # Nested fresh shell with a reordered PATH: the env plan re-runs and
      # restores the compiled PATH front (convergent projection). The e2e
      # bundle's env phase prepends nothing by itself, so assert convergence:
      # after the nested shell re-runs the env plan, sourcing the plan again
      # changes nothing (fixed point) and the reordered helper stays behind
      # the entries the plan asserts.
      _nested_snippet=$_ni_snippet
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
        "$_shell_path" -c ". '$_nested_snippet'; PATH=\"/usr/bin:/bin:/reordered/helper:\$PATH\"; export PATH; env -i HOME=\"\$HOME\" XDG_CONFIG_HOME=\"\$XDG_CONFIG_HOME\" PATH=\"\$PATH\" '$_shell_path' -c '. \"\$HOME/'"$(basename "$_nested_snippet")"'\"; p1=\$PATH; VALISE_RELOAD=1 . \"\$HOME/'"$(basename "$_nested_snippet")"'\"; p2=\$PATH; [ \"\$p1\" = \"\$p2\" ] && printf \"fixed=yes path=%s\n\" \"\$p2\" || printf \"fixed=no p1=%s p2=%s\n\" \"\$p1\" \"\$p2\"'" \
        >"$_tmp_home/nested.out" 2>"$_tmp_home/nested.err"
      if grep -q 'fixed=yes' "$_tmp_home/nested.out"; then
        pass "$_lane/$_shell_name: nested shell re-runs the env plan to a fixed point"
      else
        fail "$_lane/$_shell_name: nested shell did not reach the env fixed point"
        cat "$_tmp_home/nested.out" "$_tmp_home/nested.err" >&2
      fi
      # The compiled PATH entry must be front-most after a LOGIN shell. On
      # macOS zsh runs /etc/zprofile's path_helper AFTER ~/.zshenv, which
      # reorders PATH; the block's one-shot repair pass at the next startup
      # file (~/.zprofile) is what puts the compiled entry back in front.
      # Without it the entry ends up LAST - the defect this assertion locks.
      env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin TERM=dumb \
        "$_shell_path" -l -c 'case $PATH in "$HOME/e2e-bin:"*) printf "front=yes\n" ;; *) printf "front=no path=%s\n" "$PATH" ;; esac' \
        >"$_tmp_home/login.out" 2>"$_tmp_home/login.err" </dev/null
      if grep -q 'front=yes' "$_tmp_home/login.out"; then
        pass "$_lane/$_shell_name: a login shell keeps the env plan's PATH entry front-most"
      else
        fail "$_lane/$_shell_name: a login shell lost the env plan's PATH ordering"
        cat "$_tmp_home/login.out" "$_tmp_home/login.err" >&2
      fi
    fi
  fi

  _cleanup_home "$_tmp_home"
}

run_host_lane() {
  _shell_name=$1
  _shell_path=$(command -v "$_shell_name" 2>/dev/null || echo "")
  if [ -z "$_shell_path" ]; then
    if tooling_required; then
      fail "host/$_shell_name: required shell is not available"
    else
      skip "host/$_shell_name: shell not available"
    fi
    return 0
  fi
  run_lane "host" "$_shell_name" "$_shell_path"
}

# --- Lima lanes ---
# The release is built on the host (the BSD guest mounts the repository
# read-only); each guest installs it into its own quarantined home and
# starts the shell through the startup file valise wrote.
run_lima_lane() {
  _instance=$1
  _shell_name=$2
  _shell_path=$3

  if ! command -v limactl >/dev/null 2>&1; then
    skip "lima/$_instance/$_shell_name: limactl not available"
    return 0
  fi

  _status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$_instance" '$1 == n { print $2 }')
  if [ -z "$_status" ]; then
    skip "lima/$_instance/$_shell_name: instance not found"
    return 0
  fi
  if [ "$_status" = "Stopped" ]; then
    printf '  Starting Lima instance %s (timeout 120s)...\n' "$_instance" >&2
    # Run limactl directly so $! is its PID: killing it on timeout must not
    # leave a reparented child holding the VM lock.
    limactl start "$_instance" >/dev/null 2>&1 &
    _limactl_pid=$!
    _waited=0
    while kill -0 "$_limactl_pid" 2>/dev/null && [ "$_waited" -lt 120 ]; do
      sleep 2
      _waited=$((_waited + 2))
    done
    if kill -0 "$_limactl_pid" 2>/dev/null; then
      kill "$_limactl_pid" 2>/dev/null || :
      wait "$_limactl_pid" 2>/dev/null || true
      skip "lima/$_instance/$_shell_name: start timed out"
      return 0
    fi
    wait "$_limactl_pid" 2>/dev/null || true
    _status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$_instance" '$1 == n { print $2 }')
  fi
  if [ "$_status" != "Running" ]; then
    skip "lima/$_instance/$_shell_name: instance is $_status"
    return 0
  fi

  if ! limactl shell "$_instance" command -v "$_shell_name" >/dev/null 2>&1; then
    skip "lima/$_instance/$_shell_name: shell not available inside"
    return 0
  fi

  _lima_os=$(limactl shell "$_instance" uname -s 2>/dev/null) || _lima_os=unknown
  _lima_run="$_shell_path"
  [ "$_shell_name" = busybox ] && _lima_run="$_shell_path sh"
  _lima_snippet=$(startup_file_for "$_shell_name")
  if [ "$_shell_name" = fish ]; then
    _lima_class=fish
  else
    # The probe travels on stdin: limactl shell re-splits its arguments
    # through ssh, which would break the quoting of a -c script. A guest
    # login may print a banner first, so the class is the last line.
    _lima_class_q=$(printf '%s' "$_class_probe" | sed "s/'/'\\\\''/g")
    _lima_class=$(printf '%s\n' "$_lima_run -c '$_lima_class_q'" | limactl shell "$_instance" /bin/sh -s 2>/dev/null | tail -n 1) || _lima_class=sh
  fi
  _expected=$(expected_exports_for "$_lima_class" "$_lima_os" 0)
  _expect_line=$(printf '%s\n' "$_expected" | sed -n 1p)
  _absent_line=$(printf '%s\n' "$_expected" | sed -n 2p)
  _lima_names="${_expect_line#expect } ${_absent_line#absent }"
  if [ "$_lima_class" = fish ]; then
    _lima_probe=$_fish_probe
  else
    _lima_probe=$_posix_probe
  fi
  _lima_probe_q=$(printf '%s' "$_lima_probe" | sed "s/'/'\\\\''/g")

  _lima_out=$(limactl shell "$_instance" /bin/sh -s <<LIMA_EOF
set -u
_tmp_home=\$(mktemp -d /tmp/valise-e2e.XXXXXX) || exit 2
_valise="$REPO_ROOT/bin/valise"
_e2e="$E2E_RELEASE"
_snippet_path="\$_tmp_home/$_lima_snippet"
_henv() {
  env HOME="\$_tmp_home" XDG_DATA_HOME="\$_tmp_home/.local/share" XDG_CONFIG_HOME="\$_tmp_home/.config" \
    XDG_STATE_HOME="\$_tmp_home/.local/state" TERM="$(_probe_term)" PATH="$REPO_ROOT/bin:/usr/local/bin:/usr/bin:/bin" "\$@"
}
if (cd "\$_e2e" && _henv SHELL="$_shell_path" "\$_valise" install) >"\$_tmp_home/install1.out" 2>&1 &&
  grep -q 'installing release' "\$_tmp_home/install1.out"; then
  printf 'INSTALL_OK\n'
else
  printf 'INSTALL_FAIL\n'
  cat "\$_tmp_home/install1.out"
fi
if _henv "\$_valise" release verify >/dev/null 2>&1; then printf 'VERIFY_OK\n'; else printf 'VERIFY_FAIL\n'; fi
if [ -f "\$_snippet_path" ]; then printf 'SNIPPET_OK\n'; else printf 'SNIPPET_FAIL\n'; fi
if [ "$_lima_class" = fish ]; then
  _henv $_lima_run -c '$_lima_probe_q' $_lima_names >"\$_tmp_home/load.out" 2>"\$_tmp_home/load.err"
else
  env -i HOME="\$_tmp_home" XDG_CONFIG_HOME="\$_tmp_home/.config" PATH=/usr/bin:/bin \
    $_lima_run -c '$_lima_probe_q' probe "\$_snippet_path" $_lima_names >"\$_tmp_home/load.out" 2>"\$_tmp_home/load.err"
fi
sed 's/^/LOAD /' "\$_tmp_home/load.out"
sed 's/^/LOADERR /' "\$_tmp_home/load.err"
(cd "\$_e2e" && _henv SHELL="$_shell_path" "\$_valise" install) >"\$_tmp_home/install2.out" 2>&1 || true
if grep -q 'already installed' "\$_tmp_home/install2.out"; then printf 'IDEMPOTENT_OK\n'; else printf 'IDEMPOTENT_FAIL\n'; fi
chmod -R u+w "\$_tmp_home" 2>/dev/null
rm -rf "\$_tmp_home"
LIMA_EOF
  ) || _lima_out="LIMA_INVOKE_FAIL"

  _label="lima/$_instance/$_shell_name"
  case "$_lima_out" in *INSTALL_OK*) pass "$_label: valise install succeeds" ;;
    *) fail "$_label: valise install failed"; printf '%s\n' "$_lima_out" >&2 ;; esac
  case "$_lima_out" in *VERIFY_OK*) pass "$_label: valise release verify passes" ;;
    *) fail "$_label: valise release verify failed" ;; esac
  case "$_lima_out" in *SNIPPET_OK*) pass "$_label: shell integration written to $_lima_snippet" ;;
    *) fail "$_label: shell integration missing: $_lima_snippet" ;; esac
  _lima_tmp=$(mktemp -d "$_e2e_tmpdir/valise-e2e-lima.XXXXXX") || _lima_tmp=
  if [ -n "$_lima_tmp" ]; then
    printf '%s\n' "$_lima_out" | sed -n 's/^LOAD //p' >"$_lima_tmp/load.out"
    printf '%s\n' "$_lima_out" | sed -n 's/^LOADERR //p' >"$_lima_tmp/load.err"
    check_load "$_label" "$_lima_tmp/load.out" "$_expect_line" "$_absent_line" "$_lima_tmp/load.err"
    rm -rf "$_lima_tmp"
  else
    fail "$_label: cannot create a temp directory for load results"
  fi
  case "$_lima_out" in *IDEMPOTENT_OK*) pass "$_label: second install is idempotent" ;;
    *) fail "$_label: second install was not idempotent" ;; esac
}

# --- Composition lane (host only) ---
# A consuming project composes a provider by vendoring its tree as
# layers/<provider>. Stage a copy of examples/e2e, vendor examples/shared as
# layers/shared, and add the provider's modules to the POSIX roots. The
# probe module's optional dependency on contrib_shared_paths must resolve
# across the project/layer boundary, the layer modules must ship under
# layers/shared/ in the release, and each shell must load them.
run_composition_lane() {
  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e-compose.XXXXXX") || {
    skip "compose: cannot create temp home"
    return 0
  }
  _stage="$_tmp_home/project"
  mkdir -p "$_stage/layers/shared"
  for _part in valise.conf variants.tsv module.d modules; do
    cp -R "$E2E_ROOT/$_part" "$_stage/"
  done
  cp -R "$REPO_ROOT/examples/shared/module.d" "$REPO_ROOT/examples/shared/modules" "$_stage/layers/shared/"
  awk -F '\t' 'BEGIN { OFS = "\t" } NR > 1 && $2 != "fish" { $3 = $3 " contrib_shared_umask" } { print }' \
    "$E2E_ROOT/bundles.tsv" >"$_stage/bundles.tsv"

  if (cd "$_stage" && _home_env "$_tmp_home" "$VALISE" build) >"$_tmp_home/compose-build.out" 2>&1; then
    pass "compose: the project with a vendored layer builds"
  else
    fail "compose: the project with a vendored layer did not build"
    cat "$_tmp_home/compose-build.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi
  if [ -f "$_stage/build/release/layers/shared/module.d/contrib_shared_paths.meta" ] &&
    [ -f "$_stage/build/release/layers/shared/modules/shared/contrib_shared_umask.sh" ]; then
    pass "compose: the release ships the layer modules under layers/shared"
  else
    fail "compose: the release lacks the layer modules"
    (cd "$_stage/build/release" && find . -type f | sort) >&2
  fi

  if (cd "$_stage/build/release" && _home_env "$_tmp_home" SHELL=/bin/sh "$VALISE" install) >"$_tmp_home/compose-install.out" 2>&1 &&
    _home_env "$_tmp_home" "$VALISE" release verify >"$_tmp_home/compose-verify.out" 2>&1; then
    pass "compose: the composed release installs and verifies"
  else
    fail "compose: the composed release did not install and verify"
    cat "$_tmp_home/compose-install.out" "$_tmp_home/compose-verify.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi

  for _sh in sh bash zsh ksh; do
    _shell_path=$(command -v "$_sh" 2>/dev/null || echo "")
    if [ -z "$_shell_path" ]; then
      skip "compose/$_sh: shell not available"
      continue
    fi
    env -i HOME="$_tmp_home" XDG_CONFIG_HOME="$_tmp_home/.config" PATH=/usr/bin:/bin \
      "$_shell_path" -c '. "$HOME/.profile" || exit 99; e2e_layer_probe_ok; contrib_shared_paths_setup; printf "composed-paths=%s\n" "$PATH"; contrib_shared_umask_secure; printf "composed-umask="; umask' \
      >"$_tmp_home/compose-$_sh.out" 2>"$_tmp_home/compose-$_sh.err"
    if [ $? -ne 0 ]; then
      fail "compose/$_sh: composed load failed"
      cat "$_tmp_home/compose-$_sh.out" "$_tmp_home/compose-$_sh.err" >&2
      continue
    fi
    if grep -q 'layer probe: shared layer resolved' "$_tmp_home/compose-$_sh.out"; then
      pass "compose/$_sh: optional dependency on the layer resolved"
    else
      fail "compose/$_sh: the shared layer did not resolve"
    fi
    if grep -q '\.local/bin' "$_tmp_home/compose-$_sh.out"; then
      pass "compose/$_sh: layer module augments PATH"
    else
      fail "compose/$_sh: layer module PATH augmentation missing"
    fi
    if grep -q 'composed-umask=.*077' "$_tmp_home/compose-$_sh.out" && [ ! -s "$_tmp_home/compose-$_sh.err" ]; then
      pass "compose/$_sh: work-only module applies quietly"
    else
      fail "compose/$_sh: work-only module behaved unexpectedly"
      cat "$_tmp_home/compose-$_sh.err" >&2
    fi
  done

  # Fish leg: the composed release must verify from inside Fish and its
  # Fish module must load through the deployed hook. The layer's modules are
  # POSIX-only, so the Fish closure is unchanged by the composition.
  _compose_fish=$(command -v fish 2>/dev/null || echo "")
  if [ -z "$_compose_fish" ]; then
    skip "compose/fish: fish not available"
  elif _home_env "$_tmp_home" _COMPOSE_VALISE="$VALISE" "$_compose_fish" \
    -c 'builtin functions -q e2e_fish_loaded; or exit 1; builtin test "$VALISE_FISH_READY" = 1; or exit 1; "$_COMPOSE_VALISE" release verify >/dev/null 2>&1; or exit 1; exit 0' \
    >"$_tmp_home/compose-fish.out" 2>&1; then
    pass "compose/fish: composed release verifies and loads through Fish"
  else
    fail "compose/fish: composed release failed to verify or load through Fish"
    cat "$_tmp_home/compose-fish.out" >&2
  fi

  _cleanup_home "$_tmp_home"
}

# --- Tamper lane (host only) ---
# The seal must fail closed inside the end-to-end suite, not only in the
# CLI unit tests: after a real install, changing one byte of a sealed plan
# must make release verify fail, and restoring the exact bytes must make it
# pass again.
run_tamper_lane() {
  _tmp_home=$(mktemp -d "$_e2e_tmpdir/valise-e2e-tamper.XXXXXX") || {
    skip "tamper: cannot create temp home"
    return 0
  }

  if ! (cd "$E2E_RELEASE" && _home_env "$_tmp_home" SHELL=/bin/sh "$VALISE" install) >"$_tmp_home/tamper-install.out" 2>&1; then
    fail "tamper: valise install failed"
    cat "$_tmp_home/tamper-install.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi
  pass "tamper: release installed"

  if _home_env "$_tmp_home" "$VALISE" release verify >"$_tmp_home/tamper-verify1.out" 2>&1; then
    pass "tamper: release verify passes on the untampered release"
  else
    fail "tamper: release verify failed before tampering"
    cat "$_tmp_home/tamper-verify1.out" >&2
    _cleanup_home "$_tmp_home"
    return 0
  fi

  _tamper_active=$(cd "$_tmp_home/.config/valise/active" 2>/dev/null && pwd -P)
  _tamper_file="$_tamper_active/plans/sh.sh"
  if [ -z "$_tamper_active" ] || [ ! -f "$_tamper_file" ]; then
    fail "tamper: cannot resolve a release file to tamper with"
    _cleanup_home "$_tmp_home"
    return 0
  fi
  _tamper_save="$_tmp_home/sh.sh.orig"
  cp -p "$_tamper_file" "$_tamper_save"
  chmod u+w "$_tamper_file"
  printf '%s\n' tampered >>"$_tamper_file"
  chmod u-w "$_tamper_file"
  if _home_env "$_tmp_home" "$VALISE" release verify >"$_tmp_home/tamper-verify2.out" 2>&1; then
    fail "tamper: release verify accepted a tampered release"
    cat "$_tmp_home/tamper-verify2.out" >&2
  else
    pass "tamper: release verify rejects the tampered release"
  fi

  # Restore the exact sealed bytes and prove the release verifies again,
  # so the lane leaves no poisoned state behind it.
  chmod u+w "$_tamper_file"
  cat "$_tamper_save" >"$_tamper_file"
  chmod 0444 "$_tamper_file"
  if _home_env "$_tmp_home" "$VALISE" release verify >"$_tmp_home/tamper-verify3.out" 2>&1; then
    pass "tamper: release verify passes after byte restoration"
  else
    fail "tamper: release verify failed after restoring the sealed bytes"
    cat "$_tmp_home/tamper-verify3.out" >&2
  fi

  _cleanup_home "$_tmp_home"
}

# --- Main ---
printf '=== valise end-to-end test ===\n'
printf '  repo: %s\n' "$REPO_ROOT"
printf '  e2e:  %s\n\n' "$E2E_ROOT"

# Always rebuild so the release reflects the current engine.
printf '%s\n' '  Building the e2e project...'
if ! "$VALISE" -C "$E2E_ROOT" build >"$_e2e_tmpdir/valise-e2e-build.$$" 2>&1; then
  cat "$_e2e_tmpdir/valise-e2e-build.$$" >&2
  rm -f "$_e2e_tmpdir/valise-e2e-build.$$"
  printf '%s\n' 'FAIL: valise build of examples/e2e failed' >&2
  exit 1
fi
rm -f "$_e2e_tmpdir/valise-e2e-build.$$"

printf '%s\n' '--- Host lanes ---'
for _sh in sh bash zsh ksh dash fish; do
  run_host_lane "$_sh"
done

printf '\n%s\n' '--- Tamper lane ---'
run_tamper_lane

printf '\n%s\n' '--- Composition lane ---'
run_composition_lane

printf '\n%s\n' '--- Lima valise-linux-full lanes ---'
for _sh in sh bash zsh ksh dash fish; do
  case "$_sh" in
    sh)   _p=/bin/sh ;;
    bash) _p=/bin/bash ;;
    zsh)  _p=/usr/bin/zsh ;;
    ksh)  _p=/bin/ksh ;;
    dash) _p=/bin/dash ;;
    fish) _p=/usr/bin/fish ;;
  esac
  run_lima_lane "valise-linux-full" "$_sh" "$_p"
done

printf '\n%s\n' '--- Lima valise-busybox lanes ---'
run_lima_lane "valise-busybox" "busybox" "/bin/busybox"

printf '\n%s\n' '--- Lima valise-bsd-test lanes ---'
for _sh in sh bash ksh; do
  case "$_sh" in
    sh)   _p=/bin/sh ;;
    bash) _p=/usr/local/bin/bash ;;
    ksh)  _p=/bin/ksh ;;
  esac
  run_lima_lane "valise-bsd-test" "$_sh" "$_p"
done

printf '\n=== valise end-to-end summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"

[ "$_fail" -eq 0 ]
