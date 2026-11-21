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

# Every scenario below drives a real interpreter. Absence skips only the lanes
# that need that shell: a bash-only host still runs the bash and doctor
# scenarios, and each interpreter is resolved from PATH rather than guessed at
# /bin, because a Homebrew or /usr/local zsh is a perfectly normal install.
_zsh_bin=$(command -v zsh 2>/dev/null || :)
_bash_bin=$(command -v bash 2>/dev/null || :)
if [ -n "$_zsh_bin" ] && [ ! -x "$_zsh_bin" ]; then _zsh_bin=; fi
if [ -n "$_bash_bin" ] && [ ! -x "$_bash_bin" ]; then _bash_bin=; fi
if [ -z "$_zsh_bin" ]; then
  skip "zsh scenarios (env-only, rc-chain login, path_helper repair, dangling login file, legacy doctor): no zsh is installed"
fi
if [ -z "$_bash_bin" ]; then
  skip "bash scenarios (bash-only login file, dangling .bash_profile, bash stage 2): no bash is installed"
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

if [ -n "$_zsh_bin" ]; then
# Scenario 1: a required env module fails in .zshenv, and the dependent
# interactive module must not run in .zshrc. Strict is a control: the old code
# also blocked this case, so it must stay blocked.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
: >"$_home/envdep-fails"
_home_env "$_home" VALISE_MODE=strict -- "$_zsh_bin" -i -c ':' >"$_tmp/s1.out" 2>"$_tmp/s1.err" || :
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
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
: >"$_home/envdep-fails"
_home_env "$_home" VALISE_MODE=permissive -- "$_zsh_bin" -i -c ':' >"$_tmp/s2.out" 2>"$_tmp/s2.err" || :
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
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
: >"$_home/envopt-fails"
_home_env "$_home" VALISE_MODE=strict -- "$_zsh_bin" -i -c ':' >"$_tmp/s3.out" 2>"$_tmp/s3.err" || :
if [ "$(_marker_count "$_home/intopt.log")" -eq 0 ]; then
  pass "zsh strict: an optional env failure blocks its interactive dependent across files"
else
  fail "zsh strict: the interactive dependent of a failed optional env module ran across files"
fi

# Scenario 4: zsh login repair. .zshenv loads the env plan successfully and
# then makes envdep fail; the .zprofile repair pass re-runs the env plan and
# must record the failure, so .zshrc never runs the dependent.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
printf '\n: >"$HOME/envdep-fails"\n' >>"$_home/.zshenv"
_home_env "$_home" VALISE_MODE=strict -- "$_zsh_bin" -l -i -c ':' >"$_tmp/s4.out" 2>"$_tmp/s4.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "zsh login repair: a failed repair pass never lets the dependent run in .zshrc"
else
  fail "zsh login repair: the dependent ran after the repair pass failed its env dependency"
fi

# Scenario 5: control. With nothing failing, the interactive dependent runs
# exactly once in .zshrc, and a second read of the same release is a no-op.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
_home_env "$_home" -- "$_zsh_bin" -i -c ':' >"$_tmp/s5.out" 2>"$_tmp/s5.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "zsh healthy: the interactive dependent runs once in .zshrc"
else
  fail "zsh healthy: the interactive dependent did not run"
  cat "$_tmp/s5.err" >&2
fi
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
_home_env "$_home" -- "$_zsh_bin" -i -c '. "$HOME/.zshenv"; . "$HOME/.zshenv"' >/dev/null 2>&1 || :
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
_install "$_tmp/release-missing" "$_home" "$_zsh_bin"
_active=$(eval "$(grep '^_valise_active_link=' "$_home/.zshenv")"; printf '%s' "$_valise_active_link")
_rel_real=$(cd "$_active" && pwd -P)
chmod -R u+w "$_rel_real" 2>/dev/null || :
rm -f "$_rel_real/plans/zsh.sh"
_home_env "$_home" -- "$_zsh_bin" -i -c ':' >"$_tmp/s6.out" 2>"$_tmp/s6.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
  pass "a missing env plan file blocks the interactive stage"
else
  fail "the interactive stage ran although the env plan file was missing"
fi

