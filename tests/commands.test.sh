#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Published commands: commands= and executables= become bin/ entries in a
# built release, and install puts stubs for them in the command directory.
# Every scenario runs in a private home; nothing touches the caller's PATH
# directories or startup files.

set -eu

# This suite promises not to touch the caller's PATH directories or startup
# files. Ambient VALISE_* settings would break that promise through the direct
# "$_valise" invocations below (e.g. make-manifest), so discard them before any
# helper is defined or called. (_v and _v_caller already isolate via env -i.)
unset VALISE_CALLER_PATH VALISE_BIN_DIR

_total=0
_pass=0
_fail=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); printf '  SKIP: %s\n' "$1"; }

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

# _v_caller <caller-path> <project> <args...>: like _v, but with an explicit
# caller PATH for diagnostics. The value goes through env -i, never through a
# prefix assignment to a shell function, which persists after the call in some
# POSIX shells (including macOS /bin/sh, bash 3.2) and leaks into later tests.
_v_caller() {
  _vc_path=$1
  _vc_project=$2
  shift 2
  env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    VALISE_CALLER_PATH="$_vc_path" \
    "$_valise" -C "$_vc_project" "$@"
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

# A caller that sanitizes PATH for the engine can pass the original for PATH
# diagnostics. It must suppress a false gap warning without changing lookup.
# The baseline apply is the positive control: without a caller PATH it MUST
# warn, or the suppression assertion below proves nothing.
if grep -F "warning: $_bin is not on PATH; add it to use the published commands" "$_tmp/apply.out" >/dev/null; then
  pass "apply reports the PATH gap when no caller PATH is supplied"
else
  fail "apply reports the PATH gap when no caller PATH is supplied"
  cat "$_tmp/apply.out" >&2
fi
# Assert on the diagnostic lines, not on doctor's exit status: doctor has other
# checks whose status is irrelevant to PATH matching.
_v_caller "$_bin:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-caller.out" 2>&1 || :
if grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-caller.out" >/dev/null &&
  ! grep -F "not on PATH: $_bin" "$_tmp/doctor-caller.out" >/dev/null; then
  pass "VALISE_CALLER_PATH is used for doctor's PATH diagnostic"
else
  fail "VALISE_CALLER_PATH is used for doctor's PATH diagnostic"
  cat "$_tmp/doctor-caller.out" >&2
fi
_vc_rc=0
_v_caller "$_bin:/usr/bin:/bin" "$_proj" apply >"$_tmp/apply-caller.out" 2>&1 || _vc_rc=$?
if [ "$_vc_rc" -eq 0 ] &&
  ! grep -F "is not on PATH; add it to use the published commands" "$_tmp/apply-caller.out" >/dev/null; then
  pass "VALISE_CALLER_PATH suppresses a false install PATH warning"
else
  fail "VALISE_CALLER_PATH suppresses a false install PATH warning"
  cat "$_tmp/apply-caller.out" >&2
fi

# PATH entries are normalized before matching: a trailing slash and a doubled
# separator must still name the command directory.
_v_caller "$_bin/:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-slash.out" 2>&1 || :
_v_caller "$_home//.local/bin:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-double.out" 2>&1 || :
if grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-slash.out" >/dev/null &&
  grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-double.out" >/dev/null; then
  pass "PATH entries are normalized before matching"
else
  fail "PATH entries are normalized before matching"
  cat "$_tmp/doctor-slash.out" "$_tmp/doctor-double.out" >&2
fi

# Relative caller PATH entries are interpreted from the directory where valise
# was invoked, before -C changes to the project. Run from the home, whose
# .local/bin is the command directory, and assert both the match and a negative
# control against a same-named directory inside the project.
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_PATH=".local/bin" \
  "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-relative.out" 2>&1 || :
mkdir -p "$_proj/.local/bin"
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_proj/.local/bin" VALISE_CALLER_PATH=".local/bin" \
  "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-relative-neg.out" 2>&1 || :
if grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-relative.out" >/dev/null &&
  grep -F "warn: command directory is not on PATH: $_proj/.local/bin" "$_tmp/doctor-relative-neg.out" >/dev/null; then
  pass "relative caller PATH entries resolve from the invocation directory, not -C"
else
  fail "relative caller PATH entries resolved against the project directory"
  cat "$_tmp/doctor-relative.out" "$_tmp/doctor-relative-neg.out" >&2
fi

# An empty caller PATH entry denotes the caller's directory. Test both a match
# and a negative control so the assertion is not vacuous.
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_home" VALISE_CALLER_PATH=":" \
  "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-empty-cwd.out" 2>&1 || :
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_proj" VALISE_CALLER_PATH=":" \
  "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-empty-cwd-neg.out" 2>&1 || :
if grep -F "ok: command directory is on PATH: $_home" "$_tmp/doctor-empty-cwd.out" >/dev/null &&
  grep -F "warn: command directory is not on PATH: $_proj" "$_tmp/doctor-empty-cwd-neg.out" >/dev/null; then
  pass "an empty caller PATH entry resolves from the invocation directory"
else
  fail "an empty caller PATH entry did not resolve from the invocation directory"
  cat "$_tmp/doctor-empty-cwd.out" "$_tmp/doctor-empty-cwd-neg.out" >&2
fi

# The caller CWD is diagnostic context only: it must not leak into generated
# content, env capture, or child processes. Run from inside $_home so the
# recorded caller directory is a real value, check the exit status (a crash or
# empty output must not pass vacuously), inspect a child process's environment,
# and pre-export VALISE_CALLER_CWD to prove the export attribute is dropped.
_cwd_leak_rc=0
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_CWD=/pre-exported-leak \
  "$_valise" -C "$_proj" env export environment.d) >"$_tmp/env-export-cwd.out" 2>&1 || _cwd_leak_rc=$?
