#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Capability layer contract tests for portable profile modules.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPABILITIES_SH="$ROOT_DIR/lib/capabilities.sh"
METADATA_SH="$ROOT_DIR/lib/metadata.sh"

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

assert_eq() {
  _total=$((_total + 1))
  _label=$1
  _expected=$2
  _actual=$3
  if [ "$_expected" = "$_actual" ]; then
    pass "$_label"
  else
    fail "$_label" "expected: $_expected; actual: $_actual"
  fi
}

assert_contains() {
  _total=$((_total + 1))
  _label=$1
  _haystack=$2
  _needle=$3
  case "$_haystack" in
  *"$_needle"*) pass "$_label" ;;
  *) fail "$_label" "missing: $_needle; actual: $_haystack" ;;
  esac
}

assert_status() {
  _total=$((_total + 1))
  _label=$1
  _expected=$2
  _actual=$3
  if [ "$_expected" -eq "$_actual" ]; then
    pass "$_label (exit $_actual)"
  else
    fail "$_label" "expected exit: $_expected; actual exit: $_actual"
  fi
}

assert_file() {
  _total=$((_total + 1))
  _path=$1
  _label=$2
  if [ -f "$_path" ]; then
    pass "$_label"
  else
    fail "$_label" "missing file: $_path"
  fi
}

assert_dir() {
  _total=$((_total + 1))
  _path=$1
  _label=$2
  if [ -d "$_path" ]; then
    pass "$_label"
  else
    fail "$_label" "missing directory: $_path"
  fi
}

assert_not_exists() {
  _total=$((_total + 1))
  _path=$1
  _label=$2
  if [ ! -e "$_path" ]; then
    pass "$_label"
  else
    fail "$_label" "unexpected path exists: $_path"
  fi
}

assert_empty() {
  _total=$((_total + 1))
  _label=$1
  _actual=$2
  if [ -z "$_actual" ]; then
    pass "$_label"
  else
    fail "$_label" "expected empty output; actual: $_actual"
  fi
}

