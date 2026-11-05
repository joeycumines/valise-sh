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
# defines valise_test_reload, then runs the body.
devtool_runner() {
  _dr_release=$(shell_quote "$2") || return 1
  _dr_cat=$(trusted_utility_path cat) || return 1
  if [ "$1" = fish ]; then
    _dr_release=$(fish_quote "$2") || return 1
    {
      printf '%s\n' \
        "set -gx SHELL_PROJECT_ROOT $_dr_release" \
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
        'valise_test_reload() {' \
        '  VALISE_MODULE_ROOT=$_valise_dev_release' \
        '  VALISE_MODE=strict' \
        '  VALISE_RELOAD=1' \
        "  . \"\$_valise_dev_release/plans/$1.sh\"" \
        '  _valise_dev_status=$?' \
        '  unset VALISE_RELOAD' \
        '  return "$_valise_dev_status"' \
        '}' \
        'VALISE_MODULE_ROOT=$_valise_dev_release' \
        'VALISE_MODE=strict' \
        ". \"\$_valise_dev_release/plans/$1.sh\" || {" \
        "  printf '%s\\n' 'valise: the modules failed to load' >&2" \
        '  exit 97' \
        '}'
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

cmd_env() {
  case "${1:-}" in
  --help | -h) usage_env; return 0 ;;
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
  "$_lint_awk" -F '\t' 'NR > 1 && $13 != "valise" { print $1 "|" $6 "|" $9 "|" $12 "|" $13 }' \
    "$_lint_registry" >"$_dev_tmp/lint-rows" || die "cannot read the registry"
  while IFS='|' read -r _lint_mname _lint_shells _lint_load _lint_tests _lint_src; do
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
  done <"$_dev_tmp/lint-rows"
  lint_report ok "$_lint_parsed syntax check(s)"
  if [ -n "$_lint_select" ]; then
    for _lint_want in $_lint_select; do
      "$_lint_awk" -F '\t' -v w="$_lint_want" 'NR > 1 && $13 != "valise" && ($1 == w || $1 "@" $13 == w) { f = 1 } END { exit !f }' \
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
    _lint_dir _lint_rel _lint_file _lint_class _lint_want
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
    "$_test_awk" -F '\t' -v w="$_test_want" 'NR > 1 && $13 != "valise" && ($1 == w || $1 "@" $13 == w) { f = 1 } END { exit !f }' \
      "$_dev_tmp/registry" || die "unknown module: $_test_want"
  done
  _test_pass=0
  _test_fail=0
  _test_skip=0
  _test_n=0
  _test_any=0
  _test_rows="$_dev_tmp/rows"
  "$_test_awk" -F '\t' 'NR > 1 && $13 != "valise" && $12 != "" { print $1 "\t" $6 "\t" $12 "\t" $13 }' \
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
