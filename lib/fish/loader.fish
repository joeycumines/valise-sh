# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# Fish-native module loader.
# Implements metadata read + deterministic topological sort + strict/permissive
# error handling. Never sources POSIX bodies — only .fish files.
#
# Requires: lib/fish/metadata.fish to be sourced first.

set -g _sp_fish_loaded_modules
set -g _sp_fish_module_roots
set -g _sp_fish_metadata_provider
# The generated entrypoint publishes its own source-authenticated function ledger.
# Keep the names in the native loader's protected-state image so a module cannot
# forge or erase release-switch ownership while an activation is in progress.
# The ledger is created by the outer integration when an entrypoint succeeds.
# Capture the first source path as the immutable provenance anchor for this
# Fish session.  Later sources of a same-named loader must not be able to move
# the anchor to an attacker-controlled path ending in `loader.fish`.
if not builtin set -q _sp_fish_loader_expected_source
    builtin set -g _sp_fish_loader_expected_source (builtin status --current-filename)
end
# This ledger intentionally survives re-sourcing loader.fish. It records only
# Fish functions successfully claimed by module metadata, allowing a release
# switch to remove the previous release's exports without erasing caller-owned
# functions.
if not builtin set -q _sp_fish_loader_owned_exports
    builtin set -g _sp_fish_loader_owned_exports
end
if not builtin set -q _sp_fish_loader_owned_sources
    builtin set -g _sp_fish_loader_owned_sources
end
# Remove legacy public function replacements before the source-driven entrypoint
# runs. These names are not part of the Fish ABI; retaining a caller-defined
# no-op under either name would make an old invocation look deceptively valid.
for _sp_fish_legacy_entrypoint in sp_fish_loader_load_ordered sp_fish_loader_dispatch
    builtin functions -q "$_sp_fish_legacy_entrypoint"; and builtin functions -e "$_sp_fish_legacy_entrypoint"
end

function _sp_fish_loader_is_trusted_system_function_source --argument-names source function_name
    # Fish packages may load default functions from disk instead of embedding
    # them in the binary. Also trust only Valise's temporary generated helpers
    # in its deployed hook; all other caller and project function paths stay untrusted.
    if builtin set -q _sp_fish_loader_expected_source; and builtin test "$source" = "$_sp_fish_loader_expected_source"
        return 0
    end
    if builtin set -q _sp_fish_metadata_expected_source; and builtin test "$source" = "$_sp_fish_metadata_expected_source"
        return 0
    end
    set -l source_directory (builtin path dirname -- "$source")
    if builtin contains -- "$source_directory" /usr/share/fish/functions /usr/local/share/fish/functions /opt/local/share/fish/functions /opt/homebrew/share/fish/functions; or builtin contains -- "$source" /usr/share/fish/config.fish /usr/local/share/fish/config.fish /opt/local/share/fish/config.fish /opt/homebrew/share/fish/config.fish
        builtin test -f "$source"
        return $status
    end
    if builtin string match -q '__valise_fish_*' -- "$function_name"; and builtin string match -q '*/fish/conf.d/valise.fish' -- "$source"
        builtin test -f "$source"
        return $status
    end
    return 1
end

function sp_fish_loader_error --description 'Print loader error to stderr'
    echo "loader: $argv[1]" >&2
end

function _sp_fish_loader_rollback_activation --description 'Remove exports and state from a failed activation'
    # The ownership ledger contains only exports claimed by successfully
    # completed modules in the current activation. Removing those functions is
    # therefore safe for caller-owned functions and makes strict failures
    # transactional instead of leaving a partially active profile behind.
    set -l owned_source_index 1
    for owned_export in $_sp_fish_loader_owned_exports
        set -l owned_source ''
        if test $owned_source_index -le (builtin count $_sp_fish_loader_owned_sources)
            set owned_source $_sp_fish_loader_owned_sources[$owned_source_index]
        end
        if test -n "$owned_source"; and builtin functions -q "$owned_export"; and builtin test (builtin functions --details "$owned_export") = "$owned_source"
            builtin functions -e "$owned_export"; or builtin exit 125
        end
        builtin set owned_source_index (builtin math $owned_source_index + 1)
    end
    builtin set -g _sp_fish_loader_owned_exports; or builtin exit 125
    builtin set -g _sp_fish_loader_owned_sources; or builtin exit 125
    builtin set -g _sp_fish_loaded_modules; or builtin exit 125
    builtin set -g _sp_fish_module_roots; or builtin exit 125
    builtin set -g _sp_fish_metadata_provider; or builtin exit 125
end

function sp_fish_loader_source_body --description 'Source a Fish body in an isolated function scope'
    source "$argv[1]"
end

function _sp_fish_loader_function_definition_matches --description 'Compare a live Fish function with a trusted file snapshot'
    set -l live_name $argv[1]
    set -l snapshot_file $argv[2]
    if not builtin functions -q "$live_name"; or not test -f "$snapshot_file"
        return 1
    end
    set -l live_definition (builtin functions "$live_name")
    set -l cat_path ''
    for candidate in /bin/cat /usr/bin/cat
        if test -x "$candidate"
            set cat_path "$candidate"
            break
        end
    end
    if test -z "$cat_path"
        return 1
    end
    set -l snapshot_definition ("$cat_path" "$snapshot_file")
    if test (builtin count $live_definition) -ne (builtin count $snapshot_definition)
        return 1
    end
    # Fish's rendered definition differs only in its provenance comment. The
    # saved function has the same name, so compare every line after that
    # comment without normalizing or executing the body.
    set -l definition_index 2
    while test $definition_index -le (builtin count $live_definition)
        if not builtin test "$live_definition[$definition_index]" = "$snapshot_definition[$definition_index]"
            return 1
        end
        set definition_index (builtin math $definition_index + 1)
    end
    return 0
end

function _sp_fish_loader_function_definition_matches_text --no-scope-shadowing --description 'Compare a live Fish function with a trusted in-memory definition'
    set -l live_name $argv[1]
    set -l expected_lines $argv[2..-1]
    if not builtin functions -q "$live_name"
        return 1
    end
    set -l live_lines (string split \n -- (builtin functions "$live_name" | string collect))
    if test (builtin count $live_lines) -ne (builtin count $expected_lines)
        return 1
    end
    set -l definition_index 2
    while test $definition_index -le (builtin count $expected_lines)
        if not builtin test "$expected_lines[$definition_index]" = "$live_lines[$definition_index]"
            return 1
        end
        set definition_index (builtin math $definition_index + 1)
    end
    return 0
end

function _sp_fish_loader_function_copy_matches --no-scope-shadowing --description 'Compare source-backed function copies without trusting copied names'
    set -l original_name $argv[1]
    set -l copy_name $argv[2]
    if not builtin functions -q "$original_name"; or not builtin functions -q "$copy_name"
        return 1
    end
    set -l original_lines (string split \n -- (builtin functions "$original_name" | string collect))
    set -l copy_lines (string split \n -- (builtin functions "$copy_name" | string collect))
    if test (builtin count $original_lines) -ne (builtin count $copy_lines); or test (builtin count $original_lines) -lt 2
        return 1
    end
    set -l original_declaration (string replace -r '^function [^[:space:]]+' 'function __source_backed_copy__' -- "$original_lines[2]")
    set -l copy_declaration (string replace -r '^function [^[:space:]]+' 'function __source_backed_copy__' -- "$copy_lines[2]")
    test "$original_declaration" = "$copy_declaration"; or return 1
    set -l copy_index 3
    while test $copy_index -le (builtin count $copy_lines)
        if not builtin test "$original_lines[$copy_index]" = "$copy_lines[$copy_index]"
            return 1
        end
        set copy_index (builtin math $copy_index + 1)
    end
    return 0
end

function _sp_fish_loader_function_copy_matches_definition --no-scope-shadowing --description 'Compare a source-backed copy with a saved definition'
    set -l copy_name $argv[1]
    set -l expected_lines $argv[2..-1]
    if not builtin functions -q "$copy_name"
        return 1
    end
    set -l copy_lines (string split \n -- (builtin functions "$copy_name" | string collect))
    if test (builtin count $copy_lines) -ne (builtin count $expected_lines); or test (builtin count $copy_lines) -lt 2
        return 1
    end
    # The copy necessarily has a different function name. Compare its
    # declaration after normalizing only that name, then compare the complete
    # body verbatim. This authenticates the custody copy itself rather than
    # comparing it with the caller function after the module has replaced it.
    set -l copy_declaration (string replace -r '^function [^[:space:]]+' 'function __source_backed_copy__' -- "$copy_lines[2]")
    set -l expected_declaration (string replace -r '^function [^[:space:]]+' 'function __source_backed_copy__' -- "$expected_lines[2]")
    test "$copy_declaration" = "$expected_declaration"; or return 1
    set -l copy_index 3
    while test $copy_index -le (builtin count $copy_lines)
        if not builtin test "$copy_lines[$copy_index]" = "$expected_lines[$copy_index]"
            return 1
        end
        set copy_index (builtin math $copy_index + 1)
    end
    return 0
end

function _sp_fish_loader_function_provenance_matches --no-scope-shadowing --description 'Verify restored function origin and body provenance'
    set -l live_name $argv[1]
    set -l expected_lines $argv[2..-1]
    if not builtin functions -q "$live_name"; or test (builtin count $expected_lines) -lt 2
        return 1
    end
    set -l live_lines (string split \n -- (builtin functions "$live_name" | string collect))
    if test (builtin count $live_lines) -ne (builtin count $expected_lines)
        return 1
    end
    # `functions --copy` preserves the original defining file/line in the
    # first comment and appends a trusted "copied in" suffix. Keep the exact
    # source identity while accepting only that documented copy annotation.
    set -l live_origin (string replace -r ', copied in .*$' '' -- "$live_lines[1]")
    test "$live_origin" = "$expected_lines[1]"; or return 1
    set -l line_index 2
    while test $line_index -le (builtin count $live_lines)
        if not builtin test "$live_lines[$line_index]" = "$expected_lines[$line_index]"
            return 1
        end
        set line_index (builtin math $line_index + 1)
    end
    return 0
end

function _sp_fish_loader_capture_scope --description 'Capture one protected Fish universal scope without delimiter serialization'
    set -l scope_name $argv[1]
    set -l scope_prefix $argv[2]
    set -l global_present 0
    builtin set -q -g "$scope_name"; and builtin set global_present 1
    set -l global_exported 0
    builtin set -q -gx "$scope_name"; and builtin set global_exported 1
    set -l universal_present 0
    builtin set -q -U "$scope_name"; and builtin set universal_present 1
    set -l universal_exported 0
    builtin set -q -Ux "$scope_name"; and builtin set universal_exported 1
    set -l global_values
    if test $global_present -eq 1
        set global_values $$scope_name
    end
    set -l universal_values
    if test $universal_present -eq 1
        if test $global_present -eq 1
            set -l global_values $$scope_name
            builtin set -e -g "$scope_name"; or return 125
            set universal_values $$scope_name
            set -l restore_global_flags -g
            if test $global_exported -eq 1
                set restore_global_flags -gx
            end
            builtin set $restore_global_flags "$scope_name" $global_values
            if test $status -ne 0
                return 125
            end
        else
            set universal_values $$scope_name
        end
    end
    set -l present_name "$scope_prefix"_"$scope_name"_present
    set -l exported_name "$scope_prefix"_"$scope_name"_exported
    set -l values_name "$scope_prefix"_"$scope_name"_values
    builtin set -g "$scope_prefix"_"$scope_name"_global_present $global_present
    builtin set -g "$scope_prefix"_"$scope_name"_global_exported $global_exported
    builtin set -g "$scope_prefix"_"$scope_name"_global_values $global_values
    builtin set -g "$present_name" $universal_present
    builtin set -g "$exported_name" $universal_exported
    builtin set -g "$values_name" $universal_values
end

