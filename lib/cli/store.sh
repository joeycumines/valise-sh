# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: release store: locking, manifests, verification, install, release management.
# Sourced by bin/valise; not executable on its own.

# Acquire atomic lock via mkdir (POSIX atomic operation). Every utility that
# participates in lock integrity is resolved by absolute path so PATH cannot
# forge ownership or suppress stale-lock cleanup.
_lock_owned=0
_publish_tmp=""
_manifest_rows=""
_manifest_parse=""
_stage=""
_hook_tmp=""
_mm_tmp=""
_rr_tmp=""
_mv_path=""
_cleanup_failed=0
acquire_lock() {
  _lock_cat_path=$(trusted_utility_path cat) || die "no trusted cat utility available"
  _lock_mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _lock_rm_path=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _lock_kill_path=$(trusted_utility_path kill) || die "no trusted kill utility available"

  # Reentrant ownership is valid only for a real lock directory and a real,
  # non-symlink pid file containing this process's exact PID.
  if [ "$_lock_owned" -eq 1 ] && [ -d "$VALISE_LOCK_DIR" ] && [ ! -L "$VALISE_LOCK_DIR" ] &&
     [ -f "$VALISE_LOCK_DIR/pid" ] && [ ! -L "$VALISE_LOCK_DIR/pid" ]; then
    _existing_pid=$("$_lock_cat_path" "$VALISE_LOCK_DIR/pid" 2>/dev/null || :)
    case "$_existing_pid" in
      ''|*[!0-9]*) : ;;
      "$$") _lock_owned=1; return 0 ;;
    esac
  fi

  _lock_parent=${VALISE_LOCK_DIR%/*}
  [ -n "$_lock_parent" ] || _lock_parent=/
  if [ ! -d "$_lock_parent" ]; then
    "$_lock_mkdir_path" -p "$_lock_parent" 2>/dev/null || die "cannot create lock parent: $_lock_parent"
  fi
  if ! "$_lock_mkdir_path" -m 700 "$VALISE_LOCK_DIR" 2>/dev/null; then
    # Check for stale lock using only the trusted utility paths. An invalid or
    # unreadable lock is fail-closed rather than treated as stale.
    if [ -d "$VALISE_LOCK_DIR" ] && [ ! -L "$VALISE_LOCK_DIR" ] &&
       [ -f "$VALISE_LOCK_DIR/pid" ] && [ ! -L "$VALISE_LOCK_DIR/pid" ]; then
      _lock_pid=$("$_lock_cat_path" "$VALISE_LOCK_DIR/pid" 2>/dev/null || :)
      case "$_lock_pid" in
        ''|*[!0-9]*) die "another valise process is running (unreadable lock)" ;;
      esac
      if ! "$_lock_kill_path" -0 "$_lock_pid" 2>/dev/null; then
        info "removing stale lock (pid $_lock_pid)"
        "$_lock_rm_path" -rf "$VALISE_LOCK_DIR" 2>/dev/null || die "failed to remove stale lock"
        if [ -e "$VALISE_LOCK_DIR" ] || [ -L "$VALISE_LOCK_DIR" ]; then
          die "failed to remove stale lock"
        fi
        "$_lock_mkdir_path" -m 700 "$VALISE_LOCK_DIR" 2>/dev/null || die "failed to acquire lock after stale cleanup"
      else
        die "another valise process is running (pid $_lock_pid)"
      fi
    else
      die "failed to acquire lock: $VALISE_LOCK_DIR"
    fi
  fi
  [ -d "$VALISE_LOCK_DIR" ] && [ ! -L "$VALISE_LOCK_DIR" ] || die "lock directory is not safe"
  printf '%s\n' "$$" > "$VALISE_LOCK_DIR/pid" || die "failed to write lock ownership"
  [ -f "$VALISE_LOCK_DIR/pid" ] && [ ! -L "$VALISE_LOCK_DIR/pid" ] || die "lock ownership file is not safe"
  _lock_pid=$("$_lock_cat_path" "$VALISE_LOCK_DIR/pid" 2>/dev/null || :)
  [ "$_lock_pid" = "$$" ] || die "failed to verify lock ownership"
  _lock_owned=1
}

remove_tree() {
  _remove_tree_path=$1
  _remove_chmod_path=$(trusted_utility_path chmod) || return 1
  _remove_rm_path=$(trusted_utility_path rm) || return 1
  if [ -d "$_remove_tree_path" ] && [ ! -L "$_remove_tree_path" ]; then
    "$_remove_chmod_path" -R u+w "$_remove_tree_path" 2>/dev/null || return 1
  fi
  "$_remove_rm_path" -rf "$_remove_tree_path" 2>/dev/null || return 1
  [ ! -e "$_remove_tree_path" ] && [ ! -L "$_remove_tree_path" ]
}

seal_tree() {
  _seal_tree_root=$1
  _find_path=$(trusted_utility_path find) || return 1
  _seal_chmod_path=$(trusted_utility_path chmod) || return 1
  "$_find_path" "$_seal_tree_root" -type d -exec "$_seal_chmod_path" 0555 {} + 2>/dev/null || return 1
  _seal_tree_dirs=$("$_find_path" "$_seal_tree_root" -type d -print) || return 1
  while IFS= read -r _seal_tree_dir; do
    [ -n "$_seal_tree_dir" ] || continue
    [ "$(file_mode "$_seal_tree_dir")" = "0555" ] || return 1
  done <<EOF
$_seal_tree_dirs
EOF
  return 0
}

release_lock() {
  _release_rm_path=$(trusted_utility_path rm 2>/dev/null || :)
  _release_rmdir_path=$(trusted_utility_path rmdir 2>/dev/null || :)
  if [ -n "$_publish_tmp" ]; then
    remove_tree "$_publish_tmp" || _cleanup_failed=1
    _publish_tmp=""
  fi
  if [ -n "$_manifest_rows" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_manifest_rows" 2>/dev/null || :
    if [ -e "$_manifest_rows" ] || [ -L "$_manifest_rows" ]; then _cleanup_failed=1; fi
    _manifest_rows=""
  fi
  if [ -n "$_manifest_parse" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_manifest_parse" 2>/dev/null || :
    if [ -e "$_manifest_parse" ] || [ -L "$_manifest_parse" ]; then _cleanup_failed=1; fi
    _manifest_parse=""
  fi
  if [ -n "${_pm_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_pm_tmp" 2>/dev/null || :
    if [ -e "$_pm_tmp" ] || [ -L "$_pm_tmp" ]; then _cleanup_failed=1; fi
    _pm_tmp=""
  fi
  if [ -n "${_rr_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_rr_tmp" 2>/dev/null || :
    if [ -e "$_rr_tmp" ] || [ -L "$_rr_tmp" ]; then _cleanup_failed=1; fi
    _rr_tmp=""
  fi
  if [ -n "${_pi_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_pi_tmp" 2>/dev/null || :
    if [ -e "$_pi_tmp" ] || [ -L "$_pi_tmp" ]; then _cleanup_failed=1; fi
    _pi_tmp=""
  fi
  if [ -n "${_eb_registry_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_eb_registry_tmp" 2>/dev/null || :
    if [ -e "$_eb_registry_tmp" ] || [ -L "$_eb_registry_tmp" ]; then _cleanup_failed=1; fi
    _eb_registry_tmp=""
  fi
  if [ -n "${_doctor_cand_file:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_doctor_cand_file" 2>/dev/null || :
    if [ -e "$_doctor_cand_file" ] || [ -L "$_doctor_cand_file" ]; then _cleanup_failed=1; fi
    _doctor_cand_file=""
  fi
  if [ -n "${_module_list_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_module_list_tmp" 2>/dev/null || :
    if [ -e "$_module_list_tmp" ] || [ -L "$_module_list_tmp" ]; then _cleanup_failed=1; fi
    _module_list_tmp=""
  fi
  if [ -n "${_rg_tmp:-}" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_rg_tmp" 2>/dev/null || :
    if [ -e "$_rg_tmp" ] || [ -L "$_rg_tmp" ]; then _cleanup_failed=1; fi
    _rg_tmp=""
  fi
  if [ -n "${_publish_previous:-}" ]; then
    # A publication that failed after moving the previous output aside left
    # it here; the error already named the output, so keep the tree for the
    # user rather than deleting the only copy.
    printf 'valise: previous output kept at %s\n' "$_publish_previous/tree" >&2
    _publish_previous=""
  fi
  if [ -n "$_stage" ]; then
    remove_tree "$_stage" || _cleanup_failed=1
    _stage=""
  fi
  if [ -n "$_hook_tmp" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_hook_tmp" 2>/dev/null || :
    if [ -e "$_hook_tmp" ] || [ -L "$_hook_tmp" ]; then _cleanup_failed=1; fi
    _hook_tmp=""
  fi
  if [ -n "$_mm_tmp" ]; then
    [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$_mm_tmp" 2>/dev/null || :
    if [ -e "$_mm_tmp" ] || [ -L "$_mm_tmp" ]; then _cleanup_failed=1; fi
    _mm_tmp=""
  fi
  [ "$_lock_owned" -eq 1 ] || { [ "$_cleanup_failed" -eq 0 ]; return; }
  [ -n "$_release_rm_path" ] && "$_release_rm_path" -f "$VALISE_LOCK_DIR/pid" 2>/dev/null || :
  if [ -e "$VALISE_LOCK_DIR/pid" ] || [ -L "$VALISE_LOCK_DIR/pid" ]; then _cleanup_failed=1; fi
  [ -n "$_release_rmdir_path" ] && "$_release_rmdir_path" "$VALISE_LOCK_DIR" 2>/dev/null || :
  if [ -e "$VALISE_LOCK_DIR" ] || [ -L "$VALISE_LOCK_DIR" ]; then _cleanup_failed=1; fi
  _lock_owned=0
  [ "$_cleanup_failed" -eq 0 ]
}

_handle_int() {
  trap - INT
  release_lock
  exit 130
}

_handle_term() {
  trap - TERM
  release_lock
  exit 143
}

trap '_exit_status=$?; release_lock; if [ "$_exit_status" -eq 0 ] && [ "$_cleanup_failed" -ne 0 ]; then _exit_status=1; fi; exit "$_exit_status"' EXIT
trap '_handle_int' INT
trap '_handle_term' TERM

switch_active_link() {
  _ln_path=$(trusted_utility_path ln) || die "no trusted ln utility available"
  _readlink_path=$(trusted_utility_path readlink) || die "no trusted readlink utility available"
  if [ -e "$VALISE_ACTIVE_LINK" ] && [ ! -L "$VALISE_ACTIVE_LINK" ]; then
    die "active path exists and is not a symlink: $VALISE_ACTIVE_LINK"
  fi
  # ln -sfn replaces the destination symlink. The -n flag prevents following a
  # destination that is a symlink to a directory. If the swap fails after the
  # old link was removed, restore the prior target so the pointer is never
  # left missing.
  _switch_old_target=
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _switch_old_target=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null || :)
  fi
  if ! "$_ln_path" -sfn "$1" "$VALISE_ACTIVE_LINK"; then
    if [ -n "$_switch_old_target" ]; then
      "$_ln_path" -sfn "$_switch_old_target" "$VALISE_ACTIVE_LINK" 2>/dev/null || :
    fi
    die "failed to update active symlink"
  fi
  [ -L "$VALISE_ACTIVE_LINK" ] || die "active symlink was not created"
  [ "$($_readlink_path "$VALISE_ACTIVE_LINK" 2>/dev/null)" = "$1" ] || die "active symlink target mismatch"
  unset _switch_old_target
}

source_path_is_physical() {
  _source_root=$1
  _source_relative=$2
  _source_path=$_source_root
  _source_remaining=$_source_relative
  while [ -n "$_source_remaining" ]; do
    case "$_source_remaining" in
      */*)
        _source_component=${_source_remaining%%/*}
        _source_remaining=${_source_remaining#*/}
        ;;
      *)
        _source_component=$_source_remaining
        _source_remaining=
        ;;
    esac
    [ -n "$_source_component" ] || return 1
    _source_path=$_source_path/$_source_component
    [ ! -L "$_source_path" ] || return 1
  done
  return 0
}

