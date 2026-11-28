#!/bin/sh
# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Deterministic operation-boundary faults against the actual CLI functions.
# Utilities perform their real operation before delivering a signal, or fail a
# named operation. Every fault has an observed event marker; no timing polls,
# chmod-as-root assumptions, transcribed production functions, or live profiles.
# VALISE_TEST_CLI_SHELL selects the actual CLI and fault-driver interpreter;
# utility wrappers keep their ordinary /bin/sh interpreter.
set -eu
_total=0 _pass=0 _fail=0
pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; [ ! -f "$_tmp/result" ] || cat "$_tmp/result" >&2; }
_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise=$_repo/bin/valise
_cli_shell=${VALISE_TEST_CLI_SHELL:-/bin/sh}
[ -x "$_cli_shell" ] || { printf 'CLI test interpreter is not executable: %s\n' "$_cli_shell" >&2; exit 1; }
printf 'Transaction CLI interpreter: %s\n' "$_cli_shell"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-activation.XXXXXX")
_tmp=$(cd "$_tmp" && pwd -P)
cleanup() { chmod -R u+w "$_tmp" 2>/dev/null || :; rm -rf "$_tmp"; }
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
_home=$_tmp/home
mkdir -p "$_home" "$_tmp/work" "$_tmp/fault/bin" "$_tmp/fault/tools" "$_tmp/expected"
case $(uname -s) in
  Darwin) _mode=launchd; _bridge=$_home/Library/LaunchAgents/sh.valise.env.plist ;;
  *) _mode=systemd; _bridge=$_home/.config/environment.d/10-valise.conf ;;
esac
_v() {
  env -i HOME="$_home" PATH=/usr/bin:/bin TMPDIR="$_tmp/work" \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh "$_cli_shell" "$_valise" "$@"
}
for _label in A B C; do
  _project=$_tmp/project-$_label
  mkdir -p "$_project/module.d" "$_project/modules"
  _gui=$_mode
  [ "$_label" != B ] || _gui=off
  _names='common oldcmd'
  [ "$_label" = A ] || _names='common new1 new2'
  printf 'gui_env=%s\n' "$_gui" >"$_project/valise.conf"
  printf 'default\tsh\ttool\n' >"$_project/bundles.tsv"
  printf 'variant\tdescription\texcluded\ndefault\tAll\t\n' >"$_project/variants.tsv"
  printf 'name=tool\nside_effect=path-env\nshells=posix\nplatforms=any\nexports=%s\ncommands=%s\nload=modules/tool.sh\n' "$_names" "$_names" >"$_project/module.d/tool.meta"
  printf 'export TRANSACTION_WITNESS=%s\n' "$_label" >"$_project/modules/tool.sh"
  for _name in $_names; do printf '%s() { printf "%s:%s\\n"; }\n' "$_name" "$_label" "$_name" >>"$_project/modules/tool.sh"; done
  _v -C "$_project" build "$_tmp/release-$_label" >"$_tmp/build-$_label.log" 2>&1 || { cat "$_tmp/build-$_label.log" >&2; exit 1; }
done
_v -C "$_tmp/release-A" install >"$_tmp/setup.log" 2>&1
_a=$(basename "$(readlink "$_home/.config/valise/active")")
_v -C "$_tmp/release-B" install --no-integration >>"$_tmp/setup.log" 2>&1
_b=$(basename "$(readlink "$_home/.config/valise/active")")
_v -C "$_tmp/release-C" install --no-integration >>"$_tmp/setup.log" 2>&1
_c=$(basename "$(readlink "$_home/.config/valise/active")")
_v release use "$_a" >>"$_tmp/setup.log" 2>&1
cp -pR "$_home" "$_tmp/baseline"
_active=$_home/.config/valise/active
_state=$_home/.local/state/valise
_ledger=$_state/commands.tsv
_previous=$_state/previous
_bin=$_home/.local/bin

# Rename the actual resolver definition, so faults leave every unselected
# capability lookup exactly as production implements it.
awk '/^trusted_utility_path\(\) \{/ { copying=1; sub(/trusted_utility_path/, "original_trusted_utility_path") }
  copying { print } copying && /^}/ { exit }' "$_repo/lib/cli/common.sh" >"$_tmp/fault/original.sh"
cat >"$_tmp/fault/driver.sh" <<'DRIVER'
#!/bin/sh
set -eu
VALISE_VERSION=0.4.1
_valise_cli_path=$TEST_REPO/bin/valise
_valise_engine_bin=$TEST_REPO/bin
VALISE_CLI_DIR=$TEST_REPO/lib/cli
for part in usage common store fish-hook integration commands lifecycle devtools project; do . "$VALISE_CLI_DIR/$part.sh"; done
. "$TEST_FAULT/original.sh"
for utility in awk cat chmod ln mkdir mktemp mv readlink rm; do
  original_trusted_utility_path "$utility" >"$TEST_FAULT/tools/$utility"
done
trusted_utility_path() {
  case $1 in awk|cat|chmod|ln|mkdir|mktemp|mv|readlink|rm) printf '%s/bin/%s\n' "$TEST_FAULT" "$1" ;; *) original_trusted_utility_path "$@" ;; esac
}
FAULT_PID=$$
export FAULT_PID
case $TEST_CASE in
  repeat-install) VALISE_BIN_DIR=$HOME/alternate-bin ;;
  command-tab) VALISE_BIN_DIR="$HOME/tab$(printf '\t')" ;;
  command-newline) VALISE_BIN_DIR="$HOME/newline
