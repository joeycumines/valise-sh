#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Real-shell startup-sequence tests for the two-stage managed block. Each case
# builds a fixture project, installs it into a quarantined HOME with
# `valise install`, then starts real shells that read the installed startup
# files one after another, so the state carried between files is exercised
# the way a user's login does. Nothing here touches a live profile.

set -eu

_total=0
_pass=0
_fail=0
_skip=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); _skip=$((_skip + 1)); printf '  SKIP: %s\n' "$1"; }

# Every scenario below drives a real interpreter. Without the shell installed,
# an absence assertion passes vacuously and a presence assertion fails, so the
# whole zsh/bash part of the lane is skipped with a named reason instead.
if [ ! -x /bin/zsh ]; then
  skip "zsh scenarios: /bin/zsh is not installed"
  printf '\n%s: %d total, %d pass, %d fail, %d skip\n' "startup-state" "$_total" "$_pass" "$_fail" "$_skip"
  exit 0
fi
if [ ! -x /bin/bash ]; then
  skip "bash scenarios need /bin/bash in addition to /bin/zsh"
fi

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise="$_repo/bin/valise"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-startup-state.XXXXXX")
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

_project="$_tmp/project"
mkdir -p "$_project/module.d" "$_project/modules"
: >"$_project/valise.conf"

# _module <name> <requires> <exports> <phase> <optional> <side_effect> <body>
# Writes one module's metadata and load file. Every module is for the posix
# class so the same plans serve zsh, bash, and sh.
_module() {
  cat >"$_project/module.d/$1.meta" <<EOF
name=$1
version=
side_effect=$6
requires=$2
optional=$5
shells=posix
platforms=any
exports=$3
load=modules/$1.sh
phase=$4
EOF
  printf '%s\n' "$7" >"$_project/modules/$1.sh"
}

# A required env dependency. Its failure is switched on by a flag file, so one
# fixture serves every scenario: the flag decides the outcome at each load.
_module envdep '' envdep_fn env '' read-only '[ ! -f "$HOME/envdep-fails" ] || return 42
echo x >>"$HOME/envdep.count"
envdep_fn() { :; }'

# The interactive dependent that must not run when envdep is unavailable.
_module intdep envdep intdep_fn interactive '' read-only 'intdep_fn() { :; }
echo ran >>"$HOME/intdep.log"'

# An env module that fails only when its flag exists, reached through an
# OPTIONAL edge from an env root. Its interactive dependent must stay blocked.
_module envopt '' envopt_fn env '' read-only '[ ! -f "$HOME/envopt-fails" ] || return 42
envopt_fn() { :; }'
_module intopt envopt intopt_fn interactive '' read-only 'intopt_fn() { :; }
echo ran >>"$HOME/intopt.log"'
_module envroot '' envroot_fn env intopt read-only 'envroot_fn() { :; }'

# Two different providers of one export name, in separate bundles. The
# collision bundle loads both, one per phase; the own-a/own-b pair models a
# release switch in which the caller's function meets a new provider.
_module collide_env '' shared_fn env '' read-only 'shared_fn() { echo env; }'
_module collide_int '' shared_fn interactive '' read-only 'shared_fn() { echo interactive; }'
_module ownA_old '' reused_fn env '' read-only 'reused_fn() { echo old; }'
_module ownB_new '' reused_fn env '' read-only 'reused_fn() { echo newcomer; }'
# The migrate bundle's module is rebuilt with a different phase, so one name
# moves from env to interactive across two releases.
_module mover '' mover_fn env '' read-only 'mover_fn() { echo A-env; }'

# A module that uses the engine's shipped PATH helper (valise_path, which the
# engine provides to every project), the way a real project does. It counts its
# own loads so a reread can be checked.
_module pathmod valise_path '' env '' path-env 'echo x >>"$HOME/pathmod.count"
valise_path_prepend "$HOME/startup-toolbin"'