validate_manifest() {
  _awk_path=$(trusted_utility_path awk) || return 1
  "$_awk_path" -F '\t' '
    NR == 1 { if ($0 != "valise-manifest-v2") exit 10; next }
    NR == 2 { if ($1 != "destination" || $2 != "source" || $3 != "source_mode" || $4 != "install_mode" || $5 != "bytes" || $6 != "sha256" || NF != 6) exit 11; next }
    NF == 0 { next }
    NF != 6 || $1 == "" || $2 == "" || $1 !~ /^[A-Za-z0-9._\/-]+$/ || $2 !~ /^[A-Za-z0-9._\/-]+$/ || $1 ~ /^\// || $2 ~ /^\// || $1 ~ /\/$/ || $2 ~ /\/$/ || $1 ~ /^#/ || $1 == "destination" || $1 == "valise-manifest-v2" || $3 !~ /^0(644|755)$/ || $4 != (($3 == "0644") ? "0444" : "0555") || $5 !~ /^[0-9]+$/ || length($6) != 64 || $6 !~ /^[0-9a-fA-F]+$/ || $1 ~ /(^|\/)\.($|\/)/ || index($1, "//") || $1 ~ /(^|\/)\.\.($|\/)/ || index($2, "//") || $2 ~ /(^|\/)\.($|\/)/ || $2 ~ /(^|\/)\.\.($|\/)/ || seen[$1]++ || seen_source[$2]++ { exit 12 }
    { data_rows = 1 }
    END { if (NR < 3 || data_rows != 1) exit 13 }
  ' "$1"
}