assert_no_spc_private_variables() {
  _cap_label=$1
  _cap_leaks=$(compgen -A variable _spc_ | sort | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*$//')
  assert_empty "$_cap_label" "$_cap_leaks"
  unset _cap_label _cap_leaks
}

write_executable() {
  _target=$1
  shift
  cat >"$_target"
  chmod +x "$_target"
}

group_other_access_paths() {
  command -p find "$1" -prune \( \
    -perm -040 -o -perm -020 -o -perm -010 -o \
    -perm -004 -o -perm -002 -o -perm -001 \
  \) -print 2>/dev/null
}

printf '\n=== Capability library presence ===\n'
_total=$((_total + 1))
if [ -f "$CAPABILITIES_SH" ]; then
  pass 'capability library exists'
  _total=$((_total + 1))
  # shellcheck disable=SC1090
  if . "$CAPABILITIES_SH"; then
    pass 'capability library sources successfully'
  else
    fail 'capability library sources successfully'
  fi
else
  fail 'capability library exists' "$CAPABILITIES_SH"
  printf '\n=== capabilities summary ===\n'
  printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
  exit 1
fi

for _fn in \
  sp_cap_os \
  sp_cap_command_exists \
  sp_cap_command_path \
  sp_cap_cpu_count \
  sp_cap_file_mtime \
  sp_cap_mktemp_dir \
  sp_cap_mktemp_file \
  sp_cap_canonical_path \
  sp_cap_path_under \
  sp_cap_reject_symlink_path \
  sp_cap_homebrew_prefix \
  sp_cap_homebrew_opt_gnubin \
  sp_cap_write_compromise_paths \
  sp_cap_secure_local_bin_check \
  sp_cap_remove_tree \
  sp_cap_trusted_mktemp_file \
  sp_cap_background; do
  _total=$((_total + 1))
  if type "$_fn" >/dev/null 2>&1; then
    pass "capability function exists: $_fn"
  else
    fail "capability function exists: $_fn"
  fi
done
unset _fn

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-capabilities.XXXXXX") || exit 1
_tmp_real=$(cd "$_tmp" && pwd -P) || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

printf '\n=== OS and command discovery ===\n'
_stub_dir="$_tmp/os-stubs"
mkdir -p "$_stub_dir"
write_executable "$_stub_dir/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${SP_CAP_STUB_UNAME:-Darwin}"
STUB
_out=$(SP_CAP_STUB_UNAME=Darwin PATH="$_stub_dir:$PATH" sp_cap_os 2>&1)
_status=$?
assert_status 'sp_cap_os maps Darwin to darwin' 0 "$_status"
assert_eq 'sp_cap_os Darwin output' 'darwin' "$_out"
_out=$(SP_CAP_STUB_UNAME=Linux PATH="$_stub_dir:$PATH" sp_cap_os 2>&1)
assert_eq 'sp_cap_os Linux output' 'linux' "$_out"
_out=$(SP_CAP_STUB_UNAME=FreeBSD PATH="$_stub_dir:$PATH" sp_cap_os 2>&1)
assert_eq 'sp_cap_os FreeBSD output' 'freebsd' "$_out"
_out=$(SP_CAP_STUB_UNAME=DragonFlyBSD PATH="$_stub_dir:$PATH" sp_cap_os 2>&1)
assert_eq 'sp_cap_os generic BSD output' 'bsd' "$_out"
_out=$(SP_CAP_STUB_UNAME=Plan9 PATH="$_stub_dir:$PATH" sp_cap_os 2>&1)
assert_eq 'sp_cap_os unknown output' 'unknown' "$_out"

write_executable "$_stub_dir/tool-probe" <<'STUB'
#!/bin/sh
exit 0
STUB
PATH="$_stub_dir:$PATH" sp_cap_command_exists tool-probe >/dev/null 2>&1
assert_status 'sp_cap_command_exists finds PATH executable' 0 "$?"
PATH="$_stub_dir:$PATH" sp_cap_command_exists missing-tool-probe >/dev/null 2>&1
assert_status 'sp_cap_command_exists rejects missing command' 1 "$?"
for _option_like in -p -v --; do
  PATH="$_stub_dir:$PATH" sp_cap_command_exists "$_option_like" >/dev/null 2>&1
  assert_status "sp_cap_command_exists rejects option-like command name $_option_like" 1 "$?"
done
unset _option_like
_out=$(PATH="$_stub_dir:$PATH" sp_cap_command_path tool-probe 2>&1)
assert_eq 'sp_cap_command_path returns executable path' "$_stub_dir/tool-probe" "$_out"
_out=$(PATH="$_stub_dir:$PATH" sp_cap_command_path -- 2>&1)
assert_status 'sp_cap_command_path rejects option-like command names' 1 "$?"
assert_empty 'sp_cap_command_path emits no path for option-like command names' "$_out"

printf '\n=== CPU count fallback chain ===\n'
_cpu_dir="$_tmp/cpu-stubs"
mkdir -p "$_cpu_dir"
write_executable "$_cpu_dir/getconf" <<'STUB'
#!/bin/sh
printf 'getconf:%s\n' "$*" >>"$SP_CAP_STUB_LOG"
case "${SP_CAP_GETCONF:-ok}" in
ok) [ "$1" = _NPROCESSORS_ONLN ] && printf '8\n' && exit 0 ;;
bad) printf 'not-a-number\n'; exit 0 ;;
esac
exit 1
STUB
write_executable "$_cpu_dir/sysctl" <<'STUB'
#!/bin/sh
printf 'sysctl:%s\n' "$*" >>"$SP_CAP_STUB_LOG"
case "${SP_CAP_SYSCTL:-fail}" in
ok) [ "$1" = -n ] && [ "$2" = hw.ncpu ] && printf '6\n' && exit 0 ;;
bad) printf 'NaN\n'; exit 0 ;;
esac
exit 1
STUB
write_executable "$_cpu_dir/nproc" <<'STUB'
#!/bin/sh
printf 'nproc:%s\n' "$*" >>"$SP_CAP_STUB_LOG"
case "${SP_CAP_NPROC:-fail}" in
ok) printf '5\n'; exit 0 ;;
bad) printf 'zero\n'; exit 0 ;;
esac
exit 1
STUB
export SP_CAP_STUB_LOG="$_tmp/cpu.log"
: >"$SP_CAP_STUB_LOG"
_out=$(SP_CAP_GETCONF=ok PATH="$_cpu_dir" sp_cap_cpu_count 2>&1)
assert_eq 'sp_cap_cpu_count prefers getconf when valid' '8' "$_out"
assert_eq 'sp_cap_cpu_count stops after getconf success' 'getconf:_NPROCESSORS_ONLN' "$(cat "$SP_CAP_STUB_LOG")"
: >"$SP_CAP_STUB_LOG"
_out=$(SP_CAP_GETCONF=fail SP_CAP_SYSCTL=ok PATH="$_cpu_dir" sp_cap_cpu_count 2>&1)
assert_eq 'sp_cap_cpu_count falls back to sysctl hw.ncpu' '6' "$_out"
assert_contains 'sp_cap_cpu_count sysctl fallback probes sysctl' "$(cat "$SP_CAP_STUB_LOG")" 'sysctl:-n hw.ncpu'
: >"$SP_CAP_STUB_LOG"
_out=$(SP_CAP_GETCONF=bad SP_CAP_SYSCTL=bad SP_CAP_NPROC=ok PATH="$_cpu_dir" sp_cap_cpu_count 2>&1)
assert_eq 'sp_cap_cpu_count falls back to nproc after invalid values' '5' "$_out"
_out=$(SP_CAP_GETCONF=fail SP_CAP_SYSCTL=fail SP_CAP_NPROC=fail PATH="$_cpu_dir" sp_cap_cpu_count 2>&1)
assert_eq 'sp_cap_cpu_count degrades to one core when probes fail' '1' "$_out"

printf '\n=== File mtime helper ===\n'
_mtime_dir="$_tmp/mtime-stubs"
mkdir -p "$_mtime_dir"
_mtime_file="$_tmp/mtime-target"
: >"$_mtime_file"
write_executable "$_mtime_dir/stat" <<'STUB'
#!/bin/sh
case "${SP_CAP_STAT_STYLE:-gnu}" in
gnu)
  [ "$1" = -c ] && [ "$2" = %Y ] && printf '123\n' && exit 0
  exit 1
  ;;
bsd)
  [ "$1" = -c ] && exit 1
  [ "$1" = -f ] && [ "$2" = %m ] && printf '456\n' && exit 0
  exit 1
  ;;
bad)
  printf 'bad\n'
  exit 0
  ;;