function _sp_fish_loader_verify_universal_persistence --no-scope-shadowing --description 'Verify a universal Fish scope from a fresh process'
    set -l durable_file $argv[1]
    set -l tmp_parent $argv[2]
    set -l scope_name $argv[3]
    set -l expected_present $argv[4]
    set -l expected_exported $argv[5]
    set -l expected_values $argv[6..-1]
    set -l fish_path (status fish-path)
    if test (builtin count $fish_path) -ne 1; or not test -x "$fish_path"
        return 125
    end
    # Fish's --no-config mode also skips the universal-variable store. Read a
    # symlinked copy of the durable store from an empty, disposable config
    # root instead: no caller config executes, while the child still uses
    # Fish's own SETUVAR decoder. The path was authenticated before any
    # untrusted metadata/module source ran and is passed explicitly; do not
    # derive it from mutable XDG_CONFIG_HOME here.
    if not test -f "$durable_file"
        # An absent universal before-image is valid when Fish has never
        # materialized its universal store. There is no durable value to
        # verify in that case; a present before-image still requires the file.
        if test "$expected_present" = 0
            return 0
        end
        return 125
    end
    set -l mktemp_path ''
    for candidate in /usr/bin/mktemp /bin/mktemp
        if test -x "$candidate"
            set mktemp_path "$candidate"
            break
        end
    end
    set -l mkdir_path ''
    for candidate in /bin/mkdir /usr/bin/mkdir
        if test -x "$candidate"
            set mkdir_path "$candidate"
            break
        end
    end
    set -l ln_path ''
    for candidate in /bin/ln /usr/bin/ln
        if test -x "$candidate"
            set ln_path "$candidate"
            break
        end
    end
    set -l rm_path ''
    for candidate in /bin/rm /usr/bin/rm
        if test -x "$candidate"
            set rm_path "$candidate"
            break
        end
    end
    if test -z "$mktemp_path"; or test -z "$mkdir_path"; or test -z "$ln_path"; or test -z "$rm_path"
        return 125
    end
    # The caller captured and validated this parent before untrusted source ran.
    # Never derive it from mutable post-source TMPDIR here.
    if not string match -q '/*' -- "$tmp_parent"; or not test -d "$tmp_parent"; or not test -w "$tmp_parent"; or not test -x "$tmp_parent"
        return 125
    end
    if not sp_fish_loader_path_is_physical "$durable_file"
        return 125
    end
    set -l verify_root ("$mktemp_path" -d "$tmp_parent/valise-fish-persistence.XXXXXX" 2>/dev/null)
    if test $status -ne 0; or test (builtin count $verify_root) -ne 1
        return 125
    end
    if not "$mkdir_path" -p "$verify_root/fish"; or not "$ln_path" -s "$durable_file" "$verify_root/fish/fish_variables"
        if not "$rm_path" -rf -- "$verify_root" 2>/dev/null
            return 125
        end
        return 125
    end
    set -lx XDG_CONFIG_HOME "$verify_root"
    set -l actual ("$fish_path" -c '
        set -l name $argv[1]
        # An exported global is inherited by the verifier child and hides the
        # universal value we are checking. Remove only that child-local shadow
        # before reading the durable universal store.
        if builtin set -q -g -- $name
            set -l global_values $$name
            builtin set -e -g -- $name; or exit 125
        end
        if builtin set -q -U -- $name
            builtin printf "1\n"
            if builtin set -q -Ux -- $name
                builtin printf "1\n"
            else
                builtin printf "0\n"
            end
            string escape -- $$name
        else
            builtin printf "0\n0\n"
        end
    ' -- "$scope_name" 2>/dev/null)
    set -l child_status $status
    if not "$rm_path" -rf -- "$verify_root" 2>/dev/null
        return 125
    end
    if test $child_status -ne 0
        return 125
    end
    set -l expected $expected_present $expected_exported
    set -a expected (string escape -- $expected_values)
    if test (builtin count $actual) -ne (builtin count $expected)
        return 125
    end
    set -l value_index 1
    while test $value_index -le (builtin count $expected)
        if not builtin test "$actual[$value_index]" = "$expected[$value_index]"
            return 125
        end
        set value_index (builtin math $value_index + 1)
    end
    return 0
end

function _sp_fish_loader_restore_scope --no-scope-shadowing --description 'Restore and verify one protected Fish scope'
    set -l scope_name $argv[1]
    set -l scope_index $argv[2]
    # Production callers pass the path captured before untrusted source runs.
    # Keep direct private-helper tests and legacy callers functional by
    # resolving it only when no authenticated path was supplied.
    set -l durable_file $argv[3]
    set -l tmp_parent $argv[4]
    if test -z "$durable_file"
        set -l fallback_config_home ''
        if builtin set -q XDG_CONFIG_HOME; and test -n "$XDG_CONFIG_HOME"
            set fallback_config_home "$XDG_CONFIG_HOME"
        else if builtin set -q HOME; and test -n "$HOME"
            set fallback_config_home "$HOME/.config"
        else
            return 125
        end
        set durable_file "$fallback_config_home/fish/fish_variables"
    end
    if test -z "$tmp_parent"
        set tmp_parent /tmp
        if builtin set -q TMPDIR; and test -n "$TMPDIR"
            set tmp_parent "$TMPDIR"
        end
        set tmp_parent (builtin path resolve -- "$tmp_parent" 2>/dev/null)
        if test (builtin count $tmp_parent) -ne 1
            return 125
        end
    end
    set -l before_global_present_value "$scope_before_global_present_values[$scope_index]"
    set -l before_global_exported_value "$scope_before_global_exported_values[$scope_index]"
    set -l before_global_value_offset "$scope_before_global_value_offsets[$scope_index]"
    set -l before_global_value_count "$scope_before_global_value_counts[$scope_index]"
    set -l before_global_values
    if test "$before_global_value_count" -gt 0
        set -l before_global_value_end (builtin math $before_global_value_offset + $before_global_value_count - 1)
        set before_global_values $scope_before_global_flat_values[$before_global_value_offset..$before_global_value_end]
    end
    set -l before_universal_present_value "$scope_before_present_values[$scope_index]"
    set -l before_universal_exported_value "$scope_before_exported_values[$scope_index]"
    set -l before_universal_value_offset "$scope_before_value_offsets[$scope_index]"
    set -l before_universal_value_count "$scope_before_value_counts[$scope_index]"
    set -l before_universal_values
    if test "$before_universal_value_count" -gt 0
        set -l before_universal_value_end (builtin math $before_universal_value_offset + $before_universal_value_count - 1)
        set before_universal_values $scope_before_flat_values[$before_universal_value_offset..$before_universal_value_end]
    end

    # Erase only scopes that are present. Fish reports an absent-scope erase as
    # failure, so probing first distinguishes an expected absence from a failed
    # persistent mutation. Every mutation is checked before proceeding.
    if builtin set -q -g "$scope_name"
        builtin set -e -g "$scope_name"; or return 125
    end
    if builtin set -q -U "$scope_name"
        builtin set -e -U "$scope_name"; or return 125
    end
    # Materialize the universal before-image while it is not hidden by a
    # recreated global binding. This avoids Fish reporting a false persistent
    # mutation failure on the subsequent global restore.
    if test "$before_universal_present_value" = 1
        set -l restore_universal_flags -U
        if test "$before_universal_exported_value" = 1
            set restore_universal_flags -Ux
        end
        builtin set $restore_universal_flags "$scope_name" $before_universal_values
        if test $status -ne 0
            return 125
        end
    end
    if test "$before_global_present_value" = 1
        set -l restore_global_flags -g
        if test "$before_global_exported_value" = 1
            set restore_global_flags -gx
        end
        builtin set $restore_global_flags "$scope_name" $before_global_values
        if test $status -ne 0
            return 125
        end
    end

    # Verify global presence, export status, and every value exactly.
    set -l actual_global_present_value 0
    builtin set -q -g "$scope_name"; and set actual_global_present_value 1
    set -l actual_global_exported_value 0
    builtin set -q -gx "$scope_name"; and set actual_global_exported_value 1
    set -l actual_global_values
    if test "$actual_global_present_value" = 1
        set actual_global_values $$scope_name
    end
    if test "$actual_global_present_value" != "$before_global_present_value"; or test "$actual_global_exported_value" != "$before_global_exported_value"; or test (builtin count $actual_global_values) -ne "$before_global_value_count"
        return 125
    end
    set -l value_index 1
    while test $value_index -le (builtin count $before_global_values)
        if not builtin test "$before_global_values[$value_index]" = "$actual_global_values[$value_index]"
            return 125
        end
        set value_index (builtin math $value_index + 1)
    end

    # A global binding hides a universal binding in Fish. Temporarily hide the
    # already-verified global value to inspect the universal before-image, then
    # restore and re-verify the global scope.
    set -l hid_global 0
    if builtin set -q -g "$scope_name"
        builtin set -e -g "$scope_name"; or return 125
        set hid_global 1
    end
    set -l actual_universal_present_value 0
    builtin set -q -U "$scope_name"; and set actual_universal_present_value 1
    set -l actual_universal_exported_value 0
    builtin set -q -Ux "$scope_name"; and set actual_universal_exported_value 1
    set -l actual_universal_values
    if test "$actual_universal_present_value" = 1
        set actual_universal_values $$scope_name
    end
    if test "$actual_universal_present_value" != "$before_universal_present_value"; or test "$actual_universal_exported_value" != "$before_universal_exported_value"; or test (builtin count $actual_universal_values) -ne "$before_universal_value_count"
        if test $hid_global -eq 1
            set -l restore_global_flags -g
            if test "$before_global_exported_value" = 1
                set restore_global_flags -gx
            end
            builtin set $restore_global_flags "$scope_name" $before_global_values
            if test $status -ne 0
                return 125
            end
        end
        return 125
    end
    set value_index 1
    while test $value_index -le (builtin count $before_universal_values)
        if not builtin test "$before_universal_values[$value_index]" = "$actual_universal_values[$value_index]"
            if test $hid_global -eq 1
                set -l restore_global_flags -g
                if test "$before_global_exported_value" = 1
                    set restore_global_flags -gx
                end
                builtin set $restore_global_flags "$scope_name" $before_global_values
                if test $status -ne 0
                    return 125
                end
            end
            return 125
        end
        set value_index (builtin math $value_index + 1)
    end
    # Fish can update the current process while failing to persist the
    # universal value to fish_variables. Verify the durable image from a
    # fresh trusted Fish process before declaring the rollback successful.
    # Run this even for an absent before-image: a poisoned universal can be
    # left in fish_variables after an in-process erase appears to succeed.
    _sp_fish_loader_verify_universal_persistence "$durable_file" "$tmp_parent" "$scope_name" "$before_universal_present_value" "$before_universal_exported_value" $before_universal_values
    set -l persistence_status $status
    if test $persistence_status -ne 0
        if test $hid_global -eq 1
            set -l restore_global_flags -g
            if test "$before_global_exported_value" = 1
                set restore_global_flags -gx
            end
            builtin set $restore_global_flags "$scope_name" $before_global_values
            if test $status -ne 0
                return 125
            end
        end
        return 125
    end
    if test $hid_global -eq 1
        set -l restore_global_flags -g
        if test "$before_global_exported_value" = 1
            set restore_global_flags -gx
        end
        builtin set $restore_global_flags "$scope_name" $before_global_values
        if test $status -ne 0
            return 125
        end
    end
    return 0
end

function sp_fish_loader_platform_name --description 'Return the host platform using a trusted uname path'
    set -l uname_path ''
    for candidate in /usr/bin/uname /bin/uname
        if test -x "$candidate"
            set uname_path $candidate
            break
        end
    end
    test -n "$uname_path"; or return 1
    switch ("$uname_path" -s 2>/dev/null)
        case Darwin
            echo darwin
        case Linux
            echo linux
        case FreeBSD
            echo freebsd
        case OpenBSD
            echo openbsd
        case NetBSD
            echo netbsd
        case '*BSD'
            echo bsd
        case '*'
            echo unknown
    end
    return 0
end

function sp_fish_loader_normalize_path --description 'Normalize only verified macOS compatibility aliases'
    set -l path_value $argv[1]
    # macOS exposes /tmp and /var as compatibility symlinks to /private/*.
    # Do not apply that spelling on other systems: /var and /tmp are ordinary
    # project paths there and must be checked exactly as supplied.
    if test (sp_fish_loader_platform_name) = darwin
        if test -L /tmp; and test (path resolve -- /tmp) = /private/tmp
            switch "$path_value"
                case /tmp
                    set path_value /private/tmp
                case '/tmp/*'
                    set path_value (string replace -r '^/tmp' /private/tmp -- "$path_value")
            end
        end
        if test -L /var; and test (path resolve -- /var) = /private/var
            switch "$path_value"
                case /var
                    set path_value /private/var
                case '/var/*'
                    set path_value (string replace -r '^/var' /private/var -- "$path_value")
            end
        end
    end
    echo $path_value
    return 0
end

function sp_fish_loader_path_is_physical --description 'Reject relative, dot-segment, or symlinked path components'
    set -l path_value (sp_fish_loader_normalize_path "$argv[1]")
    or return 1
    string match -q '/*' -- "$path_value"; or return 1
    string match -q '*//*' -- "$path_value"; and return 1
    set -l prefix /
    for component in (string split '/' -- "$path_value")
        if test -z "$component"
            continue
        end
        switch "$component"
            case . ..
                return 1
        end
        if test "$prefix" = /
            set prefix "/$component"
        else
            set prefix "$prefix/$component"
        end
        if test -L "$prefix"
            return 1
        end
    end
    return 0
end

function sp_fish_loader_add_root --description 'Add a module discovery root directory'
    set -l root_dir $argv[1]
    set root_dir (sp_fish_loader_normalize_path "$root_dir")
    or begin
        sp_fish_loader_error "module root cannot be normalized: $argv[1]"
        return 1
    end
    if not sp_fish_loader_path_is_physical "$root_dir"
        sp_fish_loader_error "module root contains a symlink or unsafe component: $root_dir"
        return 1
    end
    if not test -d "$root_dir"
        sp_fish_loader_error "module root is not a directory: $root_dir"
        return 1
    end
    set -g _sp_fish_module_roots $_sp_fish_module_roots $root_dir
    return 0
end

function sp_fish_loader_files_equal --description 'Compare provider files with a trusted system utility'
    set -l first_file $argv[1]
    set -l second_file $argv[2]
    for cmp_path in /usr/bin/cmp /bin/cmp
        if test -x "$cmp_path"
            "$cmp_path" -s -- "$first_file" "$second_file"
            return $status
        end
    end
    sp_fish_loader_error 'trusted cmp utility is unavailable'
    return 1
end

function sp_fish_loader_provider_version --description 'Print the version of a parsed metadata record'
    set -l version_line (string match 'version=*' -- $argv)
    string replace 'version=' '' -- $version_line
end

function sp_fish_loader_validate_provider_conflicts --description 'Reject conflicting duplicate metadata or Fish bodies'
    set -l mod_name $argv[1]
    set -l primary_meta $argv[2]
    set -l primary_root $argv[3]
    set -l primary_parsed (sp_fish_metadata_read "$primary_meta")
    if test $status -ne 0
        return 1
    end
    set -l primary_load_line (string match 'load=*' -- $primary_parsed)
    set -l primary_load (string replace 'load=' '' -- $primary_load_line)

    for root in $_sp_fish_module_roots
        for meta_dir in "$root/module.d"
            set -l candidate "$meta_dir/$mod_name.meta"
            if test "$candidate" = "$primary_meta"
                continue
            end
            if not test -e "$candidate"; and not test -L "$candidate"
                continue
            end
            if not sp_fish_loader_path_is_physical "$candidate"
                sp_fish_loader_error "metadata path contains a symlink: $candidate"
                return 1
            end
            if not test -f "$candidate"
                sp_fish_loader_error "metadata provider is not a regular file: $candidate"
                return 1
            end
            set -l candidate_parsed (sp_fish_metadata_read "$candidate")
            if test $status -ne 0
                sp_fish_loader_error "duplicate metadata provider cannot be validated: $candidate"
                return 1
            end
            if not sp_fish_loader_files_equal "$primary_meta" "$candidate"
                set -l primary_version (sp_fish_loader_provider_version $primary_parsed)
                set -l candidate_version (sp_fish_loader_provider_version $candidate_parsed)
                if test "$primary_version" != "$candidate_version"
                    if test -z "$primary_version"; set primary_version unversioned; end
                    if test -z "$candidate_version"; set candidate_version unversioned; end
                    sp_fish_loader_error "conflicting versions are forbidden for module $mod_name: version $primary_version at $primary_meta vs version $candidate_version at $candidate (vendor a single version)"
                    return 1
                end
                sp_fish_loader_error "conflicting metadata providers for module: $mod_name"
                return 1
            end
            set -l candidate_load_line (string match 'load=*' -- $candidate_parsed)
            set -l candidate_load (string replace 'load=' '' -- $candidate_load_line)
            # Generic .sh/load_hook providers are graph metadata only for Fish;
            # they have no native body whose ownership can be compared.
            if not string match -q '*.fish' -- "$primary_load"; or not string match -q '*.fish' -- "$candidate_load"
                continue
            end
            set -l primary_body "$primary_root/$primary_load"
            set -l candidate_root (sp_fish_loader_provider_for_meta "$candidate" "$mod_name")
            if test $status -ne 0; or test -z "$candidate_root"
                sp_fish_loader_error "duplicate metadata provider root unavailable: $candidate"
                return 1
            end
            set -l candidate_body "$candidate_root/$candidate_load"
            set -l primary_body_exists 0
            set -l candidate_body_exists 0
            if test -e "$primary_body"; or test -L "$primary_body"
                set primary_body_exists 1
            end
            if test -e "$candidate_body"; or test -L "$candidate_body"
                set candidate_body_exists 1
            end
            if test $primary_body_exists -ne $candidate_body_exists
                sp_fish_loader_error "conflicting Fish body presence for module: $mod_name"
                return 1
            end
            if test $primary_body_exists -eq 1
                if not sp_fish_loader_path_is_physical "$primary_body"; or not sp_fish_loader_path_is_physical "$candidate_body"
                    sp_fish_loader_error "duplicate Fish body path contains a symlink for module: $mod_name"
                    return 1
                end
                if not test -f "$primary_body"; or not test -f "$candidate_body"
                    sp_fish_loader_error "duplicate Fish body is not a regular file for module: $mod_name"
                    return 1
                end
                if not sp_fish_loader_files_equal "$primary_body" "$candidate_body"
                    sp_fish_loader_error "conflicting Fish body providers for module: $mod_name"
                    return 1
                end
            end
        end
    end
    return 0
end

function sp_fish_loader_find_meta --description 'Find a .meta file across all registered roots'
    set -l mod_name $argv[1]
    set -g _sp_fish_metadata_provider
    set -l selected_meta ''
    set -l selected_root ''
    for root in $_sp_fish_module_roots
        # Each registered root owns only its own module.d directory. Generic
        # roots are registered separately, so a Fish root cannot accidentally
        # bind generic metadata to a Fish body path.
        for meta_dir in "$root/module.d"
            set -l candidate "$meta_dir/$mod_name.meta"
            if not test -e "$candidate"; and not test -L "$candidate"
                continue
            end
            if not sp_fish_loader_path_is_physical "$candidate"
                sp_fish_loader_error "metadata path contains a symlink: $candidate"
                return 1
            end
            if not test -f "$candidate"
                sp_fish_loader_error "metadata provider is not a regular file: $candidate"
                return 1
            end
            if test -z "$selected_meta"
                set selected_meta "$candidate"
                set selected_root "$root"
                continue
            end
            if not sp_fish_loader_files_equal "$selected_meta" "$candidate"
                set -l selected_parsed (sp_fish_metadata_read "$selected_meta")
                if test $status -ne 0
                    sp_fish_loader_error "duplicate metadata provider cannot be validated: $selected_meta"
                    return 1
                end
                set -l candidate_parsed (sp_fish_metadata_read "$candidate")
                if test $status -ne 0
                    sp_fish_loader_error "duplicate metadata provider cannot be validated: $candidate"
                    return 1
                end
                set -l selected_version (sp_fish_loader_provider_version $selected_parsed)
                set -l candidate_version (sp_fish_loader_provider_version $candidate_parsed)
                if test "$selected_version" != "$candidate_version"
                    if test -z "$selected_version"; set selected_version unversioned; end
                    if test -z "$candidate_version"; set candidate_version unversioned; end
                    sp_fish_loader_error "conflicting versions are forbidden for module $mod_name: version $selected_version at $selected_meta vs version $candidate_version at $candidate (vendor a single version)"
                    return 1
                end
                sp_fish_loader_error "conflicting metadata providers for module: $mod_name"
                return 1
            end
        end
    end
    if test -z "$selected_meta"
        return 1
    end
    if not sp_fish_loader_validate_provider_conflicts "$mod_name" "$selected_meta" "$selected_root"
        return 1
    end
    set -g _sp_fish_metadata_provider "$selected_root"
    echo "$selected_meta"
    return 0
end

function sp_fish_loader_provider_for_meta --description 'Resolve the root that supplied metadata'
    set -l meta_file $argv[1]
    set -l mod_name $argv[2]
    for root in $_sp_fish_module_roots
        for meta_dir in "$root/module.d"
            if test "$meta_file" = "$meta_dir/$mod_name.meta"
                echo "$root"
                return 0
            end
        end
    end
    return 1
end

function _sp_fish_loader_load_ordered_impl --description 'Load modules from seeds via topological sort (Kahn algorithm)'
    set -l mode $argv[1]
    set -l seeds $argv[2..-1]
    set -l explicit_seeds $seeds

    if test "$mode" != strict; and test "$mode" != permissive
        sp_fish_loader_error "invalid loader mode: $mode (must be strict or permissive)"
        return 1
    end

    # Do not let caller-defined functions shadow the builtins used by the
    # discovery and graph phases. Preserve the caller-owned shadow and fail
    # closed; erasing it would destroy its exact Fish provenance/ownership.
    set -l shadowable_builtins contains test string source path functions set printf echo math count
    for shadowed_name in $shadowable_builtins
        if builtin functions -q "$shadowed_name"
            builtin printf 'loader: caller shadowed critical Fish builtin: %s\n' "$shadowed_name" >&2
            return 1
        end
    end
    # `cd` is a Fish function, not a builtin. Accept Fish's embedded
    # definition or the function from a recognized installation path; reject
    # other definitions before they can affect root discovery.
    for path_builtin in cd pwd
        if builtin functions -q "$path_builtin"
            set -l path_builtin_source (builtin functions --details "$path_builtin")
            if test "$path_builtin" = cd; and builtin contains -- "$path_builtin_source" \
                    embedded:functions/cd.fish \
                    /usr/share/fish/functions/cd.fish \
                    /usr/local/share/fish/functions/cd.fish \
                    /opt/local/share/fish/functions/cd.fish \
                    /opt/homebrew/share/fish/functions/cd.fish
                continue
            end
            builtin printf 'loader: caller shadowed critical Fish builtin: %s\n' "$path_builtin" >&2
            return 1
        end
    end

    # Discovery itself calls loader helpers. Validate that those helpers still
    # originate from this loader file before consulting any metadata or body
    # provider. A caller-defined replacement must not get a chance to redirect
    # root precedence; re-source the verified loader file to restore it, then
    # fail the current request closed.
    set -l loader_source_file (builtin functions --details _sp_fish_loader_load_ordered_impl)
    if not builtin set -q _sp_fish_loader_expected_source; or not builtin test "$loader_source_file" = "$_sp_fish_loader_expected_source"
        builtin printf 'loader: cannot verify loader function source\n' >&2
        return 1
    end
    set -l metadata_source_file (builtin functions --details sp_fish_metadata_read)
    if not builtin set -q _sp_fish_metadata_expected_source; or not builtin test "$metadata_source_file" = "$_sp_fish_metadata_expected_source"
        builtin printf 'loader: cannot verify metadata function source\n' >&2
        return 1
    end
    set -l critical_loader_functions sp_fish_loader_error _sp_fish_loader_rollback_activation sp_fish_loader_source_body _sp_fish_loader_function_definition_matches _sp_fish_loader_function_definition_matches_text _sp_fish_loader_function_copy_matches _sp_fish_loader_function_copy_matches_definition _sp_fish_loader_function_provenance_matches _sp_fish_loader_is_trusted_system_function_source _sp_fish_loader_capture_scope _sp_fish_loader_verify_universal_persistence _sp_fish_loader_restore_scope sp_fish_loader_path_is_physical sp_fish_loader_platform_name sp_fish_loader_normalize_path sp_fish_loader_add_root sp_fish_loader_files_equal sp_fish_loader_validate_provider_conflicts sp_fish_loader_find_meta sp_fish_loader_provider_for_meta _sp_fish_loader_load_ordered_impl _sp_fish_loader_dispatch _sp_fish_loader_init
    for critical_name in $critical_loader_functions
        set -l critical_source (builtin functions --details "$critical_name")
        if not builtin test "$critical_source" = "$_sp_fish_loader_expected_source"
            # The function-reported path is attacker-controlled once a caller
            # has replaced a loader helper. Never source it as a purported
            # restoration target: a suffix such as an attacker-owned
            # `loader.fish` is not source authentication. Leave the namespace
            # untouched and fail closed before any embedded critical function
            # can be restored or any attacker path can be sourced again.
            builtin printf 'loader: caller shadowed critical loader helper: %s\n' "$critical_name" >&2
            return 1
        end
    end

    set -l critical_metadata_functions sp_fish_metadata_error sp_fish_metadata_validate_identifier sp_fish_metadata_validate_identifier_list sp_fish_metadata_validate_shell_list sp_fish_metadata_validate_platform_list sp_fish_metadata_validate_relative_path sp_fish_metadata_validate_side_effect sp_fish_metadata_validate_source_side_effect sp_fish_metadata_read
    for critical_name in $critical_metadata_functions
        set -l critical_source (builtin functions --details "$critical_name")
        if not builtin test "$critical_source" = "$metadata_source_file"
            builtin printf 'loader: caller shadowed critical metadata helper: %s\n' "$critical_name" >&2
            return 1
        end
    end

    set -l discovered
    set -l queue $seeds
    set -l meta_cache
    set -l meta_provider_modules
    set -l meta_provider_paths
    set -l optional_modules
    set -l shell_skipped_modules
    set -l failed_modules
    set -l runtime_failed_modules

    # Phase 1: BFS discovery — collect all reachable modules and their metadata
    while test (count $queue) -gt 0
        set -l current $queue[1]
        set -e queue[1]

        # Skip if already discovered
        if builtin contains -- $current $discovered
            continue
        end
        set -a discovered $current

        # Find and parse metadata. Resolve the provider in the caller scope;
        # Fish command substitutions do not propagate variable assignments.
        set -l meta_file (sp_fish_loader_find_meta $current)
        if test $status -ne 0
            if builtin contains -- $current $optional_modules
                sp_fish_loader_error "warning: optional module not found: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "module not found: $current"
                return 1
            end
            set -a failed_modules $current
            continue
        end

        set -l parsed (sp_fish_metadata_read "$meta_file")
        if test $status -ne 0
            if builtin contains -- $current $optional_modules
                sp_fish_loader_error "warning: optional metadata invalid for: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "metadata invalid for: $current"
                return 1
            end
            set -a failed_modules $current
            continue
        end

        # Cache the complete record as one delimiter-separated value. Fish
        # expands list-valued command substitutions into multiple arguments;
        # join the fields first so every metadata record remains intact.
        set -l meta_provider (sp_fish_loader_provider_for_meta "$meta_file" "$current")
        if test $status -ne 0; or test -z "$meta_provider"
            sp_fish_loader_error "metadata provider unavailable for: $current"
            return 1
        end
        set -l parsed_record (string join '|' -- $parsed)
        set -a meta_cache "$current|$parsed_record"

        # Bind the body provider to the metadata provider before applying any
        # source-language gates. A shell-skipped record is still a valid generic
        # graph record, but must not be subjected to Fish source restrictions.
        set -a meta_provider_modules $current
        set -a meta_provider_paths "$meta_provider"

        # Preserve the generic ABI's filename identity and platform gates.
        set -l name_line (string match 'name=*' -- $parsed)
        set -l name_val (string replace 'name=' '' -- $name_line)
        if test "$name_val" != "$current"
            if builtin contains -- $current $optional_modules
                sp_fish_loader_error "warning: metadata name mismatch for optional module: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "metadata name mismatch for $current: $name_val"
                return 1
            end
            set -a failed_modules $current
            continue
        end

        set -l platform_line (string match 'platforms=*' -- $parsed)
        set -l platform_val (string replace 'platforms=' '' -- $platform_line)
        set -l current_platform (sp_fish_loader_platform_name)
        test -n "$current_platform"; or set current_platform unknown
        set -l platform_match 0
        for platform in (string split ' ' -- $platform_val)
            if test -z "$platform"
                continue
            end
            if test "$platform" = any; or test "$platform" = "$current_platform"; or begin
                test "$platform" = bsd; and string match -q -r '^(bsd|freebsd|openbsd|netbsd)$' -- "$current_platform"
            end
                set platform_match 1
                break
            end
        end
        if test $platform_match -ne 1
            if builtin contains -- $current $optional_modules
                sp_fish_loader_error "warning: optional module unsupported on platform: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "unsupported platform for $current: $current_platform"
                return 1
            end
            set -a failed_modules $current
            continue
        end

        # Shell gate: modules without native Fish syntax are skipped, not
        # treated as failed dependencies. A directly-requested seed is a
        # caller request like any other, so it follows the ABI's mode
        # contract: strict mode fails closed — matching the POSIX loader's
        # strict-required failure for a shell-mismatched requested module —
        # and permissive mode reports the affected module and continues.
        # Discovered dependencies keep the satisfied-by-skip semantics.
        set -l shells_line (string match 'shells=*' -- $parsed)
        set -l shells_val (string replace 'shells=' '' -- $shells_line)
        if not builtin contains fish (string split ' ' -- $shells_val)
            if builtin contains -- $current $explicit_seeds
                if test "$mode" = strict
                    sp_fish_loader_error "unsupported shell for $current: fish"
                    return 1
                end
                sp_fish_loader_error "warning: requested module unsupported on fish: $current"
            end
            set -a shell_skipped_modules $current
            continue
        end

        # A Fish-advertised module must provide a native Fish body. Generic
        # load_hook records and POSIX .sh bodies are not executable Fish
        # providers and must not satisfy required Fish dependents.
        set -l load_line (string match 'load=*' -- $parsed)
        set -l load_val (string replace 'load=' '' -- $load_line)
        if test -z "$load_val"; or not string match -q '*.fish' -- $load_val
            if builtin contains -- $current $optional_modules; and not builtin contains -- $current $explicit_seeds
                sp_fish_loader_error "warning: optional Fish module has no native .fish load path: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "Fish module has no native .fish load path: $current"
                return 1
            end
            set -a failed_modules $current
            sp_fish_loader_error "warning: Fish module has no native .fish load path: $current"
            continue
        end

        # Fish is an ordinary source phase. Apply this only after shell and
        # native-body selection: non-Fish modules are skipped, not rejected for
        # having an install/update-only side-effect class.
        set -l side_effect_line (string match 'side_effect=*' -- $parsed)
        set -l side_effect_val (string replace 'side_effect=' '' -- $side_effect_line)
        if not sp_fish_metadata_validate_source_side_effect "$side_effect_val"
            if builtin contains -- $current $optional_modules
                sp_fish_loader_error "warning: optional module has disallowed side effect: $current"
                set -a failed_modules $current
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "side effect not allowed during Fish source: $current"
                return 1
            end
            set -a failed_modules $current
            sp_fish_loader_error "warning: side effect not allowed during Fish source: $current"
            continue
        end

        # Enqueue requires dependencies
        set -l req_line (string match 'requires=*' -- $parsed)
        set -l req_val (string replace 'requires=' '' -- $req_line)
        for dep in (string split ' ' -- $req_val)
            if test -z "$dep"
                continue
            end
            if builtin contains -- $current $optional_modules; and not builtin contains -- $dep $optional_modules; and not builtin contains -- $dep $explicit_seeds
                set -a optional_modules $dep
            end
            if not builtin contains -- $dep $discovered
                set -a queue $dep
            end
        end

        # Enqueue optional dependencies (best-effort)
        set -l opt_line (string match 'optional=*' -- $parsed)
        set -l opt_val (string replace 'optional=' '' -- $opt_line)
        for dep in (string split ' ' -- $opt_val)
            if test -z "$dep"
                continue
            end
            if not builtin contains -- $dep $optional_modules; and not builtin contains -- $dep $explicit_seeds
                set -a optional_modules $dep
            end
            if not builtin contains -- $dep $discovered
                set -a queue $dep
            end
        end
    end

    # Phase 2: Kahn's algorithm for deterministic topological sort
    set -l remaining $discovered
    set -l ordered
    set -l loaded_set

    while test (count $remaining) -gt 0
        set -l progress 0
        set -l next_remaining

        for mod in $remaining
            if builtin contains -- $mod $failed_modules
                # Remove failed/optional nodes from the pending graph without
                # putting them in loaded_set: required dependents must see the
                # failure below rather than treating it as satisfied.
                set progress 1
                continue
            end
            if builtin contains -- $mod $shell_skipped_modules
                # A non-Fish module is not part of the native Fish graph.
                set progress 1
                continue
            end
            # Get this module's requires and optional dependencies from cache.
            set -l mod_reqs
            set -l mod_optional
            for entry in $meta_cache
                set -l entry_name (string split '|' -- $entry)[1]
                if test "$entry_name" = "$mod"
                    set -l entry_parsed (string split '|' -- $entry)[2..-1]
                    set -l req_line (string match 'requires=*' -- $entry_parsed)
                    if test -n "$req_line"
                        set -l req_val (string replace 'requires=' '' -- $req_line)
                        set mod_reqs (string split ' ' -- $req_val)
                    end
                    set -l opt_line (string match 'optional=*' -- $entry_parsed)
                    if test -n "$opt_line"
                        set -l opt_val (string replace 'optional=' '' -- $opt_line)
                        set mod_optional (string split ' ' -- $opt_val)
                    end
                    break
                end
            end

            # Check if all requires are satisfied
            set -l all_met 1
            for dep in $mod_reqs
                if test -z "$dep"
                    continue
                end
                if not builtin contains -- $dep $loaded_set
                    if builtin contains -- $dep $failed_modules
                        set -a failed_modules $mod
                        set all_met 0
                        set progress 1
                        if builtin contains -- $mod $optional_modules
                            break
                        end
                        if test "$mode" = strict
                            sp_fish_loader_error "required dependency failed: $dep (needed by $mod)"
                            return 1
                        end
                        sp_fish_loader_error "warning: required dependency failed: $dep (needed by $mod)"
                        break
                    end
                    # A non-Fish module is not a Fish load prerequisite.
                    if builtin contains -- $dep $shell_skipped_modules
                        continue
                    end
                    set all_met 0
                    break
                end
            end

            # Optional dependencies are soft but ordered before the parent
            # whenever their Fish bodies are available.
            if test $all_met -eq 1
                for dep in $mod_optional
                    if test -z "$dep"
                        continue
                    end
                    if builtin contains -- $dep $loaded_set
                        continue
                    end
                    if builtin contains -- $dep $failed_modules; or builtin contains -- $dep $shell_skipped_modules
                        continue
                    end
                    set all_met 0
                    break
                end
            end

            if test $all_met -eq 1
                set -a ordered $mod
                set -a loaded_set $mod
                set progress 1
            else
                set -a next_remaining $mod
            end
        end

        if test $progress -eq 0
            sp_fish_loader_error "cycle detected in module graph: $next_remaining"
            set -l strict_cycle_failure 0
            # Never promote a hard-cycle member merely because one of its
            # required dependencies was quarantined. Required edges are only
            # satisfied by loaded_set; every non-optional cycle node is itself
            # quarantined in permissive mode and fails strict mode.
            for cycle_mod in $next_remaining
                if builtin contains -- $cycle_mod $optional_modules
                    set -a failed_modules $cycle_mod
                else
                    set strict_cycle_failure 1
                    set -a failed_modules $cycle_mod
                end
            end
            if test "$mode" = strict; and test $strict_cycle_failure -ne 0
                return 1
            end
            # Recovery may have promoted optional-cycle nodes to loaded or
            # quarantined them. Remove both classes before the next pass so a
            # recovered module is never sourced twice.
            set -l cycle_remaining
            for cycle_candidate in $next_remaining
                if builtin contains -- $cycle_candidate $loaded_set; or builtin contains -- $cycle_candidate $failed_modules
                    continue
                end
                set -a cycle_remaining $cycle_candidate
            end
            set remaining $cycle_remaining
            continue
        end

        set remaining $next_remaining
    end

    # Phase 3: Source each module body in topological order
    for mod in $ordered
        if builtin contains -- $mod $failed_modules
            continue
        end
        # Shell-gated modules are valid graph members but have no Fish body to
        # source. Their dependencies were already treated as satisfied above.
        if builtin contains -- $mod $shell_skipped_modules
            continue
        end

        # A module is topologically ready before its body runs, but a body can
        # still fail at runtime. Do not let that failure satisfy a later hard
        # dependency, especially in permissive mode.
        set -l mod_reqs
        set -l mod_exports
        for entry in $meta_cache
            set -l entry_name (string split '|' -- $entry)[1]
            if test "$entry_name" = "$mod"
                set -l entry_parsed (string split '|' -- $entry)[2..-1]
                set -l req_line (string match 'requires=*' -- $entry_parsed)
                if test -n "$req_line"
                    set -l req_val (string replace 'requires=' '' -- $req_line)
                    set mod_reqs (string split ' ' -- $req_val)
                end
                set -l exports_line (string match 'exports=*' -- $entry_parsed)
                if test -n "$exports_line"
                    set -l exports_val (string replace 'exports=' '' -- $exports_line)
                    set mod_exports (string split ' ' -- $exports_val)
                end
                break
            end
        end
        set -l failed_required ''
        for dep in $mod_reqs
            if test -n "$dep"; and builtin contains -- $dep $runtime_failed_modules
                set failed_required $dep
                break
            end
        end
        if test -n "$failed_required"
            set -a runtime_failed_modules $mod
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: optional module skipped because required dependency failed: $failed_required (needed by $mod)"
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "required dependency failed at runtime: $failed_required (needed by $mod)"
                return 1
            end
            sp_fish_loader_error "warning: required dependency failed at runtime: $failed_required (needed by $mod)"
            continue
        end

        # Retrieve provider and load path from the parallel provider cache.
        set -l entry_provider ''
        set -l provider_index (builtin contains --index -- $mod $meta_provider_modules)
        if test -n "$provider_index"
            set entry_provider $meta_provider_paths[$provider_index]
        end
        set -l load_path ''
        for entry in $meta_cache
            set -l entry_name (string split '|' -- $entry)[1]
            if test "$entry_name" = "$mod"
                set -l entry_parsed (string split '|' -- $entry)[2..-1]
                set -l load_line (string match 'load=*' -- $entry_parsed)
                if test -n "$load_line"
                    set load_path (string replace 'load=' '' -- $load_line)
                end
                break
            end
        end

        if test -z "$load_path"
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: optional module has no load path: $mod"
                set -a failed_modules $mod
                set -a runtime_failed_modules $mod
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "no load path for module: $mod"
                return 1
            end
            set -a runtime_failed_modules $mod
            sp_fish_loader_error "warning: no load path for module: $mod"
            continue
        end

        # The load path must point to a .fish file
        if not string match -q '*.fish' -- $load_path
            # Skip POSIX bodies silently — Fish never sources them
            continue
        end

        # Resolve the body from the same provider root that supplied metadata.
        set -l body_file "$entry_provider/$load_path"
        if not sp_fish_loader_path_is_physical "$body_file"
            sp_fish_loader_error "body path contains a symlink: $body_file"
            set body_file ''
        else if not test -f "$body_file"
            set body_file ''
        end

        if test -z "$body_file"
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: optional body file not found for $mod: $load_path"
                set -a failed_modules $mod
                set -a runtime_failed_modules $mod
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "body file not found for $mod: $load_path"
                return 1
            end
            set -a runtime_failed_modules $mod
            sp_fish_loader_error "warning: body file not found for $mod: $load_path"
            continue
        end

        # Declared Fish exports are ownership claims. A pre-existing export is
        # accepted only when Fish reports that it came from this exact trusted
        # body file, which makes repeated public adapter sources idempotent
        # without allowing a caller-owned function to satisfy the claim.
        set -l preexisting_export ''
        for export_name in $mod_exports
            if test -n "$export_name"; and builtin functions -q "$export_name"
                set -l existing_export_source (builtin functions --details "$export_name")
                if not builtin test "$existing_export_source" = "$body_file"
                    set preexisting_export $export_name
                    break
                end
            end
        end
        if test -n "$preexisting_export"
            set -a runtime_failed_modules $mod
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: optional module export already exists: $preexisting_export (owned by $mod)"
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "declared export already exists before load: $preexisting_export"
                return 1
            end
            sp_fish_loader_error "warning: declared export already exists before load: $preexisting_export (skipping $mod)"
            continue
        end

        # Snapshot loader-critical builtin/function definitions immediately
        # before sourcing. A module body runs in this process, so redefining
        # a loader helper or builtin such as contains must fail closed before
        # any later graph bookkeeping can invoke the replacement. Fish ships
        # `cd` as an embedded function; erase any hostile replacement during
        # restoration and use `builtin cd` for root discovery.
        # Snapshot the complete Fish function namespace. A body may define
        # private helpers that are not listed in `exports`; those helpers are
        # still activation-owned and must not survive a failed body or strict
        # rollback. Names created by a successful body join the ownership
        # ledger so a later release switch removes them too.
        set -l function_names_before (builtin functions --all --names)
        set -l reserved_function_names contains test string source path functions set printf echo builtin math count cd pwd eval sp_fish_loader_error _sp_fish_loader_rollback_activation sp_fish_loader_source_body _sp_fish_loader_function_definition_matches _sp_fish_loader_function_definition_matches_text _sp_fish_loader_function_copy_matches _sp_fish_loader_function_copy_matches_definition _sp_fish_loader_function_provenance_matches _sp_fish_loader_is_trusted_system_function_source _sp_fish_loader_capture_scope _sp_fish_loader_verify_universal_persistence _sp_fish_loader_restore_scope sp_fish_loader_path_is_physical sp_fish_loader_platform_name sp_fish_loader_normalize_path sp_fish_loader_add_root sp_fish_loader_files_equal sp_fish_loader_validate_provider_conflicts sp_fish_loader_find_meta sp_fish_loader_provider_for_meta _sp_fish_loader_load_ordered_impl _sp_fish_loader_dispatch _sp_fish_loader_init sp_fish_metadata_error sp_fish_metadata_validate_identifier sp_fish_metadata_validate_identifier_list sp_fish_metadata_validate_shell_list sp_fish_metadata_validate_platform_list sp_fish_metadata_validate_relative_path sp_fish_metadata_validate_side_effect sp_fish_metadata_validate_source_side_effect sp_fish_metadata_read
        set -l reserved_function_before
        # Snapshot caller-owned functions with Fish's source-backed copy
        # primitive. A temporary source file followed by `source` changes the
        # function's ownership/provenance; `functions --copy` retains it. The
        # randomized aliases are verified before use and are never returned to
        # the module namespace.
        set -l caller_function_names_to_snapshot
        for caller_function_name in $function_names_before
            if builtin contains -- $caller_function_name $reserved_function_names
                continue
            end
            if not builtin functions -q "$caller_function_name"
                continue
            end
            set -l caller_function_source (builtin functions --details "$caller_function_name")
            if builtin string match -q 'embedded:*' -- "$caller_function_source"; or builtin string match -q 'autoloaded:*' -- "$caller_function_source"; or builtin string match -q 'builtin' -- "$caller_function_source"
                continue
            end
            set -a caller_function_names_to_snapshot "$caller_function_name"
        end
        set -l caller_function_snapshot_names
        set -l caller_function_snapshot_copies
        set -l caller_function_snapshot_sources
        set -l caller_function_snapshot_definition_offsets
        set -l caller_function_snapshot_definition_counts
        set -l caller_function_snapshot_definition_lines
        set -l caller_function_snapshot_definition_cursor 1
        set -l caller_function_snapshot_copy_definition_offsets
        set -l caller_function_snapshot_copy_definition_counts
        set -l caller_function_snapshot_copy_definition_lines
        set -l caller_function_snapshot_copy_definition_cursor 1
        set -l caller_function_snapshot_nonce (builtin random)
        set -l caller_function_snapshot_index 1
        for caller_function_name in $caller_function_names_to_snapshot
            set -l caller_function_source (builtin functions --details "$caller_function_name")
            set -l caller_function_snapshot "__sp_fish_loader_snapshot_"$caller_function_snapshot_nonce"_"$caller_function_snapshot_index
            set -l caller_function_copy_failed 0
            builtin functions --copy "$caller_function_name" "$caller_function_snapshot"; or set caller_function_copy_failed 1
            set -l caller_function_snapshot_source (builtin functions --details "$caller_function_snapshot")
            set -l caller_function_source_authenticated 0
            if builtin test "$caller_function_snapshot_source" = "$loader_source_file"
                set caller_function_source_authenticated 1
            else if _sp_fish_loader_is_trusted_system_function_source "$caller_function_source" "$caller_function_name"
                set caller_function_source_authenticated 1
            end
            set -l caller_function_copy_matches 0
            if _sp_fish_loader_function_copy_matches "$caller_function_name" "$caller_function_snapshot"; or _sp_fish_loader_is_trusted_system_function_source "$caller_function_source" "$caller_function_name"
                set caller_function_copy_matches 1
            end
            if builtin functions -q "$caller_function_snapshot"; and builtin test $caller_function_copy_failed -eq 0; and builtin test $caller_function_source_authenticated -eq 1; and builtin test $caller_function_copy_matches -eq 1
                # The source and complete definition were authenticated.
            else
                builtin functions -e "$caller_function_snapshot" 2>/dev/null; or builtin exit 125
                builtin printf 'loader: unable to source-authenticate caller Fish function: %s\n' "$caller_function_name" >&2
                return 125
            end
            set -l caller_function_snapshot_copy_lines (string split \n -- (builtin functions "$caller_function_snapshot" | string collect))
            set -a caller_function_snapshot_copy_definition_offsets $caller_function_snapshot_copy_definition_cursor
            set -a caller_function_snapshot_copy_definition_counts (builtin count $caller_function_snapshot_copy_lines)
            set -a caller_function_snapshot_copy_definition_lines $caller_function_snapshot_copy_lines
            set caller_function_snapshot_copy_definition_cursor (builtin math $caller_function_snapshot_copy_definition_cursor + (builtin count $caller_function_snapshot_copy_lines))
            set -a function_names_before "$caller_function_snapshot"
            set -a caller_function_snapshot_names "$caller_function_name"
            set -a caller_function_snapshot_copies "$caller_function_snapshot"
            set -a caller_function_snapshot_sources "$caller_function_source"
            set -l caller_function_definition_lines (string split \n -- (builtin functions "$caller_function_name" | string collect))
            set -a caller_function_snapshot_definition_offsets $caller_function_snapshot_definition_cursor
            set -a caller_function_snapshot_definition_counts (builtin count $caller_function_definition_lines)
            set -a caller_function_snapshot_definition_lines $caller_function_definition_lines
            set caller_function_snapshot_definition_cursor (builtin math $caller_function_snapshot_definition_cursor + (builtin count $caller_function_definition_lines))
            set caller_function_snapshot_index (builtin math $caller_function_snapshot_index + 1)
        end

        for reserved_name in $reserved_function_names
            set -a reserved_function_before (builtin functions --details "$reserved_name")
        end

        # Snapshot private loader globals before sourcing. Module bodies are
        # allowed to publish their declared functions, not to rewrite the
        # loader's discovery roots, provider cache, or loaded set.
        set -l loader_state_before_loaded_values $_sp_fish_loaded_modules
        set -l loader_state_before_roots_values $_sp_fish_module_roots
        set -l loader_state_before_provider_values $_sp_fish_metadata_provider
        set -l loader_state_before_owned_values $_sp_fish_loader_owned_exports
        set -l loader_state_before_owned_sources $_sp_fish_loader_owned_sources
        # The source-driven handshake and selected project root are also
        # protected state. A body must not turn its current load into the next
        # bootstrap request or redirect the next discovery root.
        builtin set -l bootstrap_mode_before_set 0
        builtin set -q _sp_fish_loader_bootstrap_mode; and builtin set bootstrap_mode_before_set 1
        builtin set -l bootstrap_mode_before_values $_sp_fish_loader_bootstrap_mode
        builtin set -l bootstrap_seeds_before_set 0
        builtin set -q _sp_fish_loader_bootstrap_seeds; and builtin set bootstrap_seeds_before_set 1
        builtin set -l bootstrap_seeds_before_values $_sp_fish_loader_bootstrap_seeds
        builtin set -l bootstrap_status_before_set 0
        builtin set -q _sp_fish_loader_bootstrap_status; and builtin set bootstrap_status_before_set 1
        builtin set -l bootstrap_status_before_values $_sp_fish_loader_bootstrap_status
        builtin set -l project_root_before_set 0
        builtin set -q SHELL_PROJECT_ROOT; and builtin set project_root_before_set 1
        builtin set -l project_root_before_values $SHELL_PROJECT_ROOT
        builtin set -l project_root_before_exported 0
        builtin set -q -x SHELL_PROJECT_ROOT; and builtin set project_root_before_exported 1
        builtin set -l project_root_before_global_set 0
        builtin set -q -g SHELL_PROJECT_ROOT; and builtin set project_root_before_global_set 1
        builtin set -l project_root_before_global_values
        if builtin test $project_root_before_global_set -eq 1
            builtin set project_root_before_global_values $SHELL_PROJECT_ROOT
        end
        builtin set -l project_root_before_global_exported 0
        builtin set -q -gx SHELL_PROJECT_ROOT; and builtin set project_root_before_global_exported 1
        builtin set -l readiness_before_set 0
        builtin set -q VALISE_FISH_READY; and builtin set readiness_before_set 1
        builtin set -l readiness_before_values $VALISE_FISH_READY
        builtin set -l readiness_before_exported 0
        builtin set -q -x VALISE_FISH_READY; and builtin set readiness_before_exported 1
        builtin set -l readiness_before_global_set 0
        builtin set -q -g VALISE_FISH_READY; and builtin set readiness_before_global_set 1
        builtin set -l readiness_before_global_values
        if builtin test $readiness_before_global_set -eq 1
            builtin set readiness_before_global_values $VALISE_FISH_READY
        end
        builtin set -l readiness_before_global_exported 0
        builtin set -q -gx VALISE_FISH_READY; and builtin set readiness_before_global_exported 1

        # Capture universal values independently. Fish's visible value prefers
        # global scope, so the trusted helper temporarily hides a global value
        # to read the universal value without serializing arbitrary bytes.
        # Authenticate the universal-variable store before sourcing any
        # metadata or module body. Untrusted Fish source may mutate
        # XDG_CONFIG_HOME, so rollback verification must use this captured
        # path rather than re-reading ambient state later.
        set -l persistence_config_home ''
        if builtin set -q XDG_CONFIG_HOME; and test -n "$XDG_CONFIG_HOME"
            set persistence_config_home "$XDG_CONFIG_HOME"
        else if builtin set -q HOME; and test -n "$HOME"
            set persistence_config_home "$HOME/.config"
        else
            builtin exit 125
        end
        set -l persistence_durable_file "$persistence_config_home/fish/fish_variables"
        if not sp_fish_loader_path_is_physical "$persistence_durable_file"
            builtin exit 125
        end
        # Capture an absolute, writable, searchable temp parent before any
        # untrusted metadata or module body runs. Verifiers receive this value
        # explicitly and never reread mutable TMPDIR during rollback.
        set -l persistence_tmp_parent /tmp
        if builtin set -q TMPDIR; and test -n "$TMPDIR"
            set persistence_tmp_parent "$TMPDIR"
        end
        set persistence_tmp_parent (builtin path resolve -- "$persistence_tmp_parent" 2>/dev/null)
        if test (builtin count $persistence_tmp_parent) -ne 1; or not test -d "$persistence_tmp_parent"; or not test -w "$persistence_tmp_parent"; or not test -x "$persistence_tmp_parent"
            builtin exit 125
        end

        set -l protected_scope_names _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status SHELL_PROJECT_ROOT VALISE_FISH_READY _sp_fish_loader_expected_source _sp_fish_metadata_expected_source _sp_fish_loaded_modules _sp_fish_module_roots _sp_fish_metadata_provider _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_legacy_owned_exports _sp_fish_legacy_owned_sources _sp_fish_metadata_owned_exports _sp_fish_metadata_owned_sources _sp_fish_entrypoint_owned_exports _sp_fish_entrypoint_owned_sources TMPDIR HOME
        # The capture helper writes its result through global names because
        # Fish has no by-reference local assignment. Copy every result into
        # loader-local variables immediately; module source runs with
        # --no-scope-shadowing and therefore cannot forge these locals by name.
        # The temporary global names are randomized as defense in depth and
        # are erased on every path below.
        # Clear both current randomized snapshots and the historical
        # predictable scratch namespace before and after the transaction. The
        # latter is private loader state, not caller data; retaining attacker
        # forged copies would violate the fail-closed state contract.
        for scope_snapshot_prefix in _sp_fish_loader_scope_before_ __sp_fish_loader_scope_before_ _sp_fish_loader_scope_after_ __sp_fish_loader_scope_after_
            for scope_snapshot_name in (builtin set --names | builtin string match -- "$scope_snapshot_prefix*")
                if builtin set -q -g "$scope_snapshot_name"
                builtin set -e -g "$scope_snapshot_name"; or builtin exit 125
            end
            if builtin set -q -U "$scope_snapshot_name"
                builtin set -e -U "$scope_snapshot_name"; or builtin exit 125
            end
            end
        end
        set -l scope_snapshot_nonce (builtin random)
        set -l scope_before_prefix "__sp_fish_loader_scope_before_"$scope_snapshot_nonce
        set -l scope_after_prefix "__sp_fish_loader_scope_after_"$scope_snapshot_nonce
        # Keep the snapshot in ordinary loader-local arrays. Fish has no
        # nested arrays, so the value arrays are flattened with an explicit
        # start offset and count per protected variable. Do not store names of
        # local variables and later indirect-expand them: that representation
        # is scope-sensitive and can silently become an empty value.
        set -l scope_before_global_present_values
        set -l scope_before_global_exported_values
        set -l scope_before_global_value_offsets
        set -l scope_before_global_value_counts
        set -l scope_before_global_flat_values
        set -l scope_before_global_value_cursor 1
        set -l scope_before_present_values
        set -l scope_before_exported_values
        set -l scope_before_value_offsets
        set -l scope_before_value_counts
        set -l scope_before_flat_values
        set -l scope_before_value_cursor 1
        for protected_scope_name in $protected_scope_names
            _sp_fish_loader_capture_scope "$protected_scope_name" "$scope_before_prefix"; or builtin exit 125
            set -l captured_global_present_var "$scope_before_prefix"_"$protected_scope_name"_global_present
            set -l captured_global_exported_var "$scope_before_prefix"_"$protected_scope_name"_global_exported
            set -l captured_global_values_var "$scope_before_prefix"_"$protected_scope_name"_global_values
            set -a scope_before_global_present_values $$captured_global_present_var
            set -a scope_before_global_exported_values $$captured_global_exported_var
            set -a scope_before_global_value_offsets $scope_before_global_value_cursor
            set -l captured_global_values $$captured_global_values_var
            set -a scope_before_global_value_counts (builtin count $captured_global_values)
            if test (builtin count $captured_global_values) -gt 0
                set -a scope_before_global_flat_values $captured_global_values
            end
            set scope_before_global_value_cursor (builtin math $scope_before_global_value_cursor + (builtin count $captured_global_values))
            set -l captured_present_var "$scope_before_prefix"_"$protected_scope_name"_present
            set -l captured_exported_var "$scope_before_prefix"_"$protected_scope_name"_exported
            set -l captured_values_var "$scope_before_prefix"_"$protected_scope_name"_values
            set -a scope_before_present_values $$captured_present_var
            set -a scope_before_exported_values $$captured_exported_var
            set -a scope_before_value_offsets $scope_before_value_cursor
            set -l captured_values $$captured_values_var
            set -a scope_before_value_counts (builtin count $captured_values)
            if test (builtin count $captured_values) -gt 0
                set -a scope_before_flat_values $captured_values
            end
            set scope_before_value_cursor (builtin math $scope_before_value_cursor + (builtin count $captured_values))
        end

        # Source the Fish body through a helper function. A `return N` in a
        # sourced body must return from the helper, not from this loader.
        sp_fish_loader_source_body "$body_file"
        builtin set -l src_status $status
        set -l function_names_after (builtin functions --all --names)
        set -l new_function_names
        for function_name in $function_names_after
            if not builtin contains -- $function_name $function_names_before
                set -a new_function_names $function_name
            end
        end
        set -l caller_function_mutation ''
        set -l caller_function_mutations
        set -l caller_embedded_mutation ''
        set -l caller_snapshot_compromised 0
        set -l caller_function_snapshot_index 1
        for caller_function_name in $caller_function_snapshot_names
            set -l caller_function_snapshot "$caller_function_snapshot_copies[$caller_function_snapshot_index]"
            set -l caller_function_source "$caller_function_snapshot_sources[$caller_function_snapshot_index]"
            set -l caller_function_definition_offset "$caller_function_snapshot_definition_offsets[$caller_function_snapshot_index]"
            set -l caller_function_definition_count "$caller_function_snapshot_definition_counts[$caller_function_snapshot_index]"
            set -l caller_function_definition_end (builtin math $caller_function_definition_offset + $caller_function_definition_count - 1)
            set -l caller_function_definition $caller_function_snapshot_definition_lines[$caller_function_definition_offset..$caller_function_definition_end]
            set -l caller_function_snapshot_copy_definition_offset "$caller_function_snapshot_copy_definition_offsets[$caller_function_snapshot_index]"
            set -l caller_function_snapshot_copy_definition_count "$caller_function_snapshot_copy_definition_counts[$caller_function_snapshot_index]"
            set -l caller_function_snapshot_copy_definition_end (builtin math $caller_function_snapshot_copy_definition_offset + $caller_function_snapshot_copy_definition_count - 1)
            set -l caller_function_snapshot_copy_definition $caller_function_snapshot_copy_definition_lines[$caller_function_snapshot_copy_definition_offset..$caller_function_snapshot_copy_definition_end]
            if not _sp_fish_loader_function_copy_matches_definition "$caller_function_snapshot" $caller_function_snapshot_copy_definition
                set caller_snapshot_compromised 1
            end
            if not builtin functions -q "$caller_function_name"; or not _sp_fish_loader_function_definition_matches_text "$caller_function_name" $caller_function_definition; or not builtin test (builtin functions --details "$caller_function_name") = "$caller_function_source"
                set -a caller_function_mutations "$caller_function_name"
                test -n "$caller_function_mutation"; or set caller_function_mutation "$caller_function_name"
                if builtin string match -q 'embedded:*' -- "$caller_function_source"
                    test -n "$caller_embedded_mutation"; or set caller_embedded_mutation "$caller_function_name"
                end
            end
            set caller_function_snapshot_index (builtin math $caller_function_snapshot_index + 1)
        end
        builtin set -l loader_state_after_loaded $_sp_fish_loaded_modules
        builtin set -l loader_state_after_roots $_sp_fish_module_roots
        builtin set -l loader_state_after_provider $_sp_fish_metadata_provider
        builtin set -l loader_state_after_owned $_sp_fish_loader_owned_exports
        set -l loader_state_after_owned_sources $_sp_fish_loader_owned_sources
        builtin set -l loader_state_changed 0
        # Ordinary body failure is handled by the existing failure-status path
        # below. A body that edits fish_variables directly without changing
        # visible/in-process state is covered by the durable verifier below;
        # promoting every non-zero body status to private-state rollback would
        # misclassify valid permissive runtime failures.
        if builtin test (builtin count $loader_state_before_loaded_values) -ne (builtin count $loader_state_after_loaded); or \
           builtin test (builtin count $loader_state_before_roots_values) -ne (builtin count $loader_state_after_roots); or \
           builtin test (builtin count $loader_state_before_provider_values) -ne (builtin count $loader_state_after_provider); or \
           builtin test (builtin count $loader_state_before_owned_values) -ne (builtin count $loader_state_after_owned); or \
           builtin test (builtin count $loader_state_before_owned_sources) -ne (builtin count $loader_state_after_owned_sources)
            builtin set loader_state_changed 1
        else
            builtin set -l state_index 1
            for state_before_value in $loader_state_before_loaded_values
                if not builtin test "$state_before_value" = "$loader_state_after_loaded[$state_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set state_index (builtin math $state_index + 1)
            end
            if builtin test $loader_state_changed -eq 0
                builtin set state_index 1
                for state_before_value in $loader_state_before_roots_values
                    if not builtin test "$state_before_value" = "$loader_state_after_roots[$state_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set state_index (builtin math $state_index + 1)
                end
            end
            if builtin test $loader_state_changed -eq 0
                builtin set state_index 1
                for state_before_value in $loader_state_before_provider_values
                    if not builtin test "$state_before_value" = "$loader_state_after_provider[$state_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set state_index (builtin math $state_index + 1)
                end
            end
            if builtin test $loader_state_changed -eq 0
                builtin set state_index 1
                for state_before_value in $loader_state_before_owned_values
                    if not builtin test "$state_before_value" = "$loader_state_after_owned[$state_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set state_index (builtin math $state_index + 1)
                end
            end
            if builtin test $loader_state_changed -eq 0
                builtin set state_index 1
                for state_before_value in $loader_state_before_owned_sources
                    if not builtin test "$state_before_value" = "$loader_state_after_owned_sources[$state_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set state_index (builtin math $state_index + 1)
                end
            end
        end

        # Compare presence, values, and export state for every protected
        # handshake/root variable without delimiter serialization.
        builtin set -l bootstrap_mode_after_set 0
        builtin set -q _sp_fish_loader_bootstrap_mode; and builtin set bootstrap_mode_after_set 1
        builtin set -l bootstrap_mode_after_values $_sp_fish_loader_bootstrap_mode
        builtin set -l bootstrap_seeds_after_set 0
        builtin set -q _sp_fish_loader_bootstrap_seeds; and builtin set bootstrap_seeds_after_set 1
        builtin set -l bootstrap_seeds_after_values $_sp_fish_loader_bootstrap_seeds
        builtin set -l bootstrap_status_after_set 0
        builtin set -q _sp_fish_loader_bootstrap_status; and builtin set bootstrap_status_after_set 1
        builtin set -l bootstrap_status_after_values $_sp_fish_loader_bootstrap_status
        builtin set -l project_root_after_set 0
        builtin set -q SHELL_PROJECT_ROOT; and builtin set project_root_after_set 1
        builtin set -l project_root_after_values $SHELL_PROJECT_ROOT
        builtin set -l project_root_after_exported 0
        builtin set -q -x SHELL_PROJECT_ROOT; and builtin set project_root_after_exported 1
        builtin set -l readiness_after_set 0
        builtin set -q VALISE_FISH_READY; and builtin set readiness_after_set 1
        builtin set -l readiness_after_values $VALISE_FISH_READY
        builtin set -l readiness_after_exported 0
        builtin set -q -x VALISE_FISH_READY; and builtin set readiness_after_exported 1
        if builtin test $bootstrap_mode_before_set -ne $bootstrap_mode_after_set; or \
           builtin test (builtin count $bootstrap_mode_before_values) -ne (builtin count $bootstrap_mode_after_values); or \
           builtin test $bootstrap_seeds_before_set -ne $bootstrap_seeds_after_set; or \
           builtin test (builtin count $bootstrap_seeds_before_values) -ne (builtin count $bootstrap_seeds_after_values); or \
           builtin test $bootstrap_status_before_set -ne $bootstrap_status_after_set; or \
           builtin test (builtin count $bootstrap_status_before_values) -ne (builtin count $bootstrap_status_after_values); or \
           builtin test $project_root_before_set -ne $project_root_after_set; or \
           builtin test (builtin count $project_root_before_values) -ne (builtin count $project_root_after_values); or \
           builtin test $project_root_before_exported -ne $project_root_after_exported; or \
           builtin test $readiness_before_set -ne $readiness_after_set; or \
           builtin test (builtin count $readiness_before_values) -ne (builtin count $readiness_after_values); or \
           builtin test $readiness_before_exported -ne $readiness_after_exported
            builtin set loader_state_changed 1
        end
        if builtin test $loader_state_changed -eq 0
            builtin set -l protected_index 1
            for protected_before_value in $bootstrap_mode_before_values
                if not builtin test "$protected_before_value" = "$bootstrap_mode_after_values[$protected_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set protected_index (builtin math $protected_index + 1)
            end
        end
        if builtin test $loader_state_changed -eq 0
            builtin set -l protected_index 1
            for protected_before_value in $bootstrap_seeds_before_values
                if not builtin test "$protected_before_value" = "$bootstrap_seeds_after_values[$protected_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set protected_index (builtin math $protected_index + 1)
            end
        end
        if builtin test $loader_state_changed -eq 0
            builtin set -l protected_index 1
            for protected_before_value in $bootstrap_status_before_values
                if not builtin test "$protected_before_value" = "$bootstrap_status_after_values[$protected_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set protected_index (builtin math $protected_index + 1)
            end
        end
        if builtin test $loader_state_changed -eq 0
            builtin set -l protected_index 1
            for protected_before_value in $project_root_before_values
                if not builtin test "$protected_before_value" = "$project_root_after_values[$protected_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set protected_index (builtin math $protected_index + 1)
            end
        end
        if builtin test $loader_state_changed -eq 0
            builtin set -l protected_index 1
            for protected_before_value in $readiness_before_values
                if not builtin test "$protected_before_value" = "$readiness_after_values[$protected_index]"
                    builtin set loader_state_changed 1
                    break
                end
                builtin set protected_index (builtin math $protected_index + 1)
            end
        end
        # Compare the universal scope independently of the visible/global
        # snapshots above, then make any body mutation transactional.
        set -l scope_index 1
        for protected_scope_name in $protected_scope_names
            _sp_fish_loader_capture_scope "$protected_scope_name" "$scope_after_prefix"; or builtin exit 125
            set -l after_global_present_var "$scope_after_prefix"_"$protected_scope_name"_global_present
            set -l after_global_exported_var "$scope_after_prefix"_"$protected_scope_name"_global_exported
            set -l after_global_values_var "$scope_after_prefix"_"$protected_scope_name"_global_values
            set -l before_global_present_value "$scope_before_global_present_values[$scope_index]"
            set -l before_global_exported_value "$scope_before_global_exported_values[$scope_index]"
            set -l before_global_value_offset "$scope_before_global_value_offsets[$scope_index]"
            set -l before_global_value_count "$scope_before_global_value_counts[$scope_index]"
            set -l after_global_values $$after_global_values_var
            if test "$before_global_present_value" -ne $$after_global_present_var; or test "$before_global_exported_value" -ne $$after_global_exported_var; or test "$before_global_value_count" -ne (builtin count $after_global_values)
                builtin set loader_state_changed 1
            else if test "$before_global_value_count" -gt 0
                set -l scope_value_index 1
                set -l before_global_value_end (builtin math $before_global_value_offset + $before_global_value_count - 1)
                for scope_before_value in $scope_before_global_flat_values[$before_global_value_offset..$before_global_value_end]
                    if not builtin test "$scope_before_value" = "$after_global_values[$scope_value_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set scope_value_index (builtin math $scope_value_index + 1)
                end
            end
            set -l after_present_var "$scope_after_prefix"_"$protected_scope_name"_present
            set -l after_exported_var "$scope_after_prefix"_"$protected_scope_name"_exported
            set -l after_values_var "$scope_after_prefix"_"$protected_scope_name"_values
            set -l before_present_value "$scope_before_present_values[$scope_index]"
            set -l before_exported_value "$scope_before_exported_values[$scope_index]"
            set -l before_value_offset "$scope_before_value_offsets[$scope_index]"
            set -l before_value_count "$scope_before_value_counts[$scope_index]"
            set -l after_values $$after_values_var
            if test "$before_present_value" -ne $$after_present_var; or test "$before_exported_value" -ne $$after_exported_var; or test "$before_value_count" -ne (builtin count $after_values)
                builtin set loader_state_changed 1
            else if test "$before_value_count" -gt 0
                set -l scope_value_index 1
                set -l before_value_end (builtin math $before_value_offset + $before_value_count - 1)
                for scope_before_value in $scope_before_flat_values[$before_value_offset..$before_value_end]
                    if not builtin test "$scope_before_value" = "$after_values[$scope_value_index]"
                        builtin set loader_state_changed 1
                        break
                    end
                    builtin set scope_value_index (builtin math $scope_value_index + 1)
                end
            end
            set scope_index (builtin math $scope_index + 1)
        end

        if test (builtin count $caller_function_mutations) -gt 0
            builtin set loader_state_changed 1
        end
        # Classify all protected-state and function mutations before rollback.
        # A combined handshake mutation plus embedded `cd` mutation must never
        # enter a return path that leaves the embedded function installed.
        set -l preflight_embedded_mutation ''
        set -l preflight_embedded_index 1
        for preflight_reserved_name in $reserved_function_names
            set -l preflight_before_source "$reserved_function_before[$preflight_embedded_index]"
            set -l preflight_after_source (builtin functions --details "$preflight_reserved_name")
            if builtin string match -q 'embedded:*' -- "$preflight_before_source"; and not builtin test "$preflight_after_source" = "$preflight_before_source"
                set preflight_embedded_mutation "$preflight_reserved_name"
                break
            end
            set preflight_embedded_index (builtin math $preflight_embedded_index + 1)
        end
        if test $caller_snapshot_compromised -ne 0
            builtin printf '%s\n' 'loader: caller-function snapshot was tampered with' >&2
            builtin exit 125
        end
        if test -n "$caller_embedded_mutation"; or test -n "$preflight_embedded_mutation"
            set -l preflight_name "$caller_embedded_mutation"
            test -n "$preflight_name"; or set preflight_name "$preflight_embedded_mutation"
            builtin printf 'loader: embedded Fish function was mutated: %s\n' "$preflight_name" >&2
            builtin exit 125
        end
        if test (builtin count $caller_function_mutations) -ne 0
            builtin printf 'loader: exact caller-function restoration is unavailable\n' >&2
            builtin exit 125
        end
        # Even when the in-process snapshot is unchanged, the body may have
        # edited fish_variables directly. Verify every protected universal
        # before publishing a successful activation; a failed verification
        # enters the same exact before-image rollback below.
        if builtin test $loader_state_changed -eq 0
            set -l persistence_scope_index 1
            for persistence_scope_name in $protected_scope_names
                set -l persistence_after_present_var "$scope_after_prefix"_"$persistence_scope_name"_present
                set -l persistence_after_exported_var "$scope_after_prefix"_"$persistence_scope_name"_exported
                set -l persistence_after_values_var "$scope_after_prefix"_"$persistence_scope_name"_values
                _sp_fish_loader_verify_universal_persistence "$persistence_durable_file" "$persistence_tmp_parent" "$persistence_scope_name" $$persistence_after_present_var $$persistence_after_exported_var $$persistence_after_values_var
                if test $status -ne 0
                    builtin set loader_state_changed 1
                    break
                end
                set persistence_scope_index (builtin math $persistence_scope_index + 1)
            end
        end
        if builtin test $loader_state_changed -ne 0
            for created_function in $new_function_names
                if builtin functions -q "$created_function"
                    builtin functions -e "$created_function"; or builtin exit 125
                end
            end
            # Restore the trusted source files rather than eval'ing captured
            # definitions: eval would make every restored function appear to
            # originate from stdin and poison the next provenance check. Erase
            # shadow-only builtin names first because neither source file
            # defines functions named contains/test/etc.
            for reserved_name in $reserved_function_names
                if builtin functions -q "$reserved_name"
                    builtin functions -e "$reserved_name"; or builtin exit 125
                end
            end
            # Body-controlled bootstrap globals must be absent while the
            # trusted definitions are re-sourced; otherwise the loader's
            # source-time bootstrap dispatch would recursively run a second
            # load with attacker-selected seeds.
            if builtin set -q _sp_fish_loader_bootstrap_mode; builtin set -e _sp_fish_loader_bootstrap_mode; or builtin exit 125; end
            if builtin set -q _sp_fish_loader_bootstrap_seeds; builtin set -e _sp_fish_loader_bootstrap_seeds; or builtin exit 125; end
            if builtin set -q _sp_fish_loader_bootstrap_status; builtin set -e _sp_fish_loader_bootstrap_status; or builtin exit 125; end
            builtin source "$loader_source_file" 2>/dev/null; or builtin exit 125
            builtin source "$metadata_source_file" 2>/dev/null; or builtin exit 125
            set -l caller_function_snapshot_index 1
            for caller_function_name in $caller_function_snapshot_names
                set -l caller_function_snapshot "$caller_function_snapshot_copies[$caller_function_snapshot_index]"
                set -l caller_function_source "$caller_function_snapshot_sources[$caller_function_snapshot_index]"
                set -l caller_function_definition_offset "$caller_function_snapshot_definition_offsets[$caller_function_snapshot_index]"
                set -l caller_function_definition_count "$caller_function_snapshot_definition_counts[$caller_function_snapshot_index]"
                set -l caller_function_definition_end (builtin math $caller_function_definition_offset + $caller_function_definition_count - 1)
                set -l caller_function_definition $caller_function_snapshot_definition_lines[$caller_function_definition_offset..$caller_function_definition_end]
                if not _sp_fish_loader_function_definition_matches_text "$caller_function_name" $caller_function_definition
                    if builtin functions -q "$caller_function_name"
                        builtin functions -e "$caller_function_name"; or builtin exit 125
                    end
                    if not builtin functions -q "$caller_function_snapshot"; or not builtin functions --copy "$caller_function_snapshot" "$caller_function_name"; or not builtin test (builtin functions --details "$caller_function_name") = "$loader_source_file"; or not _sp_fish_loader_function_provenance_matches "$caller_function_name" $caller_function_definition
                        builtin printf 'loader: caller-function source-backed restoration failed: %s\n' "$caller_function_name" >&2
                        builtin exit 125
                    end
                end
                set caller_function_snapshot_index (builtin math $caller_function_snapshot_index + 1)
            end
            for caller_function_snapshot in $caller_function_snapshot_copies
                builtin functions -e "$caller_function_snapshot" 2>/dev/null; or builtin exit 125
            end
            set -l scope_index 1
            for protected_scope_name in $protected_scope_names
                _sp_fish_loader_restore_scope "$protected_scope_name" "$scope_index" "$persistence_durable_file" "$persistence_tmp_parent"
                if test $status -ne 0
                    builtin printf 'loader: protected-state restoration failed: %s\n' "$protected_scope_name" >&2
                    builtin exit 125
                end
                set scope_index (builtin math $scope_index + 1)
            end
            for scope_snapshot_prefix in _sp_fish_loader_scope_before_ __sp_fish_loader_scope_before_ _sp_fish_loader_scope_after_ __sp_fish_loader_scope_after_
                for scope_snapshot_name in (builtin set --names | builtin string match -- "$scope_snapshot_prefix*")
                    if builtin set -q -g "$scope_snapshot_name"
                        builtin set -e -g "$scope_snapshot_name"; or builtin exit 125
                    end
                    if builtin set -q -U "$scope_snapshot_name"
                        builtin set -e -U "$scope_snapshot_name"; or builtin exit 125
                    end
                end
            end
            if test -n "$caller_function_mutation"
                builtin printf 'loader: module replaced caller Fish function: %s\n' "$caller_function_mutation" >&2
            else
                builtin printf 'loader: module mutated private Fish loader state\n' >&2
            end
            # Publish only the trusted operation result after restoring the
            # caller state. The bootstrap wrapper consumes and erases this
            # handshake value; it is not part of the restored module state.
            builtin set -g _sp_fish_loader_bootstrap_status 1; or builtin exit 125
            return 1
        end
        builtin set -l loader_integrity_failure ''
        builtin set -l reserved_index 1
        for reserved_name in $reserved_function_names
            builtin set -l reserved_function_after (builtin functions --details "$reserved_name")
            if not builtin test "$reserved_function_after" = "$reserved_function_before[$reserved_index]"
                builtin set loader_integrity_failure "$reserved_name"
                break
            end
            builtin set reserved_index (builtin math $reserved_index + 1)
        end
        if builtin test -n "$loader_integrity_failure"
            builtin printf 'loader: module redefined loader function or builtin: %s\n' "$loader_integrity_failure" >&2
            builtin exit 125
        end
        for scope_snapshot_prefix in _sp_fish_loader_scope_before_ __sp_fish_loader_scope_before_ _sp_fish_loader_scope_after_ __sp_fish_loader_scope_after_
            for scope_snapshot_name in (builtin set --names | builtin string match -- "$scope_snapshot_prefix*")
                if builtin set -q -g "$scope_snapshot_name"
                builtin set -e -g "$scope_snapshot_name"; or builtin exit 125
            end
            if builtin set -q -U "$scope_snapshot_name"
                builtin set -e -U "$scope_snapshot_name"; or builtin exit 125
            end
            end
        end
        for caller_function_snapshot in $caller_function_snapshot_copies
            builtin functions -e "$caller_function_snapshot" 2>/dev/null; or builtin exit 125
        end
        if test $src_status -ne 0
            for created_function in $new_function_names
                if builtin functions -q "$created_function"
                    builtin functions -e "$created_function"; or builtin exit 125
                end
            end
            set -a runtime_failed_modules $mod
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: failed to source optional module $mod: $body_file (exit $src_status)"
                set -a failed_modules $mod
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "failed to source $mod: $body_file (exit $src_status)"
                return 1
            end
            # Permissive: report the failure but do not mark the module loaded.
            sp_fish_loader_error "warning: failed to source $mod: $body_file (exit $src_status)"
            continue
        end

        set -l missing_export ''
        for export_name in $mod_exports
            if not functions -q "$export_name"
                set missing_export $export_name
                break
            end
        end
        if test -n "$missing_export"
            for created_function in $new_function_names
                if builtin functions -q "$created_function"
                    builtin functions -e "$created_function"; or builtin exit 125
                end
            end
            set -a runtime_failed_modules $mod
            if builtin contains -- $mod $optional_modules
                sp_fish_loader_error "warning: optional module missing declared export: $missing_export (module $mod)"
                set -a failed_modules $mod
                continue
            end
            if test "$mode" = strict
                sp_fish_loader_error "declared export missing after load: $missing_export (module $mod)"
                return 1
            end
            sp_fish_loader_error "warning: declared export missing after load: $missing_export (module $mod)"
            continue
        end

        set -g _sp_fish_loaded_modules $_sp_fish_loaded_modules $mod
        for owned_function in $new_function_names $mod_exports
            if test -n "$owned_function"; and not builtin contains -- $owned_function $_sp_fish_loader_owned_exports
                set -a _sp_fish_loader_owned_exports $owned_function
                set -a _sp_fish_loader_owned_sources (builtin functions --details "$owned_function")
            end
        end
    end

    return 0
end

function _sp_fish_loader_dispatch --description 'Private Fish loader dispatcher'
    # This function is only called from the source-driven bootstrap at the end
    # of this file. Sourcing this file overwrites any caller definition before
    # the dispatcher is reached, so a mutable public wrapper cannot report a
    # false successful load.
    set -l dispatcher_source (builtin functions --details _sp_fish_loader_dispatch)
    set -l implementation_source (builtin functions --details _sp_fish_loader_load_ordered_impl)
    if not builtin set -q _sp_fish_loader_expected_source; or \
       not builtin test "$dispatcher_source" = "$_sp_fish_loader_expected_source"; or \
       not builtin test "$implementation_source" = "$_sp_fish_loader_expected_source"
        builtin printf 'loader: private dispatcher failed integrity validation\n' >&2
        return 1
    end
    _sp_fish_loader_load_ordered_impl $argv
    set -l dispatch_status $status
    if test $dispatch_status -ne 0
        _sp_fish_loader_rollback_activation
    end
    return $dispatch_status
end

function _sp_fish_loader_init --description 'Initialize the Fish loader with standard roots'
    # Remove only exports claimed by the previous trusted module load. This
    # makes switching releases deterministic while preserving caller-owned
    # Fish functions that were never recorded in the ownership ledger.
    set -l owned_source_index 1
    for owned_export in $_sp_fish_loader_owned_exports
        set -l owned_source ''
        if test $owned_source_index -le (builtin count $_sp_fish_loader_owned_sources)
            set owned_source $_sp_fish_loader_owned_sources[$owned_source_index]
        end
        if test -n "$owned_source"; and builtin functions -q "$owned_export"; and builtin test (builtin functions --details "$owned_export") = "$owned_source"
            builtin functions -e "$owned_export"; or builtin exit 125
        end
        builtin set owned_source_index (builtin math $owned_source_index + 1)
    end
    builtin set -g _sp_fish_loader_owned_exports; or builtin exit 125
    builtin set -g _sp_fish_loader_owned_sources; or builtin exit 125
    builtin set -g _sp_fish_loaded_modules; or builtin exit 125
    builtin set -g _sp_fish_module_roots; or builtin exit 125
    builtin set -g _sp_fish_metadata_provider; or builtin exit 125

    # Provider order is project-native, engine-native, engine-generic, then
    # project-generic. Duplicate names are validated byte-for-byte below.
    set -l script_dir (status dirname)
    set -l engine_root (builtin cd "$script_dir/../.." 2>/dev/null; and builtin pwd -P)

    # Project-native providers intentionally take precedence over engine-native
    # providers, followed by engine generic metadata and project generic
    # metadata. Duplicate names are accepted only when metadata and native
    # Fish bodies are byte-identical; conflicting providers fail closed.
    set -l project_root ''
    if set -q SHELL_PROJECT_ROOT
        if test -d "$SHELL_PROJECT_ROOT/shell/module.d"; and test -d "$SHELL_PROJECT_ROOT/shell/modules"
            set project_root "$SHELL_PROJECT_ROOT/shell"
        else
            set project_root "$SHELL_PROJECT_ROOT"
        end
    end
    if test -n "$project_root"; and test -d "$project_root/modules/fish"
        sp_fish_loader_add_root "$project_root/modules/fish"; or return 1
    end
    if test -n "$engine_root"; and test -d "$engine_root/modules/fish"
        sp_fish_loader_add_root "$engine_root/modules/fish"; or return 1
    end

    if test -n "$engine_root"; and test -d "$engine_root/module.d"; and test -d "$engine_root/modules"
        sp_fish_loader_add_root "$engine_root"; or return 1
    end
    if test -n "$project_root"; and test -d "$project_root/module.d"; and test -d "$project_root/modules"
        sp_fish_loader_add_root "$project_root"; or return 1
    end
    return 0
end

# Supported Fish entrypoint: set _sp_fish_loader_bootstrap_mode and
# _sp_fish_loader_bootstrap_seeds, then `source` this trusted file. The source
# operation replaces caller-defined entrypoint/dispatcher functions before any
# load occurs; direct calls to mutable compatibility names are intentionally not
# part of the engine ABI.
if set -q _sp_fish_loader_bootstrap_mode
    set -l _sp_fish_bootstrap_mode $_sp_fish_loader_bootstrap_mode
    set -l _sp_fish_bootstrap_seeds $_sp_fish_loader_bootstrap_seeds
    set -e _sp_fish_loader_bootstrap_mode
    set -e _sp_fish_loader_bootstrap_seeds
    # Initialization itself uses predicates and path helpers, so perform the
    # caller-shadow check before root discovery rather than waiting for the
    # implementation's later graph preflight. Every operation in this gate is
    # explicitly builtin; a caller function cannot redirect it.
    builtin set -l _sp_fish_bootstrap_status 0
    builtin set -l _sp_fish_bootstrap_shadowables contains test string source path functions set printf echo math count
    for _sp_fish_bootstrap_shadowed in $_sp_fish_bootstrap_shadowables
        if builtin functions -q "$_sp_fish_bootstrap_shadowed"
            builtin printf 'loader: caller shadowed critical Fish builtin: %s\n' "$_sp_fish_bootstrap_shadowed" >&2
            builtin set _sp_fish_bootstrap_status 1
        end
    end
    for _sp_fish_bootstrap_path_builtin in cd pwd
        if builtin functions -q "$_sp_fish_bootstrap_path_builtin"
            builtin set -l _sp_fish_bootstrap_path_source (builtin functions --details "$_sp_fish_bootstrap_path_builtin")
            if builtin test "$_sp_fish_bootstrap_path_builtin" = cd; and builtin contains -- "$_sp_fish_bootstrap_path_source" \
                    embedded:functions/cd.fish \
                    /usr/share/fish/functions/cd.fish \
                    /usr/local/share/fish/functions/cd.fish \
                    /opt/local/share/fish/functions/cd.fish \
                    /opt/homebrew/share/fish/functions/cd.fish
                continue
            end
            builtin printf 'loader: caller shadowed critical Fish builtin: %s\n' "$_sp_fish_bootstrap_path_builtin" >&2
            builtin set _sp_fish_bootstrap_status 1
        end
    end
    if builtin test $_sp_fish_bootstrap_status -eq 0
        _sp_fish_loader_init
        builtin set _sp_fish_bootstrap_status $status
    end
    if builtin test $_sp_fish_bootstrap_status -eq 0
        _sp_fish_loader_dispatch $_sp_fish_bootstrap_mode $_sp_fish_bootstrap_seeds
        builtin set _sp_fish_bootstrap_status $status
    end
    builtin set -g _sp_fish_loader_bootstrap_status $_sp_fish_bootstrap_status
end