temp_path_is_safe() {
  _temp_candidate=$1
  _temp_kind=$2
  _temp_root=${3:-${TMPDIR:-/tmp}}
  case "$_temp_root" in /*) ;; *) return 1 ;; esac
  case "$_temp_candidate" in /*) ;; *) return 1 ;; esac
  [ -e "$_temp_candidate" ] || return 1
  [ ! -L "$_temp_candidate" ] || return 1
  case "$_temp_kind" in
    file) [ -f "$_temp_candidate" ] || return 1 ;;
    dir) [ -d "$_temp_candidate" ] || return 1 ;;
    *) return 1 ;;
  esac
  _temp_root_canonical=$(cd "$_temp_root" 2>/dev/null && pwd -P) || return 1
  _temp_parent=${_temp_candidate%/*}
  [ "$_temp_parent" != "$_temp_candidate" ] || _temp_parent=/
  _temp_parent_canonical=$(cd "$_temp_parent" 2>/dev/null && pwd -P) || return 1
  case "$_temp_parent_canonical/" in
    "$_temp_root_canonical/"*) ;;
    *) return 1 ;;
  esac
  return 0
}

trusted_mktemp_at() {
  _temp_root=$1
  _temp_kind=$2
  _temp_template=$3
  _mktemp_path=$(trusted_utility_path mktemp) || return 1
  case "$_temp_kind" in
    file) _temp_candidate=$("$_mktemp_path" "$_temp_template") || return 1 ;;
    dir) _temp_candidate=$("$_mktemp_path" -d "$_temp_template") || return 1 ;;
    *) return 1 ;;
  esac
  temp_path_is_safe "$_temp_candidate" "$_temp_kind" "$_temp_root" || return 1
  printf '%s\n' "$_temp_candidate"
}

trusted_mktemp() {
  trusted_mktemp_at "${TMPDIR:-/tmp}" "$@"
}

prepare_manifest_rows() {
  _cleanup_rm_path=$(trusted_utility_path rm) || return 1
  if [ -n "$_manifest_rows" ]; then
    "$_cleanup_rm_path" -f "$_manifest_rows" 2>/dev/null || :
    _manifest_rows=""
  fi
  if [ -n "$_manifest_parse" ]; then
    "$_cleanup_rm_path" -f "$_manifest_parse" 2>/dev/null || :
    _manifest_parse=""
  fi
  # _manifest_rows is the exact private snapshot used for identity and
  # publication. Parsing is performed from a second file that only adds a
  # final newline, so an unterminated source row is still consumed by POSIX
  # read without changing the bytes whose digest defines the release.
  _manifest_rows=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-manifest.XXXXXX") || return 1
  _cat_path=$(trusted_utility_path cat) || {
    "$_cleanup_rm_path" -f "$_manifest_rows" 2>/dev/null || :
    _manifest_rows=""
    return 1
  }
  "$_cat_path" "$1" >"$_manifest_rows" || {
    "$_cleanup_rm_path" -f "$_manifest_rows" 2>/dev/null || :
    _manifest_rows=""
    return 1
  }
  _manifest_parse=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-manifest-parse.XXXXXX") || {
    "$_cleanup_rm_path" -f "$_manifest_rows" 2>/dev/null || :
    _manifest_rows=""
    return 1
  }
  _awk_path=$(trusted_utility_path awk) || {
    "$_cleanup_rm_path" -f "$_manifest_rows" "$_manifest_parse" 2>/dev/null || :
    _manifest_rows=""
    _manifest_parse=""
    return 1
  }
  "$_awk_path" '{ print }' "$_manifest_rows" >"$_manifest_parse" || {
    "$_cleanup_rm_path" -f "$_manifest_rows" "$_manifest_parse" 2>/dev/null || :
    _manifest_rows=""
    _manifest_parse=""
    return 1
  }
}

locate_manifest() {
  if [ -f "./manifest.tsv" ] && [ ! -L "./manifest.tsv" ]; then
    printf '%s\n' "./manifest.tsv"
    return 0
  fi
  return 1
}

_manifest_has_file() {
  _awk_path=$(trusted_utility_path awk) || return 1
  "$_awk_path" -F '\t' -v destination="$2" '
    NR > 2 && NF && $1 == destination { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

_manifest_has_descendant() {
  _awk_path=$(trusted_utility_path awk) || return 1
  "$_awk_path" -F '\t' -v prefix="$2/" '
    NR > 2 && NF && index($1, prefix) == 1 { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

verify_release_dir() {
  _verify_dir=$1
  _verify_manifest=$2
  _verify_canonical=$(cd "$_verify_dir" 2>/dev/null && pwd -P) || _verify_fail "cannot resolve release root" || return 1
  [ "$(file_mode "$_verify_dir")" = "0555" ] || _verify_fail "release root mode mismatch" || return 1
  _verify_snapshot="$_verify_dir/.valise-manifest"
  if [ -e "$_verify_snapshot" ] || [ -L "$_verify_snapshot" ]; then
    [ -f "$_verify_snapshot" ] || _verify_fail "release manifest snapshot is not a regular file" || return 1
    [ ! -L "$_verify_snapshot" ] || _verify_fail "release manifest snapshot must not be a symlink" || return 1
    [ "$(file_mode "$_verify_snapshot")" = "0444" ] || _verify_fail "release manifest snapshot mode mismatch" || return 1
    [ "$(file_bytes "$_verify_snapshot")" = "$(file_bytes "$_verify_manifest")" ] || _verify_fail "release manifest snapshot byte count mismatch" || return 1
    _verify_snapshot_digest=$(file_sha256 "$_verify_snapshot") || _verify_fail "no SHA-256 utility available" || return 1
    _verify_manifest_digest=$(file_sha256 "$_verify_manifest") || _verify_fail "no SHA-256 utility available" || return 1
    [ "$_verify_snapshot_digest" = "$_verify_manifest_digest" ] || _verify_fail "release manifest snapshot digest mismatch" || return 1
    _verify_expected_id="${3:-}"
    if [ -z "$_verify_expected_id" ]; then
      _verify_expected_id=$(basename "$_verify_dir")
    fi
    [ "$_verify_snapshot_digest" = "$_verify_expected_id" ] || _verify_fail "release manifest snapshot identity mismatch" || return 1
  fi
  while IFS="$(printf '\t')" read -r _dest _src _mode _imode _size _sha; do
    [ -n "$_dest" ] || continue
    case "$_dest" in valise-manifest-v2|destination) continue ;; esac
    _verify_file="$_verify_dir/$_dest"
    [ -f "$_verify_file" ] || _verify_fail "release file missing: $_dest" || return 1
    [ ! -L "$_verify_file" ] || _verify_fail "release file must not be a symlink: $_dest" || return 1
    _verify_parent=$(cd "$(path_parent "$_verify_file")" 2>/dev/null && pwd -P) || _verify_fail "release parent missing: $_dest" || return 1
    case "$_verify_parent/" in "$_verify_canonical/"*) : ;; *) _verify_fail "release path escapes target: $_dest" || return 1 ;; esac
    [ "$(file_mode "$_verify_file")" = "$_imode" ] || _verify_fail "release mode mismatch for $_dest" || return 1
    [ "$(file_bytes "$_verify_file")" = "$_size" ] || _verify_fail "release byte count mismatch for $_dest" || return 1
    case "$_sha" in *[!0123456789abcdefABCDEF]*) _verify_fail "invalid release digest for $_dest" || return 1 ;; esac
    [ "${#_sha}" -eq 64 ] || _verify_fail "invalid release digest for $_dest" || return 1
    _verify_actual=$(file_sha256 "$_verify_file") || _verify_fail "no trusted SHA-256 utility available" || return 1
    _verify_expected=$(printf '%s' "$_sha" | lower_hex) || _verify_fail "no trusted tr utility available" || return 1
    [ "$_verify_actual" = "$_verify_expected" ] || _verify_fail "release digest mismatch for $_dest" || return 1
  done < "${_manifest_parse:-$_manifest_rows}"
  _find_path=$(trusted_utility_path find) || _verify_fail "no trusted find utility available" || return 1
  _verify_bad=$("$_find_path" "$_verify_dir" -print | while IFS= read -r _verify_path; do
    [ "$_verify_path" = "$_verify_dir" ] && continue
    if [ -L "$_verify_path" ]; then
      printf '%s\n' "$_verify_path"
      break
    fi
    _verify_relative=${_verify_path#"$_verify_dir"/}
    [ "$_verify_relative" = ".valise-manifest" ] && continue
    if [ -f "$_verify_path" ]; then
      _manifest_has_file "$_verify_manifest" "$_verify_relative" || { printf '%s\n' "$_verify_path"; break; }
    elif [ -d "$_verify_path" ]; then
      if [ "$(file_mode "$_verify_path")" != "0555" ] || ! _manifest_has_descendant "$_verify_manifest" "$_verify_relative"; then
        printf '%s\n' "$_verify_path"
        break
      fi
    else
      printf '%s\n' "$_verify_path"
      break
    fi
  done)
  [ -z "$_verify_bad" ] || _verify_fail "release contains unmanifested or mutable path: $_verify_bad" || return 1
}


cmd_verify_release_root() {
  [ "$#" -eq 1 ] || die "usage: valise _verify-release-root <release-root>"
  _verify_release_arg=$1
  case "$_verify_release_arg" in
    /*) : ;;
    *) die "release root must be absolute" ;;
  esac
  [ -d "$_verify_release_arg" ] || die "release root is not a directory"
  [ ! -L "$_verify_release_arg" ] || die "release root must not be a symlink"
  _verify_release_canonical=$(cd "$_verify_release_arg" 2>/dev/null && pwd -P) || die "cannot resolve release root"
  _verify_releases_canonical=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) || die "release storage is unavailable"
  _verify_release_parent=$(cd "$(path_parent "$_verify_release_canonical")" 2>/dev/null && pwd -P) || die "release parent unavailable"
  [ "$_verify_release_parent" = "$_verify_releases_canonical" ] || die "release root escapes release storage"
  _verify_release_id=${_verify_release_canonical##*/}
  case "$_verify_release_id" in
    *[!0123456789abcdefABCDEF]*|'') die "release root identity is not a SHA-256 digest" ;;
  esac
  [ "${#_verify_release_id}" -eq 64 ] || die "release root identity is not a SHA-256 digest"
  _verify_release_snapshot="$_verify_release_canonical/.valise-manifest"
  [ -f "$_verify_release_snapshot" ] || die "release manifest snapshot is missing"
  [ ! -L "$_verify_release_snapshot" ] || die "release manifest snapshot must not be a symlink"
  prepare_manifest_rows "$_verify_release_snapshot" || die "cannot read release manifest snapshot"
  _verify_release_rows=$_manifest_rows
  validate_manifest "$_verify_release_rows" || die "invalid release manifest snapshot"
  verify_release_dir "$_verify_release_canonical" "$_verify_release_rows" "$_verify_release_id"
  printf '%s\n' "$_verify_release_canonical"
}