_cwd_child_rc=0
(cd "$_home" && env -i HOME="$_home" PATH=/usr/bin:/bin \
  XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_CWD=/pre-exported-leak \
  "$_valise" -C "$_proj" run -- /bin/sh -c 'env') >"$_tmp/env-child-cwd.out" 2>&1 || _cwd_child_rc=$?
if [ "$_cwd_leak_rc" -eq 0 ] && [ "$_cwd_child_rc" -eq 0 ] &&
   ! grep -F 'VALISE_CALLER_CWD' "$_tmp/env-export-cwd.out" >/dev/null &&
   ! grep -F "$_home" "$_tmp/env-export-cwd.out" >/dev/null &&
   ! grep -F 'VALISE_CALLER_CWD' "$_tmp/env-child-cwd.out" >/dev/null &&
   ! grep -F '/pre-exported-leak' "$_tmp/env-child-cwd.out" >/dev/null &&
   ! grep -F "$_home" "$_tmp/env-child-cwd.out" >/dev/null; then
  pass "the recorded caller directory does not leak into generated content or child processes"
else
  fail "the recorded caller directory leaked into generated content or a child process"
  cat "$_tmp/env-export-cwd.out" "$_tmp/env-child-cwd.out" >&2
fi

# The caller PATH takes precedence: a real PATH that contains the command dir
# must not silence a gap reported by the caller PATH.
env -i HOME="$_home" PATH="$_bin:/usr/bin:/bin" XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_PATH=/usr/bin:/bin \
  "$_valise" -C "$_proj" doctor >"$_tmp/doctor-precedence.out" 2>&1 || :
if grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-precedence.out" >/dev/null; then
  pass "VALISE_CALLER_PATH takes precedence over the real PATH"
else
  fail "VALISE_CALLER_PATH takes precedence over the real PATH"
  cat "$_tmp/doctor-precedence.out" >&2
fi

