#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Registry generation contract: metadata is the source of truth, the TSV is a
# deterministic generated artifact, and assemble keeps it current.

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
_test_home=$(mktemp -d "${TMPDIR:-/tmp}/valise-registry.XXXXXX")
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

_project="$_test_home/project"
mkdir -p "$_project/shell/module.d" "$_project/shell/modules" \
  "$_project/shell/layers/vendor/module.d" "$_project/shell/layers/vendor/modules" \
  "$_project/shell/release"

_meta() {
  _meta_path=$1
  _meta_name=$2
  _meta_requires=$3
  _meta_exports=$4
  _meta_load=$5
  cat >"$_meta_path" <<EOF
name=$_meta_name
version=
side_effect=read-only
requires=$_meta_requires
optional=
shells=bash
platforms=any
exports=$_meta_exports
updates=
load=$_meta_load
EOF
  unset _meta_path _meta_name _meta_requires _meta_exports _meta_load
}

_meta "$_project/shell/module.d/root.meta" root contrib_vendor_tool root_ready modules/root.sh
printf '%s\n' 'root_ready() { :; }' >"$_project/shell/modules/root.sh"
_meta "$_project/shell/layers/vendor/module.d/contrib_vendor_tool.meta" \
  contrib_vendor_tool '' vendor_tool_ready modules/contrib_vendor_tool.sh
printf '%s\n' 'vendor_tool_ready() { :; }' \
  >"$_project/shell/layers/vendor/modules/contrib_vendor_tool.sh"

printf 'variant_name\tdescription\texcluded_modules\nworkstation-full\tAll\t\n' \
  >"$_project/shell/release/install-variants"
printf '# bundle\tshell\troots\ndefault\tbash\troot\n' \
  >"$_project/shell/release/bundle-roots"

printf '=== valise registry contract ===\n'
printf '  project: %s\n\n' "$_project"

# A project with metadata and bodies but no registry generates one.
if (cd "$_project" && "$_valise" registry) >"$_test_home/registry.out" 2>"$_test_home/registry.err"; then
  pass "registry generates from metadata without a committed TSV"
else
  fail "registry generates from metadata without a committed TSV"
  cat "$_test_home/registry.err" >&2
fi
_registry="$_project/shell/release/module-registry.tsv"
_expected_registry="$_test_home/expected-registry.tsv"
{
  printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'
  printf 'root\t\tread-only\tcontrib_vendor_tool\t\tbash\tany\troot_ready\tmodules/root.sh\t\tshell/module.d\n'
  printf 'contrib_vendor_tool\t\tread-only\t\t\tbash\tany\tvendor_tool_ready\tmodules/contrib_vendor_tool.sh\t\tshell/layers/vendor/module.d\n'
} >"$_expected_registry"
if cmp -s "$_registry" "$_expected_registry"; then
  pass "generated registry has the deterministic ABI row order and columns"
else
  fail "generated registry has the deterministic ABI row order and columns"
  diff "$_expected_registry" "$_registry" >&2 || :
fi

# Check mode compares without rewriting the committed artifact.
cp "$_registry" "$_test_home/registry.before-check"
if (cd "$_project" && "$_valise" registry --check) \
  >"$_test_home/check.out" 2>"$_test_home/check.err" &&
  cmp -s "$_registry" "$_test_home/registry.before-check"; then
  pass "registry --check verifies the committed registry without rewriting it"
else
  fail "registry --check verifies the committed registry without rewriting it"
  cat "$_test_home/check.err" >&2
fi

# Check mode must fail on drift and leave the committed artifact untouched.
cp "$_registry" "$_test_home/registry.valid-before-drift"
printf 'bogus\t\tread-only\t\t\tbash\tany\t\tmodules/root.sh\t\tshell/module.d\n' \
  >>"$_registry"
cp "$_registry" "$_test_home/registry.drifted"
if (cd "$_project" && "$_valise" registry --check) \
  >"$_test_home/check-drift.out" 2>"$_test_home/check-drift.err"; then
  fail "registry --check rejects a stale committed registry"
else
  if grep -F 'module registry is out of date' "$_test_home/check-drift.err" >/dev/null &&
    cmp -s "$_registry" "$_test_home/registry.drifted"; then
    pass "registry --check rejects a stale committed registry without rewriting it"
  else
    fail "registry --check rejects a stale committed registry without rewriting it"
    cat "$_test_home/check-drift.err" >&2
  fi