esac
exit 1
STUB
_out=$(SP_CAP_STAT_STYLE=gnu PATH="$_mtime_dir" sp_cap_file_mtime "$_mtime_file" 2>&1)
assert_eq 'sp_cap_file_mtime reads GNU stat -c %Y' '123' "$_out"
_out=$(SP_CAP_STAT_STYLE=bsd PATH="$_mtime_dir" sp_cap_file_mtime "$_mtime_file" 2>&1)
assert_eq 'sp_cap_file_mtime falls back to BSD stat -f %m' '456' "$_out"
_out=$(SP_CAP_STAT_STYLE=bad PATH="$_mtime_dir" sp_cap_file_mtime "$_mtime_file" 2>&1)
assert_status 'sp_cap_file_mtime rejects non-numeric stat output' 1 "$?"
assert_empty 'sp_cap_file_mtime emits no bogus mtime on failure' "$_out"

printf '\n=== Canonical path and symlink policy helpers ===\n'
_home="$_tmp/home"
_outside="$_tmp/outside"
mkdir -p "$_home/.local/bin" "$_outside"
_home_real=$(cd "$_home" && pwd -P)
_outside_real=$(cd "$_outside" && pwd -P)
_out=$(sp_cap_canonical_path / 2>&1)
assert_eq 'sp_cap_canonical_path returns single slash for filesystem root' '/' "$_out"
_out=$(sp_cap_canonical_path /dev 2>&1)
assert_eq 'sp_cap_canonical_path does not add extra slash for root-level directories' '/dev' "$_out"
_missing_root="/__sp_cap_missing_root_$$/child"
[ ! -e "/__sp_cap_missing_root_$$" ] || exit 97
_out=$(sp_cap_canonical_path "$_missing_root" 2>&1)
assert_eq 'sp_cap_canonical_path does not add extra slash for missing root-level suffix' "$_missing_root" "$_out"
sp_cap_path_under /dev /dev >/dev/null 2>&1
assert_status 'sp_cap_path_under accepts exact root-level base directory' 0 "$?"
_out=$(sp_cap_canonical_path "$_home/.local/bin/tool" 2>&1)
assert_eq 'sp_cap_canonical_path preserves canonical existing parent plus basename' "$_home_real/.local/bin/tool" "$_out"
_out=$(sp_cap_canonical_path "$_home/new/child/tool" 2>&1)
assert_eq 'sp_cap_canonical_path resolves nearest existing ancestor for missing suffix' "$_home_real/new/child/tool" "$_out"
sp_cap_path_under "$_home" "$_home/.local/bin/tool" >/dev/null 2>&1
assert_status 'sp_cap_path_under accepts canonical child path' 0 "$?"
assert_no_spc_private_variables 'sp_cap_path_under success cleans private scratch variables'
sp_cap_path_under "$_home" "$_outside/tool" >/dev/null 2>&1
assert_status 'sp_cap_path_under rejects outside path' 1 "$?"
assert_no_spc_private_variables 'sp_cap_path_under failure cleans private scratch variables'
_path_stub_dir="$_tmp/path-stubs"
_path_stub_log="$_tmp/path-stubs.log"
mkdir -p "$_path_stub_dir"
: >"$_path_stub_log"
write_executable "$_path_stub_dir/dirname" <<'STUB'
#!/bin/sh
printf '%s\n' dirname >>"$SP_CAP_STUB_LOG"
printf '%s\n' "$SP_CAP_FAKE_DIRNAME"
STUB
write_executable "$_path_stub_dir/basename" <<'STUB'
#!/bin/sh
printf '%s\n' basename >>"$SP_CAP_STUB_LOG"
printf '%s\n' inside
STUB
SP_CAP_STUB_LOG="$_path_stub_log" SP_CAP_FAKE_DIRNAME="$_home" PATH="$_path_stub_dir:$PATH" sp_cap_path_under "$_home" /etc/passwd >/dev/null 2>&1
assert_status 'sp_cap_path_under rejects outside path with PATH-first dirname/basename' 1 "$?"
assert_empty 'sp_cap_path_under does not execute PATH-first dirname/basename' "$(cat "$_path_stub_log")"
_etc_real=$(cd /etc && pwd -P)
_cd_stub_log="$_tmp/cd-function.log"
: >"$_cd_stub_log"
_out=$(
  cd "$_home" || exit 97
  cd() { printf '%s\n' cd >>"$_cd_stub_log"; return 0; }
  sp_cap_canonical_path /etc/passwd
)
_status=$?
assert_status 'sp_cap_canonical_path succeeds with caller-defined cd function present' 0 "$_status"
assert_eq 'sp_cap_canonical_path ignores caller-defined cd function' "$_etc_real/passwd" "$_out"
assert_empty 'sp_cap_canonical_path does not execute caller-defined cd function' "$(cat "$_cd_stub_log")"
: >"$_cd_stub_log"
(
  cd "$_home" || exit 97
  cd() { printf '%s\n' cd >>"$_cd_stub_log"; return 0; }
  sp_cap_path_under "$_home" /etc/passwd >/dev/null 2>&1
)
assert_status 'sp_cap_path_under rejects outside path with caller-defined cd function' 1 "$?"
assert_empty 'sp_cap_path_under does not execute caller-defined cd function' "$(cat "$_cd_stub_log")"
: >"$_cd_stub_log"
_out=$(/bin/sh -c '
  . "$1" || exit 97
  cd "$2" || exit 97
  cd() { printf "%s\n" cd >>"$3"; return 0; }
  sp_cap_path_under "$2" /etc/passwd >/dev/null 2>&1
  printf "%s\n" "$?"
' sh "$CAPABILITIES_SH" "$_home" "$_cd_stub_log")
assert_eq '/bin/sh sp_cap_path_under rejects outside path with caller-defined cd function' '1' "$_out"
assert_empty '/bin/sh sp_cap_path_under does not execute caller-defined cd function' "$(cat "$_cd_stub_log")"
_command_stub_log="$_tmp/command-function.log"
: >"$_command_stub_log"
_out=$(bash -c '
  . "$1" || exit 97
  cd "$2" || exit 97
  SP_CAP_FAKE_PWD="$2"
  export SP_CAP_FAKE_PWD
  command() {
    printf "%s:%s\n" command "${1:-}" >>"$3"
    case "${1:-}" in
    cd)
      return 0
      ;;
    pwd)
      if [ "${2:-}" = -P ]; then
        printf "%s\n" "$SP_CAP_FAKE_PWD"
        return 0
      fi
      ;;
    printf)
      printf "%s/passwd\n" "$SP_CAP_FAKE_PWD"
      return 0
      ;;
    esac
    builtin command "$@"
  }
  sp_cap_canonical_path /etc/passwd
