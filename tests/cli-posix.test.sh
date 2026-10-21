#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Automated tests for the valise CLI.
# Pure POSIX. Runs in a quarantined disposable home.
set -eu

_total=0
_pass=0
_fail=0

pass() {
  _total=$(( _total + 1 ))
  _pass=$(( _pass + 1 ))
  printf '  PASS: %s\n' "$1"
}

fail() {
  _total=$(( _total + 1 ))
  _fail=$(( _fail + 1 ))
  printf '  FAIL: %s\n' "$1" >&2
}

check() {
  _desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    pass "$_desc"
  else
    fail "$_desc"
  fi
}

check_output_contains() {
  _desc=$1; _pattern=$2; shift 2
  _out=$("$@" 2>&1) || true
  case "$_out" in
    *"$_pattern"*) pass "$_desc" ;;
    *) fail "$_desc (output missing: $_pattern)" ;;
  esac
}

# Setup quarantined home
_test_home=$(mktemp -d "${TMPDIR:-/tmp}/valise-test.XXXXXX")
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_test_home" 2>/dev/null || :
  rm -rf -- "$_test_home"
}
_handle_int() {
  trap - INT
  _cleanup
  exit 130
}
_handle_term() {
  trap - TERM
  _cleanup
  exit 143
}
trap '_cleanup' EXIT
trap '_handle_int' INT
trap '_handle_term' TERM

export HOME="$_test_home"
export XDG_DATA_HOME="$_test_home/.local/share"
export XDG_CONFIG_HOME="$_test_home/.config"
export XDG_STATE_HOME="$_test_home/.local/state"
unset XDG_RUNTIME_DIR

_valise="$(cd "$(dirname "$0")/.." && pwd)/bin/valise"

printf '=== valise CLI tests ===\n'
printf '  valise: %s\n' "$_valise"
printf '  home: %s\n\n' "$_test_home"

# --- Version ---
check_output_contains "version prints version string" "0.1.0" "$_valise" version

# --- Help ---
check_output_contains "help shows usage" "Usage: valise" "$_valise" help
check_output_contains "no args shows usage" "Usage: valise" "$_valise"

# --- Init ---
check_output_contains "init bash outputs profile source" ". " "$_valise" init bash
check_output_contains "init zsh outputs profile source" ". " "$_valise" init zsh
check_output_contains "init ksh outputs profile source" ". " "$_valise" init ksh
check_output_contains "init fish outputs protected Fish loader integration" "loader.fish" "$_valise" init fish

# Verify init output contains active link path
_init_out=$("$_valise" init bash 2>&1)
case "$_init_out" in
  *"$XDG_CONFIG_HOME/valise/active"*) pass "init bash references XDG active path" ;;
  *) fail "init bash references XDG active path" ;;
esac

# Generated shell snippets must quote hostile XDG paths as data. In particular,
# command substitutions in an environment-provided path must not execute while
# `valise init` emits Fish, Bash, Zsh, Ksh, or POSIX-sh integration.
_injection_marker="$_test_home/integration-command-substitution-ran"
_injection_xdg="$_test_home/xdg-\$(touch $_injection_marker)/a\\'h"
XDG_CONFIG_HOME="$_injection_xdg" "$_valise" init fish >"$_test_home/init-fish-hostile.out"
XDG_CONFIG_HOME="$_injection_xdg" "$_valise" init bash >"$_test_home/init-sh-hostile.out"
if [ -e "$_injection_marker" ]; then
  fail "init integration does not execute command substitutions from XDG paths"
else
  pass "init integration does not execute command substitutions from XDG paths"
fi
if command -v fish >/dev/null 2>&1 && fish -n "$_test_home/init-fish-hostile.out" >/dev/null 2>&1; then
  pass "hostile Fish integration remains syntactically valid"
elif command -v fish >/dev/null 2>&1; then
  fail "hostile Fish integration remains syntactically valid"
else
  pass "hostile Fish integration syntax (fish unavailable)"
fi
if /bin/sh -n "$_test_home/init-sh-hostile.out"; then
  pass "hostile POSIX integration remains syntactically valid"
else
  fail "hostile POSIX integration remains syntactically valid"
fi

