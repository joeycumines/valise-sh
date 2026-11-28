# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: developer commands: env, lint, test, and run. test and run load
# modules from a throwaway release built beside the project, so they exercise
# the same plans an installed profile uses.
# Sourced by bin/valise; not executable on its own.

_dev_tmp=""

# devtool_interpreter <class>
# Print the interpreter for a shell class, or fail. The sh class is dash, or
# an sh that is not bash, zsh, or ksh in disguise.
devtool_interpreter() {
  case "$1" in
  sh)
    _di_path=$(command -v dash 2>/dev/null || :)
    if [ -z "$_di_path" ]; then
      _di_path=$(command -v sh 2>/dev/null || :)
      [ -n "$_di_path" ] || return 1
      # shellcheck disable=SC2016
      "$_di_path" -c '[ -z "${BASH_VERSION-}${ZSH_VERSION-}${KSH_VERSION-}" ]' 2>/dev/null || return 1
    fi
    ;;
  bash | zsh | ksh | fish) _di_path=$(command -v "$1" 2>/dev/null || :) ;;
  *) return 1 ;;
  esac
  case "$_di_path" in
  /*) printf '%s\n' "$_di_path" ;;
  *) return 1 ;;
  esac
}

# capture_interpreter <class>: the interpreter the env capture runs a plan with.
# This is production policy, not the test matrix's: the sh class is the absolute
# trusted /bin/sh, because the bridge must describe what a /bin/sh login loads;
# bash, zsh, and ksh are the PATH binaries their shells would run. The test
# matrix's devtool_interpreter (which prefers dash) is not used here.
capture_interpreter() {
  case "$1" in
  sh) _ci_path=$(trusted_utility_path sh 2>/dev/null || :) ;;
  bash | zsh | ksh) _ci_path=$(command -v "$1" 2>/dev/null || :) ;;
  *) return 1 ;;
  esac
  case "$_ci_path" in
  /*) printf '%s\n' "$_ci_path"; unset _ci_path ;;
  *) unset _ci_path; return 1 ;;
  esac
}

# devtool_classes <shells-field>: the shell classes a module declares.
devtool_classes() {
  _dc_out=
  for _dc_word in $1; do
    case "$_dc_word" in
    posix) _dc_add='sh bash zsh ksh' ;;
    *) _dc_add=$_dc_word ;;
    esac
    for _dc_class in $_dc_add; do
      case " $_dc_out " in *" $_dc_class "*) ;; *) _dc_out="${_dc_out:+$_dc_out }$_dc_class" ;; esac
    done
  done
  printf '%s\n' "$_dc_out"
  unset _dc_out _dc_word _dc_add _dc_class
}

# devtool_scratch: create the scratch directory for one command.
devtool_scratch() {
  trusted_mktemp_assign _dev_tmp dir "${TMPDIR:-/tmp}/valise-dev.XXXXXX" || die "cannot create scratch directory"
  # Keep the allocated name registered until physical lookup succeeds: a
  # failed or interrupted lookup must not erase the cleanup owner's pathname.
  _dev_resolved=$(CDPATH= cd -P "$_dev_tmp" && pwd -P && printf x) || die "cannot resolve scratch directory"
  _dev_resolved=${_dev_resolved%x}
  _dev_tmp=${_dev_resolved%?}
  unset _dev_resolved
}

devtool_cleanup() {
  if [ -n "$_dev_tmp" ]; then
    remove_tree "$_dev_tmp" || info "warning: cannot remove scratch directory: $_dev_tmp"
    _dev_tmp=""
  fi
}

# devtool_build <out> <log> <sh-roots> <bash-roots> <zsh-roots> <ksh-roots> <fish-roots>
# Build a release whose roots are given per shell, ignoring bundles and
# variants. Output goes to the log; fails when the build fails.
devtool_build() {
  (
    _pb_override=1
    _pbo_sh=$3 _pbo_bash=$4 _pbo_zsh=$5 _pbo_ksh=$6 _pbo_fish=$7
    project_build dev dev "$1" 0
  ) >"$2" 2>&1
}

# devtool_runner <class> <release> <file> <body-file>
# Write a script that loads the release for one shell class in strict mode,
# defines valise_test_reload, then runs the body. VALISE_TEST_RELEASE and
# VALISE_TEST_PLAN are exported so the body can load the same modules in a
# child shell.
#
# Both phase plans are sourced. A module under test may be phase=interactive,
# and the plans themselves carry no $- gate (the managed block does), so a
# test harness - which is never an interactive login - still loads the module
# it is testing. Sourcing only the env plan left `valise test` and
# `valise run --module=<interactive>` running against a shell where the module
# under test had never been defined.
devtool_runner() {
  _dr_release=$(shell_quote "$2") || return 1
  _dr_cat=$(trusted_utility_path cat) || return 1
  if [ "$1" = fish ]; then
    _dr_release=$(fish_quote "$2") || return 1
    {
      printf '%s\n' \
        "set -gx SHELL_PROJECT_ROOT $_dr_release" \
        "set -gx VALISE_TEST_RELEASE $_dr_release" \
        'set -gx VALISE_TEST_PLAN "$VALISE_TEST_RELEASE/runtime/fish/profile.fish"' \
        'source "$SHELL_PROJECT_ROOT/runtime/fish/profile.fish"' \
        'or begin' \
        "  printf '%s\\n' 'valise: the modules failed to load' >&2" \
        '  exit 97' \
        'end' \
        'function valise_test_reload' \
        '  source "$SHELL_PROJECT_ROOT/runtime/fish/profile.fish"' \
        'end'
      "$_dr_cat" "$4"
    } >"$3"
  else
    {
      printf '%s\n' \
        "_valise_dev_release=$_dr_release" \
        'VALISE_TEST_RELEASE=$_valise_dev_release' \
        "VALISE_TEST_PLAN=\$_valise_dev_release/plans/$1.sh" \
        'export VALISE_TEST_RELEASE VALISE_TEST_PLAN' \
        '_valise_dev_plans="$_valise_dev_release/plans/'"$1"'.sh"' \
        '_valise_dev_int="$_valise_dev_release/plans/'"$1"'-interactive.sh"' \
        'valise_test_reload() {' \
        '  _valise_plan_carried=' \
        '  VALISE_MODULE_ROOT=$_valise_dev_release' \
        '  VALISE_MODE=strict' \
        '  VALISE_RELOAD=1' \
        '  _valise_dev_status=0' \
        '  . "$_valise_dev_plans" || _valise_dev_status=$?' \
        '  if [ "$_valise_dev_status" -eq 0 ] && [ -f "$_valise_dev_int" ]; then' \
        '    . "$_valise_dev_int" || _valise_dev_status=$?' \
        '  fi' \
        '  unset VALISE_RELOAD VALISE_MODULE_ROOT _valise_plan_carried' \
        '  return "$_valise_dev_status"' \
        '}' \
        'VALISE_MODULE_ROOT=$_valise_dev_release' \
        'VALISE_MODE=strict' \
        '_valise_plan_carried=' \
        '. "$_valise_dev_plans" || {' \
        "  printf '%s\\n' 'valise: the modules failed to load' >&2" \
        '  exit 97' \
        '}' \
        'if [ -f "$_valise_dev_int" ]; then' \
        '  VALISE_MODULE_ROOT=$_valise_dev_release' \
        '  . "$_valise_dev_int" || {' \
        "    printf '%s\\n' 'valise: the interactive modules failed to load' >&2" \
        '    exit 97' \
        '  }' \
        'fi' \
        'unset VALISE_MODULE_ROOT _valise_plan_carried'
      # The body goes LAST: it calls valise_test_reload, which needs the plan
      # paths, so they must survive until it runs.
      "$_dr_cat" "$4"
    } >"$3"
  fi
  _dr_status=$?
  unset _dr_release _dr_cat
  return "$_dr_status"
}

# devtool_quarantine <scratch> <interpreter>
# Create the test home and XDG tree; set _dev_path to the test PATH.
devtool_quarantine() {
  _dq_scratch=$1
  _dq_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_dq_mkdir" -p "$_dq_scratch/home" "$_dq_scratch/tmp" "$_dq_scratch/xdg/config" \
    "$_dq_scratch/xdg/data" "$_dq_scratch/xdg/state" "$_dq_scratch/xdg/cache" ||
    die "cannot create the test home"
  _dev_path="${VALISE_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:${2%/*}"
  unset _dq_scratch _dq_mkdir
}

# devtool_exec <scratch> <interpreter> <runner> [args...]
# Run a runner script in a quarantined environment.
devtool_exec() {
  _de_scratch=$1
  _de_interp=$2
  _de_runner=$3
  shift 3
  devtool_quarantine "$_de_scratch" "$_de_interp"
  env -i HOME="$_de_scratch/home" TMPDIR="$_de_scratch/tmp" PATH="$_dev_path" TERM=dumb \
    LANG="${LANG:-C}" USER="${USER:-valise}" LOGNAME="${LOGNAME:-${USER:-valise}}" \
    XDG_CONFIG_HOME="$_de_scratch/xdg/config" XDG_DATA_HOME="$_de_scratch/xdg/data" \
    XDG_STATE_HOME="$_de_scratch/xdg/state" XDG_CACHE_HOME="$_de_scratch/xdg/cache" \
    VALISE_TEST_ROOT="$_de_scratch" VALISE_PROJECT_ROOT="$_project_root" \
    VALISE_TEST_MODULE="${_dev_module:-}" VALISE_TEST_MODULE_DIR="${_dev_module_dir:-}" \
    VALISE_TEST_SHELL="${_dev_class:-}" \
    "$_de_interp" "$_de_runner" "$@"
}

# --- env ---

# _eec_byte_count <tr> <wc> <scratch-dir> <input-file> <tr-args...>
# Print the byte count of tr's output, or fail when tr itself fails.
#
# A pipeline cannot be used: `tr ... | wc -c` reports wc's status, so a tr that
# cannot read its input leaves wc counting zero bytes and exiting 0 - a clean
# "no offending bytes" result from a scan that never ran. tr writes a scratch
# file whose status is checked first, and wc counts that file.
_eec_byte_count() {
  _ebc_tr=$1
  _ebc_wc=$2
  _ebc_scratch=$3
  _ebc_input=$4
  shift 4
  _ebc_rc=1
  if [ -n "$_ebc_tr" ] && [ -n "$_ebc_wc" ] &&
    LC_ALL=C "$_ebc_tr" "$@" <"$_ebc_input" >"$_ebc_scratch/count.out" 2>/dev/null; then
    _ebc_rc=0
    # wc -c pads with leading spaces on BSD; the caller strips whitespace
    # before its digit check, so the raw output is passed through.
    "$_ebc_wc" -c <"$_ebc_scratch/count.out" || _ebc_rc=1
  fi
  _ebc_status=$_ebc_rc
  unset _ebc_tr _ebc_wc _ebc_scratch _ebc_input _ebc_rc
  # Return a literal, not "$_ebc_status": the caller's cleanup contract is that
  # no private variable survives the call, and a value can only be returned from
  # a variable that still exists.
  if [ "$_ebc_status" -eq 0 ]; then
    unset _ebc_status
    return 0
  fi
  unset _ebc_status
  return 1
}

# _eec_encode_dump <od> <awk> <dump> <byte-file>: encode a NUL-delimited
# environment as NAME=<three decimal digits per value byte>. POSIX od owns
# the binary framing; awk sees only ASCII numbers, never embedded NULs. In
# particular this does not depend on nonportable awk RS="\0" behavior.
_eec_encode_dump() (
  LC_ALL=C "$1" -A n -t u1 -v <"$3" >"$4" || exit 1
  LC_ALL=C "$2" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^[0-9]+$/ || $i + 0 > 255) { bad = 1; exit 1 }
        byte = $i + 0
        if (byte == 0) {
          if (has_equals && name ~ /^[A-Za-z_][A-Za-z0-9_]*$/)
            print name "=" value
          name = value = ""
          has_equals = pending = 0
        } else {
          pending = 1
          if (has_equals) value = value sprintf("%03d", byte)
          else if (byte == 61) has_equals = 1
          else name = name sprintf("%c", byte)
        }
      }
    }
    END { if (bad || pending) exit 1 }
  ' "$4"
)

# env_export_capture <shell> [release-dir]: run a release's env plan and print
# changed exported scalars as KEY=VALUE lines. The optional release is used by
# install before it becomes active. All private state and scratch cleanup live
# in a subshell, including when a caller runs this inside a store transaction.
#
# Both runs see the same caller HOME, PATH, TMPDIR and XDG roots. Only the shell
# startup-file surface is isolated (ENV/BASH_ENV and ZDOTDIR): derived values
# must describe the real session, not a throwaway HOME. Consequently dry-run
# must not call this function. The interpreter and dump utility are resolved
# before either run, and module stdout cannot inject records into env -0.
#
# Keep NUL boundaries through the comparison and name filter. An excluded PATH
# or shell bookkeeping value may contain bytes no bridge can represent; that
# must not reject an otherwise valid export. Only selected records are decoded
# and validated. A newline resembling another assignment remains part of its
# original value and is diagnosed by its actual variable name.
env_export_capture() (
  _eec_scratch=
  _eec_signal=
  # Recording a signal before checking it closes the allocation/assignment
  # window: mktemp may already have created a directory whose name has not
  # reached this shell yet. The same handlers protect cleanup from a second
  # signal. Checkpoints stop normal work once an operation has recorded its
  # result and cleanup can identify every owned scratch path.
  trap '_eec_signal=130' INT
  trap '_eec_signal=143' TERM
  _eec_checkpoint() { [ -z "$_eec_signal" ] || exit "$_eec_signal"; }
  trap '_eec_exit=$?; trap - EXIT
    if [ -n "$_eec_scratch" ]; then
      run_ignoring_int_term remove_tree "$_eec_scratch" || {
        printf "valise: error: cannot remove env capture scratch directory: %s\n" "$_eec_scratch" >&2
        [ "$_eec_exit" -ne 0 ] || _eec_exit=1
      }
    fi
    exit "${_eec_signal:-$_eec_exit}"' EXIT
  _eec_shell=$1
  if [ -n "${2:-}" ]; then
    _eec_active=$2
  else
    _eec_active=$(active_release_dir) || exit 1
  fi
  _eec_plan="$_eec_active/plans/$_eec_shell.sh"
  [ -f "$_eec_plan" ] || _eec_plan="$_eec_active/plans/sh.sh"
  [ -f "$_eec_plan" ] || exit 1
  _eec_interp=$(capture_interpreter "$_eec_shell") || {
    printf 'valise: error: no %s interpreter is available for the env capture\n' "$_eec_shell" >&2
    exit 1
  }
  _eec_env=$(trusted_utility_path env) || {
    printf 'valise: error: no trusted env utility is available for the env capture\n' >&2
    exit 1
  }
  _eec_sh=/bin/sh
  [ -x "$_eec_sh" ] || _eec_sh=$(trusted_utility_path sh 2>/dev/null || :)
  [ -n "$_eec_sh" ] || {
    printf 'valise: error: no absolute sh is available for the env capture\n' >&2
    exit 1
  }
  _eec_awk=$(trusted_utility_path awk) || exit 1
  _eec_od=$(trusted_utility_path od) || {
    printf 'valise: error: no trusted od utility is available for the env capture\n' >&2
    exit 1
  }
  _eec_cat=$(trusted_utility_path cat) || exit 1
  _eec_mkdir=$(trusted_utility_path mkdir) || exit 1
  # Protect the entire capture, not only mktemp: a process-group signal must
  # not kill an intermediate substitution after allocation but before its name
  # reaches this worker. This worker records the signal and cleans at the next
  # checkpoint; only the short allocation subprocess ignores it.
  _eec_scratch=$(trap '' INT TERM; trusted_mktemp dir "${TMPDIR:-/tmp}/valise-env-export.XXXXXX") || exit 1
  _eec_checkpoint
  "$_eec_mkdir" -p "$_eec_scratch/zdot" || exit 1
  _eec_probe="$_eec_scratch/probe.sh"
  # A probe FILE and ordinary arguments avoid another layer of shell quoting.
  # VALISE_MODULE_ROOT is set at the source site, just as in managed startup.
  # PATH is already supplied by the outer env; do not replace an empty value.
  printf '%s\n' \
    '_mode=$1 _out=$2 _plan=$3 _interp=$4 _env=$5 _root=$6' \
    '_fixture() {' \
    '  "$_env" HOME="$EEC_HOME" ZDOTDIR="$EEC_ZDOT" BASH_ENV=/dev/null ENV=/dev/null "$@"' \
    '}' \
    'if [ "$_mode" = plan ]; then' \
    '  _fixture "$_interp" -c '\''VALISE_MODULE_ROOT=$4; . "$1" >/dev/null 2>>"$3" || exit 96; exec "$2" -0'\'' valise-probe "$_plan" "$_env" "$EEC_PLAN_ERR" "$_root" >"$_out" 2>/dev/null' \
    '  exit $?' \
    'fi' \
    '_fixture "$_interp" -c '\''exec "$1" -0'\'' valise-probe "$_env" >"$_out" 2>/dev/null' \
    >"$_eec_probe" || exit 1
  _eec_plan_err="$_eec_scratch/plan.err"
  : >"$_eec_plan_err" || exit 1
  # Unset PATH gets a useful default; explicitly empty PATH stays empty. TMPDIR
  # and each XDG root retain both their bytes and set/unset distinction.
  set -- PATH="${PATH-/usr/bin:/bin}" HOME="${HOME-/}" \
    EEC_HOME="${HOME-/}" EEC_ZDOT="$_eec_scratch/zdot" EEC_PLAN_ERR="$_eec_plan_err"
  if [ "${TMPDIR+x}" = x ]; then set -- "$@" TMPDIR="$TMPDIR"; fi
  if [ "${XDG_CONFIG_HOME+x}" = x ]; then set -- "$@" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"; fi
  if [ "${XDG_DATA_HOME+x}" = x ]; then set -- "$@" XDG_DATA_HOME="$XDG_DATA_HOME"; fi
  if [ "${XDG_STATE_HOME+x}" = x ]; then set -- "$@" XDG_STATE_HOME="$XDG_STATE_HOME"; fi
  if [ "${XDG_CACHE_HOME+x}" = x ]; then set -- "$@" XDG_CACHE_HOME="$XDG_CACHE_HOME"; fi
  _eec_checkpoint
  _eec_status=0
  "$_eec_env" -i "$@" \
    "$_eec_sh" "$_eec_probe" base "$_eec_scratch/base" "$_eec_plan" "$_eec_interp" "$_eec_env" "$_eec_active" ||
    _eec_status=$?
  _eec_checkpoint
  if [ "$_eec_status" -eq 0 ]; then
    "$_eec_env" -i "$@" \
      "$_eec_sh" "$_eec_probe" plan "$_eec_scratch/target" "$_eec_plan" "$_eec_interp" "$_eec_env" "$_eec_active" ||
      _eec_status=$?
  fi
  _eec_checkpoint
  if [ "$_eec_status" -ne 0 ]; then
    case "$_eec_status" in
    96)
      printf 'valise: error: the env plan for shell %s failed to load\n' "$_eec_shell" >&2
      if [ -s "$_eec_plan_err" ]; then
        printf 'valise: the plan reported:\n' >&2
        while IFS= read -r _eec_line || [ -n "$_eec_line" ]; do printf '  %s\n' "$_eec_line" >&2; done <"$_eec_plan_err"
      fi
      ;;
    *) printf 'valise: error: the env capture for shell %s failed (status %s)\n' "$_eec_shell" "$_eec_status" >&2 ;;
    esac
    exit 1
  fi
  for _eec_dump in base target; do
    if ! _eec_encode_dump "$_eec_od" "$_eec_awk" "$_eec_scratch/$_eec_dump" "$_eec_scratch/bytes" \
      >"$_eec_scratch/$_eec_dump.encoded"; then
      printf 'valise: error: the env capture for shell %s could not be read as NUL-delimited records\n' "$_eec_shell" >&2
      exit 1
    fi
    _eec_checkpoint
  done
  : >"$_eec_scratch/diagnostic" || exit 1
  : >"$_eec_scratch/notes" || exit 1
  # The baseline and target use the same interpreter, so incidental variables
  # cancel. Match by FILENAME, not record number (the baseline may be empty).
  # Compare encoded records before decoding: no newline or control byte can
  # become a fabricated variable, even in an excluded value.
  if ! LC_ALL=C EEC_BASE="$_eec_scratch/base.encoded" \
    EEC_DIAGNOSTIC="$_eec_scratch/diagnostic" EEC_NOTES="$_eec_scratch/notes" "$_eec_awk" '
    function key_of(rec,   at) { at = index(rec, "="); return substr(rec, 1, at - 1) }
    # RFC 3629 permits only Unicode scalar values. Some iconv implementations
    # accept obsolete five/six-byte sequences and values above U+10FFFF, so
    # iconv success alone is insufficient. Track exact continuation bounds,
    # rejecting overlong encodings and surrogate code points as well.
    function utf8_byte(b) {
      if (utf8_left) {
        if (b < utf8_min || b > utf8_max) return 0
        utf8_left--
        utf8_min = 128; utf8_max = 191
        return 1
      }
      if (b < 128) return 1
      utf8_min = 128; utf8_max = 191
      if (b >= 194 && b <= 223) utf8_left = 1
      else if (b >= 224 && b <= 239) {
        utf8_left = 2
        if (b == 224) utf8_min = 160
        if (b == 237) utf8_max = 159
      } else if (b >= 240 && b <= 244) {
        utf8_left = 3
        if (b == 240) utf8_min = 144
        if (b == 244) utf8_max = 143
      } else return 0
      return 1
    }
    FILENAME == ENVIRON["EEC_BASE"] { base[key_of($0)] = $0; next }
    {
      name = key_of($0)
      if (name in base && base[name] == $0) next
      if (name == "_" || name == "HOME" || name == "PWD" || name == "SHLVL" ||
          name == "OLDPWD" || name == "VALISE_MODULE_ROOT" || name == "ZDOTDIR" ||
          name == "BASH_ENV" || name == "ENV" || name == "EEC_HOME" ||
          name == "EEC_ZDOT" || name == "EEC_PLAN_ERR" ||
          name == "VALISE_CALLER_PATH" || name == "VALISE_CALLER_CWD") next
      if (name == "PATH" || name == "XDG_CONFIG_HOME" || name == "XDG_DATA_HOME" ||
          name == "XDG_STATE_HOME" || name == "XDG_CACHE_HOME" || name == "TMPDIR") {
        excluded++
        excluded_names = excluded_names (excluded_names == "" ? "" : " ") name
        next
      }
      encoded = substr($0, index($0, "=") + 1)
      value = ""
      forbidden = ""
      utf8_left = utf8_bad = 0
      for (i = 1; i <= length(encoded); i += 3) {
        byte = substr(encoded, i, 3) + 0
        if (!utf8_byte(byte)) utf8_bad = 1
        if (byte == 10) forbidden = "newline"
        else if (byte < 32 && byte != 9 && forbidden == "") forbidden = "control character"
        value = value sprintf("%c", byte)
      }
      if (forbidden != "") {
        printf "valise: error: the env plan sets %s to a value containing a %s; GUI env formats cannot represent it\n", name, forbidden > ENVIRON["EEC_DIAGNOSTIC"]
        bad = 1
        next
      }
      if (utf8_bad || utf8_left) {
        printf "valise: error: %s is set to a value that is not valid UTF-8; GUI env formats cannot represent it\n", name > ENVIRON["EEC_DIAGNOSTIC"]
        bad = 1
        next
      }
      # XML 1.0 excludes these two valid UTF-8 sequences. Check only selected
      # values; a noncharacter in PATH or another excluded value is irrelevant.
      if (index(value, sprintf("%c%c%c", 239, 191, 190)) ||
          index(value, sprintf("%c%c%c", 239, 191, 191))) {
        printf "valise: error: %s is set to a value containing U+FFFE or U+FFFF, which XML 1.0 forbids; GUI env formats cannot represent it\n", name > ENVIRON["EEC_DIAGNOSTIC"]
        bad = 1
        next
      }
      out = out name "=" value "\n"
    }
    END {
      if (bad) exit 1
      printf "%s", out
      if (excluded)
        printf "valise: note: %d exported variable(s) are not bridged (a GUI session sets its own): %s\n", excluded, excluded_names > ENVIRON["EEC_NOTES"]
    }
  ' "$_eec_scratch/base.encoded" "$_eec_scratch/target.encoded" >"$_eec_scratch/selected"; then
    if [ -s "$_eec_scratch/diagnostic" ]; then
      "$_eec_cat" "$_eec_scratch/diagnostic" >&2
    else
      printf 'valise: error: the env capture for shell %s could not be inspected\n' "$_eec_shell" >&2
    fi
    exit 1
  fi
  _eec_checkpoint
  # The selected stream now has unambiguous LF-delimited records. Validate it
  # with the platform UTF-8 implementation; excluded input is never passed to
  # iconv. Without trusted iconv, fail closed on non-ASCII selected values.
  _eec_iconv=$(trusted_utility_path iconv 2>/dev/null || :)
  if [ -n "$_eec_iconv" ]; then
    if ! LC_ALL=C "$_eec_iconv" -f UTF-8 -t UTF-8 <"$_eec_scratch/selected" >/dev/null 2>"$_eec_scratch/iconv.err"; then
      printf 'valise: error: the env plan produced a value that is not valid UTF-8; GUI env formats cannot represent it\n' >&2
      exit 1
    fi
  else
    _eec_tr=$(trusted_utility_path tr) || exit 1
    _eec_wc=$(trusted_utility_path wc) || exit 1
    _eec_high=$(_eec_byte_count "$_eec_tr" "$_eec_wc" "$_eec_scratch" \
      "$_eec_scratch/selected" -d '\000-\177') || {
      printf 'valise: error: the env capture for shell %s could not count its bytes\n' "$_eec_shell" >&2
      exit 1
    }
    _eec_high=${_eec_high#"${_eec_high%%[![:space:]]*}"}
    _eec_high=${_eec_high%"${_eec_high##*[![:space:]]}"}
    case "$_eec_high" in
    0) ;;
    '' | *[!0-9]*)
      printf 'valise: error: the env capture for shell %s could not count its bytes\n' "$_eec_shell" >&2
      exit 1 ;;
    *)
      printf 'valise: error: the env plan produced a non-ASCII value, and no trusted iconv is available to check it as UTF-8\n' >&2
      exit 1 ;;
    esac
  fi
  _eec_checkpoint
  "$_eec_cat" "$_eec_scratch/notes" >&2 || exit 1
  "$_eec_cat" "$_eec_scratch/selected"
)

# env_export_emit <format> <capture-lines>: render captured KEY=VALUE pairs in
# the requested GUI-bridge format. Unknown formats fail without leaking the
# private state used here.
env_export_emit() {
  _eee_format=$1
  _eee_capture=$2
  _eee_awk=$(trusted_utility_path awk) || {
    unset _eee_format _eee_capture
    return 1
  }
  _eee_rc=0
  case "$_eee_format" in
  environment.d)
    # environment.d(5) is read by systemd's environment generator, which
    # performs $VAR/${VAR} expansion EVEN INSIDE double quotes. A literal `$`
    # must therefore be written `$$`, or a value like `$HOME/bin` silently
    # becomes the GUI session's home directory. Values are double-quoted when
    # they contain whitespace or a metacharacter, with backslash and double
    # quote escaped; plain values stay bare.
    #
    # The metacharacters are tested with an index() loop over a literal
    # string: inside a POSIX bracket expression `\]` is backslash followed by a
    # literal `]` that CLOSES the class, so a class spelled that way has
    # implementation-defined meaning (BWK, gawk and BusyBox happen to agree;
    # that is luck, not portability).
    printf '%s\n' "$_eee_capture" | LC_ALL=C "$_eee_awk" -F= '
      function needs_quoting(val,   i, c, metas) {
        metas = " \t\n\"'"'"'\\$`!*?[]{}()<>|;&"
        for (i = 1; i <= length(val); i++) {
          c = substr(val, i, 1)
          if (index(metas, c) > 0) return 1
        }
        return 0
      }
      # Escaping is a character scan, not gsub. A gsub replacement string has
      # its own backslash rules: "\\\\" (two backslashes) yields TWO on BWK,
      # gawk, gawk --traditional and mawk, but ONE on BusyBox awk and
      # `gawk --posix` - measured - which writes a\\b as "a\b" (systemd reads
      # it as ab) and lets a trailing backslash escape the closing quote. A
      # substr loop produces the same bytes on all six.
      function dq_escape(val,   i, c, out) {
        out = ""
        for (i = 1; i <= length(val); i++) {
          c = substr(val, i, 1)
          if (c == "\\") out = out "\\\\"
          else if (c == "\"") out = out "\\\""
          else out = out c
        }
        return out
      }
      BEGIN {
        out = ""; bad = 0
        tab_ch = sprintf("%c", 9)
        del_ch = sprintf("%c", 127)
        n_nc = 0
        for (b = 144; b <= 175; b++) nc[++n_nc] = sprintf("%c%c%c", 239, 183, b)
        nc[++n_nc] = sprintf("%c%c%c", 239, 191, 190)
        nc[++n_nc] = sprintf("%c%c%c", 239, 191, 191)
        for (p = 1; p <= 16; p++) {
          b0 = 240 + int(p / 4)
          b1 = 143 + (p % 4) * 16
          nc[++n_nc] = sprintf("%c%c%c%c", b0, b1, 191, 190)
          nc[++n_nc] = sprintf("%c%c%c%c", b0, b1, 191, 191)
        }
      }
      function has_nonchar(val,   i) {
        for (i = 1; i <= n_nc; i++) {
          if (index(val, nc[i]) > 0) return 1
        }
        return 0
      }
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        key = $1
        sub(/^[^=]*=/, "")
        val = $0
        if (val == "") {
          printf "valise: error: %s is exported empty; environment.d cannot represent an empty value, so unset it instead\n", key > "/dev/stderr"
          bad = 1
          next
        }
        if (index(val, tab_ch) > 0 || index(val, del_ch) > 0) {
          printf "valise: error: %s contains TAB or DEL, which systemd environment.d alters during parsing; omit or normalize it\n", key > "/dev/stderr"
          bad = 1
          next
        }
        if (has_nonchar(val)) {
          printf "valise: error: %s contains a Unicode noncharacter, which systemd environment.d rejects\n", key > "/dev/stderr"
          bad = 1
          next
        }
        gsub(/\$/, "$$", val)
        if (needs_quoting(val)) {
          out = out sprintf("%s=\"%s\"\n", key, dq_escape(val))
        } else {
          out = out sprintf("%s=%s\n", key, val)
        }
      }
      END {
        # Nothing is printed when any value is refused: a partial file would look
        # like a complete bridge to whoever copied it.
        if (bad) exit 1
        printf "# written by valise (gui_env=systemd); do not edit\n%s", out
      }
    ' || _eee_rc=1
    ;;
  launchd)
    # A LaunchAgent whose program runs one launchctl setenv per variable. The
    # command string is executed by /bin/sh, so every key and value is
    # SINGLE-QUOTED for the shell FIRST and XML-escaped exactly once after.
    # Without the shell quoting, a value containing a space split into extra
    # argv words, and `;`, `$`, a backtick or a quote injected shell syntax -
    # `plutil -lint` cannot see any of that, because the plist is well formed.
    #
    # The comment line is the ownership marker: uninstall removes the plist
    # only when this exact line is present, so a foreign LaunchAgent that
    # happens to use the same Label is never deleted.
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!-- written by valise (gui_env=launchd); do not edit -->' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict>' \
      '  <key>Label</key><string>sh.valise.env</string>' \
      '  <key>ProgramArguments</key><array>' \
      '    <string>/bin/sh</string><string>-c</string>'
    printf '%s\n' "$_eee_capture" | LC_ALL=C "$_eee_awk" -F= '
      function shq(s) { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return "'"'"'" s "'"'"'" }
      BEGIN { cmd = "" }
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        key = $1; sub(/^[^=]*=/, ""); val = $0
        pair = "launchctl setenv " shq(key) " " shq(val)
        if (cmd == "") cmd = pair
        else cmd = cmd "; " pair
      }
      END {
        # An empty capture must still produce a command /bin/sh can run: a
        # bare `sh -c` with no command string exits 2 on every login.
        if (cmd == "") cmd = ":"
        gsub(/&/, "\\&amp;", cmd); gsub(/</, "\\&lt;", cmd); gsub(/>/, "\\&gt;", cmd)
        gsub(/"/, "\\&quot;", cmd)
        printf "    <string>%s</string>\n", cmd
      }
    ' || _eee_rc=1
    printf '%s\n' '  </array>' \
      '  <key>RunAtLoad</key><true/>' \
      '</dict></plist>'
    ;;
  wsl)
    # WSLENV carries NAMES with flags, not values, as one colon-joined string.
    # Per Microsoft: /p translates a path between WSL and Win32, /l marks a
    # colon-delimited path LIST, /u is Win32->WSL only, /w is WSL->Win32 only.
    # A bare name is passed through untranslated. Deriving the flag from a
    # substring of the key (`key ~ /PATH/`) is wrong twice over: it mislabels
    # CLASSPATH/MANPATH as single paths, and it invents a rule the format does
    # not have.
    printf '%s\n' "$_eee_capture" | LC_ALL=C "$_eee_awk" -F= '
      function is_path_list(val,   n, i, parts) {
        if (index(val, ":") == 0) return 0
        n = split(val, parts, ":")
        for (i = 1; i <= n; i++) {
          if (parts[i] == "" || substr(parts[i], 1, 1) != "/") return 0
        }
        return 1
      }
      function is_path(val) { return val != "" && substr(val, 1, 1) == "/" }
      BEGIN { out = "" }
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        key = $1; sub(/^[^=]*=/, ""); val = $0
        if (is_path_list(val)) entry = key "/l"
        else if (is_path(val)) entry = key "/p"
        else entry = key
        out = out (out == "" ? "" : ":") entry
      }
      END { if (out != "") printf "WSLENV=%s\n", out }
    ' || _eee_rc=1
    ;;
  *) _eee_rc=1 ;;
  esac
  _eee_status=$_eee_rc
  unset _eee_format _eee_capture _eee_awk _eee_rc
  # Return a literal, not "$_eee_status": no private variable may outlive the
  # call, and a value can only be returned from a variable that still exists.
  if [ "$_eee_status" -eq 0 ]; then
    unset _eee_status
    return 0
  fi
  unset _eee_status
  return 1
}

cmd_env() {
  case "${1:-}" in
  --help | -h) usage_env; return 0 ;;
  export)
    shift
    case "${1:-}" in
    --help | -h) usage_env; return 0 ;;
    esac
    _ee_format=${1:-}
    case "$_ee_format" in
    environment.d|launchd|wsl) ;;
    *) die "usage: valise env export <environment.d|launchd|wsl>" ;;
    esac
    [ $# -eq 1 ] || die "usage: valise env export <environment.d|launchd|wsl>"
    # One shell-selection rule for every caller (this command, the automatic
    # bridge, and doctor's dry run): a second copy drifted, letting `apply
    # --dry-run` promise bytes install would never write.
    _ee_shell=$(gui_env_bridge_shell)
    _ee_capture=$(env_export_capture "$_ee_shell") || die "cannot capture the env plan for shell $_ee_shell"
    env_export_emit "$_ee_format" "$_ee_capture" || die "cannot render the $_ee_format format"
    unset _ee_format _ee_shell _ee_capture
    return 0
    ;;
  '') ;;
  *) die "unknown env option: $1" ;;
  esac
  _env_engine=$(engine_root) || die "cannot locate the valise engine"
  if _env_project=$(project_find_root); then :; else
    [ "$?" -eq 1 ] || exit 1
  fi
  _env_bin=$(commands_bin_dir 2>/dev/null || :)
  for _env_pair in \
    "VALISE_VERSION=$VALISE_VERSION" \
    "VALISE_ENGINE_ROOT=$_env_engine" \
    "VALISE_PROJECT_ROOT=$_env_project" \
    "VALISE_DATA_DIR=$VALISE_XDG_DATA" \
    "VALISE_CONFIG_DIR=$VALISE_XDG_CONFIG" \
    "VALISE_STATE_DIR=$VALISE_XDG_STATE" \
    "VALISE_RELEASES_DIR=$VALISE_RELEASES_DIR" \
    "VALISE_ACTIVE_LINK=$VALISE_ACTIVE_LINK" \
    "VALISE_BIN_DIR=$_env_bin"; do
    printf '%s=%s\n' "${_env_pair%%=*}" "$(shell_quote "${_env_pair#*=}")"
  done
  unset _env_engine _env_project _env_bin _env_pair
}

# --- lint ---

# lint_report <ok|FAIL|skip> <message>
lint_report() {
  printf '%s: %s\n' "$1" "$2"
  [ "$1" != FAIL ] || _lint_problems=$((_lint_problems + 1))
}

# _lint_path_scan <file> <module> [phase]: reject raw PATH assignments in a
# module body. The env plan is re-sourced at every startup entry point and the
# interactive plan is re-sourced on a release switch (and on `source ~/.bashrc`
# in a live shell), so a raw 'PATH=...:$PATH' duplicates entries in EVERY
# phase. PATH changes go through valise_path_prepend/valise_path_append. The
# phase is named in the diagnostic because the reason differs: both plans are
# re-sourced, but only the env plan runs at every entry point.
#
# The scan is a regex on source lines, so it is an authoring-time ADVISORY
# guard, not a security boundary: releases are sealed by the manifest, and
# indirect writes (PATH+=, eval, ${PATH:=...}) are not textually detectable.
# Comment lines are skipped, and so are *.fish bodies: Fish mutates PATH with
# `set -x PATH`, which this POSIX rule says nothing about.
_lint_path_scan() {
  _lps_file=$1
  _lps_mod=$2
  [ -f "$_lps_file" ] || return 0
  case "$_lps_file" in
  *.fish) unset _lps_file _lps_mod; return 0 ;;
  esac
  _lps_grep=$(trusted_utility_path grep) || die "no trusted grep utility available"
  # A separator or a command keyword before the assignment catches
  # 'true; PATH=...', 'x && PATH=...', and 'export A=1 PATH=...' as well as the
  # simple leading form. '#' comment lines are excluded by the same pattern.
  _lps_hits=$("$_lps_grep" -nE \
    '(^|[;&|]|[[:space:]])(export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)?PATH=' \
    "$_lps_file" 2>/dev/null || :)
  _lps_hits=$(printf '%s\n' "$_lps_hits" |
    "$_lps_grep" -vE '^[0-9]+:[[:space:]]*#' 2>/dev/null || :)
  # Every surviving record is `N:source line` (grep -n always prefixes the line
  # number), so a non-empty result is a hit and no whitespace expansion is
  # needed. `${var//pat/}` is bash/ksh-only: it aborts dash at EXPANSION time
  # even when the value is empty, which broke `valise lint` on every Linux host
  # whose /bin/sh is dash while `sh -n` and the macOS bash lane stayed green.
  if [ -n "$_lps_hits" ]; then
    _lps_head=$(trusted_utility_path head) || die "no trusted head utility available"
    _lps_line=$(printf '%s\n' "$_lps_hits" | "$_lps_head" -n 1)
    _lps_lineno=${_lps_line%%:*}
    _lps_phase=${3:-env}
    lint_report FAIL "$_lps_mod: $_lps_phase-phase body assigns PATH directly (line $_lps_lineno); use valise_path_prepend/valise_path_append (requires=valise_path) so re-evaluation stays idempotent"
  fi
  unset _lps_file _lps_mod _lps_grep _lps_hits _lps_head _lps_line _lps_lineno _lps_phase
}

# lint_parse <class> <file> <label>
lint_parse() {
  if ! _lp_interp=$(devtool_interpreter "$1"); then
    if [ "$_lint_require" -eq 1 ]; then
      lint_report FAIL "$3: no $1 parser available"
    else
      case " $_lint_missing " in
      *" $1 "*) ;;
      *) lint_report skip "no $1 parser available; $1 syntax is not checked"; _lint_missing="$_lint_missing $1" ;;
      esac
    fi
    return 0
  fi
  if [ "$1" = fish ]; then
    _lp_out=$("$_lp_interp" --no-execute "$2" 2>&1) && _lp_rc=0 || _lp_rc=$?
  else
    _lp_out=$("$_lp_interp" -n "$2" 2>&1) && _lp_rc=0 || _lp_rc=$?
  fi
  if [ "$_lp_rc" -eq 0 ]; then
    _lint_parsed=$((_lint_parsed + 1))
  else
    lint_report FAIL "$3: $1 syntax error: $(printf '%s' "$_lp_out" | head -n 3 | tr '\n' ' ')"
  fi
  unset _lp_interp _lp_out _lp_rc
}

cmd_lint() {
  _lint_require=0
  _lint_select=
  for _lint_arg do
    case "$_lint_arg" in
    --require-parsers) _lint_require=1 ;;
    --help | -h) usage_lint; return 0 ;;
    -*) die "unknown lint option: $_lint_arg" ;;
    *) _lint_select="$_lint_select $_lint_arg" ;;
    esac
  done
  project_config_load
  devtool_scratch
  _lint_problems=0
  _lint_parsed=0
  _lint_missing=
  _lint_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"

  # Metadata: registry generation validates every record, names, prefixes,
  # and the files each module names.
  _lint_registry="$_dev_tmp/registry"
  if _lint_out=$( (registry_generate "$_project_root" "$_lint_registry") 2>&1); then
    lint_report ok "metadata of $(($("$_lint_awk" 'END { print NR }' "$_lint_registry") - 1)) module(s)"
  else
    lint_report FAIL "$(printf '%s' "$_lint_out" | sed -n 's/^valise: error: //p' | head -n 1)"
    printf 'valise lint: %d problem(s)\n' "$_lint_problems"
    devtool_cleanup
    exit 1
  fi

  # Layers: contrib_ names, versions, safe modes, and dependencies that stay
  # inside the layer or the engine.
  for _lint_layer in "$_project_root"/layers/*/; do
    [ -d "$_lint_layer" ] || continue
    _lint_layer=${_lint_layer%/}
    _lint_name=${_lint_layer##*/}
    if _lint_out=$(layer_lint_dir "$_lint_layer" "$_lint_name" 2>&1); then
      lint_report ok "layer $_lint_name"
    else
      printf '%s\n' "$_lint_out" | sed -n 's/^  FAIL: //p' | while IFS= read -r _lint_line; do
        printf 'FAIL: layers/%s: %s\n' "$_lint_name" "$_lint_line"
      done
      _lint_problems=$((_lint_problems + $(printf '%s\n' "$_lint_out" | grep -c '^  FAIL: ')))
    fi
  done
  if [ -n "$_project_lint_forbid" ] && [ -d "$_project_root/layers" ]; then
    if _lint_out=$(grep -rniE -- "$_project_lint_forbid" "$_project_root/layers" 2>/dev/null); then
      printf '%s\n' "$_lint_out" | head -n 20 | while IFS= read -r _lint_line; do
        printf 'FAIL: forbidden in layers (lint_layer_forbid): %s\n' "${_lint_line#"$_project_root"/}"
      done
      _lint_problems=$((_lint_problems + 1))
    else
      lint_report ok "layers contain nothing matching lint_layer_forbid"
    fi
  fi

  # Every bundle compiles for every variant and shell: unknown roots and
  # exclusions, missing dependencies, and exclusions that break a remaining
  # module all fail here.
  _lint_bundles=$(project_bundle_names "$_project_root") || die "cannot read bundles.tsv"
  _lint_variants=$(project_variant_names "$_project_root") || die "cannot read variants.tsv"
  for _lint_bundle in $_lint_bundles; do
    for _lint_variant in $_lint_variants; do
      _lint_excl=$(project_variant_field "$_project_root" "$_lint_variant" excluded 2>/dev/null) || {
        lint_report FAIL "variant $_lint_variant cannot be read"
        continue
      }
      _lint_combo_ok=1
      for _lint_shell in $VALISE_PROJECT_SHELLS fish; do
        _lint_roots=$(project_bundle_roots "$_project_root" "$_lint_shell" "$_lint_bundle" 2>&1) || {
          lint_report FAIL "bundle $_lint_bundle: $_lint_roots"
          _lint_combo_ok=0
          continue
        }
        [ -n "$_lint_roots" ] || continue
        if ! _lint_out=$( (project_compile "$_lint_registry" "$_lint_shell" "$_lint_roots" "$_lint_excl" \
          "$_dev_tmp/plan.$_lint_shell" closure) 2>&1); then
          # The compiler's own reason comes first; the wrapper's message last.
          lint_report FAIL "bundle $_lint_bundle variant $_lint_variant ($_lint_shell): $(printf '%s\n' "$_lint_out" |
            sed -n 's/^valise: error: //p; s/^ERROR: //p' | head -n 1)"
          _lint_combo_ok=0
        fi
      done
      [ "$_lint_combo_ok" -eq 0 ] || lint_report ok "bundle $_lint_bundle variant $_lint_variant compiles"
    done
  done

  # Syntax of every body and test with each parser its shells name.
  # Tab is IFS whitespace, so read would merge empty columns; awk emits a
  # separator that no validated name or path contains.
  "$_lint_awk" -F '\t' 'NR > 1 && $14 != "valise" { print $1 "|" $7 "|" $10 "|" $13 "|" $14 "|" $4 }' \
    "$_lint_registry" >"$_dev_tmp/lint-rows" || die "cannot read the registry"
  while IFS='|' read -r _lint_mname _lint_shells _lint_load _lint_tests _lint_src _lint_phase; do
    if [ -n "$_lint_select" ]; then
      case " $_lint_select " in
      *" $_lint_mname "* | *" $_lint_mname@$_lint_src "*) ;;
      *) continue ;;
      esac
    fi
    _lint_dir=$(project_source_dir "$_project_root" "$_lint_src") || continue
    _lint_rel=${_lint_dir#"$_project_root"}
    _lint_rel=${_lint_rel#/}
    for _lint_file in $_lint_load $_lint_tests; do
      for _lint_class in $(devtool_classes "$_lint_shells"); do
        case "$_lint_class:$_lint_file" in
        fish:*.fish | sh:* | bash:* | zsh:* | ksh:*) ;;
        *) continue ;;
        esac
        case "$_lint_class:$_lint_file" in
        fish:*) ;;
        *:*.fish) continue ;;
        esac
        lint_parse "$_lint_class" "$_lint_dir/$_lint_file" "${_lint_rel:+$_lint_rel/}$_lint_file"
      done
    done
    # Raw PATH assignment is rejected in every phase: the env plan re-runs at
    # every startup entry point and the interactive plan re-runs on a release
    # switch, so either phase duplicates entries. PATH changes go through
    # valise_path_prepend/valise_path_append (requires=valise_path).
    if [ -n "$_lint_load" ]; then
      _lint_path_scan "$_lint_dir/$_lint_load" "$_lint_mname" "${_lint_phase:-env}"
    fi
  done <"$_dev_tmp/lint-rows"
  lint_report ok "$_lint_parsed syntax check(s)"
  if [ -n "$_lint_select" ]; then
    for _lint_want in $_lint_select; do
      "$_lint_awk" -F '\t' -v w="$_lint_want" 'NR > 1 && $14 != "valise" && ($1 == w || $1 "@" $14 == w) { f = 1 } END { exit !f }' \
        "$_lint_registry" || lint_report FAIL "unknown module: $_lint_want"
    done
  fi

  devtool_cleanup
  if [ "$_lint_problems" -ne 0 ]; then
    printf 'valise lint: %d problem(s)\n' "$_lint_problems"
    exit 1
  fi
  printf 'valise lint: no problems\n'
  unset _lint_require _lint_select _lint_arg _lint_problems _lint_parsed _lint_missing _lint_awk _lint_registry \
    _lint_out _lint_layer _lint_name _lint_line _lint_bundles _lint_variants _lint_bundle _lint_variant _lint_excl \
    _lint_combo_ok _lint_shell _lint_roots _lint_mname _lint_shells _lint_load _lint_tests _lint_src \
    _lint_dir _lint_rel _lint_file _lint_class _lint_want _lint_phase
}

