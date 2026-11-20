#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Install lifecycle: preflight before the active release changes, restoring
# the previous release when a later step fails, release rollback, uninstall,
# apply --dry-run, and detection of valise loaded outside a managed block.
# Every scenario runs in a private home.

set -eu

_total=0
_skip=0
_pass=0
_fail=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); _skip=$((_skip + 1)); printf '  SKIP: %s\n' "$1"; }

# _find_count <dir> <name-pattern>: print how many paths match. A bare
# `! find ... -print -quit | grep -q .` is vacuously TRUE when find itself
# fails (a bad directory, a missing utility), which turns a broken check into
# a pass. This counts the matches and prints ERROR when find fails, so the
# caller's numeric comparison can never succeed by accident.
_find_count() {
  _fc_dir=$1
  _fc_name=$2
  _fc_out=$(find "$_fc_dir" -name "$_fc_name" -print 2>&1)
  _fc_rc=$?
  if [ "$_fc_rc" -ne 0 ]; then
    printf 'find failed (%s): %s\n' "$_fc_rc" "$_fc_out" >&2
    printf 'ERROR\n'
    return 0
  fi
  printf '%s\n' "$_fc_out" | grep -c . || :
}

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise="$_repo/bin/valise"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-lifecycle.XXXXXX")
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

_home=
_bin_override=

# _use_home <name>: switch every later valise call to a new private home.
# The ENV shim path is derived here too: a test that switches homes and then
# wrote to a shim captured from the PREVIOUS home would assert against a file
# the command under test never touched.
_use_home() {
  _home="$_tmp/$1"
  mkdir -p "$_home"
  _shim="$_home/.config/valise/env.sh"
}

# _v <project> <args...>: valise against a project with the current home.
_v() {
  _v_project=$1
  shift
  env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/bash \
    ${_bin_override:+VALISE_BIN_DIR="$_bin_override"} \
    "$_valise" -C "$_v_project" "$@"
}

# _mode <path>: the permission bits as octal, on GNU and BSD stat.
_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

