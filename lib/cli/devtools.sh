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
  _dev_tmp=$(trusted_mktemp dir "${TMPDIR:-/tmp}/valise-dev.XXXXXX") || die "cannot create scratch directory"
  _dev_tmp=$(cd "$_dev_tmp" && pwd -P) || die "cannot resolve scratch directory"
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
        '  VALISE_MODULE_ROOT=$_valise_dev_release' \
        '  VALISE_MODE=strict' \
        '  VALISE_RELOAD=1' \
        '  _valise_dev_status=0' \
        '  . "$_valise_dev_plans" || _valise_dev_status=$?' \
        '  if [ "$_valise_dev_status" -eq 0 ] && [ -f "$_valise_dev_int" ]; then' \
        '    . "$_valise_dev_int" || _valise_dev_status=$?' \
        '  fi' \
        '  unset VALISE_RELOAD' \
        '  return "$_valise_dev_status"' \
        '}' \
        'VALISE_MODULE_ROOT=$_valise_dev_release' \
        'VALISE_MODE=strict' \
        '. "$_valise_dev_plans" || {' \
        "  printf '%s\\n' 'valise: the modules failed to load' >&2" \
        '  exit 97' \
        '}' \
        'if [ -f "$_valise_dev_int" ]; then' \
        '  . "$_valise_dev_int" || {' \
        "    printf '%s\\n' 'valise: the interactive modules failed to load' >&2" \
        '    exit 97' \
        '  }' \
        'fi'
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

