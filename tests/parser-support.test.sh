#!/usr/bin/env bash

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Parser support manifest and path-class gate for shell-profile modular files.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/manifests/parser-support.tsv"

_pass=0
_fail=0
_skip=0
_xfail=0
_total=0
_required_parsers=${VALISE_REQUIRED_PARSERS:-}
_required_seen=,

pass() { printf '  PASS: %s\n' "$1"; _pass=$((_pass + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _fail=$((_fail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; _skip=$((_skip + 1)); }
xfail() { printf '  XFAIL: %s\n' "$1"; [ "$#" -gt 1 ] && printf '    %s\n' "$2"; _xfail=$((_xfail + 1)); }

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

assert_file() {
  _total=$((_total + 1))
  if [ -f "$1" ]; then
    pass "$2"
  else
    fail "$2" "missing file: $1"
  fi
}

parser_selected() {
  [ -z "$_required_parsers" ] && return 0
  case ",$_required_parsers," in
  *",$1,"*) return 0 ;;
  *) return 1 ;;
  esac
}

mark_required_parser_seen() {
  [ -n "$_required_parsers" ] || return 0
  case "$_required_seen" in
  *",$1,"*) ;;
  *) _required_seen="${_required_seen}$1," ;;
  esac
}

parser_path() {
  _parser_name="$1"
  _parser_search_path="${MACOS_PROFILE_PARSER_SEARCH_PATH:-${PATH:-}}"
  _parser_old_ifs="$IFS"
  IFS=:
  for _parser_dir in $_parser_search_path; do
    [ -n "$_parser_dir" ] || _parser_dir=.
    _parser_candidate="$_parser_dir/$_parser_name"
    if [ -x "$_parser_candidate" ] && [ ! -d "$_parser_candidate" ]; then
      printf '%s\n' "$_parser_candidate"
      IFS="$_parser_old_ifs"
      unset _parser_name _parser_search_path _parser_old_ifs _parser_dir _parser_candidate
      return 0
    fi
  done
  IFS="$_parser_old_ifs"
  unset _parser_name _parser_search_path _parser_old_ifs _parser_dir _parser_candidate
  return 0
}

parser_command_path() {
  _parser_name="$1"
  case "$_parser_name" in
  sh)
    [ -x /bin/sh ] && printf '%s\n' /bin/sh
    ;;
  bash | zsh | ksh | dash | fish)
    parser_path "$_parser_name"
    ;;
  busybox-ash)
    _parser_busybox=$(parser_path busybox)
    if [ -n "$_parser_busybox" ] && "$_parser_busybox" ash -n /dev/null >/dev/null 2>&1; then
      printf '%s\n' "$_parser_busybox"
    fi
    unset _parser_busybox
    ;;
  esac
  unset _parser_name
}

parser_version() {
  _parser_name="$1"
  _parser_exec="$2"
  _parser_status=0
  _parser_output=""
  case "$_parser_name" in
  sh)
    _parser_output=$("$_parser_exec" --version 2>&1) || _parser_status=$?
    ;;
  bash | zsh | ksh | fish)
    _parser_output=$("$_parser_exec" --version 2>&1) || _parser_status=$?
    ;;
  dash)
    _parser_output=$("$_parser_exec" -V </dev/null 2>&1) || _parser_status=$?
    ;;
  busybox-ash)
    _parser_output=$("$_parser_exec" 2>&1) || _parser_status=$?
    ;;
  *)
    _parser_status=1
    ;;
  esac
  _parser_first=$(printf '%s\n' "$_parser_output" | sed -n '1p')
  if [ "$_parser_status" -eq 0 ] && [ -n "$_parser_first" ]; then
    printf '%s\n' "$_parser_first"
  else
    printf '%s\n' 'version unavailable'
  fi
  unset _parser_name _parser_exec _parser_status _parser_output _parser_first
}

print_parser_audit() {
  _parser_name="$1"
  _parser_exec=$(parser_command_path "$_parser_name")
  if [ -n "$_parser_exec" ]; then
    _parser_display="$_parser_exec"
    [ "$_parser_name" = "busybox-ash" ] && _parser_display="$_parser_exec ash"
    _parser_ver=$(parser_version "$_parser_name" "$_parser_exec")
    printf '  AUDIT: parser=%s path=%s version=%s\n' "$_parser_name" "$_parser_display" "$_parser_ver"
  else
    printf '  AUDIT: parser=%s unavailable\n' "$_parser_name"
  fi
  unset _parser_name _parser_exec _parser_display _parser_ver
}