# _bundle <name> <roots>: one bundle row per shell class.
_bundle() {
  for _b_shell in sh bash zsh ksh; do
    printf '%s\t%s\t%s\n' "$1" "$_b_shell" "$2" >>"$_project/bundles.tsv"
  done
}
_bundle startup 'envdep intdep envroot pathmod'
_bundle collide 'collide_env collide_int'
_bundle own-a 'ownA_old'
_bundle own-b 'ownB_new'
_bundle migrate 'mover'
# The activation bundle: one module that is interactive in release A and env-
# only in release B, which has no interactive plan at all.
_bundle activation 'actmod'
unset _b_shell

_os=$(uname -s)
case "$_os" in
  Darwin|Linux|*BSD) : ;;
esac
unset _os

# _build <bundle> <out-dir>: build one bundle of the fixture into <out-dir>.
_build() {
  _b_bundle=$1
  _b_out=$2
  rm -rf "$_b_out"
  if (cd "$_project" && "$_valise" build --bundle="$_b_bundle" "$_b_out") \
    >"$_tmp/build.out" 2>"$_tmp/build.err"; then
    return 0
  fi
  cat "$_tmp/build.err" >&2
  return 1
}

# _home_env <home> [VAR=value ...] -- <command...>
# Run a command with a quarantined HOME and XDG tree, the PATH valise uses,
# and any extra variables before the `--`.
_home_env() {
  _he_home=$1
  shift
  _he_extra=
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    _he_extra="$_he_extra $1"
    shift
  done
  [ "${1:-}" = -- ] && shift
  # shellcheck disable=SC2086
  env -i HOME="$_he_home" XDG_CONFIG_HOME="$_he_home/.config" \
    XDG_DATA_HOME="$_he_home/.local/share" XDG_STATE_HOME="$_he_home/.local/state" \
    PATH="$_repo/bin:/usr/bin:/bin:/usr/sbin:/sbin" $_he_extra "$@"
}

# _install <release-dir> <home> <shell>: install the built release for a user
# whose login shell is <shell>, so the rc-stage files are written too.
_install() {
  (cd "$1" && _home_env "$2" SHELL="$3" "$_valise" install) >"$2.install.out" 2>&1
}

# _reset_home <home>: a fresh quarantined home, with no marker files.
_reset_home() {
  chmod -R u+w "$1" 2>/dev/null || :
  rm -rf "$1"
  mkdir -p "$1"
}

# _marker_count <file>: lines in a marker file, 0 when absent.
_marker_count() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

_build startup "$_tmp/release-a" || {
  fail "build the startup fixture bundle"
  exit 1
}
pass "build the startup fixture bundle"

# The generated block is sourced by every shell class, so it must parse in each
# one. A stray keyword is otherwise visible only to the scenario that happens to
# read that file, which is how a broken block can pass a single lane.
_block="$_tmp/block.sh"
(cd "$_tmp/release-a" && _home_env "$_tmp" -- "$_valise" init posix >"$_block") 2>/dev/null
for _syntax_shell in /bin/sh /bin/bash /bin/zsh /bin/ksh; do
  [ -x "$_syntax_shell" ] || continue
  if "$_syntax_shell" -n "$_block" 2>"$_tmp/syntax.err"; then
    pass "the managed block parses under $_syntax_shell"
  else
    fail "the managed block does not parse under $_syntax_shell"
    cat "$_tmp/syntax.err" >&2
  fi
done
unset _syntax_shell

_home="$_tmp/home"

# Scenario 1: a required env module fails in .zshenv, and the dependent
# interactive module must not run in .zshrc. Strict is a control: the old code
# also blocked this case, so it must stay blocked.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
: >"$_home/envdep-fails"
_home_env "$_home" VALISE_MODE=strict -- /bin/zsh -i -c ':' >"$_tmp/s1.out" 2>"$_tmp/s1.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "zsh strict: a failed required env module blocks its interactive dependent in .zshrc"
else
  fail "zsh strict: the interactive dependent ran after its env dependency failed"
  cat "$_tmp/s1.err" >&2
