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

# Exact whole-output comparison. A version check that only looks for a
# substring accepts "0.2.0-beta" and "10.2.0" as evidence of "0.2.0",
# so the version contract is pinned exactly.
check_output_equals() {
  _desc=$1; _expected=$2; shift 2
  _out=$("$@" 2>&1) || true
  if [ "$_out" = "$_expected" ]; then
    pass "$_desc"
  else
    fail "$_desc (expected '$_expected', got '$_out')"
  fi
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
check_output_equals "version prints version string" "0.2.0" "$_valise" version

# The release policy requires package.json and bin/valise to carry the same
# version. A bump that updates one and forgets the other ships a tarball
# whose metadata disagrees with its own CLI.
_pkg_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$(dirname "$_valise")/../package.json" | head -1)
check_output_equals "package.json version matches the CLI version" \
  "$_pkg_version" "$_valise" version
unset _pkg_version

# --- Help ---
check_output_contains "help shows usage" "Usage: valise" "$_valise" help
check_output_contains "no args shows usage" "Usage: valise" "$_valise"

# --- Init ---
check_output_contains "init posix outputs profile source" ". " "$_valise" init posix
check_output_contains "init fish outputs protected Fish loader integration" "loader.fish" "$_valise" init fish

# Verify init output contains active link path. The CLI prints the
# normalized path, so the expectation is normalized the same way. A raw
# comparison fails when TMPDIR ends in a slash, because the CLI collapses
# the doubled separator and the test's template keeps it.
_init_expected_active=$XDG_CONFIG_HOME/valise/active
_init_expected_active=$(printf '%s' "$_init_expected_active" |
  awk '{ n = split($0, p, "/"); out = ""; for (i = 1; i <= n; i++) { if (p[i] == "" || p[i] == ".") continue; out = out "/" p[i] } print out }')
_init_out=$("$_valise" init posix 2>&1)
case "$_init_out" in
  *"$_init_expected_active"*) pass "init posix references XDG active path" ;;
  *) fail "init posix references XDG active path (expected '$_init_expected_active')" ;;
esac
unset _init_expected_active _init_out

# Generated shell snippets must quote hostile XDG paths as data. In particular,
# command substitutions in an environment-provided path must not execute while
# `valise init` emits Fish, Bash, Zsh, Ksh, or POSIX-sh integration.
_injection_marker="$_test_home/integration-command-substitution-ran"
_injection_xdg="$_test_home/xdg-\$(touch $_injection_marker)/a\\'h"
XDG_CONFIG_HOME="$_injection_xdg" "$_valise" init fish >"$_test_home/init-fish-hostile.out"
XDG_CONFIG_HOME="$_injection_xdg" "$_valise" init posix >"$_test_home/init-sh-hostile.out"
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

# --- Release list (empty) ---
check_output_contains "release list on empty state" "no releases installed" "$_valise" release list

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
_mm_manifest="$_mm_tree/manifest.tsv"
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

# An existing directory is not a manifest file. It must be rejected without
# chmod-ing the directory or nesting the manifest inside it.
_mm_outdir="$_test_home/manifest-outdir"
mkdir -p "$_mm_outdir"
chmod 0755 "$_mm_outdir"
if "$_valise" make-manifest "$_mm_tree" --output "$_mm_outdir" >/dev/null 2>&1; then
  fail "make-manifest rejects a directory output"
elif [ "$(stat -c %a "$_mm_outdir" 2>/dev/null || stat -f %Lp "$_mm_outdir")" = 755 ] &&
  [ ! -e "$_mm_outdir/manifest.tsv" ]; then
  pass "make-manifest rejects a directory output without changing it"
else
  fail "make-manifest rejects a directory output without changing it"
fi

# A normalized output path inside the tree must still exclude itself on a
# second run, so the manifest stays byte-identical.
_mm_dot_out="$_mm_tree/./custom.manifest"
"$_valise" make-manifest "$_mm_tree" --output "$_mm_dot_out" >/dev/null 2>&1 || :
cp "$_mm_tree/custom.manifest" "$_test_home/custom.first"
if "$_valise" make-manifest "$_mm_tree" --output "$_mm_dot_out" >/dev/null 2>&1 &&
  cmp -s "$_mm_tree/custom.manifest" "$_test_home/custom.first" &&
  ! grep -F 'custom.manifest' "$_mm_tree/custom.manifest" >/dev/null 2>&1; then
  pass "make-manifest excludes a normalized in-tree output from itself"
else
  fail "make-manifest excludes a normalized in-tree output from itself"
fi
rm -f "$_mm_tree/custom.manifest"
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