cmd_verify_active() {
  _verify_print_root=0
  for _verify_arg do
    case "$_verify_arg" in
      --print-root) _verify_print_root=1 ;;
      --help|-h) usage_release; return 0 ;;
      *) die "unknown release verify option: $_verify_arg" ;;
    esac
  done
  [ -L "$VALISE_ACTIVE_LINK" ] || die "active pointer is not a symlink"
  _verify_active_target=$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null) || die "cannot read active pointer"
  case "$_verify_active_target" in
    /*) : ;;
    *)
      _verify_active_link_parent=$(cd "$(path_parent "$VALISE_ACTIVE_LINK")" 2>/dev/null && pwd -P) || die "active pointer parent unavailable"
      _verify_active_target="$_verify_active_link_parent/$_verify_active_target"
      ;;
  esac
  [ -d "$_verify_active_target" ] || die "active release target is not a directory"
  _verify_active_root=$(cd "$_verify_active_target" 2>/dev/null && pwd -P) || die "cannot resolve active release root"
  _verify_releases_root=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) || die "release root unavailable"
  _verify_active_parent=$(cd "$(path_parent "$_verify_active_root")" 2>/dev/null && pwd -P) || die "active release parent unavailable"
  [ "$_verify_active_parent" = "$_verify_releases_root" ] || die "active release escapes release root"
  _verify_active_id=${_verify_active_root##*/}
  case "$_verify_active_id" in
    *[!0123456789abcdefABCDEF]*|'') die "active release identity is not a SHA-256 digest" ;;
  esac
  [ "${#_verify_active_id}" -eq 64 ] || die "active release identity is not a SHA-256 digest"
  _verify_active_manifest="$_verify_active_root/.valise-manifest"
  [ -f "$_verify_active_manifest" ] || die "active release manifest is missing"
  [ ! -L "$_verify_active_manifest" ] || die "active release manifest must not be a symlink"
  prepare_manifest_rows "$_verify_active_manifest" || die "cannot read active release manifest"
  _verify_active_manifest_rows="$_manifest_rows"
  validate_manifest "$_verify_active_manifest_rows" || die "invalid active release manifest"
  verify_release_dir "$_verify_active_root" "$_verify_active_manifest_rows" "$_verify_active_id"
  if [ "$_verify_print_root" -eq 1 ]; then
    printf '%s\n' "$_verify_active_root"
  fi
  return 0
}
cmd_release() {
  _subcmd="${1:-list}"
  case "$_subcmd" in
    --help|-h) usage_release; return 0 ;;
    list)
      case "${2:-}" in
        --help|-h) usage_release; return 0 ;;
      esac
      if [ -d "$VALISE_RELEASES_DIR" ]; then
        _list_active_id=$(active_release_id 2>/dev/null || :)
        for _rel in "$VALISE_RELEASES_DIR"/*/; do
          [ -d "$_rel" ] || continue
          _name=$(basename "$_rel")
          if [ -n "$_list_active_id" ] && [ "$_name" = "$_list_active_id" ]; then
            printf '* %s (active)\n' "$_name"
          else
            printf '  %s\n' "$_name"
          fi
        done
        unset _list_active_id
      else
        info "no releases installed"
      fi
      ;;
    use)
      case "${2:-}" in
        --help|-h) usage_release; return 0 ;;
      esac
      _target="${2:-}"
      [ -n "$_target" ] || die "usage: valise release use <sha256>"
      case "$_target" in
        *[!A-Za-z0-9_.-]*|.*|*-|.-*|*..*) die "invalid release name: $_target" ;;
      esac
      _target_dir="$VALISE_RELEASES_DIR/$_target"
      [ -e "$_target_dir" ] || die "release not found: $_target"
      [ -d "$_target_dir" ] || die "release target is not a directory: $_target"
      [ ! -L "$_target_dir" ] || die "release target must not be a symlink: $_target"
      _releases_root=$(cd "$VALISE_RELEASES_DIR" 2>/dev/null && pwd -P) || die "release root unavailable"
      _target_parent=$(cd "$(path_parent "$_target_dir")" 2>/dev/null && pwd -P) || die "release target parent unavailable"
      case "$_target_parent/" in
        "$_releases_root/"*) : ;;
        *) die "release target escapes release root: $_target" ;;
      esac
      _target_manifest="$_target_dir/.valise-manifest"
      if [ -e "$_target_manifest" ] || [ -L "$_target_manifest" ]; then
        [ -f "$_target_manifest" ] || die "release manifest snapshot is not a regular file"
        [ ! -L "$_target_manifest" ] || die "release manifest snapshot must not be a symlink"
        _manifest="$_target_manifest"
      else
        _manifest=$(locate_manifest) ||
          die "cannot find manifest.tsv in the current directory"
      fi
      prepare_manifest_rows "$_manifest" || die "cannot snapshot manifest.tsv"
      _manifest="$_manifest_rows"
      validate_manifest "$_manifest" || die "invalid manifest.tsv schema or row"
      verify_release_dir "$_target_dir" "$_manifest" "$_target"
      _config_parent=$(path_parent "$VALISE_ACTIVE_LINK")
      if [ ! -d "$_config_parent" ]; then
        _mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
        "$_mkdir_path" -p "$_config_parent"
      fi
      acquire_lock
      switch_active_link "$_target_dir"
      release_lock
      info "switched to release $_target"
      ;;
    prune)
      shift
      _prune_keep=3
      _prune_keep_set=0
      for _prune_arg do
        case "$_prune_arg" in
          --keep=*)
            _prune_keep_set=1
            _prune_keep=${_prune_arg#--keep=}
            case "$_prune_keep" in
              '' | *[!0-9]*) die "--keep requires a non-negative integer: $_prune_keep" ;;
            esac
            # Strip leading zeros so the shell does not read the value as
            # octal in the arithmetic comparison below, and so the digit
            # count measures the value rather than its spelling.
            while [ "$_prune_keep" != "0" ] && [ "${_prune_keep#0}" != "$_prune_keep" ]; do
              _prune_keep=${_prune_keep#0}
            done
            # A value beyond the shell's integer range makes the comparison
            # below fail, which would read as "keep nothing" and remove every
            # release. Reject it instead. Nine digits is the bound: every
            # nine-digit value fits in a signed 32-bit integer, so no
            # lexicographic comparison against the maximum is needed.
            if [ "${#_prune_keep}" -gt 9 ]; then
              die "--keep is too large: $_prune_keep (maximum is 999999999)"
            fi
            ;;
          --help|-h) usage_release; return 0 ;;
          *) die "unknown release prune option: $_prune_arg" ;;
        esac
      done
      [ -d "$VALISE_RELEASES_DIR" ] || die "no releases installed"
      # The active release is identified by its canonical directory name, not
      # by a path spelling. A trailing slash, a relative target, or an alias
      # symlink must never make prune delete the release the pointer names.
      _prune_active_id=$(active_release_id 2>/dev/null || :)
      _prune_active=$_prune_active_id
      # Collect the candidate releases with their modification times. The
      # active release is excluded here and kept unconditionally below.
      _prune_sort=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-prune.XXXXXX") ||
        die "cannot create prune staging file"
      for _prune_rel in "$VALISE_RELEASES_DIR"/*/; do
        [ -d "$_prune_rel" ] || continue
        [ ! -L "$_prune_rel" ] || continue
        _prune_dir=${_prune_rel%/}
        _prune_name=${_prune_dir##*/}
        [ "$_prune_name" = "$_prune_active_id" ] && continue
        _prune_mtime=$(file_mtime "$_prune_dir") || _prune_mtime=0
        printf '%s\t%s\n' "$_prune_mtime" "$_prune_name" >>"$_prune_sort"
      done
      _prune_sort_path=$(trusted_utility_path sort) || die "no trusted sort utility available"
      _prune_sorted=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-prune-sorted.XXXXXX") ||
        die "cannot create prune ordering file"
      # Newest first; equal timestamps fall back to the release name so the
      # ordering is deterministic.
      "$_prune_sort_path" -k1,1nr -k2,2 "$_prune_sort" >"$_prune_sorted" ||
        die "cannot order releases for pruning"
      _prune_index=0
      _prune_removed=0
      _prune_kept=0
      while IFS="$(printf '\t')" read -r _prune_mtime _prune_name; do
        [ -n "$_prune_name" ] || continue
        _prune_index=$((_prune_index + 1))
        if [ "$_prune_index" -le "$_prune_keep" ]; then
          _prune_kept=$((_prune_kept + 1))
          continue
        fi
        _prune_target="$VALISE_RELEASES_DIR/$_prune_name"
        # A release is only removed after it verifies against its own
        # manifest. A corrupted release is kept, never deleted, so a damaged
        # installation can still be inspected and repaired.
        _prune_manifest="$_prune_target/.valise-manifest"
        if [ ! -f "$_prune_manifest" ] || [ -L "$_prune_manifest" ]; then
          info "keeping unverifiable release $_prune_name (no manifest snapshot)"
          _prune_kept=$((_prune_kept + 1))
          continue
        fi
        if ! prepare_manifest_rows "$_prune_manifest" ||
           ! validate_manifest "$_manifest_rows"; then
          info "keeping unverifiable release $_prune_name (invalid manifest)"
          _prune_kept=$((_prune_kept + 1))
          continue
        fi
        _verify_quiet=1
        if ! verify_release_dir "$_prune_target" "$_manifest_rows" "$_prune_name"; then
          _verify_quiet=0
          info "keeping unverifiable release $_prune_name (failed verification)"
          _prune_kept=$((_prune_kept + 1))
          continue
        fi
        _verify_quiet=0
        acquire_lock
        if remove_tree "$_prune_target"; then
          _prune_removed=$((_prune_removed + 1))
          info "removed release $_prune_name"
        else
          info "keeping release $_prune_name (could not be removed)"
          _prune_kept=$((_prune_kept + 1))
        fi
        release_lock
      done <"$_prune_sorted"
      _prune_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
      "$_prune_rm" -f "$_prune_sort" "$_prune_sorted" || die "cannot remove prune staging files"
      if [ -n "$_prune_active" ]; then
        info "prune kept the active release plus $_prune_kept other release(s); removed $_prune_removed"
      else
        info "prune kept $_prune_kept release(s); removed $_prune_removed (no active release)"
      fi
      ;;
    verify)
      if [ "$#" -gt 0 ]; then
        shift
      fi
      cmd_verify_active "$@"
      ;;
    *)
      die "unknown release subcommand: $_subcmd (use list, use, prune, or verify)"
      ;;
  esac
}