# An explicitly empty caller PATH means the caller has no PATH entries, so the
# gap is still reported even though the real PATH contains the command dir.
env -i HOME="$_home" PATH="$_bin:/usr/bin:/bin" XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_PATH= \
  "$_valise" -C "$_proj" doctor >"$_tmp/doctor-empty.out" 2>&1 || :
if grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-empty.out" >/dev/null; then
  pass "an empty VALISE_CALLER_PATH still reports the PATH gap"
else
  fail "an empty VALISE_CALLER_PATH still reports the PATH gap"
  cat "$_tmp/doctor-empty.out" >&2
fi

# A PATH entry with glob characters must be matched literally, not expanded.
# The lookalike sibling makes an unmatched pattern expansion observable: with
# globbing on, glob*[x] would expand to globax and break both assertions.
_glob_bin="$_tmp/glob*[x]"
_glob_lookalike="$_tmp/globax"
mkdir -p "$_glob_bin" "$_glob_lookalike"
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_glob_bin" VALISE_CALLER_PATH="$_glob_bin:/usr/bin:/bin" \
  "$_valise" -C "$_proj" doctor >"$_tmp/doctor-glob.out" 2>&1 || :
if grep -F "ok: command directory is on PATH: $_glob_bin" "$_tmp/doctor-glob.out" >/dev/null &&
  ! grep -F "not on PATH: $_glob_bin" "$_tmp/doctor-glob.out" >/dev/null; then
  pass "PATH matching treats glob characters literally"
else
  fail "PATH matching treats glob characters literally"
  cat "$_tmp/doctor-glob.out" >&2
fi
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_BIN_DIR="$_glob_lookalike" VALISE_CALLER_PATH="$_glob_bin:/usr/bin:/bin" \
  "$_valise" -C "$_proj" doctor >"$_tmp/doctor-glob-lookalike.out" 2>&1 || :
if grep -F "warn: command directory is not on PATH: $_glob_lookalike" "$_tmp/doctor-glob-lookalike.out" >/dev/null; then
  pass "a glob entry does not match a lookalike directory"
else
  fail "a glob entry does not match a lookalike directory"
  cat "$_tmp/doctor-glob-lookalike.out" >&2
fi

# The caller PATH is diagnostic-only: a directory on it is never used for
# command publication, command lookup, or generated profile content.
_sentinel="$_tmp/caller-only"
mkdir -p "$_sentinel"
printf '#!/bin/sh\necho caller-only\n' >"$_sentinel/hello"
chmod 0755 "$_sentinel/hello"
cp "$_sentinel/hello" "$_tmp/sentinel.hello.orig"
# A tool that would corrupt the release ledger if utility lookup used the
# caller PATH. The sentinel is off the real PATH, so it must never be found.
printf '#!/bin/sh\nprintf "CORRUPT\\n"\n' >"$_sentinel/awk"
chmod 0755 "$_sentinel/awk"
_as_rc=0
_v_caller "$_sentinel:/usr/bin:/bin" "$_proj" apply >"$_tmp/apply-sentinel.out" 2>&1 || _as_rc=$?
_ds_rc=0
_v_caller "$_sentinel:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-sentinel.out" 2>&1 || _ds_rc=$?
_ee_base_rc=0
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  "$_valise" -C "$_proj" env export environment.d >"$_tmp/env-export-base.out" 2>"$_tmp/env-export-base.err" || _ee_base_rc=$?
_ee_caller_rc=0
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_PATH="$_sentinel" \
  "$_valise" -C "$_proj" env export environment.d >"$_tmp/env-export-caller.out" 2>"$_tmp/env-export-caller.err" || _ee_caller_rc=$?