fi
cp "$_test_home/registry.valid-before-drift" "$_registry"

# Assemble must not invent a project from an unrelated working directory.
_assemble_elsewhere="$_test_home/elsewhere"
mkdir -p "$_assemble_elsewhere"
if (cd "$_assemble_elsewhere" && "$_valise" assemble "$_test_home/no-project-release") \
  >"$_test_home/elsewhere.out" 2>"$_test_home/elsewhere.err"; then
  fail "assemble rejects a directory without shell/module.d"
else
  if grep -F 'run from the consuming project root (need shell/module.d)' \
    "$_test_home/elsewhere.err" >/dev/null &&
    [ ! -e "$_assemble_elsewhere/shell" ] &&
    [ ! -e "$_test_home/no-project-release" ]; then
    pass "assemble rejects a directory without shell/module.d without writing"
  else
    fail "assemble rejects a directory without shell/module.d without writing"
    cat "$_test_home/elsewhere.err" >&2
  fi
fi

# An invalid output target must be rejected before the source registry changes.
_invalid_out="$_test_home/occupied-out"
mkdir -p "$_invalid_out/sentinel"
cp "$_registry" "$_test_home/registry.before-invalid-out"
if (cd "$_project" && "$_valise" assemble --bundle=default "$_invalid_out") \
  >"$_test_home/invalid-out.out" 2>"$_test_home/invalid-out.err"; then
  fail "assemble rejects a non-empty output directory before regenerating the registry"
else
  if grep -F 'output directory must be empty' "$_test_home/invalid-out.err" >/dev/null &&
    cmp -s "$_registry" "$_test_home/registry.before-invalid-out"; then
    pass "assemble rejects a non-empty output directory before regenerating the registry"
  else
    fail "assemble rejects a non-empty output directory before regenerating the registry"
    cat "$_test_home/invalid-out.err" >&2
  fi
fi

# Check mode must not create a missing registry parent.
_check_missing_parent="$_test_home/check-missing-parent"
if (cd "$_project" && "$_valise" registry --check "$_check_missing_parent/registry.tsv") \
  >"$_test_home/check-missing.out" 2>"$_test_home/check-missing.err"; then
  fail "registry --check rejects a missing parent without creating it"
else
  if grep -F 'module registry is missing' "$_test_home/check-missing.err" >/dev/null &&
    [ ! -e "$_check_missing_parent" ]; then
    pass "registry --check rejects a missing parent without creating it"
  else
    fail "registry --check rejects a missing parent without creating it"
    cat "$_test_home/check-missing.err" >&2
  fi
fi

# Adding a module and regenerating updates the registry.
_meta "$_project/shell/module.d/second.meta" second root second_ready modules/second.sh
printf '%s\n' 'second_ready() { :; }' >"$_project/shell/modules/second.sh"
if (cd "$_project" && "$_valise" registry) >"$_test_home/update.out" 2>"$_test_home/update.err" &&
  grep -F 'second		read-only	root		bash	any	second_ready	modules/second.sh		shell/module.d' \
    "$_registry" >/dev/null; then
  pass "adding a module and regenerating updates the registry"
else
  fail "adding a module and regenerating updates the registry"
  cat "$_test_home/update.err" >&2
fi

# Repeated generation is byte-identical.
cp "$_registry" "$_test_home/registry.first"
if (cd "$_project" && "$_valise" registry) >"$_test_home/repeat.out" 2>"$_test_home/repeat.err" &&
  cmp -s "$_registry" "$_test_home/registry.first"; then
  pass "repeated registry generation is byte-identical"
else
  fail "repeated registry generation is byte-identical"
  cat "$_test_home/repeat.err" >&2
fi

# Registry order must not depend on the caller's locale.
_meta "$_project/shell/module.d/myX.meta" myX '' myX_loaded modules/myX.sh
printf '%s\n' 'myX_loaded() { :; }' >"$_project/shell/modules/myX.sh"
_meta "$_project/shell/module.d/my_X.meta" my_X '' my_X_loaded modules/my_X.sh
printf '%s\n' 'my_X_loaded() { :; }' >"$_project/shell/modules/my_X.sh"
if (cd "$_project" && LC_ALL=C "$_valise" registry) \
  >"$_test_home/locale-c.out" 2>"$_test_home/locale-c.err"; then
  cp "$_registry" "$_test_home/registry.locale-c"
  if (cd "$_project" && LC_ALL=en_US.UTF-8 "$_valise" registry) \
    >"$_test_home/locale-utf.out" 2>"$_test_home/locale-utf.err" &&
    cmp -s "$_registry" "$_test_home/registry.locale-c"; then
    pass "registry order is independent of the caller locale"
  else
    fail "registry order is independent of the caller locale"
    cat "$_test_home/locale-utf.err" >&2
  fi
