#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Published commands: commands= and executables= become bin/ entries in a
# built release, and install puts stubs for them in the command directory.
# Every scenario runs in a private home; nothing touches the caller's PATH
# directories or startup files.

set -eu

_total=0
_pass=0
_fail=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise="$_repo/bin/valise"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-commands.XXXXXX")
_tmp=$(cd "$_tmp" && pwd -P)
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_tmp" 2>/dev/null || :
  rm -rf -- "$_tmp"
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

_home="$_tmp/home"
_bin="$_home/.local/bin"
mkdir -p "$_home"

# _v <project> <args...>: valise against a project with a private home.
_v() {
  _v_project=$1
  shift
  env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    "$_valise" -C "$_v_project" "$@"
}

# _run <command...>: run with only the command directory and the system on PATH.
_run() {
  env -i HOME="$_home" PATH="$_bin:/usr/bin:/bin" "$@"
}

# _meta <file> <name> <requires> <shells> <exports> <load> [commands] [executables]
_meta() {
  printf '%s\n' "name=$2" 'version=' 'side_effect=read-only' "requires=$3" 'optional=' \
    "shells=$4" 'platforms=any' "exports=$5" "load=$6" "commands=${7:-}" "executables=${8:-}" >"$1"
}

_active_id() {
  _ai=$(cd "$_home/.config/valise/active" && pwd -P) || return 1
  printf '%s\n' "${_ai##*/}"
}

printf '=== valise published commands ===\n'
printf '  scratch: %s\n\n' "$_tmp"

_have_bash=0
command -v bash >/dev/null 2>&1 && _have_bash=1

_proj="$_tmp/proj"
mkdir -p "$_proj/module.d" "$_proj/modules" "$_proj/scripts"
printf '%s\n' 'bundle=default' 'variant=default' >"$_proj/valise.conf"
_meta "$_proj/module.d/main.meta" main '' posix main_ready modules/main.sh
printf 'main_ready() { :; }\n' >"$_proj/modules/main.sh"
# hello depends on an engine module, so the command plan must carry its closure.
_meta "$_proj/module.d/tool_hello.meta" tool_hello valise_platform_posix posix \
  'hello mode_probe fails' modules/hello.sh 'hello mode_probe fails' scripts/greet
cat >"$_proj/modules/hello.sh" <<'EOF'
hello() { printf 'hello:%s:%s\n' "$*" "$(sp_platform_os >/dev/null && echo dep)"; }
mode_probe() { printf 'mode=%s\n' "${VALISE_MODE-unset}"; }
fails() { return 3; }
EOF
printf '#!/bin/sh\nprintf "greet:%%s\\n" "$*"\n' >"$_proj/scripts/greet"
chmod 0755 "$_proj/scripts/greet"
_meta "$_proj/module.d/tool_clash.meta" tool_clash '' posix clash modules/clash.sh clash
printf 'clash() { echo from-valise; }\n' >"$_proj/modules/clash.sh"
_roots='main tool_hello tool_clash'
{
  printf 'bundle\tshell\troots\n'
  for _s in sh zsh ksh; do printf 'default\t%s\t%s\n' "$_s" "$_roots"; done
  if [ "$_have_bash" -eq 1 ]; then
    _meta "$_proj/module.d/tool_bash.meta" tool_bash '' bash bash_probe modules/bash_probe.bash bash_probe
    printf 'bash_probe() { printf "bash:%%s\\n" "${BASH_VERSION:+yes}"; }\n' >"$_proj/modules/bash_probe.bash"
    printf 'default\tbash\t%s tool_bash\n' "$_roots"
  else
    printf 'default\tbash\t%s\n' "$_roots"
  fi
} >"$_proj/bundles.tsv"
printf 'variant\tdescription\texcluded\ndefault\tall\t\nlean\tno hello\ttool_hello\n' >"$_proj/variants.tsv"

# --- Build ---

if _v "$_proj" build >"$_tmp/build.out" 2>&1; then
  _rel="$_proj/build/release"
  if [ -x "$_rel/bin/hello" ] && [ -x "$_rel/bin/mode_probe" ] && [ -x "$_rel/bin/greet" ] &&
    [ -f "$_rel/plans/commands/tool_hello.sh" ] &&
    _conf_cmds=$(sed -n 's/^commands=//p' "$_rel/valise-release.conf") &&
    for _c in hello mode_probe fails greet clash; do
      case " $_conf_cmds " in *" $_c "*) ;; *) false ;; esac
    done; then
    pass "build writes launchers, executables, command plans, and commands= into the release"
  else
    fail "build writes launchers, executables, command plans, and commands= into the release"
    ls -lR "$_rel" >&2 || :
  fi
  if [ "$_have_bash" -eq 1 ]; then
    if head -n 1 "$_rel/bin/bash_probe" | grep -Fx '#!/usr/bin/env bash' >/dev/null &&
      head -n 1 "$_rel/bin/hello" | grep -Fx '#!/bin/sh' >/dev/null; then
      pass "a bash-only module's command runs under bash; a POSIX module's under sh"
    else
      fail "a bash-only module's command runs under bash; a POSIX module's under sh"
    fi
  fi
  if grep -F 'valise_platform_posix@valise' "$_rel/plans/commands/tool_hello.sh" >/dev/null &&
    [ -f "$_rel/valise/module.d/valise_platform_posix.meta" ]; then
    pass "the command plan loads the module's dependencies, which ship in the release"
  else
    fail "the command plan loads the module's dependencies, which ship in the release"
  fi
