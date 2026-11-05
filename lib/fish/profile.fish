# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Fish adapter for a release built by `valise build`, installed at
# runtime/fish/profile.fish.
#
# The valise Fish integration authenticates the active sealed release and
# exports SHELL_PROJECT_ROOT pointing at its root before sourcing this file.
# The seeds are the release's own roots_fish line in valise-release.conf, so a
# Fish login loads exactly the bundle the release was built for. VALISE_MODE
# selects strict or permissive failure handling (default strict, as in the
# POSIX plans). The adapter sources the release's native Fish metadata and
# loader, consumes the loader's bootstrap status marker, and publishes
# VALISE_FISH_READY=1 only after a successful activation.

# Readiness and the bootstrap handshake are engine-private state. A forged
# or stale value must not survive this activation, even one that fails
# early: erase every visible scope first, failing closed if an erase is
# refused.
for _valise_fish_profile_stale in VALISE_FISH_READY _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status _sp_fish_loader_expected_source _sp_fish_metadata_expected_source
    if builtin set -q -g "$_valise_fish_profile_stale"; and not builtin set -e -g "$_valise_fish_profile_stale"
        builtin printf '%s\n' "valise Fish profile: cannot clear stale global $_valise_fish_profile_stale" >&2
        return 1
    end
    if builtin set -q -U "$_valise_fish_profile_stale"; and not builtin set -e -U "$_valise_fish_profile_stale"
        builtin printf '%s\n' "valise Fish profile: cannot clear stale universal $_valise_fish_profile_stale" >&2
        return 1
    end
end

# Each activation starts from nothing. Remove the functions the previous
# activation's loader recorded as its own, but only where the live function
# still has the recorded Fish provenance, then drop that loader state. A
# failure below therefore never leaves the old activation callable without
# readiness.
set -l _valise_fish_profile_owned_index 1
for _valise_fish_profile_owned in $_sp_fish_loader_owned_exports
    set -l _valise_fish_profile_owned_source "$_sp_fish_loader_owned_sources[$_valise_fish_profile_owned_index]"
    if builtin test -n "$_valise_fish_profile_owned_source"; and builtin functions -q -- "$_valise_fish_profile_owned"; and builtin test (builtin functions --details -- "$_valise_fish_profile_owned") = "$_valise_fish_profile_owned_source"
        builtin functions -e -- "$_valise_fish_profile_owned"; or builtin exit 125
    end
    set _valise_fish_profile_owned_index (builtin math $_valise_fish_profile_owned_index + 1)
end
for _valise_fish_profile_stale in _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_loaded_modules _sp_fish_module_roots _sp_fish_metadata_provider
    if builtin set -q -g "$_valise_fish_profile_stale"; and not builtin set -e -g "$_valise_fish_profile_stale"
        builtin exit 125
    end
    if builtin set -q -U "$_valise_fish_profile_stale"; and not builtin set -e -U "$_valise_fish_profile_stale"
        builtin exit 125
    end
end

if not builtin set -q SHELL_PROJECT_ROOT
    builtin printf '%s\n' 'valise Fish profile: SHELL_PROJECT_ROOT is not set' >&2
    return 1
end
set -l _valise_fish_profile_root (builtin path resolve -- "$SHELL_PROJECT_ROOT" 2>/dev/null)
if builtin test (builtin count $_valise_fish_profile_root) -ne 1; or builtin test -z "$_valise_fish_profile_root"
    builtin printf '%s\n' 'valise Fish profile: SHELL_PROJECT_ROOT cannot be resolved' >&2
    return 1
end
set -l _valise_fish_profile_runtime "$_valise_fish_profile_root/runtime/fish"

for _valise_fish_profile_file in "$_valise_fish_profile_root/valise-release.conf" "$_valise_fish_profile_runtime/metadata.fish" "$_valise_fish_profile_runtime/loader.fish"
    if not builtin test -f "$_valise_fish_profile_file"; or not builtin test -r "$_valise_fish_profile_file"
        builtin printf '%s\n' "valise Fish profile: release file is not readable: $_valise_fish_profile_file" >&2
        return 1
    end
end

set -l _valise_fish_profile_mode strict
if builtin set -q VALISE_MODE
    set _valise_fish_profile_mode "$VALISE_MODE"
end

# roots_fish holds space-separated module references. The Fish loader
# resolves modules by name, so a qualified name@source keeps only its name.
set -l _valise_fish_profile_roots_lines (builtin string match -r '^roots_fish=.*' < "$_valise_fish_profile_root/valise-release.conf")
if builtin test (builtin count $_valise_fish_profile_roots_lines) -ne 1
    builtin printf '%s\n' 'valise Fish profile: valise-release.conf must hold exactly one roots_fish line' >&2
    return 1
end
set -l _valise_fish_profile_seeds
for _valise_fish_profile_ref in (builtin string split ' ' -- (builtin string replace 'roots_fish=' '' -- $_valise_fish_profile_roots_lines[1]))
    builtin test -n "$_valise_fish_profile_ref"; or continue
    set -a _valise_fish_profile_seeds (builtin string replace -r '@.*$' '' -- $_valise_fish_profile_ref)
