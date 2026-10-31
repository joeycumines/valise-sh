#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# End-to-end project UX contract: new, module, build, apply, status.

set -eu

_total=0
_pass=0
_fail=0
_skip=0

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); _skip=$((_skip + 1)); printf '  SKIP: %s\n' "$1"; }

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_valise="$_repo/bin/valise"
_test_home=$(mktemp -d "${TMPDIR:-/tmp}/valise-project-ux.XXXXXX")
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_test_home" 2>/dev/null || :
  rm -rf -- "$_test_home"
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

_home="$_test_home/home"
_project="$_test_home/project/demo"
mkdir -p "$_home" "$_test_home/project"

printf '=== valise project UX ===\n'
printf '  home: %s\n' "$_home"
printf '  project: %s\n\n' "$_project"

_env() {
  HOME="$_home" \
  XDG_DATA_HOME="$_home/.local/share" \
  XDG_CONFIG_HOME="$_home/.config" \
  XDG_STATE_HOME="$_home/.local/state" \
  "$_valise" "$@"
}

if (cd "$_test_home/project" && _env new demo) >"$_test_home/new.out" 2>"$_test_home/new.err"; then
  pass "valise new scaffolds a project"
else
  fail "valise new scaffolds a project"
  cat "$_test_home/new.err" >&2
fi
for _file in \
  shell/module.d/profile_main.meta \
  shell/modules/profile_main.sh \
  shell/release/install-variants \
  shell/release/bundle-roots \
  shell/release/project.conf; do
  if [ -f "$_project/$_file" ]; then
    pass "new project contains $_file"
  else
    fail "new project contains $_file"
  fi
done
unset _file

if (cd "$_project" && _env module new hello --exports=hello) \
  >"$_test_home/module-new.out" 2>"$_test_home/module-new.err"; then
  pass "module new creates a module"
else
  fail "module new creates a module"
  cat "$_test_home/module-new.err" >&2
fi
# The generated body must define the declared export, otherwise the module
# fails its own export check when the profile loads it.
if grep -F 'hello() {' "$_project/shell/modules/hello.sh" >/dev/null; then
  pass "module new writes a body that defines the declared export"
else
  fail "module new writes a body that defines the declared export"
  cat "$_project/shell/modules/hello.sh" >&2
fi
cat >"$_project/shell/modules/hello.sh" <<'EOF'
hello() {
  printf '%s\n' 'project ux hello'
}
EOF
if grep -F 'requires=hello' "$_project/shell/module.d/profile_main.meta" >/dev/null; then
  pass "module new wires the module into the seed aggregator"
else
  fail "module new wires the module into the seed aggregator"
fi
if (cd "$_project" && _env module new world --exports=hello) \
  >"$_test_home/module-conflict.out" 2>"$_test_home/module-conflict.err"; then
  fail "module new rejects an export already declared by another module"
else
  if grep -F 'export already exists in another module: hello' \
    "$_test_home/module-conflict.err" >/dev/null &&
    [ ! -e "$_project/shell/module.d/world.meta" ] &&
    [ ! -e "$_project/shell/modules/world.sh" ]; then
    pass "module new rejects an export already declared by another module"
  else
    fail "module new rejects an export already declared by another module"
    cat "$_test_home/module-conflict.err" >&2
  fi
fi
_module_list=$(cd "$_project" && _env module list 2>"$_test_home/module-list.err")
if printf '%s\n' "$_module_list" | grep -Fx 'hello' >/dev/null &&
  printf '%s\n' "$_module_list" | grep -Fx 'profile_main' >/dev/null; then
  pass "module list reports project modules"
else
  fail "module list reports project modules"
  printf '%s\n' "$_module_list" >&2
fi
unset _module_list

printf '%s\n' '. "$HOME/.profile"' >"$_home/.zprofile"
if (cd "$_project" && _env apply) >"$_test_home/apply.out" 2>"$_test_home/apply.err"; then
  pass "apply builds, installs, and integrates the project"