# A local build writes examples/*/build/ inside the source tree, and npm
# applies package.json "files" without consulting .gitignore. Packaging from
# a built checkout must still ship only the intended example sources.
if command -v npm >/dev/null 2>&1; then
  _pack_probe="$_test_home/pack-probe"
  mkdir -p "$_pack_probe/examples/profile-project/build/release" \
           "$_pack_probe/examples/e2e/build/release" \
           "$_pack_probe/examples/profile-project/modules"
  printf 'generated\n' >"$_pack_probe/examples/profile-project/build/release/plan.sh"
  printf 'generated\n' >"$_pack_probe/examples/e2e/build/release/plan.sh"
  printf 'source\n' >"$_pack_probe/examples/profile-project/modules/keep.sh"
  # A build directory nested below a subdirectory is the case that a
  # single-level '!examples/*/build/' would miss, so pin it too.
  mkdir -p "$_pack_probe/examples/profile-project/vendor/dep/build/release"
  printf 'generated\n' >"$_pack_probe/examples/profile-project/vendor/dep/build/release/plan.sh"
  cp "$_pkg_root/package.json" "$_pack_probe/package.json"
  _pack_status=0
  _pack_out=$(cd "$_pack_probe" && npm pack --dry-run --json 2>&1) || _pack_status=$?
  if [ "$_pack_status" -ne 0 ]; then
    fail "npm pack runs on the exclusion probe"
    printf '%s\n' "$_pack_out" >&2
    fail "npm pack excludes generated examples build output (probe did not run)"
    fail "npm pack still ships example project sources (probe did not run)"
  else
    if printf '%s\n' "$_pack_out" | grep -Eq '"path": *"examples/[^"]*/build/'; then
      fail "npm pack excludes generated examples build output"
      printf '%s\n' "$_pack_out" | grep -E '"path": *"examples/[^"]*/build/' >&2 || :
    elif printf '%s\n' "$_pack_out" | grep -Eq '"path": *"examples/[^"]*"'; then
      pass "npm pack excludes generated examples build output"
    else
      fail "npm pack excludes generated examples build output (no example files listed)"
    fi
    if printf '%s\n' "$_pack_out" | grep -Eq '"path": *"examples/profile-project/modules/keep\.sh"'; then
      pass "npm pack still ships example project sources"
    else
      fail "npm pack still ships example project sources"
    fi
  fi
  unset _pack_probe _pack_out _pack_status
else
  printf '  SKIP: npm pack example exclusion check (npm unavailable)\n'
fi
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
  for _tar_member in package/bin/valise package/lib/cli/usage.sh package/lib/cli/common.sh package/lib/cli/store.sh package/lib/cli/fish-hook.sh package/lib/cli/integration.sh package/lib/cli/project.sh package/entrypoints/profile.sh package/entrypoints/fish/profile.fish package/lib/loader.sh package/lib/metadata.sh package/lib/capabilities.sh package/lib/fish/loader.fish package/lib/fish/metadata.fish package/manifests/parser-support.tsv package/module.d/valise_path.meta package/modules/system/valise_path.sh package/docs/installation.md package/docs/release-policy.md package/examples/local/modules/hello_valise.sh package/LICENSE package/CHANGELOG.md; do
    if [ -f "$_tar_root/$_tar_member" ]; then
      pass "tarball contains $_tar_member"
    else
      fail "tarball contains $_tar_member"
    fi
  done
  if VALISE_ROOT="$_tar_root/package" \
     VALISE_MODULE_ROOT="$_tar_root/package" \
     VALISE_MODULES='valise_pager' \
     VALISE_MODE=strict \
     /bin/sh -c '. "$VALISE_ROOT/entrypoints/profile.sh" || exit 99; command -v valise_pager_defaults >/dev/null 2>&1' >/dev/null 2>&1; then
    pass "module loads from the extracted tarball tree"
  else
    fail "module loads from the extracted tarball tree"
  fi
  _npm_prefix="$_test_home/npm-prefix"
  if npm install --global --offline --prefix "$_npm_prefix" "$_npm_root/$_npm_tgz" >"$_test_home/npm-install.out" 2>&1; then
    pass "npm installs the packed CLI without a registry"
    if "$_npm_prefix/bin/valise" version 2>/dev/null | grep '^0.2.0$' >/dev/null 2>&1; then
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

# --- Install (requires manifest context) ---
# Create a minimal fake manifest for testing
_manifest_dir="$_test_home/repo"
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
  'valise-manifest-v2' \
  'destination	source	source_mode	install_mode	bytes	sha256' \
  "fixture.sh	fixture.sh	0644	0444	10	$_fixture_digest" > "$_manifest_dir/manifest.tsv"

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
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
if [ -f "$_bash_profile_expected" ]; then
  if grep -q "# BEGIN valise managed block" "$_bash_profile_expected"; then
    pass "install writes bash integration to ~/.bashrc"
  else
    fail "install writes bash integration (marker missing)"
  fi
else
  fail "install writes bash integration (file not created: $_bash_profile_expected)"
fi

# Verify idempotency: running install again should not duplicate the snippet
_snippet_count_before=$(grep -c "# BEGIN valise managed block" "$_bash_profile_expected" || echo 0)
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
_snippet_count_after=$(grep -c "# BEGIN valise managed block" "$_bash_profile_expected" || echo 0)
if [ "$_snippet_count_before" = "$_snippet_count_after" ]; then
  pass "install is idempotent (no duplicate snippets)"