end

# The adapter, not the sourced files, names the provenance anchors the
# loader checks its own definitions against. Pinning them here means a
# caller cannot preset a forged anchor before activation.
set -l _valise_fish_profile_loader_anchor "$_valise_fish_profile_runtime/loader.fish"
set -l _valise_fish_profile_metadata_anchor "$_valise_fish_profile_runtime/metadata.fish"
builtin set -g _sp_fish_loader_expected_source "$_valise_fish_profile_loader_anchor"
builtin set -g _sp_fish_metadata_expected_source "$_valise_fish_profile_metadata_anchor"

builtin set -gx _sp_fish_loader_bootstrap_mode "$_valise_fish_profile_mode"
builtin set -gx _sp_fish_loader_bootstrap_seeds $_valise_fish_profile_seeds

builtin source "$_valise_fish_profile_metadata_anchor"
set -l _valise_fish_profile_metadata_status $status
# Metadata defines functions only. It must leave the activation state it was
# handed untouched; a source that returns success after rewriting it is
# rejected the same as one that fails.
if builtin test $_valise_fish_profile_metadata_status -eq 0
    set -l _valise_fish_profile_tampered
    if not builtin test "$SHELL_PROJECT_ROOT" = "$_valise_fish_profile_root"; and not builtin test (builtin path resolve -- "$SHELL_PROJECT_ROOT" 2>/dev/null) = "$_valise_fish_profile_root"
        set -a _valise_fish_profile_tampered SHELL_PROJECT_ROOT
    end
    if builtin set -q -U _sp_fish_loader_expected_source; or not builtin test "$_sp_fish_loader_expected_source" = "$_valise_fish_profile_loader_anchor"
        set -a _valise_fish_profile_tampered _sp_fish_loader_expected_source
    end
    if builtin set -q -U _sp_fish_metadata_expected_source; or not builtin test "$_sp_fish_metadata_expected_source" = "$_valise_fish_profile_metadata_anchor"
        set -a _valise_fish_profile_tampered _sp_fish_metadata_expected_source
    end
    if builtin set -q -U _sp_fish_loader_bootstrap_mode; or not builtin test "$_sp_fish_loader_bootstrap_mode" = "$_valise_fish_profile_mode"
        set -a _valise_fish_profile_tampered _sp_fish_loader_bootstrap_mode
    end
    if builtin set -q -U _sp_fish_loader_bootstrap_seeds; or not builtin test "$_sp_fish_loader_bootstrap_seeds" = "$_valise_fish_profile_seeds"
        set -a _valise_fish_profile_tampered _sp_fish_loader_bootstrap_seeds
    end
    if builtin set -q _sp_fish_loader_bootstrap_status
        set -a _valise_fish_profile_tampered _sp_fish_loader_bootstrap_status
    end
    if builtin test (builtin count $_valise_fish_profile_tampered) -ne 0
        builtin printf '%s\n' "valise Fish profile: metadata changed activation state: $_valise_fish_profile_tampered" >&2
        set _valise_fish_profile_metadata_status 1
    end
end
if builtin test $_valise_fish_profile_metadata_status -ne 0
    for _valise_fish_profile_stale in _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status _sp_fish_loader_expected_source _sp_fish_metadata_expected_source
        builtin set -q -U "$_valise_fish_profile_stale"; and builtin set -e -U "$_valise_fish_profile_stale"
        builtin set -q -g "$_valise_fish_profile_stale"; and builtin set -e -g "$_valise_fish_profile_stale"
    end
    builtin set -g _sp_fish_loader_expected_source "$_valise_fish_profile_loader_anchor"
    builtin set -g _sp_fish_metadata_expected_source "$_valise_fish_profile_metadata_anchor"
    return $_valise_fish_profile_metadata_status
end

builtin source "$_valise_fish_profile_loader_anchor"
set -l _valise_fish_profile_loader_status $status
# The loader consumes the bootstrap request when it sources cleanly; erase
# any request a failed source left behind so it cannot leak to callers.
if builtin set -q _sp_fish_loader_bootstrap_mode
    builtin set -e _sp_fish_loader_bootstrap_mode
end
if builtin set -q _sp_fish_loader_bootstrap_seeds
    builtin set -e _sp_fish_loader_bootstrap_seeds
end
if builtin test $_valise_fish_profile_loader_status -ne 0
    if builtin set -q _sp_fish_loader_bootstrap_status
        builtin set -e _sp_fish_loader_bootstrap_status
    end
    return $_valise_fish_profile_loader_status
end

# The loader publishes a fresh bootstrap status marker on every activation;
# its absence means the loader never completed its handshake.
if not builtin set -q _sp_fish_loader_bootstrap_status
    builtin printf '%s\n' 'valise Fish profile: loader bootstrap status marker is absent' >&2
    return 1
end
set -l _valise_fish_profile_status $_sp_fish_loader_bootstrap_status
builtin set -e _sp_fish_loader_bootstrap_status
if builtin test $_valise_fish_profile_status -ne 0
    return $_valise_fish_profile_status
end

builtin set -gx VALISE_FISH_READY 1
return 0
