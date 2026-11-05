#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Install lifecycle: preflight before the active release changes, restoring
# the previous release when a later step fails, release rollback, uninstall,
# apply --dry-run, and detection of valise loaded outside a managed block.
# Every scenario runs in a private home.

set -eu

_total=0
_pass=0
_fail=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }

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
_use_home() {
  _home="$_tmp/$1"
  mkdir -p "$_home"
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

# --- A failure after the switch restores the previous release ---

_use_home txn
_v "$_proj" apply --variant=lean >/dev/null 2>&1
_lean_id=$(_active_id)
_profile_before=$(cksum <"$_home/.profile")
# The command directory sits under a regular file, so publishing hello fails
# after the active link has moved.
: >"$_tmp/not-a-dir"
_bin_override="$_tmp/not-a-dir/bin"
_txn_rc=0
_v "$_proj" apply >/dev/null 2>"$_tmp/txn.err" || _txn_rc=$?
_bin_override=
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
_bin_override="$_tmp/not-a-dir/bin"
_txn_rc=0
_v "$_proj" apply >/dev/null 2>"$_tmp/txn-first.err" || _txn_rc=$?
_bin_override=
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

printf '\n=== install lifecycle summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
