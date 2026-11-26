#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# A negative phase answer is data, not an I/O or compiler failure. Exercise
# the real probe with faults at its utility boundary in a private environment.
set -eu

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-phase-test.XXXXXX")
trap 'rm -rf "$_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
_pass=0
_fail=0
pass() { _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
mkdir -p "$_tmp/home" "$_tmp/project/module.d" "$_tmp/project/modules" "$_tmp/scratch"
: >"$_tmp/project/valise.conf"
for _phase in env interactive; do
  printf 'name=%s\nphase=%s\nside_effect=read-only\nshells=posix\nplatforms=any\nexports=\nload=modules/%s.sh\n' \
    "$_phase" "$_phase" "$_phase" >"$_tmp/project/module.d/$_phase.meta"
  printf ':\n' >"$_tmp/project/modules/$_phase.sh"
done
printf 'bundle\tshell\troots\ndefault\tsh\tenv interactive\n' >"$_tmp/project/bundles.tsv"
env -i HOME="$_tmp/home" PATH=/usr/bin:/bin \
  "$_repo/bin/valise" -C "$_tmp/project" registry >"$_tmp/registry"

# Retain the actual trusted resolver for every utility except the injected awk.
# Only the function's name changes; fault injection never edits production code.
awk '
  /^trusted_utility_path\(\) \{/ { copying = 1; sub(/trusted_utility_path/, "probe_trusted_utility_path") }
  copying { print }
  copying && /^}/ { exit }
' "$_repo/lib/cli/common.sh" >"$_tmp/resolver.sh"
cat >"$_tmp/awk" <<'EOF'
#!/bin/sh
set -eu
_compile=0
_inspect=0
for _arg do
  case $_arg in
    phase=interactive) _compile=1 ;;
    */plan|*/valise-closure-plan.*) _inspect=1 ;;
  esac
done
if [ "$_compile" -eq 1 ]; then
  printf '%s\n' "$PROBE_MODE" >>"$PROBE_MARKER"
  case $PROBE_MODE in
    compile) exit 73 ;;
    missing-header|duplicate-header)
      /usr/bin/awk "$@" >"$PROBE_OUTPUT" || exit "$?"
      if [ "$PROBE_MODE" = missing-header ]; then
        sed '/^# order=/d' "$PROBE_OUTPUT"
      else
        cat "$PROBE_OUTPUT"
        printf '# order=\n'
      fi
      exit 0 ;;
    term) kill -TERM "$PROBE_ORIGIN_PID" ;;
    term-worker) kill -TERM "$PPID" ;;
  esac
fi
if [ "$_inspect" -eq 1 ] && [ "$PROBE_MODE" = inspect ]; then
  printf 'inspection\n' >>"$PROBE_MARKER"
  exit 74
fi
exec /usr/bin/awk "$@"
EOF
chmod 0755 "$_tmp/awk"
cat >"$_tmp/mktemp" <<'EOF'
#!/bin/sh
set -eu
_allocated=$("$PROBE_REAL_MKTEMP" "$@") || exit "$?"
case $PROBE_MODE in
allocation-tree-*)
  printf 'allocated\n' >>"$PROBE_MARKER"
  # Address only this private driver and the allocation process ancestry.
  # This reproduces the relevant process-group delivery without signalling
  # the test harness or requiring a platform-specific setsid utility.
  _ancestor=$$
  _ancestors=$$
  _depth=0
  while [ "$_ancestor" != "$PROBE_ORIGIN_PID" ] && [ "$_depth" -lt 12 ]; do
    _parent=$(ps -o ppid= -p "$_ancestor") || exit 72
    set -- $_parent
    [ "$#" -eq 1 ] && [ "$1" -gt 1 ] || exit 72
    _ancestor=$1
    _ancestors="$_ancestors $_ancestor"
    _depth=$((_depth + 1))
  done
  [ "$_ancestor" = "$PROBE_ORIGIN_PID" ] || exit 72
  _signal=TERM
  [ "$PROBE_MODE" != allocation-tree-int ] || _signal=INT
  for _ancestor in $_ancestors; do kill -"$_signal" "$_ancestor" || exit 72; done
  ;;
esac
printf '%s\n' "$_allocated"
EOF
chmod 0755 "$_tmp/mktemp"
cat >"$_tmp/driver.sh" <<'EOF'
set -eu
_valise_engine_bin=$1/bin
VALISE_CLI_DIR=$1/lib/cli
for _part in usage common store fish-hook integration commands lifecycle devtools project; do
  . "$VALISE_CLI_DIR/$_part.sh"