_active_id() {
  _ai=$(cd "$_home/.config/valise/active" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "${_ai##*/}"
}

# _snapshot <dir>: every path under dir with its type, mode, and content digest.
_snapshot() {
  (
    cd "$1"
    find . | LC_ALL=C sort | while IFS= read -r _p; do
      if [ -L "$_p" ]; then
        printf '%s link %s\n' "$_p" "$(readlink "$_p")"
      elif [ -f "$_p" ]; then
        printf '%s file %s %s\n' "$_p" "$(ls -ld "$_p" | awk '{ print $1 }')" "$(cksum <"$_p")"
      else
        printf '%s dir %s\n' "$_p" "$(ls -ld "$_p" | awk '{ print $1 }')"
      fi
    done
  )
}

printf '=== valise install lifecycle ===\n'
printf '  scratch: %s\n\n' "$_tmp"

# A project whose default variant publishes the command hello and whose lean
# variant does not.
_proj="$_tmp/proj"
mkdir -p "$_proj/module.d" "$_proj/modules"
printf '%s\n' 'bundle=default' 'variant=default' >"$_proj/valise.conf"
printf '%s\n' 'name=main' 'side_effect=read-only' 'shells=posix' 'platforms=any' \
  'exports=main_ready' 'load=modules/main.sh' >"$_proj/module.d/main.meta"
printf 'main_ready() { :; }\n' >"$_proj/modules/main.sh"
printf '%s\n' 'name=tool_hello' 'side_effect=read-only' 'shells=posix' 'platforms=any' \
  'exports=hello' 'commands=hello' 'load=modules/hello.sh' >"$_proj/module.d/tool_hello.meta"
printf 'hello() { echo hello-from-valise; }\n' >"$_proj/modules/hello.sh"
{
  printf 'bundle\tshell\troots\n'
  for _s in sh bash zsh ksh; do printf 'default\t%s\tmain tool_hello\n' "$_s"; done
} >"$_proj/bundles.tsv"
printf 'variant\tdescription\texcluded\ndefault\tall\t\nlean\tno hello\ttool_hello\n' >"$_proj/variants.tsv"

# --- Preflight ---

_use_home preflight
printf '# BEGIN valise managed block\necho half a block\n' >"$_home/.zprofile"
if _v "$_proj" apply >/dev/null 2>"$_tmp/preflight.err"; then
  fail "an unpaired marker stops the first install before anything is active"
elif grep -F "unpaired valise managed block markers in $_home/.zprofile" "$_tmp/preflight.err" >/dev/null &&
  [ ! -e "$_home/.config/valise/active" ] && [ ! -L "$_home/.config/valise/active" ] &&
  [ ! -e "$_home/.profile" ] && [ ! -e "$_home/.local/bin/hello" ]; then
  pass "an unpaired marker stops the first install before anything is active"
else
  fail "an unpaired marker stops the first install before anything is active"
  cat "$_tmp/preflight.err" >&2
fi
rm -f "$_home/.zprofile"
_v "$_proj" apply --variant=lean >/dev/null 2>&1
_lean_id=$(_active_id)
printf '# BEGIN valise managed block\n' >>"$_home/.profile"
if _v "$_proj" apply >/dev/null 2>"$_tmp/preflight2.err"; then
  fail "an unpaired marker stops a later install with the active release unchanged"
elif [ "$(_active_id)" = "$_lean_id" ] && [ ! -e "$_home/.local/state/valise/previous" ]; then
  pass "an unpaired marker stops a later install with the active release unchanged"
else
  fail "an unpaired marker stops a later install with the active release unchanged"
  cat "$_tmp/preflight2.err" >&2
fi

_have_fish=0
for _f in /opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish /bin/fish; do
  [ ! -x "$_f" ] || _have_fish=1
done
if [ "$_have_fish" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  _use_home fishdir
  mkdir -p "$_home/.config/fish/conf.d"
  chmod 555 "$_home/.config/fish/conf.d"
  if _v "$_proj" apply >/dev/null 2>"$_tmp/fishdir.err"; then
    fail "an unwritable Fish hook directory stops install before anything changes"
  elif grep -F "cannot write the Fish hook in $_home/.config/fish/conf.d" "$_tmp/fishdir.err" >/dev/null &&
    [ ! -L "$_home/.config/valise/active" ] && [ ! -e "$_home/.local/share/valise/releases" ] &&
    [ ! -e "$_home/.profile" ]; then
    pass "an unwritable Fish hook directory stops install before anything changes"
  else
    fail "an unwritable Fish hook directory stops install before anything changes"
    cat "$_tmp/fishdir.err" >&2
  fi
  chmod 755 "$_home/.config/fish/conf.d"
elif [ "$_have_fish" -eq 1 ]; then
  printf '  SKIP: Fish hook directory preflight (chmod 555 is ineffective for uid 0)\n'
else
  printf '  SKIP: Fish hook directory preflight (no trusted fish)\n'
fi

_use_home bindir
: >"$_tmp/not-a-dir"
mkdir -p "$_tmp/ro-bin"
chmod 555 "$_tmp/ro-bin"
for _bad in "$_tmp/not-a-dir/bin" "$_tmp/ro-bin/bin"; do
  if [ "$(id -u)" -eq 0 ] && [ "$_bad" = "$_tmp/ro-bin/bin" ]; then
    printf '  SKIP: unwritable command directory preflight for %s (chmod 555 is ineffective for uid 0)\n' "$_bad"
    continue
  fi
  _bin_override=$_bad
  if _v "$_proj" apply >/dev/null 2>"$_tmp/bindir.err"; then
    fail "an unusable command directory stops install before anything changes ($_bad)"
  elif grep -F 'command stubs' "$_tmp/bindir.err" >/dev/null &&
    [ ! -L "$_home/.config/valise/active" ] && [ ! -e "$_home/.local/share/valise/releases" ] &&
    [ ! -e "$_home/.profile" ] && [ ! -e "$_home/.bashrc" ]; then
    pass "an unusable command directory stops install before anything changes ($_bad)"
  else
    fail "an unusable command directory stops install before anything changes ($_bad)"
    cat "$_tmp/bindir.err" >&2
  fi
done
_bin_override=
chmod 755 "$_tmp/ro-bin"

# --- A failure after the switch restores the previous release ---

_use_home txn
_v "$_proj" apply --variant=lean >/dev/null 2>&1
_lean_id=$(_active_id)
_profile_before=$(cksum <"$_home/.profile")
# The command ledger path is a directory, which preflight does not inspect,
# so publishing hello fails after the active link has moved.
_ledger="$_home/.local/state/valise/commands.tsv"
rm -f "$_ledger"
mkdir -p "$_ledger/x"
_txn_rc=0
_v "$_proj" apply >/dev/null 2>"$_tmp/txn.err" || _txn_rc=$?
rm -rf "$_ledger"
if [ "$_txn_rc" -eq 0 ]; then
  fail "a failure after the switch leaves the previous release active"
elif [ "$(_active_id)" = "$_lean_id" ] &&
  grep -F "install failed; the active release is back to $_lean_id" "$_tmp/txn.err" >/dev/null &&
  [ ! -e "$_home/.local/state/valise/previous" ] &&
  [ "$(cksum <"$_home/.profile")" = "$_profile_before" ]; then
  pass "a failure after the switch leaves the previous release active"
else
  fail "a failure after the switch leaves the previous release active"
  cat "$_tmp/txn.err" >&2
fi
_use_home txn-first
mkdir -p "$_home/.local/state/valise/commands.tsv/x"
_txn_rc=0
_v "$_proj" apply >/dev/null 2>"$_tmp/txn-first.err" || _txn_rc=$?
rm -rf "$_home/.local/state/valise/commands.tsv"
if [ "$_txn_rc" -eq 0 ]; then
  fail "a failed first install leaves no active release"
elif [ ! -e "$_home/.config/valise/active" ] && [ ! -L "$_home/.config/valise/active" ] &&
  grep -F 'install failed; no release is active, as before the install' "$_tmp/txn-first.err" >/dev/null &&
  grep -F 'already updated (they load whichever release is active):' "$_tmp/txn-first.err" |
  grep -F " $_home/.profile" >/dev/null; then
  pass "a failed first install leaves no active release and names the files it wrote"
else
  fail "a failed first install leaves no active release and names the files it wrote"
  cat "$_tmp/txn-first.err" >&2
fi

# --- Rollback ---

_use_home rollback
if _v "$_proj" release rollback >/dev/null 2>"$_tmp/rb-none.err"; then
  fail "rollback with no recorded release fails"
elif grep -F 'no previous release is recorded' "$_tmp/rb-none.err" >/dev/null; then
  pass "rollback with no recorded release fails"
else
  fail "rollback with no recorded release fails"
fi
_v "$_proj" apply >/dev/null 2>&1
_full_id=$(_active_id)
_v "$_proj" apply --variant=lean >/dev/null 2>&1
_lean_id=$(_active_id)
if [ "$_full_id" != "$_lean_id" ] && [ ! -e "$_home/.local/bin/hello" ] &&
  _v "$_proj" release rollback >"$_tmp/rb.out" 2>&1 &&
  [ "$(_active_id)" = "$_full_id" ] &&
  [ "$(env -i PATH="$_home/.local/bin:/usr/bin:/bin" hello)" = hello-from-valise ]; then
  pass "release rollback returns to the previous release and publishes its commands"
else
  fail "release rollback returns to the previous release and publishes its commands"
  cat "$_tmp/rb.out" >&2 || :
fi
if _v "$_proj" release rollback >/dev/null 2>&1 && [ "$(_active_id)" = "$_lean_id" ] &&
  [ ! -e "$_home/.local/bin/hello" ]; then
  pass "a second rollback returns to the release rolled back from"
else
  fail "a second rollback returns to the release rolled back from"
fi
chmod u+w "$_home/.local/share/valise/releases/$_full_id/plans" \
  "$_home/.local/share/valise/releases/$_full_id/plans/sh.sh"
printf '# tampered\n' >>"$_home/.local/share/valise/releases/$_full_id/plans/sh.sh"
if _v "$_proj" release rollback >/dev/null 2>&1; then
  fail "rollback refuses a release that fails verification"
elif [ "$(_active_id)" = "$_lean_id" ]; then
  pass "rollback refuses a release that fails verification"
else
  fail "rollback refuses a release that fails verification"
fi

# --- Uninstall ---

_use_home uninstall
printf 'export FROM_USER=1\n' >"$_home/.profile"
chmod 0400 "$_home/.profile"
printf '# zsh login\nexport Z=1\n' >"$_home/.zprofile"
mkdir -p "$_home/.local/bin" "$_home/.config/fish/conf.d"
printf '#!/bin/sh\necho mine\n' >"$_home/.local/bin/mytool"
printf '# my fish config\n' >"$_home/.config/fish/conf.d/mine.fish"
_before=$(_snapshot "$_home")
_v "$_proj" apply >/dev/null 2>&1
if grep -Fx '# BEGIN valise managed block' "$_home/.profile" "$_home/.bashrc" "$_home/.zprofile" >/dev/null &&
  [ -x "$_home/.local/bin/hello" ]; then
  pass "apply wrote the blocks and the command stub uninstall must remove"
else
  fail "apply wrote the blocks and the command stub uninstall must remove"
fi
if _v "$_proj" uninstall >"$_tmp/un.out" 2>&1; then
  _after=$(_snapshot "$_home")
  # Directories install created for its own files may remain; files may not.
  _missing=$(printf '%s\n' "$_before" | while IFS= read -r _line; do
    printf '%s\n' "$_after" | grep -Fx -- "$_line" >/dev/null || printf '%s\n' "$_line"
  done)
  _extra=$(printf '%s\n' "$_after" | while IFS= read -r _line; do
    case "$_line" in (*' dir '*) continue ;; esac
    printf '%s\n' "$_before" | grep -Fx -- "$_line" >/dev/null || printf '%s\n' "$_line"
  done)
  if [ -z "$_missing" ] && [ -z "$_extra" ]; then
    pass "uninstall restores every startup file byte for byte and mode for mode, and removes only what valise wrote"
  else
    fail "uninstall restores every startup file byte for byte and mode for mode, and removes only what valise wrote"
    printf 'missing or changed:\n%s\nextra:\n%s\n' "$_missing" "$_extra" >&2
    cat "$_tmp/un.out" >&2
  fi
else
  fail "uninstall succeeds"
  cat "$_tmp/un.out" >&2
fi
if [ ! -e "$_home/.local/share/valise/releases" ] && [ ! -e "$_home/.config/valise" ] &&
  [ ! -e "$_home/.local/state/valise" ]; then
  pass "uninstall removes the releases, the active link, and the valise state"
else
  fail "uninstall removes the releases, the active link, and the valise state"
  ls -laR "$_home/.local/share/valise" "$_home/.config/valise" "$_home/.local/state/valise" >&2 2>/dev/null || :
fi

_use_home uninstall-keep
_v "$_proj" apply >/dev/null 2>&1
_kept_id=$(_active_id)
printf 'echo edited\n' >"$_tmp/edited-stub"
chmod 0755 "$_tmp/edited-stub"
cp "$_tmp/edited-stub" "$_home/.local/bin/hello"
if _v "$_proj" uninstall --keep-releases >"$_tmp/keep.out" 2>&1 &&
  [ -d "$_home/.local/share/valise/releases/$_kept_id" ] &&
  [ ! -L "$_home/.config/valise/active" ] &&
  cmp -s "$_home/.local/bin/hello" "$_tmp/edited-stub" &&
  grep -F "command stub was changed outside valise; leaving it: $_home/.local/bin/hello" "$_tmp/keep.out" >/dev/null; then
  pass "uninstall --keep-releases keeps the releases and leaves an edited stub"
else
  fail "uninstall --keep-releases keeps the releases and leaves an edited stub"
  cat "$_tmp/keep.out" >&2
fi
if _v "$_proj" uninstall >/dev/null 2>&1; then
  pass "uninstall with nothing installed succeeds"
else
  fail "uninstall with nothing installed succeeds"
fi

_use_home uninstall-unpaired
_v "$_proj" apply >/dev/null 2>&1
printf '# BEGIN valise managed block\n' >>"$_home/.bashrc"
_bashrc=$(cksum <"$_home/.bashrc")
if _v "$_proj" uninstall >/dev/null 2>"$_tmp/un-unpaired.err"; then
  fail "uninstall stops on unpaired markers with nothing removed"
elif [ -L "$_home/.config/valise/active" ] && [ "$(cksum <"$_home/.bashrc")" = "$_bashrc" ] &&
  grep -Fx '# BEGIN valise managed block' "$_home/.profile" >/dev/null &&
  [ -e "$_home/.local/bin/hello" ]; then
  pass "uninstall stops on unpaired markers with nothing removed"
else
  fail "uninstall stops on unpaired markers with nothing removed"
fi

_use_home nonl
printf 'export FOO=1\n# user line\nno newline at end' >"$_home/.zshrc"
chmod 600 "$_home/.zshrc"
cp -p "$_home/.zshrc" "$_tmp/zshrc.orig"
_v "$_proj" apply >/dev/null 2>&1
_v "$_proj" apply >/dev/null 2>&1
if grep -Fx 'no newline at end' "$_home/.zshrc" >/dev/null &&
  _v "$_proj" uninstall >"$_tmp/nonl.out" 2>&1 && cmp -s "$_tmp/zshrc.orig" "$_home/.zshrc" &&
  [ "$(_mode "$_home/.zshrc")" = 600 ]; then
  pass "uninstall restores a startup file whose last line had no newline"
else
  fail "uninstall restores a startup file whose last line had no newline"
  od -c "$_home/.zshrc" | tail -3 >&2
fi

# Text after an existing block keeps the file's ending: re-applying changes
# nothing and uninstall restores the file exactly.
_use_home nonl-after
_v "$_proj" apply >/dev/null 2>&1
printf 'tail-no-nl' >>"$_home/.bashrc"
cp -p "$_home/.bashrc" "$_tmp/bashrc.edited"
_v "$_proj" apply >"$_tmp/nonl-after.out" 2>&1
if cmp -s "$_tmp/bashrc.edited" "$_home/.bashrc" &&
  grep -F "shell integration current: $_home/.bashrc" "$_tmp/nonl-after.out" >/dev/null; then
  pass "re-applying leaves text after the block without a final newline unchanged"
else
  fail "re-applying leaves text after the block without a final newline unchanged"
  od -c "$_home/.bashrc" | tail -3 >&2
fi
printf 'export A=1\nbefore\n' >"$_home/.zshrc"
cp -p "$_home/.zshrc" "$_tmp/zshrc.plain"
_v "$_proj" apply >/dev/null 2>&1
printf 'after' >>"$_home/.zshrc"
_v "$_proj" uninstall >/dev/null 2>&1
if [ "$(od -c "$_home/.zshrc")" = "$(printf 'export A=1\nbefore\nafter' | od -c)" ]; then
  pass "uninstall keeps text after the block without a final newline"
else
  fail "uninstall keeps text after the block without a final newline"
  od -c "$_home/.zshrc" | tail -3 >&2
fi

# --- ENV shim deploy, user-owned ENV, and uninstall removal ---

_use_home envshim
_v "$_proj" apply >/dev/null 2>&1
_shim="$_home/.config/valise/env.sh"
# The shim is the RC-STAGE entry point for sh/ksh interactive subshells, so it
# carries BOTH stages; ~/.profile is an env-stage file and must carry only
# stage 1, because interactive setup belongs in the shell's rc file. The ENV
# stanza names the shim in both.
if [ -f "$_shim" ] &&
  grep -q '# BEGIN valise managed block' "$_shim" &&
  grep -q 'case \$- in \*i\*)' "$_shim" &&
  grep -qF "ENV='$_shim'" "$_shim" &&
  [ "$(_mode "$_shim")" = 644 ]; then
  pass "apply deploys a two-stage ENV shim naming itself"
else
  fail "apply did not deploy a correct ENV shim"
  ls -l "$_shim" >&2 2>/dev/null || :
  cat "$_shim" >&2 2>/dev/null || :
fi
# The harness home is a bash login (SHELL=/bin/bash), and a login bash reads
# only .profile, so .profile carries the interactive stage as well as stage 1
# and the ENV stanza. A non-bash login file is covered by the e2e stage lanes.
if grep -q '# BEGIN valise managed block' "$_home/.profile" &&
  grep -q 'case \$- in \*i\*)' "$_home/.profile" &&
  grep -qF "ENV='$_shim'" "$_home/.profile"; then
  pass "~/.profile carries the interactive stage as the bash login file and wires ENV at the shim"
else
  fail "~/.profile does not carry the interactive stage and the ENV stanza"
  cat "$_home/.profile" >&2 2>/dev/null || :
fi
# A bash/zsh install must produce the same wiring: the harness runs
# SHELL=/bin/bash, so this is the case that used to be silently missing.
_use_home envshim-bash
( cd "$_proj" && env -i HOME="$_home" PATH=/usr/bin:/bin \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/bash "$_valise" apply ) >/dev/null 2>&1
# The ENV stanza is unconditional: bash ignores ENV when invoked as bash and
# READS it when invoked as `sh`, so gating on the plan class excluded a shell
# that needs it.
if grep -qF "ENV='$_home/.config/valise/env.sh'" "$_home/.profile" &&
  ! grep -q 'case "$_valise_plan" in' "$_home/.profile" &&
  [ -f "$_home/.config/valise/env.sh" ]; then
  pass "installing under bash wires ENV unconditionally for an sh login shell"
else
  fail "installing under bash did not wire ENV unconditionally"
  grep -n 'ENV' "$_home/.profile" >&2
fi
# A user-owned $ENV file is never overwritten: the block only sets ENV when
# the current value is empty, contains a '$' (the shell expands it), or names
# no existing file.
printf 'export USER_ENV=1\n' >"$_tmp/user-env.sh"
( cd "$_proj" && env -i HOME="$_home" PATH=/usr/bin:/bin ENV="$_tmp/user-env.sh" \
    XDG_DATA_HOME="$_home/.local/share" XDG_CONFIG_HOME="$_home/.config" \
    XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh "$_valise" apply ) >/dev/null 2>&1
if [ "$(cksum <"$_tmp/user-env.sh")" = "$(printf 'export USER_ENV=1\n' | cksum)" ]; then
  pass "a user-owned \$ENV file is left untouched"
else
  fail "a user-owned \$ENV file was modified"
fi
# A non-valise file at the shim path is left in place with a warning.
_use_home envshim-owned
mkdir -p "$_home/.config/valise"
printf 'export MINE=1\n' >"$_home/.config/valise/env.sh"
_v "$_proj" apply >"$_tmp/env-owned.out" 2>&1
if [ "$(cksum <"$_home/.config/valise/env.sh")" = "$(printf 'export MINE=1\n' | cksum)" ] &&
  grep -F "leaving $_home/.config/valise/env.sh: it is not the valise ENV shim" "$_tmp/env-owned.out" >/dev/null; then
  pass "a user-owned shim file is left in place with a warning"
else
  fail "a user-owned shim file was overwritten"
  cat "$_tmp/env-owned.out" >&2
fi
# Uninstall removes the valise-owned shim, and leaves a foreign one alone.
_use_home envshim
_v "$_proj" uninstall >"$_tmp/env-un.out" 2>&1
if [ ! -e "$_shim" ]; then
  pass "uninstall removes the valise ENV shim"
else
  fail "uninstall did not remove the valise ENV shim"
  cat "$_tmp/env-un.out" >&2
fi
_v "$_proj" apply >/dev/null 2>&1
printf 'export MINE=2\n' >"$_shim"
_v "$_proj" uninstall >"$_tmp/env-un2.out" 2>&1
if [ -f "$_shim" ] && grep -F "leaving $_shim: it is not the valise ENV shim" "$_tmp/env-un2.out" >/dev/null; then
  pass "uninstall leaves a user-owned shim in place with a warning"
else
  fail "uninstall did not leave a user-owned shim alone"
  cat "$_tmp/env-un2.out" >&2
fi
# User content appended BELOW the managed block survives both apply and
# uninstall: the shim is a managed startup file, not a valise-owned whole file.
_use_home envshim-user-content
_v "$_proj" apply >/dev/null 2>&1
printf '%s\n' '# the user owns this line' 'export USER_APPENDED=1' >>"$_shim"
_v "$_proj" apply >/dev/null 2>&1
if grep -qx 'export USER_APPENDED=1' "$_shim" >/dev/null 2>&1; then
  pass "re-applying keeps user content below the shim block"
else
  fail "re-applying discarded user content below the shim block"
  cat "$_shim" >&2
fi
_v "$_proj" uninstall >/dev/null 2>&1
if [ -f "$_shim" ] && grep -qx 'export USER_APPENDED=1' "$_shim" &&
  ! grep -q '# BEGIN valise managed block' "$_shim"; then
  pass "uninstall strips the shim block and keeps user content below it"
else
  fail "uninstall did not preserve user content below the shim block"
  cat "$_shim" >&2 2>/dev/null || :
fi
# A DAMAGED shim must stop uninstall with nothing modified. The shim is a
# managed startup file, so it gets the same paired-marker pre-check every
# startup file gets: before that, an unpaired BEGIN swallowed every line after
# it (including the user's own) and, because install had created the file, the
# emptied shim was then deleted.
_use_home envshim-damaged
_v "$_proj" apply >/dev/null 2>&1
printf '%s\n' '# the user owns this line' 'export USER_VALUE=must_survive' >>"$_shim"
_before_profile=$(cksum <"$_home/.profile")
# Remove only the END marker, leaving BEGIN unmatched and user content below.
_grep_path=$(command -v grep)
"$_grep_path" -v '^# END valise managed block$' "$_shim" >"$_tmp/shim-damaged" || :
cat "$_tmp/shim-damaged" >"$_shim"
_shim_damaged=$(cksum <"$_shim")
if _v "$_proj" uninstall >/dev/null 2>"$_tmp/un-damaged.err"; then
  fail "uninstall stops on a damaged ENV shim with nothing removed (it succeeded)"
elif [ -f "$_shim" ] && [ "$(cksum <"$_shim")" = "$_shim_damaged" ] &&
  "$_grep_path" -qx 'export USER_VALUE=must_survive' "$_shim" &&
  [ "$(cksum <"$_home/.profile")" = "$_before_profile" ] &&
  [ -L "$_home/.config/valise/active" ]; then
  pass "uninstall stops on a damaged ENV shim with nothing removed"
else
  fail "uninstall stops on a damaged ENV shim with nothing removed"
  cat "$_tmp/un-damaged.err" >&2
  [ ! -f "$_shim" ] || cat "$_shim" >&2
fi

# A file that merely MENTIONS the marker in prose is not valise-owned: the
# marker test is a whole-line match, so it must be left completely alone.
_use_home envshim-prose
mkdir -p "$_home/.config/valise"
printf '%s\n' '# my notes: the tool writes # BEGIN valise managed block here' 'export PROSE=1' \
  >"$_home/.config/valise/env.sh"
cp "$_home/.config/valise/env.sh" "$_tmp/shim-prose.orig"
_v "$_proj" apply >"$_tmp/env-prose.out" 2>&1
if cmp -s "$_home/.config/valise/env.sh" "$_tmp/shim-prose.orig" &&
  grep -F "leaving $_home/.config/valise/env.sh: it is not the valise ENV shim" "$_tmp/env-prose.out" >/dev/null; then
  pass "a file that only mentions the marker in prose is left alone"
else
  fail "a prose marker mention was treated as valise-owned"
  cat "$_tmp/env-prose.out" >&2
  cat "$_home/.config/valise/env.sh" >&2
fi

# --- zshenv target ---

_use_home zshenv
_v "$_proj" apply >/dev/null 2>&1
# zsh is installed on this host class list only when present; the .zshenv
# target is emitted when zsh exists OR the file exists. Force the file to
# exist case by pre-creating it, then re-apply.
if command -v zsh >/dev/null 2>&1; then
  if [ -f "$_home/.zshenv" ] && grep -q '# BEGIN valise managed block' "$_home/.zshenv"; then
    pass "apply writes the managed block to ~/.zshenv when zsh is installed"
  else
    fail "apply did not write the managed block to ~/.zshenv"
    ls -l "$_home/.zshenv" >&2 2>/dev/null || :
  fi
else
  printf 'export ZPRE=1\n' >"$_home/.zshenv"
  _v "$_proj" apply >/dev/null 2>&1
  if grep -q '# BEGIN valise managed block' "$_home/.zshenv" &&
    grep -q 'export ZPRE=1' "$_home/.zshenv"; then
    pass "apply writes the managed block to an existing ~/.zshenv"
  else
    fail "apply did not add the block to an existing ~/.zshenv"
  fi
  _v "$_proj" uninstall >/dev/null 2>&1
  if [ "$(cat "$_home/.zshenv" 2>/dev/null)" = 'export ZPRE=1' ]; then
    pass "uninstall removes the block from ~/.zshenv leaving prior content intact"
  else
    fail "uninstall did not restore ~/.zshenv exactly"
    cat "$_home/.zshenv" >&2 2>/dev/null || :
  fi
fi


# --- apply --dry-run ---

_use_home dryrun
printf 'export KEEP=1\n' >"$_home/.profile"
_before=$(_snapshot "$_home")
if _v "$_proj" apply --dry-run >"$_tmp/dry.out" 2>&1 && [ "$(_snapshot "$_home")" = "$_before" ] &&
  grep -F '  would install to ' "$_tmp/dry.out" >/dev/null &&
  grep -F '  would become active (now: none)' "$_tmp/dry.out" >/dev/null &&
  grep -F "  would update: $_home/.profile" "$_tmp/dry.out" >/dev/null &&
  grep -F "  would create: $_home/.bashrc" "$_tmp/dry.out" >/dev/null &&
  grep -F "  would publish: $_home/.local/bin/hello" "$_tmp/dry.out" >/dev/null; then
  pass "apply --dry-run on a fresh home describes the install and writes nothing in HOME"
else
  fail "apply --dry-run on a fresh home describes the install and writes nothing in HOME"
  cat "$_tmp/dry.out" >&2
fi
_v "$_proj" apply >/dev/null 2>&1
_before=$(_snapshot "$_home")
if _v "$_proj" apply --variant=lean --dry-run >"$_tmp/dry2.out" 2>&1 && [ "$(_snapshot "$_home")" = "$_before" ] &&
  grep -F "  current: $_home/.profile" "$_tmp/dry2.out" >/dev/null &&
  grep -F "  would remove: $_home/.local/bin/hello" "$_tmp/dry2.out" >/dev/null; then
  pass "apply --dry-run after an install reports current files and the stubs it would remove"
else
  fail "apply --dry-run after an install reports current files and the stubs it would remove"
  cat "$_tmp/dry2.out" >&2
fi
_v "$_proj" apply --variant=lean >/dev/null 2>&1
if _v "$_proj" apply --variant=lean --dry-run >"$_tmp/dry3.out" 2>&1 &&
  awk '$0 == "commands" { getline; found = ($0 == "  none") } END { exit found ? 0 : 1 }' "$_tmp/dry3.out"; then
  pass "apply --dry-run says none when no command stub would change"
else
  fail "apply --dry-run says none when no command stub would change"
  cat "$_tmp/dry3.out" >&2
fi

# --- valise loaded outside a managed block ---

_use_home unmanaged
printf '. "$HOME/.config/valise/active/plans/sh.sh"\n' >"$_home/.profile"
if _v "$_proj" apply >"$_tmp/unmanaged.out" 2>&1 &&
  grep -F 'warning: these lines load valise outside a managed block' "$_tmp/unmanaged.out" >/dev/null &&
  grep -F "$_home/.profile:1: " "$_tmp/unmanaged.out" >/dev/null; then
  pass "install warns about a hand-written plan source line"
else
  fail "install warns about a hand-written plan source line"
  cat "$_tmp/unmanaged.out" >&2
fi
if _v "$_proj" doctor >"$_tmp/unmanaged-doctor.out" 2>&1; then
  fail "doctor fails on a hand-written plan source line"
elif grep -F 'FAIL: valise is loaded outside a managed block' "$_tmp/unmanaged-doctor.out" >/dev/null; then
  pass "doctor fails on a hand-written plan source line"
else
  fail "doctor fails on a hand-written plan source line"
  cat "$_tmp/unmanaged-doctor.out" >&2
fi
_use_home managed-only
_v "$_proj" apply >/dev/null 2>&1
if _v "$_proj" doctor >"$_tmp/clean-doctor.out" 2>&1; then
  pass "doctor passes when valise is loaded only by managed blocks"
else
  fail "doctor passes when valise is loaded only by managed blocks"
  cat "$_tmp/clean-doctor.out" >&2
fi

# --- GUI bridge transactions (review findings: removal, release use, preview) ---
# _bridge_proj <dest> <gui_env> <salt>: a copy of the sample project with the
# given bridge mode, and a salt so each copy builds a distinct release.
_bridge_proj() {
  rm -rf "$1"
  cp -R "$_proj" "$1"
  printf 'gui_env=%s\n' "$2" >>"$1/valise.conf"
  printf '# salt %s\n' "$3" >>"$1/modules/main.sh"
}
_state_previous() { printf '%s\n' "$_home/.local/state/valise/previous"; }

# Removal: both owned bridges exist; the LaunchAgents directory refuses the second
# removal. A failed removal must leave BOTH files exactly as they were.
# chmod 555 cannot make a directory unwritable for uid 0, so skip as root.
if [ "$(id -u)" -eq 0 ]; then
  skip "a failed bridge removal leaves every owned bridge file byte-identical and no aside file (needs non-root: chmod 555 is ineffective for uid 0)"
else
_use_home bridge-remove
mkdir -p "$_home/.config/environment.d" "$_home/Library/LaunchAgents"
printf '%s\n' '# written by valise (gui_env=systemd); do not edit' 'E2E_KEEP=one' \
  >"$_home/.config/environment.d/10-valise.conf"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!-- written by valise (gui_env=launchd); do not edit -->' '<plist version="1.0"><dict/></plist>' \
  >"$_home/Library/LaunchAgents/sh.valise.env.plist"
_rm_sys_before=$(cksum <"$_home/.config/environment.d/10-valise.conf")
_rm_lad_before=$(cksum <"$_home/Library/LaunchAgents/sh.valise.env.plist")
chmod 555 "$_home/Library/LaunchAgents"
if _v "$_proj" apply >"$_tmp/rm-fail.out" 2>&1; then
  rm_apply_status=0
else
  rm_apply_status=1
fi
chmod 755 "$_home/Library/LaunchAgents"
if [ "$rm_apply_status" -ne 0 ] &&
  [ -f "$_home/.config/environment.d/10-valise.conf" ] &&
  [ "$(cksum <"$_home/.config/environment.d/10-valise.conf")" = "$_rm_sys_before" ] &&
  [ "$(cksum <"$_home/Library/LaunchAgents/sh.valise.env.plist")" = "$_rm_lad_before" ] &&
  [ "$(_find_count "$_home/.config/environment.d" '.valise-remove.*')" = 0 ] &&
  [ "$(_find_count "$_home/Library/LaunchAgents" '.valise-remove.*')" = 0 ]; then
  pass "a failed bridge removal leaves every owned bridge file byte-identical and no aside file"
else
  fail "a failed bridge removal changed an owned bridge file or left an aside file"
  cat "$_tmp/rm-fail.out" >&2
  find "$_home/.config/environment.d" "$_home/Library/LaunchAgents" -name '.valise-remove.*' >&2 || :
fi
fi

# Release use: the publish of the bridge fails, because the bridge file is
# immutable. The active link must return to the outgoing release, and the
# previous-release record must still name the release before that one, so a
# rollback afterwards does not select the release that is already active.
if [ "$(uname -s)" != Darwin ]; then
  skip "release use publish failure: needs chflags uchg (macOS)"
else
  _use_home publish-fail
  _bridge_proj "$_tmp/bp-a" launchd a
  _v "$_tmp/bp-a" apply >"$_tmp/pf-a.out" 2>&1 || :
  _id_a=$(_active_id)
  _bridge_proj "$_tmp/bp-b" launchd b
  _v "$_tmp/bp-b" apply --no-integration >"$_tmp/pf-b.out" 2>&1 || :
  _id_b=$(_active_id)
  _lad="$_home/Library/LaunchAgents/sh.valise.env.plist"
  if [ -n "$_id_a" ] && [ -n "$_id_b" ] && [ "$_id_a" != "$_id_b" ] && [ -f "$_lad" ] &&
    [ "$(cat "$(_state_previous)")" = "$_id_a" ]; then
    _lad_before=$(cksum <"$_lad")
    chflags uchg "$_lad"
    if _v "$_proj" release use "$_id_a" >"$_tmp/pf-use.out" 2>&1; then
      pf_use=0
    else
      pf_use=1
    fi
    chflags nouchg "$_lad"
    if [ "$pf_use" -ne 0 ] && [ "$(_active_id)" = "$_id_b" ] &&
      [ "$(cat "$(_state_previous)")" = "$_id_a" ] && [ "$(cksum <"$_lad")" = "$_lad_before" ]; then
      pass "a failed bridge publish on release use keeps the outgoing release and its previous record"
    else
      fail "a failed bridge publish on release use left the previous-release record pointing at the active release"
      cat "$_tmp/pf-use.out" >&2
    fi
    # Moving the outgoing bridge aside CREATES an .valise-outgoing.* name with
    # mktemp before the mv runs. An immutable bridge makes that mv fail, and the
    # created file must not be stranded in the bridge directory.
    if [ "$(_find_count "$_home/Library/LaunchAgents" '.valise-outgoing.*')" = 0 ]; then
      pass "a failed bridge publish strands no .valise-outgoing aside file"
    else
      fail "a failed bridge publish left an .valise-outgoing aside file behind"
      find "$_home/Library/LaunchAgents" -name '.valise-outgoing.*' >&2 || :
    fi
  else
    fail "could not set up two installed releases for the release-use publish failure"
    cat "$_tmp/pf-a.out" "$_tmp/pf-b.out" >&2
  fi

  # Release use where the bridge publish SUCCEEDS but command reconciliation
  # then fails. The link, the previous-release record AND the bridge must all be
  # back on the outgoing release: leaving the new release's bridge published
  # while the old release is active is the exact inconsistency the transaction
  # exists to prevent.
  #
  # Two releases whose published command DIFFERS, so reconcile has real work:
  # release r2 adds a second command. The stub directory is then made immutable
  # (chflags uchg), which blocks the new stub's creation after the bridge has
  # already been published.
  if [ "$(uname -s)" != Darwin ]; then
    skip "a reconcile failure on release use restores the bridge (needs chflags uchg)"
  else
  _use_home reconcile-fail
  _bridge_proj "$_tmp/bp-r1" launchd r1
  # A module that EXPORTS a value the bridge carries, so the two releases render
  # different plists. Without it both bridges are byte-identical and the
  # "restored the outgoing bridge" assertion below could never fail.
  printf 'export E2E_RECONCILE=r1\n' >>"$_tmp/bp-r1/modules/hello.sh"
  _v "$_tmp/bp-r1" apply >"$_tmp/rf-1.out" 2>&1 || :
  _id_r1=$(_active_id)
  _lad="$_home/Library/LaunchAgents/sh.valise.env.plist"
  _lad_r1=$(cksum <"$_lad" 2>/dev/null || :)
  _bridge_proj "$_tmp/bp-r2" launchd r2
  printf 'export E2E_RECONCILE=r2\n' >>"$_tmp/bp-r2/modules/hello.sh"
  printf '%s\n' 'name=tool_extra' 'side_effect=read-only' 'shells=posix' 'platforms=any' \
    'exports=extra' 'commands=extra' 'load=modules/extra.sh' >"$_tmp/bp-r2/module.d/tool_extra.meta"
  printf 'extra() { echo extra; }\n' >"$_tmp/bp-r2/modules/extra.sh"
  # Append the new root to every data row of bundles.tsv (tab separated).
  awk -F '	' -v OFS='	' 'NF == 3 && $1 == "default" { $3 = $3 " tool_extra" } { print }' \
    "$_tmp/bp-r2/bundles.tsv" >"$_tmp/bp-r2/bundles.new"
  mv "$_tmp/bp-r2/bundles.new" "$_tmp/bp-r2/bundles.tsv"
  _v "$_tmp/bp-r2" apply >"$_tmp/rf-2.out" 2>&1 || :
  _id_r2=$(_active_id)
  _stub="$_home/.local/bin"
  if [ -n "$_id_r1" ] && [ -n "$_id_r2" ] && [ "$_id_r1" != "$_id_r2" ] &&
    [ -f "$_lad" ] && [ -f "$_stub/extra" ]; then
    _lad_r2=$(cksum <"$_lad")
    if [ "$_lad_r1" = "$_lad_r2" ]; then
      # The setup is the thing that is wrong, not the code under test: report it
      # as a failure rather than asserting "the bridge was restored" against two
      # byte-identical bridges, which would pass no matter what the rollback did.
      fail "the reconcile-failure setup rendered two identical GUI env bridges, so the restore cannot be observed"
    elif
      _prev_before=$(cat "$(_state_previous)")
      chflags uchg "$_stub"
      if _v "$_tmp/bp-r1" release use "$_id_r1" >"$_tmp/rf-use.out" 2>&1; then
        rf_use=0
      else
        rf_use=1
      fi
      chflags nouchg "$_stub" 2>/dev/null || :
      [ "$rf_use" -ne 0 ]
    then
      if [ "$(_active_id)" = "$_id_r2" ] &&
        [ "$(cat "$(_state_previous)")" = "$_prev_before" ] &&
        [ "$(cksum <"$_lad")" = "$_lad_r2" ] &&
        [ "$(_find_count "$_home/.local/share/valise" '.commands.*')" = 0 ] &&
        [ "$(_find_count "$_home/Library/LaunchAgents" '.valise-outgoing.*')" = 0 ]; then
        pass "a reconcile failure on release use restores the link, the previous record, and the outgoing bridge"
      else
        fail "a reconcile failure on release use left the bridge describing a release that is not active"
        cat "$_tmp/rf-use.out" >&2
        printf 'active=%s previous=%s\n' "$(_active_id)" "$(cat "$(_state_previous)" 2>/dev/null)" >&2
        cksum <"$_lad" >&2 2>/dev/null || :
        printf 'was: %s\n' "$_lad_r2" >&2
        find "$_home/.local/share/valise" "$_home/Library/LaunchAgents" \
          -name '.commands.*' -o -name '.valise-outgoing.*' >&2 2>/dev/null || :
      fi
    else
      fail "a reconcile failure on release use did not fail the activation, so the rollback was never exercised"
      cat "$_tmp/rf-use.out" >&2
    fi
  else
    fail "could not set up two installed releases for the reconcile-failure case"
    cat "$_tmp/rf-1.out" "$_tmp/rf-2.out" >&2
  fi
  fi

  # Install after a switch: the same immutable bridge makes the publish fail after
  # the link moved. The install transaction must restore the link AND the record.
  _bridge_proj "$_tmp/bp-c" launchd c
  _id_before=$(_active_id)
  _prev_before=$(cat "$(_state_previous)")
  chflags uchg "$_lad"
  if _v "$_tmp/bp-c" apply >"$_tmp/pf-install.out" 2>&1; then
    pf_install=0
  else
    pf_install=1
  fi
  chflags nouchg "$_lad"
  if [ "$pf_install" -ne 0 ] && [ "$(_active_id)" = "$_id_before" ] &&
    [ "$(cat "$(_state_previous)")" = "$_prev_before" ]; then
    pass "a failed bridge publish during install restores the link and the previous-release record"
  else
    fail "a failed bridge publish during install left the link or the previous-release record changed"
    cat "$_tmp/pf-install.out" >&2
  fi

  # The REMOVE direction of the same transaction. The incoming release sets
  # gui_env=off, so gui_env_bridge_stage stages `_gui_action=remove` and leaves
  # _gui_target EMPTY - a guard keyed on _gui_target cannot see the outgoing
  # bridge, and remove_gui_env_bridge would then delete it for good. A reconcile
  # failure afterwards rolls the link back to a release whose bridge is already
  # gone: the exact inconsistency the transaction exists to prevent, in the
  # other direction. This lane has its OWN home and bridge path so it leaves no
  # state for the lanes below.
  _use_home remove-dir
  _bridge_proj "$_tmp/bp-o1" launchd o1
  _v "$_tmp/bp-o1" apply >"$_tmp/rd-1.out" 2>&1 || :
  _id_o1=$(_active_id)
  _bridge_proj "$_tmp/bp-o2" off o2
  printf '%s\n' 'name=tool_extra' 'side_effect=read-only' 'shells=posix' 'platforms=any' \
    'exports=extra' 'commands=extra' 'load=modules/extra.sh' >"$_tmp/bp-o2/module.d/tool_extra.meta"
  printf 'extra() { echo extra; }\n' >"$_tmp/bp-o2/modules/extra.sh"
  awk -F '	' -v OFS='	' 'NF == 3 && $1 == "default" { $3 = $3 " tool_extra" } { print }' \
    "$_tmp/bp-o2/bundles.tsv" >"$_tmp/bp-o2/bundles.new"
  mv "$_tmp/bp-o2/bundles.new" "$_tmp/bp-o2/bundles.tsv"
  _v "$_tmp/bp-o2" apply >"$_tmp/rd-2.out" 2>&1 || :
  _id_o2=$(_active_id)
  # Back to r1 so r2 is not active and reconcile has to ADD `extra`.
  _v "$_tmp/bp-o1" apply >"$_tmp/rd-3.out" 2>&1 || :
  _lad_rd="$_home/Library/LaunchAgents/sh.valise.env.plist"
  if [ -n "$_id_o1" ] && [ -n "$_id_o2" ] && [ "$_id_o1" != "$_id_o2" ] &&
    [ "$(_active_id)" = "$_id_o1" ] && [ -f "$_lad_rd" ]; then
    _lad_o1=$(cksum <"$_lad_rd")
    chflags uchg "$_home/.local/bin"
    if _v "$_tmp/bp-o1" release use "$_id_o2" >"$_tmp/rd-use.out" 2>&1; then
      rd_use=0
    else
      rd_use=1
    fi
    chflags nouchg "$_home/.local/bin" 2>/dev/null || :
    if [ "$rd_use" -ne 0 ] && [ "$(_active_id)" = "$_id_o1" ] &&
      [ -f "$_lad_rd" ] && [ "$(cksum <"$_lad_rd")" = "$_lad_o1" ]; then
      pass "a reconcile failure from a bridge-owning release to gui_env=off restores the outgoing bridge"
    else
      fail "a reconcile failure from a bridge-owning release to gui_env=off destroyed the outgoing bridge"
      cat "$_tmp/rd-use.out" >&2
      printf 'active=%s (want %s)\n' "$(_active_id)" "$_id_o1" >&2
      if [ -f "$_lad_rd" ]; then cksum <"$_lad_rd" >&2; else printf 'bridge=GONE\n' >&2; fi
    fi
  else
    fail "could not set up the bridge-owning to gui_env=off reconcile-failure case"
    cat "$_tmp/rd-1.out" "$_tmp/rd-2.out" "$_tmp/rd-3.out" >&2
  fi
fi

# Preview: a mode for the OTHER platform is reported as skipped, and nothing is
# created. The write path refuses that mode on this platform, so the preview must.
_use_home preview-platform
case "$(uname -s)" in
  Darwin) _pv_platform=darwin; _pv_other=systemd ;;
  *) _pv_platform=linux; _pv_other=launchd ;;
