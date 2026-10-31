#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Contract test for the CLI gaps closed in the profile-management overhaul:
# doctor fails without a usable release and checks the running shell's
# startup file, `variant prune` keeps the active release and never removes a
# release that fails verification, explain-bundles and layer-lint run
# natively without python3, and every command has its own --help.
#
# Pure POSIX. Runs in a quarantined disposable home.

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
_test_root=$(mktemp -d "${TMPDIR:-/tmp}/valise-cli-gaps.XXXXXX")
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_test_root" 2>/dev/null || :
  rm -rf -- "$_test_root"
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

printf '=== valise CLI gaps ===\n'
printf '  root: %s\n\n' "$_test_root"

# A quarantined environment with its own HOME and XDG roots.
_env() {
  HOME="$_test_root/home"
  XDG_DATA_HOME="$_test_root/home/.local/share"
  XDG_CONFIG_HOME="$_test_root/home/.config"
  XDG_STATE_HOME="$_test_root/home/.local/state"
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME PATH
}
mkdir -p "$_test_root/home"

# Build a release tree with one regular file and install it.
_make_release() {
  _mr_tree=$1
  _mr_body=$2
  mkdir -p "$_mr_tree/bin"
  printf '%s\n' "$_mr_body" >"$_mr_tree/bin/tool.sh"
  chmod 0755 "$_mr_tree/bin/tool.sh"
  (cd "$_mr_tree" && "$_valise" make-manifest . >/dev/null 2>&1)
}

# --- doctor: no active release must fail ---

if _env; then
  if "$_valise" doctor >"$_test_root/doctor-empty.out" 2>&1; then
    fail "doctor fails with no active release"
  else
    pass "doctor fails with no active release"
  fi
  if grep -F 'no active release configured' "$_test_root/doctor-empty.out" >/dev/null 2>&1; then
    pass "doctor names the missing active release"
  else
    fail "doctor names the missing active release"
    cat "$_test_root/doctor-empty.out" >&2
  fi
fi

# --- doctor: --pre-install is the explicit opt-out ---

if _env; then
  if "$_valise" doctor --pre-install >"$_test_root/doctor-pre.out" 2>&1; then
    pass "doctor --pre-install succeeds without a release"
  else
    fail "doctor --pre-install succeeds without a release"
    cat "$_test_root/doctor-pre.out" >&2
  fi
  if grep -F 'skipping the active release check' "$_test_root/doctor-pre.out" >/dev/null 2>&1; then
    pass "doctor --pre-install says it skipped the release check"
  else
    fail "doctor --pre-install says it skipped the release check"
  fi
fi

# --- doctor: names the missing integration ---

if _env; then
  if "$_valise" doctor --no-integration >"$_test_root/doctor-noint.out" 2>&1; then
    fail "doctor fails with no release even without the integration check"
  else
    pass "doctor fails with no release even without the integration check"
  fi
fi

# --- doctor: an installed release with a managed block passes ---

