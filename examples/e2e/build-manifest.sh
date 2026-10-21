#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# build-manifest.sh: vendor engine files into the e2e release tree and
# generate a profile-release.manifest with correct sizes and SHA-256 digests.
#
# Usage: run from any directory. The script resolves paths relative to itself.
# Output: shell/install/profile-release.manifest (overwritten each run).

set -eu

_script_dir=$(cd "$(dirname "$0")" && pwd -P)
_repo_root=$(cd "$_script_dir/../.." && pwd -P)
_e2e_root="$_script_dir"

# --- Locate SHA-256 utility ---
# Match bin/valise fallback chain: sha256sum, shasum -a 256, sha256 (BSD).
_sha_cmd=""
if command -v sha256sum >/dev/null 2>&1; then
  _sha_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  _sha_cmd="shasum"
elif command -v sha256 >/dev/null 2>&1; then
  _sha_cmd="sha256"
else
  printf 'ERROR: no SHA-256 utility found (need sha256sum, shasum, or sha256)\n' >&2
  exit 1
fi

file_sha256() {
  _sha_output=""
  if [ "$_sha_cmd" = "sha256sum" ]; then
    _sha_output=$(sha256sum "$1")
  elif [ "$_sha_cmd" = "shasum" ]; then
    _sha_output=$(shasum -a 256 "$1")
  else
    _sha_output=$(sha256 "$1")
  fi
  # BSD sha256 prints "SHA256 (filename) = digest"; sha256sum/shasum print
  # "digest  filename". Gate the BSD strip behind the SHA256 ( prefix to
  # avoid corrupting output when the filename contains "= ".
  case "$_sha_output" in
    "SHA256 ("*) _sha_output=${_sha_output##* = } ;;
  esac
  _sha_output=${_sha_output%% *}
  _sha_output=${_sha_output%%$(printf '\t')*}
  printf '%s\n' "$_sha_output"
}

file_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

# --- Vendor engine files ---
# These are copies of the engine source that form the release payload.
# They are NOT committed (see .gitignore); this script regenerates them.

_vendor_copy() {
  _src="$_repo_root/$1"
  _dst="$_e2e_root/$1"
  _dst_dir=$(dirname "$_dst")
  [ -f "$_src" ] || { printf 'ERROR: engine source missing: %s\n' "$_src" >&2; exit 1; }
  mkdir -p "$_dst_dir"
  cp "$_src" "$_dst"
  chmod 0644 "$_dst"
}

printf 'Vendoring engine files from %s...\n' "$_repo_root"

# Core libraries
_vendor_copy lib/metadata.sh
_vendor_copy lib/loader.sh
_vendor_copy lib/capabilities.sh
_vendor_copy lib/compiler.awk

# Fish libraries
_vendor_copy lib/fish/loader.fish
_vendor_copy lib/fish/metadata.fish

# Generic Fish entrypoint adapter (sourced by the generated Fish
# integration after it authenticates the active release)
_vendor_copy entrypoints/fish/profile.fish

# Entrypoint
_vendor_copy entrypoints/profile.sh

# Platform module metadata
_vendor_copy module.d/platform_posix.meta
_vendor_copy module.d/platform_macos.meta
_vendor_copy module.d/platform_linux.meta
_vendor_copy module.d/platform_bsd.meta

# Platform module bodies
_vendor_copy modules/platform/posix.sh
_vendor_copy modules/platform/macos/capabilities.sh
_vendor_copy modules/platform/linux/capabilities.sh
_vendor_copy modules/platform/bsd/capabilities.sh

# Shareable engine catalog (ships in every release built from this engine)
_engine_contrib_count=0
for _contrib_src in "$_repo_root"/module.d/contrib_*.meta; do
  [ -f "$_contrib_src" ] || continue
  _vendor_copy "module.d/$(basename "$_contrib_src")"
  _engine_contrib_count=$((_engine_contrib_count + 1))
done
for _contrib_src in "$_repo_root"/modules/system/contrib_*.sh; do
  [ -f "$_contrib_src" ] || continue
  _vendor_copy "modules/system/$(basename "$_contrib_src")"
  _engine_contrib_count=$((_engine_contrib_count + 1))
done
if [ "$_engine_contrib_count" -eq 0 ]; then
  printf 'ERROR: no shareable engine modules found in %s\n' "$_repo_root" >&2
  exit 1
fi

# --- Vendor shared layer (cross-repo composition) ---
# The provider tree at examples/shared simulates a version-pinned external
# repository. Its files are copied under layer/shared/ so the release keeps
# provider bytes separate from consumer bytes while one manifest covers the
# whole closure. layer-pin.txt records the pinned provider revision.