" ;;
esac
case $1 in
  use) release_activate "$2" ;;
  rollback) cmd_release_rollback ;;
  install) cd "$2"; cmd_install ;;
  remove) remove_gui_env_bridge ;;
  lock) acquire_lock; release_lock ;;
  lock-reentrant)
    acquire_lock
    _first_lock=$(commands_file_identity "$VALISE_LOCK_DIR/pid")
    acquire_lock
    [ "$(commands_file_identity "$VALISE_LOCK_DIR/pid")" = "$_first_lock" ] || die "reentrant acquisition replaced the ownership record"
    printf 'reentrant-verified\n'
    ;;
  allocate)
    _allocation_root=$TMPDIR
    _allocation_template="$TMPDIR/literal '\$(printf injected) [x].XXXXXX"
    _allocation_kind=dir
    case $TEST_CASE in
      allocator-relative)
        cd "$TMPDIR"; mkdir relative
        _allocation_root=relative
        _allocation_template=relative/valise-install.XXXXXX ;;
      allocator-escape)
        mkdir "$TMPDIR/allowed" "$TMPDIR/outside"
        _allocation_root=$TMPDIR/allowed
        _allocation_template=$TMPDIR/outside/valise-install.XXXXXX ;;
      allocator-kind) _allocation_kind=unsupported ;;
    esac
    trusted_mktemp_assign _stage "$_allocation_kind" "$_allocation_template" "$_allocation_root"
    [ -d "$_stage" ] || die "allocator did not assign an existing directory"
    case $_stage in *'$(printf injected)'*) : ;; *) die "allocator evaluated pathname syntax" ;; esac
    ;;
  commands) release_commands "$2" ;;
esac
DRIVER
cat >"$_tmp/fault/wrapper" <<'WRAPPER'
#!/bin/sh
set -eu
utility=${0##*/}
IFS= read -r real <"$TEST_FAULT/tools/$utility"
last= first=
for arg do
  last=$arg
  case $arg in -*) ;; *) [ -n "$first" ] || first=$arg ;; esac
done
active=$HOME/.config/valise/active
ledger=$HOME/.local/state/valise/commands.tsv
previous=$HOME/.local/state/valise/previous
old=$HOME/.local/bin/oldcmd
new=$HOME/.local/bin/new1
emit() { printf '%s\n' "$1" >>"$TEST_FAULT/events"; }
once() { [ ! -e "$TEST_FAULT/$1" ] || return 1; : >"$TEST_FAULT/$1"; }
# Model a terminal signal without signaling the harness's process group. Walk
# this wrapper's own ancestry to the test driver, validate it completely, then
# signal from the driver down to this wrapper. This includes every intervening
# command-substitution shell that must preserve an allocated pathname.
signal_chain() {
  _asc_signal=$1 _asc_node=$$ _asc_pids= _asc_count=0
  while [ "$_asc_count" -lt 12 ]; do
    _asc_pids="$_asc_node $_asc_pids"
    [ "$_asc_node" != "$FAULT_PID" ] || break
    _asc_parent=$(ps -o ppid= -p "$_asc_node") || exit 71
    set -- $_asc_parent
    [ "$#" -eq 1 ] || exit 71
    case $1 in ''|*[!0-9]*) exit 71 ;; esac
    [ "$1" -gt 1 ] || exit 71
    _asc_node=$1
    _asc_count=$((_asc_count + 1))
  done
  [ "$_asc_node" = "$FAULT_PID" ] || exit 71
  for _asc_node in $_asc_pids; do kill -"$_asc_signal" "$_asc_node" 2>/dev/null || :; done
}
case $utility:$TEST_CASE in
  mktemp:allocator-*) emit allocator-invoked ;;
  awk:commands-read)
    case $last in */command-config/valise-release.conf) emit command-config-read-failed; exit 2 ;; esac ;;
  readlink:unreadable-link)
    if [ "$last" = "$active" ]; then emit readlink-failed; exit 1; fi ;;
  cat:ledger-read)
    if [ "$last" = "$ledger" ]; then emit ledger-read-failed; exit 1; fi ;;
  rm:exit-then-signal|rm:exit-then-child-signal|rm:failed-link-restore|rm:failed-bridge-restore)
    if [ "$last" = "$old" ] && once forward-failed; then emit forward-failed; exit 1; fi ;;
  cat:exit-then-child-signal|cat:two-signals-child)
    case $last in */.transaction.*/previous)
      if once second-signal; then
        emit restore-child-signal
        signal=TERM
        [ "$TEST_CASE" != two-signals-child ] || signal=INT
        signal_chain "$signal"
      fi ;;
    esac ;;
  rm:signal-lock-cleanup-child)
    if [ "$last" = "$HOME/.local/state/valise/lock/pid" ] && once second-signal; then
      emit lock-cleanup-child-signal
      signal_chain TERM
    fi ;;
  mv:two-signal-remove-child)
    case $first in */.valise-remove.*)
      if once second-signal; then
        emit bridge-restore-child-signal
        signal_chain INT
      fi ;;
    esac ;;
  ln:failed-link-restore)
    if [ "$last" = "$active" ] && [ "$first" = "$HOME/.local/share/valise/releases/$TEST_A" ] && [ -f "$TEST_FAULT/forward-failed" ]; then
      emit link-restore-failed; exit 1
    fi ;;
  mv:remove-second-failed)
    case $last in */.valise-remove.*)
      case $first in */LaunchAgents/*) emit second-remove-failed; exit 1 ;; esac ;;
    esac ;;
  chmod:stage-cleanup-failed)
    case $last in */.valise-gui.*) emit stage-protect-failed; exit 1 ;; esac ;;
  rm:stage-cleanup-failed)
    case $last in */.valise-gui.*) emit stage-cleanup-failed; exit 1 ;; esac ;;
  rm:bridge-cleanup-failed)
    case $last in */LaunchAgents/.valise-remove.*) emit bridge-cleanup-failed; exit 1 ;; esac ;;
  ln:failed-stub-restore)
    case $first in */.valise-restore.*)
      if [ "$last" = "$old" ]; then emit stub-restore-failed; exit 1; fi ;;
    esac ;;
  mv:failed-bridge-restore)
    case $first in */.valise-restore.*)
      if [ "$last" = "$TEST_BRIDGE" ]; then emit bridge-restore-failed; exit 1; fi ;;
    esac ;;
  mv:partial-stubs|mv:missing-manifest|mv:lost-ledger|mv:failed-previous-restore|mv:failed-stub-restore|mv:edited-old|mv:edited-new|mv:collision)
    if [ "$TEST_CASE" = failed-previous-restore ]; then
      case $first in */.valise-restore.*)
        if [ "$last" = "$previous" ]; then emit previous-restore-failed; exit 1; fi ;;
      esac
    fi
    if [ "$last" = "$ledger" ] && [ -f "$TEST_FAULT/published" ] && once forward-failed; then
      if [ "$TEST_CASE" = lost-ledger ]; then
        IFS= read -r rm_real <"$TEST_FAULT/tools/rm"
        "$rm_real" "$ledger"
        emit ledger-removed
      fi
      emit ledger-publish-failed
      exit 1
    fi ;;
  mv:repeat-install)
    if [ "$last" = "$ledger" ] && [ -f "$HOME/alternate-bin/common" ] && once forward-failed; then emit ledger-publish-failed; exit 1; fi ;;
  rm:cleanup-failed)
    case $last in */.transaction.*) emit recovery-cleanup-failed; exit 1 ;; esac ;;
  ln:collision)
    if [ "$last" = "$new" ]; then
      IFS= read -r cat_real <"$TEST_FAULT/tools/cat"
      "$cat_real" "$first" >"$last"
      emit foreign-collision
      : >"$TEST_FAULT/published"
    fi ;;