_release_one="$_test_root/release-one"
_make_release "$_release_one" '# release one'
if _env; then
  (cd "$_release_one" && "$_valise" install) >"$_test_root/install-one.out" 2>&1 || :
  if "$_valise" doctor >"$_test_root/doctor-ok.out" 2>&1; then
    pass "doctor succeeds with a verified release and a managed block"
  else
    fail "doctor succeeds with a verified release and a managed block"
    cat "$_test_root/doctor-ok.out" >&2
  fi
  if grep -F 'startup file contains the valise managed block' "$_test_root/doctor-ok.out" >/dev/null 2>&1; then
    pass "doctor reports the managed block in a startup file"
  else
    fail "doctor reports the managed block in a startup file"
    cat "$_test_root/doctor-ok.out" >&2
  fi
  if grep -F 'active release verifies' "$_test_root/doctor-ok.out" >/dev/null 2>&1; then
    pass "doctor verifies the active release"
  else
    fail "doctor verifies the active release"
    cat "$_test_root/doctor-ok.out" >&2
  fi

  # The active pointer must name the release that was just installed, and
  # verify-active must resolve that pointer to a directory that verifies.
  # The comparison is on the resolved directories, not on their spellings:
  # the CLI writes a normalized target, so a raw comparison fails whenever
  # the test's own path spelling differs (a TMPDIR ending in a slash, for
  # example).
  _active_link="$XDG_CONFIG_HOME/valise/active"
  _active_target=$(readlink "$_active_link" 2>/dev/null || :)
  _active_resolved=$(cd "$_active_target" 2>/dev/null && pwd -P) || _active_resolved=
  _expected_target=$(find "$XDG_DATA_HOME/valise/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  _expected_resolved=$(cd "$_expected_target" 2>/dev/null && pwd -P) || _expected_resolved=
  if [ -n "$_active_resolved" ] && [ "$_active_resolved" = "$_expected_resolved" ] &&
    [ -d "$_active_target" ]; then
    pass "the active pointer names the installed release directory"
  else
    fail "the active pointer names the installed release directory" \
      "pointer=$_active_target expected=$_expected_target"
  fi
  unset _active_resolved _expected_resolved
  if "$_valise" verify-active >"$_test_root/verify-active.out" 2>&1; then
    pass "verify-active resolves the active pointer to a verifying release"
  else
    fail "verify-active resolves the active pointer to a verifying release"
    cat "$_test_root/verify-active.out" >&2
  fi

  # --no-integration must skip the startup-file check, not merely the
  # release check. A machine with a good release and no managed block
  # fails the default doctor, and passes when the integration check is
  # explicitly turned off.
  _profile_backup="$_test_root/profile-backup"
  if [ -f "$HOME/.profile" ]; then
    cp "$HOME/.profile" "$_profile_backup"
  else
    : >"$_profile_backup"
  fi
  _bashrc_backup="$_test_root/bashrc-backup"
  if [ -f "$HOME/.bashrc" ]; then mv "$HOME/.bashrc" "$_bashrc_backup"; fi
  rm -f "$HOME/.profile"
  if "$_valise" doctor >"$_test_root/doctor-noblock.out" 2>&1; then
    fail "doctor fails when the startup file has no managed block"
  else
    pass "doctor fails when the startup file has no managed block"
  fi
  if grep -F 'no valise integration found' "$_test_root/doctor-noblock.out" >/dev/null 2>&1; then
    pass "doctor names the missing startup-file integration"
  else
    fail "doctor names the missing startup-file integration"
    cat "$_test_root/doctor-noblock.out" >&2
  fi
  if "$_valise" doctor --no-integration >"$_test_root/doctor-noblock-noint.out" 2>&1; then
    pass "doctor --no-integration skips the startup-file check"
  else
    fail "doctor --no-integration skips the startup-file check"
    cat "$_test_root/doctor-noblock-noint.out" >&2
  fi
  if grep -F 'skipping the shell integration check' \
    "$_test_root/doctor-noblock-noint.out" >/dev/null 2>&1; then
    pass "doctor --no-integration reports that it skipped the check"
  else
    fail "doctor --no-integration reports that it skipped the check"
    cat "$_test_root/doctor-noblock-noint.out" >&2
  fi
  if grep -F 'startup file' "$_test_root/doctor-noblock-noint.out" >/dev/null 2>&1; then
    fail "doctor --no-integration examines no startup file"
    cat "$_test_root/doctor-noblock-noint.out" >&2
  else
    pass "doctor --no-integration examines no startup file"
  fi
  if [ -f "$_bashrc_backup" ]; then mv "$_bashrc_backup" "$HOME/.bashrc"; fi
  if [ -s "$_profile_backup" ]; then
    cp "$_profile_backup" "$HOME/.profile"
  else
    rm -f "$HOME/.profile"
  fi
fi

# --- doctor: a tampered release fails ---

if _env; then
  _active=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
  if [ -n "$_active" ] && [ -d "$_active" ]; then
    chmod -R u+w "$_active" 2>/dev/null || :
    printf 'tampered\n' >>"$_active/bin/tool.sh"
    if "$_valise" doctor >"$_test_root/doctor-tampered.out" 2>&1; then
      fail "doctor fails when the active release is tampered"
    else
      pass "doctor fails when the active release is tampered"
    fi
    if grep -F 'active release does not verify' "$_test_root/doctor-tampered.out" >/dev/null 2>&1; then
      pass "doctor names the release that does not verify"
    else
      fail "doctor names the release that does not verify"
      cat "$_test_root/doctor-tampered.out" >&2
    fi
  else
    skip "doctor fails when the active release is tampered (no active release)"
    skip "doctor names the release that does not verify (no active release)"
  fi
fi

# --- variant prune ---

# Install four distinct releases so prune has something to choose between.
_prune_home="$_test_root/prune-home"
mkdir -p "$_prune_home"
_prune_active=""
_prune_index=0
for _prune_body in one two three four; do
  _prune_index=$((_prune_index + 1))
  _prune_tree="$_test_root/prune-tree-$_prune_index"
  _make_release "$_prune_tree" "# release $_prune_body"
  (
    cd "$_prune_tree" &&
      HOME="$_prune_home" \
        XDG_DATA_HOME="$_prune_home/.local/share" \
        XDG_CONFIG_HOME="$_prune_home/.config" \
        XDG_STATE_HOME="$_prune_home/.local/state" \
        SHELL=/bin/bash \
        "$_valise" install --no-integration
  ) >"$_test_root/prune-install-$_prune_index.out" 2>&1
  # Distinct modification times so the newest-N ordering is deterministic.
  sleep 1
done

_prune_releases="$_prune_home/.local/share/valise/releases"
_prune_count=$(find "$_prune_releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$_prune_count" -eq 4 ]; then
  pass "four distinct releases are installed for the prune test"
else
  fail "four distinct releases are installed for the prune test" "got $_prune_count"
fi

_prune_active=$(readlink "$_prune_home/.config/valise/active" 2>/dev/null || :)
_prune_active_id=${_prune_active##*/}

if [ -n "$_prune_active_id" ]; then
  (
    cd "$_prune_releases/.." &&
      HOME="$_prune_home" \
        XDG_DATA_HOME="$_prune_home/.local/share" \
        XDG_CONFIG_HOME="$_prune_home/.config" \
        XDG_STATE_HOME="$_prune_home/.local/state" \
        "$_valise" variant prune --keep=1
  ) >"$_test_root/prune.out" 2>&1 || true
  _prune_after=$(find "$_prune_releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_prune_after" -eq 2 ]; then
    pass "prune keeps the active release plus the newest one"
  else
    fail "prune keeps the active release plus the newest one" "got $_prune_after releases"
    cat "$_test_root/prune.out" >&2
  fi
  if [ -d "$_prune_releases/$_prune_active_id" ]; then
    pass "prune keeps the active release"
  else
    fail "prune keeps the active release"
  fi
else
  skip "prune keeps the active release plus the newest one (no active release)"
  skip "prune keeps the active release (no active release)"
fi

# A release that fails verification must not be removed.
_prune_corrupt=""
for _prune_candidate in "$_prune_releases"/*/; do
  [ -d "$_prune_candidate" ] || continue
  _prune_candidate_id=${_prune_candidate%/}
  _prune_candidate_id=${_prune_candidate_id##*/}
  [ "$_prune_candidate_id" = "$_prune_active_id" ] && continue
  _prune_corrupt=$_prune_candidate_id
  break
done
if [ -n "$_prune_corrupt" ]; then
  chmod -R u+w "$_prune_releases/$_prune_corrupt" 2>/dev/null || :
  printf 'tampered\n' >>"$_prune_releases/$_prune_corrupt/bin/tool.sh"
  (
    cd "$_prune_releases/.." &&
      HOME="$_prune_home" \
        XDG_DATA_HOME="$_prune_home/.local/share" \
        XDG_CONFIG_HOME="$_prune_home/.config" \
        XDG_STATE_HOME="$_prune_home/.local/state" \
        "$_valise" variant prune --keep=0
  ) >"$_test_root/prune-corrupt.out" 2>&1 || true
  if [ -d "$_prune_releases/$_prune_corrupt" ]; then
    pass "prune keeps a release that fails verification"
  else
    fail "prune keeps a release that fails verification"
    cat "$_test_root/prune-corrupt.out" >&2
  fi
  if grep -F 'keeping unverifiable release' "$_test_root/prune-corrupt.out" >/dev/null 2>&1; then
    pass "prune reports that it kept an unverifiable release"
  else
    fail "prune reports that it kept an unverifiable release"
    cat "$_test_root/prune-corrupt.out" >&2
  fi
else
  skip "prune keeps a release that fails verification (no candidate)"
  skip "prune reports that it kept an unverifiable release (no candidate)"
fi

# --- explain-bundles without python3 ---

_project="$_test_root/project"
mkdir -p "$_project/shell/module.d" "$_project/shell/modules" "$_project/shell/release"
printf '%s\n' \
  'name=root_mod' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=' \
  'optional=' \
  'shells=sh bash zsh ksh' \
  'platforms=any' \
  'exports=root_mod_ready' \
  'updates=' \
  'load=modules/root_mod.sh' \
  >"$_project/shell/module.d/root_mod.meta"
printf 'root_mod_ready() { :; }\n' >"$_project/shell/modules/root_mod.sh"
printf '%s\n' \
  'name=dep_mod' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=root_mod' \
  'optional=' \
  'shells=sh bash zsh ksh' \
  'platforms=any' \
  'exports=dep_mod_ready' \
  'updates=' \
  'load=modules/dep_mod.sh' \
  >"$_project/shell/module.d/dep_mod.meta"
printf 'dep_mod_ready() { :; }\n' >"$_project/shell/modules/dep_mod.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tdep_mod\ndefault\tzsh\tdep_mod\n' \
  >"$_project/shell/release/bundle-roots"
printf 'variant_name\tdescription\texcluded_modules\nworkstation-full\tAll modules\t\n' \
  >"$_project/shell/release/install-variants"

# A PATH without python3 proves the native implementation is used.
_no_python_path="$_test_root/no-python-bin"
mkdir -p "$_no_python_path"
# On a merged-/usr system a tool exists in both directories, so link only the first.
for _tool in awk cat chmod cmp cp find ln mkdir mktemp mv rm rmdir sha256sum shasum sort stat tr wc; do
  if [ -x "/usr/bin/$_tool" ]; then
    ln -s "/usr/bin/$_tool" "$_no_python_path/$_tool"
  elif [ -x "/bin/$_tool" ]; then
    ln -s "/bin/$_tool" "$_no_python_path/$_tool"
  fi
done

if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" explain-bundles
) >"$_test_root/explain-bundles.out" 2>"$_test_root/explain-bundles.err"; then
  pass "explain-bundles runs without python3"
