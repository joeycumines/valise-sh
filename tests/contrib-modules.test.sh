#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Tests for the shipped portable contrib_ modules: strict loading through
# the entrypoint plus real behavior (PATH augmentation, editor/pager/XDG/
# history defaults) in quarantined child shells.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Standalone valise-sh: .git is a directory (real clone) or absent (tarball).
# Vendored submodule inside parent: .git is a file (gitdir pointer).
if [ -d "$ROOT_DIR/.git" ] || [ ! -f "$ROOT_DIR/.git" ]; then
  REPO_ROOT="$ROOT_DIR"
else
  REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
fi

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

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

# assert_line <label> <output> <exact-line>: the output holds this whole line.
# Substring matching hides an assertion that a longer, wrong line satisfies
# (`remove-dupes=/b:/c` matched the true `remove-dupes=/b:/c:/b`), so any
# assertion about a complete value uses this instead.
assert_line() {
  _total=$((_total + 1))
  _label=$1
  if printf '%s\n' "$2" | grep -Fqx -- "$3"; then
    pass "$_label"
  else
    fail "$_label" "missing exact line: $3; actual: $2"
  fi
}

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/shell-profile-contrib.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

_ALL_MODULES='valise_path valise_editor valise_pager valise_xdg valise_history'
_ALL_EXPORTS='valise_path_prepend valise_path_append valise_path_contains valise_path_remove valise_path_normalize valise_editor_defaults valise_pager_defaults valise_xdg_defaults valise_history_defaults'

printf '\n=== contrib modules load strict ===\n'

for _sh in /bin/sh /bin/bash /bin/zsh /bin/ksh; do
  if [ ! -x "$_sh" ]; then
    printf '  SKIP: contrib strict load under %s (shell unavailable)\n' "$_sh"
    continue
  fi
  _load_out=$(
    cd "$REPO_ROOT" || exit 97
    VALISE_ROOT="$ROOT_DIR" \
      VALISE_MODULE_ROOT="$ROOT_DIR" \
      VALISE_MODULES="$_ALL_MODULES" \
      VALISE_MODE=strict \
      "$_sh" -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; _s=$?; _missing=; for _f in '"$_ALL_EXPORTS"'; do command -v "$_f" >/dev/null 2>&1 || _missing="$_missing $_f"; done; printf "status=%s missing=%s\n" "$_s" "${_missing:-none}"'
  )
  assert_eq "contrib modules load strict under $_sh with all exports" 'status=0 missing=none' "$_load_out"
done

printf '\n=== valise_path behavior ===\n'

_path_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; PATH=/usr/bin:/bin; valise_path_prepend /a /b; printf "prepend=%s\n" "$PATH"; valise_path_prepend /b; printf "move=%s\n" "$PATH"; valise_path_append /c /a; printf "append=%s\n" "$PATH"; valise_path_prepend; printf "idempotent=%s\n" "$PATH"; PATH=":/usr/bin::/bin:"; valise_path_prepend; printf "normalized=%s\n" "$PATH"'
)
assert_contains 'valise_path_prepend keeps argument order' "$_path_out" 'prepend=/a:/b:/usr/bin:/bin'
assert_contains 'valise_path_prepend moves repeats without dupes' "$_path_out" 'move=/b:/a:/usr/bin:/bin'
assert_contains 'valise_path_append moves repeats to the end' "$_path_out" 'append=/b:/usr/bin:/bin:/c:/a'
assert_contains 'valise_path reload is idempotent' "$_path_out" 'idempotent=/b:/usr/bin:/bin:/c:/a'
assert_contains 'valise_path drops empty components' "$_path_out" 'normalized=/usr/bin:/bin'

# --- valise_path_contains / valise_path_remove / valise_path_normalize ---
# These assertions fail before the helpers exist (command not found).