esac
_bridge_proj "$_tmp/bp-pv" "$_pv_other" pv
if _v "$_tmp/bp-pv" apply --dry-run >"$_tmp/pv.out" 2>&1 &&
  grep -F "skipped (gui_env=$_pv_other is not supported on $_pv_platform)" "$_tmp/pv.out" >/dev/null &&
  ! grep -E 'would (create|regenerate): .*10-valise\.conf' "$_tmp/pv.out" >/dev/null &&
  ! grep -E 'would (create|regenerate): .*sh\.valise\.env\.plist' "$_tmp/pv.out" >/dev/null; then
  pass "a dry run reports a bridge mode for another platform as skipped"
else
  fail "a dry run promised a bridge this platform would not write"
  cat "$_tmp/pv.out" >&2
fi

# Preview parity for gui_env=off: install REMOVES a valise-owned bridge an
# earlier release wrote, so the dry run must say so instead of "none".
_use_home preview-off
mkdir -p "$_home/.config/environment.d"
printf '%s\n' '# written by valise (gui_env=systemd); do not edit' 'E2E_KEEP=one' \
  >"$_home/.config/environment.d/10-valise.conf"
_bridge_proj "$_tmp/bp-off" off offpv
if _v "$_tmp/bp-off" apply --dry-run >"$_tmp/pv-off.out" 2>&1 &&
  grep -F "  would remove: $_home/.config/environment.d/10-valise.conf" "$_tmp/pv-off.out" >/dev/null; then
  pass "a dry run reports a valise-owned bridge that gui_env=off would remove"
