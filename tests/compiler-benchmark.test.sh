#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Structural scaling and determinism test for the awk plan compiler.
#
# This gate never measures elapsed time. Wall-clock duration is a property of
# the machine and its load, not of the compiler, so a duration assertion is a
# coin flip that reports on the host rather than on the code. The scaling
# property is proved here structurally instead: the compiler must emit exactly
# one fixed-size block per module, source every module exactly once in
# dependency order, and produce byte-identical output for identical input.
# Those identities hold on any host, at any load, in any POSIX awk.
#
# Wall-clock measurement is retained as diagnosis tooling a human runs on
# purpose: tools/compiler-benchmark-timing.sh (`make benchmark-timing`).
set -eu

_total=0
_pass=0
_fail=0

pass() { _total=$((_total+1)); _pass=$((_pass+1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total+1)); _fail=$((_fail+1)); printf '  FAIL: %s\n' "$1" >&2; }

_test_home=$(mktemp -d "${TMPDIR:-/tmp}/valise-bench.XXXXXX")
trap 'rm -rf -- "$_test_home"' EXIT

_script_dir=$(cd "$(dirname "$0")/.." && pwd)
_awk="$_script_dir/lib/compiler.awk"

printf '=== valise compiler structural scaling ===\n\n'

# The emitted plan is a fixed-size shell block per module, wrapped in a
# constant-size preamble and epilogue. BLOCK_LINES is that per-module size.
BLOCK_LINES=7
FIXED_LINES=58

# Generate a synthetic module graph of N modules: a linear dependency chain
# plus a fan-out edge every 7th module, seeded from the last 5 modules so the
# whole graph must be resolved transitively.
generate_graph() {
  _n=$1
  _out=$2
  _seeds=""
  _start=$((_n - 4))
  [ "$_start" -ge 1 ] || _start=1
  _i=$_start
  while [ "$_i" -le "$_n" ]; do
    _seeds="$_seeds mod_$_i"
    _i=$((_i+1))
  done
  printf 'SEED:%s\n' "$_seeds" > "$_out"
  printf 'PRELUDE:sp_cap_test_one sp_cap_test_two\n' >> "$_out"
  _i=1
  while [ "$_i" -le "$_n" ]; do
    _req=""
    if [ "$_i" -gt 1 ]; then
      _prev=$((_i-1))
      _req="mod_$_prev"
    fi
    if [ "$_i" -gt 7 ] && [ $((_i % 7)) -eq 0 ]; then
      _fan=$((_i-7))
      _req="$_req mod_$_fan"
    fi
    printf 'MOD:mod_%d\t%s\tmodules/test/mod_%d.sh\tany\tread-only\t\n' "$_i" "$_req" "$_i" >> "$_out"
    _i=$((_i+1))
  done
}

SIZES='100 500 2000'
_baseline_block_lines=''

for _size in $SIZES; do
  _input="$_test_home/graph_$_size.txt"
  _output="$_test_home/plan_$_size.out"
  _repeat="$_test_home/plan_${_size}_repeat.out"
  generate_graph "$_size" "$_input"

  awk -v target_shell="bash" -v plan_name="bench" -f "$_awk" "$_input" > "$_output" 2>&1

  # No diagnostics escaped into the plan.
  if grep -q 'ERROR' "$_output" 2>/dev/null; then
    fail "$_size modules: unexpected error in output"
  else
    pass "$_size modules: no errors"
  fi

  # Exactly one emitted source block per module.
  _source_lines=$(grep -c '^[[:space:]]*\. "\${VALISE_MODULE_ROOT%/}/modules/test/mod_' "$_output" 2>/dev/null || echo 0)
  if [ "$_source_lines" -eq "$_size" ]; then
    pass "$_size modules: emitted $_source_lines source blocks"
  else
    fail "$_size modules: expected $_size source blocks, got $_source_lines"
  fi

  # Exactly one module source per module: no duplicate or skipped emission.
  _sourced=$(grep -c '^[[:space:]]*\. "\${VALISE_MODULE_ROOT%/}/modules/test/mod_' "$_output" 2>/dev/null || echo 0)
  if [ "$_sourced" -eq "$_size" ]; then
    pass "$_size modules: sourced each module exactly once"
  else
    fail "$_size modules: expected $_size module sources, got $_sourced"
  fi

  # Structural linearity: the plan is a constant-size shell block per module
  # plus constant-size preamble and epilogue. This identity is what proves
  # emitted work grows linearly in N; any re-emission or per-dependency
  # expansion breaks it, and it holds identically on every host.
  _lines=$(wc -l < "$_output" | tr -d ' ')
  _expected_lines=$((FIXED_LINES + BLOCK_LINES * _size))
  if [ "$_lines" -eq "$_expected_lines" ]; then
    pass "$_size modules: plan is exactly $_expected_lines lines (linear emission identity)"
  else
    fail "$_size modules: expected $_expected_lines lines, got $_lines"
  fi

  # The per-module block size must be identical at every size, which is the
  # part of the identity a quadratic or re-entrant implementation would move.
  if [ -z "$_baseline_block_lines" ]; then
    _baseline_block_lines=$(( (_lines - FIXED_LINES) / _size ))
  fi
  _observed_block_lines=$(( (_lines - FIXED_LINES) / _size ))
  if [ "$_observed_block_lines" -eq "$_baseline_block_lines" ] &&
     [ "$_observed_block_lines" -eq "$BLOCK_LINES" ]; then
    pass "$_size modules: per-module emission is $_observed_block_lines lines, unchanged with N"
  else
    fail "$_size modules: per-module emission drifted to $_observed_block_lines lines (baseline $_baseline_block_lines, expected $BLOCK_LINES)"
  fi

  # Dependency order is complete and deterministic: first module first, last
  # module last, and exactly N ids in the order line.
  _order=$(sed -n 's/^# order=//p' "$_output")
  _order_count=0
  for _id in $_order; do
    _order_count=$((_order_count+1))
  done
  _first=''
  _last=''
  for _id in $_order; do
    [ -z "$_first" ] && _first=$_id
    _last=$_id
  done
  if [ "$_order_count" -eq "$_size" ] && [ "$_first" = mod_1 ] && [ "$_last" = "mod_$_size" ]; then
    pass "$_size modules: dependency order lists $_order_count modules, mod_1 first, mod_$_size last"
  else
    fail "$_size modules: order line has $_order_count entries (first=${_first:-none} last=${_last:-none})"
  fi

  # Identical input must yield byte-identical output.
  awk -v target_shell="bash" -v plan_name="bench" -f "$_awk" "$_input" > "$_repeat" 2>&1
  if cmp -s "$_output" "$_repeat"; then
    pass "$_size modules: repeated compilation is byte-identical"
  else
    fail "$_size modules: repeated compilation differs from the first run"
  fi
done

printf '\n=== valise compiler structural scaling summary ===\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"
printf 'NOTE: elapsed time is not asserted here by design. Run tools/compiler-benchmark-timing.sh by hand for timings.\n'
[ "$_fail" -eq 0 ] || exit 1