cmd_install() {
  _install_integration=1
  for _arg do
    case "$_arg" in
      --help|-h) usage_install; return 0 ;;
      --no-integration) _install_integration=0 ;;
      *) die "unknown install option: $_arg (usage: valise install [--no-integration])" ;;
    esac
  done

  _manifest_source=$(locate_manifest) ||
    die "cannot find manifest.tsv in the current directory (run valise install from a release tree built by valise build)"
  _manifest_root=$(cd "$(path_parent "$_manifest_source")" && pwd -P) || die "cannot resolve manifest source root"
  prepare_manifest_rows "$_manifest_source" || die "cannot normalize manifest.tsv"
  _manifest="$_manifest_rows"
  validate_manifest "$_manifest" || die "invalid manifest.tsv schema or row"

  # Release identity is content-derived; the schema header is not an ID.
  _release_id=$(file_sha256 "$_manifest") || die "no trusted SHA-256 utility available"
  case "$_release_id" in
    *[!0123456789abcdefABCDEF]*|'') die "invalid release ID derived from manifest" ;;
  esac
  [ "${#_release_id}" -eq 64 ] || die "invalid release ID derived from manifest"

  _target_dir="$VALISE_RELEASES_DIR/$_release_id"

  acquire_lock
  _mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _chmod_path=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_mkdir_path" -p "$VALISE_XDG_CONFIG" "$VALISE_XDG_STATE" || die "cannot create valise configuration directories"
  [ ! -L "$_target_dir" ] || die "release target must not be a symlink: $_release_id"

  if [ -e "$_target_dir" ] && [ ! -d "$_target_dir" ]; then
    die "release path is not a directory: $_target_dir"
  fi
  if [ -d "$_target_dir" ]; then
    _target_manifest="$_target_dir/.valise-manifest"
    if [ -e "$_target_manifest" ] || [ -L "$_target_manifest" ]; then
      [ -f "$_target_manifest" ] || die "release manifest snapshot is not a regular file"
      [ ! -L "$_target_manifest" ] || die "release manifest snapshot must not be a symlink"
      prepare_manifest_rows "$_target_manifest" || die "cannot snapshot release manifest"
      _target_manifest="$_manifest_rows"
      validate_manifest "$_target_manifest" || die "invalid release manifest snapshot"
      verify_release_dir "$_target_dir" "$_target_manifest" "$_release_id"
    else
      verify_release_dir "$_target_dir" "$_manifest" "$_release_id"
    fi
    info "release $_release_id already installed and verified"
  else
    info "installing release $_release_id..."

    # Create target directories
    "$_mkdir_path" -p "$VALISE_RELEASES_DIR" "$VALISE_XDG_CONFIG" "$VALISE_XDG_STATE"

    # Stage into temp directory first
    _stage=$(trusted_mktemp dir "${TMPDIR:-/tmp}/valise-install.XXXXXX") || die "cannot create staging directory"
    _cp_path=$(trusted_utility_path cp) || die "no trusted cp utility available"
    "$_cp_path" -p "$_manifest" "$_stage/.valise-manifest" || die "failed to stage release manifest"
    "$_chmod_path" 0444 "$_stage/.valise-manifest" || die "failed to seal release manifest"

    # Copy release files from manifest
    # The manifest format is: destination source mode install_mode size sha256
    while IFS="$(printf '\t')" read -r _dest _src _mode _imode _size _sha; do
      [ -n "$_dest" ] || continue
      case "$_dest" in \#*|valise-manifest-v2|destination) continue ;; esac
      case "$_src" in
        ""|.|./*|*/.|*/./*|*//*|/*|*/../*|../*|*/..|..*) die "invalid manifest source path: $_src" ;;
      esac
      case "$_dest" in
        ""|.|./*|*/.|*/./*|*//*|/*|*/../*|../*|*/..|..*) die "invalid manifest destination path: $_dest" ;;
      esac
      _src_path="$_manifest_root/$_src"
      _dest_path="$_stage/$_dest"
      [ -f "$_src_path" ] || die "manifest source missing: $_src"
      source_path_is_physical "$_manifest_root" "$_src" || die "manifest source path contains a symlink: $_src"
      [ ! -L "$_src_path" ] || die "manifest source must not be a symlink: $_src"
      _src_parent=$(cd "$(path_parent "$_src_path")" 2>/dev/null && pwd -P) || die "manifest source parent missing: $_src"
      case "$_src_parent/" in
        "$_manifest_root/"*) : ;;
        *) die "manifest source escapes source root: $_src" ;;
      esac
      [ "$(file_mode "$_src_path")" = "$_mode" ] || die "manifest source mode mismatch: $_src"
      [ "$(file_bytes "$_src_path")" = "$_size" ] || die "manifest source byte count mismatch: $_src"
      case "$_mode:$_imode" in
        0644:0444|0755:0555) : ;;
        *) die "invalid immutable mode pair for $_dest" ;;
      esac
      [ -n "$_sha" ] || die "manifest digest missing: $_dest"
      case "$_sha" in
        *[!0123456789abcdefABCDEF]*) die "invalid manifest digest for $_dest" ;;
      esac
      [ "${#_sha}" -eq 64 ] || die "invalid manifest digest for $_dest"
      _dest_parent=$(path_parent "$_dest_path")
      "$_mkdir_path" -p "$_dest_parent"
      "$_cp_path" -p "$_src_path" "$_dest_path" || die "failed to copy $_src"
      "$_chmod_path" "$_imode" "$_dest_path" || die "failed to seal $_dest"
    done < "${_manifest_parse:-$_manifest_rows}"

    # Verify staged files against manifest digests
    _verify_ok=1
    while IFS="$(printf '\t')" read -r _dest _src _mode _imode _size _sha; do
      [ -n "$_dest" ] || continue
      case "$_dest" in \#*|valise-manifest-v2|destination) continue ;; esac
      case "$_dest" in
        ""|.|./*|*/.|*/./*|*//*|/*|*/../*|../*|*/..|..*) die "invalid manifest destination path: $_dest" ;;
      esac
      _staged_file="$_stage/$_dest"
      [ -f "$_staged_file" ] || die "staged manifest file missing: $_dest"
      [ "$(file_mode "$_staged_file")" = "$_imode" ] || die "staged install mode mismatch: $_dest"
      [ "$(file_bytes "$_staged_file")" = "$_size" ] || die "staged byte count mismatch: $_dest"
      [ -n "$_sha" ] || die "manifest digest missing: $_dest"
      case "$_sha" in
        *[!0123456789abcdefABCDEF]*) die "invalid manifest digest for $_dest" ;;
      esac
      [ "${#_sha}" -eq 64 ] || die "invalid manifest digest for $_dest"
      _actual=$(file_sha256 "$_staged_file") || die "no trusted SHA-256 utility available"
      _expected=$(printf '%s' "$_sha" | lower_hex) || die "no trusted tr utility available"
      if [ "$_actual" != "$_expected" ]; then
        die "digest mismatch for $_dest: expected $_sha got $_actual"
      fi
    done < "${_manifest_parse:-$_manifest_rows}"

    # Seal all release directories; files already received their declared
    # immutable mode while being staged. Never publish an incompletely sealed
    # tree.
    seal_tree "$_stage" || die "failed to seal release directories"

    # Publish through a temporary sibling, then atomically rename the
    # complete immutable tree into place. The EXIT/signal cleanup removes any
    # incomplete sibling before it can poison this release ID.
    _publish_tmp="$VALISE_RELEASES_DIR/.valise-release.$_release_id.$$"
    [ ! -e "$_publish_tmp" ] && [ ! -L "$_publish_tmp" ] || die "release publication temporary path already exists"
    "$_cp_path" -rp "$_stage" "$_publish_tmp" || die "failed to publish release"
    seal_tree "$_publish_tmp" || die "failed to seal published release"
    verify_release_dir "$_publish_tmp" "$_manifest" "$_release_id"
    [ ! -e "$_target_dir" ] && [ ! -L "$_target_dir" ] || die "release target appeared during publication"
    _mv_path=$(trusted_utility_path mv) || die "no trusted mv utility available"
    "$_mv_path" "$_publish_tmp" "$_target_dir" || die "failed to publish release"
    _publish_tmp=""
    [ -d "$_target_dir" ] || die "published release directory is missing"
    verify_release_dir "$_target_dir" "$_manifest" "$_release_id"
    remove_tree "$_stage" || die "failed to remove staging directory"
    _stage=""
    info "release $_release_id installed"
  fi

  # Update active symlink atomically without clobbering a non-symlink path.
  if [ ! -L "$VALISE_ACTIVE_LINK" ] || [ "$(readlink_target "$VALISE_ACTIVE_LINK" 2>/dev/null)" != "$_target_dir" ]; then
    if [ -e "$VALISE_ACTIVE_LINK" ] && [ ! -L "$VALISE_ACTIVE_LINK" ]; then
      die "active path exists and is not a symlink: $VALISE_ACTIVE_LINK"
    fi
    switch_active_link "$_target_dir"
    info "active release set to $_release_id"
  fi

  # Deploy the Fish conf.d hook when Fish is available. A built release has no
  # Fish surface; an engine release exposes the project Fish entrypoint, so the
  # emitted integration handles that shape.
  _fish_path=$(trusted_utility_path fish 2>/dev/null || :)
  if [ "$_install_integration" -eq 1 ] && [ -n "$_fish_path" ]; then
    _fish_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
    _fish_hook="$_fish_conf_dir/valise.fish"
    _mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
    "$_mkdir_path" -p "$_fish_conf_dir" || die "cannot create Fish configuration directory"
    [ ! -L "$_fish_hook" ] || die "Fish hook path must not be a symlink: $_fish_hook"
    if [ -d "$_fish_hook" ]; then
      die "Fish hook path is a directory: $_fish_hook"
    fi
    # Use the platform mktemp in the destination directory. Its exclusive
    # creation makes a pre-created predictable symlink unable to redirect the
    # shell redirection below into an attacker-selected victim.
    _hook_tmp=$(trusted_mktemp_at "$_fish_conf_dir" file "$_fish_conf_dir/.valise-hook.XXXXXX") || die "cannot create Fish hook staging file"
    [ -f "$_hook_tmp" ] && [ ! -L "$_hook_tmp" ] || die "Fish hook staging path is unsafe"
    print_fish_integration >"$_hook_tmp" || die "cannot write Fish hook"
    _chmod_path=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
    "$_chmod_path" 0644 "$_hook_tmp" || die "cannot set Fish hook mode"
    _cat_path=$(trusted_utility_path cat) || die "no trusted cat utility available"
    _hook_expected=$("$_cat_path" "$_hook_tmp") || die "cannot read Fish hook staging file"
    _mv_path=$(trusted_utility_path mv) || die "no trusted mv utility available"
    # mv -f uses rename(2) which atomically replaces a regular file
    # destination on both BSD and GNU systems. The hook path was verified
    # non-symlink above, so no explicit removal is needed — mv -f alone
    # preserves atomicity.
    "$_mv_path" -f "$_hook_tmp" "$_fish_hook" || die "cannot publish Fish hook"
    _hook_tmp=""
    [ -f "$_fish_hook" ] || die "Fish hook was not published"
    [ "$(file_mode "$_fish_hook")" = 0644 ] || die "Fish hook mode mismatch"
    _hook_actual=$("$_cat_path" "$_fish_hook") || die "cannot read published Fish hook"
    [ "$_hook_actual" = "$_hook_expected" ] || die "published Fish hook contents mismatch"
    info "Fish hook deployed: $_fish_hook"
    info "remove this file to uninstall the Fish integration"
  fi

  if [ "$_install_integration" -eq 1 ]; then
    write_posix_integration
  fi

  release_lock
  info "installation complete"
  info "run 'valise init' to print the shell integration snippet for manual setup"
}