# --- test ---

cmd_test() {
  _test_shells=
  _test_require=0
  _test_select=
  for _test_arg do
    case "$_test_arg" in
    --shell=*) _test_shells="$_test_shells $(printf '%s' "${_test_arg#--shell=}" | tr ',' ' ')" ;;
    --require-shells) _test_require=1 ;;
    --help | -h) usage_test; return 0 ;;
    -*) die "unknown test option: $_test_arg" ;;
    *) _test_select="$_test_select $_test_arg" ;;
    esac
  done
  for _test_class in $_test_shells; do
    case "$_test_class" in
    sh | bash | zsh | ksh | fish) ;;
    *) die "unknown shell class: $_test_class (use sh, bash, zsh, ksh, or fish)" ;;
    esac
  done
  project_config_load
  devtool_scratch
  _test_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  registry_generate "$_project_root" "$_dev_tmp/registry"
  for _test_want in $_test_select; do
    "$_test_awk" -F '\t' -v w="$_test_want" 'NR > 1 && $14 != "valise" && ($1 == w || $1 "@" $14 == w) { f = 1 } END { exit !f }' \
      "$_dev_tmp/registry" || die "unknown module: $_test_want"
  done
  _test_pass=0
  _test_fail=0
  _test_skip=0
  _test_n=0
  _test_any=0
  _test_rows="$_dev_tmp/rows"
  "$_test_awk" -F '\t' 'NR > 1 && $14 != "valise" && $13 != "" { print $1 "\t" $7 "\t" $13 "\t" $14 }' \
    "$_dev_tmp/registry" >"$_test_rows"
  while IFS="$(printf '\t')" read -r _dev_name _test_mshells _test_files _test_src; do
    if [ -n "$_test_select" ]; then
      case " $_test_select " in
      *" $_dev_name "* | *" $_dev_name@$_test_src "*) ;;
      *) continue ;;
      esac
    fi
    _test_any=1
    _dev_module=$_dev_name
    _dev_module_dir=$(project_source_dir "$_project_root" "$_test_src") || die "unsupported registry source: $_test_src"
    _test_id="$_dev_name@$_test_src"
    _test_classes=$(devtool_classes "$_test_mshells")
    _test_n=$((_test_n + 1))
    _test_rel="$_dev_tmp/release-$_test_n"
    # One release per module: the module is the only root for every shell it
    # supports, and no variant applies.
    _r_sh= _r_bash= _r_zsh= _r_ksh= _r_fish=
    for _dev_class in $_test_classes; do
      eval "_r_$_dev_class=\$_test_id"
    done
    if ! devtool_build "$_test_rel" "$_dev_tmp/build-$_test_n.log" "$_r_sh" "$_r_bash" "$_r_zsh" "$_r_ksh" "$_r_fish"; then
      printf 'FAIL %s: cannot build a release for it\n' "$_dev_name"
      sed 's/^/    /' "$_dev_tmp/build-$_test_n.log"
      _test_fail=$((_test_fail + 1))
      continue
    fi
    for _dev_class in $_test_classes; do
      if [ -n "$_test_shells" ]; then
        case " $_test_shells " in *" $_dev_class "*) ;; *) continue ;; esac
      fi
      if ! _test_interp=$(devtool_interpreter "$_dev_class"); then
        if [ "$_test_require" -eq 1 ]; then
          printf 'FAIL %s [%s]: no %s interpreter\n' "$_dev_name" "$_dev_class" "$_dev_class"
          _test_fail=$((_test_fail + 1))
        else
          printf 'skip %s [%s]: no %s interpreter\n' "$_dev_name" "$_dev_class" "$_dev_class"
          _test_skip=$((_test_skip + 1))
        fi
        continue
      fi
      for _test_file in $_test_files; do
        # Fish tests run only in Fish; every other test only in POSIX shells.
        case "$_dev_class:$_test_file" in
        fish:*.fish) ;;
        fish:* | *:*.fish) continue ;;
        esac
        _test_n=$((_test_n + 1))
        _test_scratch="$_dev_tmp/run-$_test_n"
        _test_runner="$_dev_tmp/runner-$_test_n"
        devtool_runner "$_dev_class" "$_test_rel" "$_test_runner" "$_dev_module_dir/$_test_file" ||
          die "cannot write the test runner"
        if _test_out=$(devtool_exec "$_test_scratch" "$_test_interp" "$_test_runner" 2>&1 </dev/null); then
          printf 'ok %s [%s] %s\n' "$_dev_name" "$_dev_class" "$_test_file"
          _test_pass=$((_test_pass + 1))
        else
          printf 'FAIL %s [%s] %s\n' "$_dev_name" "$_dev_class" "$_test_file"
          [ -z "$_test_out" ] || printf '%s\n' "$_test_out" | sed 's/^/    /'
          _test_fail=$((_test_fail + 1))
        fi
      done
    done
  done <"$_test_rows"
  devtool_cleanup
  if [ "$_test_any" -eq 0 ]; then
    printf 'valise test: no selected module declares tests=\n'
    [ -z "$_test_select" ] || exit 1
    return 0
  fi
  printf 'valise test: %d passed, %d failed, %d skipped\n' "$_test_pass" "$_test_fail" "$_test_skip"
  [ "$_test_fail" -eq 0 ] || exit 1
  unset _test_shells _test_require _test_select _test_arg _test_class _test_awk _test_want _test_pass _test_fail \
    _test_skip _test_n _test_any _test_rows _dev_name _test_mshells _test_files _test_src _dev_module \
    _dev_module_dir _test_id _test_classes _test_rel _r_sh _r_bash _r_zsh _r_ksh _r_fish _dev_class _test_interp \
    _test_file _test_scratch _test_runner _test_out
}