' bash "$CAPABILITIES_SH" "$_home" "$_command_stub_log")
_status=$?
assert_status 'sp_cap_canonical_path succeeds with caller-defined command function present' 0 "$_status"
assert_eq 'sp_cap_canonical_path ignores caller-defined command function' "$_etc_real/passwd" "$_out"
assert_empty 'sp_cap_canonical_path does not execute caller-defined command function' "$(cat "$_command_stub_log")"
: >"$_command_stub_log"
_out=$(bash -c '
  . "$1" || exit 97
  cd "$2" || exit 97
  SP_CAP_FAKE_PWD="$2"
  export SP_CAP_FAKE_PWD
  command() {
    printf "%s:%s\n" command "${1:-}" >>"$3"
    case "${1:-}" in
    cd)
      return 0
      ;;
    pwd)
      if [ "${2:-}" = -P ]; then
        printf "%s\n" "$SP_CAP_FAKE_PWD"
        return 0
      fi
      ;;
    printf)
      printf "%s/passwd\n" "$SP_CAP_FAKE_PWD"
      return 0
      ;;
    esac
    builtin command "$@"
  }
  sp_cap_path_under "$2" /etc/passwd >/dev/null 2>&1
  printf "%s\n" "$?"
' bash "$CAPABILITIES_SH" "$_home" "$_command_stub_log")
assert_eq 'sp_cap_path_under rejects outside path with caller-defined command function' '1' "$_out"
assert_empty 'sp_cap_path_under does not execute caller-defined command function' "$(cat "$_command_stub_log")"
ln -s "$_outside" "$_home/link-out"
sp_cap_path_under "$_home" "$_home/link-out/tool" >/dev/null 2>&1
assert_status 'sp_cap_path_under rejects symlink-parent escape after canonicalization' 1 "$?"
sp_cap_reject_symlink_path "$_home_real/link-out/tool" >/dev/null 2>&1
assert_status 'sp_cap_reject_symlink_path rejects symlink parent before mutation' 1 "$?"
sp_cap_reject_symlink_path "$_home_real/.local/bin/tool" >/dev/null 2>&1
assert_status 'sp_cap_reject_symlink_path accepts non-symlink missing final path' 0 "$?"

printf '\n=== Secure temp directory helper ===\n'
_out=$(unset TMPDIR; sp_cap_mktemp_dir default-temp 2>&1)
_status=$?
assert_status 'sp_cap_mktemp_dir default succeeds when TMPDIR is unset' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  assert_dir "$_out" 'sp_cap_mktemp_dir default creates a directory'
  _bad_default_perms=$(group_other_access_paths "$_out")
  assert_empty 'sp_cap_mktemp_dir default creates group/other-closed directory' "$_bad_default_perms"
  rm -rf "$_out"
else
  _total=$((_total + 2))
  fail 'sp_cap_mktemp_dir default creates a directory' "actual: $_out"
  fail 'sp_cap_mktemp_dir default creates group/other-closed directory' "actual: $_out"