esac
rc=0
"$real" "$@" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
case $utility:$TEST_CASE in
  mktemp:signal-staging)
    case $last in */.valise-gui.*) emit bridge-staged; kill -TERM "$FAULT_PID" ;; esac ;;
  mktemp:signal-manifest)
    case $last in */valise-manifest.*) if once first-signal; then emit manifest-staged; kill -TERM "$FAULT_PID"; fi ;; esac ;;
  mktemp:signal-manifest-child)
    case $last in */valise-manifest.*)
      if once first-signal; then emit manifest-child-signal; signal_chain TERM; fi ;;
    esac ;;
  mktemp:signal-staging-child)
    case $last in */.valise-gui.*)
      if once first-signal; then emit staging-child-signal; signal_chain INT; fi ;;
    esac ;;
  mv:signal-remove|mv:two-signal-remove|mv:two-signal-remove-child)
    case $last in */.valise-remove.*)
      if once first-signal; then emit bridge-set-aside; kill -TERM "$FAULT_PID"; fi ;;
    esac
    case $first in */.valise-remove.*)
      if [ "$TEST_CASE" = two-signal-remove ] && once second-signal; then emit bridge-restore-signal; kill -INT "$FAULT_PID"; fi ;;
    esac ;;
  mkdir:signal-lock)
    case $last in */valise/lock) emit lock-created; kill -TERM "$FAULT_PID" ;; esac ;;
  mkdir:signal-lock-child-term|mkdir:signal-lock-child-int)
    case $last in */valise/lock)
      emit lock-created-child-signal
      signal=TERM
      [ "$TEST_CASE" != signal-lock-child-int ] || signal=INT
      signal_chain "$signal" ;;
    esac ;;
  ln:signal-active|ln:two-signals|ln:two-signals-child)
    if [ "$last" = "$active" ]; then
      if [ "$first" = "$HOME/.local/share/valise/releases/$TEST_B" ] && once first-signal; then
        emit first-signal; kill -TERM "$FAULT_PID"
      elif [ "$TEST_CASE" = two-signals ] && [ "$first" = "$HOME/.local/share/valise/releases/$TEST_A" ] && [ -e "$TEST_FAULT/first-signal" ]; then
        emit second-signal; kill -INT "$FAULT_PID"
      fi
    fi ;;
  mv:signal-bridge|mv:install-signal)
    case $first in */.valise-gui.*)
      if [ "$last" = "$TEST_BRIDGE" ] && once first-signal; then emit bridge-published; kill -TERM "$FAULT_PID"; fi ;;
    esac ;;
  mv:exit-then-signal)
    case $first in */.valise-restore.*)
      if [ "$last" = "$previous" ] && once second-signal; then emit restore-signal; kill -TERM "$FAULT_PID"; fi ;;
    esac ;;
  ln:partial-stubs|ln:missing-manifest|ln:lost-ledger|ln:failed-previous-restore|ln:failed-stub-restore|ln:edited-old|ln:edited-new)
    if [ "$last" = "$new" ]; then
      : >"$TEST_FAULT/published"
      emit stub-published
      if [ "$TEST_CASE" = missing-manifest ]; then
        IFS= read -r chmod_real <"$TEST_FAULT/tools/chmod"
        IFS= read -r rm_real <"$TEST_FAULT/tools/rm"
        "$chmod_real" u+w "$HOME/.local/share/valise/releases/$TEST_A"
        "$rm_real" "$HOME/.local/share/valise/releases/$TEST_A/valise-release.conf"
        emit outgoing-manifest-removed
      elif [ "$TEST_CASE" = edited-new ]; then
        printf '# user edit\n' >>"$last"
        emit new-stub-edited
      fi
    fi ;;
  rm:edited-old)
    if [ "$last" = "$old" ]; then printf 'user replacement\n' >"$old"; emit old-stub-edited; fi ;;
esac
exit 0
WRAPPER
chmod 0755 "$_tmp/fault/driver.sh" "$_tmp/fault/wrapper"
for _tool in awk cat chmod ln mkdir mktemp mv readlink rm; do cp "$_tmp/fault/wrapper" "$_tmp/fault/bin/$_tool"; done

