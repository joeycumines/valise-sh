#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Developer commands: valise env, lint, test, and run against sample projects.
# Nothing here installs a release; every valise call uses a private home.

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
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/valise-dev.XXXXXX")
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
mkdir -p "$_home"

# _v <project> <args...>
_v() {
  _v_project=$1
  shift
  env -i HOME="$_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    TMPDIR="$_tmp" "$_valise" -C "$_v_project" "$@"
}

# _meta <file> key=value...
_meta() {
  _meta_file=$1
  shift
  printf '%s\n' "$@" >"$_meta_file"
}

printf '=== valise developer commands ===\n'
printf '  scratch: %s\n\n' "$_tmp"

# The sample project mirrors a consumer: primary modules, a provider layer,
# a test per module, and a fixture that must exist before the module loads.
_proj="$_tmp/proj"
mkdir -p "$_proj/module.d" "$_proj/modules" "$_proj/tests" \
  "$_proj/layers/acme/module.d" "$_proj/layers/acme/modules" "$_proj/layers/acme/tests"
printf '%s\n' 'bundle=default' 'variant=default' 'lint_layer_forbid=examplecorp|bedrock' >"$_proj/valise.conf"
_meta "$_proj/module.d/main.meta" name=main side_effect=read-only 'requires=contrib_acme_path' \
  shells=posix platforms=any exports=main_ready load=modules/main.sh tests=tests/main.sh
printf 'main_ready() { printf "ready:%%s\\n" "$*"; }\nMAIN_SCALAR=sample-one\nexport MAIN_SCALAR\n' >"$_proj/modules/main.sh"
printf '%s\n' '[ "$(main_ready x)" = ready:x ] || { echo "main_ready: $(main_ready x)"; exit 1; }' \
  '[ "$HOME" = "$VALISE_TEST_ROOT/home" ] || { echo "HOME=$HOME"; exit 1; }' \
  '[ "$VALISE_TEST_MODULE" = main ] || exit 1' \
  '[ -f "$VALISE_TEST_PLAN" ] && [ "${VALISE_TEST_PLAN%/plans/*}" = "$VALISE_TEST_RELEASE" ] || { echo "plan=$VALISE_TEST_PLAN"; exit 1; }' \
  '_child=$(/bin/sh -c '"'"'VALISE_MODULE_ROOT=$VALISE_TEST_RELEASE VALISE_MODE=strict; . "$VALISE_TEST_PLAN" && main_ready child'"'"')' \
  '[ "$_child" = ready:child ] || { echo "child shell: $_child"; exit 1; }' >"$_proj/tests/main.sh"
_meta "$_proj/module.d/secrets.meta" name=secrets side_effect=local-secret shells=posix platforms=any \
  exports=secret_loaded load=modules/secrets.sh tests=tests/secrets.sh
cat >"$_proj/modules/secrets.sh" <<'EOF'
if [ -r "$HOME/.secrets/token" ]; then
  IFS= read -r TOKEN <"$HOME/.secrets/token"
fi
secret_loaded() { [ -n "${TOKEN-}" ]; }
EOF
cat >"$_proj/tests/secrets.sh" <<'EOF'
secret_loaded && { echo 'token present before the fixture'; exit 1; }
mkdir -p "$HOME/.secrets" && printf 'fake-token\n' >"$HOME/.secrets/token"
valise_test_reload || { echo 'reload failed'; exit 1; }
[ "$TOKEN" = fake-token ] || { echo "TOKEN=$TOKEN"; exit 1; }
EOF
_meta "$_proj/module.d/bash_only.meta" name=bash_only side_effect=read-only shells=bash platforms=any \
  exports=bash_only_ok load=modules/bash_only.bash tests=tests/bash_only.sh
printf 'bash_only_ok() { [ -n "${BASH_VERSION-}" ]; }\n' >"$_proj/modules/bash_only.bash"
printf 'bash_only_ok\n' >"$_proj/tests/bash_only.sh"
_meta "$_proj/layers/acme/module.d/contrib_acme_path.meta" name=contrib_acme_path version=1.0.0 \
  side_effect=read-only requires=valise_platform_posix shells=posix platforms=any \
  exports=acme_path_has load=modules/path.sh tests=tests/path.sh
printf 'acme_path_has() { case ":$PATH:" in *":$1:"*) return 0 ;; esac; return 1; }\n' \
  >"$_proj/layers/acme/modules/path.sh"
printf 'acme_path_has /usr/bin || { echo "PATH=$PATH"; exit 1; }\n' >"$_proj/layers/acme/tests/path.sh"
{
  printf 'bundle\tshell\troots\n'
  for _s in sh zsh ksh; do printf 'default\t%s\tmain secrets\n' "$_s"; done
  printf 'default\tbash\tmain secrets bash_only\n'
} >"$_proj/bundles.tsv"
printf 'variant\tdescription\texcluded\ndefault\tall\t\nno-secrets\twithout secrets\tsecrets\n' >"$_proj/variants.tsv"
_have_fish=0
if command -v fish >/dev/null 2>&1; then
  _have_fish=1
  _meta "$_proj/module.d/fish_bits.meta" name=fish_bits side_effect=read-only shells=fish platforms=any \
    exports=fish_bits_ok load=modules/fish_bits.fish tests=tests/fish_bits.fish
  printf 'function fish_bits_ok\n  echo fish-ok\nend\n' >"$_proj/modules/fish_bits.fish"
  printf 'test (fish_bits_ok) = fish-ok\n' >"$_proj/tests/fish_bits.fish"
  printf 'default\tfish\tfish_bits\n' >>"$_proj/bundles.tsv"
fi

# --- env ---

if _v "$_proj" env >"$_tmp/env.out" 2>&1 &&
  grep -Fx "VALISE_ENGINE_ROOT='$_repo'" "$_tmp/env.out" >/dev/null &&
  grep -Fx "VALISE_PROJECT_ROOT='$_proj'" "$_tmp/env.out" >/dev/null &&
  grep -Fx "VALISE_BIN_DIR='$_home/.local/bin'" "$_tmp/env.out" >/dev/null &&
  (eval "$(cat "$_tmp/env.out")"; [ -n "$VALISE_VERSION" ] && [ "$VALISE_STATE_DIR" = "$_home/.local/state/valise" ]); then
  pass "env prints shell-quoted engine, project, and storage paths"
else
  fail "env prints shell-quoted engine, project, and storage paths"
  cat "$_tmp/env.out" >&2
fi
if (cd "$_tmp" && env -i HOME="$_home" PATH=/usr/bin:/bin "$_valise" env) | grep -Fx "VALISE_PROJECT_ROOT=''" >/dev/null; then
  pass "env outside a project leaves VALISE_PROJECT_ROOT empty"
else
  fail "env outside a project leaves VALISE_PROJECT_ROOT empty"
fi

# --- env export ---
# Install the sample project's release into the scratch home, then check the
# three export formats against the env plan's actual exports.

if _v "$_proj" apply >"$_tmp/apply-env.out" 2>&1; then
  pass "apply installs a release for env export testing"
else
  fail "apply installs a release for env export testing"
  cat "$_tmp/apply-env.out" >&2
fi
if _v "$_proj" env export environment.d >"$_tmp/env-export-ed.out" 2>"$_tmp/env-export-ed.err"; then
  pass "env export environment.d succeeds"
else
  fail "env export environment.d succeeds"
  cat "$_tmp/env-export-ed.err" >&2
fi
# The sample project's closure pulls in the engine's valise_editor/valise_pager
# modules, so the capture must be non-empty and contain only identifier
# KEY=VALUE lines (bare or double-quoted).
if [ -s "$_tmp/env-export-ed.out" ] &&
  grep -q '^# written by valise' "$_tmp/env-export-ed.out" &&
  ! grep -qvE '^(#|[A-Za-z_][A-Za-z0-9_]*=)' "$_tmp/env-export-ed.out" 2>/dev/null; then
  pass "env export environment.d emits the env plan's exported scalars as identifier KEY=VALUE lines"
else
  fail "env export environment.d emits the env plan's exported scalars as identifier KEY=VALUE lines"
  cat "$_tmp/env-export-ed.out" >&2
fi
# The sample project's own env module exports a scalar; assert it appears.
if grep -q '^MAIN_SCALAR=sample-one$' "$_tmp/env-export-ed.out"; then
  pass "env export environment.d includes the project module's exported scalar (MAIN_SCALAR)"
else
  fail "env export environment.d includes the project module's exported scalar (MAIN_SCALAR)"
  cat "$_tmp/env-export-ed.out" >&2
fi
if grep -q '^PATH=' "$_tmp/env-export-ed.out"; then
  fail "env export environment.d must not emit PATH (shell bookkeeping, not a profile scalar)"
else
  pass "env export environment.d skips PATH and shell bookkeeping vars"
fi
if _v "$_proj" env export wsl >"$_tmp/env-export-wsl.out" 2>&1; then
  pass "env export wsl succeeds"
else
  fail "env export wsl succeeds"
fi
if grep -q '^WSLENV=' "$_tmp/env-export-wsl.out"; then
  _wsl_line=$(grep '^WSLENV=' "$_tmp/env-export-wsl.out")
  if printf '%s\n' "$_wsl_line" | grep -qE '^WSLENV=[A-Za-z_][A-Za-z0-9_]*(/(l|p|w))?(:[A-Za-z_][A-Za-z0-9_]*(/(l|p|w))?)*$'; then
    pass "env export wsl emits one colon-joined WSLENV line"
  else
    fail "env export wsl emits a malformed WSLENV line"
    printf '%s\n' "$_wsl_line" >&2
  fi
else
  fail "env export wsl emits one colon-joined WSLENV line"
  cat "$_tmp/env-export-wsl.out" >&2
fi
if _v "$_proj" env export launchd >"$_tmp/env-export-ld.out" 2>&1; then
  pass "env export launchd succeeds"
else
  fail "env export launchd succeeds"
fi
if grep -q '<string>sh.valise.env</string>' "$_tmp/env-export-ld.out" &&
  grep -q 'launchctl setenv' "$_tmp/env-export-ld.out" &&
  grep -q '</plist>' "$_tmp/env-export-ld.out"; then
  pass "env export launchd emits a plist with launchctl setenv"
else
  fail "env export launchd emits a plist with launchctl setenv"
  cat "$_tmp/env-export-ld.out" >&2
fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$_tmp/env-export-ld.out" >/dev/null 2>&1; then
    pass "env export launchd plist passes plutil -lint"
  else
    fail "env export launchd plist passes plutil -lint"
    cat "$_tmp/env-export-ld.out" >&2
  fi
else
  skip "env export launchd plist passes plutil -lint (plutil unavailable)"
fi
# F6: XML-special characters in values must be escaped exactly once, and the
# value is shell-quoted BEFORE the XML escaping, so the command /bin/sh runs
# carries the literal value. The value is assigned quoted in the module body so
# the shell parses it.
if printf 'XMLV="a<&>\\"b"\nexport XMLV\n' >>"$_proj/modules/main.sh" &&
  _v "$_proj" apply >/dev/null 2>&1 &&
  _v "$_proj" env export launchd >"$_tmp/env-export-ld-xml.out" 2>&1; then
  if grep -qF "launchctl setenv 'XMLV' 'a&lt;&amp;&gt;&quot;b'" "$_tmp/env-export-ld-xml.out" &&
    ! grep -q '&amp;amp;\|&amp;lt;\|&amp;gt;\|&amp;quot;' "$_tmp/env-export-ld-xml.out"; then
    pass "env export launchd shell-quotes then XML-escapes the value exactly once"
  else
    fail "env export launchd did not quote and escape the XML-special value correctly"
    grep 'XMLV' "$_tmp/env-export-ld-xml.out" >&2
  fi
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$_tmp/env-export-ld-xml.out" >/dev/null 2>&1; then
      pass "env export launchd plist with XML-special value passes plutil -lint"
    else
      fail "env export launchd plist with XML-special value fails plutil -lint"
      cat "$_tmp/env-export-ld-xml.out" >&2
    fi
  else
    skip "env export launchd plist with XML-special value passes plutil -lint (plutil unavailable)"
  fi
else
  fail "env export launchd with an XML-special value did not run"
  cat "$_tmp/env-export-ld-xml.out" >&2 2>/dev/null || :
fi
if _v "$_proj" env export bogus >/dev/null 2>"$_tmp/env-export-bogus.err"; then
  fail "env export rejects an unknown format"
elif grep -F 'usage: valise env export' "$_tmp/env-export-bogus.err" >/dev/null; then
  pass "env export rejects an unknown format"
else
  fail "env export rejects an unknown format"
  cat "$_tmp/env-export-bogus.err" >&2