else
  fail "a dry run hid the bridge removal gui_env=off performs"
  cat "$_tmp/pv-off.out" >&2
fi
# ...and a foreign file at the bridge path is reported as left alone, not removed.
printf '%s\n' 'E2E_FOREIGN=one' >"$_home/.config/environment.d/10-valise.conf"
if _v "$_tmp/bp-off" apply --dry-run >"$_tmp/pv-off2.out" 2>&1 &&
  grep -F "  left alone (not the valise bridge): $_home/.config/environment.d/10-valise.conf" "$_tmp/pv-off2.out" >/dev/null &&
  ! grep -F "  would remove: $_home/.config/environment.d/10-valise.conf" "$_tmp/pv-off2.out" >/dev/null; then
  pass "a dry run leaves a foreign bridge file alone under gui_env=off"
else
  fail "a dry run promised to remove a foreign bridge file under gui_env=off"
  cat "$_tmp/pv-off2.out" >&2
fi

# A failed bridge publish must not leave a 0600 staging file behind in the
# bridge directory. Portable injection that works even as uid 0: make the
# bridge's parent directory contain a non-empty directory named exactly like
# the staging template cannot work (mktemp names are random), so instead the
# launchd target on macOS is made immutable with chflags and the systemd
# target on Linux is made unwritable for non-root; as root on macOS the
# existing chflags lane above already covers the publish-failure path, so this
# lane asserts the no-staging-file property there.
if [ "$(uname -s)" = Darwin ]; then
  _use_home stage-leak
  _bridge_proj "$_tmp/bp-leak" launchd leak
  _v "$_tmp/bp-leak" apply >/dev/null 2>&1 || :
  _leak_lad="$_home/Library/LaunchAgents/sh.valise.env.plist"
  if [ -f "$_leak_lad" ]; then
    chflags uchg "$_leak_lad"
    _bridge_proj "$_tmp/bp-leak2" launchd leak2
    if _v "$_tmp/bp-leak2" apply >"$_tmp/leak3.out" 2>&1; then
      leak_apply=0
    else
      leak_apply=1
    fi
    chflags nouchg "$_leak_lad" 2>/dev/null || :
    if [ "$leak_apply" -ne 0 ] &&
      [ "$(_find_count "$_home/Library/LaunchAgents" '.valise-gui.*')" = 0 ]; then
      pass "a failed bridge publish leaves no .valise-gui staging file behind"
    else
      fail "a failed bridge publish left a .valise-gui staging file behind"
      cat "$_tmp/leak3.out" >&2
      find "$_home/Library/LaunchAgents" -name '.valise-gui.*' >&2 || :
    fi
  else
    skip "a failed bridge publish leaves no .valise-gui staging file behind (no bridge staged)"
  fi