# Scenario 7: a PATH helper entry must survive a user rc file that resets PATH
# after the managed block already ran in .zshenv. The later managed block sees
# the same release, so only a changed PATH can tell it to re-assert the plan.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
printf 'PATH=/usr/bin:/bin\nexport PATH\n' | cat - "$_home/.zshrc" >"$_home/.zshrc.new"
mv "$_home/.zshrc.new" "$_home/.zshrc"
_home_env "$_home" -- "$_zsh_bin" -i -c 'printf "%s\n" "${PATH%%:*}"' >"$_tmp/s7.out" 2>"$_tmp/s7.err" || :
if [ "$(head -n 1 "$_tmp/s7.out")" = "$_home/startup-toolbin" ]; then
  pass "zsh: a user rc file that resets PATH after the env plan does not lose the valise PATH entry"
else
  fail "zsh: a PATH reset in .zshrc dropped the valise PATH entry (first entry: $(head -n 1 "$_tmp/s7.out"))"
fi

# Scenario 8: control. A reread with an unchanged PATH runs no env body again.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
_home_env "$_home" -- "$_zsh_bin" -i -c '. "$HOME/.zshenv"; . "$HOME/.zshenv"' >/dev/null 2>&1 || :
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
_install "$_tmp/release-collide" "$_home" "$_zsh_bin"
_home_env "$_home" -- "$_zsh_bin" -i -c 'shared_fn' >"$_tmp/s9.out" 2>"$_tmp/s9.err" || :
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
_install "$_tmp/release-migrate-a" "$_home" "$_zsh_bin"
_active=$(_active_link_of "$_home")
_home_env "$_home" "MIG_B=$_tmp/release-migrate-b" "ACTIVE_LINK=$_active" -- "$_zsh_bin" -i -c \
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
_install "$_tmp/release-own-a" "$_home" "$_zsh_bin"
_active=$(_active_link_of "$_home")
_home_env "$_home" "OWN_B=$_tmp/release-own-b" "ACTIVE_LINK=$_active" -- "$_zsh_bin" -i -c \
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
_install "$_tmp/release-act-a" "$_home" "$_zsh_bin"
_active=$(_active_link_of "$_home")
# Return to A's INSTALLED release (its store directory and release id), which is
# how a real `valise release use` comes back to it.
_store_a=$(readlink "$_active")
_home_env "$_home" "ACT_A=$_store_a" "ACT_B=$_tmp/release-act-b" "ACTIVE_LINK=$_active" -- "$_zsh_bin" -i -c \
  'first=$(actmod_fn); ln -sfn "$ACT_B" "$ACTIVE_LINK"; . "$HOME/.zshenv"; . "$HOME/.zshrc"; second=$(actmod_fn); ln -sfn "$ACT_A" "$ACTIVE_LINK"; . "$HOME/.zshenv"; . "$HOME/.zshrc"; third=$(actmod_fn); printf "%s %s %s\n" "$first" "$second" "$third"' \
  >"$_tmp/s12.out" 2>"$_tmp/s12.err" || :
if [ "$(tail -n 1 "$_tmp/s12.out")" = "A-int B-env A-int" ]; then
  pass "A -> B -> A in one interactive shell returns the interactive function from A"
else
  fail "A -> B -> A returned the wrong implementation (got: $(tail -n 1 "$_tmp/s12.out"))"
fi


fi

if [ -n "$_bash_bin" ]; then
# Scenario 13: a fresh bash home (no login or rc files) with bash as the login
# shell. `bash --login -i` reads only the login file, never .bashrc, so the
# interactive plan must be reachable from that login file.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
_home_env "$_home" -- "$_bash_bin" --login -i -c ':' >"$_tmp/s13.out" 2>"$_tmp/s13.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash login: an interactive login shell reaches the interactive stage in a fresh home"
else
  fail "bash login: an interactive login shell did not load the interactive plan in a fresh home"
  cat "$_tmp/s13.err" >&2
fi