reset_case() {
  chmod -R u+w "$_home" 2>/dev/null || :
  rm -rf "$_home"
  cp -pR "$_tmp/baseline" "$_home"
  rm -f "$_tmp/fault/events" "$_tmp/fault/forward-failed" "$_tmp/fault/published" "$_tmp/fault/first-signal" "$_tmp/fault/second-signal"
}
save_expected() {
  rm -f "$_tmp/expected/"*
  _expected_had=0
  if [ -L "$_active" ]; then _expected_had=1; readlink "$_active" >"$_tmp/expected/active"; fi
  cp -p "$_previous" "$_tmp/expected/previous"
  cp -p "$_ledger" "$_tmp/expected/commands.tsv"
  _expected_bridge=0
  if [ -f "$_bridge" ]; then _expected_bridge=1; cp -p "$_bridge" "$_tmp/expected/bridge"; fi
  cp -p "$_bin/common" "$_tmp/expected/common"
  cp -p "$_bin/oldcmd" "$_tmp/expected/oldcmd"
}
run_fault() {
  _case=$1; shift
  _rc=0
  env -i HOME="$_home" PATH=/usr/bin:/bin TMPDIR="$_tmp/work" \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    TEST_REPO="$_repo" TEST_FAULT="$_tmp/fault" TEST_CASE="$_case" \
    TEST_A="$_a" TEST_B="$_b" TEST_C="$_c" TEST_BRIDGE="$_bridge" \
    "$_cli_shell" "$_tmp/fault/driver.sh" "$@" >"$_tmp/result" 2>&1 || _rc=$?
}
event() { grep -Fx "$1" "$_tmp/fault/events" >/dev/null 2>&1; }
no_temps() {
  _left=$(find "$_home" "$_tmp/work" \( -name 'lock' -o -name '.transaction.*' -o -name '.commands.*' -o -name '.previous.*' -o -name '.valise-stub.*' -o -name '.valise-restore.*' -o -name '.valise-gui.*' -o -name '.valise-remove.*' -o -name 'valise-manifest*' -o -name 'valise-install.*' \) -print) || return 1
  [ -z "$_left" ]
}
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
identity() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"; }
restored() {
  if [ "$_expected_had" -eq 1 ]; then
    readlink "$_active" >"$_tmp/current-active" || return 1
    cmp -s "$_tmp/expected/active" "$_tmp/current-active" || return 1
  else
    [ ! -e "$_active" ] && [ ! -L "$_active" ] || return 1
  fi
  if [ "$_expected_bridge" -eq 1 ]; then
    cmp -s "$_tmp/expected/bridge" "$_bridge" && [ "$(mode "$_tmp/expected/bridge")" = "$(mode "$_bridge")" ] || return 1
  else
    [ ! -e "$_bridge" ] && [ ! -L "$_bridge" ] || return 1
  fi
  for _file in previous commands.tsv common oldcmd; do
    case $_file in previous) _path=$_previous ;; commands.tsv) _path=$_ledger ;; *) _path=$_bin/$_file ;; esac
    [ "$(mode "$_tmp/expected/$_file")" = "$(mode "$_path")" ] || return 1
  done
  cmp -s "$_tmp/expected/previous" "$_previous" &&
    cmp -s "$_tmp/expected/commands.tsv" "$_ledger" &&
    cmp -s "$_tmp/expected/common" "$_bin/common" &&
    cmp -s "$_tmp/expected/oldcmd" "$_bin/oldcmd" &&
    [ ! -e "$_bin/new1" ] && [ ! -e "$_bin/new2" ] && no_temps
}
recovery_present() {
  _recovery=$(find "$_state" -name '.transaction.*' -type d -print) || return 1
  [ -n "$_recovery" ] && [ -f "$_recovery/active-target" ] && [ -f "$_recovery/commands.tsv" ] &&
    [ -f "$_recovery/bridge-1" ] && grep -F "activation recovery files preserved at $_recovery" "$_tmp/result" >/dev/null &&
    [ ! -e "$_state/lock" ]
}

printf '=== activation transactions ===\n'
# Transparent wrappers prove the harness itself preserves normal use/off,
# bridge publication, command publication, and rollback's previous record.
reset_case
run_fault control use "$_b"
if [ "$_rc" -eq 0 ] && [ "$(basename "$(readlink "$_active")")" = "$_b" ] &&
  [ "$(cat "$_previous")" = "$_a" ] && [ ! -e "$_bridge" ] && [ ! -e "$_bin/oldcmd" ] &&
  [ -x "$_bin/new1" ] && [ -x "$_bin/new2" ] && no_temps; then
  pass 'transparent control commits bridge removal and the incoming command set'
else fail 'transparent control commits bridge removal and the incoming command set'; fi
run_fault control rollback
if [ "$_rc" -eq 0 ] && [ "$(basename "$(readlink "$_active")")" = "$_a" ] &&
  [ "$(cat "$_previous")" = "$_b" ] && [ -f "$_bridge" ] && [ -x "$_bin/oldcmd" ] && no_temps; then
  pass 'transparent rollback restores the bridge and records the outgoing release'
else fail 'transparent rollback restores the bridge and records the outgoing release'; fi

for _fault in signal-active signal-bridge signal-staging signal-manifest signal-staging-child signal-manifest-child two-signals two-signals-child exit-then-signal exit-then-child-signal partial-stubs missing-manifest lost-ledger; do
  reset_case; save_expected
  _target=$_b _want=1
  case $_fault in signal-bridge|signal-staging|signal-staging-child|exit-then-signal|exit-then-child-signal) _target=$_c ;; esac
  case $_fault in signal-active|signal-bridge|signal-staging|signal-manifest|signal-manifest-child|exit-then-signal|exit-then-child-signal) _want=143 ;; two-signals|two-signals-child|signal-staging-child) _want=130 ;; esac
  run_fault "$_fault" use "$_target"
  _observed=0
  case $_fault in
    signal-active) event first-signal && _observed=1 ;;
    signal-bridge) event bridge-published && _observed=1 ;;
    signal-staging) event bridge-staged && _observed=1 ;;
    signal-manifest) event manifest-staged && _observed=1 ;;
    signal-staging-child) event staging-child-signal && _observed=1 ;;
    signal-manifest-child) event manifest-child-signal && _observed=1 ;;
    two-signals) event first-signal && event second-signal && _observed=1 ;;
    two-signals-child) event first-signal && event restore-child-signal && _observed=1 ;;
    exit-then-signal) event forward-failed && event restore-signal && _observed=1 ;;
    exit-then-child-signal) event forward-failed && event restore-child-signal && _observed=1 ;;
    partial-stubs) event stub-published && event ledger-publish-failed && _observed=1 ;;
    missing-manifest) event outgoing-manifest-removed && event ledger-publish-failed && _observed=1 ;;
    lost-ledger) event ledger-removed && event ledger-publish-failed && _observed=1 ;;
  esac
  if [ "$_rc" -eq "$_want" ] && [ "$_observed" -eq 1 ] && restored; then
    pass "$_fault restores active, previous, bridge, exact stubs and ledger; cleans lock and staging (exit $_want)"
  else fail "$_fault restores every state component and cleanup (exit $_rc, expected $_want, event $_observed)"; fi
