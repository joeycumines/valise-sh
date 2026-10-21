# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Generic Fish entrypoint adapter shipped with the valise engine.
#
# The valise Fish integration authenticates the active sealed release and
# exports SHELL_PROJECT_ROOT pointing at its root before sourcing this file.
# This adapter then requests modules the same way the POSIX entrypoint does:
# VALISE_MODULES selects the graph (unset loads nothing), VALISE_MODE selects
# strict or permissive failure handling (default permissive). It sources the
# release's native Fish metadata and loader, consumes the loader's bootstrap
# status marker, and publishes VALISE_FISH_READY=1 only after a successful
# activation. Consuming projects may ship their own adapter at the same
# release path to add project-specific selection policy.

if not builtin set -q SHELL_PROJECT_ROOT
    builtin printf '%s\n' 'valise Fish entrypoint: SHELL_PROJECT_ROOT is not set' >&2
    return 1
end
set -l _valise_fish_entrypoint_root "$SHELL_PROJECT_ROOT"

if not builtin test -r "$_valise_fish_entrypoint_root/lib/fish/metadata.fish"
    builtin printf '%s\n' "valise Fish entrypoint: metadata library is not readable: $_valise_fish_entrypoint_root/lib/fish/metadata.fish" >&2
    return 1
end
if not builtin test -r "$_valise_fish_entrypoint_root/lib/fish/loader.fish"
    builtin printf '%s\n' "valise Fish entrypoint: loader library is not readable: $_valise_fish_entrypoint_root/lib/fish/loader.fish" >&2
    return 1
end

# The bootstrap handshake variables are engine-private state. A forged or
# stale marker must not survive into this activation: erase every visible
# scope before requesting a fresh bootstrap, failing closed if an erase
# is refused.
for _valise_fish_entrypoint_stale in _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status
    if builtin set -q -g "$_valise_fish_entrypoint_stale"; and not builtin set -e -g "$_valise_fish_entrypoint_stale"
        builtin printf '%s\n' "valise Fish entrypoint: cannot clear stale global $_valise_fish_entrypoint_stale" >&2
        return 1
    end
    if builtin set -q -U "$_valise_fish_entrypoint_stale"; and not builtin set -e -U "$_valise_fish_entrypoint_stale"
        builtin printf '%s\n' "valise Fish entrypoint: cannot clear stale universal $_valise_fish_entrypoint_stale" >&2
        return 1
    end
end

set -l _valise_fish_entrypoint_mode permissive
if builtin set -q VALISE_MODE
    set _valise_fish_entrypoint_mode "$VALISE_MODE"
end

set -l _valise_fish_entrypoint_seeds
if builtin set -q VALISE_MODULES; and builtin test -n "$VALISE_MODULES"
    set _valise_fish_entrypoint_seeds (builtin string split ' ' -- $VALISE_MODULES)
end

builtin set -gx _sp_fish_loader_bootstrap_mode "$_valise_fish_entrypoint_mode"
builtin set -gx _sp_fish_loader_bootstrap_seeds $_valise_fish_entrypoint_seeds

builtin source "$_valise_fish_entrypoint_root/lib/fish/metadata.fish"
set -l _valise_fish_entrypoint_metadata_status $status
if builtin test $_valise_fish_entrypoint_metadata_status -ne 0
    builtin set -e _sp_fish_loader_bootstrap_mode
    builtin set -e _sp_fish_loader_bootstrap_seeds
    return $_valise_fish_entrypoint_metadata_status
end

builtin source "$_valise_fish_entrypoint_root/lib/fish/loader.fish"
set -l _valise_fish_entrypoint_loader_status $status
# The loader consumes the bootstrap request when it sources cleanly; erase
# any request a failed source left behind so it cannot leak to callers.
if builtin set -q _sp_fish_loader_bootstrap_mode
    builtin set -e _sp_fish_loader_bootstrap_mode
end
if builtin set -q _sp_fish_loader_bootstrap_seeds
    builtin set -e _sp_fish_loader_bootstrap_seeds
end
if builtin test $_valise_fish_entrypoint_loader_status -ne 0
    # A failed source may have published a partial status marker; erase it
    # so the caller's fresh-marker check below cannot see stale state.
    if builtin set -q _sp_fish_loader_bootstrap_status
        builtin set -e _sp_fish_loader_bootstrap_status
    end
    return $_valise_fish_entrypoint_loader_status
end

# The loader publishes a fresh bootstrap status marker on every activation;
# its absence means the loader never completed its handshake.
if not builtin set -q _sp_fish_loader_bootstrap_status
    builtin printf '%s\n' 'valise Fish entrypoint: loader bootstrap status marker is absent' >&2
    return 1
end
set -l _valise_fish_entrypoint_status $_sp_fish_loader_bootstrap_status
builtin set -e _sp_fish_loader_bootstrap_status
if builtin test $_valise_fish_entrypoint_status -ne 0
    return $_valise_fish_entrypoint_status
end

builtin set -gx VALISE_FISH_READY 1
return 0