else
  fail "apply builds, installs, and integrates the project"
  cat "$_test_home/apply.err" >&2
fi
if grep -F '. "$HOME/.profile"' "$_home/.zprofile" >/dev/null &&
  grep -F '# BEGIN valise managed block' "$_home/.zprofile" >/dev/null; then
  pass "apply preserves existing zprofile content while adding its managed block"
else
  fail "apply preserves existing zprofile content while adding its managed block"
fi
_profile="$_home/.profile"
if [ -f "$_profile" ] && grep -F '# BEGIN valise managed block' "$_profile" >/dev/null; then
  pass "apply writes a managed profile block"
else
  fail "apply writes a managed profile block"
fi
if [ ! -e "$_home/.local/state/valise/lock" ] && [ ! -L "$_home/.local/state/valise/lock" ]; then
  pass "apply leaves no state lock behind"
else
  fail "apply leaves no state lock behind"
fi
# The default apply payload is the shared profile plus the one-line zsh
# pointer zsh needs; nothing else may appear in the home directory.
if [ ! -e "$_home/.bash_profile" ] &&
  [ ! -e "$_home/.bashrc" ] &&
  [ ! -e "$_home/.kshrc" ] &&
  [ ! -e "$_home/.zshrc" ] &&
  [ ! -e "$_home/.config/fish/conf.d/valise.fish" ]; then
  pass "apply creates no shell-specific or Fish startup file"
else
  fail "apply creates no shell-specific or Fish startup file"
fi
if [ -f "$_home/.zprofile" ] &&
  [ "$(awk '/^# BEGIN valise managed block$/{f=1;next} /^# END valise managed block$/{f=0} f' \
    "$_home/.zprofile" | grep -c .)" -eq 1 ] &&
  awk '/^# BEGIN valise managed block$/{f=1;next} /^# END valise managed block$/{f=0} f' \
    "$_home/.zprofile" | grep -Fx '. "$HOME/.profile"' >/dev/null; then
  pass "apply zprofile managed block is the one-line profile pointer"
else
  fail "apply zprofile managed block is the one-line profile pointer"
  printf '%s\n' '--- .zprofile ---' >&2
  cat "$_home/.zprofile" >&2
fi
if HOME="$_home" /bin/bash -lc 'hello' 2>"$_test_home/bash.err" | grep -F 'project ux hello' >/dev/null; then
  pass "bash login shell loads the applied module"
else
  fail "bash login shell loads the applied module"
  cat "$_test_home/bash.err" >&2
fi
if HOME="$_home" /bin/ksh -lc 'hello' 2>"$_test_home/ksh.err" | grep -F 'project ux hello' >/dev/null; then
  pass "ksh login shell loads the applied module"
else
  fail "ksh login shell loads the applied module"
  cat "$_test_home/ksh.err" >&2
fi
if [ ! -x /bin/zsh ]; then
  if [ "${VALISE_REQUIRE_TOOLING:-0}" = 1 ]; then
    fail "zsh login shell loads the applied module (/bin/zsh unavailable)"
  else
    skip "zsh login shell loads the applied module (/bin/zsh unavailable)"
  fi
elif HOME="$_home" /bin/zsh -lc 'hello' 2>"$_test_home/zsh.err" | grep -F 'project ux hello' >/dev/null; then
  pass "zsh login shell loads the applied module"
else
  fail "zsh login shell loads the applied module"
  cat "$_test_home/zsh.err" >&2
fi
if [ ! -x /bin/dash ]; then
  if [ "${VALISE_REQUIRE_TOOLING:-0}" = 1 ]; then
    fail "dash loads nothing from the applied profile (/bin/dash unavailable)"
  else
    skip "dash loads nothing from the applied profile (/bin/dash unavailable)"
  fi
