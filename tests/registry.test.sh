#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Registry contract: metadata is the source of truth, the registry is an
# internal table generated on demand, and a build never writes generated
# files into the project.

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
_test_home=$(cd "$_test_home" && pwd -P)
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
mkdir -p "$_project/module.d" "$_project/modules" \
  "$_project/layers/vendor/module.d" "$_project/layers/vendor/modules"
: >"$_project/valise.conf"

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
load=$_meta_load
EOF
  unset _meta_path _meta_name _meta_requires _meta_exports _meta_load
}

_meta "$_project/module.d/root.meta" root contrib_vendor_tool root_ready modules/root.sh
printf '%s\n' 'root_ready() { :; }' >"$_project/modules/root.sh"
_meta "$_project/layers/vendor/module.d/contrib_vendor_tool.meta" \
  contrib_vendor_tool '' vendor_tool_ready modules/contrib_vendor_tool.sh
printf '%s\n' 'vendor_tool_ready() { :; }' \
  >"$_project/layers/vendor/modules/contrib_vendor_tool.sh"

printf 'variant\tdescription\texcluded\ndefault\tAll\t\n' >"$_project/variants.tsv"
printf 'bundle\tshell\troots\ndefault\tbash\troot\n' >"$_project/bundles.tsv"

printf '=== valise registry contract ===\n'
printf '  project: %s\n\n' "$_project"

_registry="$_test_home/registry.out"
if (cd "$_project" && "$_valise" registry) >"$_registry" 2>"$_test_home/registry.err"; then
  pass "registry prints the table generated from metadata"
else
  fail "registry prints the table generated from metadata"
  cat "$_test_home/registry.err" >&2
fi

# Project rows come first in module.d then layer order; the engine's own
# modules follow under the source "valise", one row per engine metadata file.
{
  printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tcommands\texecutables\ttests\tsource\n'
  printf 'root\t\tread-only\tcontrib_vendor_tool\t\tbash\tany\troot_ready\tmodules/root.sh\t\t\t\tmodule.d\n'
  printf 'contrib_vendor_tool\t\tread-only\t\t\tbash\tany\tvendor_tool_ready\tmodules/contrib_vendor_tool.sh\t\t\t\tlayers/vendor/module.d\n'
} >"$_test_home/expected-head.tsv"
if head -n 3 "$_registry" | cmp -s - "$_test_home/expected-head.tsv"; then
  pass "registry has the 0.3 columns and the project rows in source order"
else
  fail "registry has the 0.3 columns and the project rows in source order"
  head -n 3 "$_registry" | diff "$_test_home/expected-head.tsv" - >&2 || :