done

reset_case; save_expected
run_fault signal-lock lock
if [ "$_rc" -eq 143 ] && event lock-created && restored; then pass 'TERM immediately after lock mkdir cleans the newly owned lock';
else fail 'TERM immediately after lock mkdir cleans the newly owned lock'; fi

# A real terminal signal also reaches the child utility. It must not turn a
# successful mkdir into an unowned lock or interrupt lock cleanup midway.
for _lock_signal in signal-lock-child-term signal-lock-child-int signal-lock-cleanup-child; do
  reset_case; save_expected
  run_fault "$_lock_signal" lock
  _want=143
  [ "$_lock_signal" != signal-lock-child-int ] || _want=130
  _event=lock-created-child-signal
  [ "$_lock_signal" != signal-lock-cleanup-child ] || _event=lock-cleanup-child-signal
  if [ "$_rc" -eq "$_want" ] && event "$_event" && restored; then
    pass "$_lock_signal preserves ownership bookkeeping and finishes lock cleanup (exit $_want)"
  else fail "$_lock_signal preserves ownership bookkeeping and finishes lock cleanup (exit $_rc)"; fi
done

# A stale owner record cannot authorize an atomic compare-and-delete. Two
# contenders must both leave a pre-existing lock exactly as they found it,
# whether its recorded owner is alive or has already exited.
for _owner_state in live stale; do
  reset_case; save_expected
  _owner_pid=$$
  if [ "$_owner_state" = stale ]; then
    ( : ) &
    _owner_pid=$!
    wait "$_owner_pid"
    if kill -0 "$_owner_pid" 2>/dev/null; then fail 'stale-lock fixture owner is still alive'; continue; fi
  fi
  _existing_lock=$_state/lock
  mkdir -m 0700 "$_existing_lock"
  printf '%s\n' "$_owner_pid" >"$_existing_lock/pid"
  chmod 0640 "$_existing_lock/pid"
  cp -p "$_existing_lock/pid" "$_tmp/expected/lock-pid"
  _lock_before=$(identity "$_existing_lock")
  _pid_before=$(identity "$_existing_lock/pid")
  _v release use "$_b" >"$_tmp/contender-one" 2>&1 &
  _contender_one=$!
  _v release use "$_c" >"$_tmp/contender-two" 2>&1 &
  _contender_two=$!
  _one_status=0; wait "$_contender_one" || _one_status=$?
  _two_status=0; wait "$_contender_two" || _two_status=$?
  cat "$_tmp/contender-one" "$_tmp/contender-two" >"$_tmp/result"
  _lock_preserved=0
  if [ -d "$_existing_lock" ] && [ ! -L "$_existing_lock" ] &&
    [ -f "$_existing_lock/pid" ] && [ ! -L "$_existing_lock/pid" ] &&
    [ "$(identity "$_existing_lock")" = "$_lock_before" ] &&
    [ "$(identity "$_existing_lock/pid")" = "$_pid_before" ] &&
    [ "$(mode "$_existing_lock")" = 700 ] && [ "$(mode "$_existing_lock/pid")" = 640 ] &&
    cmp -s "$_existing_lock/pid" "$_tmp/expected/lock-pid" &&
    grep -F 'lock already exists (recorded pid ' "$_tmp/contender-one" >/dev/null &&
    grep -F 'lock already exists (recorded pid ' "$_tmp/contender-two" >/dev/null; then _lock_preserved=1; fi
  rm -f "$_existing_lock/pid"
  rmdir "$_existing_lock"
  if [ "$_one_status" -ne 0 ] && [ "$_two_status" -ne 0 ] && [ "$_lock_preserved" -eq 1 ] && restored; then
    pass "two contenders preserve an existing $_owner_state lock's bytes, modes, type and inode"
  else fail "two contenders preserve an existing $_owner_state lock's bytes, modes, type and inode"; fi
done
reset_case; save_expected
run_fault control lock-reentrant
if [ "$_rc" -eq 0 ] && grep -Fx reentrant-verified "$_tmp/result" >/dev/null && restored; then
  pass 'the exact current lock owner can acquire reentrantly without replacing its record'
else fail 'the exact current lock owner can acquire reentrantly without replacing its record'; fi