fi
_out=$(TMPDIR="$_tmp" sp_cap_mktemp_dir profile-test 2>&1)
_status=$?
assert_status 'sp_cap_mktemp_dir succeeds under absolute TMPDIR' 0 "$_status"
assert_dir "$_out" 'sp_cap_mktemp_dir creates a directory'
_total=$((_total + 1))
case "$_out" in
"$_tmp_real"/profile-test.*) pass 'sp_cap_mktemp_dir uses requested parent and prefix' ;;
*) fail 'sp_cap_mktemp_dir uses requested parent and prefix' "actual: $_out" ;;
esac
_bad_perms=$(group_other_access_paths "$_out")
assert_empty 'sp_cap_mktemp_dir creates group/other-closed directory' "$_bad_perms"
_mktemp_parent="$_tmp/mktemp-parent"
_mktemp_parent_real="$_tmp_real/mktemp-parent"
_evil_tmp="$_tmp/evil-mktemp-result"
_mktemp_stub_dir="$_tmp/mktemp-stubs"
_mktemp_stub_log="$_tmp/mktemp-stubs.log"
mkdir -p "$_mktemp_parent" "$_evil_tmp" "$_mktemp_stub_dir"
chmod 777 "$_evil_tmp"
: >"$_mktemp_stub_log"
write_executable "$_mktemp_stub_dir/mktemp" <<'STUB'
#!/bin/sh
printf '%s\n' fake-mktemp >>"$SP_CAP_STUB_LOG"
printf '%s\n' "$SP_CAP_FAKE_MKTEMP_OUT"
exit 0
STUB
_out=$(SP_CAP_STUB_LOG="$_mktemp_stub_log" SP_CAP_FAKE_MKTEMP_OUT="$_evil_tmp" PATH="$_mktemp_stub_dir:$PATH" sp_cap_mktemp_dir profile-test "$_mktemp_parent" 2>&1)
_status=$?
assert_status 'sp_cap_mktemp_dir uses trusted mktemp despite PATH-first fake' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  _total=$((_total + 1))
  case "$_out" in
  "$_mktemp_parent_real"/profile-test.*) pass 'sp_cap_mktemp_dir hostile-PATH result stays under requested parent and prefix' ;;
  *) fail 'sp_cap_mktemp_dir hostile-PATH result stays under requested parent and prefix' "actual: $_out" ;;
  esac
  _bad_fake_perms=$(group_other_access_paths "$_out")
  assert_empty 'sp_cap_mktemp_dir hostile-PATH result is group/other-closed' "$_bad_fake_perms"
  rm -rf "$_out"
else
  _total=$((_total + 2))
  fail 'sp_cap_mktemp_dir hostile-PATH result stays under requested parent and prefix' "actual: $_out"
  fail 'sp_cap_mktemp_dir hostile-PATH result is group/other-closed' "actual: $_out"
fi
assert_empty 'sp_cap_mktemp_dir does not execute PATH-first fake mktemp' "$(cat "$_mktemp_stub_log")"
_mktemp_command_log="$_tmp/mktemp-command.log"
_mktemp_victim="$_mktemp_parent_real/profile-test.command-victim"
rm -rf "$_mktemp_victim"
mkdir -p "$_mktemp_victim"
chmod 700 "$_mktemp_victim"
: >"$_mktemp_command_log"
_out=$(
  SP_CAP_FAKE_MKTEMP_OUT="$_mktemp_victim"
  command() {
    printf '%s:%s:%s\n' command "${1:-}" "${2:-}" >>"$_mktemp_command_log"
    if [ "${1:-}" = -p ] && [ "${2:-}" = mktemp ]; then
      printf '%s\n' "$SP_CAP_FAKE_MKTEMP_OUT"
      return 0
    fi
    if [ "${1:-}" = -p ] && [ "${2:-}" = find ]; then
      return 0
    fi
    builtin command "$@"
  }
  sp_cap_mktemp_dir profile-test "$_mktemp_parent" 2>&1
)
_status=$?
assert_status 'sp_cap_mktemp_dir ignores caller-defined command function for mktemp' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  _total=$((_total + 1))
  if [ "$_out" != "$_mktemp_victim" ]; then
    pass 'sp_cap_mktemp_dir does not accept command-function-selected victim'
  else
    fail 'sp_cap_mktemp_dir does not accept command-function-selected victim' "actual: $_out"
  fi
  rm -rf "$_out"
else
  _total=$((_total + 1))
  fail 'sp_cap_mktemp_dir does not accept command-function-selected victim' "actual: $_out"
fi
assert_empty 'sp_cap_mktemp_dir does not execute caller-defined command function' "$(cat "$_mktemp_command_log")"
for _accessible_mode in 0755 0750 0701; do
  _accessible_tmp="$_mktemp_parent_real/profile-test.accessible-$_accessible_mode"
  rm -rf "$_accessible_tmp"
  mkdir -p "$_accessible_tmp"
  chmod "$_accessible_mode" "$_accessible_tmp"
  _out=$(sp_cap_group_other_access_paths "$_accessible_tmp" 2>&1)
  _status=$?
  assert_status "sp_cap_group_other_access_paths inspects $_accessible_mode directory" 0 "$_status"
  assert_eq "sp_cap_group_other_access_paths reports $_accessible_mode directory" "$_accessible_tmp" "$_out"
done
unset _accessible_mode _accessible_tmp
_out=$(TMPDIR=relative sp_cap_mktemp_dir profile-test 2>&1)
assert_status 'sp_cap_mktemp_dir rejects relative TMPDIR for mutation safety' 1 "$?"

printf '\n=== Secure temp file helper ===\n'
_mktemp_file_parent="$_tmp/temp-file-parent"
_mktemp_file_parent_real="$_tmp_real/temp-file-parent"
mkdir -p "$_mktemp_file_parent"
_out=$(sp_cap_mktemp_file "$_mktemp_file_parent" wrapper-state 2>&1)
_status=$?
assert_status 'sp_cap_mktemp_file succeeds under absolute parent' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  assert_file "$_out" 'sp_cap_mktemp_file creates a regular file'
  _total=$((_total + 1))
  case "$_out" in
  "$_mktemp_file_parent_real"/.wrapper-state.*) pass 'sp_cap_mktemp_file uses hidden requested parent and prefix' ;;
  *) fail 'sp_cap_mktemp_file uses hidden requested parent and prefix' "actual: $_out" ;;
  esac
  _bad_file_perms=$(group_other_access_paths "$_out")
  assert_empty 'sp_cap_mktemp_file creates group/other-closed file' "$_bad_file_perms"
  rm -f "$_out"