# --- Doctor (clean state) ---
# doctor should report no active release but not die on missing dirs
_doctor_out=$("$_valise" doctor 2>&1) || true
case "$_doctor_out" in
  *"platform:"*) pass "doctor reports platform" ;;
  *) fail "doctor reports platform" ;;
esac

# --- Variant list (empty) ---
check_output_contains "variant list on empty state" "no releases installed" "$_valise" variant list

# --- Make-manifest (standalone publisher) ---
_mm_tree="$_test_home/pubtree"
mkdir -p "$_mm_tree/bin"
printf '#!/bin/sh\necho hi\n' >"$_mm_tree/bin/tool.sh"
chmod 0755 "$_mm_tree/bin/tool.sh"
printf 'plain\n' >"$_mm_tree/readme.txt"
if "$_valise" make-manifest "$_mm_tree" >"$_test_home/make-manifest.out" 2>&1; then
  pass "make-manifest writes a manifest for a tree"
else
  fail "make-manifest writes a manifest for a tree"
fi
check_output_contains "make-manifest reports file count" "2 files" cat "$_test_home/make-manifest.out"
_mm_manifest="$_mm_tree/shell/install/profile-release.manifest"
_mm_row1=$(awk -F'\t' 'NR==3 { print $1, $2, $3, $4 }' "$_mm_manifest")
if [ "$_mm_row1" = "bin/tool.sh bin/tool.sh 0755 0555" ]; then
  pass "make-manifest records executable mode pair"
else
  fail "make-manifest records executable mode pair (got: $_mm_row1)"
fi
_mm_row2=$(awk -F'\t' 'NR==4 { print $1, $2, $3, $4 }' "$_mm_manifest")
if [ "$_mm_row2" = "readme.txt readme.txt 0644 0444" ]; then
  pass "make-manifest records regular mode pair"
else
  fail "make-manifest records regular mode pair (got: $_mm_row2)"
fi
cp "$_mm_manifest" "$_test_home/make-manifest.first"
if "$_valise" make-manifest "$_mm_tree" >/dev/null 2>&1 && cmp -s "$_mm_manifest" "$_test_home/make-manifest.first"; then
  pass "make-manifest rebuilds byte-identically"
else
  fail "make-manifest rebuilds byte-identically"
fi
if "$_valise" make-manifest "$_mm_tree" --output "$_test_home/space-form.manifest" >/dev/null 2>&1 && [ -f "$_test_home/space-form.manifest" ]; then
  pass "make-manifest accepts space-separated --output"
else
  fail "make-manifest accepts space-separated --output"
fi
if "$_valise" make-manifest "$_mm_tree" --output="$_test_home/equals-form.manifest" >/dev/null 2>&1 && cmp -s "$_test_home/space-form.manifest" "$_test_home/equals-form.manifest"; then
  pass "make-manifest equals-form output matches"
else
  fail "make-manifest equals-form output matches"
fi
ln -s readme.txt "$_mm_tree/link.sh"
if "$_valise" make-manifest "$_mm_tree" --output "$_test_home/sym.manifest" >/dev/null 2>&1; then
  fail "make-manifest rejects symlink trees"
else
  pass "make-manifest rejects symlink trees"
fi
rm "$_mm_tree/link.sh"
chmod 0600 "$_mm_tree/readme.txt"
if "$_valise" make-manifest "$_mm_tree" --output "$_test_home/mode.manifest" >/dev/null 2>&1; then
  fail "make-manifest rejects non-0644/0755 modes"
else
  pass "make-manifest rejects non-0644/0755 modes"
fi
chmod 0644 "$_mm_tree/readme.txt"
printf 'x\n' >"$_mm_tree/with space.txt"
if "$_valise" make-manifest "$_mm_tree" --output "$_test_home/space.manifest" >/dev/null 2>&1; then
  fail "make-manifest rejects names outside the manifest charset"
else
  pass "make-manifest rejects names outside the manifest charset"
fi
rm "$_mm_tree/with space.txt"
mkdir -p "$_test_home/emptytree"
if "$_valise" make-manifest "$_test_home/emptytree" >/dev/null 2>&1; then
  fail "make-manifest rejects empty trees"
else
  pass "make-manifest rejects empty trees"
fi
if "$_valise" install --variant=x >/dev/null 2>&1; then
  fail "install rejects the removed --variant flag"
else
  pass "install rejects the removed --variant flag"