# Preflight failures keep the rejected object itself, including symlink targets.
for _bad in symlink-ledger directory-ledger fifo-ledger malformed-ledger symlink-previous invalid-previous unreadable-link ledger-read; do
  reset_case; save_expected
  case $_bad in
    symlink-ledger) mv "$_ledger" "$_state/saved-ledger"; ln -s saved-ledger "$_ledger" ;;
    directory-ledger) rm "$_ledger"; mkdir "$_ledger" ;;
    fifo-ledger) rm "$_ledger"; mkfifo "$_ledger" ;;
    malformed-ledger) printf 'invalid ledger\n' >"$_ledger" ;;
    symlink-previous) mv "$_previous" "$_state/saved-previous"; ln -s saved-previous "$_previous" ;;
    invalid-previous) printf '%s\nextra\n' "$_a" >"$_previous" ;;
  esac
  _doctor_failed=1
  case $_bad in *-ledger)
    _doctor_rc=0
    _v doctor >"$_tmp/doctor-bad-ledger" 2>&1 || _doctor_rc=$?
    if [ "$_doctor_rc" -eq 0 ] || ! grep -F 'FAIL: invalid command ledger:' "$_tmp/doctor-bad-ledger" >/dev/null ||
      grep -F 'installed without integration' "$_tmp/doctor-bad-ledger" >/dev/null; then _doctor_failed=0; fi ;;
  esac
  run_fault "$_bad" use "$_b"
  _preserved=$_doctor_failed
  case $_bad in
    symlink-ledger) [ -L "$_ledger" ] && cmp -s "$_state/saved-ledger" "$_tmp/expected/commands.tsv" || _preserved=0; rm "$_ledger"; mv "$_state/saved-ledger" "$_ledger" ;;
    directory-ledger) [ -d "$_ledger" ] || _preserved=0; rmdir "$_ledger"; cp -p "$_tmp/expected/commands.tsv" "$_ledger" ;;
    fifo-ledger) [ -p "$_ledger" ] || _preserved=0; rm "$_ledger"; cp -p "$_tmp/expected/commands.tsv" "$_ledger" ;;
    malformed-ledger) [ "$(cat "$_ledger")" = 'invalid ledger' ] || _preserved=0; cp -p "$_tmp/expected/commands.tsv" "$_ledger" ;;
    symlink-previous) [ -L "$_previous" ] && cmp -s "$_state/saved-previous" "$_tmp/expected/previous" || _preserved=0; rm "$_previous"; mv "$_state/saved-previous" "$_previous" ;;
    invalid-previous) [ "$(wc -l <"$_previous" | tr -d ' ')" -eq 2 ] || _preserved=0; cp -p "$_tmp/expected/previous" "$_previous" ;;
    unreadable-link) event readlink-failed || _preserved=0 ;;
    ledger-read) event ledger-read-failed || _preserved=0 ;;
  esac
  if [ "$_rc" -ne 0 ] && [ "$_preserved" -eq 1 ] && restored; then pass "$_bad is rejected without changing live activation state";
  else fail "$_bad is rejected without changing live activation state"; fi
done

# Absent, dangling and relative pointers are three distinct snapshots.
for _pointer in absent dangling relative newline; do
  reset_case
  case $_pointer in
    absent) rm "$_active" ;;
    dangling) ln -sfn '../../missing-release' "$_active" ;;
    relative) ln -sfn "../../.local/share/valise/releases/$_a" "$_active" ;;
    newline) ln -sfn '../../missing-release

' "$_active" ;;
  esac
  save_expected
  run_fault partial-stubs use "$_b"
  if [ "$_rc" -eq 1 ] && event stub-published && event ledger-publish-failed && restored; then
    pass "failed switch restores the exact $_pointer active pointer and preexisting integration"
  else fail "failed switch restores the exact $_pointer active pointer and preexisting integration"; fi
done
reset_case
ln -sfn "../../.local/share/valise/releases/$_a" "$_active"
run_fault control use "$_b"
if [ "$_rc" -eq 0 ] && [ "$(cat "$_previous")" = "$_a" ]; then pass 'a successful relative-pointer switch records the outgoing release';
else fail 'a successful relative-pointer switch records the outgoing release'; fi

for _edit in edited-old edited-new collision; do
  reset_case; save_expected
  run_fault "$_edit" use "$_b"
  _good=0
  case $_edit in
    edited-old) event old-stub-edited && [ "$(cat "$_bin/oldcmd")" = 'user replacement' ] && ! grep -F "$_bin/oldcmd" "$_ledger" >/dev/null && _good=1 ;;
    edited-new) event new-stub-edited && grep -Fx '# user edit' "$_bin/new1" >/dev/null && ! grep -F "$_bin/new1" "$_ledger" >/dev/null && _good=1 ;;
    collision) event foreign-collision && [ -f "$_bin/new1" ] && ! grep -F "$_bin/new1" "$_ledger" >/dev/null && _good=1 ;;
  esac
  if [ "$_rc" -eq 1 ] && [ "$_good" -eq 1 ] && event ledger-publish-failed &&
    [ "$(basename "$(readlink "$_active")")" = "$_a" ] && cmp -s "$_tmp/expected/bridge" "$_bridge" && no_temps; then
    pass "rollback preserves $_edit without claiming the user's file"
  else fail "rollback preserves $_edit without claiming the user's file"; fi
done

reset_case; save_expected
run_fault failed-link-restore use "$_c"
if [ "$_rc" -eq 1 ] && event link-restore-failed && [ "$(basename "$(readlink "$_active")")" = "$_c" ] &&
  [ "$(cat "$_previous")" = "$_a" ] && ! cmp -s "$_tmp/expected/bridge" "$_bridge" &&
  grep -F 'left in their current state' "$_tmp/result" >/dev/null && recovery_present; then
  pass 'a failed link restore preserves incoming bridge/current state and names complete recovery copies'
else fail 'a failed link restore preserves incoming bridge/current state and names complete recovery copies'; fi
reset_case; save_expected
run_fault failed-bridge-restore use "$_c"
if [ "$_rc" -eq 1 ] && event bridge-restore-failed && [ "$(basename "$(readlink "$_active")")" = "$_a" ] &&
  cmp -s "$_tmp/expected/previous" "$_previous" && cmp -s "$_tmp/expected/commands.tsv" "$_ledger" &&
  grep -F 'cannot restore GUI bridge' "$_tmp/result" >/dev/null && recovery_present; then
  pass 'a failed bridge restore retains its snapshot, completes other restores, and releases the lock'
else fail 'a failed bridge restore retains its snapshot, completes other restores, and releases the lock'; fi
reset_case
run_fault cleanup-failed use "$_b"
if [ "$_rc" -eq 1 ] && event recovery-cleanup-failed && [ "$(basename "$(readlink "$_active")")" = "$_b" ] &&
  [ "$(cat "$_previous")" = "$_a" ] && [ ! -e "$_bridge" ] && [ -x "$_bin/new1" ] && [ ! -e "$_bin/oldcmd" ] && recovery_present; then
  pass 'post-commit cleanup failure reports nonzero and preserves the committed release'
else fail 'post-commit cleanup failure reports nonzero and preserves the committed release'; fi