fi
# gui_env=off (the default) must write no bridge on apply; gui_env=launchd on
# darwin (or systemd where a systemd user session exists) must write one and
# uninstall must remove it.
if [ ! -e "$_home/.config/environment.d/10-valise.conf" ] &&
  [ ! -e "$_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
  pass "gui_env=off (default) writes no GUI bridge on apply"
else
  fail "gui_env=off (default) writes no GUI bridge on apply"
  ls -l "$_home/.config/environment.d" "$_home/Library/LaunchAgents" >&2 2>/dev/null || :
fi
_gui_proj="$_tmp/proj-gui"
cp -R "$_proj" "$_gui_proj"
printf 'gui_env=launchd\n' >>"$_gui_proj/valise.conf"
_gui_home="$_tmp/home-gui"
mkdir -p "$_gui_home"
if env -i HOME="$_gui_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_gui_home/.local/share" \
    XDG_CONFIG_HOME="$_gui_home/.config" XDG_STATE_HOME="$_gui_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_gui_proj" apply >"$_tmp/apply-gui.out" 2>&1; then
  pass "apply with gui_env=launchd succeeds"
else
  fail "apply with gui_env=launchd succeeds"
  cat "$_tmp/apply-gui.out" >&2
fi
if [ -f "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
  grep -q 'launchctl setenv' "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" 2>/dev/null; then
  pass "gui_env=launchd writes the LaunchAgent plist on apply"
elif [ "$(uname -s)" = Darwin ]; then
  fail "gui_env=launchd writes the LaunchAgent plist on apply"
  ls -l "$_gui_home/Library/LaunchAgents" >&2 2>/dev/null || :
else
  skip "gui_env=launchd writes the LaunchAgent plist on apply (not darwin; bridge skipped by design)"
fi
if [ -f "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
  sed -n '2p' "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" 2>/dev/null |
    grep -Fq '<!-- written by valise (gui_env=launchd); do not edit -->'; then
  pass "launchd plist carries the valise ownership marker line"
elif [ "$(uname -s)" = Darwin ] && [ -f "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
  fail "launchd plist is missing the valise ownership marker line"
  head -n 3 "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" >&2
else
  skip "launchd plist carries the valise ownership marker line (bridge not written)"
fi
# F1/F3: a user-owned file at the bridge path must never be overwritten by
# apply nor removed by uninstall. Plant a foreign plist, re-apply, and check.
if [ "$(uname -s)" = Darwin ]; then
  _foreign_home="$_tmp/home-foreign"
  mkdir -p "$_foreign_home/Library/LaunchAgents"
  printf 'foreign user file\n' >"$_foreign_home/Library/LaunchAgents/sh.valise.env.plist"
  _foreign_proj="$_tmp/proj-foreign"
  cp -R "$_proj" "$_foreign_proj"
  printf 'gui_env=launchd\n' >>"$_foreign_proj/valise.conf"
  env -i HOME="$_foreign_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_foreign_home/.local/share" \
    XDG_CONFIG_HOME="$_foreign_home/.config" XDG_STATE_HOME="$_foreign_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_foreign_proj" apply >"$_tmp/apply-foreign.out" 2>&1 || :
  if [ -f "$_foreign_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
    grep -q 'foreign user file' "$_foreign_home/Library/LaunchAgents/sh.valise.env.plist" 2>/dev/null &&
    grep -q 'not the valise GUI env bridge' "$_tmp/apply-foreign.out"; then
    pass "apply leaves a user-owned file at the bridge path untouched (warns)"
  else
    fail "apply clobbered or misreported a user-owned bridge file"
    ls -l "$_foreign_home/Library/LaunchAgents" >&2 2>/dev/null || :
    cat "$_tmp/apply-foreign.out" >&2
  fi
  # F2-followup: a foreign plist that merely uses the valise Label must also
  # survive — ownership is the exact marker line, not the Label string.
  _foreign2_home="$_tmp/home-foreign2"
  mkdir -p "$_foreign2_home/Library/LaunchAgents"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n  <key>Label</key><string>sh.valise.env</string>\n</dict></plist>\n' \
    >"$_foreign2_home/Library/LaunchAgents/sh.valise.env.plist"
  _foreign2_proj="$_tmp/proj-foreign2"
  cp -R "$_proj" "$_foreign2_proj"
  printf 'gui_env=launchd\n' >>"$_foreign2_proj/valise.conf"
  env -i HOME="$_foreign2_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_foreign2_home/.local/share" \
    XDG_CONFIG_HOME="$_foreign2_home/.config" XDG_STATE_HOME="$_foreign2_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_foreign2_proj" uninstall >"$_tmp/un-foreign2.out" 2>&1 || :
  if [ -f "$_foreign2_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
    grep -q '<string>sh.valise.env</string>' "$_foreign2_home/Library/LaunchAgents/sh.valise.env.plist" 2>/dev/null; then
    pass "uninstall leaves a foreign plist that only shares the Label untouched"
  else
    fail "uninstall removed a foreign plist that carries only the Label"
    cat "$_tmp/un-foreign2.out" >&2
  fi
  env -i HOME="$_foreign_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_foreign_home/.local/share" \
    XDG_CONFIG_HOME="$_foreign_home/.config" XDG_STATE_HOME="$_foreign_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_foreign_proj" uninstall >"$_tmp/un-foreign.out" 2>&1 || :
  if [ -f "$_foreign_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
    grep -q 'foreign user file' "$_foreign_home/Library/LaunchAgents/sh.valise.env.plist" 2>/dev/null; then
    pass "uninstall leaves a user-owned file at the bridge path untouched"
  else
    fail "uninstall removed a user-owned file at the bridge path"
    cat "$_tmp/un-foreign.out" >&2
  fi
else
  skip "apply/uninstall leave a user-owned bridge file untouched (not darwin)"
  skip "uninstall leaves a user-owned file at the bridge path untouched (not darwin)"
fi
# F5: extra arguments to env export are rejected.
if _v "$_proj" env export launchd extra >/dev/null 2>"$_tmp/env-export-extra.err"; then
  fail "env export rejects extra arguments"
elif grep -F 'usage: valise env export' "$_tmp/env-export-extra.err" >/dev/null; then
  pass "env export rejects extra arguments"
else
  fail "env export did not reject extra arguments"
  cat "$_tmp/env-export-extra.err" >&2
fi
if [ -f "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ] &&
  env -i HOME="$_gui_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_gui_home/.local/share" \
    XDG_CONFIG_HOME="$_gui_home/.config" XDG_STATE_HOME="$_gui_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_gui_proj" uninstall >"$_tmp/un-gui.out" 2>&1 &&
  [ ! -e "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
  pass "uninstall removes the LaunchAgent bridge"
elif [ ! -f "$_gui_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
  skip "uninstall removes the LaunchAgent bridge (bridge was not written)"
else
  fail "uninstall removes the LaunchAgent bridge"
  cat "$_tmp/un-gui.out" >&2
fi
# gui_env must reject unknown values at config load time.
_bad_proj="$_tmp/proj-bad-gui"
cp -R "$_proj" "$_bad_proj"
printf 'gui_env=bogus\n' >>"$_bad_proj/valise.conf"
if _v "$_bad_proj" status >/dev/null 2>"$_tmp/bad-gui.err"; then
  fail "valise.conf rejects gui_env=bogus"
elif grep -F 'gui_env must be off, systemd, or launchd' "$_tmp/bad-gui.err" >/dev/null; then
  pass "valise.conf rejects gui_env=bogus"
else
  fail "valise.conf rejects gui_env=bogus"
  cat "$_tmp/bad-gui.err" >&2
fi

# --- lint ---

if _v "$_proj" lint >"$_tmp/lint.out" 2>&1 && grep -Fx 'valise lint: no problems' "$_tmp/lint.out" >/dev/null &&
  grep -E '^ok: [1-9][0-9]* syntax check' "$_tmp/lint.out" >/dev/null; then
  pass "lint passes a clean project and checks syntax"
else
  fail "lint passes a clean project and checks syntax"
  cat "$_tmp/lint.out" >&2
fi

# _lint_case <label> <expected text> <mutation command>: lint a mutated copy.
_lint_case() {
  _lc_copy="$_tmp/lint-$_total"
  cp -R "$_proj" "$_lc_copy"
  (cd "$_lc_copy" && eval "$3")
  if _v "$_lc_copy" lint >"$_tmp/lc.out" 2>&1; then
    case "$2" in
    'valise lint: no problems')
      pass "$1"
      ;;
    *)
      fail "$1 (lint passed)"
      ;;
    esac
  elif grep -F -- "$2" "$_tmp/lc.out" >/dev/null; then
    pass "$1"
  else
    fail "$1"
    cat "$_tmp/lc.out" >&2
  fi
}
_lint_case "lint names a metadata file whose name does not match" \
  'secrets.meta: metadata name other does not match file name secrets' \
  "sed 's/^name=secrets\$/name=other/' module.d/secrets.meta >m && mv m module.d/secrets.meta"
_lint_case "lint names a missing body" 'main.meta: file does not exist: modules/main.sh' 'rm modules/main.sh'
_lint_case "lint names a bash syntax error" 'modules/bash_only.bash: bash syntax error' \
  "printf 'bash_only_ok() { if then; }\\n' >modules/bash_only.bash"
_lint_case "lint requires a layer module version" 'layers/acme: contrib_acme_path.meta: layer modules must declare a version' \
  "sed '/^version=/d' layers/acme/module.d/contrib_acme_path.meta >m && mv m layers/acme/module.d/contrib_acme_path.meta"
_lint_case "lint rejects a layer dependency outside the layer and engine" \
  'dependency main is neither in this layer nor an engine module' \
  "sed 's/^requires=.*/requires=main/' layers/acme/module.d/contrib_acme_path.meta >m && mv m layers/acme/module.d/contrib_acme_path.meta"
_lint_case "lint enforces lint_layer_forbid" 'forbidden in layers (lint_layer_forbid): layers/acme/modules/path.sh:2:' \
  "printf '# ExampleCorp internal\\n' >>layers/acme/modules/path.sh"
_lint_case "lint names an unknown bundle root" 'bundle default variant default (sh): unknown bundle root: nosuch' \
  "sed 's/main secrets\$/main secrets nosuch/' bundles.tsv >b && mv b bundles.tsv"
_lint_case "lint fails a variant that excludes a required dependency" \
  'bundle default variant no-secrets (sh): variant exclusion breaks a required dependency: main requires secrets' \
  "sed 's/^requires=contrib_acme_path\$/requires=contrib_acme_path secrets/' module.d/main.meta >m && mv m module.d/main.meta"
_lint_case "lint rejects an unknown phase value" \
  'invalid phase: bogus' \
  "sed 's/^side_effect=local-secret\$/side_effect=local-secret\\nphase=bogus/' module.d/secrets.meta >m && mv m module.d/secrets.meta"
_lint_case "lint rejects raw PATH assignment in an env-phase body" \
  'secrets: env-phase body assigns PATH directly' \
  "printf 'PATH=\$HOME/.local/bin:\$PATH\\nexport PATH\\n' >>modules/secrets.sh"
_lint_case "lint rejects export PATH prepend in an env-phase body" \
  'env-phase body assigns PATH directly' \
  "printf 'export PATH=\$HOME/bin:\$PATH\\n' >>modules/main.sh"
_lint_case "lint diagnostic names valise_path_prepend for raw PATH writes" \
  'valise_path_prepend' \
  "printf 'PATH=\$HOME/bin:\$PATH\\n' >>modules/main.sh"
_lint_case "lint accepts valise_path_prepend in a body" \
  'valise lint: no problems' \
  "printf 'valise_path_prepend \"\$HOME/.local/bin\"\\n' >>modules/main.sh"
_lint_case "lint rejects a raw PATH write in an interactive-phase body" \
  'main: interactive-phase body assigns PATH directly' \
  "sed 's/^side_effect=read-only\$/side_effect=read-only\\nphase=interactive/' module.d/main.meta >m && mv m module.d/main.meta && printf 'PATH=\$HOME/bin:\$PATH\\n' >>modules/main.sh"
_lint_case "lint ignores a commented PATH assignment" \
  'valise lint: no problems' \
  "printf '# PATH=\$HOME/bin:\$PATH\\n' >>modules/secrets.sh"
_lint_case "lint catches a PATH assignment after a separator" \
  'body assigns PATH directly' \
  "printf 'true; PATH=\$HOME/bin:\$PATH\\n' >>modules/secrets.sh"
_lint_case "lint catches a PATH assignment after a logical and" \
  'body assigns PATH directly' \
  "printf 'true && PATH=\$HOME/bin:\$PATH\\n' >>modules/secrets.sh"
_lint_case "lint catches a PATH assignment after another export" \
  'body assigns PATH directly' \
  "printf 'export A=1 PATH=\$HOME/bin\\n' >>modules/secrets.sh"

# `bin/valise` is #!/bin/sh, so its code must survive the shell that /bin/sh is
# on the target platform. A POSIX-incompatible expansion passes `sh -n` and
# still aborts at expansion time, so the only honest check is to RUN the CLI
# under an sh that is not bash, zsh, or ksh in disguise.
_dash_sh=
for _dash_candidate in dash /bin/dash /usr/bin/dash; do
  _dash_path=$(command -v "$_dash_candidate" 2>/dev/null || :)
  [ -n "$_dash_path" ] || continue
  if "$_dash_path" -c '[ -z "${BASH_VERSION-}${ZSH_VERSION-}${KSH_VERSION-}" ]' 2>/dev/null; then
    _dash_sh=$_dash_path
    break
  fi
done
if [ -n "$_dash_sh" ]; then
  if env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    TMPDIR="$_tmp" "$_dash_sh" "$_valise" -C "$_proj" lint >"$_tmp/lint-dash.out" 2>&1 &&
    grep -Fx 'valise lint: no problems' "$_tmp/lint-dash.out" >/dev/null; then
    pass "lint passes a clean project when the CLI runs under $_dash_sh"
  else
    fail "lint passes a clean project when the CLI runs under $_dash_sh"
    cat "$_tmp/lint-dash.out" >&2
  fi
  _dash_bad="$_tmp/lint-dash-bad"
  cp -R "$_proj" "$_dash_bad"
  printf 'PATH=$HOME/bin:$PATH\n' >>"$_dash_bad/modules/secrets.sh"
  if env -i HOME="$_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_home/.local/share" \
    XDG_CONFIG_HOME="$_home/.config" XDG_STATE_HOME="$_home/.local/state" SHELL=/bin/sh \
    TMPDIR="$_tmp" "$_dash_sh" "$_valise" -C "$_dash_bad" lint >"$_tmp/lint-dash-bad.out" 2>&1; then
    fail "lint rejects a raw PATH write when the CLI runs under $_dash_sh (it passed)"
  elif grep -F 'secrets: env-phase body assigns PATH directly' "$_tmp/lint-dash-bad.out" >/dev/null &&
    ! grep -F 'Bad substitution' "$_tmp/lint-dash-bad.out" >/dev/null; then
    pass "lint rejects a raw PATH write when the CLI runs under $_dash_sh"
  else
    fail "lint rejects a raw PATH write when the CLI runs under $_dash_sh"
    cat "$_tmp/lint-dash-bad.out" >&2
  fi
else
  skip "lint runs under a POSIX sh that is not bash/zsh/ksh (no such sh available)"
  skip "lint rejects a raw PATH write under a POSIX sh that is not bash/zsh/ksh (no such sh available)"
fi

# --- test ---

_v "$_proj" test >"$_tmp/test.out" 2>&1 && _test_rc=0 || _test_rc=$?
_expect_ok='main [sh] tests/main.sh|main [bash] tests/main.sh|secrets [bash] tests/secrets.sh|bash_only [bash] tests/bash_only.sh|contrib_acme_path [bash] tests/path.sh'
_missing=
_oldifs=$IFS
IFS='|'
for _line in $_expect_ok; do
  grep -Fx "ok $_line" "$_tmp/test.out" >/dev/null || _missing="$_missing [$_line]"
done
IFS=$_oldifs
if [ "$_test_rc" -eq 0 ] && [ -z "$_missing" ] && ! grep -F 'bash_only [zsh]' "$_tmp/test.out" >/dev/null &&
  grep -E '^valise test: [0-9]+ passed, 0 failed' "$_tmp/test.out" >/dev/null; then
  pass "test runs every module's tests in each declared shell, with fixtures and reload"
else
  fail "test runs every module's tests in each declared shell, with fixtures and reload (missing:$_missing)"
  cat "$_tmp/test.out" >&2
fi
if [ "$_have_fish" -eq 1 ]; then
  if grep -Fx 'ok fish_bits [fish] tests/fish_bits.fish' "$_tmp/test.out" >/dev/null &&
    ! grep -F 'main [fish]' "$_tmp/test.out" >/dev/null; then
    pass "Fish tests run in Fish only"
  else
    fail "Fish tests run in Fish only"
  fi
else
  skip "Fish tests run in Fish only (fish not installed)"
fi
for _class in zsh ksh; do
  if command -v "$_class" >/dev/null 2>&1; then
    if grep -Fx "ok main [$_class] tests/main.sh" "$_tmp/test.out" >/dev/null; then
      pass "posix module tests run in $_class"
    else
      fail "posix module tests run in $_class"
    fi
  else
    skip "posix module tests run in $_class ($_class not installed)"
  fi
done
if _v "$_proj" test --shell=bash secrets >"$_tmp/test-one.out" 2>&1 &&
  [ "$(grep -c '^ok ' "$_tmp/test-one.out")" -eq 1 ] && grep -Fx 'ok secrets [bash] tests/secrets.sh' "$_tmp/test-one.out" >/dev/null; then
  pass "test --shell and a module argument narrow the run"
else
  fail "test --shell and a module argument narrow the run"
  cat "$_tmp/test-one.out" >&2
fi
printf 'echo "main is broken"\nexit 4\n' >>"$_proj/tests/main.sh"
if _v "$_proj" test --shell=bash main >"$_tmp/test-fail.out" 2>&1; then
  fail "a failing test fails valise test and shows its output"
elif grep -Fx 'FAIL main [bash] tests/main.sh' "$_tmp/test-fail.out" >/dev/null &&
  grep -Fx '    main is broken' "$_tmp/test-fail.out" >/dev/null &&
  grep -F 'valise test: 0 passed, 1 failed' "$_tmp/test-fail.out" >/dev/null; then
  pass "a failing test fails valise test and shows its output"
else
  fail "a failing test fails valise test and shows its output"
  cat "$_tmp/test-fail.out" >&2
fi
sed '$d' "$_proj/tests/main.sh" | sed '$d' >"$_tmp/main.sh" && mv "$_tmp/main.sh" "$_proj/tests/main.sh"
printf 'main_ready() { return 1; }\nfalse\n' >"$_tmp/broken.sh"
cp "$_proj/modules/main.sh" "$_tmp/main.body"
cp "$_tmp/broken.sh" "$_proj/modules/main.sh"
if _v "$_proj" test --shell=bash main >"$_tmp/test-load.out" 2>&1; then
  fail "a module that fails to load fails its tests"
elif grep -F 'the modules failed to load' "$_tmp/test-load.out" >/dev/null; then
  pass "a module that fails to load fails its tests"
else
  fail "a module that fails to load fails its tests"
  cat "$_tmp/test-load.out" >&2
fi
cp "$_tmp/main.body" "$_proj/modules/main.sh"
if _v "$_proj" test nosuch >/dev/null 2>"$_tmp/test-unknown.err"; then
  fail "test rejects an unknown module"
elif grep -F 'unknown module: nosuch' "$_tmp/test-unknown.err" >/dev/null; then
  pass "test rejects an unknown module"
else
  fail "test rejects an unknown module"
fi

# --- run ---

_run_out=$(_v "$_proj" run --shell=bash --module=main -- 'main_ready "$@"; printf "%s\n" "$HOME"' a b 2>&1) || :
if [ "$(printf '%s\n' "$_run_out" | sed -n 1p)" = 'ready:a b' ] &&
  case "$(printf '%s\n' "$_run_out" | sed -n 2p)" in "$_tmp"/valise-dev.*) true ;; *) false ;; esac; then
  pass "run loads a module, passes arguments, and quarantines HOME"
else
  fail "run loads a module, passes arguments, and quarantines HOME"
  printf '%s\n' "$_run_out" >&2
fi
_rc=0
_v "$_proj" run --shell=sh --module=main -- 'exit 7' >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 7 ]; then
  pass "run returns the script's exit status"
else
  fail "run returns the script's exit status (got $_rc)"
fi
if [ "$(_v "$_proj" run --shell=bash --keep-env -- 'printf "%s\n" "$HOME"; command -v main_ready bash_only_ok secret_loaded >/dev/null && echo loaded' 2>&1)" = "$_home
loaded" ]; then
  pass "run without --module loads the default bundle; --keep-env keeps the caller's HOME"
else
  fail "run without --module loads the default bundle; --keep-env keeps the caller's HOME"
fi
if [ "$(_v "$_proj" run --shell=bash --variant=no-secrets -- 'command -v secret_loaded >/dev/null || echo absent' 2>&1)" = absent ]; then
  pass "run --variant applies the variant's exclusions"
else
  fail "run --variant applies the variant's exclusions"
fi
# run owns no stdin: both quarantine modes must forward arbitrary bytes and
# preserve argument boundaries, including an empty argument. File comparison
# catches embedded NULs and trailing newlines that command substitution loses.
printf 'first\000second\r\nback\\slash\n\n' >"$_tmp/run-stdin.in"
printf 'arg=<a b>\narg=<x*y>\narg=<>\n' >"$_tmp/run-args.want"
# A separate home keeps --keep-env from reading the release installed by the
# env-export cases above (zsh reads .zshenv even for a noninteractive script).
_stdin_home="$_tmp/stdin-home"
mkdir -p "$_stdin_home"
_stdin_run() ( _home=$_stdin_home; _v "$_proj" "$@"; )
for _stdin_shell in sh bash zsh ksh fish; do
  if ! command -v "$_stdin_shell" >/dev/null 2>&1; then
    skip "run forwards stdin and arguments in $_stdin_shell (interpreter absent)"
    continue
  fi
  _stdin_module=main
  _stdin_script='printf "arg=<%s>\n" "$@" >&2; cat'
  if [ "$_stdin_shell" = fish ]; then
    _stdin_module=fish_bits
    _stdin_script='printf "arg=<%s>\n" $argv >&2; cat'
  fi
  for _stdin_mode in quarantine keep-env; do
    set --
    [ "$_stdin_mode" != keep-env ] || set -- --keep-env
    if _stdin_run run --shell="$_stdin_shell" --module="$_stdin_module" "$@" -- \
      "$_stdin_script" 'a b' 'x*y' '' <"$_tmp/run-stdin.in" \
      >"$_tmp/run-stdin.out" 2>"$_tmp/run-args.out" &&
      cmp -s "$_tmp/run-stdin.in" "$_tmp/run-stdin.out" &&
      cmp -s "$_tmp/run-args.want" "$_tmp/run-args.out"; then
      pass "run forwards stdin byte for byte and preserves arguments ($_stdin_shell, $_stdin_mode)"
    else
      fail "run changed stdin or arguments ($_stdin_shell, $_stdin_mode)"
      cat "$_tmp/run-args.out" >&2
    fi
  done
done

# A native cd wrapper is valid only when Fish reports its real distributed
# source. A caller config cannot make its own cd.fish trusted by rewriting
# Fish's mutable data/function search variables. Quarantined run/test must
# still work with that same poisoned caller HOME.
if [ "$_have_fish" -eq 1 ]; then
  mkdir -p "$_stdin_home/.config/fish" "$_stdin_home/fake/share/fish/functions"
  printf '%s\n' 'function cd; printf "caller-cd-ran\\n"; return 1; end' \
    >"$_stdin_home/fake/share/fish/functions/cd.fish"
  cat >"$_stdin_home/.config/fish/config.fish" <<'EOF'
set -g __fish_data_dir "$HOME/fake/share/fish"
set -g fish_function_path "$__fish_data_dir/functions" $fish_function_path
builtin source "$__fish_data_dir/functions/cd.fish"
EOF
  _fish_caller_rc=0
  _stdin_run run --shell=fish --module=fish_bits --keep-env -- 'printf "poison-accepted\\n"' \
    >"$_tmp/fish-caller.out" 2>"$_tmp/fish-caller.err" || _fish_caller_rc=$?
  if [ "$_fish_caller_rc" -ne 0 ] && [ ! -s "$_tmp/fish-caller.out" ] &&
    grep -F 'caller shadowed critical Fish builtin: cd' "$_tmp/fish-caller.err" >/dev/null; then
    pass "run --keep-env rejects a caller cd function despite a forged Fish data prefix"
  else
    fail "run --keep-env accepted or executed a caller cd function"
    cat "$_tmp/fish-caller.out" "$_tmp/fish-caller.err" >&2
  fi
  if [ "$(_stdin_run run --shell=fish --module=fish_bits -- 'fish_bits_ok' 2>"$_tmp/fish-isolated-run.err")" = fish-ok ] &&
    [ ! -s "$_tmp/fish-isolated-run.err" ] &&
    _stdin_run test --shell=fish fish_bits >"$_tmp/fish-isolated-test.out" 2>"$_tmp/fish-isolated-test.err" &&
    grep -Fx 'ok fish_bits [fish] tests/fish_bits.fish' "$_tmp/fish-isolated-test.out" >/dev/null &&
    [ ! -s "$_tmp/fish-isolated-test.err" ]; then
    pass "quarantined Fish run and test ignore a poisoned caller config"
  else
    fail "quarantined Fish run or test used a poisoned caller config"
    cat "$_tmp/fish-isolated-run.err" "$_tmp/fish-isolated-test.out" "$_tmp/fish-isolated-test.err" >&2
  fi
fi

# Tests, unlike run, deliberately read EOF: their stdin is otherwise the
# metadata-row loop. Check the test call site still applies that restriction.
cp "$_proj/tests/main.sh" "$_tmp/main-test-stdin.orig"
printf '%s\n' 'if IFS= read -r _stdin; then echo "test read caller stdin"; exit 1; fi' >>"$_proj/tests/main.sh"
if _v "$_proj" test --shell=sh main <"$_tmp/run-stdin.in" >"$_tmp/test-stdin.out" 2>&1 &&
  grep -F 'ok main [sh]' "$_tmp/test-stdin.out" >/dev/null; then
  pass "test runners receive EOF while run retains caller stdin"
else
  fail "test runners consumed caller stdin or the metadata row stream"
  cat "$_tmp/test-stdin.out" >&2
fi
mv "$_tmp/main-test-stdin.orig" "$_proj/tests/main.sh"

# --- interactive phase: test, run, and published commands ---
# A phase=interactive module must still be exercised by the developer tools:
# the plans carry no $- gate (the managed block does), so the harness sources
# the module under test. And a module that publishes a command needs its own
# body in the command plan whatever phase it declares.
_int_proj="$_tmp/proj-interactive"
cp -R "$_proj" "$_int_proj"
printf '%s\n' 'name=intbits' 'side_effect=read-only' 'shells=posix' 'platforms=any' \
  'exports=intbits_ok' 'load=modules/intbits.sh' 'tests=tests/intbits.sh' \
  'commands=intbits_ok' 'phase=interactive' >"$_int_proj/module.d/intbits.meta"
printf 'intbits_ok() { printf "intbits:%%s\\n" "$*"; }\n' >"$_int_proj/modules/intbits.sh"
printf 'test "$(intbits_ok x)" = intbits:x\n' >"$_int_proj/tests/intbits.sh"
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "default" && $2 == "bash" { $3 = $3 " intbits" } { print }' \
  "$_int_proj/bundles.tsv" >"$_tmp/b.tsv" && mv "$_tmp/b.tsv" "$_int_proj/bundles.tsv"
if _v "$_int_proj" test --shell=bash intbits >"$_tmp/int-test.out" 2>&1 &&
  grep -Fx 'ok intbits [bash] tests/intbits.sh' "$_tmp/int-test.out" >/dev/null; then
  pass "test loads a phase=interactive module under test"
else
  fail "test did not load a phase=interactive module under test"
  cat "$_tmp/int-test.out" >&2
fi
if [ "$(_v "$_int_proj" run --shell=bash --module=intbits -- 'intbits_ok y' 2>&1)" = intbits:y ]; then
  pass "run --module loads a phase=interactive module"
else
  fail "run --module did not load a phase=interactive module"
fi
if _v "$_int_proj" apply >/dev/null 2>&1 &&
  _cmd_bin=$(ls "$_home"/.local/bin/intbits_ok 2>/dev/null) &&
  [ -n "$_cmd_bin" ] &&
  [ "$(env -i HOME="$_home" PATH=/usr/bin:/bin "$_cmd_bin" z 2>&1)" = intbits:z ]; then
  pass "a command published by a phase=interactive module runs"
else
  fail "a command published by a phase=interactive module does not run"
  _v "$_int_proj" apply >&2 2>&1 || :
fi

# --- capture ---
# The GUI env capture keeps the caller's real HOME while isolating the rc
# surface, so a $HOME-derived scalar carries the REAL path and not the
# throwaway probe directory. A value containing a newline must fail loudly
# rather than being silently truncated; module stdout must not inject a fake
# KEY=VALUE line.
_gopath_proj="$_tmp/proj-gopath"
cp -R "$_proj" "$_gopath_proj"
printf 'GOPATH=$HOME/go\nexport GOPATH\n' >>"$_gopath_proj/modules/main.sh"
if _v "$_gopath_proj" apply >/dev/null 2>&1 &&
  _v "$_gopath_proj" env export environment.d >"$_tmp/gopath.out" 2>"$_tmp/gopath.err"; then
  if grep -Fx "GOPATH=$_home/go" "$_tmp/gopath.out" >/dev/null; then
    pass "env export keeps a \$HOME-derived scalar's real path"
  else
    fail "env export rewrote a \$HOME-derived scalar"
    grep 'GOPATH' "$_tmp/gopath.out" >&2
  fi
else
  fail "env export failed on a \$HOME-derived scalar"
  cat "$_tmp/gopath.err" >&2
fi
_multiline_proj="$_tmp/proj-multiline"
cp -R "$_proj" "$_multiline_proj"
printf 'MULTIV="first line\nsecond line"\nexport MULTIV\n' >>"$_multiline_proj/modules/main.sh"
if _v "$_multiline_proj" apply >/dev/null 2>&1; then
  if _v "$_multiline_proj" env export environment.d >"$_tmp/ml.out" 2>"$_tmp/ml.err"; then
    fail "env export accepted a value containing a newline"
    cat "$_tmp/ml.out" >&2
  elif grep -F 'MULTIV' "$_tmp/ml.err" >/dev/null; then
    pass "env export fails loudly on a value containing a newline"
  else
    fail "env export failed without naming the offending key"
    cat "$_tmp/ml.err" >&2
  fi
else
  fail "could not install the newline-value fixture"
fi
_noise_proj="$_tmp/proj-noise"
cp -R "$_proj" "$_noise_proj"
printf 'printf "FAKE_INJECTED=1\\n"\n' >>"$_noise_proj/modules/main.sh"
if _v "$_noise_proj" apply >/dev/null 2>&1 &&
  _v "$_noise_proj" env export environment.d >"$_tmp/noise.out" 2>&1; then
  if grep -q '^FAKE_INJECTED=' "$_tmp/noise.out"; then
    fail "module stdout injected a variable into the GUI env bridge"
    cat "$_tmp/noise.out" >&2
  else
    pass "module stdout cannot inject a variable into the GUI env bridge"
  fi
else
  fail "env export failed on the stdout-noise fixture"
fi
# A value the target format cannot represent must be refused BY NAME, not
# truncated into a different value. SOH is the internal record separator and
# would fabricate a variable mid-value; ESC and CR are outside the character
# range XML 1.0 permits, so the plist would not parse. Both must fail here,
# before publication, instead of emitting a corrupt bridge.
_ctrl_proj="$_tmp/proj-ctrl"
cp -R "$_proj" "$_ctrl_proj"
printf 'SOHV=$(printf "first\\001FORGED=second")\nexport SOHV\n' >>"$_ctrl_proj/modules/main.sh"
if _v "$_ctrl_proj" apply >/dev/null 2>&1; then
  if _v "$_ctrl_proj" env export environment.d >"$_tmp/soh.out" 2>"$_tmp/soh.err"; then
    if grep -q '^FORGED=' "$_tmp/soh.out"; then
      fail "a value containing SOH fabricated a variable in the GUI env bridge"
      cat "$_tmp/soh.out" >&2
    else
      fail "env export accepted a value containing a control byte"
      cat "$_tmp/soh.out" >&2
    fi
  elif grep -F 'SOHV' "$_tmp/soh.err" >/dev/null; then
    pass "env export refuses a value containing SOH and names the key"
  else
    fail "env export failed on a SOH value without naming the key"
    cat "$_tmp/soh.err" >&2
  fi
else
  fail "could not install the control-byte fixture"
fi
_esc_proj="$_tmp/proj-esc"
cp -R "$_proj" "$_esc_proj"
printf 'ESCV=$(printf "a\\033b")\nexport ESCV\n' >>"$_esc_proj/modules/main.sh"
if _v "$_esc_proj" apply >/dev/null 2>&1; then
  if _v "$_esc_proj" env export launchd >"$_tmp/esc.plist" 2>"$_tmp/esc.err"; then
    fail "env export launchd accepted a value containing ESC"
  elif grep -F 'ESCV' "$_tmp/esc.err" >/dev/null; then
    pass "env export launchd refuses a value containing ESC and names the key"
  else
    fail "env export launchd failed on an ESC value without naming the key"
    cat "$_tmp/esc.err" >&2
  fi
else
  fail "could not install the ESC fixture"
fi
# An export derived from XDG_CONFIG_HOME must carry the caller's REAL root.
# Replacing XDG_* with scratch paths made the value point into a directory the
# capture deletes before the bridge is ever read.
_xdg_proj="$_tmp/proj-xdg"
cp -R "$_proj" "$_xdg_proj"
printf 'MY_CONFIG="$XDG_CONFIG_HOME/tool"\nexport MY_CONFIG\n' >>"$_xdg_proj/modules/main.sh"
_xdg_home="$_tmp/home-xdg"
mkdir -p "$_xdg_home/.config"
# _xdg_v <args...>: one valise call with the fixture's XDG layout. The two steps
# are reported separately so a failure names the step that broke rather than
# collapsing into one opaque assertion.
_xdg_v() {
  env -i HOME="$_xdg_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_xdg_home/.local/share" \
    XDG_CONFIG_HOME="$_xdg_home/.config" XDG_STATE_HOME="$_xdg_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_xdg_proj" "$@"
}
if ! _xdg_v apply >"$_tmp/xdg-apply.out" 2>&1; then
  fail "the XDG-derived-scalar fixture installed"
  cat "$_tmp/xdg-apply.out" >&2
elif ! _xdg_v env export environment.d >"$_tmp/xdg.out" 2>"$_tmp/xdg.err"; then
  # Print the full diagnostic AND the fixture state: this assertion has failed
  # twice while another copy of the suite was running, and never in isolation,
  # so a recurrence must be self-diagnosing.
  fail "env export succeeded on an XDG-derived scalar"
  cat "$_tmp/xdg.err" >&2 2>/dev/null || :
  printf 'fixture: home=%s\n' "$_xdg_home" >&2
  ls -ld "$_xdg_home" "$_xdg_home/.config" 2>&1 >&2 || :
  printf 'active: ' >&2
  (cd "$_xdg_home/.config/valise/active" 2>/dev/null && pwd -P) >&2 || printf 'none\n' >&2
  printf 'releases: ' >&2
  ls "$_xdg_home/.local/share/valise/releases" 2>&1 >&2 || :
elif grep -Fx "MY_CONFIG=$_xdg_home/.config/tool" "$_tmp/xdg.out" >/dev/null; then
  pass "env export keeps an XDG_CONFIG_HOME-derived scalar's real path"
else
  fail "env export rewrote an XDG_CONFIG_HOME-derived scalar"
  grep 'MY_CONFIG' "$_tmp/xdg.out" >&2 2>/dev/null || cat "$_tmp/xdg.err" >&2
fi
# The dump utility is resolved BEFORE the plan runs and invoked absolutely. A
# plan may legitimately prepend a directory to PATH; if the dump were resolved
# afterwards, a forged `env` there could fabricate records.
_envpath_proj="$_tmp/proj-envpath"
cp -R "$_proj" "$_envpath_proj"
printf 'valise_path_prepend "$HOME/fakebin"\n' >>"$_envpath_proj/modules/main.sh"
# Rewrite the metadata portably (BSD and GNU sed spell in-place differently).
awk '$0 ~ /^requires=/ { print $0 " valise_path"; next } { print }' \
  "$_envpath_proj/module.d/main.meta" >"$_tmp/main.meta" &&
  mv "$_tmp/main.meta" "$_envpath_proj/module.d/main.meta"
if _v "$_envpath_proj" apply >/dev/null 2>&1; then
  mkdir -p "$_home/fakebin"
  cat >"$_home/fakebin/env" <<'EOF2'
#!/bin/sh
printf 'FORGED_FROM_PATH=1\0'
EOF2
  chmod +x "$_home/fakebin/env"
  if _v "$_envpath_proj" env export environment.d >"$_tmp/envpath.out" 2>"$_tmp/envpath.err"; then
    if grep -q '^FORGED_FROM_PATH=' "$_tmp/envpath.out"; then
      fail "a forged env on the plan's PATH influenced the capture"
      cat "$_tmp/envpath.out" >&2
    elif grep -q '^MAIN_SCALAR=' "$_tmp/envpath.out"; then
      pass "the env dump ignores an executable the plan prepended to PATH"
    else
      fail "the env dump lost the real exports when the plan prepended to PATH"
      cat "$_tmp/envpath.out" >&2
    fi
  else
    fail "env export failed when the plan prepended a directory to PATH"
    cat "$_tmp/envpath.err" >&2
  fi
  rm -rf "$_home/fakebin"
else
  fail "could not install the PATH-prepend fixture"
fi
# A launchd plist is XML, so a captured value must be valid UTF-8. A raw high
# byte passed the C0 scan but produced a plist plutil REFUSED ("Unable to
# convert string to correct encoding") while the renderer reported success.
_utf8_proj="$_tmp/proj-utf8"
cp -R "$_proj" "$_utf8_proj"
printf 'HIGHV=$(printf "a\\200b")\nexport HIGHV\n' >>"$_utf8_proj/modules/main.sh"
if _v "$_utf8_proj" apply >/dev/null 2>&1; then
  if _v "$_utf8_proj" env export launchd >"$_tmp/utf8.plist" 2>"$_tmp/utf8.err"; then
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$_tmp/utf8.plist" >/dev/null 2>&1; then
      fail "a value with an invalid UTF-8 byte is refused before it reaches the plist"
      plutil -lint "$_tmp/utf8.plist" >&2 2>&1 || :
    else
      fail "env export accepted a value with an invalid UTF-8 byte"
    fi
  elif grep -F 'not valid UTF-8' "$_tmp/utf8.err" >/dev/null; then
    pass "a value with an invalid UTF-8 byte is refused before it reaches the plist"
  else
    fail "env export failed on an invalid UTF-8 byte without naming the reason"
    cat "$_tmp/utf8.err" >&2
  fi
else
  fail "could not install the invalid-UTF-8 fixture"
fi
# Valid multibyte UTF-8 must still be bridged and must still parse.
_utf8ok_proj="$_tmp/proj-utf8ok"
cp -R "$_proj" "$_utf8ok_proj"
printf 'UTFV=$(printf "caf\\303\\251")\nexport UTFV\n' >>"$_utf8ok_proj/modules/main.sh"
if _v "$_utf8ok_proj" apply >/dev/null 2>&1 &&
  _v "$_utf8ok_proj" env export launchd >"$_tmp/utf8ok.plist" 2>"$_tmp/utf8ok.err" &&
  grep -F 'UTFV' "$_tmp/utf8ok.plist" >/dev/null; then
  if ! command -v plutil >/dev/null 2>&1 || plutil -lint "$_tmp/utf8ok.plist" >/dev/null 2>&1; then
    pass "a valid multibyte UTF-8 value is bridged and parses"
  else
    fail "a valid multibyte UTF-8 value produced an unparseable plist"
    plutil -lint "$_tmp/utf8ok.plist" >&2 2>&1 || :
  fi
else
  fail "env export rejected a valid multibyte UTF-8 value"
  cat "$_tmp/utf8ok.err" >&2 2>/dev/null || :
fi

# The probe must hand VALISE_MODULE_ROOT to the inner shell in a way that
# actually reaches it. The capture assigns it at the source site from a
# positional parameter, exactly as the managed block does
# (`VALISE_MODULE_ROOT="$_valise_active"` before sourcing) and as the module
# authoring docs show for a nested shell. When it was instead passed as an
# argument to the _fixture helper, this lane failed intermittently - one run in
# three - with "runtime/capabilities.sh: No such file"; assigning at the source
# site ran clean six times in a row. A plain, clean project must always capture.
_reach_proj="$_tmp/proj-reach"
cp -R "$_proj" "$_reach_proj"
if _v "$_reach_proj" apply >/dev/null 2>&1 &&
  _v "$_reach_proj" env export environment.d >"$_tmp/reach.out" 2>"$_tmp/reach.err"; then
  if grep -F 'runtime/capabilities.sh' "$_tmp/reach.err" >/dev/null; then
    fail "the env capture resolves the module root for the plan"
    cat "$_tmp/reach.err" >&2
  else
    pass "the env capture resolves the module root for the plan"
  fi
else
  fail "the env capture resolves the module root for the plan (capture failed)"
  cat "$_tmp/reach.err" >&2
fi

# The env-export cases above legitimately ran `apply`, which installs into
# $_home, so this assertion only checks that no TMPDIR scratch is left behind:
# the capture must remove its own scratch dir on every path.
# --- env export renderers: value fidelity ---
# A launchd value is executed by /bin/sh. Extract the command string, unescape
# the XML, run it with a stub launchctl, and assert the exact argv.
_torture_proj="$_tmp/proj-torture"
cp -R "$_proj" "$_torture_proj"
cat >>"$_torture_proj/modules/main.sh" <<'EOF2'
TORMENT1='a b;c$d'
TORMENT2="e'f\"g\\h"
export TORMENT1 TORMENT2
EOF2
if _v "$_torture_proj" apply >/dev/null 2>&1 &&
  _v "$_torture_proj" env export launchd >"$_tmp/torture.plist" 2>"$_tmp/torture.err"; then
  mkdir -p "$_tmp/stub"
  cat >"$_tmp/stub/launchctl" <<'EOF2'
#!/bin/sh
printf 'argc=%s\n' "$#"
for _a in "$@"; do printf 'arg=[%s]\n' "$_a"; done
EOF2
  chmod +x "$_tmp/stub/launchctl"
  _cmd_line=$(sed -n 's:.*<string>\(launchctl setenv .*\)</string>.*:\1:p' "$_tmp/torture.plist" |
    sed 's/&quot;/"/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g')
  _stub_out=$(PATH="$_tmp/stub:/usr/bin:/bin" /bin/sh -c "$_cmd_line" 2>&1)
  if printf '%s\n' "$_stub_out" | grep -Fx 'arg=[a b;c$d]' >/dev/null &&
    printf '%s\n' "$_stub_out" | grep -Fx 'arg=[e'"'"'f"g\h]' >/dev/null; then
    pass "env export launchd round-trips shell metacharacters to launchctl argv"
  else
    fail "env export launchd corrupts shell metacharacters"
    printf '%s\n' "$_stub_out" >&2
  fi
  if ! command -v plutil >/dev/null 2>&1; then
    skip "env export launchd torture plist passes plutil -lint (plutil unavailable)"
  elif plutil -lint "$_tmp/torture.plist" >/dev/null 2>&1; then
    pass "env export launchd torture plist passes plutil -lint"
  else
    fail "env export launchd torture plist fails plutil -lint"
  fi
else
  fail "env export launchd torture case did not run"
  cat "$_tmp/torture.err" >&2 2>/dev/null || :
fi
# environment.d must double '$' (systemd expands it even inside quotes).
if _v "$_torture_proj" env export environment.d >"$_tmp/torture.ed" 2>&1 &&
  grep -Fx 'TORMENT1="a b;c$$d"' "$_tmp/torture.ed" >/dev/null; then
  pass "env export environment.d doubles \$ so systemd leaves it literal"
else
  fail "env export environment.d did not double \$"
  grep 'TORMENT1' "$_tmp/torture.ed" >&2 2>/dev/null || :
fi
# environment.d must escape backslashes and double quotes CHARACTER BY
# CHARACTER. A gsub replacement string has its own backslash rules: two
# backslashes yield two on BWK/gawk/mawk but ONE on BusyBox awk and
# `gawk --posix`, which writes a\b as "a\b" (systemd reads ab) and lets a
# trailing backslash escape the closing quote. Asserted on the bytes rather
# than trusting the implementation, so the host awk that runs is the oracle.
_bs_proj="$_tmp/proj-backslash"
cp -R "$_proj" "$_bs_proj"
cat >>"$_bs_proj/modules/main.sh" <<'EOF2'
BSMID='a\b'
BSQUOTE='x"y'
BSTRAIL='end\'
export BSMID BSQUOTE BSTRAIL
EOF2
if _v "$_bs_proj" apply >/dev/null 2>&1 &&
  _v "$_bs_proj" env export environment.d >"$_tmp/bs.ed" 2>&1 &&
  grep -Fx 'BSMID="a\\b"' "$_tmp/bs.ed" >/dev/null &&
  grep -Fx 'BSQUOTE="x\"y"' "$_tmp/bs.ed" >/dev/null &&
  grep -Fx 'BSTRAIL="end\\"' "$_tmp/bs.ed" >/dev/null; then
  pass "env export environment.d escapes backslashes and quotes byte-exactly"
else
  fail "env export environment.d corrupted a backslash or a double quote"
  grep -F 'BS' "$_tmp/bs.ed" >&2 2>/dev/null || :
  cat "$_tmp/bs.ed" >&2 2>/dev/null || :
fi
# WSLENV flags follow the value shape, not a substring of the key.
_wsl_proj="$_tmp/proj-wsl"
cp -R "$_proj" "$_wsl_proj"
cat >>"$_wsl_proj/modules/main.sh" <<'EOF2'
MANPATH=/usr/share/man:/usr/local/share/man
SINGLE=/usr/local/bin
CLASSPATH=foo:bar
export MANPATH SINGLE CLASSPATH
EOF2
if _v "$_wsl_proj" apply >/dev/null 2>&1 &&
  _v "$_wsl_proj" env export wsl >"$_tmp/wsl.out" 2>&1; then
  _wsl_line=$(grep '^WSLENV=' "$_tmp/wsl.out" | head -n 1)
  if printf '%s' "$_wsl_line" | grep -q 'MANPATH/l' &&
    printf '%s' "$_wsl_line" | grep -q 'SINGLE/p' &&
    printf '%s' "$_wsl_line" | grep -Eq '(^|:)CLASSPATH(:|$)'; then
    pass "env export wsl derives the flag from the value shape, not the key"
  else
    fail "env export wsl mislabels variables"
    printf '%s\n' "$_wsl_line" >&2
  fi
else
  fail "env export wsl flag case did not run"
fi
# --help is a help request, not a usage error.
if _v "$_proj" env export --help >"$_tmp/env-help.out" 2>&1 &&
  grep -F 'usage: valise env' "$_tmp/env-help.out" >/dev/null; then
  pass "env export --help prints usage"
else
  fail "env export --help does not print usage"
fi

# --- gui_env lifecycle ---
# The mode is recorded in the release at build time, so an install from a
# relocated release tree still writes the bridge.
_reloc_home="$_tmp/home-reloc"
mkdir -p "$_reloc_home"
if [ -d "$_gui_proj/build/release" ] && [ "$(uname -s)" = Darwin ]; then
  rm -rf "$_tmp/reloc"
  cp -R "$_gui_proj/build/release" "$_tmp/reloc"
  if ( cd "$_tmp/reloc" && env -i HOME="$_reloc_home" PATH="${PATH:-/usr/bin:/bin}" \
      XDG_DATA_HOME="$_reloc_home/.local/share" XDG_CONFIG_HOME="$_reloc_home/.config" \
      XDG_STATE_HOME="$_reloc_home/.local/state" SHELL=/bin/bash TMPDIR="$_tmp" \
      "$_valise" install ) >"$_tmp/reloc-install.out" 2>&1 &&
    [ -f "$_reloc_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
    pass "install from a relocated release tree writes the declared gui_env bridge"
  else
    fail "install from a relocated release tree did not write the bridge"
    cat "$_tmp/reloc-install.out" >&2
  fi
else
  skip "install from a relocated release tree writes the declared gui_env bridge (not darwin)"
fi
# gui_env=off on the next release removes the bridge the previous one wrote.
# This builds its own fixture so it does not depend on a sibling case having
# run first.
if [ "$(uname -s)" = Darwin ]; then
  _off_home="$_tmp/home-gui-off"
  mkdir -p "$_off_home"
  _off_proj="$_tmp/proj-gui-off"
  cp -R "$_proj" "$_off_proj"
  printf 'gui_env=launchd\n' >>"$_off_proj/valise.conf"
  env -i HOME="$_off_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_off_home/.local/share" \
    XDG_CONFIG_HOME="$_off_home/.config" XDG_STATE_HOME="$_off_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_off_proj" apply >"$_tmp/gui-off-first.out" 2>&1 || :
  if [ ! -f "$_off_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
    fail "the gui_env=off fixture did not write a bridge to remove"
  else
    sed 's/^gui_env=launchd$/gui_env=off/' "$_off_proj/valise.conf" >"$_tmp/gui-off.conf"
    cp "$_tmp/gui-off.conf" "$_off_proj/valise.conf"
    env -i HOME="$_off_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_off_home/.local/share" \
      XDG_CONFIG_HOME="$_off_home/.config" XDG_STATE_HOME="$_off_home/.local/state" SHELL=/bin/bash \
      TMPDIR="$_tmp" "$_valise" -C "$_off_proj" apply >"$_tmp/gui-off.out" 2>&1 || :
    if [ ! -e "$_off_home/Library/LaunchAgents/sh.valise.env.plist" ]; then
      pass "gui_env=off removes the bridge an earlier release wrote"
    else
      fail "gui_env=off left a stale bridge behind"
      cat "$_tmp/gui-off.out" >&2
    fi
  fi
else
  skip "gui_env=off removes the bridge an earlier release wrote (not darwin)"
fi
# --- GUI env bridge: format, mode, transaction, and no-integration ---

# _gui_v <home> <project> <args...>: one valise call with a given home.
_gui_v() {
  _gv_home=$1
  _gv_proj=$2
  shift 2
  env -i HOME="$_gv_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_gv_home/.local/share" \
    XDG_CONFIG_HOME="$_gv_home/.config" XDG_STATE_HOME="$_gv_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_gv_proj" "$@"
}

# The configured mode is `systemd`; the renderer's format is `environment.d`.
# Passing the configured name straight through made every automatic systemd
# bridge fail to render while install still announced that it had written one.
_sd_home="$_tmp/home-systemd"
mkdir -p "$_sd_home"
_sd_proj="$_tmp/proj-systemd"
cp -R "$_proj" "$_sd_proj"
printf 'gui_env=systemd\n' >>"$_sd_proj/valise.conf"
if [ "$(uname -s)" != Linux ]; then
  skip "gui_env=systemd writes environment.d/10-valise.conf on install (not Linux; skipped by design)"
  skip "the gui_env=systemd success line appears only when the file exists (not Linux)"
else
  if _gui_v "$_sd_home" "$_sd_proj" apply >"$_tmp/sd-apply.out" 2>&1; then
    _sd_file="$_sd_home/.config/environment.d/10-valise.conf"
    if [ -f "$_sd_file" ] && grep -q '^MAIN_SCALAR=' "$_sd_file" &&
      grep -F "GUI env bridge written (systemd): $_sd_file" "$_tmp/sd-apply.out" >/dev/null; then
      pass "gui_env=systemd writes environment.d/10-valise.conf on install"
    else
      fail "gui_env=systemd did not write the environment.d bridge"
      cat "$_tmp/sd-apply.out" >&2
      ls -l "$_sd_home/.config/environment.d" >&2 2>/dev/null || :
    fi
    # Captured values can come from a local-secret module, so the bridge must
    # not be world-readable over a restrictive umask.
    if [ "$(stat -c '%a' "$_sd_file" 2>/dev/null || stat -f '%Lp' "$_sd_file")" = 600 ]; then
      pass "the GUI env bridge is published mode 0600"
    else
      fail "the GUI env bridge is not mode 0600"
      ls -l "$_sd_file" >&2 2>/dev/null || :
    fi
  else
    fail "gui_env=systemd apply failed"
    cat "$_tmp/sd-apply.out" >&2
  fi
  # A capture failure must not leave the previous release's bridge describing
  # the previous env while apply reports success: prepare before the switch and
  # abort the switch when preparation fails.
  _stale_home="$_tmp/home-stale"
  mkdir -p "$_stale_home"
  _stale_proj="$_tmp/proj-stale"
  cp -R "$_proj" "$_stale_proj"
  printf 'gui_env=systemd\n' >>"$_stale_proj/valise.conf"
  _gui_v "$_stale_home" "$_stale_proj" apply >/dev/null 2>&1 || :
  _stale_file="$_stale_home/.config/environment.d/10-valise.conf"
  if [ ! -f "$_stale_file" ]; then
    fail "the stale-bridge fixture did not write an initial bridge"
  else
    _stale_id_before=$(cd "$_stale_home/.config/valise/active" 2>/dev/null && pwd -P) || _stale_id_before=
    # A second release whose env plan exports an unrepresentable value: the
    # capture must refuse, and apply must NOT switch to it.
    printf '%s\n' 'unrepresentable() { :; }' 'UNREPRESENTABLE="$(printf "a\nb")"' \
      'export UNREPRESENTABLE' >>"$_stale_proj/modules/main.sh"
    if _gui_v "$_stale_home" "$_stale_proj" apply >"$_tmp/stale-apply.out" 2>&1; then
      fail "apply fails when the env plan cannot be captured for the bridge (it succeeded)"
    else
      _stale_id_after=$(cd "$_stale_home/.config/valise/active" 2>/dev/null && pwd -P) || _stale_id_after=
      if [ "$_stale_id_after" = "$_stale_id_before" ]; then
        pass "apply with an uncapturable env plan leaves the active release unchanged"
      else
        fail "apply switched the active release before the bridge could be prepared"
        printf 'before=%s after=%s\n' "$_stale_id_before" "$_stale_id_after" >&2
      fi
    fi
  fi
  # --no-integration promises no startup file, shim, hook, bridge, or stubs.
  # A later release switch must not quietly write one.
  _ni_home="$_tmp/home-no-int"
  mkdir -p "$_ni_home"
  _ni_proj="$_tmp/proj-no-int"
  cp -R "$_proj" "$_ni_proj"
  printf 'gui_env=systemd\n' >>"$_ni_proj/valise.conf"
  _gui_v "$_ni_home" "$_ni_proj" apply --no-integration >"$_tmp/ni-apply.out" 2>&1 || :
  if [ -e "$_ni_home/.config/environment.d/10-valise.conf" ]; then
    fail "--no-integration wrote a GUI env bridge"
  else
    _ni_id=$(cd "$_ni_home/.config/valise/active" 2>/dev/null && pwd -P) || _ni_id=
    _ni_id=${_ni_id##*/}
    if [ -n "$_ni_id" ] && _gui_v "$_ni_home" "$_ni_proj" release use "$_ni_id" >"$_tmp/ni-use.out" 2>&1; then
      if [ ! -e "$_ni_home/.config/environment.d/10-valise.conf" ]; then
        pass "release use after --no-integration writes no GUI env bridge"
      else
        fail "release use after --no-integration wrote a GUI env bridge"
      fi
    else
      fail "release use after --no-integration failed"
      cat "$_tmp/ni-use.out" >&2 2>/dev/null || :
    fi
  fi
fi

# --dry-run reports the shim and the bridge.
_dry_proj="$_tmp/proj-dry"
cp -R "$_gui_proj" "$_dry_proj"
_dry_home="$_tmp/home-dry"
mkdir -p "$_dry_home"
if env -i HOME="$_dry_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_dry_home/.local/share" \
  XDG_CONFIG_HOME="$_dry_home/.config" XDG_STATE_HOME="$_dry_home/.local/state" SHELL=/bin/bash \
  TMPDIR="$_tmp" "$_valise" -C "$_dry_proj" apply --dry-run >"$_tmp/dry.out" 2>&1 &&
  grep -F "$_dry_home/.config/valise/env.sh" "$_tmp/dry.out" >/dev/null &&
  grep -F 'gui env bridge' "$_tmp/dry.out" >/dev/null; then
  pass "apply --dry-run names the ENV shim and the GUI env bridge"
else
  fail "apply --dry-run omits the shim or the bridge"
  cat "$_tmp/dry.out" >&2
fi
# A local-state module is allowed by the ABI to create directories under
# $XDG_STATE_HOME. A dry run that CAPTURES the env plan executes that body
# against the real HOME, contradicting its "nothing outside build/ is written"
# promise, so the preview must report the bridge without capturing.
_side_proj="$_tmp/proj-dry-side"
cp -R "$_proj" "$_side_proj"
printf 'gui_env=launchd\n' >>"$_side_proj/valise.conf"
cat >>"$_side_proj/modules/main.sh" <<'EOF2'
DRY_STATE="$HOME/dry-run-side-effect"
mkdir -p "$DRY_STATE/app"
export DRY_STATE
EOF2
_dry_side_home="$_tmp/home-dry-side"
mkdir -p "$_dry_side_home"
env -i HOME="$_dry_side_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_dry_side_home/.local/share" \
  XDG_CONFIG_HOME="$_dry_side_home/.config" XDG_STATE_HOME="$_dry_side_home/.local/state" SHELL=/bin/bash \
  TMPDIR="$_tmp" "$_valise" -C "$_side_proj" apply --dry-run >"$_tmp/dry-side.out" 2>&1 || :
if [ ! -e "$_dry_side_home/dry-run-side-effect" ]; then
  pass "apply --dry-run does not execute module bodies against the real HOME"
else
  fail "apply --dry-run wrote into the real HOME"
  ls -l "$_dry_side_home/dry-run-side-effect" >&2 2>/dev/null || :
fi
if grep -F 'would regenerate:' "$_tmp/dry-side.out" >/dev/null ||
  grep -F 'would create:' "$_tmp/dry-side.out" >/dev/null; then
  pass "apply --dry-run reports the bridge action without rendering it"
else
  fail "apply --dry-run did not report the bridge action"
  cat "$_tmp/dry-side.out" >&2
fi

# A dry run must agree with install about OWNERSHIP: a file at the bridge path
# that valise does not own is left alone, and the preview must say so rather
# than promising an update install will never perform.
_dry_foreign_home="$_tmp/home-dry-foreign"
mkdir -p "$_dry_foreign_home/.config/environment.d"
printf 'foreign\n' >"$_dry_foreign_home/.config/environment.d/10-valise.conf"
# The fixture must ask for the SYSTEMD bridge: this lane runs on Linux, where a
# launchd project is skipped by design and the ownership path is never reached.
_dry_foreign_proj="$_tmp/proj-dry-foreign"
cp -R "$_proj" "$_dry_foreign_proj"
printf 'gui_env=systemd\n' >>"$_dry_foreign_proj/valise.conf"
env -i HOME="$_dry_foreign_home" PATH="${PATH:-/usr/bin:/bin}" XDG_DATA_HOME="$_dry_foreign_home/.local/share" \
  XDG_CONFIG_HOME="$_dry_foreign_home/.config" XDG_STATE_HOME="$_dry_foreign_home/.local/state" SHELL=/bin/bash \
  TMPDIR="$_tmp" "$_valise" -C "$_dry_foreign_proj" apply --dry-run >"$_tmp/dry-foreign.out" 2>&1 || :
if [ "$(uname -s)" = Linux ]; then
  if grep -F 'left alone (not the valise bridge):' "$_tmp/dry-foreign.out" >/dev/null &&
    [ "$(cat "$_dry_foreign_home/.config/environment.d/10-valise.conf")" = foreign ]; then
    pass "apply --dry-run leaves a foreign bridge file alone and says so"
  else
    fail "apply --dry-run misreported a foreign bridge file"
    cat "$_tmp/dry-foreign.out" >&2
  fi
else
  skip "apply --dry-run leaves a foreign bridge file alone and says so (not Linux)"
fi

if [ -z "$(ls -A "$_tmp" | grep '^valise-dev\.\|^valise-env-export\.' || :)" ]; then
  pass "lint, test, run, and env export leave no scratch behind in TMPDIR"
else
  fail "lint, test, run, and env export leave no scratch behind in TMPDIR"
  ls -A "$_tmp" >&2
fi

# The developer runner must start each reload with fresh availability. A
# dependency that fails on the first load, whose prerequisite is then created,
# must run its interactive dependent when valise_test_reload runs again. The
# optional edges keep the initial load successful, as a real optional module is.
_rp="$_tmp/reload-proj"
mkdir -p "$_rp/module.d" "$_rp/modules" "$_rp/tests"
printf '%s\n' 'bundle=default' 'variant=default' >"$_rp/valise.conf"
printf 'default\tbash\treload_root\n' >"$_rp/bundles.tsv"
_meta "$_rp/module.d/reload_root.meta" name=reload_root version=1.0.0 side_effect=read-only \
  'requires=' 'optional=flaky_child' shells=bash platforms=any exports=reload_root_fn \
  load=modules/reload_root.sh tests=tests/reload.sh
printf 'reload_root_fn() { :; }\n' >"$_rp/modules/reload_root.sh"
_meta "$_rp/module.d/flaky_child.meta" name=flaky_child version=1.0.0 side_effect=read-only \
  requires=flaky_dep 'optional=' shells=bash platforms=any phase=interactive exports=flaky_child_fn \
  load=modules/flaky_child.sh tests=
printf 'flaky_child_fn() { :; }\necho ran >>"$HOME/child.log"\n' >"$_rp/modules/flaky_child.sh"
_meta "$_rp/module.d/flaky_dep.meta" name=flaky_dep version=1.0.0 side_effect=read-only \
  'requires=' 'optional=' shells=bash platforms=any exports=flaky_dep_fn \
  load=modules/flaky_dep.sh tests=
printf '%s\n' '[ -f "$HOME/flaky-prereq" ] || return 1' 'flaky_dep_fn() { :; }' >"$_rp/modules/flaky_dep.sh"
printf '%s\n' 'if [ -s "$HOME/child.log" ]; then echo "child ran before the prerequisite"; exit 1; fi' \
  ': >"$HOME/flaky-prereq"' 'valise_test_reload || { echo "reload failed"; exit 1; }' \
  '[ -s "$HOME/child.log" ] || { echo "the repaired dependency did not run its dependent"; exit 1; }' \
  >"$_rp/tests/reload.sh"
if _v "$_rp" test --shell=bash >"$_tmp/reload.out" 2>&1 &&
  grep -F 'valise test: 1 passed, 0 failed' "$_tmp/reload.out" >/dev/null; then
  pass "valise_test_reload runs a dependent once its failed dependency is repaired"
else
  fail "valise_test_reload kept a repaired dependency unavailable"
  cat "$_tmp/reload.out" >&2
fi

# The runner must not leak its own bookkeeping into the body it runs. An
# env-only release has no interactive plan, which is what used to keep
# VALISE_MODULE_ROOT set, and the plan leaves _valise_plan_carried set even
# when empty, so `${...+set}` detects it. The MODULE body legitimately runs
# while VALISE_MODULE_ROOT is set (the plan sources capabilities.sh through
# it); the leak the runner used to have was into the TEST callback and into a
# `run` script, which execute after the plans. Those are the oracles here: each
# exits nonzero when a private name is visible, so the command itself fails.
_rl="$_tmp/leak-proj"
mkdir -p "$_rl/module.d" "$_rl/modules" "$_rl/tests"
printf '%s\n' 'bundle=default' 'variant=default' >"$_rl/valise.conf"
printf 'default\tbash\tenvonly\ndefault\tbash\tinteractiveone\n' >"$_rl/bundles.tsv"
_meta "$_rl/module.d/envonly.meta" name=envonly version=1.0.0 side_effect=read-only \
  'requires=' 'optional=' shells=bash platforms=any exports=envonly_fn \
  load=modules/envonly.sh tests=tests/check.sh
_meta "$_rl/module.d/interactiveone.meta" name=interactiveone version=1.0.0 side_effect=read-only \
  'requires=' 'optional=' shells=bash platforms=any phase=interactive exports=interactiveone_fn \
  load=modules/interactiveone.sh tests=tests/check.sh
printf 'envonly_fn() { :; }\n' >"$_rl/modules/envonly.sh"
printf 'interactiveone_fn() { :; }\n' >"$_rl/modules/interactiveone.sh"
# check.sh is shared by both modules and is also used as the `run` script.
# It checks the state BEFORE and AFTER a reload, because valise_test_reload
# sets both names around the plan sources and must clear them again.
cat >"$_rl/tests/check.sh" <<'EOF2'
if [ "${VALISE_MODULE_ROOT+x}" = x ]; then
  printf 'leaked: VALISE_MODULE_ROOT\n' >&2
  exit 1
fi
if [ "${_valise_plan_carried+x}" = x ]; then
  printf 'leaked: _valise_plan_carried\n' >&2
  exit 1
fi
if [ "${1-}" = reload ]; then
  valise_test_reload || { printf 'reload failed\n' >&2; exit 1; }
  if [ "${VALISE_MODULE_ROOT+x}" = x ]; then
    printf 'leaked after reload: VALISE_MODULE_ROOT\n' >&2
    exit 1
  fi
  if [ "${_valise_plan_carried+x}" = x ]; then
    printf 'leaked after reload: _valise_plan_carried\n' >&2
    exit 1
  fi
fi
EOF2
# The test callback takes no arguments, so it gets a reload-free variant.
printf '%s\n' \
  'if [ "${VALISE_MODULE_ROOT+x}" = x ]; then printf "leaked: VALISE_MODULE_ROOT\n" >&2; exit 1; fi' \
  'if [ "${_valise_plan_carried+x}" = x ]; then printf "leaked: _valise_plan_carried\n" >&2; exit 1; fi' \
  'valise_test_reload || { printf "reload failed\n" >&2; exit 1; }' \
  'if [ "${VALISE_MODULE_ROOT+x}" = x ]; then printf "leaked after reload: VALISE_MODULE_ROOT\n" >&2; exit 1; fi' \
  'if [ "${_valise_plan_carried+x}" = x ]; then printf "leaked after reload: _valise_plan_carried\n" >&2; exit 1; fi' \
  >"$_rl/tests/check.sh"
for _leak_mod in envonly interactiveone; do
  if _v "$_rl" test --shell=bash >"$_tmp/leak-$_leak_mod-test.out" 2>&1; then
    pass "valise test leaks no runner state into a $_leak_mod callback"
  else
    fail "valise test leaked runner state into a $_leak_mod callback"
    cat "$_tmp/leak-$_leak_mod-test.out" >&2
  fi
  # `valise run -- <script>` takes the script INLINE, so it carries the same
  # checks the callback does.
  _leak_script=$(
    printf '%s\n' \
      'if [ "${VALISE_MODULE_ROOT+x}" = x ]; then printf "leaked: VALISE_MODULE_ROOT\n" >&2; exit 1; fi' \
      'if [ "${_valise_plan_carried+x}" = x ]; then printf "leaked: _valise_plan_carried\n" >&2; exit 1; fi' \
      'valise_test_reload || { printf "reload failed\n" >&2; exit 1; }' \
      'if [ "${VALISE_MODULE_ROOT+x}" = x ]; then printf "leaked after reload: VALISE_MODULE_ROOT\n" >&2; exit 1; fi' \
      'if [ "${_valise_plan_carried+x}" = x ]; then printf "leaked after reload: _valise_plan_carried\n" >&2; exit 1; fi'
  )
  if _v "$_rl" run --shell=bash --module="$_leak_mod" -- "$_leak_script" >"$_tmp/leak-$_leak_mod-run.out" 2>&1; then
    pass "valise run leaks no runner state into a $_leak_mod script"
  else
    fail "valise run leaked runner state into a $_leak_mod script"
    cat "$_tmp/leak-$_leak_mod-run.out" >&2
  fi
done

# --- GUI env capture fidelity and refusal (review findings on env export) ---
# One fixture project, one module whose body is replaced per case, applied with
# gui_env=off so `apply` never captures; `env export` is the thing under test.
_cp="$_tmp/capture-proj"
_cap_home="$_tmp/cap-home"
mkdir -p "$_cp/module.d" "$_cp/modules" "$_cap_home" "$_tmp/fakebin"
printf '%s\n' 'bundle=default' 'variant=default' 'gui_env=off' >"$_cp/valise.conf"
printf 'default\tsh\tcapmod\ndefault\tbash\tcapmod\n' >"$_cp/bundles.tsv"
_meta "$_cp/module.d/capmod.meta" name=capmod version=1.0.0 side_effect=read-only \
  'requires=' 'optional=' shells=posix platforms=any exports= load=modules/capmod.sh tests=
# The fakebin `sh` must resolve like the real bash/zsh/ksh interpreters do -
# from PATH - so link the bash found on PATH instead of hardcoding /bin/bash.
_cap_bash=$(command -v bash 2>/dev/null || :)
[ -n "$_cap_bash" ] || _cap_bash=/bin/bash
ln -sf "$_cap_bash" "$_tmp/fakebin/sh"
unset _cap_bash
# _cap_body: the module body for the next case, read from stdin.
_cap_body() { cat >"$_cp/modules/capmod.sh"; }
# _cap_apply: install the current body (no capture: gui_env=off).
_cap_apply() {
  env -i HOME="$_cap_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_cap_home/.local/share" \
    XDG_CONFIG_HOME="$_cap_home/.config" XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$_valise" -C "$_cp" apply >"$_tmp/cap-apply.out" 2>&1
}
# _cap_export <format> [VAR=value...]: run `env export` for the active release.
_cap_export() {
  _ce_format=$1
  shift
  env -i HOME="$_cap_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_cap_home/.local/share" \
    XDG_CONFIG_HOME="$_cap_home/.config" XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/bash \
    TMPDIR="$_tmp" "$@" "$_valise" -C "$_cp" env export "$_ce_format" \
    >"$_tmp/cap-export.out" 2>"$_tmp/cap-export.err"
  _ce_rc=$?
  unset _ce_format
  return "$_ce_rc"
}

# Scenario A: a plan derived from the caller's TMPDIR keeps the caller's path.
mkdir -p "$_tmp/caller-tmp"
_cap_body <<'EOF'
CAP_CACHE="$TMPDIR/tool-cache"
export CAP_CACHE
EOF
if _cap_apply && _cap_export environment.d "TMPDIR=$_tmp/caller-tmp" &&
  grep -Fx "CAP_CACHE=$_tmp/caller-tmp/tool-cache" "$_tmp/cap-export.out" >/dev/null; then
  pass "env export keeps the caller's TMPDIR for a derived export"
else
  fail "env export replaced the caller's TMPDIR with another path"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

# Scenario B: an UNSET XDG_CONFIG_HOME stays unset in the plan, so its default applies.
_cap_body <<'EOF'
: "${XDG_CONFIG_HOME:=$HOME/custom-config}"
CAP_CFG="$XDG_CONFIG_HOME/tool"
export CAP_CFG
EOF
if env -i HOME="$_cap_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_cap_home/.local/share" \
  XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/bash TMPDIR="$_tmp" \
  "$_valise" -C "$_cp" apply >"$_tmp/cap-apply.out" 2>&1 &&
  env -i HOME="$_cap_home" PATH=/usr/bin:/bin XDG_DATA_HOME="$_cap_home/.local/share" \
  XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/bash TMPDIR="$_tmp" \
  "$_valise" -C "$_cp" env export environment.d >"$_tmp/cap-unset.out" 2>"$_tmp/cap-unset.err" &&
  grep -Fx "CAP_CFG=$_cap_home/custom-config/tool" "$_tmp/cap-unset.out" >/dev/null; then
  pass "env export applies a module's default for an unset XDG root"
else
  fail "env export gave an unset XDG root a value the session would not see"
  cat "$_tmp/cap-unset.out" "$_tmp/cap-unset.err" >&2 2>/dev/null || :
fi

# Scenario C: a SET XDG cache root reaches the plan unchanged. The cache root is
# used because valise locates its own active link under XDG_CONFIG_HOME, so
# overriding that variable for the valise command would move the release.
_cap_body <<'EOF'
CAP_CACHE_X="$XDG_CACHE_HOME/x"
export CAP_CACHE_X
EOF
if _cap_apply && _cap_export environment.d "XDG_CACHE_HOME=$_tmp/caller-cache" &&
  grep -Fx "CAP_CACHE_X=$_tmp/caller-cache/x" "$_tmp/cap-export.out" >/dev/null; then
  pass "env export uses the caller's set XDG root"
else
  fail "env export did not use the caller's set XDG root"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

# Scenario D: control-byte, newline, and noncharacter values are refused by name,
# and the forged record is never published. Each case is its own module body.
_refuse_case() {
  _rc_name=$1
  _rc_expect=$2
  if _cap_apply && ! _cap_export environment.d &&
    grep -F "$_rc_expect" "$_tmp/cap-export.err" >/dev/null &&
    [ ! -s "$_tmp/cap-export.out" ]; then
    pass "$_rc_name is refused"
  else
    fail "$_rc_name was not refused as an unrepresentable value"
    cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
  fi
}
_cap_body <<'EOF'
X='a
FORGED=1'
export X
EOF
_refuse_case "a newline followed by an assignment-shaped tail" 'sets X to a value containing a newline'
_cap_body <<'EOF'
CAP_SOH=$(printf 'a\001b')
export CAP_SOH
EOF
_refuse_case "an SOH byte (0x01)" 'CAP_SOH'
_cap_body <<'EOF'
CAP_ESC=$(printf 'a\033b')
export CAP_ESC
EOF
_refuse_case "an ESC byte (0x1b)" 'CAP_ESC'
_cap_body <<'EOF'
CAP_NONCHAR=$(printf '\357\277\276')
export CAP_NONCHAR
EOF
_refuse_case "U+FFFE, an XML noncharacter" 'CAP_NONCHAR'
_cap_body <<'EOF'
CAP_NONCHAR=$(printf '\357\277\277')
export CAP_NONCHAR
EOF
_refuse_case "U+FFFF, an XML noncharacter" 'CAP_NONCHAR'

_cap_body <<'EOF'
CAP_INVALID_UTF8=$(printf '\200')
export CAP_INVALID_UTF8
EOF
_refuse_case "an invalid UTF-8 value" 'not valid UTF-8'

# Scenario E: representable values still export: valid multibyte UTF-8 exports
# to both environment.d and launchd; TAB and DEL are preserved by launchd and
# refused by name for environment.d (systemd alters TAB/DEL on round-trip);
# Unicode noncharacters (e.g. U+FDD0, U+1FFFE, U+10FFFF) are refused by name
# for environment.d.
_cap_body <<'EOF'
CAP_UTF=$(printf 'caf\303\251')
export CAP_UTF
EOF
if _cap_apply && _cap_export environment.d && grep -Fx "CAP_UTF=$(printf 'caf\303\251')" "$_tmp/cap-export.out" >/dev/null; then
  pass "valid multibyte UTF-8 values are exported to environment.d"
else
  fail "a valid UTF-8 value was refused or dropped by environment.d"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

_cap_body <<'EOF'
CAP_UTF=$(printf 'caf\303\251')
CAP_TAB=$(printf 'a\tb')
CAP_DEL=$(printf 'a\177b')
export CAP_UTF CAP_TAB CAP_DEL
EOF
if _cap_apply && _cap_export launchd &&
  grep -F "'CAP_UTF' '$(printf 'caf\303\251')'" "$_tmp/cap-export.out" >/dev/null &&
  grep -F "'CAP_TAB' '$(printf 'a\tb')'" "$_tmp/cap-export.out" >/dev/null &&
  grep -F "'CAP_DEL' '$(printf 'a\177b')'" "$_tmp/cap-export.out" >/dev/null; then
  pass "valid UTF-8, TAB, and DEL values are preserved for launchd"
else
  fail "launchd refused or dropped UTF-8, TAB, or DEL"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

_cap_body <<'EOF'
CAP_TAB=$(printf 'a\tb')
export CAP_TAB
EOF
_refuse_case "a TAB byte for environment.d" 'CAP_TAB'

_cap_body <<'EOF'
CAP_DEL=$(printf 'a\177b')
export CAP_DEL
EOF
_refuse_case "a DEL byte for environment.d" 'CAP_DEL'

_cap_body <<'EOF'
CAP_NC_FDD0=$(printf 'a\357\267\220b')
export CAP_NC_FDD0
EOF
_refuse_case "U+FDD0 noncharacter for environment.d" 'CAP_NC_FDD0'

_cap_body <<'EOF'
CAP_NC_ASTRAL=$(printf 'a\360\237\277\276b')
export CAP_NC_ASTRAL
EOF
_refuse_case "U+1FFFE astral noncharacter for environment.d" 'CAP_NC_ASTRAL'

_cap_body <<'EOF'
CAP_NC_TOP=$(printf 'a\364\217\277\277b')
export CAP_NC_TOP
EOF
_refuse_case "U+10FFFF astral noncharacter for environment.d" 'CAP_NC_TOP'

# Scenario E2: caller PATH is preserved as input to env capture so PATH-dependent
# exports (command -v probes and valise_editor_defaults) match an installed env
# plan, while PATH itself stays excluded from bridge output.
_custom_bin="$_tmp/caller-custom-bin"
mkdir -p "$_custom_bin"
printf '#!/bin/sh\nexit 0\n' >"$_custom_bin/probe-owned-tool"
printf '#!/bin/sh\nexit 0\n' >"$_custom_bin/nvim"
chmod 755 "$_custom_bin/probe-owned-tool" "$_custom_bin/nvim"
_cap_body <<'EOF'
CAP_TOOL=$(command -v probe-owned-tool 2>/dev/null || printf unavailable)
export CAP_TOOL
EOF
if _cap_apply && env -i HOME="$_cap_home" PATH="$_custom_bin:/usr/bin:/bin" \
  XDG_DATA_HOME="$_cap_home/.local/share" XDG_CONFIG_HOME="$_cap_home/.config" \
  XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/sh TMPDIR="$_tmp" \
  "$_valise" -C "$_cp" env export environment.d >"$_tmp/cap-path.out" 2>"$_tmp/cap-path.err" &&
  grep -Fx "CAP_TOOL=$_custom_bin/probe-owned-tool" "$_tmp/cap-path.out" >/dev/null &&
  ! grep -q '^PATH=' "$_tmp/cap-path.out"; then
  pass "env export preserves caller PATH as input for command -v while excluding PATH from output"
else
  fail "env export lost caller PATH for command -v or leaked PATH into output"
  cat "$_tmp/cap-path.out" "$_tmp/cap-path.err" >&2 2>/dev/null || :
fi

# Excluded inputs are still available to the plan, but cannot poison the
# representation check or create a record through an assignment-shaped tail.
# This installs once, then varies caller PATH and a root which does not locate
# the store; each success must contain a real nonempty export.
_cap_body <<'EOF'
CAP_SAFE=ok
export CAP_SAFE
EOF
if _cap_apply; then
  for _excluded_case in newline soh esc invalid-utf8 xml-noncharacter; do
    case "$_excluded_case" in
    newline) _excluded_bytes=$(printf 'bad\nFORGED=1') ;;
    soh) _excluded_bytes=$(printf 'bad\001FORGED=1') ;;
    esc) _excluded_bytes=$(printf 'bad\033FORGED=1') ;;
    invalid-utf8) _excluded_bytes=$(printf 'bad\200FORGED=1') ;;
    xml-noncharacter) _excluded_bytes=$(printf 'bad\357\277\276FORGED=1') ;;
    esac
    if _cap_export environment.d "SHELL=/bin/sh" "PATH=$_excluded_bytes:/usr/bin:/bin" \
      "XDG_CACHE_HOME=$_excluded_bytes" &&
      grep -Fx 'CAP_SAFE=ok' "$_tmp/cap-export.out" >/dev/null &&
      ! grep -E '^(PATH|XDG_CACHE_HOME|FORGED)=' "$_tmp/cap-export.out" >/dev/null &&
      ! grep -F 'not bridged' "$_tmp/cap-export.err" >/dev/null; then
      pass "unchanged excluded $_excluded_case bytes do not reject or inject published values"
    else
      fail "unchanged excluded $_excluded_case bytes rejected or injected a published value"
      cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2
    fi
  done
else
  fail "could not install the excluded-input fixture"
  cat "$_tmp/cap-apply.out" >&2
fi

# Changed excluded values are reported by name, even if their bytes could not
# be encoded in any bridge. Shell/capture bookkeeping is silently excluded.
_cap_body <<'EOF'
CAP_SAFE=ok
PATH=$(printf 'bad\nFORGED=1\001\200\357\277\276')
XDG_CACHE_HOME=$PATH
TMPDIR=$PATH
HOME=$PATH
EEC_HOME=$PATH
export CAP_SAFE PATH XDG_CACHE_HOME TMPDIR HOME EEC_HOME
EOF
if _cap_apply && _cap_export environment.d &&
  grep -Fx 'CAP_SAFE=ok' "$_tmp/cap-export.out" >/dev/null &&
  ! grep -E '^(PATH|XDG_CACHE_HOME|TMPDIR|HOME|EEC_HOME|FORGED)=' "$_tmp/cap-export.out" >/dev/null &&
  grep -F '3 exported variable(s) are not bridged' "$_tmp/cap-export.err" >/dev/null &&
  grep -F 'PATH' "$_tmp/cap-export.err" >/dev/null &&
  grep -F 'XDG_CACHE_HOME' "$_tmp/cap-export.err" >/dev/null &&
  grep -F 'TMPDIR' "$_tmp/cap-export.err" >/dev/null; then
  pass "changed excluded values retain diagnostics without validating or decoding them as records"
else
  fail "changed excluded values were lost, injected, or validated as published data"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

# Explicitly empty HOME, PATH and XDG roots reach the plan unchanged.
_cap_body <<'EOF'
if [ "${PATH+x}" = x ] && [ -z "$PATH" ]; then CAP_PATH_STATE=empty; else CAP_PATH_STATE=nonempty; fi
if [ "${XDG_CACHE_HOME+x}" = x ]; then
  if [ -z "$XDG_CACHE_HOME" ]; then CAP_CACHE_STATE=empty; else CAP_CACHE_STATE=nonempty; fi
else CAP_CACHE_STATE=unset
fi
if [ -z "$HOME" ]; then CAP_HOME_STATE=empty; else CAP_HOME_STATE=nonempty; fi
export CAP_PATH_STATE CAP_CACHE_STATE CAP_HOME_STATE
EOF
if _cap_apply && _cap_export environment.d SHELL=/bin/sh PATH= XDG_CACHE_HOME= HOME= &&
  grep -Fx 'CAP_PATH_STATE=empty' "$_tmp/cap-export.out" >/dev/null &&
  grep -Fx 'CAP_CACHE_STATE=empty' "$_tmp/cap-export.out" >/dev/null &&
  grep -Fx 'CAP_HOME_STATE=empty' "$_tmp/cap-export.out" >/dev/null &&
  _cap_export environment.d SHELL=/bin/sh &&
  grep -Fx 'CAP_PATH_STATE=nonempty' "$_tmp/cap-export.out" >/dev/null &&
  grep -Fx 'CAP_CACHE_STATE=unset' "$_tmp/cap-export.out" >/dev/null &&
  grep -Fx 'CAP_HOME_STATE=nonempty' "$_tmp/cap-export.out" >/dev/null; then
  pass "env capture preserves empty HOME/PATH and distinguishes empty and unset XDG roots"
else
  fail "env capture changed empty HOME/PATH or an XDG root set/unset distinction"
  cat "$_tmp/cap-export.out" "$_tmp/cap-export.err" >&2 2>/dev/null || :
fi

_ed_proj="$_tmp/cap-editor-proj"
mkdir -p "$_ed_proj/module.d" "$_ed_proj/modules"
: >"$_ed_proj/valise.conf"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\n' >"$_ed_proj/variants.tsv"
printf 'name=cap_ed\nversion=\nside_effect=read-only\nrequires=valise_editor\noptional=\nshells=posix\nplatforms=any\nexports=\nload=modules/cap_ed.sh\n' >"$_ed_proj/module.d/cap_ed.meta"
printf 'valise_editor_defaults\n' >"$_ed_proj/modules/cap_ed.sh"
printf '# bundle\tshell\troots\ndefault\tsh\tcap_ed\ndefault\tbash\tcap_ed\n' >"$_ed_proj/bundles.tsv"
_ed_home="$_tmp/cap-ed-home"
mkdir -p "$_ed_home"
if env -i HOME="$_ed_home" PATH="$_custom_bin:/usr/bin:/bin" \
  XDG_DATA_HOME="$_ed_home/.local/share" XDG_CONFIG_HOME="$_ed_home/.config" \
  XDG_STATE_HOME="$_ed_home/.local/state" SHELL=/bin/sh TMPDIR="$_tmp" \
  "$_valise" -C "$_ed_proj" apply --no-integration >/dev/null 2>&1 &&
  env -i HOME="$_ed_home" PATH="$_custom_bin:/usr/bin:/bin" \
  XDG_DATA_HOME="$_ed_home/.local/share" XDG_CONFIG_HOME="$_ed_home/.config" \
  XDG_STATE_HOME="$_ed_home/.local/state" SHELL=/bin/sh TMPDIR="$_tmp" \
  "$_valise" -C "$_ed_proj" env export environment.d >"$_tmp/cap-ed.out" 2>"$_tmp/cap-ed.err" &&
  grep -Fx 'EDITOR=nvim' "$_tmp/cap-ed.out" >/dev/null &&
  grep -Fx 'VISUAL=nvim' "$_tmp/cap-ed.out" >/dev/null; then
  pass "env export matches installed env plan for valise_editor_defaults with nvim on caller PATH"
else
  fail "env export diverged from installed env plan for valise_editor_defaults"
  cat "$_tmp/cap-ed.out" "$_tmp/cap-ed.err" >&2 2>/dev/null || :
fi

# Scenario F: an empty value cannot reach environment.d; it is refused by name,
# while launchd still bridges it.
_cap_body <<'EOF'
CAP_EMPTY=
export CAP_EMPTY
EOF
_refuse_case "an empty value for environment.d" 'CAP_EMPTY'
if _cap_apply && _cap_export launchd && grep -F 'CAP_EMPTY' "$_tmp/cap-export.out" >/dev/null; then
  pass "an empty value is still bridged to launchd"
else
  fail "launchd dropped an empty value"
fi

# Scenario G: production capture does not need dash. A `sh` that is bash, with no
# dash anywhere on PATH, must still capture for a /bin/sh login.
_cap_body <<'EOF'
CAP_SHV=ok
export CAP_SHV
EOF
if _cap_apply && env -i HOME="$_cap_home" PATH="$_tmp/fakebin" XDG_DATA_HOME="$_cap_home/.local/share" \
  XDG_CONFIG_HOME="$_cap_home/.config" XDG_STATE_HOME="$_cap_home/.local/state" SHELL=/bin/sh TMPDIR="$_tmp" \
  "$_valise" -C "$_cp" env export environment.d >"$_tmp/cap-sh.out" 2>"$_tmp/cap-sh.err" &&
  grep -Fx 'CAP_SHV=ok' "$_tmp/cap-sh.out" >/dev/null; then
  pass "env export captures for a /bin/sh login without dash on PATH"
else
  fail "env export needed a dash that the sh login does not use"
  cat "$_tmp/cap-sh.err" >&2 2>/dev/null || :
fi

# Faults at delegated utility boundaries exercise real allocation and cleanup,
# without racing wall-clock sleeps. The interpreter-selection subprocess execs
# a PID recorder, so its PPID identifies the capture worker precisely. All
# signals target that private worker and, in the allocation-tree cases, its
# allocation descendants. They never target this test or its process group.
mkdir -p "$_tmp/capture-fault/release/plans" "$_tmp/capture-fault/scratch"
printf 'CAP_SIGNAL=ok\nexport CAP_SIGNAL\n' >"$_tmp/capture-fault/release/plans/sh.sh"
awk '
  /^trusted_utility_path\(\) \{/ { copying = 1; sub(/trusted_utility_path/, "capture_trusted_utility_path") }
  copying { print }
  copying && /^}/ { exit }
' "$_repo/lib/cli/common.sh" >"$_tmp/capture-fault/resolver.sh"
cat >"$_tmp/capture-fault/record-pid" <<'EOF'
#!/bin/sh
printf '%s\n' "$PPID" >"$CAPTURE_PID"
printf '/bin/sh\n'
EOF
cat >"$_tmp/capture-fault/mktemp" <<'EOF'
#!/bin/sh
set -eu
_allocated=$("$CAPTURE_REAL_MKTEMP" "$@") || exit "$?"
printf '%s\n' "$_allocated" >"$CAPTURE_ALLOCATED"
printf 'allocated\n' >>"$CAPTURE_MARKER"
case $CAPTURE_FAULT in
allocation-tree-*)
  # Collect the complete allocation ancestry before sending anything. The
  # kernel can deliver a terminal signal to these processes together; killing
  # only the worker misses a utility that committed but lost its exit status.
  _worker=$(cat "$CAPTURE_PID")
  _ancestor=$$
  _ancestors=$$
  _depth=0
  while [ "$_ancestor" != "$_worker" ] && [ "$_depth" -lt 12 ]; do
    _parent=$(ps -o ppid= -p "$_ancestor") || exit 72
    set -- $_parent
    [ "$#" -eq 1 ] && [ "$1" -gt 1 ] || exit 72
    _ancestor=$1
    _ancestors="$_ancestors $_ancestor"
    _depth=$((_depth + 1))
  done
  [ "$_ancestor" = "$_worker" ] || exit 72
  printf 'allocation-tree-signalled\n' >>"$CAPTURE_MARKER"
  for _ancestor in $_ancestors; do kill -"$CAPTURE_SIGNAL" "$_ancestor" || exit 72; done
  ;;
esac
printf '%s\n' "$_allocated"
case $CAPTURE_FAULT in allocation-*) kill -"$CAPTURE_SIGNAL" "$(cat "$CAPTURE_PID")" ;; esac
EOF
cat >"$_tmp/capture-fault/od" <<'EOF'
#!/bin/sh
set -eu
printf 'scanning\n' >>"$CAPTURE_MARKER"
case $CAPTURE_FAULT in
scan-term) kill -TERM "$(cat "$CAPTURE_PID")" ;;
od-error) exit 71 ;;
esac
exec "$CAPTURE_REAL_OD" "$@"
EOF
cat >"$_tmp/capture-fault/rm" <<'EOF'
#!/bin/sh
set -eu
_capture_cleanup=0
for _arg do
  case $_arg in "$CAPTURE_SCRATCH"/valise-env-export.*) _capture_cleanup=1 ;; esac
