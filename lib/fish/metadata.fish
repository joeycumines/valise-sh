# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Fish-native module metadata ABI helpers.
# Replicates the validation semantics of lib/metadata.sh in native Fish.
# Never sources POSIX bodies. Pure Fish syntax only.

# The first metadata source establishes the exact provenance anchor consumed by
# the native loader. A later same-name source cannot move this anchor merely by
# ending in `metadata.fish`.
if not builtin set -q _sp_fish_metadata_expected_source
    builtin set -g _sp_fish_metadata_expected_source (builtin status --current-filename)
end

function sp_fish_metadata_error --description 'Print metadata error to stderr'
    echo "metadata: $argv[1]" >&2
end

function sp_fish_metadata_validate_identifier --description 'Validate a module identifier'
    set -l ident $argv[1]
    if test -z "$ident"
        return 1
    end
    # Must start with lowercase letter or underscore
    if not string match -qr '^[a-z_]' -- "$ident"
        return 1
    end
    # Must contain only valid characters
    if string match -qr '[^a-zA-Z0-9_]' -- "$ident"
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_identifier_list --description 'Validate space-separated identifier list'
    set -l list_val $argv[1]
    set -l label $argv[2]
    if test -z "$list_val"
        return 0
    end
    set -l seen 0
    for word in (string split ' ' -- $list_val)
        if test -z "$word"
            continue
        end
        set seen 1
        if not sp_fish_metadata_validate_identifier "$word"
            sp_fish_metadata_error "invalid $label: $word"
            return 1
        end
    end
    if test $seen -eq 0
        sp_fish_metadata_error "missing required metadata field: $label"
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_shell_list --description 'Validate shell list includes only known shells'
    set -l shells_val $argv[1]
    if test -z "$shells_val"
        sp_fish_metadata_error 'missing required metadata field: shells'
        return 1
    end
    set -l seen 0
    for sh in (string split ' ' -- $shells_val)
        if test -z "$sh"
            continue
        end
        set seen 1
        switch "$sh"
            case sh bash zsh ksh fish
                # valid
            case '*'
                sp_fish_metadata_error "invalid shell: $sh"
                return 1
        end
    end
    if test $seen -eq 0
        sp_fish_metadata_error 'missing required metadata field: shells'
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_platform_list --description 'Validate platform list'
    set -l platforms_val $argv[1]
    if test -z "$platforms_val"
        sp_fish_metadata_error 'missing required metadata field: platforms'
        return 1
    end
    set -l seen 0
    for plat in (string split ' ' -- $platforms_val)
        if test -z "$plat"
            continue
        end
        set seen 1
        switch "$plat"
            case any darwin linux bsd freebsd openbsd netbsd
                # valid
            case '*'
                sp_fish_metadata_error "invalid platform: $plat"
                return 1
        end
    end
    if test $seen -eq 0
        sp_fish_metadata_error 'missing required metadata field: platforms'
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_relative_path --description 'Validate a relative load path'
    set -l path_val $argv[1]
    if test -z "$path_val"
        return 0
    end
    if string match -qr '^/' -- "$path_val"; or string match -qr '(^|/)\.\.?(/|$)' -- "$path_val"
        sp_fish_metadata_error "invalid relative path: $path_val"
        return 1
    end
    if string match -qr '[^a-zA-Z0-9_./-]' -- "$path_val"
        sp_fish_metadata_error "invalid relative path: $path_val"
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_side_effect --description 'Validate side_effect value'
    switch "$argv[1]"
        case read-only path-env generated-file update-network install-time local-secret work-only
            return 0
        case '*'
            sp_fish_metadata_error "invalid side_effect: $argv[1]"
            return 1
    end
end

function sp_fish_metadata_validate_version --description 'Validate an optional module version'
    set -l version_val $argv[1]
    if test -z "$version_val"
        return 0
    end
    if not string match -qr '^[0-9]' -- "$version_val"
        sp_fish_metadata_error "invalid version: $version_val"
        return 1
    end
    if string match -qr '[^0-9A-Za-z._-]' -- "$version_val"
        sp_fish_metadata_error "invalid version: $version_val"
        return 1
    end
    return 0
end

function sp_fish_metadata_validate_source_side_effect --description 'Reject side effects forbidden during ordinary source'
    if not sp_fish_metadata_validate_side_effect "$argv[1]"
        return 1
    end
    switch "$argv[1]"
        case generated-file update-network install-time
            sp_fish_metadata_error "side_effect not allowed during ordinary source: $argv[1]"
            return 1
        case '*'
            return 0
    end