else
  fail "explain-bundles runs without python3"
  cat "$_test_root/explain-bundles.err" >&2
fi
if grep -F 'Installed bundle resolution' "$_test_root/explain-bundles.out" >/dev/null 2>&1 &&
  grep -F 'dep_mod' "$_test_root/explain-bundles.out" >/dev/null 2>&1 &&
  grep -F 'root_mod' "$_test_root/explain-bundles.out" >/dev/null 2>&1; then
  pass "explain-bundles reports the roots and the module closure"
else
  fail "explain-bundles reports the roots and the module closure"
  cat "$_test_root/explain-bundles.out" >&2
fi
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" explain-bundles --bundle=default
) >"$_test_root/explain-bundles-one.out" 2>&1; then
  pass "explain-bundles accepts a bundle name"
else
  fail "explain-bundles accepts a bundle name"
  cat "$_test_root/explain-bundles-one.out" >&2
fi
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" explain-bundles --bundle=no-such-bundle
) >"$_test_root/explain-bundles-bad.out" 2>&1; then
  fail "explain-bundles rejects an unknown bundle"
else
  pass "explain-bundles rejects an unknown bundle"
fi

# --- layer-lint without python3 ---

_layer="$_project/shell/layers/vendor"
mkdir -p "$_layer/module.d" "$_layer/modules/shared"
printf '%s\n' \
  'name=contrib_vendor_tool' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=' \
  'optional=' \
  'shells=sh bash zsh ksh' \
  'platforms=any' \
  'exports=contrib_vendor_tool_ready' \
  'updates=' \
  'load=modules/shared/contrib_vendor_tool.sh' \
  >"$_layer/module.d/contrib_vendor_tool.meta"