else
  _total=$((_total + 3))
  fail 'sp_cap_mktemp_file creates a regular file' "actual: $_out"
  fail 'sp_cap_mktemp_file uses hidden requested parent and prefix' "actual: $_out"
  fail 'sp_cap_mktemp_file creates group/other-closed file' "actual: $_out"
fi
_direct_file_out="$_tmp/direct-temp-file.out"
_direct_file_err="$_tmp/direct-temp-file.err"
sp_cap_mktemp_file "$_mktemp_file_parent" direct-clean >"$_direct_file_out" 2>"$_direct_file_err"
_status=$?
assert_status 'sp_cap_mktemp_file direct call succeeds' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  _direct_file=$(cat "$_direct_file_out")
  assert_file "$_direct_file" 'sp_cap_mktemp_file direct call creates file before cleanup'
  rm -f "$_direct_file"
else
  _total=$((_total + 1))
  fail 'sp_cap_mktemp_file direct call creates file before cleanup' "actual stderr: $(cat "$_direct_file_err")"
fi
assert_no_spc_private_variables 'sp_cap_mktemp_file success cleans private scratch variables'
sp_cap_mktemp_file relative-parent wrapper-state >/dev/null 2>&1
assert_status 'sp_cap_mktemp_file rejects relative parent for mutation safety' 1 "$?"
assert_no_spc_private_variables 'sp_cap_mktemp_file relative-parent failure cleans private scratch variables'
_out=$(sp_cap_mktemp_file "$_mktemp_file_parent" '../bad' 2>&1)
assert_status 'sp_cap_mktemp_file rejects escaped prefixes' 1 "$?"
assert_contains 'sp_cap_mktemp_file invalid-prefix diagnostic is clear' "$_out" 'invalid temp file prefix'
_file_stub_log="$_tmp/mktemp-file-stubs.log"
_file_evil="$_tmp/evil-mktemp-file"
: >"$_file_stub_log"
: >"$_file_evil"
chmod 666 "$_file_evil"
_out=$(SP_CAP_STUB_LOG="$_file_stub_log" SP_CAP_FAKE_MKTEMP_OUT="$_file_evil" PATH="$_mktemp_stub_dir:$PATH" sp_cap_mktemp_file "$_mktemp_file_parent" wrapper-state 2>&1)
_status=$?
assert_status 'sp_cap_mktemp_file uses trusted mktemp despite PATH-first fake' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  _total=$((_total + 1))
  case "$_out" in
  "$_mktemp_file_parent_real"/.wrapper-state.*) pass 'sp_cap_mktemp_file hostile-PATH result stays under requested parent and prefix' ;;
  *) fail 'sp_cap_mktemp_file hostile-PATH result stays under requested parent and prefix' "actual: $_out" ;;
  esac
  _bad_fake_file_perms=$(group_other_access_paths "$_out")
  assert_empty 'sp_cap_mktemp_file hostile-PATH result is group/other-closed' "$_bad_fake_file_perms"
  rm -f "$_out"
else
  _total=$((_total + 2))
  fail 'sp_cap_mktemp_file hostile-PATH result stays under requested parent and prefix' "actual: $_out"
  fail 'sp_cap_mktemp_file hostile-PATH result is group/other-closed' "actual: $_out"
fi
assert_empty 'sp_cap_mktemp_file does not execute PATH-first fake mktemp' "$(cat "$_file_stub_log")"
_file_command_log="$_tmp/mktemp-file-command.log"
_file_victim="$_mktemp_file_parent_real/.wrapper-state.command-victim"
rm -f "$_file_victim"
: >"$_file_victim"
chmod 600 "$_file_victim"
: >"$_file_command_log"
_out=$(
  SP_CAP_FAKE_MKTEMP_OUT="$_file_victim"
  command() {
    printf '%s:%s:%s\n' command "${1:-}" "${2:-}" >>"$_file_command_log"
    if [ "${1:-}" = -p ] && [ "${2:-}" = mktemp ]; then
      printf '%s\n' "$SP_CAP_FAKE_MKTEMP_OUT"
      return 0
    fi
    if [ "${1:-}" = -p ] && [ "${2:-}" = find ]; then
      return 0
    fi
    builtin command "$@"
  }
  sp_cap_mktemp_file "$_mktemp_file_parent" wrapper-state 2>&1
)
_status=$?
assert_status 'sp_cap_mktemp_file ignores caller-defined command function for mktemp' 0 "$_status"
if [ "$_status" -eq 0 ]; then
  _total=$((_total + 1))
  if [ "$_out" != "$_file_victim" ]; then
    pass 'sp_cap_mktemp_file does not accept command-function-selected victim'
  else
    fail 'sp_cap_mktemp_file does not accept command-function-selected victim' "actual: $_out"
  fi
  rm -f "$_out"
else
  _total=$((_total + 1))
  fail 'sp_cap_mktemp_file does not accept command-function-selected victim' "actual: $_out"