else
  fail "registry order is independent of the caller locale"
  cat "$_test_home/locale-c.err" >&2
fi

# A mismatched metadata name fails with the file and both names.
cat >"$_project/shell/module.d/mismatch.meta" <<'EOF'
name=wrong_name
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
updates=
load=modules/root.sh
EOF
if (cd "$_project" && "$_valise" registry) \
  >"$_test_home/mismatch.out" 2>"$_test_home/mismatch.err"; then
  fail "registry rejects a metadata name that does not match the file name"
else
  if grep -F 'shell/module.d/mismatch.meta: metadata name wrong_name does not match file name mismatch' \
    "$_test_home/mismatch.err" >/dev/null; then
    pass "registry rejects a metadata name that does not match the file name"
  else
    fail "registry rejects a metadata name that does not match the file name"
    cat "$_test_home/mismatch.err" >&2
  fi
fi
rm -f "$_project/shell/module.d/mismatch.meta"

# A missing body fails with the module and load path.
cat >"$_project/shell/module.d/missing_body.meta" <<'EOF'
name=missing_body
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
updates=
load=modules/does-not-exist.sh
EOF
if (cd "$_project" && "$_valise" registry) \
  >"$_test_home/missing.out" 2>"$_test_home/missing.err"; then
  fail "registry rejects a missing module body"
else
  if grep -F 'shell/module.d/missing_body.meta: load path does not exist: modules/does-not-exist.sh' \
    "$_test_home/missing.err" >/dev/null; then
    pass "registry rejects a missing module body"
  else
    fail "registry rejects a missing module body"
    cat "$_test_home/missing.err" >&2
  fi
fi
rm -f "$_project/shell/module.d/missing_body.meta"

# A layer module without the contrib_ prefix fails.
cat >"$_project/shell/layers/vendor/module.d/bad_layer.meta" <<'EOF'
name=bad_layer
version=1.0.0
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
updates=
load=modules/contrib_vendor_tool.sh
EOF
if (cd "$_project" && "$_valise" registry) \
  >"$_test_home/layer.out" 2>"$_test_home/layer.err"; then
  fail "registry rejects a layer module without the contrib_ prefix"
else
  if grep -F 'shell/layers/vendor/module.d/bad_layer.meta: layer module name bad_layer must use the contrib_ prefix' \
    "$_test_home/layer.err" >/dev/null; then
    pass "registry rejects a layer module without the contrib_ prefix"
  else
    fail "registry rejects a layer module without the contrib_ prefix"
    cat "$_test_home/layer.err" >&2
  fi
fi
rm -f "$_project/shell/layers/vendor/module.d/bad_layer.meta"

# Restore the valid registry and prove assemble regenerates it by default.
(cd "$_project" && "$_valise" registry) >/dev/null 2>&1
cp "$_registry" "$_test_home/registry.assemble-baseline"
rm -f "$_registry"
rm -rf "$_test_home/release1" "$_test_home/release2"
if (cd "$_project" && "$_valise" assemble --bundle=default "$_test_home/release1") \
  >"$_test_home/assemble1.out" 2>"$_test_home/assemble1.err" &&
  cmp -s "$_registry" "$_test_home/registry.assemble-baseline"; then
  pass "assemble regenerates a missing registry from metadata"
else
  fail "assemble regenerates a missing registry from metadata"
  cat "$_test_home/assemble1.err" >&2
fi
if (cd "$_project" && "$_valise" assemble --bundle=default "$_test_home/release2") \
  >"$_test_home/assemble2.out" 2>"$_test_home/assemble2.err" &&
  cmp -s "$_test_home/release1/shell/install/profile-release.manifest" \
    "$_test_home/release2/shell/install/profile-release.manifest"; then
  pass "repeated assemble produces a byte-identical manifest"
else
  fail "repeated assemble produces a byte-identical manifest"
  cat "$_test_home/assemble2.err" >&2
fi
if cmp -s "$_test_home/release1/shell/release/module-registry.tsv" "$_registry"; then
  pass "assembled release carries the generated registry"
else
  fail "assembled release carries the generated registry"
fi

printf '\n=== valise registry summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