else
  fail "the command project builds"
  cat "$_tmp/build.out" >&2
fi

# --- Build refusals ---

_bad="$_tmp/bad-fish"
cp -R "$_proj" "$_bad"
rm -rf "$_bad/build"
_meta "$_bad/module.d/fishy.meta" fishy '' fish fishy_cmd modules/fishy.fish fishy_cmd
printf 'function fishy_cmd; end\n' >"$_bad/modules/fishy.fish"
printf 'default\tfish\tfishy\n' >>"$_bad/bundles.tsv"
if _v "$_bad" build >/dev/null 2>"$_tmp/bad-fish.err"; then
  fail "a Fish-only module that declares commands is a build error"
elif grep -F 'Fish-only modules cannot publish commands' "$_tmp/bad-fish.err" >/dev/null &&
  [ ! -e "$_bad/build/release" ]; then
  pass "a Fish-only module that declares commands is a build error"
else
  fail "a Fish-only module that declares commands is a build error"
  cat "$_tmp/bad-fish.err" >&2
fi

_dup="$_tmp/bad-dup"
cp -R "$_proj" "$_dup"
rm -rf "$_dup/build"
_meta "$_dup/module.d/tool_dup.meta" tool_dup '' posix hello modules/dup.sh hello
printf 'hello() { :; }\n' >"$_dup/modules/dup.sh"
printf 'name=main\nversion=\nside_effect=read-only\nrequires=\noptional=tool_dup\nshells=posix\nplatforms=any\nexports=main_ready\nload=modules/main.sh\n' \
  >"$_dup/module.d/main.meta"
if _v "$_dup" build >/dev/null 2>"$_tmp/dup.err"; then
  fail "two modules publishing one command name is a build error"
elif grep -F 'command hello is published by more than one module' "$_tmp/dup.err" >/dev/null; then
  pass "two modules publishing one command name is a build error"
else
  fail "two modules publishing one command name is a build error"
  cat "$_tmp/dup.err" >&2
fi

# --- Install publishes stubs ---

mkdir -p "$_bin"
printf '#!/bin/sh\necho user-clash\n' >"$_bin/clash"
chmod 0755 "$_bin/clash"
cp "$_bin/clash" "$_tmp/clash.orig"

if _v "$_proj" apply >"$_tmp/apply.out" 2>&1; then
  pass "apply installs the command project"
else
  fail "apply installs the command project"
  cat "$_tmp/apply.out" >&2
fi
_id_full=$(_active_id || :)

if [ "$(_run hello a b 2>&1)" = 'hello:a b:dep' ]; then
  pass "hello a b runs the module function through the published stub"
else
  fail "hello a b runs the module function through the published stub"
  _run hello a b >&2 || :
fi
if [ "$(_run greet x y 2>&1)" = 'greet:x y' ]; then
  pass "an executables= script runs through its stub"
else
  fail "an executables= script runs through its stub"
fi
if [ "$(_run mode_probe)" = 'mode=unset' ] &&
  [ "$(_run env VALISE_MODE=permissive mode_probe)" = 'mode=permissive' ]; then
  pass "the launcher loads in strict mode and restores the caller's VALISE_MODE"
else
  fail "the launcher loads in strict mode and restores the caller's VALISE_MODE"
fi
_rc=0
_run fails || _rc=$?
if [ "$_rc" -eq 3 ]; then
  pass "the command's exit status reaches the caller"
else
  fail "the command's exit status reaches the caller (got $_rc)"