done
. "$2/resolver.sh"
PROBE_ORIGIN_PID=$$
export PROBE_ORIGIN_PID
trusted_utility_path() {
  case $1 in
    awk) printf '%s\n' "$PROBE_AWK" ;;
    mktemp) printf '%s\n' "$PROBE_MKTEMP" ;;
    *) probe_trusted_utility_path "$1" ;;
  esac
}
case $3 in
  compile-command)
    cd "$2/project"
    cmd_compile "$TMPDIR/compiled"
    printf 'finished\n'
    exit 0 ;;
  registry-command)
    cd "$2/project"
    cmd_registry
    printf 'finished\n'
    exit 0 ;;
  dev-scratch)
    devtool_scratch
    printf 'finished\n'
    exit 0 ;;
esac
if project_closure_has_phase "$2/registry" sh "$3" '' interactive; then
  printf 'answer=yes\n'
else
  printf 'answer=no\n'
fi
printf 'finished\n'
EOF

_run() {
  _case_mode=$1 _case_roots=$2
  _case_scratch=$_tmp/scratch/$_case_mode-$_case_roots
  mkdir -p "$_case_scratch"
  : >"$_tmp/marker"
  _case_status=0
  env -i HOME="$_tmp/home" PATH=/usr/bin:/bin TMPDIR="$_case_scratch" \
    PROBE_MODE="$_case_mode" PROBE_MARKER="$_tmp/marker" PROBE_OUTPUT="$_tmp/plan.out" PROBE_AWK="$_tmp/awk" \
    PROBE_MKTEMP="$_tmp/mktemp" PROBE_REAL_MKTEMP="$_real_mktemp" \
    /bin/sh "$_tmp/driver.sh" "$_repo" "$_tmp" "$_case_roots" >"$_tmp/out" 2>"$_tmp/err" || _case_status=$?
}
_clean_scratch() {
  _left=$(find "$_case_scratch" ! -path "$_case_scratch" -print) && [ -z "$_left" ]
}

printf '=== phase probe failure boundaries ===\n'
_real_mktemp=$(command -v mktemp)
for _roots in env interactive; do
  _run healthy "$_roots"
  _want=no
  [ "$_roots" != interactive ] || _want=yes
  if [ "$_case_status" -eq 0 ] && grep -qx "answer=$_want" "$_tmp/out" &&
    grep -qx finished "$_tmp/out" && [ -s "$_tmp/marker" ] && _clean_scratch; then
    pass "$_roots closure returns the correct phase answer and cleans its scratch"
  else
    fail "$_roots closure probe"
    cat "$_tmp/out" "$_tmp/err" >&2
  fi
done
for _fault in compile inspect missing-header duplicate-header term term-worker allocation-tree-term allocation-tree-int; do
  _run "$_fault" interactive
  if [ "$_case_status" -ne 0 ] && [ -s "$_tmp/marker" ] &&
    ! grep -qx finished "$_tmp/out" && _clean_scratch; then
    _signal_status=$_case_status
    case $_fault in
      term|allocation-tree-term) _signal_status=143 ;;
      allocation-tree-int) _signal_status=130 ;;
    esac
    if [ "$_case_status" -eq "$_signal_status" ]; then
      pass "$_fault aborts the caller and removes all probe scratch"
    else
      fail "$_fault lost its signal status ($_case_status)"
    fi
  else
    fail "$_fault was hidden as an empty closure or leaked probe scratch"
    cat "$_tmp/out" "$_tmp/err" >&2
    find "$_case_scratch" -print >&2
  fi
done
for _owner in compile-command registry-command dev-scratch; do
  for _fault in allocation-tree-term allocation-tree-int; do
    _run "$_fault" "$_owner"
    _want_status=143
    [ "$_fault" != allocation-tree-int ] || _want_status=130
    if [ "$_case_status" -eq "$_want_status" ] && grep -qx allocated "$_tmp/marker" &&
      ! grep -qx finished "$_tmp/out" && _clean_scratch; then
      pass "$_owner records allocation ownership before $_fault exits"
    else
      fail "$_owner lost allocation ownership or signal status at $_fault ($_case_status)"
      cat "$_tmp/out" "$_tmp/err" >&2
      find "$_case_scratch" -print >&2
    fi
  done
done
_run healthy missing_module
if [ "$_case_status" -ne 0 ] && ! grep -qx finished "$_tmp/out" &&
  grep -q 'unknown bundle root' "$_tmp/err" && _clean_scratch; then
  pass "invalid graph cannot masquerade as a phase with no modules"
else
  fail "invalid graph was hidden or leaked probe scratch"
  cat "$_tmp/out" "$_tmp/err" >&2
fi
printf '\nphase-probe: %s pass, %s fail\n' "$_pass" "$_fail"
[ "$_fail" -eq 0 ]