elif [ "$(id -u)" -ne 0 ]; then
  # On Linux without chattr there is no way to make gui_env_bridge_publish fail
  # AFTER the 0600 staging file exists: the only levers (an unwritable bridge
  # DIRECTORY, or an unowned target) are both rejected earlier, by
  # integration_preflight and gui_env_bridge_stage's ownership test, so mktemp
  # never runs and no staging file can be left behind. The previous version of
  # this lane made the directory read-only, which does exactly that: preflight
  # aborts with 'cannot write the GUI env bridge in <dir>' and the assertion
  # passed without exercising the cleanup it was written for.
  #
  # What IS provable here: the preflight refusal happens BEFORE anything is
  # staged, so no staging file exists when it aborts. That is the property this
  # lane now asserts on Linux; the publish-failure cleanup is covered by the
  # chflags lane above (macOS), which can fail the mv itself.
  _use_home stage-leak
  _bridge_proj "$_tmp/bp-leak" systemd leak
  _v "$_tmp/bp-leak" apply --no-integration >/dev/null 2>&1 || :
  mkdir -p "$_home/.config/environment.d"
  chmod 555 "$_home/.config/environment.d"
  if _v "$_tmp/bp-leak" apply >"$_tmp/leak3.out" 2>&1; then
    leak_apply=0
  else
    leak_apply=1
  fi
  chmod 755 "$_home/.config/environment.d" 2>/dev/null || :
  if [ "$leak_apply" -ne 0 ] &&
    grep -q 'cannot write the GUI env bridge in' "$_tmp/leak3.out" &&
    [ "$(_find_count "$_home/.config/environment.d" '.valise-gui.*')" = 0 ]; then
    pass "an unwritable bridge directory is refused at preflight, before anything is staged"
  else
    fail "an unwritable bridge directory was not refused at preflight, or a staging file was left behind"
    cat "$_tmp/leak3.out" >&2
    find "$_home/.config/environment.d" -name '.valise-gui.*' >&2 || :
  fi