_shared_src="$_repo_root/examples/shared"
_shared_dst="$_e2e_root/layer/shared"
[ -d "$_shared_src/module.d" ] || { printf 'ERROR: shared provider missing: %s\n' "$_shared_src" >&2; exit 1; }
mkdir -p "$_shared_dst/module.d" "$_shared_dst/modules"
for _shared_meta in "$_shared_src"/module.d/*.meta; do
  [ -f "$_shared_meta" ] || { printf 'ERROR: no shared provider metadata in %s\n' "$_shared_src/module.d" >&2; exit 1; }
  cp "$_shared_meta" "$_shared_dst/module.d/"
  chmod 0644 "$_shared_dst/module.d/$(basename "$_shared_meta")"
done
for _shared_area in "$_shared_src"/modules/*; do
  [ -d "$_shared_area" ] || continue
  mkdir -p "$_shared_dst/modules/$(basename "$_shared_area")"
  for _shared_body in "$_shared_area"/*.sh; do
    [ -f "$_shared_body" ] || continue
    cp "$_shared_body" "$_shared_dst/modules/$(basename "$_shared_area")/"
    chmod 0644 "$_shared_dst/modules/$(basename "$_shared_area")/$(basename "$_shared_body")"
  done
done
_shared_rev=$(cd "$_shared_src" && git rev-parse HEAD 2>/dev/null || printf 'unknown')
printf 'provider=examples/shared\nrevision=%s\n' "$_shared_rev" > "$_shared_dst/layer-pin.txt"
chmod 0644 "$_shared_dst/layer-pin.txt"
printf 'Vendored shared layer from %s (revision %s)\n' "$_shared_src" "$_shared_rev"

# --- Generate manifest ---
_manifest_dir="$_e2e_root/shell/install"
mkdir -p "$_manifest_dir"
_manifest="$_manifest_dir/profile-release.manifest"

printf 'Generating manifest...\n'

# Collect all files to include in the manifest.
# Engine files (vendored) + e2e example modules (native).
_file_list=""

# Engine files
for _f in \
  lib/metadata.sh lib/loader.sh lib/capabilities.sh lib/compiler.awk \
  lib/fish/loader.fish lib/fish/metadata.fish \
  entrypoints/profile.sh entrypoints/fish/profile.fish \
  module.d/platform_posix.meta module.d/platform_macos.meta \
  module.d/platform_linux.meta module.d/platform_bsd.meta \
  modules/platform/posix.sh \
  modules/platform/macos/capabilities.sh \
  modules/platform/linux/capabilities.sh \
  modules/platform/bsd/capabilities.sh \
; do
  _file_list="$_file_list $_f"
done

# E2e example module metadata
_e2e_meta_count=0

# Shareable engine catalog (vendored above)
for _f in "$_e2e_root"/module.d/contrib_*.meta "$_e2e_root"/modules/system/contrib_*.sh; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$_e2e_root"/}
  _file_list="$_file_list $_rel"
done
for _f in "$_e2e_root"/module.d/e2e_*.meta; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$_e2e_root"/}
  _file_list="$_file_list $_rel"
  _e2e_meta_count=$((_e2e_meta_count + 1))
done

# E2e example module bodies (POSIX)
_e2e_sh_count=0
for _f in "$_e2e_root"/modules/e2e/*.sh; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$_e2e_root"/}
  _file_list="$_file_list $_rel"
  _e2e_sh_count=$((_e2e_sh_count + 1))
done

# E2e example module bodies (Fish)
_e2e_fish_count=0
for _f in "$_e2e_root"/modules/e2e/*.fish; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$_e2e_root"/}
  _file_list="$_file_list $_rel"
  _e2e_fish_count=$((_e2e_fish_count + 1))
done

# Shared layer files (cross-repo composition): provider metadata, bodies,
# and the pin file recording the vendored revision.
_shared_count=0
for _f in "$_e2e_root"/layer/shared/module.d/*.meta "$_e2e_root"/layer/shared/modules/*/*.sh "$_e2e_root"/layer/shared/layer-pin.txt; do
  [ -f "$_f" ] || continue
  _rel=${_f#"$_e2e_root"/}
  _file_list="$_file_list $_rel"
  _shared_count=$((_shared_count + 1))
done

# Fail closed when a glob collected nothing: POSIX sh leaves a non-matching
# glob unexpanded, so without this an empty or missing e2e directory would
# build a manifest silently missing e2e files.
if [ "$_e2e_meta_count" -eq 0 ]; then
  printf 'ERROR: no e2e module metadata found in %s\n' "$_e2e_root/module.d" >&2
  exit 1
fi
if [ "$((_e2e_sh_count + _e2e_fish_count))" -eq 0 ]; then
  printf 'ERROR: no e2e module bodies found in %s\n' "$_e2e_root/modules/e2e" >&2
  exit 1
fi
if [ "$_shared_count" -eq 0 ]; then
  printf 'ERROR: no shared layer files found in %s\n' "$_e2e_root/layer/shared" >&2
  exit 1
fi

# Write manifest header
printf 'shell-profile-release-manifest-v1\n' > "$_manifest"
printf 'destination\tsource\tsource_mode\tinstall_mode\tbytes\tsha256\n' >> "$_manifest"

# Write data rows
for _rel in $_file_list; do
  _full="$_e2e_root/$_rel"
  [ -f "$_full" ] || { printf 'ERROR: file missing: %s\n' "$_full" >&2; exit 1; }
  [ ! -L "$_full" ] || { printf 'ERROR: symlink in release: %s\n' "$_full" >&2; exit 1; }
  _bytes=$(file_bytes "$_full")
  _sha=$(file_sha256 "$_full")
  # destination == source for this flat release layout
  # All release files are 0644 source -> 0444 installed (immutable)
  printf '%s\t%s\t0644\t0444\t%s\t%s\n' "$_rel" "$_rel" "$_bytes" "$_sha" >> "$_manifest"
done

_file_count=$(awk 'NR > 2 && NF > 0 { count++ } END { print count+0 }' "$_manifest")
printf 'Manifest written: %s (%d files)\n' "$_manifest" "$_file_count"