# A bash login can inherit ZSH_VERSION/KSH_VERSION from its parent and can be
# launched with shell options such as `verbose` enabled. The bash-login stage
# must still run: it gates on the running shell, and its POSIX-mode probe must
# not mistake `verbose on` after `posix off` for POSIX mode.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
_home_env "$_home" ZSH_VERSION=5.9 KSH_VERSION=1.0 SHELLOPTS=verbose \
  -- "$_bash_bin" --login -i -c ':' >"$_tmp/s13b.out" 2>"$_tmp/s13b.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash login with inherited shell versions and verbose option loads the interactive stage once"
else
  fail "bash login with inherited shell versions or verbose option skipped the interactive stage"
  cat "$_tmp/s13b.err" >&2
fi

# The same lane with a bash-ONLY witness: the startup bundle's intdep module is
# posix-class, so a wrong plan class (ksh/zsh) would still load it and pass
# silently. A bash-only module proves plans/bash*.sh actually ran: with
# KSH_VERSION inherited, the old version-variable precedence picked ksh, no
# bash plan existed, and the interactive module never loaded.
if [ -n "$_bash_bin" ]; then
  _bproj="$_tmp/project-bashonly"
  mkdir -p "$_bproj/module.d" "$_bproj/modules"
  : >"$_bproj/valise.conf"
  printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_bproj/variants.tsv"
  printf 'name=bashwitness\nversion=\nside_effect=read-only\nrequires=\noptional=\nshells=bash\nplatforms=any\nexports=\nload=modules/bashwitness.sh\nphase=interactive\n' >"$_bproj/module.d/bashwitness.meta"
  printf 'echo ran >>"$HOME/bashwitness.log"\n' >"$_bproj/modules/bashwitness.sh"
  printf '# bundle\tshell\troots\ndefault\tbash\tbashwitness\n' >"$_bproj/bundles.tsv"
  rm -rf "$_tmp/release-bashonly"
  (cd "$_bproj" && "$_valise" build "$_tmp/release-bashonly") >/dev/null 2>&1
  _reset_home "$_home"
  _install "$_tmp/release-bashonly" "$_home" "$_bash_bin"
  _home_env "$_home" KSH_VERSION=1.0 ZSH_VERSION=5.9 \
    -- "$_bash_bin" --login -i -c ':' >"$_tmp/s13c.out" 2>"$_tmp/s13c.err" || :
  if [ "$(_marker_count "$_home/bashwitness.log")" -eq 1 ]; then
    pass "bash login with inherited KSH_VERSION/ZSH_VERSION loads the bash-only interactive plan"
  else
    fail "bash login with inherited KSH_VERSION/ZSH_VERSION did not load the bash plan"
    cat "$_tmp/s13c.err" >&2
  fi

  # bash invoked as `sh` reads ~/.profile BEFORE enabling POSIX mode, so the
  # env-only stage must stay in effect there: the interactive module must NOT
  # load from .profile.
  _reset_home "$_home"
  _install "$_tmp/release-a" "$_home" "$_bash_bin"
  _sh_link="$_tmp/sh-as-sh"
  ln -sf "$_bash_bin" "$_sh_link"
  _home_env "$_home" -- "$_sh_link" -l -i -c ':' >"$_tmp/s13d.out" 2>"$_tmp/s13d.err" || :
  if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ]; then
    pass "bash invoked as sh stays on the env-only stage while reading the login file"
  else
    fail "bash invoked as sh ran the interactive stage during the login file"
    cat "$_tmp/s13d.err" >&2
  fi
fi