fi

# Scenario 2: the same failure in PERMISSIVE mode. The plan returns success,
# so the managed block must carry the unavailable list into .zshrc. Before the
# fix the release guard skipped the env stage there and cleared the list.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
: >"$_home/envdep-fails"
_home_env "$_home" VALISE_MODE=permissive -- /bin/zsh -i -c ':' >"$_tmp/s2.out" 2>"$_tmp/s2.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "zsh permissive: a failed required env module blocks its interactive dependent across .zshenv and .zshrc"
else
  fail "zsh permissive: the interactive dependent ran across separate startup files after its env dependency failed"
fi
if grep -q 'required dependency unavailable: envdep' "$_tmp/s2.err"; then
  pass "zsh permissive: the blocked dependent names the unavailable env dependency"
else
  fail "zsh permissive: the unavailable dependency was not named on stderr"
  cat "$_tmp/s2.err" >&2
fi

# Scenario 3: an OPTIONAL env dependency fails in strict mode. Its interactive
# dependent (reached through an optional edge) must stay blocked across files.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
: >"$_home/envopt-fails"
_home_env "$_home" VALISE_MODE=strict -- /bin/zsh -i -c ':' >"$_tmp/s3.out" 2>"$_tmp/s3.err" || :
if [ "$(_marker_count "$_home/intopt.log")" -eq 0 ]; then
  pass "zsh strict: an optional env failure blocks its interactive dependent across files"
else
  fail "zsh strict: the interactive dependent of a failed optional env module ran across files"
fi

# Scenario 4: zsh login repair. .zshenv loads the env plan successfully and
# then makes envdep fail; the .zprofile repair pass re-runs the env plan and
# must record the failure, so .zshrc never runs the dependent.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
printf '\n: >"$HOME/envdep-fails"\n' >>"$_home/.zshenv"
_home_env "$_home" VALISE_MODE=strict -- /bin/zsh -l -i -c ':' >"$_tmp/s4.out" 2>"$_tmp/s4.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "zsh login repair: a failed repair pass never lets the dependent run in .zshrc"
else
  fail "zsh login repair: the dependent ran after the repair pass failed its env dependency"
fi

# Scenario 5: control. With nothing failing, the interactive dependent runs
# exactly once in .zshrc, and a second read of the same release is a no-op.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
_home_env "$_home" -- /bin/zsh -i -c ':' >"$_tmp/s5.out" 2>"$_tmp/s5.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "zsh healthy: the interactive dependent runs once in .zshrc"
else
  fail "zsh healthy: the interactive dependent did not run"
  cat "$_tmp/s5.err" >&2
fi
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
_home_env "$_home" -- /bin/zsh -i -c '. "$HOME/.zshenv"; . "$HOME/.zshenv"' >/dev/null 2>&1 || :
if [ "$(_marker_count "$_home/envdep.count")" -eq 1 ]; then
  pass "a second read of the same release in one shell does not reload the env plan"
else
  fail "a second read of the same release reloaded the env plan"
fi

# Scenario 6: a release with no env plan file must run no interactive module,
# even though its interactive plan is present. The stage-1 failure must block
# stage 2 instead of letting it run on a missing env stage. The fixture release
# is salted so it gets its own store id: deleting plans/zsh.sh from the shared
# release-a would also break every later scenario that reinstalls it.
rm -f "$_project/modules/envdep.sh.salt6"
printf '%s\n' '# salt 6' >>"$_project/modules/envdep.sh"
_build startup "$_tmp/release-missing" || { fail "build the missing-plan fixture bundle"; exit 1; }
_reset_home "$_home"
_install "$_tmp/release-missing" "$_home" /bin/zsh
_active=$(eval "$(grep '^_valise_active_link=' "$_home/.zshenv")"; printf '%s' "$_valise_active_link")
_rel_real=$(cd "$_active" && pwd -P)
chmod -R u+w "$_rel_real" 2>/dev/null || :
rm -f "$_rel_real/plans/zsh.sh"
_home_env "$_home" -- /bin/zsh -i -c ':' >"$_tmp/s6.out" 2>"$_tmp/s6.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "a missing env plan file blocks the interactive stage"
else
  fail "the interactive stage ran although the env plan file was missing"