reset_case; save_expected
run_fault install-signal install "$_tmp/release-C"
if [ "$_rc" -eq 143 ] && event bridge-published && restored; then pass 'install shares full rollback and signal cleanup after bridge publication';
else fail 'install shares full rollback and signal cleanup after bridge publication'; fi
reset_case; save_expected
run_fault repeat-install install "$_tmp/release-A"
if [ "$_rc" -eq 1 ] && event ledger-publish-failed && restored && [ ! -e "$_home/alternate-bin/common" ]; then
  pass 'a repeat install rolls command changes back even when the active release never moves'
else fail 'a repeat install rolls command changes back even when the active release never moves'; fi

reset_case
rm "$_bridge"
save_expected
run_fault signal-bridge use "$_c"
if [ "$_rc" -eq 143 ] && event bridge-published && restored; then
  pass 'a signal after publishing the first bridge restores its original absence'
else fail 'a signal after publishing the first bridge restores its original absence'; fi
reset_case
chmod 0440 "$_previous"
chmod 0400 "$_ledger" "$_bridge"
chmod 0700 "$_bin/oldcmd"
save_expected
run_fault partial-stubs use "$_c"
if [ "$_rc" -eq 1 ] && event ledger-publish-failed && restored; then
  pass 'rollback restores exact ownership-file and bridge permission modes'
else fail 'rollback restores exact ownership-file and bridge permission modes'; fi
for _restore in failed-previous-restore failed-stub-restore; do
  reset_case; save_expected
  run_fault "$_restore" use "$_c"
  _event=previous-restore-failed
  [ "$_restore" != failed-stub-restore ] || _event=stub-restore-failed
  if [ "$_rc" -eq 1 ] && event "$_event" && event ledger-publish-failed &&
    [ "$(basename "$(readlink "$_active")")" = "$_a" ] &&
    cmp -s "$_tmp/expected/bridge" "$_bridge" && recovery_present; then
    pass "$_restore preserves recovery copies and still restores the outgoing bridge"
  else fail "$_restore preserves recovery copies and still restores the outgoing bridge"; fi
done

# Staging and snapshots must identify the same bridge through a parent alias.
reset_case
mv "$_home/.config" "$_home/config-real"
ln -s config-real "$_home/.config"
save_expected
run_fault partial-stubs use "$_c"
if [ "$_rc" -eq 1 ] && event ledger-publish-failed && restored; then
  pass 'rollback restores the predecessor bridge through a symlinked configuration parent'
else fail 'rollback restores the predecessor bridge through a symlinked configuration parent'; fi
for _delimiter in command-tab command-newline bridge-tab bridge-newline; do
  reset_case
  case $_delimiter in bridge-*)
    _bridge_parent=$(dirname "$_bridge")
    case $_delimiter in bridge-tab) _odd_parent="$_home/bridge$(printf '\t')" ;; bridge-newline) _odd_parent="$_home/bridge
" ;; esac
    mv "$_bridge_parent" "$_odd_parent"
    ln -s "$_odd_parent" "$_bridge_parent"
    ;;
  esac
  save_expected
  run_fault "$_delimiter" use "$_c"
  if [ "$_rc" -eq 1 ] && grep -F 'cannot contain TAB or newline in activation records' "$_tmp/result" >/dev/null && restored; then
    pass "$_delimiter is rejected before changing the active pointer or integration"
  else fail "$_delimiter is rejected before changing the active pointer or integration"; fi
done

# The rollback entry point has its own pre-read/lock path, but shares recovery.
reset_case; save_expected
run_fault partial-stubs rollback
if [ "$_rc" -eq 1 ] && event stub-published && event ledger-publish-failed && restored; then
  pass 'release rollback restores its own outgoing state after partial reconciliation'
else fail 'release rollback restores its own outgoing state after partial reconciliation'; fi

# A first install has no previous active pointer, ledger, or bridge to restore.
# A subsequent install must still succeed and publish its complete command set.
reset_case
chmod -R u+w "$_home"
rm -rf "$_home"
mkdir "$_home"
run_fault partial-stubs install "$_tmp/release-B"
if [ "$_rc" -eq 1 ] && event stub-published && event ledger-publish-failed &&
  [ ! -e "$_active" ] && [ ! -L "$_active" ] && [ ! -e "$_ledger" ] &&
  [ ! -e "$_bin/common" ] && [ ! -e "$_bin/new1" ] && [ ! -e "$_bin/new2" ] && no_temps; then
  pass 'failed first install removes only its published stubs and restores absent integration state'
else fail 'failed first install removes only its published stubs and restores absent integration state'; fi
_v -C "$_tmp/release-B" install >"$_tmp/result" 2>&1
if [ -f "$_ledger" ] && [ ! -L "$_ledger" ] && [ -x "$_bin/common" ] && [ -x "$_bin/new1" ] && [ -x "$_bin/new2" ] && no_temps; then
  pass 'install succeeds with full command integration after a failed first install'
else fail 'install succeeds with full command integration after a failed first install'; fi