_ext_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99
      PATH=/usr/bin:/bin:/usr/bin
      valise_path_contains /usr/bin && printf "contains-present=yes\n" || printf "contains-present=NO\n"
      valise_path_contains /nope && printf "contains-absent=YES\n" || printf "contains-absent=no\n"
      valise_path_contains "" && printf "contains-empty=YES\n" || printf "contains-empty=no\n"
      valise_path_contains "a:b" && printf "contains-colon=YES\n" || printf "contains-colon=no\n"
      valise_path_contains /usr && printf "contains-partial=YES\n" || printf "contains-partial=no\n"
      valise_path_remove /usr/bin; printf "remove-one=%s rc-ok\n" "$PATH"
      valise_path_remove /nope; printf "remove-absent-rc=%s\n" "$?"
      PATH=/a:/b:/a:/c::/b:
      valise_path_remove /a; printf "remove-dupes=%s\n" "$PATH"
      PATH=:/x::/y:
      valise_path_remove /x; printf "remove-norm=%s\n" "$PATH"
      PATH=:/x::/y:
      valise_path_normalize; printf "normalize=%s\n" "$PATH"
      PATH=/x:/y:/x
      valise_path_normalize; printf "normalize-dedupe=%s\n" "$PATH"
      PATH=/usr/bin:/bin
      valise_path_remove "a:b" 2>/dev/null; printf "remove-colon-rc=%s path=%s\n" "$?" "$PATH"
      valise_path_contains "/a*b" && printf "contains-glob=YES\n" || printf "contains-glob=no\n"
      PATH=/a*b:/usr/bin
      valise_path_contains "/a*b" && printf "contains-glob-literal=yes\n" || printf "contains-glob-literal=NO\n"
      valise_path_remove "/a*b"; printf "remove-glob-literal=%s\n" "$PATH"
      PATH=/usr/bin:/bin
      valise_path_prepend "/x?y"; valise_path_contains "/x?y" && printf "prepend-glob-contains=yes\n" || printf "prepend-glob-contains=NO\n"; printf "prepend-glob-path=%s\n" "$PATH"
      PATH=/a:/b
      valise_path_remove /a /b
      valise_path_append /b; printf "append-after-empty=%s\n" "${PATH-EMPTY}"
      valise_path_remove /b
      valise_path_prepend /c; printf "prepend-after-empty=%s\n" "${PATH-EMPTY}"'
)
assert_contains 'valise_path_contains finds a present entry' "$_ext_out" 'contains-present=yes'
assert_contains 'valise_path_contains rejects an absent entry' "$_ext_out" 'contains-absent=no'
assert_contains 'valise_path_contains rejects an empty argument' "$_ext_out" 'contains-empty=no'
assert_contains 'valise_path_contains rejects a colon-bearing argument' "$_ext_out" 'contains-colon=no'
assert_contains 'valise_path_contains does not match a partial entry' "$_ext_out" 'contains-partial=no'
assert_contains 'valise_path_remove removes every occurrence' "$_ext_out" 'remove-one=/bin rc-ok'
assert_contains 'valise_path_remove of an absent entry succeeds' "$_ext_out" 'remove-absent-rc=0'
assert_line 'valise_path_remove removes every occurrence and keeps other duplicates' "$_ext_out" 'remove-dupes=/b:/c:/b'
assert_contains 'valise_path_remove also drops empty components' "$_ext_out" 'remove-norm=/y'
assert_contains 'valise_path_normalize drops empty components' "$_ext_out" 'normalize=/x:/y'
assert_contains 'valise_path_normalize keeps first occurrence of dupes' "$_ext_out" 'normalize-dedupe=/x:/y'
assert_contains 'valise_path_remove rejects a colon argument and leaves PATH untouched' "$_ext_out" 'remove-colon-rc=1 path=/usr/bin:/bin'
assert_contains 'valise_path_contains on an absent glob does not match' "$_ext_out" 'contains-glob=no'
assert_contains 'valise_path_contains matches a metacharacter entry byte-exactly' "$_ext_out" 'contains-glob-literal=yes'
assert_contains 'valise_path_remove removes a metacharacter entry byte-exactly' "$_ext_out" 'remove-glob-literal=/usr/bin'
assert_contains 'valise_path_prepend adds a metacharacter entry literally and contains finds it' "$_ext_out" 'prepend-glob-contains=yes'
assert_contains 'valise_path_prepend does not glob the metacharacter argument' "$_ext_out" 'prepend-glob-path=/x?y:/usr/bin:/bin'
assert_contains 'valise_path_append after PATH emptied adds no leading empty component' "$_ext_out" 'append-after-empty=/b'
assert_contains 'valise_path_prepend after PATH emptied adds no leading empty component' "$_ext_out" 'prepend-after-empty=/c'