# A non-bash shell that inherits an exported BASH_VERSION must not be mistaken
# for native bash. zsh is the available non-bash login shell here.
if [ -n "$_zsh_bin" ]; then
  _reset_home "$_home"
  _install "$_tmp/release-a" "$_home" "$_zsh_bin"
  _home_env "$_home" BASH_VERSION=5.3.20 \
    -- "$_zsh_bin" -l -i -c ':' >"$_tmp/s13e.out" 2>"$_tmp/s13e.err" || :
  # zsh --login -i reads .zshrc, so the interactive plan SHOULD load exactly
  # once there - but only because the probe picked the zsh plan, not because
  # BASH_VERSION made the shell look native bash in .profile. The witness is
  # the plan class the block chose: the .zshenv block must carry the emulate
  # probe (zsh), and .profile must not have run stage 2 there. .profile DOES
  # carry the bash-login stage (the literal marker line) because install
  # writes it into the bash login file regardless of $SHELL; what matters is
  # that the gate evaluated false in zsh (no shopt), so stage 2 did not fire
  # from .profile. The intdep count of exactly 1 (loaded once, via .zshrc)
  # together with the zsh plan probe in .zshenv proves that.
  if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ] &&
    grep -q 'command -v emulate' "$_home/.zshenv" 2>/dev/null &&
    grep -q 'elif command -v emulate' "$_home/.profile" 2>/dev/null; then
    pass "zsh login with inherited BASH_VERSION is not treated as native bash"
  else
    fail "zsh login with inherited BASH_VERSION picked the wrong plan class or ran stage 2 in .profile"
    cat "$_tmp/s13e.err" >&2
    grep -n '_valise_plan=' "$_home/.zshenv" >&2 2>/dev/null || :
  fi
fi

# Scenario 14: control. A non-login interactive bash reads .bashrc, and a
# non-interactive `bash -c` stays silent and loads no interactive module.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
_home_env "$_home" -- "$_bash_bin" -i -c ':' >"$_tmp/s14.out" 2>"$_tmp/s14.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash: an interactive non-login shell loads the interactive plan once from .bashrc"
else
  fail "bash: an interactive non-login shell did not load the interactive plan"
fi
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
_home_env "$_home" -- "$_bash_bin" -c ':' >"$_tmp/s14b.out" 2>"$_tmp/s14b.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 0 ] && [ ! -s "$_tmp/s14b.out" ] && [ ! -s "$_tmp/s14b.err" ]; then
  pass "bash -c stays silent and loads no interactive module"
else
  fail "bash -c printed output or loaded an interactive module"
fi

# Scenario 15: a user's login file that already sources .bashrc. The interactive
# plan must load exactly once: from .bashrc, with the login file's stage a no-op.
_reset_home "$_home"
printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n' >"$_home/.profile"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
_home_env "$_home" -- "$_bash_bin" --login -i -c ':' >"$_tmp/s15.out" 2>"$_tmp/s15.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "bash login: a login file that sources .bashrc loads the interactive plan exactly once"
else
  fail "bash login: a login file that sources .bashrc loaded the interactive plan $(_marker_count "$_home/intdep.log") times"
fi
# The env plan must ALSO run exactly once in that login. A login bash does not
# set `l` in `$-` (measured), so the repair ticket cannot fire for bash and the
# rc-chain login must not double-run the env bodies.
if [ "$(_marker_count "$_home/envdep.count")" -eq 1 ]; then
  pass "bash login: a login file that sources .bashrc runs the env plan exactly once"
else
  fail "bash login: a login file that sources .bashrc ran the env plan $(_marker_count "$_home/envdep.count") times"
fi

fi

if [ -n "$_bash_bin" ]; then
# Scenario 16: a bash-only login file must carry the interactive stage even when
# $SHELL is not bash and there is no ~/.bashrc. Only bash reads .bash_profile, so
# stage 2 there is inert for every other shell, while leaving it env-only gave an
# interactive `bash --login -i` no interactive setup at all (bash ignores ENV).
_reset_home "$_home"
printf '# user profile\n' >"$_home/.bash_profile"
# This lane runs on a bash-only host too, where _zsh_bin is empty. install only
# uses $SHELL to choose which shell gets an rc file; pass a real value.
_install "$_tmp/release-a" "$_home" "${_zsh_bin:-$_bash_bin}"
if grep -q 'case \$- in \*i\*)' "$_home/.bash_profile" 2>/dev/null; then
  pass "zsh-default home: a bash-only login file carries the interactive stage"
else
  fail "zsh-default home: .bash_profile was left env-only, so an interactive login bash never reaches stage 2"
fi
_home_env "$_home" -- "$_bash_bin" --login -i -c ':' >"$_tmp/s18.out" 2>"$_tmp/s18.err" || :
if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
  pass "zsh-default home: bash --login -i reaches the interactive stage through .bash_profile"
else
  fail "zsh-default home: bash --login -i did not run the interactive module"
  cat "$_tmp/s18.err" >&2
fi