fi
assert_empty 'sp_cap_mktemp_file does not execute caller-defined command function' "$(cat "$_file_command_log")"

printf '\n=== Homebrew path discovery ===\n'
_brew_prefix="$_tmp/homebrew-prefix"
mkdir -p "$_brew_prefix/opt/findutils/libexec/gnubin"
_out=$(HOMEBREW_PREFIX="$_brew_prefix" sp_cap_homebrew_prefix 2>&1)
assert_eq 'sp_cap_homebrew_prefix trusts absolute existing HOMEBREW_PREFIX' "$_brew_prefix" "$_out"
_out=$(HOMEBREW_PREFIX="$_brew_prefix" sp_cap_homebrew_opt_gnubin findutils 2>&1)
assert_eq 'sp_cap_homebrew_opt_gnubin emits existing gnubin path' "$_brew_prefix/opt/findutils/libexec/gnubin" "$_out"
mkdir -p "$_brew_prefix/libexec/gnubin"
_out=$(HOMEBREW_PREFIX="$_brew_prefix" sp_cap_homebrew_opt_gnubin .. 2>&1)
assert_status 'sp_cap_homebrew_opt_gnubin rejects dot-segment formula names' 1 "$?"
assert_empty 'sp_cap_homebrew_opt_gnubin emits no escaped path for dot-segment formulas' "$_out"
_brew_cmd_dir="$_tmp/brew-cmd"
_brew_cmd_prefix="$_tmp/brew-cmd-prefix"
mkdir -p "$_brew_cmd_dir" "$_brew_cmd_prefix"
write_executable "$_brew_cmd_dir/brew" <<'STUB'
#!/bin/sh
[ "$1" = --prefix ] || exit 1
printf '%s\n' "$SP_CAP_BREW_PREFIX"
STUB
_out=$(HOMEBREW_PREFIX= SP_CAP_BREW_PREFIX="$_brew_cmd_prefix" PATH="$_brew_cmd_dir:$PATH" sp_cap_homebrew_prefix 2>&1)
assert_eq 'sp_cap_homebrew_prefix falls back to brew --prefix' "$_brew_cmd_prefix" "$_out"

printf '\n=== Secure local-bin permission checks ===\n'
mkdir -p "$_home/.local/bin"
sp_cap_secure_local_bin_check "$_home" >/dev/null 2>&1
assert_status 'sp_cap_secure_local_bin_check accepts owned closed local bin chain' 0 "$?"
_compromised="$_home/.local/bin/compromised"
: >"$_compromised"
chmod o+w "$_compromised"
_out=$(sp_cap_secure_local_bin_check "$_home" 2>&1)
assert_status 'sp_cap_secure_local_bin_check rejects externally writable executable chain' 1 "$?"
assert_contains 'sp_cap_secure_local_bin_check diagnostic names compromised chain' "$_out" 'Compromised execution chain'
_inspect_stub_dir="$_tmp/inspect-stubs"
_inspect_stub_log="$_tmp/inspect-stubs.log"
mkdir -p "$_inspect_stub_dir"
: >"$_inspect_stub_log"
write_executable "$_inspect_stub_dir/find" <<'STUB'
#!/bin/sh
printf '%s\n' fake-find >>"$SP_CAP_STUB_LOG"
exit 0
STUB
_out=$(SP_CAP_STUB_LOG="$_inspect_stub_log" PATH="$_inspect_stub_dir:$PATH" sp_cap_secure_local_bin_check "$_home" 2>&1)
assert_status 'sp_cap_secure_local_bin_check rejects compromised local bin with PATH-first fake find' 1 "$?"
assert_contains 'sp_cap_secure_local_bin_check fake-find diagnostic still names compromised chain' "$_out" 'Compromised execution chain'
assert_empty 'sp_cap_secure_local_bin_check does not execute PATH-first fake find' "$(cat "$_inspect_stub_log")"
_inspect_command_log="$_tmp/inspect-command.log"
: >"$_inspect_command_log"
_out=$(bash -c '
  . "$1" || exit 97
  SP_CAP_COMMAND_LOG=$3
  export SP_CAP_COMMAND_LOG
  command() {
    printf "%s:%s:%s\n" command "${1:-}" "${2:-}" >>"$SP_CAP_COMMAND_LOG"
    if [ "${1:-}" = -p ] && [ "${2:-}" = id ]; then
      case "${3:-}" in
      -u)
        case "${4:-}" in
        -n) printf "%s\n" fakeuser ;;
        *) printf "%s\n" 0 ;;
        esac
        return 0
        ;;
      -g)
        case "${4:-}" in
        -n) printf "%s\n" fakeuser ;;
        *) printf "%s\n" 0 ;;
        esac
        return 0
        ;;
      esac
    fi
    if [ "${1:-}" = -p ] && [ "${2:-}" = find ]; then
      return 0
    fi
    builtin command "$@"
  }
  sp_cap_secure_local_bin_check "$2" 2>&1