printf 'contrib_vendor_tool_ready() { :; }\n' \
  >"$_layer/modules/shared/contrib_vendor_tool.sh"

if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" layer-lint vendor
) >"$_test_root/layer-lint.out" 2>"$_test_root/layer-lint.err"; then
  pass "layer-lint accepts a valid provider layer without python3"
else
  fail "layer-lint accepts a valid provider layer without python3"
  cat "$_test_root/layer-lint.err" >&2
fi

# An unprefixed name must be rejected.
mkdir -p "$_project/shell/layers/unprefixed/module.d" "$_project/shell/layers/unprefixed/modules/shared"
printf '%s\n' \
  'name=no_prefix_module' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=' \
  'optional=' \
  'shells=sh' \
  'platforms=any' \
  'exports=' \
  'updates=' \
  'load=modules/shared/no_prefix_module.sh' \
  >"$_project/shell/layers/unprefixed/module.d/no_prefix_module.meta"
printf '# body\n' >"$_project/shell/layers/unprefixed/modules/shared/no_prefix_module.sh"
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" layer-lint unprefixed
) >"$_test_root/layer-lint-unprefixed.out" 2>&1; then
  fail "layer-lint rejects a layer module without the contrib_ prefix"
else
  pass "layer-lint rejects a layer module without the contrib_ prefix"