# `valise env` emits real KEY=value lines, so comparing it with and without the
# caller PATH is a non-vacuous check that nothing diagnostic leaks into output.
_env_base_rc=0
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  "$_valise" -C "$_proj" env >"$_tmp/env-base.out" 2>/dev/null || _env_base_rc=$?
_env_caller_rc=0
env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
  VALISE_CALLER_PATH="$_sentinel" \
  "$_valise" -C "$_proj" env >"$_tmp/env-caller.out" 2>/dev/null || _env_caller_rc=$?
if [ "$_as_rc" -eq 0 ] && [ "$_ds_rc" -eq 0 ] &&
   [ "$_ee_base_rc" -eq 0 ] && [ "$_ee_caller_rc" -eq 0 ] &&
   [ "$_env_base_rc" -eq 0 ] && [ "$_env_caller_rc" -eq 0 ] &&
   [ ! -e "$_sentinel/mode_probe" ] && [ ! -e "$_sentinel/greet" ] &&
   cmp -s "$_sentinel/hello" "$_tmp/sentinel.hello.orig" &&
   ! grep -F "CORRUPT" "$_tmp/apply-sentinel.out" "$_tmp/doctor-sentinel.out" >/dev/null &&
   grep -F "ok: command published: $_bin/hello" "$_tmp/doctor-sentinel.out" >/dev/null &&
   cmp -s "$_tmp/env-export-base.out" "$_tmp/env-export-caller.out" &&
   grep -F "VALISE_VERSION=" "$_tmp/env-base.out" >/dev/null &&
   cmp -s "$_tmp/env-base.out" "$_tmp/env-caller.out" &&
   ! grep -F "$_sentinel" "$_tmp/env-caller.out" >/dev/null &&
   [ "$(_run hello a b 2>&1)" = 'hello:a b:dep' ]; then
  pass "VALISE_CALLER_PATH does not affect lookup or generated profile content"
else
  fail "VALISE_CALLER_PATH does not affect lookup or generated profile content"
  cat "$_tmp/apply-sentinel.out" "$_tmp/doctor-sentinel.out" \
    "$_tmp/env-export-base.out" "$_tmp/env-export-caller.out" \
    "$_tmp/env-base.out" "$_tmp/env-caller.out" >&2
fi
# Positive control for the repeat-apply suppression: a repeat apply whose
# caller PATH lacks the command dir MUST still warn, proving the suppression
# above is caused by VALISE_CALLER_PATH and not by apply skipping the check.
if grep -F "warning: $_bin is not on PATH; add it to use the published commands" "$_tmp/apply-sentinel.out" >/dev/null; then
  pass "a repeat apply still warns when the caller PATH lacks the command dir"
else
  fail "a repeat apply still warns when the caller PATH lacks the command dir"
  cat "$_tmp/apply-sentinel.out" >&2
fi
# apply consults VALISE_CALLER_PATH too: with the command dir on the caller
# PATH the repeat apply exits 0 and stays silent about the gap.
_ac_rc=0
_v_caller "$_bin:/usr/bin:/bin" "$_proj" apply >"$_tmp/apply-caller2.out" 2>&1 || _ac_rc=$?
if [ "$_ac_rc" -eq 0 ] &&
  ! grep -F "is not on PATH; add it to use the published commands" "$_tmp/apply-caller2.out" >/dev/null; then
  pass "apply uses VALISE_CALLER_PATH for its PATH-gap warning"
else
  fail "apply uses VALISE_CALLER_PATH for its PATH-gap warning"
  cat "$_tmp/apply-caller2.out" >&2
fi
# Command substitution strips trailing newlines, so an entry that ends in one
# must NOT match the newline-free command directory.
_nl='
'
_v_caller "$_bin$_nl:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-nl.out" 2>&1 || :
_v_caller "$_bin$_nl" "$_proj" doctor >"$_tmp/doctor-nl-only.out" 2>&1 || :
if grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-nl.out" >/dev/null &&
   grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-nl-only.out" >/dev/null; then
  pass "a trailing newline in a caller PATH entry does not falsely match"