run_parser() {
  _run_parser_name="$1"
  _run_file="$2"
  _run_label="$3"
  _run_requirement="$4"
  if ! parser_selected "$_run_parser_name"; then
    unset _run_parser_name _run_file _run_label _run_requirement
    return 0
  fi
  mark_required_parser_seen "$_run_parser_name"
  _run_parser_exec=$(parser_command_path "$_run_parser_name")
  _total=$((_total + 1))
  if [ -z "$_run_parser_exec" ]; then
    if [ -n "$_required_parsers" ]; then
      fail "$_run_label" "required parser unavailable: $_run_parser_name"
    else
      skip "$_run_label ($_run_parser_name unavailable)"
    fi
    unset _run_parser_name _run_file _run_label _run_requirement _run_parser_exec
    return 0
  fi
  _err_file=$(mktemp "${TMPDIR:-/tmp}/shell-profile-parser.XXXXXX") || exit 1
  case "$_run_parser_name" in
  busybox-ash)
    "$_run_parser_exec" ash -n "$_run_file" >/dev/null 2>"$_err_file"
    _status=$?
    ;;
  *)
    "$_run_parser_exec" -n "$_run_file" >/dev/null 2>"$_err_file"
    _status=$?
    ;;
  esac
  if [ "$_status" -eq 0 ]; then
    pass "$_run_label"
  else
    _err=$(tr '\n' ' ' <"$_err_file" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
    if [ "$_run_requirement" = "xfail" ]; then
      xfail "$_run_label" "exit $_status${_err:+; $_err}"
    else
      fail "$_run_label" "exit $_status${_err:+; $_err}"
    fi
  fi
  rm -f "$_err_file"
  unset _run_parser_name _run_file _run_label _run_requirement _run_parser_exec _err_file _status _err
}

manifest_lookup() {
  _lookup_rel="$1"
  while IFS=$'\t' read -r _pattern _class _parsers _requirement _notes; do
    case "$_pattern" in '' | \#*) continue ;; esac
    if [[ "$_lookup_rel" == $_pattern ]]; then
      printf '%s\t%s\t%s\t%s\n' "$_pattern" "$_class" "$_parsers" "$_requirement"
    fi
  done <"$MANIFEST"
  unset _lookup_rel _pattern _class _parsers _requirement _notes
}

assert_manifest_row() {
  _pattern="$1"
  _class="$2"
  _parsers="$3"
  _requirement="$4"
  _total=$((_total + 1))
  if awk -F '\t' -v p="$_pattern" -v c="$_class" -v ps="$_parsers" -v r="$_requirement" '
    $0 !~ /^#/ && $1 == p && $2 == c && $3 == ps && $4 == r { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST"; then
    pass "manifest row exists: $_pattern -> $_class/$_parsers/$_requirement"
  else
    fail "manifest row missing" "$_pattern -> $_class/$_parsers/$_requirement"
  fi
  unset _pattern _class _parsers _requirement
}

assert_no_manifest_row() {
  _pattern="$1"
  _total=$((_total + 1))
  if awk -F '\t' -v p="$_pattern" '$0 !~ /^#/ && $1 == p { found = 1 } END { exit found ? 1 : 0 }' "$MANIFEST"; then
    pass "unshipped parser surface is absent from manifest: $_pattern"
  else
    fail 'unshipped parser surface is advertised in manifest' "$_pattern"
  fi
  unset _pattern
}

validate_required_parsers() {
  [ -n "$_required_parsers" ] || return 0
  case "$_required_parsers" in
  ,* | *, | *,,* | *[!A-Za-z0-9,-]*)
    _total=$((_total + 1))
    fail 'required parser list is canonical' "invalid VALISE_REQUIRED_PARSERS: $_required_parsers"
    return 0
    ;;
  esac
  _required_old_ifs=$IFS
  IFS=,
  for _required_parser in $_required_parsers; do
    case "$_required_parser" in
    bash | zsh | ksh | sh | dash | busybox-ash | fish) ;;
    *)
      _total=$((_total + 1))
      fail 'required parser name is supported' "unknown parser: $_required_parser"
      ;;
    esac
  done
  IFS=$_required_old_ifs
  unset _required_old_ifs _required_parser
}

validate_required_parsers

printf '\n=== Shell-profile parser executable audit ===\n'
for _parser in bash zsh ksh sh dash busybox-ash fish; do
  print_parser_audit "$_parser"