else
  fail "install is idempotent (snippet count changed: $_snippet_count_before -> $_snippet_count_after)"
fi

# Test zsh deployment
_zsh_profile_expected="$_test_home/.zshrc"
(cd "$_test_home/repo" && SHELL=/bin/zsh "$_valise" install >/dev/null 2>&1)
if [ -f "$_zsh_profile_expected" ]; then
  if grep -q "# BEGIN valise managed block" "$_zsh_profile_expected"; then
    pass "install writes zsh integration to ~/.zshrc"
  else
    fail "install writes zsh integration (marker missing)"
  fi
else
  fail "install writes zsh integration (file not created: $_zsh_profile_expected)"
fi

# Test that existing profile content is preserved
_custom_profile_content="# existing user config"
_bash_profile_test="$_test_home/.bashrc"
printf '%s\n' "$_custom_profile_content" > "$_bash_profile_test"
(cd "$_test_home/repo" && SHELL=/bin/bash "$_valise" install >/dev/null 2>&1)
if grep -q "existing user config" "$_bash_profile_test"; then
  pass "install preserves existing profile content"
else
  fail "install preserves existing profile content"
fi

# Test ksh deployment
_ksh_profile_expected="$_test_home/.profile"
(cd "$_test_home/repo" && SHELL=/bin/ksh "$_valise" install >/dev/null 2>&1)
if [ -f "$_ksh_profile_expected" ]; then
  if grep -q "# BEGIN valise managed block" "$_ksh_profile_expected"; then
    pass "install writes ksh integration"
  else
    fail "install writes ksh integration (marker missing)"
  fi
else
  fail "install writes ksh integration (file not created: $_ksh_profile_expected)"
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

if "$_valise" release verify >/dev/null 2>&1; then
  pass "release verify authenticates the installed release"
else
  fail "release verify authenticates the installed release"
fi
_installed_active=$(readlink "$XDG_CONFIG_HOME/valise/active")
chmod u+w "$_installed_active/fixture.sh"
printf '%s\n' tampered >>"$_installed_active/fixture.sh"
if "$_valise" release verify >/dev/null 2>&1; then
  fail "release verify rejects a tampered release"
else
  pass "release verify rejects a tampered release"
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
# parsing logic — by running install + release verify with HOME containing
# '= ', so every staged and installed release path contains '= '. A parsing
# regression fails install or verify instead of passing silently.
_eq_home="$_test_home/home= with equals"
mkdir -p "$_eq_home"
if (cd "$_test_home/repo" && HOME="$_eq_home" XDG_DATA_HOME="$_eq_home/.local/share" XDG_CONFIG_HOME="$_eq_home/.config" XDG_STATE_HOME="$_eq_home/.local/state" SHELL=/bin/bash "$_valise" install >/dev/null 2>&1); then
  pass "install succeeds with '= ' in HOME path"
else
  fail "install succeeds with '= ' in HOME path"
fi
if HOME="$_eq_home" XDG_DATA_HOME="$_eq_home/.local/share" XDG_CONFIG_HOME="$_eq_home/.config" XDG_STATE_HOME="$_eq_home/.local/state" "$_valise" release verify >/dev/null 2>&1; then
  pass "release verify passes with '= ' in HOME path"
else
  fail "release verify passes with '= ' in HOME path"
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
(cd "$_test_home/repo" && "$_valise" release use release_b 2>/dev/null)

_profile_after=$(cat "$_test_home/.profile")
if [ "$_profile_before" = "$_profile_after" ]; then
  pass "release use does not modify .profile"
else
  fail "release use does not modify .profile"
fi

# Verify symlink actually changed. The pointer names a release directory;
# compare the directory each path resolves to, not its spelling. The CLI
# writes a normalized target, so a raw comparison fails whenever the test's
# own path spelling differs (a TMPDIR ending in a slash, for example).
_active_target=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
_active_resolved=$(cd "$_active_target" 2>/dev/null && pwd -P) || _active_resolved=
_rel2_resolved=$(cd "$_rel2" 2>/dev/null && pwd -P) || _rel2_resolved=
if [ -n "$_active_resolved" ] && [ "$_active_resolved" = "$_rel2_resolved" ]; then
  pass "release use updates active symlink"
else
  fail "release use updates active symlink (got: $_active_target)"
fi

# Switch back
(cd "$_test_home/repo" && "$_valise" release use release_a 2>/dev/null)
_active_target=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
_active_resolved=$(cd "$_active_target" 2>/dev/null && pwd -P) || _active_resolved=
_rel1_resolved=$(cd "$_rel1" 2>/dev/null && pwd -P) || _rel1_resolved=
if [ -n "$_active_resolved" ] && [ "$_active_resolved" = "$_rel1_resolved" ]; then
  pass "release use round-trips correctly"
else
  fail "release use round-trips correctly"
fi
unset _active_target _active_resolved _rel1_resolved _rel2_resolved

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
