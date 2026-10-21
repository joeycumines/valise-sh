#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Verify the shell-profile engine test runner starts inside a hermetic test environment.

set -u

_pass=0
_fail=0
_total=0

pass() {
  printf '  PASS: %s\n' "$1"
  _pass=$((_pass + 1))
}

fail() {
  printf '  FAIL: %s\n' "$1"
  [ "$#" -gt 1 ] && printf '    %s\n' "$2"
  _fail=$((_fail + 1))
}

assert_eq() {
  _total=$((_total + 1))
  _label="$1"
  _expected="$2"
  _actual="$3"
  if [ "$_expected" = "$_actual" ]; then
    pass "$_label"
  else
    fail "$_label" "expected: $_expected; actual: $_actual"
  fi
}

assert_unset() {
  _total=$((_total + 1))
  _label="$1"
  _name="$2"
  if [ -z "${!_name+x}" ]; then
    pass "$_label"
  else
    fail "$_label" "$_name should be unset"
  fi
}

assert_not_under_path() {
  _total=$((_total + 1))
  _label="$1"
  _value="$2"
  _forbidden="$3"
  case "$_value" in
  "$_forbidden" | "$_forbidden"/*)
    fail "$_label" "unsafe inherited path: $_value"
    ;;
  *)
    pass "$_label"
    ;;
  esac
}

printf '\n=== shell-profile test-runner quarantine ===\n'

_forbidden_home=${VALISE_TEST_FORBIDDEN_HOME:-/__shell_profile_forbidden_home__}

assert_not_under_path 'runner HOME excludes inherited forbidden home' "${HOME:-}" "$_forbidden_home"
assert_eq 'runner TMPDIR is controlled' '/tmp' "${TMPDIR:-}"
assert_unset 'runner clears inherited BASH_ENV' BASH_ENV
assert_unset 'runner clears inherited ENV' ENV
assert_unset 'runner clears inherited ZDOTDIR' ZDOTDIR

_total=$((_total + 1))
case ":${PATH:-}:" in
*:"$_forbidden_home":* | *:"$_forbidden_home"/*:*)
  fail 'runner PATH excludes inherited forbidden home' "PATH=${PATH:-}"
  ;;
*)
  pass 'runner PATH excludes inherited forbidden home'
  ;;
esac

printf '\n=== shell-profile test-runner quarantine summary ===\n'
printf 'Total: %s  Pass: %s  Fail: %s\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