# env_export_capture <shell> [release-dir]: run a release's env plan for
# <shell> in a quarantined environment and print the exported scalar
# KEY=VALUE pairs that differ from a baseline. The release defaults to the
# active one; install_preview passes the tree it is about to install, which is
# not active yet.
#
# Faithfulness rules, each of which a previous version broke:
#   * HOME stays the caller's real HOME. A throwaway HOME made every
#     HOME-derived scalar (GOPATH, CARGO_HOME, XDG_*) bake the probe
#     directory's path - which is deleted before the bridge is even read -
#     into the GUI session. Only the startup-file surface is isolated:
#     ZDOTDIR points at an empty directory, and BASH_ENV/ENV point at
#     /dev/null, so no user rc file runs.
#   * The baseline runs the SAME interpreter with the SAME fixture env as the
#     target, so shell-specific incidental variables (LOGNAME, SHLVL, ksh's
#     A__z) cancel instead of being captured as exports.
#   * The interpreter is resolved by devtool_interpreter BEFORE the sandbox
#     starts, so a Homebrew bash/zsh/ksh is found. The probe PATH is fixed and
#     calls its tools bare on purpose: it is a quarantined environment, not
#     the caller's PATH, so there is nothing there to forge.
#   * The dump is written through a dedicated fd with the plan's stdout
#     suppressed, so a module that prints KEY=VALUE cannot inject a variable
#     into the bridge.
#   * Every failure - no interpreter, a plan that fails to source, a scratch
#     file that cannot be made - is a failure of this function. Nothing is
#     reported as a successful empty capture.
#   * Values are separated by NUL (env -0) and converted to SOH before awk,
#     because a value containing a newline would otherwise be split, sorted and
#     reassembled wrong, and a continuation line shaped like NAME=value would
#     be captured as a FABRICATED variable. A newline inside a value is
#     detected and reported instead of truncated silently.
env_export_capture() {
  _eec_shell=$1
  if [ -n "${2:-}" ]; then
    _eec_active=$2
  else
    _eec_active=$(active_release_dir) || return 1
  fi
  _eec_plan="$_eec_active/plans/$_eec_shell.sh"
  [ -f "$_eec_plan" ] || _eec_plan="$_eec_active/plans/sh.sh"
  [ -f "$_eec_plan" ] || return 1
  _eec_interp=$(devtool_interpreter "$_eec_shell") || {
    printf 'valise: error: no %s interpreter is available for the env capture\n' "$_eec_shell" >&2
    unset _eec_shell _eec_active _eec_plan
    return 1
  }
  _eec_scratch=$(trusted_mktemp dir "${TMPDIR:-/tmp}/valise-env-export.XXXXXX") || return 1
  _eec_mkdir=$(trusted_utility_path mkdir) || { remove_tree "$_eec_scratch"; return 1; }
  if ! "$_eec_mkdir" -p "$_eec_scratch/zdot" "$_eec_scratch/xdg/config" "$_eec_scratch/xdg/data" \
    "$_eec_scratch/xdg/state" "$_eec_scratch/xdg/cache" "$_eec_scratch/tmp"; then
    remove_tree "$_eec_scratch"
    unset _eec_shell _eec_active _eec_plan _eec_interp _eec_scratch _eec_mkdir
    return 1
  fi
  # The probe is a FILE, so no quoting layer can reinterpret a path. It takes
  # the dump destination and the plan as ordinary arguments and hands the plan
  # to the interpreter as a positional parameter, so nothing nests a -c script
  # inside another string. `exec env -0` replaces the shell after the plan has
  # been sourced, so the dump can only contain the post-plan environment: the
  # plan's own stdout goes to /dev/null and cannot inject a KEY=VALUE line.
  _eec_probe="$_eec_scratch/probe.sh"
  printf '%s\n' \
    '_mode=$1 _out=$2 _plan=$3 _interp=$4' \
    '_fixture() {' \
    '  env -i HOME="$EEC_HOME" ZDOTDIR="$EEC_ZDOT" BASH_ENV=/dev/null ENV=/dev/null \' \
    '    PATH=/usr/bin:/bin TMPDIR="$EEC_TMP" \' \
    '    XDG_CONFIG_HOME="$EEC_XC" XDG_DATA_HOME="$EEC_XD" XDG_STATE_HOME="$EEC_XS" \' \
    '    XDG_CACHE_HOME="$EEC_XK" "$@"' \
    '}' \
    'if [ "$_mode" = plan ]; then' \
    '  _fixture VALISE_MODULE_ROOT="$EEC_ROOT" "$_interp" -c '"'"'. "$1" >/dev/null 2>&1 || exit 96; exec env -0'"'"' probe "$_plan" >"$_out" 2>/dev/null' \
    '  exit $?' \
    'fi' \
    '_fixture "$_interp" -c '"'"'exec env -0'"'"' >"$_out" 2>/dev/null' \
    >"$_eec_probe" || {
    remove_tree "$_eec_scratch"
    unset _eec_shell _eec_active _eec_plan _eec_interp _eec_scratch _eec_mkdir _eec_probe
    return 1
  }
  _eec_status=0
  env -i PATH=/usr/bin:/bin \
    EEC_HOME="${HOME:-/}" EEC_ZDOT="$_eec_scratch/zdot" EEC_TMP="$_eec_scratch/tmp" \
    EEC_XC="$_eec_scratch/xdg/config" EEC_XD="$_eec_scratch/xdg/data" \
    EEC_XS="$_eec_scratch/xdg/state" EEC_XK="$_eec_scratch/xdg/cache" \
    EEC_ROOT="$_eec_active" \
    sh "$_eec_probe" base "$_eec_scratch/base" "$_eec_plan" "$_eec_interp" || _eec_status=$?
  if [ "$_eec_status" -eq 0 ]; then
    env -i PATH=/usr/bin:/bin \
      EEC_HOME="${HOME:-/}" EEC_ZDOT="$_eec_scratch/zdot" EEC_TMP="$_eec_scratch/tmp" \
      EEC_XC="$_eec_scratch/xdg/config" EEC_XD="$_eec_scratch/xdg/data" \
      EEC_XS="$_eec_scratch/xdg/state" EEC_XK="$_eec_scratch/xdg/cache" \
      EEC_ROOT="$_eec_active" \
      sh "$_eec_probe" plan "$_eec_scratch/target" "$_eec_plan" "$_eec_interp" || _eec_status=$?
  fi
  if [ "$_eec_status" -ne 0 ]; then
    case "$_eec_status" in
    96) printf 'valise: error: the env plan for shell %s failed to load\n' "$_eec_shell" >&2 ;;
    *) printf 'valise: error: the env capture for shell %s failed (status %s)\n' "$_eec_shell" "$_eec_status" >&2 ;;
    esac
    remove_tree "$_eec_scratch"
    unset _eec_shell _eec_active _eec_plan _eec_interp _eec_scratch _eec_mkdir _eec_probe _eec_status
    return 1
  fi
  # Diff the two dumps as SOH records. Both sides come from the SAME
  # interpreter and fixture environment, so incidental shell variables cancel
  # instead of being captured. A key present on both sides with a DIFFERENT
  # value is a real override and is kept; a key present only in the target is
  # an export. Records are matched by FILENAME, never by record count, so an
  # empty baseline cannot shift which side a record belongs to.
  _eec_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _eec_tr=$(trusted_utility_path tr) || die "no trusted tr utility available"
  _eec_result=0
  _eec_diagnosed=0
  "$_eec_tr" '\000' '\001' <"$_eec_scratch/base" >"$_eec_scratch/base.soh" || _eec_result=1
  "$_eec_tr" '\000' '\001' <"$_eec_scratch/target" >"$_eec_scratch/target.soh" || _eec_result=1
  if [ "$_eec_result" -eq 0 ]; then
    BASE="$_eec_scratch/base.soh" TARGET="$_eec_scratch/target.soh" "$_eec_awk" '
      BEGIN { RS = "\001"; ORS = "\001" }
      function key_of(rec,   at) { at = index(rec, "="); return at ? substr(rec, 1, at - 1) : "" }
      FILENAME == ENVIRON["BASE"] { base_key[key_of($0)] = $0; next }
      FILENAME == ENVIRON["TARGET"] {
        k = key_of($0)
        if (k == "") next
        if (k in base_key) { if (base_key[k] != $0) print $0; next }
        print $0
      }
    ' "$_eec_scratch/base.soh" "$_eec_scratch/target.soh" \
      >"$_eec_scratch/diff.soh" || _eec_result=1
  fi
  if [ "$_eec_result" -eq 0 ]; then
    # A value containing a newline cannot be represented in environment.d
    # (one KEY=VALUE per line), in a plist string, or in WSLENV. Truncating it
    # silently would publish a WRONG value to the GUI session, so the capture
    # refuses: name the owning key and fail. This is why the dumps are
    # NUL/SOH separated - a line-based diff could not even detect the case.
    _eec_diagnosed=0
    if ! "$_eec_awk" '
      BEGIN { RS = "\001"; bad = 0 }
      {
        if (index($0, "\n") == 0) next
        name = $0; sub(/=.*/, "", name)
        printf "valise: error: the env plan sets %s to a value containing a newline; GUI env formats cannot represent it\n", name > "/dev/stderr"
        bad = 1
      }
      END { exit bad ? 1 : 0 }
    ' "$_eec_scratch/diff.soh"; then
      _eec_result=1
      _eec_diagnosed=1
    fi
  fi
  if [ "$_eec_result" -eq 0 ]; then
    "$_eec_awk" '
      BEGIN { RS = "\001"; ORS = "" }
      {
        name = $0; sub(/=.*/, "", name)
        if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
        if (name == "_" || name == "HOME" || name == "PATH" || name == "PWD" ||
            name == "SHLVL" || name == "OLDPWD" || name == "VALISE_MODULE_ROOT" ||
            name == "ZDOTDIR" || name == "BASH_ENV" || name == "ENV" ||
            name == "XDG_CONFIG_HOME" || name == "XDG_DATA_HOME" ||
            name == "XDG_STATE_HOME" || name == "XDG_CACHE_HOME" || name == "TMPDIR") next
        print $0 "\n"
      }
    ' "$_eec_scratch/diff.soh"
  fi
  if [ "$_eec_result" -ne 0 ]; then
    [ "$_eec_diagnosed" = 1 ] ||
      printf 'valise: error: the env capture for shell %s could not be read\n' "$_eec_shell" >&2
  fi
  remove_tree "$_eec_scratch"
  _eec_rc=$_eec_result
  unset _eec_shell _eec_active _eec_plan _eec_interp _eec_scratch _eec_mkdir _eec_probe _eec_status
  unset _eec_awk _eec_tr _eec_result _eec_diagnosed
  return "$_eec_rc"
}

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
    printf '%s\n' '# written by valise (gui_env=systemd); do not edit'
    printf '%s\n' "$_eee_capture" | "$_eee_awk" -F= '
      function needs_quoting(val,   i, c, metas) {
        metas = " \t\n\"'"'"'\\$`!*?[]{}()<>|;&"
        for (i = 1; i <= length(val); i++) {
          c = substr(val, i, 1)
          if (index(metas, c) > 0) return 1
        }
        return 0
      }
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        key = $1
        sub(/^[^=]*=/, "")
        val = $0
        gsub(/\$/, "$$", val)
        if (needs_quoting(val)) {
          gsub(/\\/, "\\\\", val); gsub(/"/, "\\\"", val)
          printf "%s=\"%s\"\n", key, val
        } else {
          printf "%s=%s\n", key, val
        }
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
    printf '%s\n' "$_eee_capture" | "$_eee_awk" -F= '
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
    printf '%s\n' "$_eee_capture" | "$_eee_awk" -F= '
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
  unset _eee_format _eee_capture _eee_awk
  return "$_eee_rc"
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
    _ee_shell=sh
    case "${SHELL:-}" in
    */zsh|zsh) _ee_shell=zsh ;;
    */ksh|ksh) _ee_shell=ksh ;;
    */bash|bash) _ee_shell=bash ;;
    esac
    _ee_capture=$(env_export_capture "$_ee_shell") || die "cannot capture the env plan for shell $_ee_shell"
    env_export_emit "$_ee_format" "$_ee_capture" || die "cannot render the $_ee_format format"
    unset _ee_format _ee_shell _ee_capture
    return 0
    ;;
  '') ;;
  *) die "unknown env option: $1" ;;
  esac
  _env_engine=$(engine_root) || die "cannot locate the valise engine"
  _env_project=$(project_find_root 2>/dev/null || :)
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

# _lint_path_scan <file> <module>: reject raw PATH assignments in a module
# body. The env plan is re-sourced at every startup entry point and the
# interactive plan is re-sourced on a release switch (and on `source ~/.bashrc`
# in a live shell), so a raw 'PATH=...:$PATH' duplicates entries in EVERY
# phase. PATH changes go through valise_path_prepend/valise_path_append.
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
  if [ -n "${_lps_hits// /}" ]; then
    _lps_head=$(trusted_utility_path head) || die "no trusted head utility available"
    _lps_line=$(printf '%s\n' "$_lps_hits" | "$_lps_head" -n 1)
    _lps_lineno=${_lps_line%%:*}
    lint_report FAIL "$_lps_mod: body assigns PATH directly (line $_lps_lineno); use valise_path_prepend/valise_path_append (requires=valise_path) so re-evaluation stays idempotent"
  fi
  unset _lps_file _lps_mod _lps_grep _lps_hits _lps_head _lps_line _lps_lineno
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
      _lint_path_scan "$_lint_dir/$_lint_load" "$_lint_mname"
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
    "$_run_interp" "$_dev_tmp/runner" "$@" || _run_rc=$?
  else
    devtool_exec "$_dev_tmp/home" "$_run_interp" "$_dev_tmp/runner" "$@" || _run_rc=$?
  fi
  devtool_cleanup
  unset _run_class _run_modules _run_bundle _run_variant _run_keep _run_script _run_interp _run_rel \
    _r_sh _r_bash _r_zsh _r_ksh _r_fish
  return "$_run_rc"
}
