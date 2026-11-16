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
if [ "$_have_fish" -eq 1 ]; then
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
else
  printf '  SKIP: Fish hook directory preflight (no trusted fish)\n'
fi

_use_home bindir
: >"$_tmp/not-a-dir"
mkdir -p "$_tmp/ro-bin"
chmod 555 "$_tmp/ro-bin"
for _bad in "$_tmp/not-a-dir/bin" "$_tmp/ro-bin/bin"; do
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
  [ "$(cksum <"$_home/Library/LaunchAgents/sh.valise.env.plist")" = "$_rm_lad_before" ]; then
  pass "a failed bridge removal leaves every owned bridge file byte-identical"
else
  fail "a failed bridge removal changed an owned bridge file"
  cat "$_tmp/rm-fail.out" >&2
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
  else
    fail "could not set up two installed releases for the release-use publish failure"
    cat "$_tmp/pf-a.out" "$_tmp/pf-b.out" >&2
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

printf '\n=== install lifecycle summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