else
  skip "a failed bridge publish leaves no .valise-gui staging file behind (needs macOS chflags or non-root Linux)"
fi

# Uninstall must finish (active link, records, releases removed) and exit
# nonzero when the bridge removal fails, instead of aborting mid-uninstall.
# Portable injection: macOS chflags on the LaunchAgent; Linux non-root
# read-only environment.d.
if [ "$(uname -s)" = Darwin ]; then
  _use_home uninstall-bridge-fail
  _bridge_proj "$_tmp/bp-un" launchd un
  _v "$_tmp/bp-un" apply >/dev/null 2>&1 || :
  _un_lad="$_home/Library/LaunchAgents/sh.valise.env.plist"
  if [ -f "$_un_lad" ]; then
    chflags uchg "$_un_lad"
    if _v "$_proj" uninstall >"$_tmp/un-bridge.out" 2>&1; then
      un_rc=0
    else
      un_rc=1
    fi
    chflags nouchg "$_un_lad" 2>/dev/null || :
    if [ "$un_rc" -ne 0 ] &&
      [ ! -L "$_home/.config/valise/active" ] &&
      [ ! -e "$_home/.local/share/valise/releases" ] &&
      grep -q 'warning: the GUI env bridge could not be removed completely' "$_tmp/un-bridge.out"; then
      pass "uninstall finishes and reports nonzero when the bridge removal fails"
    else
      fail "uninstall aborted mid-flight or hid the bridge failure"
      cat "$_tmp/un-bridge.out" >&2
    fi
  else
    skip "uninstall finishes and reports nonzero when the bridge removal fails (no bridge staged)"
  fi