done
if [ "$_capture_cleanup" -eq 1 ]; then
  printf 'cleanup-started\n' >>"$CAPTURE_MARKER"
  case $CAPTURE_FAULT in
    allocation-*|scan-term|cleanup-term) kill -"$CAPTURE_SIGNAL" "$(cat "$CAPTURE_PID")" ;;
    cleanup-child-*)
      kill -"$CAPTURE_SIGNAL" "$(cat "$CAPTURE_PID")"
      kill -"$CAPTURE_SIGNAL" "$$"
      ;;
  esac
fi
"$CAPTURE_REAL_RM" "$@" || exit "$?"
[ "$_capture_cleanup" -eq 0 ] || printf 'cleanup-finished\n' >>"$CAPTURE_MARKER"
EOF
chmod 0755 "$_tmp/capture-fault/record-pid" "$_tmp/capture-fault/mktemp" \
  "$_tmp/capture-fault/od" "$_tmp/capture-fault/rm"
cat >"$_tmp/capture-fault/driver.sh" <<'EOF'
set -eu
VALISE_CLI_DIR=$1/lib/cli
for part in usage common store fish-hook integration commands lifecycle devtools project; do
  . "$VALISE_CLI_DIR/$part.sh"
done
. "$2/resolver.sh"
trusted_utility_path() {
  case $1 in
  mktemp|od|rm) printf '%s/%s\n' "$CAPTURE_FAULT_ROOT" "$1" ;;
  *) capture_trusted_utility_path "$1" ;;
  esac
}
capture_interpreter() { exec /bin/sh "$CAPTURE_FAULT_ROOT/record-pid"; }
env_export_capture sh "$2/release"
EOF
_capture_real_mktemp=$(command -v mktemp)
_capture_real_od=$(command -v od)
_capture_real_rm=$(command -v rm)
for _capture_fault in healthy allocation-term allocation-int allocation-tree-term allocation-tree-int scan-term od-error cleanup-term cleanup-child-term cleanup-child-int; do
  _capture_signal=TERM
  _capture_expected=143
  case $_capture_fault in
  healthy) _capture_expected=0 ;;
  allocation-int|allocation-tree-int|cleanup-child-int) _capture_signal=INT; _capture_expected=130 ;;
  od-error) _capture_expected=1 ;;
  esac
  : >"$_tmp/capture-fault/marker"
  _capture_scratch="$_tmp/capture-fault/scratch/$_capture_fault"
  mkdir -p "$_capture_scratch"
  _capture_rc=0
  env -i HOME="$_home" PATH=/usr/bin:/bin TMPDIR="$_capture_scratch" \
    CAPTURE_FAULT="$_capture_fault" CAPTURE_SIGNAL="$_capture_signal" \
    CAPTURE_FAULT_ROOT="$_tmp/capture-fault" CAPTURE_SCRATCH="$_capture_scratch" \
    CAPTURE_PID="$_tmp/capture-fault/pid" CAPTURE_ALLOCATED="$_tmp/capture-fault/allocated" \
    CAPTURE_MARKER="$_tmp/capture-fault/marker" CAPTURE_REAL_MKTEMP="$_capture_real_mktemp" \
    CAPTURE_REAL_OD="$_capture_real_od" CAPTURE_REAL_RM="$_capture_real_rm" \
    /bin/sh "$_tmp/capture-fault/driver.sh" "$_repo" "$_tmp/capture-fault" \
    >"$_tmp/capture-fault/out" 2>"$_tmp/capture-fault/err" || _capture_rc=$?
  _capture_allocated=$(cat "$_tmp/capture-fault/allocated")
  _capture_left=$(find "$_capture_scratch" ! -path "$_capture_scratch" -print) || _capture_left=ERROR
  _capture_output_ok=0
  case $_capture_fault in
  healthy|cleanup-*)
    grep -Fx 'CAP_SIGNAL=ok' "$_tmp/capture-fault/out" >/dev/null && _capture_output_ok=1 ;;
  *) [ -s "$_tmp/capture-fault/out" ] || _capture_output_ok=1 ;;
  esac
  if [ "$_capture_rc" -eq "$_capture_expected" ] && [ "$_capture_output_ok" -eq 1 ] &&
    grep -Fx allocated "$_tmp/capture-fault/marker" >/dev/null &&
    grep -Fx cleanup-started "$_tmp/capture-fault/marker" >/dev/null &&
    grep -Fx cleanup-finished "$_tmp/capture-fault/marker" >/dev/null &&
    [ ! -e "$_capture_allocated" ] && [ ! -L "$_capture_allocated" ] && [ -z "$_capture_left" ]; then
    pass "env capture owns scratch through allocation, failure and cleanup ($_capture_fault)"
  else
    fail "env capture lost scratch, status or output at $_capture_fault (status=$_capture_rc)"
    cat "$_tmp/capture-fault/out" "$_tmp/capture-fault/err" "$_tmp/capture-fault/marker" >&2
    printf 'allocated=%s leftovers=%s\n' "$_capture_allocated" "$_capture_left" >&2
  fi