# --- Byte-exact matching under hostile shell options and metacharacter entries ---
# `shopt -s nocasematch` makes `case` PATTERNS case-insensitive, so a `case`
# membership test silently matches a differently-cased entry. `[ a = b ]` stays
# byte-exact, so every membership test goes through that. Metacharacter entries
# must never collide with lookalike literal entries either.
#
# The metacharacter fixtures use REAL paths in a scratch directory that contains
# a file the pattern matches. Against nonexistent paths (`/a*b`, `/axxb`) an
# unquoted word-split of the PATH list has nothing to expand to, so those
# assertions passed against the broken implementation and could not fail; with
# `aXb` on disk a glob-expanding implementation rewrites `/a*b` into it and the
# assertion catches it.
_mx_dir=$(mktemp -d "${TMPDIR:-/tmp}/valise-meta.XXXXXX") || _mx_dir=
if [ -z "$_mx_dir" ]; then
  fail "could not create a scratch directory for the metacharacter lane"
else
  : >"$_mx_dir/aXb"
fi
for _bx_sh in /bin/bash /opt/homebrew/bin/bash; do
  [ -x "$_bx_sh" ] || continue
  [ -n "$_mx_dir" ] || continue
  _bx_out=$(
    VALISE_ROOT="$ROOT_DIR" \
      VALISE_MODULE_ROOT="$ROOT_DIR" \
      VALISE_MODULES='valise_path' \
      VALISE_MODE=strict \
      "$_bx_sh" -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99
        mx=$1
        shopt -s nocasematch
        PATH=/usr/bin:/BIN
        valise_path_contains /bin && printf "nc-contains=MATCHED\n" || printf "nc-contains=absent\n"
        valise_path_remove /bin; printf "nc-remove=%s\n" "$PATH"
        PATH=/usr/bin:/BIN
        valise_path_prepend /bin; printf "nc-prepend=%s\n" "$PATH"
        PATH=/usr/bin:/BIN
        valise_path_append /bin; printf "nc-append=%s\n" "$PATH"
        PATH=/usr/bin:/bin:/BIN
        valise_path_normalize; printf "nc-normalize=%s\n" "$PATH"
        PATH="$mx/a*:$mx/aXb:/bin"
        valise_path_normalize; printf "meta-normalize=%s\n" "$PATH"
        PATH="$mx/aXb:/bin"
        valise_path_prepend "$mx/a*"; printf "meta-prepend=%s\n" "$PATH"
        PATH="$mx/a*:/bin"
        valise_path_prepend "$mx/aXb"; printf "meta-prepend-rev=%s\n" "$PATH"
        PATH="$mx/a*:$mx/aXb"
        valise_path_remove "$mx/aXb"; printf "meta-remove=%s\n" "$PATH"
        PATH="$mx/aXb:$mx/a*"
        valise_path_contains "$mx/a*" && printf "meta-contains=present\n" || printf "meta-contains=absent\n"' \
      valise-mx "$_mx_dir"
  )
  assert_line "byte-exact contains ignores a differently-cased entry ($_bx_sh)" "$_bx_out" 'nc-contains=absent'
  assert_line "byte-exact remove keeps a differently-cased entry ($_bx_sh)" "$_bx_out" 'nc-remove=/usr/bin:/BIN'
  assert_line "byte-exact prepend adds beside a differently-cased entry ($_bx_sh)" "$_bx_out" 'nc-prepend=/bin:/usr/bin:/BIN'
  assert_line "byte-exact append adds beside a differently-cased entry ($_bx_sh)" "$_bx_out" 'nc-append=/usr/bin:/BIN:/bin'
  assert_line "byte-exact normalize keeps case-distinct entries ($_bx_sh)" "$_bx_out" 'nc-normalize=/usr/bin:/bin:/BIN'
  assert_line "normalize keeps a metacharacter entry beside a real matching file ($_bx_sh)" \
    "$_bx_out" "meta-normalize=$_mx_dir/a*:$_mx_dir/aXb:/bin"
  assert_line "prepend adds a metacharacter entry beside a real matching file ($_bx_sh)" \
    "$_bx_out" "meta-prepend=$_mx_dir/a*:$_mx_dir/aXb:/bin"
  assert_line "prepend adds a literal entry beside a metacharacter entry ($_bx_sh)" \
    "$_bx_out" "meta-prepend-rev=$_mx_dir/aXb:$_mx_dir/a*:/bin"
  assert_line "remove of a literal entry keeps its metacharacter entry ($_bx_sh)" \
    "$_bx_out" "meta-remove=$_mx_dir/a*"
  assert_line "contains matches a metacharacter entry byte-exactly ($_bx_sh)" "$_bx_out" 'meta-contains=present'
done
[ -z "$_mx_dir" ] || rm -rf "$_mx_dir"

