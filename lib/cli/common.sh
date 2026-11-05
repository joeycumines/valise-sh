# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: shared helpers, XDG roots, trusted utilities, file probes.
# Sourced by bin/valise; not executable on its own.

die() {
  printf 'valise: error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'valise: %s\n' "$*"
}

# Verification failure reporting. The default mode aborts the command, which
# is what install and release use. Quiet mode returns a nonzero status
# instead, so a diagnostic command can report the failure and carry on. The
# message text is identical in both modes.
_verify_quiet=0
_verify_fail() {
  if [ "$_verify_quiet" -eq 1 ]; then
    printf 'valise: error: %s\n' "$*" >&2
    return 1
  fi
  die "$*"
}

# Lexically normalize an absolute path: collapse repeated slashes, drop "."
# segments, and resolve ".." against the preceding component. Relative paths
# are resolved against the physical working directory first.
path_normalize() {
  _path_norm_value=$1
  case "$_path_norm_value" in
    /*) ;;
    *) _path_norm_value=$(pwd -P)/$_path_norm_value ;;
  esac
  _path_norm_out=
  if [ "${IFS+x}" = x ]; then
    _path_norm_ifs_was_set=1
    _path_norm_old_ifs=${IFS-}
  else
    _path_norm_ifs_was_set=0
    _path_norm_old_ifs=
  fi
  case $- in
    *f*) _path_norm_glob_was_set=1 ;;
    *) _path_norm_glob_was_set=0 ;;
  esac
  set -f
  IFS=/
  for _path_norm_part in $_path_norm_value; do
    case "$_path_norm_part" in
      ''|.) continue ;;
      ..)
        case "$_path_norm_out" in
          '') ;;
          */*) _path_norm_out=${_path_norm_out%/*} ;;
          *) _path_norm_out= ;;
        esac
        continue
        ;;
    esac
    _path_norm_out=${_path_norm_out:+$_path_norm_out/}$_path_norm_part
  done
  if [ "$_path_norm_ifs_was_set" -eq 1 ]; then
    IFS=$_path_norm_old_ifs
  else
    unset IFS
  fi
  if [ "$_path_norm_glob_was_set" -eq 0 ]; then
    set +f
  fi
  printf '/%s\n' "$_path_norm_out"
}

# XDG defaults per install-contracts.md.
#
# The roots are normalized to absolute paths. A relative XDG_DATA_HOME would
# otherwise be written into the active symlink verbatim, and a relative
# symlink target resolves against the directory holding the link rather
# than the caller's working directory. The pointer would then dangle, and
# prune would compare the active release by a path spelling that never
# matches the release directory.
VALISE_XDG_DATA=$(path_normalize "${XDG_DATA_HOME:-$HOME/.local/share}/valise")
VALISE_XDG_CONFIG=$(path_normalize "${XDG_CONFIG_HOME:-$HOME/.config}/valise")
VALISE_XDG_STATE=$(path_normalize "${XDG_STATE_HOME:-$HOME/.local/state}/valise")
VALISE_RELEASES_DIR="$VALISE_XDG_DATA/releases"
VALISE_ACTIVE_LINK="$VALISE_XDG_CONFIG/active"
VALISE_LOCK_DIR="$VALISE_XDG_STATE/lock"

# POSIX path parent extraction avoids ambient dirname resolution in manifest
# discovery and every subsequent source/destination validation path.
path_parent() {
  _path_parent_value=$1
  # Strip trailing slashes so "out/" and "out" share one parent (".").
  # Without this, path_parent("out/") is "out" itself: parent-mkdir creates
  # the destination, the emptiness check treats it as pre-created-empty, and
  # staging lands inside the destination (publish then fails ENOTEMPTY).
  while [ "$_path_parent_value" != "/" ] &&
    [ "${_path_parent_value%/}" != "$_path_parent_value" ]; do
    _path_parent_value=${_path_parent_value%/}
  done
  case "$_path_parent_value" in
    */*)
      _path_parent_value=${_path_parent_value%/*}
      [ -n "$_path_parent_value" ] || _path_parent_value=/
      ;;
    *) _path_parent_value=. ;;
  esac
  printf '%s\n' "$_path_parent_value"
}

# Physical directory of bin/valise, resolved once by bin/valise before any
# library is sourced.
valise_script_dir() {
  printf '%s\n' "$_valise_engine_bin"
}

# Emit a single-quoted literal for generated POSIX shell code. The generated
# snippets must not interpolate user-controlled XDG paths into double quotes:
# `$()` and backticks would still execute there. POSIX single quotes preserve
# every character except apostrophe, which is represented by the standard
# '\'' sequence.
shell_quote() {
  _shell_quote_value=$1
  printf "'"
  while [ -n "$_shell_quote_value" ]; do
    _shell_quote_char=${_shell_quote_value%"${_shell_quote_value#?}"}
    _shell_quote_value=${_shell_quote_value#?}
    case "$_shell_quote_char" in
      "'") printf "%s" "'\\''" ;;
      *) printf '%s' "$_shell_quote_char" ;;
    esac
  done
  printf "'"
}

# Fish single-quoted literals use a backslash-escaped apostrophe. Encode each
# source backslash as two backslashes so a backslash immediately before an
# apostrophe cannot change the quote grammar. Dollar signs, semicolons, and
# command-substitution markers remain literal, so arbitrary XDG paths cannot
# inject Fish commands.
fish_quote() {
  _fish_quote_value=$1
  printf "'"
  while [ -n "$_fish_quote_value" ]; do
    _fish_quote_char=${_fish_quote_value%"${_fish_quote_value#?}"}
    _fish_quote_value=${_fish_quote_value#?}
    case "$_fish_quote_char" in
      \\) printf '%s' '\\' ;;
      "'") printf '%s' "\\'" ;;
      *) printf '%s' "$_fish_quote_char" ;;
    esac
  done
  printf "'"
}

trusted_uname() {
  if [ -x /usr/bin/uname ]; then
    /usr/bin/uname "$@"
  elif [ -x /bin/uname ]; then
    /bin/uname "$@"
  else
    return 1
  fi
}

# Resolve only platform-owned utility paths for integrity operations. These
# checks must not be redirected by a caller-controlled PATH.
trusted_utility_path() {
  case "$1" in
    awk) _trusted_candidates='/usr/bin/awk /bin/awk' ;;
    cat) _trusted_candidates='/bin/cat /usr/bin/cat' ;;
    cp) _trusted_candidates='/bin/cp /usr/bin/cp' ;;
    chmod) _trusted_candidates='/bin/chmod /usr/bin/chmod' ;;
    cmp) _trusted_candidates='/usr/bin/cmp /bin/cmp' ;;
    ln) _trusted_candidates='/bin/ln /usr/bin/ln' ;;
    mkdir) _trusted_candidates='/bin/mkdir /usr/bin/mkdir' ;;
    kill) _trusted_candidates='/bin/kill /usr/bin/kill' ;;
    mktemp) _trusted_candidates='/usr/bin/mktemp /bin/mktemp /opt/homebrew/bin/mktemp /usr/local/bin/mktemp' ;;
    readlink) _trusted_candidates='/usr/bin/readlink /bin/readlink' ;;
    rmdir) _trusted_candidates='/bin/rmdir /usr/bin/rmdir' ;;
    find) _trusted_candidates='/usr/bin/find /bin/find' ;;
    fish) _trusted_candidates='/opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish /bin/fish' ;;
    mv) _trusted_candidates='/bin/mv /usr/bin/mv' ;;
    rm) _trusted_candidates='/bin/rm /usr/bin/rm' ;;
    stat) _trusted_candidates='/usr/bin/stat /bin/stat' ;;
    tr) _trusted_candidates='/usr/bin/tr /bin/tr' ;;
    wc) _trusted_candidates='/usr/bin/wc /bin/wc' ;;
    sha256sum) _trusted_candidates='/usr/bin/sha256sum /bin/sha256sum /sbin/sha256sum /opt/homebrew/bin/sha256sum /usr/local/bin/sha256sum' ;;
    sha256) _trusted_candidates='/usr/bin/sha256 /bin/sha256 /sbin/sha256 /opt/homebrew/bin/sha256 /usr/local/bin/sha256' ;;
    shasum) _trusted_candidates='/usr/bin/shasum /bin/shasum /opt/homebrew/bin/shasum /usr/local/bin/shasum' ;;
    sort) _trusted_candidates='/usr/bin/sort /bin/sort' ;;
    *) return 1 ;;
  esac
  for _trusted_candidate in $_trusted_candidates; do
    if [ -x "$_trusted_candidate" ]; then
      printf '%s\n' "$_trusted_candidate"
      return 0
    fi
  done
  return 1
}

readlink_target() {
  _readlink_path=$(trusted_utility_path readlink) || return 1
  "$_readlink_path" "$1"
}

# active_release_dir
# Print the physical directory the active pointer names, or fail. The result
# is canonical, so a trailing slash, a relative target, or an alias symlink
# never changes the release identity.
active_release_dir() {
  [ -L "$VALISE_ACTIVE_LINK" ] || return 1
  _ard_target=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null) || return 1
  [ -n "$_ard_target" ] || return 1
  case "$_ard_target" in
    /*) : ;;
    *)
      _ard_parent=$(cd "$(path_parent "$VALISE_ACTIVE_LINK")" 2>/dev/null && pwd -P) || return 1
      _ard_target="$_ard_parent/$_ard_target"
      ;;
  esac
  _ard_target=$(path_normalize "$_ard_target") || return 1
  (cd "$_ard_target" 2>/dev/null && pwd -P)
}

# active_release_id
# Print the active release's directory name. Identity is the name, not the
# path spelling.
active_release_id() {
  _ari_dir=$(active_release_dir) || return 1
  printf '%s\n' "${_ari_dir##*/}"
}