fi

# An unversioned module must be rejected.
mkdir -p "$_project/shell/layers/unversioned/module.d" "$_project/shell/layers/unversioned/modules/shared"
printf '%s\n' \
  'name=contrib_unversioned' \
  'version=' \
  'side_effect=read-only' \
  'requires=' \
  'optional=' \
  'shells=sh' \
  'platforms=any' \
  'exports=' \
  'updates=' \
  'load=modules/shared/contrib_unversioned.sh' \
  >"$_project/shell/layers/unversioned/module.d/contrib_unversioned.meta"
printf '# body\n' >"$_project/shell/layers/unversioned/modules/shared/contrib_unversioned.sh"
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" layer-lint unversioned
) >"$_test_root/layer-lint-unversioned.out" 2>&1; then
  fail "layer-lint rejects a layer module without a version"
else
  pass "layer-lint rejects a layer module without a version"
fi

# A broken load target must be rejected.
mkdir -p "$_project/shell/layers/broken/module.d"
printf '%s\n' \
  'name=contrib_broken' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=' \
  'optional=' \
  'shells=sh' \
  'platforms=any' \
  'exports=' \
  'updates=' \
  'load=modules/shared/contrib_broken.sh' \
  >"$_project/shell/layers/broken/module.d/contrib_broken.meta"
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" layer-lint broken
) >"$_test_root/layer-lint-broken.out" 2>&1; then
  fail "layer-lint rejects a layer module with a missing body"
else
  pass "layer-lint rejects a layer module with a missing body"
fi

# A dependency outside the layer and outside the engine must be rejected.
mkdir -p "$_project/shell/layers/outside/module.d" "$_project/shell/layers/outside/modules/shared"
printf '%s\n' \
  'name=contrib_outside' \
  'version=1.0.0' \
  'side_effect=read-only' \
  'requires=not_in_this_layer' \
  'optional=' \
  'shells=sh' \
  'platforms=any' \
  'exports=' \
  'updates=' \
  'load=modules/shared/contrib_outside.sh' \
  >"$_project/shell/layers/outside/module.d/contrib_outside.meta"
printf '# body\n' >"$_project/shell/layers/outside/modules/shared/contrib_outside.sh"
if (
  cd "$_project" &&
    PATH="$_no_python_path" HOME="$_test_root/home" \
      "$_valise" layer-lint outside
) >"$_test_root/layer-lint-outside.out" 2>&1; then
  fail "layer-lint rejects a dependency outside the layer and the engine"
else
  pass "layer-lint rejects a dependency outside the layer and the engine"
fi

# --- regressions found by the Task 8 quality review ---
#
# Each case below pins a defect that the review found and the
# orchestrator reproduced. They are written so that the old behavior
# fails the assertion, not just the current behavior passing it.

# (1) `install` writes its own marker, not the
# "# BEGIN valise managed block" pair. Doctor must recognize the marker
# install actually writes, or it reports a correctly installed system as
# having no integration.
_auto_home="$_test_root/auto-home"
mkdir -p "$_auto_home"
_auto_release="$_test_root/auto-release"
_make_release "$_auto_release" '# auto release'
(
  cd "$_auto_release" &&
    HOME="$_auto_home" \
      XDG_DATA_HOME="$_auto_home/.local/share" \
      XDG_CONFIG_HOME="$_auto_home/.config" \
      XDG_STATE_HOME="$_auto_home/.local/state" \
      SHELL=/bin/bash \
      "$_valise" install
) >"$_test_root/install-auto.out" 2>&1 || :
if (
  HOME="$_auto_home" \
    XDG_DATA_HOME="$_auto_home/.local/share" \
    XDG_CONFIG_HOME="$_auto_home/.config" \
    XDG_STATE_HOME="$_auto_home/.local/state" \
    SHELL=/bin/bash \
    "$_valise" doctor
) >"$_test_root/doctor-auto.out" 2>&1; then
  pass "doctor succeeds after install"