# --- A metacharacter PATH entry beside a REAL lookalike file on disk ---
# The lane above used paths that do not exist, so pathname expansion had nothing
# to match and could not distort the comparison. With a real file present, an
# unquoted word-split of the PATH list expanded `/gd/a*b` to that file and the
# literal entry was never compared: contains reported it absent and remove then
# targeted the wrong entry. Every membership test must run with globbing off.
_gd_dir=$(mktemp -d "${TMPDIR:-/tmp}/valise-glob.XXXXXX") || _gd_dir=
if [ -z "$_gd_dir" ]; then
  fail "could not create a scratch directory for the glob-collision lane"
else
  : >"$_gd_dir/aXb"
  : >"$_gd_dir/aYb"
  for _gd_sh in /bin/sh /bin/dash /bin/bash /bin/zsh /bin/ksh; do
    [ -x "$_gd_sh" ] || continue
    # The scratch directory is passed as a positional parameter: it cannot be
    # expanded inside the single-quoted -c program.
    _gd_out=$(
      VALISE_ROOT="$ROOT_DIR" \
        VALISE_MODULE_ROOT="$ROOT_DIR" \
        VALISE_MODULES='valise_path' \
        VALISE_MODE=strict \
        "$_gd_sh" -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99
          gd=$1
          PATH="$gd/a*b:$gd/aXb:/bin"
          valise_path_contains "$gd/a*b" && printf "glob-contains=present\n" || printf "glob-contains=absent\n"
          PATH="$gd/a*b:$gd/aXb:/bin"
          valise_path_remove "$gd/aXb"; printf "glob-remove=%s\n" "$PATH"
          PATH="$gd/a*b:$gd/aXb:/bin"
          valise_path_normalize; printf "glob-normalize=%s\n" "$PATH"
          PATH="$gd/a*b:/bin"
          valise_path_prepend "$gd/aXb"; printf "glob-prepend=%s\n" "$PATH"
          PATH="$gd/aXb:/bin"
          valise_path_append "$gd/a*b"; printf "glob-append=%s\n" "$PATH"
          PATH="$gd/a*b:$gd/aXb"
          valise_path_remove "$gd/a*b"; printf "glob-remove-meta=%s\n" "$PATH"
          PATH="$gd/a*b:$gd/aXb:/bin"
          valise_path_contains "$gd/aYb" && printf "glob-lookalike=present\n" || printf "glob-lookalike=absent\n"' valise-gd "$_gd_dir"
    )
    assert_line "contains a metacharacter entry beside a lookalike file on disk ($_gd_sh)" \
      "$_gd_out" 'glob-contains=present'
    assert_line "remove a literal entry beside a metacharacter entry and a lookalike file ($_gd_sh)" \
      "$_gd_out" "glob-remove=$_gd_dir/a*b:/bin"
    assert_line "normalize keeps both entries beside a lookalike file on disk ($_gd_sh)" \
      "$_gd_out" "glob-normalize=$_gd_dir/a*b:$_gd_dir/aXb:/bin"
    assert_line "prepend keeps a metacharacter entry beside a lookalike file on disk ($_gd_sh)" \
      "$_gd_out" "glob-prepend=$_gd_dir/aXb:$_gd_dir/a*b:/bin"
    assert_line "append keeps a metacharacter entry beside a lookalike file on disk ($_gd_sh)" \
      "$_gd_out" "glob-append=$_gd_dir/aXb:/bin:$_gd_dir/a*b"
    assert_line "remove the metacharacter entry itself and keep its lookalike ($_gd_sh)" \
      "$_gd_out" "glob-remove-meta=$_gd_dir/aXb"
    assert_line "contains does not match a lookalike file for a metacharacter entry ($_gd_sh)" \
      "$_gd_out" 'glob-lookalike=absent'
  done
  rm -rf "$_gd_dir"
fi

# valise_path_remove must leave PATH exactly as the caller had it when every
# argument is rejected: a set-but-empty PATH stays set, not unset.
_rej_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99
      PATH=
      valise_path_remove "" 2>/dev/null
      printf "rej-rc=%s\n" "$?"
      printf "rej-state=%s\n" "${PATH+set}"
      PATH=/usr/bin:/bin
      valise_path_remove "" 2>/dev/null
      printf "rej-keep=%s\n" "$PATH"
      PATH=/usr/bin:/bin
      valise_path_remove 2>/dev/null
      printf "noargs=%s\n" "$PATH"'
)
assert_line 'a rejected argument leaves a set-but-empty PATH set' "$_rej_out" 'rej-state=set'
assert_line 'a rejected argument leaves a populated PATH untouched' "$_rej_out" 'rej-keep=/usr/bin:/bin'
assert_line 'remove with no arguments leaves PATH untouched' "$_rej_out" 'noargs=/usr/bin:/bin'