done

# Exercise the complete noncharacter set and valid boundary neighbors through
# the real capture and format helpers. Generate UTF-8 from code points here,
# independently of the emitter's byte-pattern table. Octal text keeps the test
# vector file itself free of newlines/control bytes inside records.
LC_ALL=C awk '
  function byte(n) { return sprintf("\\0%03o", n) }
  function utf8(n) {
    if (n < 128) return byte(n)
    if (n < 2048) return byte(192 + int(n / 64)) byte(128 + n % 64)
    if (n < 65536) return byte(224 + int(n / 4096)) byte(128 + int(n / 64) % 64) byte(128 + n % 64)
    return byte(240 + int(n / 262144)) byte(128 + int(n / 4096) % 64) byte(128 + int(n / 64) % 64) byte(128 + n % 64)
  }
  function vector(kind, n) { printf "%s\tU+%X\t%s\n", kind, n, utf8(n) }
  BEGIN {
    for (n = 64976; n <= 65007; n++) vector("noncharacter", n)
    for (plane = 0; plane <= 16; plane++) {
      vector(plane == 0 ? "xml-noncharacter" : "noncharacter", plane * 65536 + 65534)
      vector(plane == 0 ? "xml-noncharacter" : "noncharacter", plane * 65536 + 65535)
      vector("valid", plane * 65536 + 65533)
      if (plane) vector("valid", plane * 65536)
    }
    vector("valid", 64975); vector("valid", 65008)
    vector("valid", 55295); vector("valid", 57344)
    vector("valid", 128); vector("valid", 2047); vector("valid", 2048)
    vector("valid", 4095); vector("valid", 4096); vector("valid", 53248)
    vector("valid", 1114108)
    for (n = 1; n < 32; n++) if (n != 9) vector("control", n)
    print "invalid\tcontinuation\t" byte(128)
    print "invalid\toverlong\t" byte(192) byte(175)
    print "invalid\ttruncated\t" byte(194)
    print "invalid\tsurrogate\t" byte(237) byte(160) byte(128)
    print "invalid\tabove-max\t" byte(244) byte(144) byte(128) byte(128)
    print "invalid\tforbidden-byte\t" byte(255)
    print "invalid\tf5-leader\t" byte(245) byte(128) byte(128) byte(128)
    print "invalid\tfive-byte\t" byte(248) byte(136) byte(128) byte(128) byte(128)
    print "invalid\tsix-byte\t" byte(252) byte(132) byte(128) byte(128) byte(128) byte(128)
    print "invalid\tthree-byte-overlong\t" byte(224) byte(159) byte(191)
    print "invalid\tfour-byte-overlong\t" byte(240) byte(143) byte(191) byte(191)
    print "invalid\ttruncated-four-byte\t" byte(240) byte(144) byte(128)
    print "invalid\tbad-continuation\t" byte(194) byte(127)
  }
