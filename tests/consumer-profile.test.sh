#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# End-to-end contract against a real consumer project.
#
# VALISE_CONSUMER_PROFILE names the root of a valise project (the directory
# holding valise.conf). The tree is copied to a temporary directory and only
# the copy is used: the original is never modified and no live profile is
# sourced. The consumer's own lint and module tests run through this
# checkout's valise, then every bundle is built twice to prove the release
# is deterministic.
#
# Without VALISE_CONSUMER_PROFILE, or when it does not name a valise
# project, the suite records a visible skip.

set -u

_pass=0
_fail=0
_skip=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); _total=$((_total + 1)); }
fail() { printf '  FAIL: %s\n' "$1" >&2; _fail=$((_fail + 1)); _total=$((_total + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); _total=$((_total + 1)); }

summary() {
  printf '=== consumer-profile summary ===\nTotal: %d  Pass: %d  Skip: %d  Fail: %d\n' \
    "$_total" "$_pass" "$_skip" "$_fail"
  [ "$_fail" -eq 0 ]
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
VALISE="$REPO_ROOT/bin/valise"
CONSUMER_SRC=${VALISE_CONSUMER_PROFILE:-}

if [ -z "$CONSUMER_SRC" ]; then
  skip 'VALISE_CONSUMER_PROFILE is not set (point it at a valise project root to run this suite)'
  summary
  exit $?
fi
if [ ! -f "$CONSUMER_SRC/valise.conf" ]; then
  skip "VALISE_CONSUMER_PROFILE=$CONSUMER_SRC is not a valise project (no valise.conf)"
  summary
  exit $?
fi

_cp_tmpdir=${TMPDIR:-/tmp}
_cp_tmpdir=${_cp_tmpdir%/}
WORK="$(mktemp -d "$_cp_tmpdir/valise-consumer.XXXXXX")" || {
  printf '  FAIL: cannot create the working directory\n' >&2
  exit 1
}
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null || :
  rm -rf "$WORK" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

CONSUMER="$WORK/project"
if ! cp -R "$CONSUMER_SRC" "$CONSUMER"; then
  printf '  FAIL: cannot copy the consumer tree\n' >&2
  exit 1
fi
rm -rf "$CONSUMER/build"
mkdir -p "$WORK/home" "$WORK/tmp"

# Every valise invocation runs with a private HOME and XDG tree.
consumer_valise() {
  env -i PATH="${VALISE_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
    XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" \
    XDG_STATE_HOME="$WORK/home/.local/state" \
    "$VALISE" -C "$CONSUMER" "$@"
}

if consumer_valise lint >"$WORK/lint.out" 2>&1; then
  pass 'consumer project passes valise lint'
else
  fail 'consumer project passes valise lint'
  sed 's/^/    /' "$WORK/lint.out" >&2
fi

if consumer_valise test >"$WORK/test.out" 2>&1; then
  pass 'consumer module tests pass under valise test'
else
  fail 'consumer module tests pass under valise test'
  sed 's/^/    /' "$WORK/test.out" >&2
fi

_bundles=$(awk -F '\t' '!/^[[:space:]]*#/ && NF >= 2 && !seen[$1]++ { print $1 }' "$CONSUMER/bundles.tsv")
for _bundle in $_bundles; do
  if consumer_valise build --bundle="$_bundle" "$WORK/build-$_bundle-a" >"$WORK/build.out" 2>&1 &&
    consumer_valise build --bundle="$_bundle" "$WORK/build-$_bundle-b" >>"$WORK/build.out" 2>&1; then
    pass "bundle $_bundle builds"
    if cmp -s "$WORK/build-$_bundle-a/manifest.tsv" "$WORK/build-$_bundle-b/manifest.tsv"; then
      pass "bundle $_bundle builds deterministically"
    else
      fail "bundle $_bundle builds deterministically"
    fi
  else
    fail "bundle $_bundle builds"
    sed 's/^/    /' "$WORK/build.out" >&2
  fi
done

summary
