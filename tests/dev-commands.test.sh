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
printf 'main_ready() { printf "ready:%%s\\n" "$*"; }\n' >"$_proj/modules/main.sh"
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
    fail "$1 (lint passed)"
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
if [ ! -e "$_home/.local/share/valise" ] && [ ! -e "$_home/.config/valise" ] && [ -z "$(ls -A "$_tmp" | grep '^valise-dev\.' || :)" ]; then
  pass "lint, test, and run install nothing and leave no scratch behind"
else
  fail "lint, test, and run install nothing and leave no scratch behind"
  ls -A "$_tmp" "$_home" >&2
fi

printf '\n=== developer commands summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