fi

# Scenario 7: a PATH helper entry must survive a user rc file that resets PATH
# after the managed block already ran in .zshenv. The later managed block sees
# the same release, so only a changed PATH can tell it to re-assert the plan.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
printf 'PATH=/usr/bin:/bin\nexport PATH\n' | cat - "$_home/.zshrc" >"$_home/.zshrc.new"
mv "$_home/.zshrc.new" "$_home/.zshrc"
_home_env "$_home" -- /bin/zsh -i -c 'printf "%s\n" "${PATH%%:*}"' >"$_tmp/s7.out" 2>"$_tmp/s7.err" || :
if [ "$(head -n 1 "$_tmp/s7.out")" = "$_home/startup-toolbin" ]; then
  pass "zsh: a user rc file that resets PATH after the env plan does not lose the valise PATH entry"
else
  fail "zsh: a PATH reset in .zshrc dropped the valise PATH entry (first entry: $(head -n 1 "$_tmp/s7.out"))"
fi

# Scenario 8: control. A reread with an unchanged PATH runs no env body again.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
_home_env "$_home" -- /bin/zsh -i -c '. "$HOME/.zshenv"; . "$HOME/.zshenv"' >/dev/null 2>&1 || :
if [ "$(_marker_count "$_home/pathmod.count")" -eq 1 ]; then
  pass "an unchanged PATH reread does not rerun env module bodies"
else
  fail "an unchanged PATH reread reran env module bodies ($(_marker_count "$_home/pathmod.count") loads)"
fi

# _active_link_of <home>: the active link path the installed block carries.
_active_link_of() {
  (eval "$(grep '^_valise_active_link=' "$1/.zshenv")"; printf '%s' "$_valise_active_link")
}

# Ownership builds: the collision bundle, the two providers of one name, and
# the same module name built once as env and once as interactive.
_build collide "$_tmp/release-collide" || { fail "build the collision bundle"; exit 1; }
_build own-a "$_tmp/release-own-a" || { fail "build the own-a bundle"; exit 1; }
_build own-b "$_tmp/release-own-b" || { fail "build the own-b bundle"; exit 1; }
_build migrate "$_tmp/release-migrate-a" || { fail "build the migrate-a bundle"; exit 1; }
_module mover '' mover_fn interactive '' read-only 'mover_fn() { echo B-int; }'
_build migrate "$_tmp/release-migrate-b" || { fail "build the migrate-b bundle"; exit 1; }

# Scenario 9: two different modules export one name. Separate zsh startup files
# (env in .zshenv, interactive in .zshrc) must report the collision and keep the
# env provider, exactly as one combined plan does.
_reset_home "$_home"
_install "$_tmp/release-collide" "$_home" /bin/zsh
_home_env "$_home" -- /bin/zsh -i -c 'shared_fn' >"$_tmp/s9.out" 2>"$_tmp/s9.err" || :
if [ "$(cat "$_tmp/s9.out")" = env ]; then
  pass "zsh: a different module's export is not replaced across startup files"
else
  fail "zsh: the interactive provider replaced the env provider's export (output: $(cat "$_tmp/s9.out"))"
fi
if grep -q 'declared export already exists before load: shared_fn' "$_tmp/s9.err"; then
  pass "zsh: the export collision is reported across startup files"
else
  fail "zsh: the export collision was not reported across startup files"
fi