fi
check_output_contains "help lists make-manifest" "make-manifest" "$_valise" help
_help_out=$("$_valise" help 2>&1)
case "$_help_out" in
  *'install [--variant'*) fail "help no longer advertises install --variant" ;;
  *) pass "help no longer advertises install --variant" ;;
esac

# --- Package tarball path ---
# The package.json files whitelist must name paths that exist here, so the
# documented npm tarball carries the CLI payload it claims to carry.
_pkg_root=${_valise%/bin/valise}
for _pkg_member in bin lib modules entrypoints module.d manifests docs examples; do
  if [ -d "$_pkg_root/$_pkg_member" ]; then
    pass "package files entry exists: $_pkg_member"
  else
    fail "package files entry exists: $_pkg_member"
  fi
done
unset _pkg_root
if command -v npm >/dev/null 2>&1; then
  _npm_root="$_test_home/npm-pack"
  mkdir -p "$_npm_root"
  if _npm_out=$(npm pack --json --pack-destination "$_npm_root" 2>&1); then
    pass "npm pack produces the tarball"
  else
    fail "npm pack produces the tarball"
    printf '%s\n' "$_npm_out" >&2
  fi
  _npm_tgz=$(printf '%s\n' "$_npm_out" | sed -n 's/.*"filename": *"\([^"]*\)".*/\1/p' | sed -n '1p')
  if [ -n "$_npm_tgz" ] && [ -f "$_npm_root/$_npm_tgz" ]; then
    pass "packed tarball exists"
  else
    fail "packed tarball exists"
  fi
  _tar_root="$_test_home/tarball"
  mkdir -p "$_tar_root"
  if tar -xf "$_npm_root/$_npm_tgz" -C "$_tar_root" 2>/dev/null; then
    pass "packed tarball extracts"
  else
    fail "packed tarball extracts"
  fi
  for _tar_member in package/bin/valise package/entrypoints/profile.sh package/entrypoints/fish/profile.fish package/lib/loader.sh package/lib/metadata.sh package/lib/capabilities.sh package/lib/fish/loader.fish package/lib/fish/metadata.fish package/manifests/parser-support.tsv package/module.d/contrib_path.meta package/modules/system/contrib_path.sh package/docs/installation.md package/docs/release-policy.md package/examples/local/modules/hello_valise.sh package/LICENSE package/CHANGELOG.md; do
    if [ -f "$_tar_root/$_tar_member" ]; then
      pass "tarball contains $_tar_member"
    else
      fail "tarball contains $_tar_member"
    fi
  done
  if VALISE_ROOT="$_tar_root/package" \
     VALISE_MODULE_ROOT="$_tar_root/package" \
     VALISE_MODULES='contrib_pager' \
     VALISE_MODE=strict \
     /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; command -v contrib_pager_defaults >/dev/null 2>&1' >/dev/null 2>&1; then
    pass "module loads from the extracted tarball tree"
  else
    fail "module loads from the extracted tarball tree"
  fi
  _npm_prefix="$_test_home/npm-prefix"
  if npm install --global --offline --prefix "$_npm_prefix" "$_npm_root/$_npm_tgz" >"$_test_home/npm-install.out" 2>&1; then
    pass "npm installs the packed CLI without a registry"
    if "$_npm_prefix/bin/valise" version 2>/dev/null | grep '^0.1.0$' >/dev/null 2>&1; then
      pass "installed npm binary runs"
    else
      fail "installed npm binary runs"
    fi
  else
    fail "npm installs the packed CLI without a registry"
    cat "$_test_home/npm-install.out" >&2
  fi
  rm -rf "$_npm_root" "$_tar_root" "$_npm_prefix"
  unset _npm_out _npm_tgz _tar_root _tar_member _npm_prefix
else
  printf '  SKIP: npm pack tarball check (npm unavailable)\n'
fi
unset _pkg_member

# Compile must reject an unknown variant instead of silently using the default
# workstation surface. This is a pure validation path and is safe on all hosts.
_unknown_compile_dir="$_test_home/unknown-variant-output"
if "$_valise" compile --variant=unknown "$_unknown_compile_dir" >"$_test_home/unknown-variant.stdout" 2>"$_test_home/unknown-variant.stderr"; then
  fail "compile rejects unknown variant"
else
  pass "compile rejects unknown variant"