else
  fail "doctor succeeds after install"
  cat "$_test_root/doctor-auto.out" >&2
fi

# (2) A home directory containing whitespace must not break the startup
# file check. The candidate paths are read one per line, so a space in
# the path is not a word separator.
_space_home="$_test_root/My Home"
mkdir -p "$_space_home"
_space_release="$_test_root/space-release"
_make_release "$_space_release" '# space release'
(
  cd "$_space_release" &&
    HOME="$_space_home" \
      XDG_DATA_HOME="$_space_home/.local/share" \
      XDG_CONFIG_HOME="$_space_home/.config" \
      XDG_STATE_HOME="$_space_home/.local/state" \
      "$_valise" install
) >"$_test_root/install-space.out" 2>&1 || :
if (
  HOME="$_space_home" \
    XDG_DATA_HOME="$_space_home/.local/share" \
    XDG_CONFIG_HOME="$_space_home/.config" \
    XDG_STATE_HOME="$_space_home/.local/state" \
    "$_valise" doctor
) >"$_test_root/doctor-space.out" 2>&1; then
  pass "doctor succeeds with whitespace in HOME"
else
  fail "doctor succeeds with whitespace in HOME"
  cat "$_test_root/doctor-space.out" >&2
fi

# (3) A Fish user's deployed conf.d hook must be checked. install writes
# the hook; doctor must look for it when $SHELL names fish.
_fish_home="$_test_root/fish-home"
mkdir -p "$_fish_home"
_fish_release="$_test_root/fish-release"
_make_release "$_fish_release" '# fish release'
(
  cd "$_fish_release" &&
    HOME="$_fish_home" \
      XDG_DATA_HOME="$_fish_home/.local/share" \
      XDG_CONFIG_HOME="$_fish_home/.config" \
      XDG_STATE_HOME="$_fish_home/.local/state" \
      SHELL=/usr/local/bin/fish \
      "$_valise" install
) >"$_test_root/install-fish.out" 2>&1 || :
if (
  HOME="$_fish_home" \
    XDG_DATA_HOME="$_fish_home/.local/share" \
    XDG_CONFIG_HOME="$_fish_home/.config" \
    XDG_STATE_HOME="$_fish_home/.local/state" \
    SHELL=/usr/local/bin/fish \
    "$_valise" doctor
) >"$_test_root/doctor-fish.out" 2>&1; then
  pass "doctor checks the fish integration hook"
else
  fail "doctor checks the fish integration hook"
  cat "$_test_root/doctor-fish.out" >&2
fi

# (4) `layer-lint` with no argument must print its usage and fail on
# every shell. A failing shift is a special-builtin error, so the guard
# has to check the argument count before shifting.
for _ll_shell in sh bash dash ksh; do
  command -v "$_ll_shell" >/dev/null 2>&1 || continue
  _ll_out=$("$_ll_shell" "$_valise" layer-lint 2>&1) && _ll_rc=0 || _ll_rc=$?
  if [ "$_ll_rc" -eq 1 ] && printf '%s' "$_ll_out" | grep -F 'usage: valise layer-lint' >/dev/null 2>&1; then
    pass "layer-lint with no argument fails with usage under $_ll_shell"
  else
    fail "layer-lint with no argument fails with usage under $_ll_shell (rc=$_ll_rc)"
    printf '%s\n' "$_ll_out" >&2
  fi
done

# (5) layer-lint must accept a valid layer whose dependency sorts LAST.
# The name lists are matched with " $name ", so they need a trailing
# space or the final entry never matches.
mkdir -p "$_test_root/order-project/shell/module.d" \
  "$_test_root/order-project/shell/modules" \
  "$_test_root/order-project/shell/layers/ordered/module.d" \
  "$_test_root/order-project/shell/layers/ordered/modules/shared"