' bash "$CAPABILITIES_SH" "$_home" "$_inspect_command_log")
assert_status 'sp_cap_secure_local_bin_check rejects compromised local bin with caller-defined command function' 1 "$?"
assert_contains 'sp_cap_secure_local_bin_check fake-command diagnostic still names compromised chain' "$_out" 'Compromised execution chain'
assert_empty 'sp_cap_secure_local_bin_check does not execute caller-defined command function' "$(cat "$_inspect_command_log")"
chmod o-w "$_compromised"
ln -s "$_outside" "$_home/.local/bin/symlinked-tool"
sp_cap_secure_local_bin_check "$_home" >/dev/null 2>&1
assert_status 'sp_cap_secure_local_bin_check rejects symlink in local bin tree' 1 "$?"
sp_cap_secure_local_bin_check "$_home" allow-owned-symlinks >/dev/null 2>&1
assert_status 'sp_cap_secure_local_bin_check accepts a user-owned symlink with allow-owned-symlinks' 0 "$?"
chmod o+w "$_compromised"
sp_cap_secure_local_bin_check "$_home" allow-owned-symlinks >/dev/null 2>&1
assert_status 'sp_cap_secure_local_bin_check still rejects a world-writable file with allow-owned-symlinks' 1 "$?"
chmod o-w "$_compromised"
sp_cap_secure_local_bin_check "$_home" unknown-policy >/dev/null 2>&1
assert_status 'sp_cap_secure_local_bin_check rejects an unknown symlink policy' 1 "$?"

printf '\n=== Background process helper ===\n'
_background_marker="$_tmp/background-marker"
_out=$(sp_cap_background /bin/sh -c 'printf done >"$1"' sh "$_background_marker" 2>&1)
_status=$?
assert_status 'sp_cap_background starts command successfully' 0 "$_status"
_total=$((_total + 1))
case "$_out" in
'' | *[!0123456789]*) fail 'sp_cap_background prints numeric pid' "actual: $_out" ;;
*) pass 'sp_cap_background prints numeric pid' ;;
esac
for _i in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$_background_marker" ] && break
  sleep 0.1
done
assert_eq 'sp_cap_background child completed with redirected stdio' 'done' "$(cat "$_background_marker" 2>/dev/null)"

printf '\n=== Capability layer availability through profile entrypoint ===\n'
_modroot="$_tmp/module-root"
mkdir -p "$_modroot/module.d" "$_modroot/modules"
cat >"$_modroot/module.d/cap_probe.meta" <<'META'
name=cap_probe
requires=
optional=
shells=posix bash zsh ksh
platforms=any
side_effect=read-only
exports=cap_probe_loaded
load=modules/cap_probe.sh
META
cat >"$_modroot/modules/cap_probe.sh" <<'MODULE'
cap_probe_loaded() { :; }
_cap_probe_os=$(sp_cap_os)
_cap_probe_cpu=$(sp_cap_cpu_count)
if [ -n "${SP_CAP_PROBE_TRACE:-}" ]; then
  printf 'os=%s cpu=%s\n' "$_cap_probe_os" "$_cap_probe_cpu" >"$SP_CAP_PROBE_TRACE"
fi
MODULE
_probe_trace="$_tmp/cap-probe.trace"
_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$_modroot" \
    VALISE_MODULES=cap_probe \
    VALISE_MODE=strict \
    SP_CAP_PROBE_TRACE="$_probe_trace" \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" >/dev/null 2>/dev/null; _s=$?; printf "status=%s loaded=%s trace=%s\n" "$_s" "$(command -v cap_probe_loaded >/dev/null 2>&1 && printf yes || printf no)" "$(cat "$SP_CAP_PROBE_TRACE" 2>/dev/null)"'
)
assert_contains 'entrypoint sources capability library before loading modules' "$_out" 'status=0'
assert_contains 'entrypoint-loaded module can call sp_cap_os' "$_out" 'trace=os='
assert_contains 'entrypoint-loaded module exports expected function' "$_out" 'loaded=yes'

printf '\n=== Platform module metadata presence ===\n'
# shellcheck disable=SC1090
. "$METADATA_SH"
for _file in \
  "$ROOT_DIR/module.d/valise_platform_posix.meta" \
  "$ROOT_DIR/module.d/valise_platform_macos.meta" \
  "$ROOT_DIR/module.d/valise_platform_linux.meta" \
  "$ROOT_DIR/module.d/valise_platform_bsd.meta" \
  "$ROOT_DIR/modules/platform/posix.sh" \
  "$ROOT_DIR/modules/platform/macos/capabilities.sh" \
  "$ROOT_DIR/modules/platform/linux/capabilities.sh" \
  "$ROOT_DIR/modules/platform/bsd/capabilities.sh"; do
  assert_file "$_file" "platform artifact exists: ${_file#$ROOT_DIR/}"
done
unset _file
_out=$(sp_metadata_read "$ROOT_DIR/module.d/valise_platform_posix.meta" 2>&1)
assert_contains 'valise_platform_posix metadata supports all platforms' "$_out" 'platforms=any'
_out=$(sp_metadata_read "$ROOT_DIR/module.d/valise_platform_macos.meta" 2>&1)
assert_contains 'valise_platform_macos metadata gates Darwin only' "$_out" 'platforms=darwin'
_out=$(sp_metadata_read "$ROOT_DIR/module.d/valise_platform_linux.meta" 2>&1)
assert_contains 'valise_platform_linux metadata gates Linux only' "$_out" 'platforms=linux'
_out=$(sp_metadata_read "$ROOT_DIR/module.d/valise_platform_bsd.meta" 2>&1)
assert_contains 'valise_platform_bsd metadata gates BSD family' "$_out" 'platforms=bsd freebsd openbsd netbsd'

printf '\n=== capabilities summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
