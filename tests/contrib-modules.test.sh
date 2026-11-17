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
assert_contains 'valise_path_remove dedupes and normalizes' "$_ext_out" 'remove-dupes=/b:/c'
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
assert_contains 'helpers tolerate an unset PATH under set -u (remove)' "$_setu_out" 'setu-remove='

_state_out2=$(
  VALISE_ROOT="$ROOT_DIR" \
    VALISE_MODULE_ROOT="$ROOT_DIR" \
    VALISE_MODULES='valise_path' \
    VALISE_MODE=strict \
    /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; IFS=","; set -f; PATH=/usr/bin:/bin; valise_path_remove /nope; valise_path_normalize; valise_path_contains /usr/bin; printf "ifs=%s\n" "$IFS"; case $- in *f*) printf "noglob=yes\n" ;; *) printf "noglob=NO\n" ;; esac; printf "leftover=%s\n" "${_contrib_path_mode-_contrib_path_mode-unset}${_pr_p-_pr_p-unset}${_vp_rc-_vp_rc-unset}${_vp_f-_vp_f-unset}${_vp_p-_vp_p-unset}${_vp_arg-_vp_arg-unset}${_vp_kept-_vp_kept-unset}${_vp_rem-_vp_rem-unset}${_vp_out-_vp_out-unset}"'
)
assert_contains 'valise_path_remove/normalize/contains preserve caller IFS' "$_state_out2" 'ifs=,'
assert_contains 'valise_path_remove/normalize/contains preserve noglob option' "$_state_out2" 'noglob=yes'
assert_contains 'valise_path helpers leave no temp variables behind' "$_state_out2" 'leftover=_contrib_path_mode-unset_pr_p-unset_vp_rc-unset_vp_f-unset_vp_p-unset_vp_arg-unset_vp_kept-unset_vp_rem-unset_vp_out-unset'

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