# Scenario 10: control. One module moves from env (release A) to interactive
# (release B); a switch in one zsh process must replace its own export.
_reset_home "$_home"
_install "$_tmp/release-migrate-a" "$_home" /bin/zsh
_active=$(_active_link_of "$_home")
_home_env "$_home" "MIG_B=$_tmp/release-migrate-b" "ACTIVE_LINK=$_active" -- /bin/zsh -i -c \
  'ln -sfn "$MIG_B" "$ACTIVE_LINK"; . "$HOME/.zshenv"; . "$HOME/.zshrc"; mover_fn' \
  >"$_tmp/s10.out" 2>"$_tmp/s10.err" || :
if [ "$(tail -n 1 "$_tmp/s10.out")" = B-int ]; then
  pass "a module moving from env to interactive replaces its own export across a release switch"
else
  fail "a module moving from env to interactive kept its old export (output: $(tail -n 1 "$_tmp/s10.out"))"
fi

# Scenario 11: a caller's function meets a new provider after a release switch.
# The release that first loaded ownA_old is gone, so its ledger entry must not
# let the reload unset the caller's function for the newcomer.
_reset_home "$_home"
_install "$_tmp/release-own-a" "$_home" /bin/zsh
_active=$(_active_link_of "$_home")
_home_env "$_home" "OWN_B=$_tmp/release-own-b" "ACTIVE_LINK=$_active" -- /bin/zsh -i -c \
  'reused_fn() { echo caller; }; ln -sfn "$OWN_B" "$ACTIVE_LINK"; . "$HOME/.zshenv"; reused_fn' \
  >"$_tmp/s11.out" 2>"$_tmp/s11.err" || :
if [ "$(tail -n 1 "$_tmp/s11.out")" = caller ]; then
  pass "a caller's function survives a release switch that brings a different provider of the same name"
else
  fail "a release switch replaced the caller's function with another provider (output: $(tail -n 1 "$_tmp/s11.out"))"
fi
if grep -q 'declared export already exists before load: reused_fn' "$_tmp/s11.err"; then
  pass "the caller's colliding function is reported on the switch"
else
  fail "the caller's colliding function was not reported on the switch"
fi

# Scenario 12: release A (interactive module), then release B (env-only, so no
# interactive plan), then A again, all in ONE interactive zsh. The interactive
# function must come back from A, not stay as B's env definition.
_module actmod '' actmod_fn interactive '' read-only 'actmod_fn() { echo A-int; }'
_build activation "$_tmp/release-act-a" || { fail "build the activation bundle for A"; exit 1; }
_module actmod '' actmod_fn env '' read-only 'actmod_fn() { echo B-env; }'
_build activation "$_tmp/release-act-b" || { fail "build the activation bundle for B"; exit 1; }
_reset_home "$_home"
_install "$_tmp/release-act-a" "$_home" /bin/zsh
_active=$(_active_link_of "$_home")
# Return to A's INSTALLED release (its store directory and release id), which is
# how a real `valise release use` comes back to it.
_store_a=$(readlink "$_active")
_home_env "$_home" "ACT_A=$_store_a" "ACT_B=$_tmp/release-act-b" "ACTIVE_LINK=$_active" -- /bin/zsh -i -c \
  'first=$(actmod_fn); ln -sfn "$ACT_B" "$ACTIVE_LINK"; . "$HOME/.zshenv"; . "$HOME/.zshrc"; second=$(actmod_fn); ln -sfn "$ACT_A" "$ACTIVE_LINK"; . "$HOME/.zshenv"; . "$HOME/.zshrc"; third=$(actmod_fn); printf "%s %s %s\n" "$first" "$second" "$third"' \
  >"$_tmp/s12.out" 2>"$_tmp/s12.err" || :
if [ "$(tail -n 1 "$_tmp/s12.out")" = "A-int B-env A-int" ]; then
  pass "A -> B -> A in one interactive shell returns the interactive function from A"
else
  fail "A -> B -> A returned the wrong implementation (got: $(tail -n 1 "$_tmp/s12.out"))"
fi