fi
_engine_meta_count=0
for _engine_meta in "$_repo"/module.d/*.meta; do
  [ -f "$_engine_meta" ] && _engine_meta_count=$((_engine_meta_count + 1))
done
_engine_rows=$(awk -F '\t' 'NR > 3 && $13 == "valise" && $1 ~ /^valise_/' "$_registry" | wc -l | tr -d ' ')
_total_rows=$(awk 'END { print NR }' "$_registry")
if [ "$_engine_meta_count" -gt 0 ] && [ "$_engine_rows" -eq "$_engine_meta_count" ] &&
  [ "$_total_rows" -eq $((3 + _engine_meta_count)) ]; then
  pass "every engine module is available to the project under the valise source"
else
  fail "every engine module is available to the project under the valise source ($_engine_rows of $_engine_meta_count)"
fi

# A path argument writes the same bytes to a file and nothing to the project.
if (cd "$_project" && "$_valise" registry "$_test_home/registry.file") >/dev/null 2>&1 &&
  cmp -s "$_registry" "$_test_home/registry.file"; then
  pass "registry <path> writes the same table to a file"
else
  fail "registry <path> writes the same table to a file"
fi
if (cd "$_project" && "$_valise" registry "$_test_home/missing-parent/registry.tsv") >/dev/null 2>&1; then
  fail "registry <path> rejects a missing parent directory"
elif [ ! -e "$_test_home/missing-parent" ]; then
  pass "registry <path> rejects a missing parent directory without creating it"
else
  fail "registry <path> rejects a missing parent directory without creating it"
fi

# -C selects the project from anywhere; a subdirectory finds its project.
if "$_valise" -C "$_project" registry 2>/dev/null | cmp -s - "$_registry" &&
  (cd "$_project/layers/vendor" && "$_valise" registry) 2>/dev/null | cmp -s - "$_registry"; then
  pass "registry finds the project through -C and from a subdirectory"
else
  fail "registry finds the project through -C and from a subdirectory"
fi

# Outside a project the command fails with a direction, not a guess.
mkdir -p "$_test_home/not-a-project"
if (cd "$_test_home/not-a-project" && "$_valise" registry) >/dev/null 2>"$_test_home/noproj.err"; then
  fail "registry outside a project fails"
elif grep -F 'not inside a valise project' "$_test_home/noproj.err" >/dev/null; then
  pass "registry outside a project fails and names valise.conf"
else
  fail "registry outside a project fails and names valise.conf"
  cat "$_test_home/noproj.err" >&2
fi

# Generation is deterministic and independent of the caller's locale.
if (cd "$_project" && LC_ALL=en_US.UTF-8 "$_valise" registry) 2>/dev/null | cmp -s - "$_registry" &&
  (cd "$_project" && LC_ALL=C "$_valise" registry) 2>/dev/null | cmp -s - "$_registry"; then
  pass "registry output is byte-identical across runs and locales"
else
  fail "registry output is byte-identical across runs and locales"
fi

# Adding a module shows up at the end of the module.d rows.
_meta "$_project/module.d/zeta.meta" zeta '' zeta_ready modules/zeta.sh
printf '%s\n' 'zeta_ready() { :; }' >"$_project/modules/zeta.sh"
if (cd "$_project" && "$_valise" registry) 2>/dev/null | awk -F '\t' 'NR == 3 { exit !($1 == "zeta" && $13 == "module.d") }'; then
  pass "a new module appears in the registry without any regeneration step"
else
  fail "a new module appears in the registry without any regeneration step"
fi
rm -f "$_project/module.d/zeta.meta" "$_project/modules/zeta.sh"

# expect_rejected <label> <message>
# Run registry and require failure with the message on stderr.
expect_rejected() {
  if (cd "$_project" && "$_valise" registry) >/dev/null 2>"$_test_home/reject.err"; then
    fail "$1"
  elif grep -F -- "$2" "$_test_home/reject.err" >/dev/null; then
    pass "$1"
  else
    fail "$1"
    cat "$_test_home/reject.err" >&2
  fi
}

_meta "$_project/module.d/mismatch.meta" other '' '' modules/root.sh
expect_rejected "registry rejects a metadata name that does not match the file name" \
  'module.d/mismatch.meta: metadata name other does not match file name mismatch'
rm -f "$_project/module.d/mismatch.meta"

_meta "$_project/module.d/valise_mine.meta" valise_mine '' '' modules/root.sh
expect_rejected "registry reserves the valise_ prefix for engine modules" \
  'the valise_ prefix is reserved for engine modules: valise_mine'
rm -f "$_project/module.d/valise_mine.meta"

_meta "$_project/layers/vendor/module.d/bad_layer.meta" bad_layer '' '' modules/contrib_vendor_tool.sh
expect_rejected "registry rejects a layer module without the contrib_ prefix" \
  'layers/vendor/module.d/bad_layer.meta: layer module name bad_layer must use the contrib_ prefix'
rm -f "$_project/layers/vendor/module.d/bad_layer.meta"

_meta "$_project/module.d/no_body.meta" no_body '' '' modules/no_body.sh
expect_rejected "registry rejects a missing module body" \
  'module.d/no_body.meta: file does not exist: modules/no_body.sh'
rm -f "$_project/module.d/no_body.meta"

printf 'linked_ready() { :; }\n' >"$_test_home/outside-body.sh"
ln -s "$_test_home/outside-body.sh" "$_project/modules/linked.sh"
_meta "$_project/module.d/linked.meta" linked '' linked_ready modules/linked.sh
expect_rejected "registry rejects a module body reached through a symlink" \
  'module.d/linked.meta: path contains a symlink: modules/linked.sh'
rm -f "$_project/module.d/linked.meta" "$_project/modules/linked.sh"

# A layer directory name ends up in plan source text, so it must be plain.
_bad_layer="$_project/layers/l)"
mkdir -p "$_bad_layer/module.d" "$_bad_layer/modules"
_meta "$_bad_layer/module.d/contrib_bad_layer.meta" contrib_bad_layer '' \
  contrib_bad_layer_ready modules/contrib_bad_layer.sh
printf 'contrib_bad_layer_ready() { :; }\n' >"$_bad_layer/modules/contrib_bad_layer.sh"
expect_rejected "registry rejects an unsafe layer directory name" 'invalid layer directory name'
rm -rf "$_bad_layer"

_meta "$_project/module.d/reserved_export.meta" reserved_export '' if modules/root.sh
expect_rejected "registry rejects a reserved-word export" 'invalid export (reserved word): if'
rm -f "$_project/module.d/reserved_export.meta"

cat >"$_project/module.d/load_hook_mod.meta" <<'EOF'
name=load_hook_mod
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
load_hook=_shell_module_load_hook_mod
EOF
expect_rejected "registry rejects a load_hook module" 'metadata field load_hook is not supported; use load'
rm -f "$_project/module.d/load_hook_mod.meta"

# A build leaves the project tree exactly as it was, apart from build/.
_snapshot() {
  (cd "$_project" && find . -path ./build -prune -o -print | LC_ALL=C sort)
}
_snapshot >"$_test_home/tree.before"
if (cd "$_project" && "$_valise" build) >"$_test_home/build1.out" 2>"$_test_home/build1.err"; then
  pass "build succeeds without a committed registry"
else
  fail "build succeeds without a committed registry"
  cat "$_test_home/build1.err" >&2
fi
_snapshot >"$_test_home/tree.after"
if cmp -s "$_test_home/tree.before" "$_test_home/tree.after"; then
  pass "build writes no generated file into the project"
else
  fail "build writes no generated file into the project"
  diff "$_test_home/tree.before" "$_test_home/tree.after" >&2 || :
fi
if [ -f "$_project/build/release/manifest.tsv" ] &&
  ! find "$_project/build/release" -name '*registry*' | grep . >/dev/null; then
  pass "the release carries a manifest and no registry"
else
  fail "the release carries a manifest and no registry"
fi
if (cd "$_project" && "$_valise" build "$_test_home/release2") >/dev/null 2>&1 &&
  cmp -s "$_project/build/release/manifest.tsv" "$_test_home/release2/manifest.tsv"; then
  pass "repeated build produces a byte-identical manifest"
else
  fail "repeated build produces a byte-identical manifest"
fi

# An explicit output that is not empty is refused before anything is written.
mkdir -p "$_test_home/occupied"
printf 'keep\n' >"$_test_home/occupied/keep.txt"
if (cd "$_project" && "$_valise" build "$_test_home/occupied") >/dev/null 2>"$_test_home/occupied.err"; then
  fail "build rejects a non-empty explicit output directory"
elif grep -F 'output directory must be empty' "$_test_home/occupied.err" >/dev/null &&
  [ "$(ls -A "$_test_home/occupied")" = keep.txt ] &&
  ! ls -A "$_test_home" | grep -F '.valise-build.' >/dev/null; then
  pass "build rejects a non-empty explicit output directory without writing"
else
  fail "build rejects a non-empty explicit output directory without writing"
  cat "$_test_home/occupied.err" >&2
fi

printf '\n=== valise registry summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