printf '%s\n' \
  'name=platform_posix' 'version=1.0.0' 'side_effect=read-only' 'requires=' \
  'optional=' 'shells=sh' 'platforms=any' 'exports=' 'updates=' \
  'load=modules/platform_posix.sh' \
  >"$_test_root/order-project/shell/module.d/platform_posix.meta"
printf '# body\n' >"$_test_root/order-project/shell/modules/platform_posix.sh"
for _ord_name in contrib_aaa contrib_zzz; do
  printf '%s\n' \
    "name=$_ord_name" 'version=1.0.0' 'side_effect=read-only' 'requires=' \
    'optional=' 'shells=sh' 'platforms=any' 'exports=' 'updates=' \
    "load=modules/shared/$_ord_name.sh" \
    >"$_test_root/order-project/shell/layers/ordered/module.d/$_ord_name.meta"
  printf '# body\n' \
    >"$_test_root/order-project/shell/layers/ordered/modules/shared/$_ord_name.sh"
done
# contrib_aaa depends on contrib_zzz, which sorts last.
printf '%s\n' \
  'name=contrib_aaa' 'version=1.0.0' 'side_effect=read-only' \
  'requires=contrib_zzz' 'optional=' 'shells=sh' 'platforms=any' 'exports=' \
  'updates=' 'load=modules/shared/contrib_aaa.sh' \
  >"$_test_root/order-project/shell/layers/ordered/module.d/contrib_aaa.meta"
if (
  cd "$_test_root/order-project" && "$_valise" layer-lint ordered
) >"$_test_root/layer-lint-order.out" 2>&1; then
  pass "layer-lint accepts a dependency that sorts last"
else
  fail "layer-lint accepts a dependency that sorts last"
  cat "$_test_root/layer-lint-order.out" >&2
fi

# (6) `variant prune --keep=N` must reject a value beyond the shell's
# integer range instead of reading it as "keep nothing".
_prune_home="$_test_root/prune-range-home"
mkdir -p "$_prune_home"
_prune_env() {
  HOME="$_prune_home"
  XDG_DATA_HOME="$_prune_home/.local/share"
  XDG_CONFIG_HOME="$_prune_home/.config"
  XDG_STATE_HOME="$_prune_home/.local/state"
  export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
}
_prune_env
_prune_release="$_test_root/prune-range-release"
_make_release "$_prune_release" '# prune range release'
if (cd "$_prune_release" && "$_valise" install --no-integration) >"$_test_root/prune-range-install.out" 2>&1; then
  if "$_valise" variant prune --keep=99999999999999999999 >"$_test_root/prune-range.out" 2>&1; then
    fail "prune rejects a --keep value beyond the integer range"
  else
    pass "prune rejects a --keep value beyond the integer range"
  fi
  if grep -F 'too large' "$_test_root/prune-range.out" >/dev/null 2>&1; then
    pass "prune says why the --keep value was rejected"
  else
    fail "prune says why the --keep value was rejected"
    cat "$_test_root/prune-range.out" >&2
  fi
  _prune_active=$(readlink "$XDG_CONFIG_HOME/valise/active" 2>/dev/null || :)
  if [ -n "$_prune_active" ] && [ -d "$_prune_active" ]; then
    pass "the rejected prune left the active release in place"
  else
    fail "the rejected prune left the active release in place"
  fi
else
  fail "prune rejects a --keep value beyond the integer range (install failed)"
  skip "prune says why the --keep value was rejected (install failed)"
  skip "the rejected prune left the active release in place (install failed)"
fi