# Resolve the consuming project root for the commands that read project
# files (compile, build, explain-*, layer-lint). The working directory
# wins over the engine's own checkout, so a package install cannot supply a
# different source root than the project the caller is standing in. A
# project is recognised by shell/release/module-registry.tsv or by a
# shell/module.d directory.
#
# Prints the canonical project root, or fails.
resolve_project_root() {
  _rpr_script_dir=$(valise_script_dir) || return 1
  for _rpr_candidate in "." "$_rpr_script_dir/.." "$_rpr_script_dir/../.." "$_rpr_script_dir/../../.."; do
    if [ -f "$_rpr_candidate/shell/release/module-registry.tsv" ] ||
       [ -d "$_rpr_candidate/shell/module.d" ]; then
      (cd "$_rpr_candidate" && pwd -P)
      return 0
    fi
  done
  return 1
}

# Resolve the engine checkout that ships this CLI. Its modules live in
# module.d/ at the top level, not under shell/.
resolve_engine_root() {
  _rer_script_dir=$(valise_script_dir) || return 1
  for _rer_candidate in "$_rer_script_dir/.." "$_rer_script_dir/../.." "$_rer_script_dir/../../.."; do
    if [ -d "$_rer_candidate/module.d" ] && [ -d "$_rer_candidate/lib" ]; then
      (cd "$_rer_candidate" && pwd -P)
      return 0
    fi
  done
  return 1
}