' >"$_tmp/capture-vectors.tsv"
mkdir -p "$_tmp/character-release/plans"
cat >"$_tmp/character-check.sh" <<'EOF'
set -eu
VALISE_CLI_DIR=$1/lib/cli
for part in usage common store fish-hook integration commands lifecycle devtools project; do
  . "$VALISE_CLI_DIR/$part.sh"
done
_char_root=$2
_char_failed=0
_char_noncharacters=0
_char_valid=0
_char_controls=0
_char_invalid=0
while IFS="$(printf '\t')" read -r _char_kind _char_label _char_octets; do
  case $_char_label in
  truncated*) _char_value=$(printf 'before%b' "$_char_octets") ;;
  *) _char_value=$(printf 'before%bafter' "$_char_octets") ;;
  esac
  _char_record="CAP_PROBE=$_char_value"
  printf "CAP_PROBE='%s'\nexport CAP_PROBE\n" "$_char_value" >"$_char_root/character-release/plans/sh.sh"
  _char_rc=0
  env_export_capture sh "$_char_root/character-release" >"$_char_root/character-capture.out" \
    2>"$_char_root/character-capture.err" || _char_rc=$?
  case $_char_kind in
  control|invalid|xml-noncharacter)
    if [ "$_char_rc" -eq 0 ] || [ -s "$_char_root/character-capture.out" ] ||
      [ ! -s "$_char_root/character-capture.err" ]; then
      printf 'capture failed to refuse %s (%s)\n' "$_char_label" "$_char_kind" >&2
      _char_failed=1
    fi
    if [ "$_char_kind" = control ]; then
      _char_controls=$((_char_controls + 1))
      grep -F 'sets CAP_PROBE to a value containing' "$_char_root/character-capture.err" >/dev/null || _char_failed=1
      continue
    elif [ "$_char_kind" = invalid ]; then
      _char_invalid=$((_char_invalid + 1))
      grep -F 'CAP_PROBE is set to a value that is not valid UTF-8' "$_char_root/character-capture.err" >/dev/null || _char_failed=1
      continue
    fi
    ;;
  *)
    printf '%s\n' "$_char_record" >"$_char_root/character-capture.want"
    if [ "$_char_rc" -ne 0 ] || ! cmp -s "$_char_root/character-capture.want" "$_char_root/character-capture.out"; then
      printf 'capture altered valid UTF-8 %s\n' "$_char_label" >&2
      cat "$_char_root/character-capture.err" >&2
      _char_failed=1
    fi
    ;;
  esac
  _char_rc=0
  env_export_emit environment.d "$_char_record" >"$_char_root/character-env.out" \
    2>"$_char_root/character-env.err" || _char_rc=$?
  case $_char_kind in
  *noncharacter)
    _char_noncharacters=$((_char_noncharacters + 1))
    if [ "$_char_rc" -eq 0 ] || [ -s "$_char_root/character-env.out" ] ||
      ! grep -F 'CAP_PROBE contains a Unicode noncharacter' "$_char_root/character-env.err" >/dev/null; then
      printf 'environment.d failed to refuse %s\n' "$_char_label" >&2
      _char_failed=1
    fi
    ;;
  valid)
    _char_valid=$((_char_valid + 1))
    if [ "$_char_rc" -ne 0 ] || ! grep -Fx "$_char_record" "$_char_root/character-env.out" >/dev/null; then
      printf 'environment.d refused or altered neighbor %s\n' "$_char_label" >&2
      _char_failed=1
    fi
    ;;
  esac
  # XML permits the other 64 noncharacters; launchd preserves their bytes.
  if [ "$_char_kind" != xml-noncharacter ]; then
    if ! env_export_emit launchd "$_char_record" >"$_char_root/character-launchd.out" ||
      ! grep -F "$_char_value" "$_char_root/character-launchd.out" >/dev/null; then
      printf 'launchd refused or altered valid XML %s\n' "$_char_label" >&2
      _char_failed=1
    fi
  fi
done <"$_char_root/capture-vectors.tsv"
[ "$_char_noncharacters" -eq 66 ] && [ "$_char_valid" -eq 44 ] &&
  [ "$_char_controls" -eq 30 ] && [ "$_char_invalid" -eq 13 ] || _char_failed=1
printf 'characters: %s noncharacters, %s valid neighbors, %s controls, %s invalid UTF-8 sequences\n' \
  "$_char_noncharacters" "$_char_valid" "$_char_controls" "$_char_invalid"
exit "$_char_failed"
EOF
if env -i HOME="$_home" PATH=/usr/bin:/bin TMPDIR="$_tmp" \
  /bin/sh "$_tmp/character-check.sh" "$_repo" "$_tmp" >"$_tmp/characters.out" 2>&1 &&
  grep -Fx 'characters: 66 noncharacters, 44 valid neighbors, 30 controls, 13 invalid UTF-8 sequences' "$_tmp/characters.out" >/dev/null; then
  pass "capture and GUI formats distinguish all Unicode noncharacters, valid neighbors, C0 controls and invalid UTF-8"
else
  fail "capture or GUI format character validation disagreed with the complete boundary matrix"
  cat "$_tmp/characters.out" >&2
fi

printf '\n=== developer commands summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
