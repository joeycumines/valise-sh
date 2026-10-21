#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Markdown documentation-link case-sensitivity guard.
#
# Every inline relative markdown link must resolve exactly as written on a
# case-sensitive filesystem: each path component (directories and the final
# filename) must exist with byte-exact casing. This is verified with
# case-sensitive `-path` matching so it works even on case-insensitive hosts,
# guarding against macOS/Windows-cased links that break on Linux ext4 and BSD.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TREE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

_pass=0
_fail=0
_total=0

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }

# Strip fenced code blocks so inline examples are not treated as links.
strip_fenced_blocks() {
  /usr/bin/awk 'BEGIN { fence = 0 } /^```/ { fence = !fence; next } fence == 0 { print }' <"$1"
}

# Every relative path component of $_candidate must appear with byte-exact
# casing in $_base_dir. Uses find -path (case-sensitive matching even on
# case-insensitive filesystems) and refuses glob metacharacters outright so a
# bracketed filename cannot silently become a pattern.
casing_exact() {
  _ce_base_dir=$1
  _ce_candidate=$2
  case "$_ce_candidate" in
  *[\[\*\?\[]*)
    printf '%s\n' "glob-metacharacter-in-link"
    return 0
    ;;
  esac
  # A leading ./ adds no component to verify; strip it.
  while :; do
    case "$_ce_candidate" in
    ./*) _ce_candidate=${_ce_candidate#./} ;;
    *) break ;;
    esac
  done
  _ce_dir=$_ce_base_dir
  while [ -n "$_ce_candidate" ]; do
    _ce_segment=${_ce_candidate%%/*}
    case "$_ce_candidate" in
    */*) _ce_candidate=${_ce_candidate#*/} ;;
    *) _ce_candidate= ;;
    esac
    case "$_ce_segment" in
    ..)
      # Parent traversal: the casing of '..' itself is vacuous; step up.
      _ce_dir=$(dirname "$_ce_dir")
      continue
      ;;
    .) continue ;;
    esac
    _ce_hit=$(
      cd "$_ce_dir" 2>/dev/null &&
        find . -maxdepth 1 -path "./$_ce_segment" |
        head -n 1
    )
    [ -n "$_ce_hit" ] || {
      printf '%s\n' "$_ce_segment"
      return 0
    }
    _ce_dir=$_ce_dir/$_ce_segment
  done
  printf '%s\n' ''
}

# Enumerate only git-visible files: tracked plus untracked-but-not-ignored.
# Worktree-local excluded content (local skills, agent worktrees, scratch) is
# not product and must not fail the gate.
list_md_files() {
  (cd "$TREE_ROOT" && git ls-files -z --cached --others --exclude-standard -- '*.md' | tr '\0' '\n')
}
_total=$((_total + 1))
_md_count=$(list_md_files | wc -l | tr -d ' ')
if [ "$_md_count" -gt 0 ]; then
  pass "markdown files exist to verify ($_md_count files)"
else
  fail "markdown files exist to verify" "no .md files found under $TREE_ROOT"
fi

_link_found=0
_link_seq=0
_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/shell-doc-links.XXXXXX") || exit 1
cleanup() { rm -rf "$_tmp_dir" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
# Scan the tree's markdown files, plus the repository-root AGENTS.md (outside
# TREE_ROOT but maintained by this product; its links point into shell/).
_md_file_list=$_tmp_dir/md-files
{
  list_md_files | sed 's|^|./|' | sort
  [ -f "$TREE_ROOT/../AGENTS.md" ] && printf '%s\n' '../AGENTS.md'
} >"$_md_file_list"
while IFS= read -r _md; do
  _md_rel=${_md#"./"}
  _md_dir=$(cd "$TREE_ROOT/$(dirname "$_md")" && pwd -P)
  _md="$TREE_ROOT/$_md"
  _targets_file=$_tmp_dir/targets.$_link_seq
  : >"$_targets_file"
  strip_fenced_blocks "$_md" | /usr/bin/grep -oE '\[[^]]*\]\([^)]*\)' |
    /usr/bin/sed -E 's/^\[[^]]*\]\(([^)#]*)(#[^)]*)?\)$/\1/' >>"$_targets_file" || :
  _link_seq=$((_link_seq + 1))
  while IFS= read -r _path; do
    [ -n "$_path" ] || continue
    case "$_path" in
    *"://"* | *"mailto:"*) continue ;;
    esac
    case "$_path" in
    *.md | *.tsv) ;;
    *) continue ;;
    esac
    _link_found=$((_link_found + 1))
    case "$_path" in
    /*)
      _total=$((_total + 1))
      fail "link is tree-relative, not absolute: $_md_rel -> $_path"
      continue
      ;;
    esac
    _resolved="$_md_dir/$_path"
    _total=$((_total + 1))
    if [ ! -e "$_resolved" ]; then
      fail "relative link resolves: $_md_rel -> $_path" "missing: $_resolved"
      continue
    fi
    pass "relative link resolves: $_md_rel -> $_path"
    _total=$((_total + 1))
    _mismatch=$(casing_exact "$_md_dir" "$_path")
    if [ -z "$_mismatch" ]; then
      pass "link path casing matches on-disk byte-exactly: $_md_rel -> $_path"
    elif [ "$_mismatch" = "glob-metacharacter-in-link" ]; then
      fail "link path casing matches on-disk byte-exactly: $_md_rel -> $_path" \
        "link contains glob metacharacters; refusing to pattern-match"
    else
      fail "link path casing matches on-disk byte-exactly: $_md_rel -> $_path" \
        "no case-sensitive match for component: $_mismatch"
    fi
  done <"$_targets_file"
done <"$_md_file_list"

_total=$((_total + 1))
if [ "$_link_found" -gt 0 ]; then
  pass "markdown links exist to verify ($_link_found links)"
else
  fail "markdown links exist to verify" "no relative .md/.tsv links found; the guard is exercising nothing"
fi

printf '\n=== doc-link case-sensitivity summary (%s) ===\n' "$TREE_ROOT"
printf 'Total: %d  Pass: %d  Fail: %d\n' "$_total" "$_pass" "$_fail"

[ "$_fail" -eq 0 ]