end

function sp_fish_metadata_read --description 'Read and validate a .meta file, output key=value lines'
    if test (count $argv) -ne 1
        sp_fish_metadata_error 'usage: sp_fish_metadata_read <metadata-file>'
        return 1
    end
    set -l meta_file $argv[1]
    if not test -r "$meta_file"
        sp_fish_metadata_error "metadata file is not readable: $meta_file"
        return 1
    end

    set -l m_name ''
    set -l m_requires ''
    set -l m_optional ''
    set -l m_shells ''
    set -l m_platforms ''
    set -l m_side_effect ''
    set -l m_exports ''
    set -l m_updates ''
    set -l m_version ''
    set -l m_load ''
    set -l m_load_hook ''

    while read -l line
        # Skip empty lines and comments
        if test -z "$line"; or string match -qr '^#' -- "$line"
            continue
        end
        # Must contain =
        if not string match -q '*=*' -- "$line"
            sp_fish_metadata_error "invalid metadata line: $line"
            return 1
        end
        set -l key (string split -m1 '=' -- "$line")[1]
        set -l val (string split -m1 '=' -- "$line")[2]
        switch "$key"
            case name; set m_name $val
            case requires; set m_requires $val
            case optional; set m_optional $val
            case shells; set m_shells $val
            case platforms; set m_platforms $val
            case side_effect; set m_side_effect $val
            case exports; set m_exports $val
            case updates; set m_updates $val
            case version; set m_version $val
            case load; set m_load $val
            case load_hook; set m_load_hook $val
            case '*'
                sp_fish_metadata_error "unknown metadata field: $key"
                return 1
        end
    end < "$meta_file"

    # Required fields
    if test -z "$m_name"
        sp_fish_metadata_error 'missing required metadata field: name'
        return 1
    end
    if test -z "$m_shells"
        sp_fish_metadata_error 'missing required metadata field: shells'
        return 1
    end
    if test -z "$m_platforms"
        sp_fish_metadata_error 'missing required metadata field: platforms'
        return 1
    end
    if test -z "$m_side_effect"
        sp_fish_metadata_error 'missing required metadata field: side_effect'
        return 1
    end

    # Match the generic metadata ABI before the Fish loader applies its
    # shell/body selection. Generic POSIX records must parse successfully so
    # the loader can skip them when their shells do not include Fish.
    if test -z "$m_load"; and test -z "$m_load_hook"
        sp_fish_metadata_error 'missing required metadata field: load or load_hook'
        return 1
    end
    if test -n "$m_load"; and test -n "$m_load_hook"
        sp_fish_metadata_error 'metadata fields load and load_hook are mutually exclusive'
        return 1
    end
    if test -n "$m_load_hook"; and not sp_fish_metadata_validate_identifier "$m_load_hook"
        sp_fish_metadata_error "invalid load_hook: $m_load_hook"
        return 1
    end

    # Validations
    if not sp_fish_metadata_validate_identifier "$m_name"
        sp_fish_metadata_error "invalid module name: $m_name"
        return 1
    end
    if not sp_fish_metadata_validate_identifier_list "$m_requires" dependency
        return 1
    end
    if not sp_fish_metadata_validate_identifier_list "$m_optional" optional_dependency
        return 1
    end
    if not sp_fish_metadata_validate_shell_list "$m_shells"
        return 1
    end
    if not sp_fish_metadata_validate_platform_list "$m_platforms"
        return 1
    end
    if not sp_fish_metadata_validate_side_effect "$m_side_effect"
        return 1
    end
    if not sp_fish_metadata_validate_identifier_list "$m_exports" export
        return 1
    end
    if not sp_fish_metadata_validate_identifier_list "$m_updates" update_registration
        return 1
    end
    if not sp_fish_metadata_validate_version "$m_version"
        return 1
    end
    if not sp_fish_metadata_validate_relative_path "$m_load"
        return 1
    end
    # Output normalized metadata
    echo "name=$m_name"
    echo "requires=$m_requires"
    echo "optional=$m_optional"
    echo "shells=$m_shells"
    echo "platforms=$m_platforms"
    echo "side_effect=$m_side_effect"
    echo "exports=$m_exports"
    echo "updates=$m_updates"
    echo "version=$m_version"
    echo "load=$m_load"
    echo "load_hook=$m_load_hook"
    return 0
end