elif HOME="$_home" /bin/dash -c '. "$HOME/.profile"' \
  2>"$_test_home/dash-source.err"; then
  if HOME="$_home" /bin/dash -c '. "$HOME/.profile"; command -v hello >/dev/null 2>&1' \
    2>"$_test_home/dash.err"; then
    fail "dash loads nothing from the applied profile"
  else
    pass "dash loads nothing from the applied profile"
  fi
else
  fail "applied profile sources cleanly in dash"
  cat "$_test_home/dash-source.err" >&2
fi

_status=$(cd "$_project" && _env status 2>"$_test_home/status.err")
if printf '%s\n' "$_status" | grep -F 'active release:' >/dev/null &&
  printf '%s\n' "$_status" | grep -F 'integration target:' >/dev/null &&
  printf '%s\n' "$_status" | grep -F 'drift: active release matches build output' >/dev/null; then
  pass "status reports project, active release, integration, and no drift"
else
  fail "status reports project, active release, integration, and no drift"
  printf '%s\n' "$_status" >&2
  cat "$_test_home/status.err" >&2
fi
unset _status

_profile_before=$(shasum "$_profile" 2>/dev/null | cut -d' ' -f1)
_release_before=$(readlink "$_home/.config/valise/active")
if (cd "$_project" && _env apply) >"$_test_home/apply2.out" 2>"$_test_home/apply2.err" &&
  [ "$(shasum "$_profile" 2>/dev/null | cut -d' ' -f1)" = "$_profile_before" ] &&
  [ "$(readlink "$_home/.config/valise/active")" = "$_release_before" ]; then
  pass "apply is idempotent"
else
  fail "apply is idempotent"
  cat "$_test_home/apply2.err" >&2
fi
unset _profile_before _release_before

if (cd "$_project" && _env module remove hello) \
  >"$_test_home/module-remove.out" 2>"$_test_home/module-remove.err"; then
  pass "module remove removes the module"
else
  fail "module remove removes the module"
  cat "$_test_home/module-remove.err" >&2
fi
if [ ! -e "$_project/shell/module.d/hello.meta" ] &&
  [ ! -e "$_project/shell/modules/hello.sh" ] &&
  ! grep -F 'hello' "$_project/shell/release/module-registry.tsv" >/dev/null &&
  ! grep -F 'requires=hello' "$_project/shell/module.d/profile_main.meta" >/dev/null; then
  pass "module remove removes files, registry row, and seed reference"
else
  fail "module remove removes files, registry row, and seed reference"
fi

if (cd "$_project" && _env build) >"$_test_home/build-after-remove.out" 2>"$_test_home/build-after-remove.err" &&
  [ -f "$_project/build/release/shell/install/profile-release.manifest" ]; then
  pass "build succeeds after module removal"
else
  fail "build succeeds after module removal"
  cat "$_test_home/build-after-remove.err" >&2
fi

# A HOME that ends in a slash is a legal HOME. The apply command decides
# whether to write the zsh pointer by comparing the integration target with
# ~/.profile; a comparison between a normalized path and the raw HOME string
# misses the match for such a HOME, and the zsh pointer is silently skipped.
# A zsh user then gets no profile integration at all.
_slash_home="$_test_home/slash-home"
_slash_project="$_test_home/slash-project"
mkdir -p "$_slash_home"
(cd "$_test_home" && _env new slash-project) >"$_test_home/slash-new.out" 2>"$_test_home/slash-new.err" || :
_slash_env() {
  HOME="$_slash_home/" \
  XDG_DATA_HOME="$_slash_home/.local/share" \
  XDG_CONFIG_HOME="$_slash_home/.config" \
  XDG_STATE_HOME="$_slash_home/.local/state" \
  "$_valise" "$@"
}
if (cd "$_slash_project" && _slash_env apply) \
  >"$_test_home/slash-apply.out" 2>"$_test_home/slash-apply.err"; then
  if [ -f "$_slash_home/.zprofile" ] &&
    grep -F '# BEGIN valise managed block' "$_slash_home/.zprofile" >/dev/null &&
    grep -F '. "$HOME/.profile"' "$_slash_home/.zprofile" >/dev/null; then
    pass "apply writes the zsh pointer when HOME ends in a slash"
  else
    fail "apply writes the zsh pointer when HOME ends in a slash"
    cat "$_slash_home/.zprofile" >&2 2>/dev/null || :
  fi