# Print the module names a layer is allowed to depend on: the engine's own
# modules, plus the primary-root modules of the consuming project. A layer
# may require a module in its own layer, or one of these; anything else is a
# dependency the layer does not own.
engine_module_names() {
  _emn_root=$1
  for _emn_meta in "$_emn_root"/module.d/*.meta "$_emn_root"/shell/module.d/*.meta; do
    [ -f "$_emn_meta" ] || continue
    _emn_name=${_emn_meta##*/}
    printf '%s\n' "${_emn_name%.meta}"
  done
}

# Return a file's three-digit permission mode in the manifest's octal form.
# BSD stat and GNU stat use different option spellings, so probe both.
file_mode() {
  _stat_path=$(trusted_utility_path stat) || return 1
  # BSD stat accepts -f; GNU stat accepts -c. GNU stat may nevertheless
  # accept -f as a filesystem-stat format and exit successfully, so select a
  # result by validating the output rather than relying on exit status alone.
  _mode_value=$("$_stat_path" -f '%Lp' "$1" 2>/dev/null || :)
  case "$_mode_value" in
    [0-7][0-7][0-7]) printf '0%s\n' "$_mode_value"; return 0 ;;
  esac
  _mode_value=$("$_stat_path" -c '%a' "$1" 2>/dev/null || :) || return 1
  case "$_mode_value" in
    [0-7][0-7][0-7]) printf '0%s\n' "$_mode_value" ;;
    *) return 1 ;;
  esac
}