fi
if [ -e "$_unknown_compile_dir" ] || [ -L "$_unknown_compile_dir" ]; then
  fail "unknown variant leaves no partial output"
else
  pass "unknown variant leaves no partial output"
fi

# Bundle compilation is exercised when the parent release authority is present.
# The standalone engine checkout intentionally has no project bundle sources.
_bundle_source_root=$(cd "$(dirname "$_valise")/../../.." && pwd -P)
if [ -f "$_bundle_source_root/shell/release/bundles.json" ]; then
  _contrib_compile_dir="$_test_home/contrib-compile"
  if "$_valise" compile --bundle=with-contrib "$_contrib_compile_dir" >"$_test_home/contrib-compile.stdout" 2>"$_test_home/contrib-compile.stderr"; then
    if grep 'compiled plan for bash' "$_test_home/contrib-compile.stdout" >/dev/null 2>&1 &&
       grep 'layers/contrib/modules/contrib/hello.sh' "$_contrib_compile_dir/installed-modules.bash" >/dev/null 2>&1; then
      pass "compile preserves source-qualified contribution bundle roots"
    else
      fail "compile preserves source-qualified contribution bundle roots"
    fi
  else
    fail "compile accepts contribution bundle"
  fi
  _invalid_bundle_dir="$_test_home/invalid-bundle-output"
  if "$_valise" compile --bundle=does-not-exist "$_invalid_bundle_dir" >"$_test_home/invalid-bundle.stdout" 2>"$_test_home/invalid-bundle.stderr"; then
    fail "compile rejects unknown bundle"
  else
    pass "compile rejects unknown bundle"
  fi
  if [ -e "$_invalid_bundle_dir" ] || [ -L "$_invalid_bundle_dir" ]; then
    fail "unknown bundle leaves no partial output"
  else
    pass "unknown bundle leaves no partial output"
  fi
  _empty_bundle_dir="$_test_home/empty-bundle-output"
  if "$_valise" compile --bundle= "$_empty_bundle_dir" >"$_test_home/empty-bundle.stdout" 2>"$_test_home/empty-bundle.stderr"; then
    fail "compile rejects empty bundle name"
  else
    pass "compile rejects empty bundle name"
  fi
  if [ -e "$_empty_bundle_dir" ] || [ -L "$_empty_bundle_dir" ]; then
    fail "empty bundle leaves no partial output"
  else
    pass "empty bundle leaves no partial output"
  fi

  # Compilation is transactional with respect to a caller-owned destination:
  # a non-empty output directory is rejected before any plan is written. This
  # prevents a later-shell path failure from leaving an earlier plan behind.
  _occupied_compile_dir="$_test_home/occupied-compile-output"
  mkdir -p "$_occupied_compile_dir/installed-modules.zsh"
  printf '%s\n' caller-owned >"$_occupied_compile_dir/sentinel"
  if "$_valise" compile --bundle=with-contrib "$_occupied_compile_dir" >"$_test_home/occupied-compile.stdout" 2>"$_test_home/occupied-compile.stderr"; then
    fail "compile rejects non-empty output transactionally"
  else
    pass "compile rejects non-empty output transactionally"
  fi
  if [ -e "$_occupied_compile_dir/installed-modules.bash" ] || [ ! -f "$_occupied_compile_dir/sentinel" ] || [ ! -d "$_occupied_compile_dir/installed-modules.zsh" ]; then
    fail "non-empty output remains untouched after compile rejection"
  else
    pass "non-empty output remains untouched after compile rejection"
  fi

  _empty_compile_dir="$_test_home/empty-compile-output"
  mkdir -p "$_empty_compile_dir"
  if "$_valise" compile --bundle=with-contrib "$_empty_compile_dir" >"$_test_home/empty-compile.stdout" 2>"$_test_home/empty-compile.stderr"; then
    pass "compile publishes into an empty pre-created output directory"
  else
    fail "compile publishes into an empty pre-created output directory"
  fi
  if [ -f "$_empty_compile_dir/installed-modules.bash" ]; then
    pass "empty pre-created destination received published plans"
  else
    fail "empty pre-created destination received published plans"
  fi

  # A missing destination is created only at successful publish; staging never
  # leaks into the parent on success or on the occupied-directory rejection.
  _absent_compile_dir="$_test_home/absent-compile-output"
  if "$_valise" compile --bundle=with-contrib "$_absent_compile_dir" >"$_test_home/absent-compile.stdout" 2>"$_test_home/absent-compile.stderr"; then
    pass "compile publishes into an absent output directory"
  else
    fail "compile publishes into an absent output directory"
  fi
  if [ -f "$_absent_compile_dir/installed-modules.bash" ] &&
     [ -f "$_absent_compile_dir/installed-modules.zsh" ] &&
     [ -f "$_absent_compile_dir/installed-modules.ksh" ] &&
     [ -f "$_absent_compile_dir/wrapper-lifecycle.bash" ]; then
    pass "absent destination receives every compiled plan"
  else
    fail "absent destination receives every compiled plan"
  fi
  _stage_leftovers=$(find "$_test_home" -maxdepth 2 -name '.valise-compile.*' 2>/dev/null || :)
  if [ -z "$_stage_leftovers" ]; then
    pass "successful compile leaves no staging directories"
  else
    fail "successful compile leaves no staging directories: $_stage_leftovers"
  fi

  # Trailing-slash destinations must behave like their slash-free twins:
  # stage beside the destination, never inside it.
  _slash_compile_dir="$_test_home/slash-compile-output/"
  if "$_valise" compile --bundle=with-contrib "$_slash_compile_dir" >"$_test_home/slash-compile.stdout" 2>"$_test_home/slash-compile.stderr"; then
    pass "compile publishes into a trailing-slash output directory"
  else
    fail "compile publishes into a trailing-slash output directory" \
      "$(cat "$_test_home/slash-compile.stderr" 2>/dev/null || :)"
  fi
  if [ -f "$_test_home/slash-compile-output/installed-modules.bash" ]; then
    pass "trailing-slash destination received published plans"
  else
    fail "trailing-slash destination received published plans"
  fi
  _slash_stage_leftovers=$(find "$_test_home" -maxdepth 2 -name '.valise-compile.*' 2>/dev/null || :)
  if [ -z "$_slash_stage_leftovers" ]; then
    pass "trailing-slash compile leaves no staging directories"
  else
    fail "trailing-slash compile leaves no staging directories: $_slash_stage_leftovers"
  fi

  check_output_contains "explain-bundles shows installed bundle" "Installed bundle resolution:" "$_valise" explain-bundles