_setu_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99
      set -u
      unset PATH
      valise_path_contains /x && printf "setu-contains=YES\n" || printf "setu-contains=no\n"
      valise_path_normalize && printf "setu-normalize=ok\n" || printf "setu-normalize=FAIL\n"
      valise_path_prepend /a && printf "setu-prepend=%s\n" "$PATH" || printf "setu-prepend=FAIL\n"
      valise_path_remove /a && printf "setu-remove=%s\n" "${PATH-unset}" || printf "setu-remove=FAIL\n"'
)
assert_contains 'helpers tolerate an unset PATH under set -u (contains)' "$_setu_out" 'setu-contains=no'
assert_contains 'helpers tolerate an unset PATH under set -u (normalize)' "$_setu_out" 'setu-normalize=ok'
assert_contains 'helpers tolerate an unset PATH under set -u (prepend)' "$_setu_out" 'setu-prepend=/a'
assert_line 'helpers tolerate an unset PATH under set -u (remove)' "$_setu_out" 'setu-remove=unset'

_state_out2=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; IFS=","; set -f; PATH=/usr/bin:/bin; valise_path_remove /nope; valise_path_normalize; valise_path_contains /usr/bin; valise_path_prepend /x; valise_path_append /y; printf "ifs=%s\n" "$IFS"; case $- in *f*) printf "noglob=yes\n" ;; *) printf "noglob=NO\n" ;; esac; printf "leftover=%s\n" "${_contrib_path_mode-_contrib_path_mode-unset}${_pr_p-_pr_p-unset}${_vp_rc-_vp_rc-unset}${_vp_f-_vp_f-unset}${_vp_p-_vp_p-unset}${_vp_arg-_vp_arg-unset}${_vp_kept-_vp_kept-unset}${_vp_rem-_vp_rem-unset}${_vp_out-_vp_out-unset}${_vplc_rest-_vplc_rest-unset}${_vplc_entry-_vplc_entry-unset}${_vplc_head-_vplc_head-unset}${_vplc_rc-_vplc_rc-unset}${_contrib_path_rem-_contrib_path_rem-unset}${_contrib_path_kept-_contrib_path_kept-unset}${_contrib_path_field-_contrib_path_field-unset}${_contrib_path_wanted-_contrib_path_wanted-unset}${_contrib_path_item-_contrib_path_item-unset}${_contrib_path_new-_contrib_path_new-unset}"'
)
assert_contains 'valise_path_remove/normalize/contains preserve caller IFS' "$_state_out2" 'ifs=,'
assert_contains 'valise_path_remove/normalize/contains preserve noglob option' "$_state_out2" 'noglob=yes'
assert_contains 'valise_path helpers leave no temp variables behind' "$_state_out2" 'leftover=_contrib_path_mode-unset_pr_p-unset_vp_rc-unset_vp_f-unset_vp_p-unset_vp_arg-unset_vp_kept-unset_vp_rem-unset_vp_out-unset_vplc_rest-unset_vplc_entry-unset_vplc_head-unset_vplc_rc-unset_contrib_path_rem-unset_contrib_path_kept-unset_contrib_path_field-unset_contrib_path_wanted-unset_contrib_path_item-unset_contrib_path_new-unset'

_state_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; IFS=","; set -f; PATH=/usr/bin:/bin; valise_path_prepend /x; printf "ifs=%s\n" "$IFS"; case $- in *f*) printf "noglob=yes\n" ;; *) printf "noglob=NO\n" ;; esac'
)
assert_contains 'valise_path preserves caller IFS' "$_state_out" 'ifs=,'
assert_contains 'valise_path preserves noglob option' "$_state_out" 'noglob=yes'

printf '\n=== contrib defaults behavior ===\n'

# Supply a controlled editor in the quarantined PATH. The test runner's
# PATH intentionally omits interactive programs, so relying on the host's vi
# installation makes this behavior test nondeterministic.
mkdir -p "$_tmp/default-bin" || exit 1
cat >"$_tmp/default-bin/vi" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$_tmp/default-bin/vi" || exit 1