elif [ "$(id -u)" -ne 0 ]; then
  _use_home uninstall-bridge-fail
  _bridge_proj "$_tmp/bp-un" systemd un
  _v "$_tmp/bp-un" apply >/dev/null 2>&1 || :
  if [ -f "$_home/.config/environment.d/10-valise.conf" ]; then
    chmod 555 "$_home/.config/environment.d"
    if _v "$_proj" uninstall >"$_tmp/un-bridge.out" 2>&1; then
      un_rc=0
    else
      un_rc=1
    fi
    chmod 755 "$_home/.config/environment.d" 2>/dev/null || :
    if [ "$un_rc" -ne 0 ] &&
      [ ! -L "$_home/.config/valise/active" ] &&
      [ ! -e "$_home/.local/share/valise/releases" ] &&
      grep -q 'warning: the GUI env bridge could not be removed completely' "$_tmp/un-bridge.out"; then
      pass "uninstall finishes and reports nonzero when the bridge removal fails"
    else
      fail "uninstall aborted mid-flight or hid the bridge failure"
      cat "$_tmp/un-bridge.out" >&2
    fi
  else
    skip "uninstall finishes and reports nonzero when the bridge removal fails (no bridge staged)"
  fi
else
  skip "uninstall finishes and reports nonzero when the bridge removal fails (needs macOS chflags or non-root Linux)"
fi

# --- Hardening regressions: FIFO, activation rollback, relative active link,
#     post-commit bridge cleanup, and failed outgoing backup ---
if [ "$(uname -s)" = Darwin ]; then
  _lc_mode=launchd
  _lc_bridge_rel="Library/LaunchAgents/sh.valise.env.plist"
else
  _lc_mode=systemd
  _lc_bridge_rel=".config/environment.d/10-valise.conf"
fi

# 1. A foreign FIFO at the bridge path must not block bridge_is_valise_owned.
_use_home fifo-bridge
_bridge_proj "$_tmp/bp-fifo" "$_lc_mode" fifo
mkdir -p "$(dirname "$_home/$_lc_bridge_rel")"
mkfifo "$_home/$_lc_bridge_rel"
_v "$_tmp/bp-fifo" apply >"$_tmp/fifo.out" 2>&1 &
_fifo_pid=$!
_fifo_wait=0
while kill -0 "$_fifo_pid" 2>/dev/null && [ "$_fifo_wait" -lt 10 ]; do
  sleep 1
  _fifo_wait=$((_fifo_wait + 1))
done
if kill -0 "$_fifo_pid" 2>/dev/null; then
  kill -9 "$_fifo_pid" 2>/dev/null || :
  wait "$_fifo_pid" 2>/dev/null || :
  fail "bridge ownership check blocked on a foreign FIFO"
else
  wait "$_fifo_pid" || :
  if [ -p "$_home/$_lc_bridge_rel" ] &&
    grep -F 'not the valise GUI env bridge' "$_tmp/fifo.out" >/dev/null; then
    pass "bridge ownership check refuses a foreign FIFO without blocking"
  else
    fail "bridge ownership check mishandled a foreign FIFO"
    cat "$_tmp/fifo.out" >&2
  fi
fi

# 2. Activation errors (unwritable config dir or symlinked previous record)
#    must restore the outgoing bridge and leave no .valise-outgoing.* or
#    valise-reconcile.* files behind.
_use_home act-err-prev
_bridge_proj "$_tmp/bp-ae-a" "$_lc_mode" aea
printf 'export E2E_AE=a\n' >>"$_tmp/bp-ae-a/modules/hello.sh"
_v "$_tmp/bp-ae-a" apply >"$_tmp/ae-a.out" 2>&1 || :
_id_ae_a=$(_active_id)
_bridge_proj "$_tmp/bp-ae-b" "$_lc_mode" aeb
printf 'export E2E_AE=b\n' >>"$_tmp/bp-ae-b/modules/hello.sh"
_v "$_tmp/bp-ae-b" apply --no-integration >"$_tmp/ae-b.out" 2>&1 || :
_id_ae_b=$(_active_id)
_v "$_proj" release use "$_id_ae_a" >/dev/null 2>&1 || :
_ae_bridge="$_home/$_lc_bridge_rel"
_ae_bridge_dir=$(dirname "$_ae_bridge")
_ae_before=$(cksum <"$_ae_bridge" 2>/dev/null || :)
printf 'fixture\n' >"$_tmp/prev-fixture"
rm -f "$(_state_previous)"
ln -s "$_tmp/prev-fixture" "$(_state_previous)"
if _v "$_proj" release use "$_id_ae_b" >"$_tmp/ae-prev.out" 2>&1; then
  ae_prev_rc=0
else
  ae_prev_rc=1
fi
if [ "$ae_prev_rc" -ne 0 ] && [ "$(_active_id)" = "$_id_ae_a" ] &&
  [ -f "$_ae_bridge" ] && [ "$(cksum <"$_ae_bridge")" = "$_ae_before" ] &&
  [ "$(cat "$_tmp/prev-fixture")" = "fixture" ] &&
  [ "$(_find_count "$_ae_bridge_dir" '.valise-outgoing.*')" = 0 ]; then
  pass "release use with a symlinked previous record preserves active release and outgoing bridge"
else
  fail "release use with a symlinked previous record damaged active release or stranded bridge"
  cat "$_tmp/ae-prev.out" >&2
  find "$_ae_bridge_dir" -name '.valise-outgoing.*' >&2 || :
fi

if [ "$(id -u)" -eq 0 ]; then
  skip "release use with unwritable config dir preserves outgoing bridge (chmod 555 is ineffective for uid 0)"