fi

# --- Install (requires manifest context) ---
# Create a minimal fake manifest for testing
_manifest_dir="$_test_home/repo/shell/install"
mkdir -p "$_manifest_dir"
_release_sha="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
_fixture_source="$_test_home/repo/fixture.sh"
printf '# fixture\n' > "$_fixture_source"
# The manifest deliberately declares the source mode; normalize the fixture
# before hashing so a restrictive caller umask cannot change the test input.
chmod 0644 "$_fixture_source"
if command -v sha256sum >/dev/null 2>&1; then
  _fixture_digest=$(sha256sum "$_fixture_source" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  _fixture_digest=$(shasum -a 256 "$_fixture_source" | cut -d' ' -f1)
else
  printf '%s\n' 'FAIL: no SHA-256 utility (need sha256sum or shasum)' >&2
  exit 1
fi
printf '%s\n' \
  'shell-profile-release-manifest-v1' \
  'destination	source	source_mode	install_mode	bytes	sha256' \
  "fixture.sh	fixture.sh	0644	0444	10	$_fixture_digest" > "$_manifest_dir/profile-release.manifest"

# Test install from repo root context
(cd "$_test_home/repo" && "$_valise" install 2>&1)

# Check that directories were created
if [ -d "$XDG_DATA_HOME/valise/releases" ]; then
  pass "install creates releases directory"
else
  fail "install creates releases directory"
fi

if [ -d "$XDG_CONFIG_HOME/valise" ]; then
  pass "install creates config directory"
else
  fail "install creates config directory"
fi

# Check that shell integration was auto-deployed
# The test environment sets SHELL=/bin/sh, so we test with explicit bash
_bash_profile_expected="$_test_home/.bashrc"
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  _bash_profile_expected="$_test_home/.bash_profile"
fi
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
if [ -f "$_bash_profile_expected" ]; then
  if grep -q "managed by valise install" "$_bash_profile_expected"; then
    pass "install auto-deploys bash integration to platform-appropriate file"
  else
    fail "install auto-deploys bash integration (marker missing)"
  fi
else
  fail "install auto-deploys bash integration (file not created: $_bash_profile_expected)"
fi

# Verify idempotency: running install again should not duplicate the snippet
_snippet_count_before=$(grep -c "managed by valise install" "$_bash_profile_expected" || echo 0)
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
_snippet_count_after=$(grep -c "managed by valise install" "$_bash_profile_expected" || echo 0)
if [ "$_snippet_count_before" = "$_snippet_count_after" ]; then
  pass "install is idempotent (no duplicate snippets)"
else
  fail "install is idempotent (snippet count changed: $_snippet_count_before -> $_snippet_count_after)"
fi

# Test zsh deployment
_zsh_profile_expected="$_test_home/.zshrc"
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  _zsh_profile_expected="$_test_home/.zprofile"
fi
(cd "$_test_home/repo" && SHELL=/bin/zsh "$_valise" install >/dev/null 2>&1)
if [ -f "$_zsh_profile_expected" ]; then
  if grep -q "managed by valise install" "$_zsh_profile_expected"; then
    pass "install auto-deploys zsh integration to platform-appropriate file"
  else
    fail "install auto-deploys zsh integration (marker missing)"
  fi
else
  fail "install auto-deploys zsh integration (file not created: $_zsh_profile_expected)"
fi

# Test that existing profile content is preserved
_custom_profile_content="# existing user config"
_bash_profile_test="$_test_home/.bashrc"
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  _bash_profile_test="$_test_home/.bash_profile"
fi
printf '%s\n' "$_custom_profile_content" > "$_bash_profile_test"
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
if grep -q "existing user config" "$_bash_profile_test"; then
  pass "install preserves existing profile content"
else
  fail "install preserves existing profile content"
fi

# Test ksh deployment
_ksh_profile_expected="$_test_home/.kshrc"
(cd "$_test_home/repo" && SHELL=/bin/ksh "$_valise" install >/dev/null 2>&1)
if [ -f "$_ksh_profile_expected" ]; then
  if grep -q "managed by valise install" "$_ksh_profile_expected"; then
    pass "install auto-deploys ksh integration"
  else
    fail "install auto-deploys ksh integration (marker missing)"
  fi
else
  fail "install auto-deploys ksh integration (file not created: $_ksh_profile_expected)"
fi

# Test unknown shell: install should skip POSIX shell integration gracefully
_unknown_before_count=$(find "$_test_home" -maxdepth 1 -name '.bash*' -o -name '.zsh*' -o -name '.ksh*' 2>/dev/null | wc -l)
(cd "$_test_home/repo" && SHELL=/bin/tcsh "$_valise" install >/dev/null 2>&1)
_unknown_after_count=$(find "$_test_home" -maxdepth 1 -name '.bash*' -o -name '.zsh*' -o -name '.ksh*' 2>/dev/null | wc -l)
if [ "$_unknown_before_count" = "$_unknown_after_count" ]; then
  pass "install skips shell integration for unknown shell"
else
  fail "install skips shell integration for unknown shell (new files appeared)"
fi

# Test symlink profile: install should skip and not overwrite the symlink
_symlink_profile="$_test_home/.bashrc"
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  _symlink_profile="$_test_home/.bash_profile"
fi
rm -f "$_symlink_profile"
printf '%s\n' "# symlink target" > "$_test_home/.profile-real"
ln -s "$_test_home/.profile-real" "$_symlink_profile"
# Capture the install output without letting a `grep -q` miss abort the
# suite under `set -eu`. The subshell + pipeline would otherwise exit the
# parent script silently with no fail recorded.
_symlink_install_out=$(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install 2>&1) || true
_symlink_warned=0
case "$_symlink_install_out" in
  *symlink*) _symlink_warned=1 ;;