# Scenario 17: a DANGLING .bash_profile symlink is ignored by bash (stat returns
# ENOENT) and it falls back to .profile, so the block must land in .profile, not
# in a file bash never reads.
_reset_home "$_home"
ln -s /nonexistent-valise-target "$_home/.bash_profile"
_install "$_tmp/release-a" "$_home" "$_bash_bin"
if [ -f "$_home/.profile" ] && grep -q '# BEGIN valise managed block' "$_home/.profile" 2>/dev/null &&
  [ ! -e "$_home/.bash_profile" ]; then
  pass "a dangling .bash_profile symlink does not shadow .profile"
else
  fail "a dangling .bash_profile symlink was treated as the bash login file"
  ls -l "$_home/.bash_profile" "$_home/.profile" >&2 2>/dev/null || :
fi
fi

if [ -n "$_zsh_bin" ]; then
# Scenario 19: doctor. A fresh zsh install writes env-only blocks into .zprofile
# and .zshenv; those are current, so doctor must not call them a legacy shape.
# A genuine single-stage rc-file block (no interactivity gate) must still be
# reported, and so must one in an ENV-stage file: a 0.2-era block in .zshenv
# ran interactive setup in every `zsh -c`, which is the bug 0.3 fixed, and the
# gate heuristic alone cannot tell it from a current env-only block.
_reset_home "$_home"
_install "$_tmp/release-a" "$_home" "$_zsh_bin"
_home_env "$_home" SHELL="$_zsh_bin" -- "$_valise" doctor >"$_tmp/s19.out" 2>&1 || :
if grep -q 'legacy single-stage' "$_tmp/s19.out"; then
  fail "doctor reports a fresh install's env-only block as legacy"
  grep 'legacy' "$_tmp/s19.out" >&2
else
  pass "doctor reports no legacy block after a fresh zsh install"
fi
_reset_home "$_home"
printf '# BEGIN valise managed block\n: single stage\n# END valise managed block\n' >"$_home/.zshrc"
printf '# BEGIN valise managed block\n: single stage\n# END valise managed block\n' >"$_home/.zshenv"
_home_env "$_home" SHELL="$_zsh_bin" -- "$_valise" doctor >"$_tmp/s16b.out" 2>&1 || :
# doctor exits nonzero via die on findings, so || : is expected here; what
# must NOT happen is a set -u unbound-variable crash before the footer.
if grep -q 'zshrc has a legacy single-stage block' "$_tmp/s16b.out" &&
  grep -q 'zshenv has a legacy single-stage block' "$_tmp/s16b.out" &&
  grep -q 'some checks failed' "$_tmp/s16b.out" &&
  ! grep -q 'unbound variable' "$_tmp/s16b.out"; then
  pass "doctor reports a genuine single-stage rc-file block and one in an env-stage file"
else
  fail "doctor did not report a genuine single-stage block in every file"
  cat "$_tmp/s16b.out" >&2
fi
fi

# Scenario 20: fresh zsh-default home (no .bash_profile, no .bash_login, no
# .bashrc) must still load interactive modules in `bash --login -i` via the
# .profile fallback, without creating .bashrc.
if [ -n "$_bash_bin" ]; then
  _reset_home "$_home"
  _install "$_tmp/release-a" "$_home" "${_zsh_bin:-/bin/zsh}"
  if [ ! -e "$_home/.bashrc" ] && grep -q '_valise_bash_native' "$_home/.profile" 2>/dev/null; then
    pass "fresh zsh-default home: .profile carries bash-login stage without creating .bashrc"
  else
    fail "fresh zsh-default home: .profile missing bash-login stage or .bashrc was created"
  fi
  _home_env "$_home" -- "$_bash_bin" --login -i -c ':' >"$_tmp/s20.out" 2>"$_tmp/s20.err" || :
  if [ "$(_marker_count "$_home/intdep.log")" -eq 1 ]; then
    pass "fresh zsh-default home: bash --login -i loads interactive module exactly once"
  else
    fail "fresh zsh-default home: bash --login -i ran interactive module $(_marker_count "$_home/intdep.log") times"
    cat "$_tmp/s20.err" >&2
  fi
fi