if [ ! -x /bin/bash ]; then
  skip "bash scenarios 13-15: /bin/bash is not installed"
  printf '\n%s: %d total, %d pass, %d fail, %d skip\n' "startup-state" "$_total" "$_pass" "$_fail" "$_skip"
  [ "$_fail" -eq 0 ] || exit 1
  exit 0
fi

# Scenario 13: a fresh bash home (no login or rc files) with bash as the login
# shell. `bash --login -i` reads only the login file, never .bashrc, so the
# interactive plan must be reachable from that login file.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/bash
_home_env "$_home" -- /bin/bash --login -i -c ':' >"$_tmp/s13.out" 2>"$_tmp/s13.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash login: an interactive login shell reaches the interactive stage in a fresh home"
else
  fail "bash login: an interactive login shell did not load the interactive plan in a fresh home"
  cat "$_tmp/s13.err" >&2
fi

# Scenario 14: control. A non-login interactive bash reads .bashrc, and a
# non-interactive `bash -c` stays silent and loads no interactive module.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/bash
_home_env "$_home" -- /bin/bash -i -c ':' >"$_tmp/s14.out" 2>"$_tmp/s14.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash: an interactive non-login shell loads the interactive plan once from .bashrc"
else
  fail "bash: an interactive non-login shell did not load the interactive plan"
fi
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/bash
_home_env "$_home" -- /bin/bash -c ':' >"$_tmp/s14b.out" 2>"$_tmp/s14b.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ] && [ ! -s "$_tmp/s14b.out" ] && [ ! -s "$_tmp/s14b.err" ]; then
  pass "bash -c stays silent and loads no interactive module"
else
  fail "bash -c printed output or loaded an interactive module"
fi

# Scenario 15: a user's login file that already sources .bashrc. The interactive
# plan must load exactly once: from .bashrc, with the login file's stage a no-op.
_reset_home "$_home"
printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n' >"$_home/.profile"
_install "$_tmp/release-a" "$_home" /bin/bash
_home_env "$_home" -- /bin/bash --login -i -c ':' >"$_tmp/s15.out" 2>"$_tmp/s15.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash login: a login file that sources .bashrc loads the interactive plan exactly once"
else
  fail "bash login: a login file that sources .bashrc loaded the interactive plan $(_marker_count "$_home/intdep.log") times"
fi

# Scenario 16: doctor. A fresh zsh install writes env-only blocks into .zprofile
# and .zshenv; those are current, so doctor must not call them a legacy shape.
# A genuine single-stage rc-file block (no interactivity gate) must still be
# reported.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" /bin/zsh
_home_env "$_home" SHELL=/bin/zsh -- "$_valise" doctor >"$_tmp/s16.out" 2>&1 || :
if grep -q 'legacy single-stage' "$_tmp/s16.out"; then
  fail "doctor reports a fresh install's env-only block as legacy"
  grep 'legacy' "$_tmp/s16.out" >&2
else
  pass "doctor reports no legacy block after a fresh zsh install"
fi
_reset_home "$_home"
printf '# BEGIN valise managed block\n: single stage\n# END valise managed block\n' >"$_home/.zshrc"
_home_env "$_home" SHELL=/bin/zsh -- "$_valise" doctor >"$_tmp/s16b.out" 2>&1 || :
# doctor exits nonzero via die on findings, so || : is expected here; what
# must NOT happen is a set -u unbound-variable crash before the footer.
if grep -q 'zshrc has a legacy single-stage block' "$_tmp/s16b.out" &&
  grep -q 'some checks failed' "$_tmp/s16b.out" &&
  ! grep -q 'unbound variable' "$_tmp/s16b.out"; then
  pass "doctor still reports a genuine single-stage rc-file block"
else
  fail "doctor did not report a genuine single-stage rc-file block"
  cat "$_tmp/s16b.out" >&2
fi

printf '\n%s: %d total, %d pass, %d fail, %d skip\n' "startup-state" "$_total" "$_pass" "$_fail" "$_skip"
[ "$_fail" -eq 0 ]