_defaults_out=$(
  env -i PATH="$_tmp/default-bin:/usr/bin:/bin" HOME=/tmp \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_editor valise_pager valise_xdg valise_history' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; valise_editor_defaults; valise_pager_defaults; valise_xdg_defaults; valise_history_defaults; if command -v "${EDITOR-__none__}" >/dev/null 2>&1; then printf "editor-resolves=yes\n"; else printf "editor-resolves=no\n"; fi; if [ -n "${EDITOR-}" ] && [ "${VISUAL-}" = "$EDITOR" ]; then printf "mirror=yes\n"; else printf "mirror=no\n"; fi; printf "xdg=%s histfile=%s histsize=%s\n" "${XDG_DATA_HOME-unset}" "${HISTFILE-unset}" "${HISTSIZE-unset}"; if [ -z "${PAGER-}" ]; then printf "pager=unset-acceptable\n"; elif command -v "$PAGER" >/dev/null 2>&1; then printf "pager=resolves\n"; else printf "pager=BROKEN\n"; fi'
)
assert_contains 'valise_editor_defaults sets EDITOR to an available editor' "$_defaults_out" 'editor-resolves=yes'
assert_contains 'valise_editor_defaults mirrors VISUAL' "$_defaults_out" 'mirror=yes'
assert_contains 'valise_xdg_defaults derives from HOME' "$_defaults_out" 'xdg=/tmp/.local/share'
assert_contains 'valise_history_defaults sets HISTFILE under HOME' "$_defaults_out" 'histfile=/tmp/.sh_history'
assert_contains 'valise_history_defaults sets HISTSIZE' "$_defaults_out" 'histsize=5000'
_pager_broken=$(printf '%s\n' "$_defaults_out" | grep -c 'pager=BROKEN' || true)
assert_eq 'valise_pager_defaults never sets a broken PAGER' 0 "$_pager_broken"

_preset_out=$(
  env -i PATH=/usr/bin:/bin HOME=/tmp EDITOR=emacs VISUAL=micro PAGER=most XDG_DATA_HOME=/custom HISTFILE=/custom/hist HISTSIZE=10 \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_editor valise_pager valise_xdg valise_history' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; valise_editor_defaults; valise_pager_defaults; valise_xdg_defaults; valise_history_defaults; printf "editor=%s visual=%s pager=%s xdg=%s histfile=%s histsize=%s\n" "$EDITOR" "$VISUAL" "$PAGER" "$XDG_DATA_HOME" "$HISTFILE" "$HISTSIZE"'
)
assert_eq 'contrib defaults never override user values' \
  'editor=emacs visual=micro pager=most xdg=/custom histfile=/custom/hist histsize=10' "$_preset_out"

_shim_bin="$_tmp/fakebin"
mkdir -p "$_shim_bin"
printf '#!/bin/sh\nexit 0\n' >"$_shim_bin/nvim"
printf '#!/bin/sh\nexit 0\n' >"$_shim_bin/less"
chmod +x "$_shim_bin/nvim" "$_shim_bin/less"
_shim_out=$(
  env -i PATH="$_shim_bin:/usr/bin:/bin" HOME=/tmp \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_editor valise_pager' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; valise_editor_defaults; valise_pager_defaults; printf "editor=%s pager=%s\n" "${EDITOR-unset}" "${PAGER-unset}"'
)
assert_eq 'contrib defaults prefer nvim and less when present' 'editor=nvim pager=less' "$_shim_out"

printf '\n=== contrib modules source quietly and behave idempotently ===\n'

_quiet_out=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES="$_ALL_MODULES" \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh"'
)
assert_eq 'contrib modules source with no output' '' "$_quiet_out"

_idem_out=$(
  env -i PATH=/usr/bin:/bin HOME=/tmp \
    VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES="$_ALL_MODULES" \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; PATH=/usr/bin:/bin; valise_path_prepend /a; _once=$PATH; valise_path_prepend /a; printf "path-stable=%s\n" "$([ "$PATH" = "$_once" ] && printf yes || printf no)"; valise_editor_defaults; _e1=$EDITOR; valise_editor_defaults; printf "editor-stable=%s\n" "$([ "$EDITOR" = "$_e1" ] && printf yes || printf no)"'
)
assert_contains 'valise_path_prepend is stable on repeat calls' "$_idem_out" 'path-stable=yes'
assert_contains 'valise_editor_defaults is stable on repeat calls' "$_idem_out" 'editor-stable=yes'

printf '\n=== contrib-modules summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