done
unset _parser

printf '\n=== Shell-profile parser support manifest shape ===\n'
assert_file "$MANIFEST" "parser support manifest exists"
assert_manifest_row 'entrypoints/profile.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'entrypoints/fish/*.fish' 'fish' 'fish' 'required'
assert_manifest_row 'lib/*.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'lib/*.awk' 'non-shell' 'none' 'required'
assert_manifest_row 'lib/fish/*.fish' 'fish' 'fish' 'required'
assert_manifest_row 'modules/system/*.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'modules/platform/posix.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'modules/platform/macos/*.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'modules/platform/linux/*.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_manifest_row 'modules/platform/bsd/*.sh' 'posix' 'sh,dash,ksh,busybox-ash,bash' 'required'
assert_no_manifest_row 'modules/core/*.sh'
assert_no_manifest_row 'modules/update/*.sh'
assert_no_manifest_row 'modules/git/*.sh'
assert_no_manifest_row 'modules/lang/*.sh'
assert_no_manifest_row 'modules/work/*.sh'
assert_no_manifest_row 'modules/secrets/*.sh'
assert_no_manifest_row 'modules/ai/*.sh'
assert_no_manifest_row 'modules/wrappers/*.sh'
assert_no_manifest_row 'modules/shell/bash/*.sh'
assert_no_manifest_row 'modules/shell/zsh/*.sh'
assert_no_manifest_row 'modules/shell/fish/*.fish'
assert_no_manifest_row 'entrypoints/bash/profile.sh'
assert_no_manifest_row 'entrypoints/zsh/profile.zsh'
assert_no_manifest_row 'entrypoints/ksh/profile.sh'
assert_no_manifest_row 'modules/fish/core/*.fish'

printf '\n=== Shell-profile architecture-path parser gate ===\n'
_found_files=0
while IFS= read -r _rel; do
  [ -n "$_rel" ] || continue
  case "$_rel" in
  */.gitkeep | .gitkeep) continue ;;
  bin/valise | *.sh | *.zsh | *.fish | *.awk) ;;
  *)
    _total=$((_total + 1))
    fail "architecture-path file has parser-manifest compatible suffix" "$_rel"
    continue
    ;;
  esac
  _found_files=$((_found_files + 1))
  _rows=$(manifest_lookup "$_rel")
  _total=$((_total + 1))
  if [ -z "$_rows" ]; then
    fail "architecture-path file is declared in parser manifest" "$_rel"
    continue
  fi
  pass "architecture-path file is declared in parser manifest ($_rel)"
  _row_count=$(printf '%s\n' "$_rows" | sed '/^$/d' | wc -l | tr -d ' ')
  assert_eq "architecture-path file has exactly one parser manifest row ($_rel)" "1" "$_row_count"
  _row=$(printf '%s\n' "$_rows" | sed -n '1p')
  IFS=$'\t' read -r _pattern _class _parsers _requirement <<ROW
$_row
ROW
  _old_ifs="$IFS"
  IFS=,
  for _parser_name in $_parsers; do
    [ -n "$_parser_name" ] || continue
    run_parser "$_parser_name" "$ROOT_DIR/$_rel" "$_rel parses with $_parser_name via manifest class $_class" "$_requirement"
  done
  IFS="$_old_ifs"
  unset _rows _row_count _row _pattern _class _parsers _requirement _old_ifs _parser_name
done < <(cd "$ROOT_DIR" && find bin entrypoints lib modules -type f -print | sed 's|^./||' | sort)

if [ "$_found_files" -eq 0 ]; then
  _total=$((_total + 1))
  skip 'no modular shell files exist yet; manifest rows will gate the first architecture-path file'
fi
unset _found_files _rel

if [ -n "$_required_parsers" ]; then
  _required_old_ifs=$IFS
  IFS=,
  for _required_parser in $_required_parsers; do
    case "$_required_seen" in
    *",$_required_parser,"*) ;;
    *)
      _total=$((_total + 1))
      fail 'required parser exercised at least once' "no manifest-owned file selected parser: $_required_parser"
      ;;
    esac
  done
  IFS=$_required_old_ifs
  unset _required_old_ifs _required_parser
  assert_eq 'required parser mode records zero skips' '0' "$_skip"
fi

printf '\n=== shell-profile parser-support summary ===\n'
printf 'Total: %d  Pass: %d  XFail: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_xfail" "$_skip" "$_fail"

[ "$_fail" -eq 0 ]