fi
if [ "$_have_bash" -eq 1 ]; then
  # The launcher finds bash on PATH, which may be outside /usr/bin:/bin.
  _bash_dir=$(command -v bash)
  _bash_dir=${_bash_dir%/*}
  if [ "$(env -i HOME="$_home" PATH="$_bin:$_bash_dir:/usr/bin:/bin" bash_probe)" = 'bash:yes' ]; then
    pass "a bash-only command runs in bash"
  else
    fail "a bash-only command runs in bash"
  fi
fi
if cmp -s "$_bin/clash" "$_tmp/clash.orig" &&
  grep -F "command clash not published: $_bin/clash exists and valise does not own it" "$_tmp/apply.out" >/dev/null; then
  pass "a pre-existing user file is left untouched and reported"
else
  fail "a pre-existing user file is left untouched and reported"
  cat "$_tmp/apply.out" >&2
fi
_v "$_proj" doctor >"$_tmp/doctor.out" 2>&1 || :
if grep -F "warn: command clash not published: $_bin/clash exists and valise does not own it" "$_tmp/doctor.out" >/dev/null &&
  grep -F "ok: command published: $_bin/hello" "$_tmp/doctor.out" >/dev/null &&
  grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor.out" >/dev/null; then
  pass "doctor reports published commands, the collision, and the PATH gap"
else
  fail "doctor reports published commands, the collision, and the PATH gap"
  cat "$_tmp/doctor.out" >&2
fi
if [ "$(stat -c %a "$_home/.config/valise/active/bin/hello" 2>/dev/null ||
  stat -f %Lp "$_home/.config/valise/active/bin/hello")" = 555 ]; then
  pass "installed launchers are sealed 0555"
else
  fail "installed launchers are sealed 0555"
fi
_ino_before=$(ls -i "$_bin/hello" | awk '{ print $1 }')
_v "$_proj" apply >/dev/null 2>&1 || :
_ino_after=$(ls -i "$_bin/hello" | awk '{ print $1 }')
if [ "$_ino_before" = "$_ino_after" ]; then
  pass "reapplying keeps owned stubs in place"
else
  fail "reapplying keeps owned stubs in place"
fi

# --- Switching releases ---

if _v "$_proj" apply --variant=lean >"$_tmp/lean.out" 2>&1 &&
  [ ! -e "$_bin/hello" ] && [ ! -e "$_bin/mode_probe" ] && [ ! -e "$_bin/greet" ] &&
  cmp -s "$_bin/clash" "$_tmp/clash.orig"; then
  pass "a release without the commands removes their owned stubs only"
else
  fail "a release without the commands removes their owned stubs only"
  cat "$_tmp/lean.out" >&2
  ls -l "$_bin" >&2 || :
fi
if [ -n "$_id_full" ] && _v "$_proj" release use "$_id_full" >"$_tmp/use.out" 2>&1 &&
  [ "$(_run greet back)" = 'greet:back' ]; then
  pass "release use publishes the stubs of the release it switches to"
else
  fail "release use publishes the stubs of the release it switches to"
  cat "$_tmp/use.out" >&2
fi

# --- Stubs changed outside valise ---

printf '#!/bin/sh\necho edited\n' >"$_bin/greet"
cp "$_bin/greet" "$_tmp/greet.edited"
if _v "$_proj" apply --variant=lean >"$_tmp/edit.out" 2>&1 &&
  cmp -s "$_bin/greet" "$_tmp/greet.edited" &&
  grep -F "command stub was changed outside valise; leaving it and no longer managing it: $_bin/greet" "$_tmp/edit.out" >/dev/null &&
  ! grep -F "$_bin/greet" "$_home/.local/state/valise/commands.tsv" >/dev/null; then
  pass "an edited stub is left in place and dropped from the ledger"
else
  fail "an edited stub is left in place and dropped from the ledger"
  cat "$_tmp/edit.out" >&2
fi
rm -f "$_bin/greet"

# --- No integration ---

_home2="$_tmp/home2"
mkdir -p "$_home2"
if env -i HOME="$_home2" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home2/.local/share" \
  XDG_CONFIG_HOME="$_home2/.config" XDG_STATE_HOME="$_home2/.local/state" SHELL=/bin/sh \
  "$_valise" -C "$_proj" apply --no-integration >/dev/null 2>&1 &&
  [ ! -e "$_home2/.local/bin" ] && [ ! -e "$_home2/.local/state/valise/commands.tsv" ]; then
  pass "--no-integration publishes no command stubs"
else
  fail "--no-integration publishes no command stubs"
fi

_custom="$_tmp/custom-bin"
_home3="$_tmp/home3"
mkdir -p "$_home3"
if env -i HOME="$_home3" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home3/.local/share" \
  XDG_CONFIG_HOME="$_home3/.config" XDG_STATE_HOME="$_home3/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_custom" "$_valise" -C "$_proj" apply >/dev/null 2>&1 &&
  [ "$(env -i PATH="$_custom:/usr/bin:/bin" greet c)" = 'greet:c' ] && [ ! -e "$_home3/.local/bin" ]; then
  pass "VALISE_BIN_DIR chooses the command directory"
else
  fail "VALISE_BIN_DIR chooses the command directory"
fi

printf '\n=== published commands summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