else
  fail "apply writes the zsh pointer when HOME ends in a slash"
  cat "$_test_home/slash-apply.err" >&2
fi
unset _slash_home _slash_project

# --- Managed block markers ---------------------------------------------------
_marker_home="$_test_home/marker-home"
_marker_project="$_test_home/marker-project"
mkdir -p "$_marker_home"
(cd "$_test_home" && _env new marker-project) >/dev/null 2>&1 || :
_marker_env() {
  HOME="$_marker_home" \
  XDG_DATA_HOME="$_marker_home/.local/share" \
  XDG_CONFIG_HOME="$_marker_home/.config" \
  XDG_STATE_HOME="$_marker_home/.local/state" \
  "$_valise" "$@"
}
for _marker_case in unpaired_begin altered_end orphan_end nested_begin; do
  case "$_marker_case" in
  unpaired_begin) printf '%s\n' '# BEGIN valise managed block' 'old' 'export USER_LINE=1' ;;
  altered_end) printf '%s\n' '# BEGIN valise managed block' 'old' '# END valise managed block trimmed' 'export USER_LINE=1' ;;
  orphan_end) printf '%s\n' 'old' '# END valise managed block' 'export USER_LINE=1' ;;
  nested_begin) printf '%s\n' '# BEGIN valise managed block' '# BEGIN valise managed block' '# END valise managed block' 'export USER_LINE=1' ;;
  esac >"$_marker_home/.profile"
  cp "$_marker_home/.profile" "$_test_home/marker.before"
  if (cd "$_marker_project" && _marker_env apply) \
    >"$_test_home/marker.out" 2>"$_test_home/marker.err"; then
    fail "apply refuses $_marker_case markers"
  elif grep -F 'unpaired valise managed block markers' "$_test_home/marker.err" >/dev/null &&
    cmp -s "$_test_home/marker.before" "$_marker_home/.profile"; then
    pass "apply refuses $_marker_case markers and leaves the file unchanged"
  else
    fail "apply refuses $_marker_case markers and leaves the file unchanged"
    cat "$_test_home/marker.err" >&2
  fi
done
unset _marker_case

# --- module remove ------------------------------------------------------------
_rm_project="$_test_home/rm-project"
(cd "$_test_home" && _env new rm-project) >/dev/null 2>&1 || :
(cd "$_rm_project" && _env module new keeper --exports=keeper_fn && _env module new gone --exports=gone_fn &&
  _env module new only_root --exports=only_root_fn) >/dev/null 2>&1 || :
cat >"$_rm_project/shell/module.d/only_child_meta.meta" <<'EOF'
name=only_child_meta
version=
side_effect=read-only
requires=only_root
optional=
shells=sh
platforms=any
exports=
updates=
load=
EOF
printf 'variant_name\tdescription\texcluded_modules\nworkstation-full\tAll\t\nminimal\tMinimal\tgone\nsmall\tSmall\tgone keeper\n' \
  >"$_rm_project/shell/release/install-variants"
printf '# bundle\tshell\troots\ndefault\tbash\tprofile_main gone\ndefault\tzsh\tprofile_main\ndefault\tksh\tprofile_main\n' \
  >"$_rm_project/shell/release/bundle-roots"
if (cd "$_rm_project" && _env module remove only_root) \
  >"$_test_home/rm-refuse.out" 2>"$_test_home/rm-refuse.err"; then
  fail "module remove refuses to empty a meta module"