else
  fail "a trailing newline in a caller PATH entry does not falsely match"
  cat "$_tmp/doctor-nl.out" "$_tmp/doctor-nl-only.out" >&2
fi
# Parameter-expansion splitting must not break on whitespace inside an entry.
# Empty entries resolve to the caller's invocation directory when valise
# records one (bin/valise always does), so "::$_bin", "$_bin:" and
# "/usr/bin::$_bin" all match, while a value of only empty entries ("::") does
# not match the command directory. Library-only callers that leave
# VALISE_CALLER_CWD unset skip empty entries instead of resolving them against
# the directory valise runs in after -C.
_sp="$_tmp/dir with space"
mkdir -p "$_sp"
_v_caller "$_sp:/usr/bin:/bin" "$_proj" doctor >"$_tmp/doctor-space.out" 2>&1 || :
_v_caller ":$_bin" "$_proj" doctor >"$_tmp/doctor-lead.out" 2>&1 || :
_v_caller "$_bin:" "$_proj" doctor >"$_tmp/doctor-trail.out" 2>&1 || :
_v_caller "/usr/bin::$_bin" "$_proj" doctor >"$_tmp/doctor-double2.out" 2>&1 || :
_v_caller "::" "$_proj" doctor >"$_tmp/doctor-empty-only.out" 2>&1 || :
if grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-space.out" >/dev/null &&
   grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-lead.out" >/dev/null &&
   grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-trail.out" >/dev/null &&
   grep -F "ok: command directory is on PATH: $_bin" "$_tmp/doctor-double2.out" >/dev/null &&
   grep -F "warn: command directory is not on PATH: $_bin" "$_tmp/doctor-empty-only.out" >/dev/null; then
  pass "whitespace entries are not split and empty entries resolve to the caller directory"
else
  fail "whitespace entries are not split and empty entries resolve to the caller directory"
  cat "$_tmp/doctor-space.out" "$_tmp/doctor-lead.out" "$_tmp/doctor-trail.out" \
    "$_tmp/doctor-double2.out" "$_tmp/doctor-empty-only.out" >&2
fi