esac
if [ -L "$_symlink_profile" ] && [ "$_symlink_warned" -eq 1 ]; then
  pass "install preserves symlink profile (does not replace)"
elif [ -L "$_symlink_profile" ]; then
  fail "install preserves symlink profile (no symlink diagnostic emitted)"
else
  fail "install preserves symlink profile (symlink was replaced)"
fi

if "$_valise" verify-active >/dev/null 2>&1; then
  pass "verify-active authenticates the installed release"
else
  fail "verify-active authenticates the installed release"
fi
_installed_active=$(readlink "$XDG_CONFIG_HOME/valise/active")
chmod u+w "$_installed_active/fixture.sh"
printf '%s\n' tampered >>"$_installed_active/fixture.sh"
if "$_valise" verify-active >/dev/null 2>&1; then
  fail "verify-active rejects a tampered release"
else
  pass "verify-active rejects a tampered release"
fi
chmod u-w "$_installed_active/fixture.sh"
# Restore the disposable release bytes before the later variant-switch fixture
# copies them into its intentionally minimal test releases.
chmod u+w "$_installed_active/fixture.sh"
cp -p "$_fixture_source" "$_installed_active/fixture.sh"
chmod 0444 "$_installed_active/fixture.sh"

# --- file_sha256 '= ' path regression test ---
# Regression test for the greedy ${_sha_output##*= } strip that corrupted
# sha256sum/shasum output when the absolute path contains '= ' (equals
# followed by space). This exercises bin/valise itself — not a copy of its
# parsing logic — by running install + verify-active with HOME containing
# '= ', so every staged and installed release path contains '= '. A parsing
# regression fails install or verify instead of passing silently.
_eq_home="$_test_home/home= with equals"
mkdir -p "$_eq_home"
if (cd "$_test_home/repo" && HOME="$_eq_home" XDG_DATA_HOME="$_eq_home/.local/share" XDG_CONFIG_HOME="$_eq_home/.config" XDG_STATE_HOME="$_eq_home/.local/state" SHELL=/bin/bash "$_valise" install >/dev/null 2>&1); then
  pass "install succeeds with '= ' in HOME path"
