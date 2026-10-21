#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Manual timing diagnosis for the awk plan compiler.
#
# This tool is diagnosis, not a gate. Nothing in `make test` or `make check`
# runs it, and no pass/fail decision anywhere depends on its output. Elapsed
# time measures the machine and whatever else it is doing, so it is only
# interpretable by a human who knows the host state and can compare runs.
#
# The gated proof that emitted work is linear in module count is structural and
# lives in tests/compiler-benchmark.test.sh. Use this tool when you want to
# know whether a change made the compiler slower, or when a release-gate run
# felt slow and you need to attribute it.
#
# Usage: tools/compiler-benchmark-timing.sh [module-count ...]
#   Defaults to 100 500 2000. Prefer an idle host; run it more than once and
#   compare, because a single sample on a loaded machine says nothing.
set -eu

_script_dir=$(cd "$(dirname "$0")/.." && pwd)
_awk="$_script_dir/lib/compiler.awk"

_test_home=$(mktemp -d "${TMPDIR:-/tmp}/valise-bench-timing.XXXXXX")
trap 'rm -rf -- "$_test_home"' EXIT

printf '=== valise compiler timing diagnosis (manual, non-gating) ===\n'
printf 'host: %s\n' "$(uname -sm)"
if command -v uptime >/dev/null 2>&1; then
  printf 'load: %s\n' "$(uptime 2>/dev/null || printf unknown)"
fi
printf 'awk:  %s\n' "$(awk --version 2>&1 | head -1 || awk -W version 2>&1 | head -1 || printf unknown)"
printf '\n'

# Same graph shape as the structural gate: linear chain plus a fan-out edge
# every 7th module, seeded from the last 5 modules.
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
      _req="mod_$((_i-1))"
    fi
    if [ "$_i" -gt 7 ] && [ $((_i % 7)) -eq 0 ]; then
      _req="$_req mod_$((_i-7))"
    fi
    printf 'MOD:mod_%d\t%s\tmodules/test/mod_%d.sh\n' "$_i" "$_req" "$_i" >> "$_out"
    _i=$((_i+1))
  done
}

# Prefer a sub-second clock when the platform has one; fall back to whole
# seconds, which is only good enough for coarse comparison.
_clock_now() {
  # Validate the OUTPUT, not the exit status: a strftime without %N prints a
  # literal trailing N and still exits 0, and the arithmetic below would then
  # abort on "value too great for base".
  _ns=$(date +%s%N 2>/dev/null || printf '')
  case "$_ns" in
    ''|*[!0-9]*)
      _s=$(date +%s 2>/dev/null || printf '')
      case "$_s" in
        ''|*[!0-9]*) printf '0\n' ;;
        *) printf '%s000000000\n' "$_s" ;;
      esac
      ;;
    *) printf '%s\n' "$_ns" ;;
  esac
}

printf '%8s  %12s  %12s\n' modules elapsed_ns per_module_ns
_baseline_ns=''
_baseline_size=''

for _size in ${*:-100 500 2000}; do
  _input="$_test_home/graph_$_size.txt"
  _output="$_test_home/plan_$_size.out"
  generate_graph "$_size" "$_input"

  _start=$(_clock_now)
  awk -v target_shell="bash" -v plan_name="bench" -f "$_awk" "$_input" > "$_output" 2>&1
  _end=$(_clock_now)

  _elapsed=$((_end - _start))
  [ "$_elapsed" -gt 0 ] || _elapsed=1
  _per_module=$((_elapsed / _size))
  printf '%8s  %12s  %12s\n' "$_size" "$_elapsed" "$_per_module"

  if [ -z "$_baseline_ns" ]; then
    _baseline_ns=$_elapsed
    _baseline_size=$_size
  fi
done

printf '\nInterpretation (human judgement, never a gate):\n'
printf '  - linear compiler: elapsed grows about in proportion to module count\n'
printf '  - per-module cost should stay roughly flat across the rows above\n'
printf '  - a super-linear jump suggests revisiting the resolution algorithm\n'
printf '  - a uniformly slow run usually means the host was busy, not the code\n'
printf '  - baseline for ratios above: %s modules\n' "$_baseline_size"
printf '\nStructural proof that emission is linear: tests/compiler-benchmark.test.sh\n'
