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
if grep -qE '^[A-Za-z_][A-Za-z0-9_]*/(p|l)$' "$_tmp/env-export-wsl.out" &&
  grep -q '/p$' "$_tmp/env-export-wsl.out" 2>/dev/null || true; then
  :
fi
if grep -qE '^[A-Za-z_][A-Za-z0-9_]*/(p|l)$' "$_tmp/env-export-wsl.out"; then
  pass "env export wsl emits NAME/flag lines"
else
  fail "env export wsl emits NAME/flag lines"
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
# F6: XML-special characters in values must be escaped exactly once — the
# plist string must contain &amp; (not &amp;amp;) for a literal '&'. The value
# is assigned quoted in the module body so the shell parses it.
if printf 'XMLV="a<&>\\"b"\nexport XMLV\n' >>"$_proj/modules/main.sh" &&
  _v "$_proj" apply >/dev/null 2>&1 &&
  _v "$_proj" env export launchd >"$_tmp/env-export-ld-xml.out" 2>&1; then
  if grep -q 'launchctl setenv XMLV a&lt;&amp;&gt;&quot;b' "$_tmp/env-export-ld-xml.out" &&
    ! grep -q '&amp;amp;\|&amp;lt;\|&amp;gt;\|&amp;quot;' "$_tmp/env-export-ld-xml.out"; then
    pass "env export launchd escapes XML-special value chars exactly once"
  else
    fail "env export launchd double-escapes XML-special value chars"
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
_lint_case "lint accepts valise_path_prepend in an env-phase body" \
  'valise lint: no problems' \
  "printf 'valise_path_prepend \"\$HOME/.local/bin\"\\n' >>modules/main.sh"
_lint_case "lint allows raw PATH writes in an interactive-phase body" \
  'valise lint: no problems' \
  "sed 's/^side_effect=read-only\$/side_effect=read-only\\nphase=interactive/' module.d/main.meta >m && mv m module.d/main.meta && printf 'PATH=\$HOME/bin:\$PATH\\n' >>modules/main.sh"

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
# The env-export block above ran `apply`, which legitimately installs into
# $_home, so the no-install assertion below only checks TMPDIR scratch: the
# env export capture must remove its own scratch dir.
if [ -z "$(ls -A "$_tmp" | grep '^valise-dev\.\|^valise-env-export\.' || :)" ]; then
  pass "lint, test, run, and env export leave no scratch behind in TMPDIR"
else
  fail "lint, test, run, and env export leave no scratch behind in TMPDIR"
  ls -A "$_tmp" >&2
fi

printf '\n=== developer commands summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