cmd_make_manifest() {
  _mm_tree=""
  _mm_out=""
  _mm_want_out=0
  for _mm_arg do
    case "$_mm_arg" in
      --output) _mm_want_out=1 ;;
      --output=*)
        _mm_out=${_mm_arg#--output=}
        [ -n "$_mm_out" ] || die "usage: valise make-manifest <tree> [--output <file>]"
        ;;
      --help|-h) printf '%s\n' "usage: valise make-manifest <tree> [--output <file>]"; return 0 ;;
      --*) die "unknown make-manifest option: $_mm_arg" ;;
      *)
        if [ "$_mm_want_out" -eq 1 ]; then
          _mm_out=$_mm_arg
          _mm_want_out=0
        elif [ -n "$_mm_tree" ]; then
          die "usage: valise make-manifest <tree> [--output <file>]"
        else
          _mm_tree=$_mm_arg
        fi
        ;;
    esac
  done
  [ "$_mm_want_out" -eq 0 ] || die "usage: valise make-manifest <tree> [--output <file>]"
  [ -n "$_mm_tree" ] || die "usage: valise make-manifest <tree> [--output <file>]"
  [ -d "$_mm_tree" ] || die "manifest tree is not a directory: $_mm_tree"
  _mm_root=$(cd "$_mm_tree" && pwd -P) || die "cannot resolve manifest tree: $_mm_tree"
  _mm_default_out="$_mm_root/manifest.tsv"
  if [ -z "$_mm_out" ]; then
    _mm_out="$_mm_default_out"
  fi
  case "$_mm_out" in
    /*) : ;;
    *)
      while :; do
        case "$_mm_out" in
          ./*) _mm_out=${_mm_out#./} ;;
          *) break ;;
        esac
      done
      _mm_cwd=$(pwd -P) || die "cannot resolve working directory"
      _mm_out="$_mm_cwd/$_mm_out"
      ;;
  esac
  _mm_out=$(path_normalize "$_mm_out") || die "cannot normalize manifest output path"
  _mm_out_dir=$(path_parent "$_mm_out") || die "cannot resolve manifest parent"
  _mm_mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_mm_mkdir_path" -p "$_mm_out_dir" || die "cannot create manifest directory: $_mm_out_dir"
  # Resolve the parent physically: find reports physical paths, and /tmp is a
  # symlink to /private/tmp on macOS. A lexical comparison would include the
  # manifest in itself on the second run.
  _mm_out_dir=$(cd "$_mm_out_dir" && pwd -P) || die "cannot resolve manifest parent: $_mm_out_dir"
  _mm_out="$_mm_out_dir/${_mm_out##*/}"
  if [ -e "$_mm_out" ] || [ -L "$_mm_out" ]; then
    [ -f "$_mm_out" ] && [ ! -L "$_mm_out" ] ||
      die "manifest output is not a regular file: $_mm_out"
  fi
  _mm_find_path=$(trusted_utility_path find) || die "no trusted find utility available"
  _mm_sort_path=$(trusted_utility_path sort) || die "no trusted sort utility available"
  # Symlinks never enter a sealed release: find without -L reports them as
  # -type l, so any symlink anywhere under the tree fails closed here.
  _mm_links=$("$_mm_find_path" "$_mm_root" -type l -print) || die "cannot scan manifest tree: $_mm_root"
  [ -z "$_mm_links" ] || die "manifest tree must not contain symlinks: $_mm_root"
  _mm_list=$("$_mm_find_path" "$_mm_root" -type f -print) || die "cannot list manifest tree: $_mm_root"
  _mm_tmp=$(trusted_mktemp_at "$_mm_out_dir" file "$_mm_out_dir/.valise-manifest.XXXXXX") || die "cannot stage manifest"
  _mm_tab=$(printf '\t')
  _mm_nl='