# Invoked from the root directory, an empty or relative caller PATH entry must
# join with exactly one separator: VALISE_CALLER_CWD=/ must not produce the
# POSIX implementation-defined leading "//".
if [ "$(id -u)" -eq 0 ] && [ -w / ]; then
  _root_rc=0
  (cd / && env -i HOME="$_home" PATH=/usr/bin:/bin \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    VALISE_BIN_DIR=/ VALISE_CALLER_PATH=":" \
    "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-root-empty.out" 2>&1 || _root_rc=$?
  _root_rel_rc=0
  (cd / && env -i HOME="$_home" PATH=/usr/bin:/bin \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    VALISE_BIN_DIR=/usr/bin VALISE_CALLER_PATH="usr/bin" \
    "$_valise" -C "$_proj" doctor) >"$_tmp/doctor-root-rel.out" 2>&1 || _root_rel_rc=$?
  if [ "$_root_rc" -eq 0 ] &&
     grep -F "ok: command directory is on PATH: /" "$_tmp/doctor-root-empty.out" >/dev/null &&
     [ "$_root_rel_rc" -eq 0 ] &&
     grep -F "ok: command directory is on PATH: /usr/bin" "$_tmp/doctor-root-rel.out" >/dev/null; then
    pass "an empty or relative caller PATH entry invoked from / joins without a leading //"
  else
    fail "a caller PATH entry invoked from / did not resolve without a leading //"
    cat "$_tmp/doctor-root-empty.out" "$_tmp/doctor-root-rel.out" >&2
  fi
else
  skip "caller PATH entries invoked from / (needs a writable / or non-root)"
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

# --- Release contents are not trusted for command names ---

_home4="$_tmp/home4"
mkdir -p "$_home4"
_evil="$_tmp/evil-release"
cp -R "$_proj/build/release" "$_evil"
chmod -R u+w "$_evil"
sed 's/^commands=.*/commands=hello ..\/..\/escaped-stub/' "$_evil/valise-release.conf" >"$_tmp/conf" &&
  cat "$_tmp/conf" >"$_evil/valise-release.conf"
rm -f "$_evil/manifest.tsv"
"$_valise" make-manifest "$_evil" >/dev/null 2>&1
if (cd "$_evil" && env -i HOME="$_home4" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home4/.local/share" \
  XDG_CONFIG_HOME="$_home4/.config" XDG_STATE_HOME="$_home4/.local/state" SHELL=/bin/sh \
  "$_valise" install) >"$_tmp/evil.out" 2>&1; then
  fail "install refuses a release that lists an invalid command name"
elif grep -F 'invalid command name' "$_tmp/evil.out" >/dev/null &&
  [ ! -e "$_home4/escaped-stub" ] && [ ! -e "$_home4/.local/bin" ] && [ ! -e "$_home4/.config/valise/active" ]; then
  pass "install refuses a release that lists an invalid command name"
else
  fail "install refuses a release that lists an invalid command name"
  cat "$_tmp/evil.out" >&2
fi

# --- An interrupted publication leaves no stub valise does not own ---

_many="$_tmp/many"
mkdir -p "$_many/module.d" "$_many/modules"
printf '%s\n' 'bundle=default' 'variant=default' >"$_many/valise.conf"
_names=
_i=0
: >"$_many/modules/many.sh"
while [ "$_i" -lt 400 ]; do
  _names="$_names c$_i"
  printf 'c%d() { :; }\n' "$_i" >>"$_many/modules/many.sh"
  _i=$((_i + 1))
done
_meta "$_many/module.d/many.meta" many '' posix "${_names# }" modules/many.sh "${_names# }"
printf 'bundle\tshell\troots\ndefault\tsh\tmany\n' >"$_many/bundles.tsv"
_v "$_many" build >/dev/null 2>&1
for _scenario in first second; do
  _home5="$_tmp/home5-$_scenario"
  mkdir -p "$_home5"
  _env5="HOME=$_home5 XDG_DATA_HOME=$_home5/.local/share XDG_CONFIG_HOME=$_home5/.config XDG_STATE_HOME=$_home5/.local/state"
  if [ "$_scenario" = second ]; then
    (cd "$_proj/build/release" && env -i $_env5 PATH=/usr/bin:/bin SHELL=/bin/sh "$_valise" install) >/dev/null 2>&1
  fi
  (cd "$_many/build/release" && exec env -i $_env5 PATH=/usr/bin:/bin SHELL=/bin/sh "$_valise" install) \
    >"$_tmp/many-$_scenario.out" 2>&1 &
  _pid=$!
  _n=0
  while [ ! -e "$_home5/.local/bin/c3" ] && [ "$_n" -lt 6000 ] && kill -0 "$_pid" 2>/dev/null; do
    sleep 0.01 2>/dev/null || sleep 1
    _n=$((_n + 1))
  done
  _seen=0
  [ ! -e "$_home5/.local/bin/c3" ] || _seen=1
  kill -TERM "$_pid" 2>/dev/null || :
  _rc=0
  wait "$_pid" || _rc=$?
  _left=$(ls "$_home5/.local/bin" 2>/dev/null | grep -E '^c[0-9]+$' || :)
  if [ "$_rc" -eq 0 ] || [ "$_seen" -eq 0 ]; then
    printf '  SKIP: the install was not interrupted while publishing stubs (%s install)\n' "$_scenario"
  elif [ -z "$_left" ]; then
    pass "an install interrupted while publishing stubs removes them ($_scenario install)"
  else
    fail "an install interrupted while publishing stubs removes them ($_scenario install)"
    printf '    left: %s\n' $_left >&2
  fi
done

printf '\n=== published commands summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
