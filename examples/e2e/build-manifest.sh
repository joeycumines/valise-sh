#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# build-manifest.sh: vendor engine files into an e2e release tree and
# generate a profile-release.manifest with correct sizes and SHA-256 digests.
#
# Usage: sh build-manifest.sh [output-dir]
# Default output-dir: examples/e2e/build/release

set -eu

_script_dir=$(cd "$(dirname "$0")" && pwd -P)
_repo_root=$(cd "$_script_dir/../.." && pwd -P)
_e2e_root="$_script_dir"
_out_dir="${1:-$_e2e_root/build/release}"
_valise="$_repo_root/bin/valise"

[ -x "$_valise" ] || { printf 'ERROR: valise CLI not found at %s\n' "$_valise" >&2; exit 1; }

# Prepare clean output directory
rm -rf "$_out_dir"
mkdir -p "$_out_dir"

_vendor_copy() {
  _src="$_repo_root/$1"
  _dst="$_out_dir/$1"
  _dst_dir=$(dirname "$_dst")
  [ -f "$_src" ] || { printf 'ERROR: engine source missing: %s\n' "$_src" >&2; exit 1; }
  mkdir -p "$_dst_dir"
  cp "$_src" "$_dst"
  chmod 0644 "$_dst"
}

printf 'Vendoring engine files into %s...\n' "$_out_dir"

# Core libraries
_vendor_copy lib/metadata.sh
_vendor_copy lib/loader.sh
_vendor_copy lib/capabilities.sh
_vendor_copy lib/compiler.awk

# Fish libraries
_vendor_copy lib/fish/loader.fish
_vendor_copy lib/fish/metadata.fish

# Generic Fish entrypoint adapter
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

# --- Native e2e example modules ---
_e2e_meta_count=0
mkdir -p "$_out_dir/module.d"
for _meta in "$_e2e_root"/module.d/e2e_*.meta; do
  [ -f "$_meta" ] || continue
  cp "$_meta" "$_out_dir/module.d/"
  chmod 0644 "$_out_dir/module.d/$(basename "$_meta")"
  _e2e_meta_count=$((_e2e_meta_count + 1))
done

_e2e_body_count=0
mkdir -p "$_out_dir/modules/e2e"
for _body in "$_e2e_root"/modules/e2e/*.sh "$_e2e_root"/modules/e2e/*.fish; do
  [ -f "$_body" ] || continue
  cp "$_body" "$_out_dir/modules/e2e/"
  chmod 0644 "$_out_dir/modules/e2e/$(basename "$_body")"
  _e2e_body_count=$((_e2e_body_count + 1))
done

if [ "$_e2e_meta_count" -eq 0 ]; then
  printf 'ERROR: no e2e module metadata found in %s\n' "$_e2e_root/module.d" >&2
  exit 1
fi
if [ "$_e2e_body_count" -eq 0 ]; then
  printf 'ERROR: no e2e module bodies found in %s\n' "$_e2e_root/modules/e2e" >&2
  exit 1
fi

# --- Vendor shared layer (cross-repo composition) ---
_shared_src="$_repo_root/examples/shared"
_shared_dst="$_out_dir/layer/shared"
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

# Normalise file modes before manifesting
find "$_out_dir" -type f -exec chmod 0644 {} +

# --- Generate manifest using valise CLI ---
"$_valise" make-manifest "$_out_dir"