'
  _mm_count=0
  printf '%s\n' "valise-manifest-v2" >"$_mm_tmp" || die "cannot write manifest"
  printf 'destination\tsource\tsource_mode\tinstall_mode\tbytes\tsha256\n' >>"$_mm_tmp" || die "cannot write manifest"
  _mm_sorted=$(printf '%s\n' "$_mm_list" | LC_ALL=C "$_mm_sort_path") || die "cannot sort manifest tree listing"
  while IFS= read -r _mm_full || [ -n "$_mm_full" ]; do
    [ -n "$_mm_full" ] || continue
    # The manifest describes the tree payload, never itself: both the
    # requested output and the default output path stay out of the rows so
    # consecutive runs over an unchanged tree are byte-identical.
    [ "$_mm_full" != "$_mm_out" ] || continue
    [ "$_mm_full" != "$_mm_default_out" ] || continue
    [ "$_mm_full" != "$_mm_tmp" ] || continue
    _mm_rel=${_mm_full#"$_mm_root"/}
    # Same name rules as validate_manifest: the schema charset plus no
    # tab/newline (row delimiters) and no dot segments. Anything else
    # fails here naming the file instead of at validation time.
    case "$_mm_rel" in
      *"$_mm_nl"*|*"$_mm_tab"*|*[!A-Za-z0-9._/-]*|"#"*|.|..|./*|../*|*/.|*/..|*/./*|*/../*) die "manifest tree file has an unrepresentable name: $_mm_full" ;;
    esac
    _mm_mode=$(file_mode "$_mm_full") || die "cannot read file mode: $_mm_full"
    case "$_mm_mode" in
      0644) _mm_imode=0444 ;;
      0755) _mm_imode=0555 ;;
      *) die "manifest tree file has unsupported mode $_mm_mode (normalize to 0644 or 0755): $_mm_full" ;;
    esac
    _mm_bytes=$(file_bytes "$_mm_full") || die "cannot read file size: $_mm_full"
    _mm_sha=$(file_sha256 "$_mm_full") || die "no trusted SHA-256 utility available"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_mm_rel" "$_mm_rel" "$_mm_mode" "$_mm_imode" "$_mm_bytes" "$_mm_sha" >>"$_mm_tmp" || die "cannot write manifest"
    _mm_count=$((_mm_count + 1))
  done <<_MM_SORTED_EOF
$_mm_sorted
_MM_SORTED_EOF
  [ "$_mm_count" -gt 0 ] || die "manifest tree contains no files: $_mm_root"
  validate_manifest "$_mm_tmp" || die "generated manifest failed validation"
  _mm_mv_path=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_mm_mv_path" -f "$_mm_tmp" "$_mm_out" || die "cannot publish manifest: $_mm_out"
  _mm_chmod_path=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_mm_chmod_path" 0644 "$_mm_out" || die "cannot set manifest mode: $_mm_out"
  _mm_tmp=""
  info "manifest written: $_mm_out ($_mm_count files)"
}