else
  fail "install succeeds with '= ' in HOME path"
fi
if HOME="$_eq_home" XDG_DATA_HOME="$_eq_home/.local/share" XDG_CONFIG_HOME="$_eq_home/.config" XDG_STATE_HOME="$_eq_home/.local/state" "$_valise" verify-active >/dev/null 2>&1; then
  pass "verify-active passes with '= ' in HOME path"
else
  fail "verify-active passes with '= ' in HOME path"
fi

# --- Atomic symlink swap test ---
# Create two fake releases and verify swap doesn't touch .profile
_rel1="$XDG_DATA_HOME/valise/releases/release_a"
_rel2="$XDG_DATA_HOME/valise/releases/release_b"
_installed_active=$(readlink "$XDG_CONFIG_HOME/valise/active")
mkdir -p "$_rel1" "$_rel2"
cp -p "$_installed_active/fixture.sh" "$_rel1/fixture.sh"
cp -p "$_installed_active/fixture.sh" "$_rel2/fixture.sh"
chmod 0444 "$_rel1/fixture.sh" "$_rel2/fixture.sh"
chmod 0555 "$_rel1" "$_rel2"

# Set initial active
ln -sfn "$_rel1" "$XDG_CONFIG_HOME/valise/active"

# Create a .profile that should NOT be modified by variant switch
printf '# test profile\n' > "$_test_home/.profile"
_profile_before=$(cat "$_test_home/.profile")

# Switch variant
(cd "$_test_home/repo" && "$_valise" variant use release_b 2>/dev/null)

_profile_after=$(cat "$_test_home/.profile")
if [ "$_profile_before" = "$_profile_after" ]; then
  pass "variant use does not modify .profile"
else
  fail "variant use does not modify .profile"
fi

# Verify symlink actually changed
_active_target=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
if [ "$_active_target" = "$_rel2" ]; then
  pass "variant use updates active symlink"
else
  fail "variant use updates active symlink (got: $_active_target)"
fi

# Switch back
(cd "$_test_home/repo" && "$_valise" variant use release_a 2>/dev/null)
_active_target=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
if [ "$_active_target" = "$_rel1" ]; then
  pass "variant use round-trips correctly"
else
  fail "variant use round-trips correctly"
fi

# --- Unknown command ---
_unknown_out=$("$_valise" bogus 2>&1) || true
case "$_unknown_out" in
  *"unknown command: bogus"*) pass "unknown command rejected" ;;
  *) fail "unknown command rejected" ;;
esac

# --- Summary ---
printf '\n=== valise CLI summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ] || exit 1