elif grep -F 'only_child_meta requires only this module' "$_test_home/rm-refuse.err" >/dev/null &&
  [ -f "$_rm_project/shell/modules/only_root.sh" ] &&
  [ -f "$_rm_project/shell/module.d/only_root.meta" ] &&
  grep -Fx 'requires=only_root' "$_rm_project/shell/module.d/only_child_meta.meta" >/dev/null; then
  pass "module remove refuses to empty a meta module and changes nothing"
else
  fail "module remove refuses to empty a meta module and changes nothing"
  cat "$_test_home/rm-refuse.err" >&2
fi
rm -f "$_rm_project/shell/module.d/only_child_meta.meta"
if (cd "$_rm_project" && _env module remove profile_main) \
  >"$_test_home/rm-root.out" 2>"$_test_home/rm-root.err"; then
  fail "module remove refuses to empty a bundle"
elif grep -F 'only root of a bundle' "$_test_home/rm-root.err" >/dev/null &&
  [ -f "$_rm_project/shell/module.d/profile_main.meta" ]; then
  pass "module remove refuses to empty a bundle and changes nothing"
else
  fail "module remove refuses to empty a bundle and changes nothing"
  cat "$_test_home/rm-root.err" >&2
fi
if (cd "$_rm_project" && _env module remove gone && _env build) \
  >"$_test_home/rm-refs.out" 2>"$_test_home/rm-refs.err" &&
  (cd "$_rm_project" && _env build --variant=minimal "$_test_home/rm-minimal") \
  >>"$_test_home/rm-refs.out" 2>>"$_test_home/rm-refs.err" &&
  grep -F "$(printf 'default\tbash\tprofile_main')" "$_rm_project/shell/release/bundle-roots" >/dev/null &&
  ! grep -F 'gone' "$_rm_project/shell/release/bundle-roots" >/dev/null &&
  grep -F "$(printf 'small\tSmall\tkeeper')" "$_rm_project/shell/release/install-variants" >/dev/null &&
  ! grep -F 'gone' "$_rm_project/shell/release/install-variants" >/dev/null; then
  pass "module remove strips bundle roots and variant exclusions, and the project builds"
else
  fail "module remove strips bundle roots and variant exclusions, and the project builds"
  cat "$_test_home/rm-refs.err" >&2
  cat "$_rm_project/shell/release/bundle-roots" "$_rm_project/shell/release/install-variants" >&2
fi

# --- apply in a vendored layout -----------------------------------------------
# An older manifest at the project root is found first by locate_manifest. Apply
# must still install the manifest it just built.
_vendor_home="$_test_home/vendor-home"
_vendor_project="$_test_home/vendor-project"
mkdir -p "$_vendor_home"
(cd "$_test_home" && _env new vendor-project) >/dev/null 2>&1 || :
mkdir -p "$_vendor_project/valise-sh"
cp -R "$_repo/bin" "$_repo/lib" "$_vendor_project/valise-sh/"
_vendor_env() {
  HOME="$_vendor_home" \
  XDG_DATA_HOME="$_vendor_home/.local/share" \
  XDG_CONFIG_HOME="$_vendor_home/.config" \
  XDG_STATE_HOME="$_vendor_home/.local/state" \
  "$_vendor_project/valise-sh/bin/valise" "$@"
}
if (cd "$_vendor_project" && _vendor_env build) >"$_test_home/vendor.out" 2>"$_test_home/vendor.err" &&
  (cd "$_vendor_project/build/release" && tar cf - .) | (cd "$_vendor_project" && tar xf -) &&
  (cd "$_vendor_project" && _vendor_env module new fresh --exports=fresh_fn && _vendor_env apply) \
    >>"$_test_home/vendor.out" 2>>"$_test_home/vendor.err" &&
  HOME="$_vendor_home" /bin/bash -c '. "$HOME/.profile"; command -v fresh_fn >/dev/null'; then
  pass "apply installs the manifest it built, not a stale one at the project root"
else
  fail "apply installs the manifest it built, not a stale one at the project root"
  cat "$_test_home/vendor.err" >&2
fi

printf '\n=== valise project UX summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