# (7) A relative XDG_DATA_HOME must still produce a working active
# pointer. A relative symlink target resolves against the directory
# holding the link, not the caller's working directory, so the pointer
# would dangle and prune would delete the release it points at.
_rel_home="$_test_root/relative-home"
_rel_work="$_test_root/relative-work"
_rel_release="$_test_root/relative-release"
mkdir -p "$_rel_home" "$_rel_work"
_make_release "$_rel_release" '# relative release'
# A relative XDG root resolves against the working directory, and install
# finds the manifest from the working directory too, so both must be run
# from the same place for the pointer to name the release directory.
(
  cd "$_rel_work" &&
    cp -R "$_rel_release" ./release &&
    cd ./release &&
    HOME="$_rel_home" \
      XDG_DATA_HOME=../reldata \
      XDG_CONFIG_HOME=../relconf \
      XDG_STATE_HOME=../relstate \
      "$_valise" install --no-integration
) >"$_test_root/relative-install.out" 2>&1 || :
_rel_target=$(readlink "$_rel_work/relconf/valise/active" 2>/dev/null || :)
case "$_rel_target" in
/*) _rel_absolute=1 ;;
*) _rel_absolute=0 ;;
esac
if [ "$_rel_absolute" -eq 1 ] && [ -d "$_rel_target" ]; then
  pass "a relative XDG_DATA_HOME produces an absolute active pointer"
else
  fail "a relative XDG_DATA_HOME produces an absolute active pointer (target=$_rel_target)"
  cat "$_test_root/relative-install.out" >&2
fi
if (
  cd "$_rel_work/release" &&
    HOME="$_rel_home" \
      XDG_DATA_HOME=../reldata \
      XDG_CONFIG_HOME=../relconf \
      XDG_STATE_HOME=../relstate \
      "$_valise" variant prune --keep=0
) >"$_test_root/relative-prune.out" 2>&1; then
  _rel_after=$(readlink "$_rel_work/relconf/valise/active" 2>/dev/null || :)
  if [ -n "$_rel_after" ] && [ -d "$_rel_after" ]; then
    pass "prune keeps the active release under a relative XDG_DATA_HOME"
  else
    fail "prune keeps the active release under a relative XDG_DATA_HOME"
    cat "$_test_root/relative-prune.out" >&2
  fi
else
  fail "prune keeps the active release under a relative XDG_DATA_HOME"
  cat "$_test_root/relative-prune.out" >&2
fi

# (8) explain-bundles must not leave a registry scratch file behind when
# it fails.
_leak_home="$_test_root/leak-home"
_leak_project="$_test_root/leak-project"
_leak_tmp="$_test_root/leak-tmp"
mkdir -p "$_leak_home" "$_leak_project/shell/module.d" "$_leak_project/shell/modules" \
  "$_leak_project/shell/release" "$_leak_tmp"
printf '%s\n' \
  'name=leak_module' 'version=1.0.0' 'side_effect=read-only' 'requires=' \
  'optional=' 'shells=sh' 'platforms=any' 'exports=' 'updates=' \
  'load=modules/leak_module.sh' \
  >"$_leak_project/shell/module.d/leak_module.meta"
printf '# body\n' >"$_leak_project/shell/modules/leak_module.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tleak_module\n' \
  >"$_leak_project/shell/release/bundle-roots"
if (
  cd "$_leak_project" &&
    TMPDIR="$_leak_tmp" HOME="$_leak_home" \
      "$_valise" explain-bundles --bundle=no-such-bundle
) >"$_test_root/leak.out" 2>&1; then
  fail "explain-bundles rejects an unknown bundle"
else
  pass "explain-bundles rejects an unknown bundle"
fi
_leak_left=$(find "$_leak_tmp" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$_leak_left" -eq 0 ]; then
  pass "a failed explain-bundles leaves no scratch file behind"
else
  fail "a failed explain-bundles leaves no scratch file behind"
  find "$_leak_tmp" -type f >&2 2>/dev/null || :
fi

# --- command-specific --help ---

for _help_cmd in compile assemble install init new module variant doctor status \
  verify-active registry build apply make-manifest explain-variant explain-bundles layer-lint; do
  if "$_valise" "$_help_cmd" --help >"$_test_root/help-$_help_cmd.out" 2>&1; then
    pass "$_help_cmd --help succeeds"
  else
    fail "$_help_cmd --help succeeds"
    cat "$_test_root/help-$_help_cmd.out" >&2
  fi
  if grep -F "usage: valise $_help_cmd" "$_test_root/help-$_help_cmd.out" >/dev/null 2>&1; then
    pass "$_help_cmd --help prints its own usage"
  else
    fail "$_help_cmd --help prints its own usage"
    cat "$_test_root/help-$_help_cmd.out" >&2
  fi
  if grep -F 'Usage: valise <command> [options]' "$_test_root/help-$_help_cmd.out" >/dev/null 2>&1; then
    fail "$_help_cmd --help does not print the global usage"
  else
    pass "$_help_cmd --help does not print the global usage"
  fi
done

printf '\n=== valise CLI gaps summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