# --- run ---

cmd_run() {
  _run_class=
  _run_modules=
  _run_bundle=
  _run_variant=
  _run_keep=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --shell=*) _run_class=${1#--shell=} ;;
    --module=*) _run_modules="${_run_modules:+$_run_modules }${1#--module=}" ;;
    --bundle=*) _run_bundle=${1#--bundle=} ;;
    --variant=*) _run_variant=${1#--variant=} ;;
    --keep-env) _run_keep=1 ;;
    --help | -h) usage_run; return 0 ;;
    --) shift; break ;;
    *) die "unknown run option: $1 (the script follows --)" ;;
    esac
    shift
  done
  [ "$#" -ge 1 ] || die "usage: valise run [options] -- <script> [args...]"
  _run_script=$1
  shift
  if [ -z "$_run_class" ]; then
    case "${SHELL:-}" in
    */bash | bash) _run_class=bash ;;
    */zsh | zsh) _run_class=zsh ;;
    */ksh | ksh) _run_class=ksh ;;
    */fish | fish) _run_class=fish ;;
    *) _run_class=sh ;;
    esac
  fi
  case "$_run_class" in
  sh | bash | zsh | ksh | fish) ;;
  *) die "unknown shell class: $_run_class (use sh, bash, zsh, ksh, or fish)" ;;
  esac
  [ -z "$_run_modules" ] || [ -z "$_run_bundle$_run_variant" ] ||
    die "--module selects the roots itself; it cannot be combined with --bundle or --variant"
  _run_interp=$(devtool_interpreter "$_run_class") || die "no $_run_class interpreter found"
  project_config_load
  devtool_scratch
  _run_rel="$_dev_tmp/release"
  if [ -n "$_run_modules" ]; then
    _r_sh= _r_bash= _r_zsh= _r_ksh= _r_fish=
    eval "_r_$_run_class=\$_run_modules"
    devtool_build "$_run_rel" "$_dev_tmp/build.log" "$_r_sh" "$_r_bash" "$_r_zsh" "$_r_ksh" "$_r_fish" || {
      sed 's/^/  /' "$_dev_tmp/build.log" >&2
      die "cannot build the selected modules"
    }
  else
    if ! (project_build "${_run_variant:-$_project_variant}" "${_run_bundle:-$_project_bundle}" "$_run_rel" 0) \
      >"$_dev_tmp/build.log" 2>&1; then
      sed 's/^/  /' "$_dev_tmp/build.log" >&2
      die "cannot build the project"
    fi
    [ -f "$_run_rel/plans/$_run_class.sh" ] || [ "$_run_class" = fish ] ||
      die "the bundle has no roots for $_run_class"
    [ "$_run_class" != fish ] || [ -d "$_run_rel/runtime/fish" ] || die "the bundle has no roots for fish"
  fi
  printf '%s\n' "$_run_script" >"$_dev_tmp/script" || die "cannot write the script"
  devtool_runner "$_run_class" "$_run_rel" "$_dev_tmp/runner" "$_dev_tmp/script" || die "cannot write the runner"
  _run_rc=0
  if [ "$_run_keep" -eq 1 ]; then
    # Normalize TERM like the quarantine path below: a caller without TERM (CI
    # runners) makes fish's init run tput with no terminfo entry, printing
    # diagnostics to stderr that the caller never asked for. TERM=dumb is the
    # same inert terminal the quarantine path already uses.
    if [ -z "${TERM:-}" ]; then
      TERM=dumb "$_run_interp" "$_dev_tmp/runner" "$@" || _run_rc=$?
    else
      "$_run_interp" "$_dev_tmp/runner" "$@" || _run_rc=$?
    fi
  else
    devtool_exec "$_dev_tmp/home" "$_run_interp" "$_dev_tmp/runner" "$@" || _run_rc=$?
  fi
  devtool_cleanup
  unset _run_class _run_modules _run_bundle _run_variant _run_keep _run_script _run_interp _run_rel \
    _r_sh _r_bash _r_zsh _r_ksh _r_fish
  return "$_run_rc"
}