# Both bridge formats can coexist in a shared home. Exercise the actual
# two-phase remover without a transaction snapshot hiding an aside bug.
for _removal in signal-remove two-signal-remove two-signal-remove-child remove-second-failed bridge-cleanup-failed; do
  reset_case; save_expected
  _systemd=$_home/.config/environment.d/10-valise.conf
  _launchd=$_home/Library/LaunchAgents/sh.valise.env.plist
  mkdir -p "$(dirname "$_systemd")" "$(dirname "$_launchd")"
  if [ ! -e "$_systemd" ]; then printf '%s\n' '# written by valise (gui_env=systemd); do not edit' 'WITNESS=systemd' >"$_systemd"; fi
  if [ ! -e "$_launchd" ]; then printf '%s\n' '<!-- written by valise (gui_env=launchd); do not edit -->' '<plist version="1.0"><dict/></plist>' >"$_launchd"; fi
  cp -p "$_systemd" "$_tmp/expected/systemd"
  cp -p "$_launchd" "$_tmp/expected/launchd"
  _want=1 _event=second-remove-failed
  case $_removal in
    signal-remove) _want=143 _event=bridge-set-aside ;;
    two-signal-remove) _want=130 _event=bridge-restore-signal ;;
    two-signal-remove-child) _want=130 _event=bridge-restore-child-signal ;;
    bridge-cleanup-failed) _event=bridge-cleanup-failed ;;
  esac
  if [ "$_removal" = bridge-cleanup-failed ]; then run_fault "$_removal" use "$_b";
  else run_fault "$_removal" remove; fi
  if [ "$_removal" = bridge-cleanup-failed ]; then
    _aside=$(find "$(dirname "$_launchd")" -name '.valise-remove.*' -type f -print)
    if [ "$_rc" -eq 1 ] && event "$_event" && [ "$(basename "$(readlink "$_active")")" = "$_b" ] &&
      [ ! -e "$_systemd" ] && [ ! -e "$_launchd" ] && [ -n "$_aside" ] &&
      cmp -s "$_aside" "$_tmp/expected/launchd" && grep -F "GUI bridge cleanup file preserved at $_aside" "$_tmp/result" >/dev/null &&
      [ ! -e "$_state/lock" ] && [ -x "$_bin/new1" ]; then
      pass 'bridge deletion cleanup failure preserves committed activation and names the leftover copy'
    else fail 'bridge deletion cleanup failure preserves committed activation and names the leftover copy'; fi
  elif [ "$_rc" -eq "$_want" ] && event "$_event" && cmp -s "$_systemd" "$_tmp/expected/systemd" &&
    cmp -s "$_launchd" "$_tmp/expected/launchd" && no_temps; then
    pass "$_removal restores both bridge files and cleans every aside (exit $_want)"
  else fail "$_removal restores both bridge files and cleans every aside (exit $_rc, expected $_want)"; fi
done

# Unterminated final records are valid data, not missing ownership rows.
for _action in keep remove uninstall; do
  reset_case
  _rows=$(cat "$_ledger")
  printf '%s' "$_rows" >"$_ledger"
  _rc=0
  case $_action in
    keep) _v release use "$_a" >"$_tmp/result" 2>&1 || _rc=$? ;;
    remove) _v release use "$_b" >"$_tmp/result" 2>&1 || _rc=$? ;;
    uninstall) _v uninstall --keep-releases >"$_tmp/result" 2>&1 || _rc=$? ;;
  esac
  _good=0
  case $_action in
    keep) [ -x "$_bin/oldcmd" ] && grep -F "$_bin/oldcmd" "$_ledger" >/dev/null && _good=1 ;;
    remove|uninstall) [ ! -e "$_bin/oldcmd" ] && [ ! -L "$_bin/oldcmd" ] && _good=1 ;;
  esac
  if [ "$_rc" -eq 0 ] && [ "$_good" -eq 1 ] && no_temps; then
    pass "$_action consumes an ownership ledger's final record without a newline"
  else fail "$_action consumes an ownership ledger's final record without a newline"; fi
done
reset_case; save_expected
run_fault stage-cleanup-failed use "$_c"
_stage_left=$(find "$(dirname "$_bridge")" -name '.valise-gui.*' -type f -print)
if [ "$_rc" -eq 1 ] && event stage-protect-failed && event stage-cleanup-failed &&
  [ -n "$_stage_left" ] && grep -F "GUI environment staging file preserved at $_stage_left" "$_tmp/result" >/dev/null &&
  [ ! -e "$_state/lock" ] && [ "$(basename "$(readlink "$_active")")" = "$_a" ] &&
  cmp -s "$_tmp/expected/bridge" "$_bridge"; then
  pass 'failed pre-activation staging cleanup names the retained private file and releases the lock'
else fail 'failed pre-activation staging cleanup names the retained private file and releases the lock'; fi

# `commands` is optional in older format=2 releases. Distinguish its absence
# from an actual read failure, and validate the complete configuration as data.
reset_case
mkdir -p "$_tmp/command-config"
for _config in absent-key empty-key malformed duplicate commands-read; do
  printf 'format=2\n' >"$_tmp/command-config/valise-release.conf"
  case $_config in
    empty-key) printf 'commands=\n' >>"$_tmp/command-config/valise-release.conf" ;;
    malformed) printf 'commands missing-equals\n' >>"$_tmp/command-config/valise-release.conf" ;;
    duplicate) printf 'commands=one\ncommands=two\n' >>"$_tmp/command-config/valise-release.conf" ;;
  esac
  run_fault "$_config" commands "$_tmp/command-config"
  case $_config in
    absent-key|empty-key)
      if [ "$_rc" -eq 0 ] && [ -z "$(cat "$_tmp/result")" ]; then
        pass "a valid release with $_config publishes zero commands"
      else fail "a valid release with $_config publishes zero commands"; fi ;;
    *)
      _observed=1
      [ "$_config" != commands-read ] || { event command-config-read-failed || _observed=0; }
      if [ "$_rc" -ne 0 ] && [ "$_observed" -eq 1 ] && grep -F 'cannot read commands from the release configuration' "$_tmp/result" >/dev/null; then
        pass "$_config fails closed instead of becoming an empty command set"
      else fail "$_config fails closed instead of becoming an empty command set"; fi ;;
  esac
done

# Allocation validation happens before the real allocator can create a file.
# The control includes quotes, whitespace, globs and shell-looking text so the
# assignment helper must pass pathname data without interpreting it as code.
for _allocator in allocator-control allocator-relative allocator-escape allocator-kind; do
  reset_case; save_expected
  run_fault "$_allocator" allocate
  if [ "$_allocator" = allocator-control ]; then
    if [ "$_rc" -eq 0 ] && event allocator-invoked && restored; then
      pass 'allocator assigns literal pathname data and cleans its registered directory'
    else fail 'allocator assigns literal pathname data and cleans its registered directory'; fi
  elif [ "$_rc" -ne 0 ] && ! event allocator-invoked && restored; then
    pass "$_allocator is rejected before creating an allocation"
  else fail "$_allocator is rejected before creating an allocation"; fi
done

printf '\nactivation transactions: %d total, %d pass, %d fail\n' "$_total" "$_pass" "$_fail"
[ "$_fail" -eq 0 ]