else
  rm -f "$(_state_previous)"
  chmod 555 "$_home/.config/valise"
  if _v "$_proj" release use "$_id_ae_b" >"$_tmp/ae-ro.out" 2>&1; then
    ae_ro_rc=0
  else
    ae_ro_rc=1
  fi
  chmod 755 "$_home/.config/valise"
  if [ "$ae_ro_rc" -ne 0 ] && [ "$(_active_id)" = "$_id_ae_a" ] &&
    [ -f "$_ae_bridge" ] && [ "$(cksum <"$_ae_bridge")" = "$_ae_before" ] &&
    [ "$(_find_count "$_ae_bridge_dir" '.valise-outgoing.*')" = 0 ] &&
    [ "$(_find_count "$_tmp" 'valise-reconcile.*')" = 0 ]; then
    pass "release use with unwritable config dir restores outgoing bridge and cleans reconcile temp"
  else
    fail "release use with unwritable config dir stranded outgoing bridge or reconcile temp"
    cat "$_tmp/ae-ro.out" >&2
    find "$_ae_bridge_dir" -name '.valise-outgoing.*' >&2 || :
    find "$_tmp" -name 'valise-reconcile.*' >&2 || :
  fi
fi

# 3. Rollback through a valid relative active symlink must preserve outgoing
#    command stubs rather than resolving the relative link target against CWD.
_use_home rel-active-rollback
_bridge_proj "$_tmp/bp-rel-a" "$_lc_mode" rela
printf 'export E2E_REL=a\n' >>"$_tmp/bp-rel-a/modules/hello.sh"
_v "$_tmp/bp-rel-a" apply >"$_tmp/rel-a.out" 2>&1 || :
_id_rel_a=$(_active_id)
_bridge_proj "$_tmp/bp-rel-b" "$_lc_mode" relb
printf 'export E2E_REL=b\n' >>"$_tmp/bp-rel-b/modules/hello.sh"
_v "$_tmp/bp-rel-b" apply --no-integration >"$_tmp/rel-b.out" 2>&1 || :
_id_rel_b=$(_active_id)
_v "$_proj" release use "$_id_rel_a" >/dev/null 2>&1 || :
_rel_target="../../.local/share/valise/releases/$_id_rel_a"
ln -sfn "$_rel_target" "$_home/.config/valise/active"
_rel_bridge="$_home/$_lc_bridge_rel"
_rel_before=$(cksum <"$_rel_bridge" 2>/dev/null || :)
_rel_stub="$_home/.local/bin/hello"
_rel_ledger="$_home/.local/state/valise/commands.tsv"
if _v "$_proj" release verify >/dev/null 2>&1 && [ -x "$_rel_stub" ]; then
  # Force reconcile_commands to fail by making the ledger a symlink; rollback
  # must restore the relative active link, bridge, and keep the outgoing stub.
  mv "$_rel_ledger" "$_tmp/saved-commands.tsv"
  ln -s "$_tmp/saved-commands.tsv" "$_rel_ledger"
  if _v "$_proj" release use "$_id_rel_b" >"$_tmp/rel-use.out" 2>&1; then
    rel_rc=0
  else
    rel_rc=1
  fi
  rm -f "$_rel_ledger"
  mv "$_tmp/saved-commands.tsv" "$_rel_ledger"
  if [ "$rel_rc" -ne 0 ] &&
    [ "$(readlink "$_home/.config/valise/active")" = "$_rel_target" ] &&
    [ -x "$_rel_stub" ] &&
    [ -f "$_rel_bridge" ] && [ "$(cksum <"$_rel_bridge")" = "$_rel_before" ]; then
    pass "rollback through a valid relative active symlink preserves outgoing command stubs and bridge"
  else
    fail "rollback through a valid relative active symlink damaged stubs, link, or bridge"
    cat "$_tmp/rel-use.out" >&2
    ls -la "$_home/.config/valise/active" "$_rel_stub" "$_rel_bridge" >&2 2>/dev/null || :
  fi
else
  fail "could not establish valid relative active symlink fixture"
fi

# 4. remove_gui_env_bridge phase-2 delete failure returns 2 (committed), so
#    gui_env_bridge_publish succeeds without rolling back the active release.
_p2_home="$_tmp/p2-home"
mkdir -p "$_p2_home/.config/environment.d" "$_p2_home/Library/LaunchAgents" "$_p2_home/fakebin"
printf '%s\n' '# written by valise (gui_env=systemd); do not edit' 'P2=1' \
  >"$_p2_home/.config/environment.d/10-valise.conf"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!-- written by valise (gui_env=launchd); do not edit -->' '<plist version="1.0"><dict/></plist>' \
  >"$_p2_home/Library/LaunchAgents/sh.valise.env.plist"
_p2_out=$(
  HOME="$_p2_home" XDG_CONFIG_HOME="$_p2_home/.config" XDG_DATA_HOME="$_p2_home/.local/share" \
  XDG_STATE_HOME="$_p2_home/.local/state" TMPDIR="$_tmp" \
  /bin/sh -c '
    set -eu
    VALISE_CLI_DIR="'"$_repo"'/lib/cli"
    for p in usage common store fish-hook integration commands lifecycle devtools project; do
      . "$VALISE_CLI_DIR/$p.sh"
    done
    # Fail rm only on the launchd .valise-remove.* aside file (phase 2).
    _real_rm=$(trusted_utility_path rm)
    cat >"'"$_p2_home"'/fakebin/rm" <<EOF
#!/bin/sh
for a do
  case "\$a" in
  */LaunchAgents/.valise-remove.*) exit 1 ;;
  esac
done
exec "$_real_rm" "\$@"
EOF
    chmod 755 "'"$_p2_home"'/fakebin/rm"
    trusted_utility_path() {
      if [ "$1" = rm ]; then printf "%s\n" "'"$_p2_home"'/fakebin/rm"; return 0; fi
      command -v "$1"
    }
    _gui_action=remove
    _p2_rc=0
    gui_env_bridge_publish || _p2_rc=$?
    printf "publish_rc=%s\n" "$_p2_rc"
  ' 2>"$_tmp/p2.err" || :
)
if printf '%s\n' "$_p2_out" | grep -Fx 'publish_rc=0' >/dev/null &&
  [ ! -e "$_p2_home/.config/environment.d/10-valise.conf" ] &&
  [ ! -e "$_p2_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
  grep -F '.valise-remove.' "$_tmp/p2.err" >/dev/null; then
  pass "remove_gui_env_bridge phase-2 delete failure does not roll back committed bridge removal"
else
  fail "remove_gui_env_bridge phase-2 delete failure triggered rollback or hid leftover aside"
  printf '%s\n' "$_p2_out" >&2
  cat "$_tmp/p2.err" >&2
fi

# 5. Failed outgoing bridge backup in release_activate must abort before
#    mutating the active link or overwriting the predecessor bridge.
_bk_out=$(
  HOME="$_home" XDG_CONFIG_HOME="$_home/.config" XDG_DATA_HOME="$_home/.local/share" \
  XDG_STATE_HOME="$_home/.local/state" TMPDIR="$_tmp" \
  /bin/sh -c '
    set -eu
    VALISE_CLI_DIR="'"$_repo"'/lib/cli"
    for p in usage common store fish-hook integration commands lifecycle devtools project; do
      . "$VALISE_CLI_DIR/$p.sh"
    done
    _orig_mktemp_at=$(command -v true)
    # Fail only when allocating .valise-outgoing.*
    trusted_mktemp_at() {
      case "$3" in
      */.valise-outgoing.*) return 1 ;;
      esac
      _tma_dir=$1; _tma_kind=$2; _tma_tpl=$3
      _tma_mk=$(trusted_utility_path mktemp) || return 1
      if [ "$_tma_kind" = dir ]; then "$_tma_mk" -d "$_tma_tpl"; else "$_tma_mk" "$_tma_tpl"; fi
    }
    release_activate "'"$_id_rel_b"'"
  ' 2>"$_tmp/bk.err" && echo "ok" || echo "failed"
)
if [ "$_bk_out" = "failed" ] &&
  [ "$(readlink "$_home/.config/valise/active")" = "$_rel_target" ] &&
  [ -f "$_rel_bridge" ] && [ "$(cksum <"$_rel_bridge")" = "$_rel_before" ] &&
  grep -F 'cannot create a backup for the outgoing GUI env bridge' "$_tmp/bk.err" >/dev/null; then
  pass "release_activate aborts before switching when outgoing bridge backup fails"
else
  fail "release_activate continued after failed outgoing bridge backup"
  printf 'bk_out=%s\n' "$_bk_out" >&2
  cat "$_tmp/bk.err" >&2
fi

printf '\n=== install lifecycle summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d  Skip: %d\n' "$_total" "$_pass" "$_fail" "$_skip"
[ "$_fail" -eq 0 ] || exit 1