# Return a regular file's exact byte count without locale-dependent padding.
file_bytes() {
  _wc_path=$(trusted_utility_path wc) || return 1
  _tr_path=$(trusted_utility_path tr) || return 1
  "$_wc_path" -c < "$1" | "$_tr_path" -d '[:space:]'
}

# Return a file's modification time in whole epoch seconds. BSD stat and GNU
# stat use different option spellings, so probe both and select the result by
# validating the output rather than trusting exit status alone: GNU stat
# accepts -f as a filesystem-status flag and can exit successfully while
# printing something that is not a timestamp.
file_mtime() {
  _mtime_stat=$(trusted_utility_path stat) || return 1
  _mtime_value=$("$_mtime_stat" -c %Y "$1" 2>/dev/null || :)
  case "$_mtime_value" in
    '' | *[!0-9]*) ;;
    *) printf '%s\n' "$_mtime_value"; return 0 ;;
  esac
  _mtime_value=$("$_mtime_stat" -f %m "$1" 2>/dev/null || :)
  case "$_mtime_value" in
    '' | *[!0-9]*) return 1 ;;
    *) printf '%s\n' "$_mtime_value" ;;
  esac
}

file_sha256() {
  _sha_path=$(trusted_utility_path sha256sum 2>/dev/null || :)
  if [ -n "$_sha_path" ]; then
    _sha_output=$("$_sha_path" "$1") || return 1
  else
    _sha_path=$(trusted_utility_path shasum 2>/dev/null || :)
    if [ -n "$_sha_path" ]; then
      _sha_output=$("$_sha_path" -a 256 "$1") || return 1
    else
      _sha_path=$(trusted_utility_path sha256 2>/dev/null || :)
      [ -n "$_sha_path" ] || return 1
      _sha_output=$("$_sha_path" "$1") || return 1
    fi
  fi
  # Supported utilities: sha256sum/shasum print "digest  filename";
  # BSD sha256 prints "SHA256 (filename) = digest" or just the digest.
  # The BSD format strip must be gated behind the SHA256 ( prefix: a
  # blanket *=* match corrupts sha256sum/shasum output whenever the
  # absolute file path contains "= " (equals followed by space).
  case "$_sha_output" in
    "SHA256 ("*) _sha_output=${_sha_output##* = } ;;
  esac
  _sha_output=${_sha_output%% *}
  _sha_output=${_sha_output%%$(printf '\t')*}
  printf '%s\n' "$_sha_output"
}

lower_hex() {
  _tr_path=$(trusted_utility_path tr) || return 1
  "$_tr_path" 'A-F' 'a-f'
}

cmd_version() {
  printf '%s\n' "$VALISE_VERSION"
}