# Scenario 21: startup must never adopt a foreign regular file or symlink at
# $XDG_CONFIG_HOME/valise/env.sh into ENV.
_reset_home "$_home"
mkdir -p "$_home/.config/valise"
printf 'printf "foreign-code-ran\\n"\n' >"$_home/.config/valise/env.sh"
_install "$_tmp/release-a" "$_home" "${_bash_bin:-/bin/sh}"
_s21_reg=$(_home_env "$_home" -- /bin/sh -c '
  unset ENV
  . "$HOME/.profile"
  printf "ENV=%s\n" "${ENV-unset}"
  /bin/sh -ic ":"
' 2>&1 || :)
if printf '%s\n' "$_s21_reg" | grep -Fx 'ENV=unset' >/dev/null &&
  ! printf '%s\n' "$_s21_reg" | grep -F 'foreign-code-ran' >/dev/null; then
  pass "startup refuses to adopt a foreign regular file as the ENV shim"
else
  fail "startup adopted or executed a foreign regular file as ENV shim"
  printf '%s\n' "$_s21_reg" >&2
fi

_reset_home "$_home"
mkdir -p "$_home/.config/valise"
printf '# BEGIN valise managed block\nprintf "symlink-code-ran\\n"\n# END valise managed block\n' >"$_tmp/foreign-shim-target.sh"
ln -s "$_tmp/foreign-shim-target.sh" "$_home/.config/valise/env.sh"
_install "$_tmp/release-a" "$_home" "${_bash_bin:-/bin/sh}"
_s21_sym=$(_home_env "$_home" -- /bin/sh -c '
  unset ENV
  . "$HOME/.profile"
  printf "ENV=%s\n" "${ENV-unset}"
  /bin/sh -ic ":"
' 2>&1 || :)
if printf '%s\n' "$_s21_sym" | grep -Fx 'ENV=unset' >/dev/null &&
  ! printf '%s\n' "$_s21_sym" | grep -F 'symlink-code-ran' >/dev/null; then
  pass "startup refuses to adopt a symlink as the ENV shim"
else
  fail "startup adopted or executed a symlink as ENV shim"
  printf '%s\n' "$_s21_sym" >&2
fi

# Scenario 22: A -> partially failed B -> A and A -> env-only B -> A must
# invalidate _valise_interactive_loaded so returning to A restores A's exports.
if [ -n "$_bash_bin" ]; then
  _pfa="$_tmp/proj-pf-a"
  _pfb="$_tmp/proj-pf-b"
  _pfc="$_tmp/proj-pf-c"
  for _pfd in "$_pfa" "$_pfb" "$_pfc"; do
    mkdir -p "$_pfd/module.d" "$_pfd/modules"
    : >"$_pfd/valise.conf"
    printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_pfd/variants.tsv"
    printf 'name=envbase\nversion=\nside_effect=read-only\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=\nload=modules/envbase.sh\n' >"$_pfd/module.d/envbase.meta"
    printf ': envbase\n' >"$_pfd/modules/envbase.sh"
  done
  # Release A: interactive intone (returns A) + inttwo (succeeds)
  printf 'name=intone\nversion=\nside_effect=read-only\nphase=interactive\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=review_value\nload=modules/intone.sh\n' >"$_pfa/module.d/intone.meta"
  printf 'review_value() { printf "A\\n"; }\n' >"$_pfa/modules/intone.sh"
  printf 'name=inttwo\nversion=\nside_effect=read-only\nphase=interactive\nrequires=intone\noptional=\nshells=posix\nplatforms=any\nexports=\nload=modules/inttwo.sh\n' >"$_pfa/module.d/inttwo.meta"
  printf ': ok\n' >"$_pfa/modules/inttwo.sh"
  printf '# bundle\tshell\troots\ndefault\tbash\tenvbase inttwo\ndefault\tzsh\tenvbase inttwo\n' >"$_pfa/bundles.tsv"
  # Release B: interactive intone (returns B) + inttwo (fails 42)
  printf 'name=intone\nversion=\nside_effect=read-only\nphase=interactive\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=review_value\nload=modules/intone.sh\n' >"$_pfb/module.d/intone.meta"
  printf 'review_value() { printf "B\\n"; }\n' >"$_pfb/modules/intone.sh"
  printf 'name=inttwo\nversion=\nside_effect=read-only\nphase=interactive\nrequires=intone\noptional=\nshells=posix\nplatforms=any\nexports=\nload=modules/inttwo.sh\n' >"$_pfb/module.d/inttwo.meta"
  printf 'return 42\n' >"$_pfb/modules/inttwo.sh"
  printf '# bundle\tshell\troots\ndefault\tbash\tenvbase inttwo\ndefault\tzsh\tenvbase inttwo\n' >"$_pfb/bundles.tsv"
  # Release C: intone moved to env phase (returns C)
  printf 'name=intone\nversion=\nside_effect=read-only\nphase=env\nrequires=\noptional=\nshells=posix\nplatforms=any\nexports=review_value\nload=modules/intone.sh\n' >"$_pfc/module.d/intone.meta"
  printf 'review_value() { printf "C\\n"; }\n' >"$_pfc/modules/intone.sh"
  printf '# bundle\tshell\troots\ndefault\tbash\tenvbase intone\ndefault\tzsh\tenvbase intone\n' >"$_pfc/bundles.tsv"

  rm -rf "$_tmp/rel-pf-a" "$_tmp/rel-pf-b" "$_tmp/rel-pf-c"
  (cd "$_pfa" && "$_valise" build "$_tmp/rel-pf-a") >/dev/null 2>&1
  (cd "$_pfb" && "$_valise" build "$_tmp/rel-pf-b") >/dev/null 2>&1
  (cd "$_pfc" && "$_valise" build "$_tmp/rel-pf-c") >/dev/null 2>&1

  _reset_home "$_home"
  printf '# user\n' >"$_home/.bash_profile"
  _install "$_tmp/rel-pf-b" "$_home" "$_bash_bin"
  _pf_b_id=$(basename "$(readlink "$_home/.config/valise/active")")
  _install "$_tmp/rel-pf-c" "$_home" "$_bash_bin"
  _pf_c_id=$(basename "$(readlink "$_home/.config/valise/active")")
  _install "$_tmp/rel-pf-a" "$_home" "$_bash_bin"
  _pf_a_id=$(basename "$(readlink "$_home/.config/valise/active")")

  _s22_out=$(_home_env "$_home" -- "$_bash_bin" -i -c '
    . "$HOME/.bashrc"
    printf "initial=%s\n" "$(review_value)"
    "'"$_valise"'" release use "'"$_pf_b_id"'" >/dev/null 2>&1
    . "$HOME/.bashrc" 2>/dev/null
    printf "failed_B=%s\n" "$(review_value)"
    "'"$_valise"'" release rollback >/dev/null 2>&1
    . "$HOME/.bashrc"
    printf "rollback_A=%s\n" "$(review_value)"
    "'"$_valise"'" release use "'"$_pf_c_id"'" >/dev/null 2>&1
    . "$HOME/.profile"
    printf "envonly_C=%s\n" "$(review_value)"
    "'"$_valise"'" release use "'"$_pf_a_id"'" >/dev/null 2>&1
    . "$HOME/.bashrc"
    printf "back_from_C=%s\n" "$(review_value)"
  ' 2>/dev/null || :)
  if printf '%s\n' "$_s22_out" | grep -Fx 'initial=A' >/dev/null &&
    printf '%s\n' "$_s22_out" | grep -Fx 'failed_B=B' >/dev/null &&
    printf '%s\n' "$_s22_out" | grep -Fx 'rollback_A=A' >/dev/null &&
    printf '%s\n' "$_s22_out" | grep -Fx 'envonly_C=C' >/dev/null &&
    printf '%s\n' "$_s22_out" | grep -Fx 'back_from_C=A' >/dev/null; then
    pass "interactive success marker is invalidated across partially failed and env-only release switches"
  else
    fail "interactive reload retained stale definitions after failed or env-only switch"
    printf '%s\n' "$_s22_out" >&2
  fi
fi

printf '\n%s: %d total, %d pass, %d fail, %d skip\n' "startup-state" "$_total" "$_pass" "$_fail" "$_skip"
[ "$_fail" -eq 0 ]
