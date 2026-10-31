#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Quarantined native-Fish runtime coverage for the reusable loader.
set -eu

_fish=$(PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" command -v fish 2>/dev/null || :)
if [ -z "$_fish" ]; then
  printf '%s\n' 'FAIL: fish is required for the native Fish runtime gate' >&2
  exit 1
fi

_test_tmpdir=${TMPDIR:-/tmp}
case $_test_tmpdir in
  /) ;;
  *) _test_tmpdir=${_test_tmpdir%/} ;;
esac
_test_root=$(mktemp -d "$_test_tmpdir/valise-fish-runtime.XXXXXX")
_test_home="$_test_root/home"
_fixture="$_test_root/project"
_program="$_test_root/runtime.fish"
mkdir -p "$_test_home" "$_fixture/module.d" "$_fixture/modules/fish/module.d" "$_fixture/modules/fish"
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_test_root" 2>/dev/null || :
  rm -rf -- "$_test_root"
}
trap _cleanup EXIT INT TERM

_meta() {
  _meta_path=$1; _meta_name=$2; _meta_shells=$3; _meta_platforms=$4
  _meta_effect=$5; _meta_exports=$6; _meta_load=$7; _meta_requires=${8:-}; _meta_optional=${9:-}
  {
    printf 'name=%s\n' "$_meta_name"
    printf 'requires=%s\n' "$_meta_requires"
    printf 'optional=%s\n' "$_meta_optional"
    printf 'shells=%s\n' "$_meta_shells"
    printf 'platforms=%s\n' "$_meta_platforms"
    printf 'side_effect=%s\n' "$_meta_effect"
    printf 'exports=%s\n' "$_meta_exports"
    printf 'updates=\nload=%s\n' "$_meta_load"
  } >"$_meta_path"
}

_body() {
  _body_path=$1
  printf '%s\n' "$2" >"$_body_path"
}

# Native Fish providers are selected before generic project providers.
_meta "$_fixture/modules/fish/module.d/precedence.meta" precedence fish any read-only precedence_native_loaded native.fish
_body "$_fixture/modules/fish/native.fish" 'set -g precedence_provider native; function precedence_native_loaded; end'
_meta "$_fixture/module.d/generic_only.meta" generic_only fish any read-only generic_only_loaded modules/fish/generic_only.fish
_body "$_fixture/modules/fish/generic_only.fish" 'set -g generic_provider generic; function generic_only_loaded; end'
# Same-name providers with differing metadata are rejected before any body runs.
_meta "$_fixture/modules/fish/module.d/conflict.meta" conflict fish any read-only conflict_native_loaded native_conflict.fish
_body "$_fixture/modules/fish/native_conflict.fish" 'set -g conflict_sourced native; function conflict_native_loaded; end'
_meta "$_fixture/module.d/conflict.meta" conflict fish any read-only conflict_generic_loaded modules/fish/generic_conflict.fish
_body "$_fixture/modules/fish/generic_conflict.fish" 'set -g conflict_sourced generic; function conflict_generic_loaded; end'
# Same-name providers with different versions fail closed with a
# version-skew diagnostic before either body runs. The _meta helper has no
# version support, so these records are written directly.
{
  printf 'name=%s\n' version_skew
  printf 'requires=\noptional=\nshells=fish\nplatforms=any\nside_effect=read-only\nexports=version_skew_loaded\nupdates=\nversion=1.0.0\nload=native_version_skew.fish\n'
} >"$_fixture/modules/fish/module.d/version_skew.meta"
_body "$_fixture/modules/fish/native_version_skew.fish" 'set -g version_skew_sourced native; function version_skew_loaded; end'
{
  printf 'name=%s\n' version_skew
  printf 'requires=\noptional=\nshells=fish\nplatforms=any\nside_effect=read-only\nexports=version_skew_loaded\nupdates=\nversion=2.0.0\nload=modules/fish/version_skew.fish\n'
} >"$_fixture/module.d/version_skew.meta"
_body "$_fixture/modules/fish/version_skew.fish" 'set -g version_skew_sourced generic; function version_skew_loaded; end'

# Shell-skipped dependency is satisfied without sourcing its non-Fish body.
_meta "$_fixture/module.d/shell_skip.meta" shell_skip bash any install-time shell_skip_loaded modules/fish/shell_skip.fish
_body "$_fixture/modules/fish/shell_skip.fish" 'set -g shell_skip_sourced 1; function shell_skip_loaded; end'
_meta "$_fixture/module.d/gated_app.meta" gated_app fish any read-only gated_app_loaded modules/fish/gated_app.fish shell_skip
# A POSIX-only module requested directly (not as a dependency) exercises the
# shell-gate mode contract: strict must fail closed like the POSIX loader,
# permissive must report and continue, and the body must never run.
_meta "$_fixture/module.d/posix_only_seed.meta" posix_only_seed "sh bash zsh ksh" any read-only posix_only_seed_loaded modules/fish/posix_only_seed.fish
_body "$_fixture/modules/fish/posix_only_seed.fish" 'set -g posix_only_sourced 1; function posix_only_seed_loaded; end'
# The shared ABI parses POSIX local-state and dependency-only meta records
# before the shell gate skips them. A native Fish module can depend on both.
_meta "$_fixture/module.d/local_state_skip.meta" local_state_skip "sh bash zsh ksh" any local-state '' modules/fish/local_state_skip.sh
_meta "$_fixture/module.d/meta_only.meta" meta_only "sh bash zsh ksh" any read-only '' '' local_state_skip
_meta "$_fixture/module.d/meta_dependent.meta" meta_dependent fish any read-only meta_dependent_loaded modules/fish/meta_dependent.fish meta_only
_body "$_fixture/modules/fish/meta_dependent.fish" 'function meta_dependent_loaded; end'
# An optional-only cycle pins the native Fish ordering contract: the
# single-pass Kahn sort has no optional-relaxed fallback (unlike the POSIX
# loader's two-pass sort), so a stall quarantines its members — strict mode
# fails closed because the requested seed is stalled, permissive quarantines
# and continues with nothing sourced.
_meta "$_fixture/module.d/opt_cycle_a.meta" opt_cycle_a fish any read-only opt_cycle_a_loaded modules/fish/opt_cycle_a.fish '' opt_cycle_b
_body "$_fixture/modules/fish/opt_cycle_a.fish" 'set -g opt_cycle_a_sourced 1; function opt_cycle_a_loaded; end'
_meta "$_fixture/module.d/opt_cycle_b.meta" opt_cycle_b fish any read-only opt_cycle_b_loaded modules/fish/opt_cycle_b.fish '' opt_cycle_a
_body "$_fixture/modules/fish/opt_cycle_b.fish" 'set -g opt_cycle_b_sourced 1; function opt_cycle_b_loaded; end'
_body "$_fixture/modules/fish/gated_app.fish" 'function gated_app_loaded; end'

# A strict activation must roll back exports from modules that completed before
# a later required body fails.
_meta "$_fixture/module.d/partial_a.meta" partial_a fish any read-only partial_a_loaded modules/fish/partial_a.fish
_body "$_fixture/modules/fish/partial_a.fish" 'function partial_a_loaded; end'
_meta "$_fixture/module.d/partial_b.meta" partial_b fish any read-only partial_b_loaded modules/fish/partial_b.fish partial_a
_body "$_fixture/modules/fish/partial_b.fish" 'function partial_b_loaded; end; return 9'
# An undeclared helper must be transactional too; exports are not the whole namespace.
_meta "$_fixture/module.d/partial_helper.meta" partial_helper fish any read-only partial_helper_loaded modules/fish/partial_helper.fish
_body "$_fixture/modules/fish/partial_helper.fish" 'function partial_helper_loaded; end; function undeclared_partial_helper; end; return 13'
_meta "$_fixture/module.d/helper_success.meta" helper_success fish any read-only helper_success_loaded modules/fish/helper_success.fish
_body "$_fixture/modules/fish/helper_success.fish" 'function helper_success_loaded; end; function helper_success_private; end'

# A body must not replace a caller-owned function that it did not declare.
# The loader must reject the activation and restore the original definition.
_meta "$_fixture/module.d/caller_collision.meta" caller_collision fish any read-only caller_collision_loaded modules/fish/caller_collision.fish
_body "$_fixture/modules/fish/caller_collision.fish" 'function caller_owned_collision; echo replaced; end; function caller_collision_loaded; end'
# A module cannot clear the loader's caller-local snapshot arrays. The body
# must remain isolated from the transaction locals so its caller-function
# replacement is still detected and rolled back.
_meta "$_fixture/module.d/local_snapshot_attack.meta" local_snapshot_attack fish any read-only local_snapshot_attack_loaded modules/fish/local_snapshot_attack.fish
_body "$_fixture/modules/fish/local_snapshot_attack.fish" 'set caller_function_snapshot_names; set caller_function_snapshot_copies; set caller_function_snapshot_sources; set caller_function_snapshot_definition_offsets; set caller_function_snapshot_definition_counts; set caller_function_snapshot_definition_lines; function caller_owned_snapshot; echo replaced-snapshot; end; function local_snapshot_attack_loaded; end'
_meta "$_fixture/module.d/private_collision.meta" private_collision fish any read-only private_collision_loaded modules/fish/private_collision.fish
_body "$_fixture/modules/fish/private_collision.fish" 'function _caller_owned_private; echo replaced-private; end; function private_collision_loaded; end'
_meta "$_fixture/module.d/private_failed.meta" private_failed fish any read-only private_failed_loaded modules/fish/private_failed.fish
_body "$_fixture/modules/fish/private_failed.fish" 'function _private_failed_helper; end; function private_failed_loaded; end; return 17'

# Required runtime failure, cycle, and return-status isolation fixtures.
_meta "$_fixture/module.d/runtime_dep.meta" runtime_dep fish any read-only runtime_dep_loaded modules/fish/runtime_dep.fish
_body "$_fixture/modules/fish/runtime_dep.fish" 'set -g runtime_dep_seen 1; false'
_meta "$_fixture/module.d/runtime_app.meta" runtime_app fish any read-only runtime_app_loaded modules/fish/runtime_app.fish runtime_dep
_body "$_fixture/modules/fish/runtime_app.fish" 'function runtime_app_loaded; end'
_meta "$_fixture/module.d/cycle_a.meta" cycle_a fish any read-only cycle_a_loaded modules/fish/cycle_a.fish cycle_b
_body "$_fixture/modules/fish/cycle_a.fish" 'function cycle_a_loaded; end'
_meta "$_fixture/module.d/cycle_b.meta" cycle_b fish any read-only cycle_b_loaded modules/fish/cycle_b.fish cycle_a
_body "$_fixture/modules/fish/cycle_b.fish" 'function cycle_b_loaded; end'
_meta "$_fixture/module.d/return_dep.meta" return_dep fish any read-only return_dep_loaded modules/fish/return_dep.fish
_body "$_fixture/modules/fish/return_dep.fish" 'set -g return_dep_seen 1; return 7'
_meta "$_fixture/module.d/return_app.meta" return_app fish any read-only return_app_loaded modules/fish/return_app.fish return_dep
_body "$_fixture/modules/fish/return_app.fish" 'function return_app_loaded; end'
_meta "$_fixture/module.d/hijack.meta" hijack fish any read-only hijack_loaded modules/fish/hijack.fish
_body "$_fixture/modules/fish/hijack.fish" 'function contains; return 0; end; function cd; return 1; end; function hijack_loaded; end'
# Namespace mutation is built dynamically so lexical preflight cannot
# recognize the Fish namespace command or erase option. Runtime integrity must
# therefore fail closed after the embedded cd has been replaced.
_meta "$_fixture/module.d/indirect_cd.meta" indirect_cd fish any read-only indirect_cd_loaded modules/fish/indirect_cd.fish
_body "$_fixture/modules/fish/indirect_cd.fish" 'set -g _sp_fish_loader_bootstrap_mode poisoned-by-embedded; set -U SHELL_PROJECT_ROOT poisoned-native-universal; function indirect_cd_replacer; set -l _function_command (string join "" func tions); set -l _erase_word (string join "" era se); set -l _erase_option --$_erase_word; set -l _critical_name (string join "" c d); $_function_command $_erase_option $_critical_name; function $_critical_name; builtin printf '%s\n' attacker > "$NATIVE_DYNAMIC_MARKER"; end; end; indirect_cd_replacer; function indirect_cd_loaded; end'
_meta "$_fixture/module.d/clean.meta" clean fish any read-only clean_loaded modules/fish/clean.fish
_body "$_fixture/modules/fish/clean.fish" 'function clean_loaded; end'
_meta "$_fixture/module.d/independent.meta" independent fish any read-only independent_loaded modules/fish/independent.fish
_body "$_fixture/modules/fish/independent.fish" 'function independent_loaded; end'
_meta "$_fixture/module.d/after_hijack.meta" after_hijack fish any read-only after_hijack_loaded modules/fish/after_hijack.fish
_body "$_fixture/modules/fish/after_hijack.fish" 'function after_hijack_loaded; end'
_meta "$_fixture/module.d/after_cd.meta" after_cd fish any read-only after_cd_loaded modules/fish/after_cd.fish
_body "$_fixture/modules/fish/after_cd.fish" 'function after_cd_loaded; end'
_meta "$_fixture/module.d/after_pwd.meta" after_pwd fish any read-only after_pwd_loaded modules/fish/after_pwd.fish
_body "$_fixture/modules/fish/after_pwd.fish" 'function after_pwd_loaded; end'
_meta "$_fixture/module.d/after_path.meta" after_path fish any read-only after_path_loaded modules/fish/after_path.fish
_body "$_fixture/modules/fish/after_path.fish" 'function after_path_loaded; end'
_meta "$_fixture/module.d/poison.meta" poison fish any read-only poison_loaded modules/fish/poison.fish
_body "$_fixture/modules/fish/poison.fish" 'set -g _sp_fish_loader_bootstrap_mode strict; set -g _sp_fish_loader_bootstrap_seeds poisoned_from_body; set -g _sp_fish_loader_bootstrap_status 0; set -gx SHELL_PROJECT_ROOT /tmp/poisoned-root; set -U SHELL_PROJECT_ROOT poisoned-universal; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_present 1; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_exported 0; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_values /tmp/poisoned-root; function poison_loaded; end'
_meta "$_fixture/module.d/poisoned_from_body.meta" poisoned_from_body fish any read-only poisoned_from_body_loaded modules/fish/poisoned_from_body.fish
_body "$_fixture/modules/fish/poisoned_from_body.fish" 'set -g recursive_poison_loaded 1; function poisoned_from_body_loaded; end'
# Isolate the protected-universal snapshot attack: the visible global root is
# unchanged, so this fixture fails against the former global-snapshot loader.
_meta "$_fixture/module.d/isolated_snapshot_attack.meta" isolated_snapshot_attack fish any read-only isolated_snapshot_attack_loaded modules/fish/isolated_snapshot_attack.fish
_body "$_fixture/modules/fish/isolated_snapshot_attack.fish" 'set -U SHELL_PROJECT_ROOT poisoned-universal-only; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_present 1; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_exported 0; set -g _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_values poisoned-universal-only; function isolated_snapshot_attack_loaded; end'
_meta "$_fixture/module.d/global_readiness_attack.meta" global_readiness_attack fish any read-only global_readiness_attack_loaded modules/fish/global_readiness_attack.fish
_body "$_fixture/modules/fish/global_readiness_attack.fish" 'set -g VALISE_FISH_READY 99; function global_readiness_attack_loaded; end'
_meta "$_fixture/module.d/global_export_attack.meta" global_export_attack fish any read-only global_export_attack_loaded modules/fish/global_export_attack.fish
_body "$_fixture/modules/fish/global_export_attack.fish" 'set -gx _sp_fish_loader_bootstrap_status 0; function global_export_attack_loaded; end'
# A failed native body may redirect XDG_CONFIG_HOME before rollback. The
# verifier must retain the durable fish_variables path captured before source,
# rather than accepting an empty attacker-selected store.
_meta "$_fixture/module.d/durable_path_attack.meta" durable_path_attack fish any read-only durable_path_attack_loaded modules/fish/durable_path_attack.fish
_body "$_fixture/modules/fish/durable_path_attack.fish" 'set -U SHELL_PROJECT_ROOT durable-path-poison; set -gx XDG_CONFIG_HOME "$HOME/alternate-config"; command chmod u-w "$HOME/.config/fish"; function durable_path_attack_loaded; end; return 23'

# Construct an unsupported platform dynamically so the test is meaningful on
# both Darwin and Linux lanes.
_platform=$(/usr/bin/uname -s 2>/dev/null || printf unknown)
case "$_platform" in Darwin) _opposite_platform=linux ;; *) _opposite_platform=darwin ;; esac
_meta "$_fixture/module.d/wrong_platform.meta" wrong_platform fish "$_opposite_platform" read-only wrong_platform_loaded modules/fish/wrong_platform.fish
_body "$_fixture/modules/fish/wrong_platform.fish" 'set -g wrong_platform_sourced 1; function wrong_platform_loaded; end'
# A platform-skipped optional dependency is expected to be absent on this
# host. It must stay silent and must not stop its declaring module, matching
# the POSIX loader's treatment of optional platform skips.
_meta "$_fixture/module.d/opt_platform_user.meta" opt_platform_user fish any read-only opt_platform_user_loaded modules/fish/opt_platform_user.fish '' wrong_platform
_body "$_fixture/modules/fish/opt_platform_user.fish" 'set -g opt_platform_user_sourced 1; function opt_platform_user_loaded; end'
# The platform-skipped module can sit one required edge below a module that
# was discovered as optional first. The required-closure fixpoint must still
# report it, exactly as the POSIX loader does.
_meta "$_fixture/module.d/nested_opt.meta" nested_opt fish any read-only nested_opt_loaded modules/fish/nested_opt.fish '' nested_mid
_body "$_fixture/modules/fish/nested_opt.fish" 'set -g nested_opt_sourced 1; function nested_opt_loaded; end'
_meta "$_fixture/module.d/nested_mid.meta" nested_mid fish any read-only nested_mid_loaded modules/fish/nested_mid.fish nested_platform
_body "$_fixture/modules/fish/nested_mid.fish" 'set -g nested_mid_sourced 1; function nested_mid_loaded; end'
_meta "$_fixture/module.d/zzz_nested_bridge.meta" zzz_nested_bridge fish any read-only zzz_nested_bridge_loaded modules/fish/zzz_nested_bridge.fish nested_mid
_body "$_fixture/modules/fish/zzz_nested_bridge.fish" 'set -g zzz_nested_bridge_sourced 1; function zzz_nested_bridge_loaded; end'
_meta "$_fixture/module.d/nested_root.meta" nested_root fish any read-only nested_root_loaded modules/fish/nested_root.fish zzz_nested_bridge nested_opt
_body "$_fixture/modules/fish/nested_root.fish" 'set -g nested_root_sourced 1; function nested_root_loaded; end'
_meta "$_fixture/module.d/nested_platform.meta" nested_platform fish "$_opposite_platform" read-only nested_platform_loaded modules/fish/nested_platform.fish
_body "$_fixture/modules/fish/nested_platform.fish" 'set -g nested_platform_sourced 1; function nested_platform_loaded; end'

_engine=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
# An absent universal store is a valid empty before-image. Rollback must still
# restore global state and must not treat the first Fish process in a home as
# an integrity failure.
_missing_persistence_home="$_test_root/missing-persistence-home"
mkdir -p "$_missing_persistence_home/.config"
_missing_persistence_program="$_test_root/missing-persistence-rollback.fish"
cat >"$_missing_persistence_program" <<EOF
builtin source '$_engine/lib/fish/loader.fish'
builtin set -g SHELL_PROJECT_ROOT poisoned-global
set -l scope_before_global_present_values 0
set -l scope_before_global_exported_values 0
set -l scope_before_global_value_offsets 1
set -l scope_before_global_value_counts 0
set -l scope_before_global_flat_values
set -l scope_before_present_values 0
set -l scope_before_exported_values 0
set -l scope_before_value_offsets 1
set -l scope_before_value_counts 0
set -l scope_before_flat_values
_sp_fish_loader_restore_scope SHELL_PROJECT_ROOT 1
set -l _missing_persistence_status \$status
builtin test \$_missing_persistence_status -eq 0; or exit 125
builtin set -q SHELL_PROJECT_ROOT; and exit 125
exit 0
EOF
if ! HOME="$_missing_persistence_home" XDG_CONFIG_HOME="$_missing_persistence_home/.config" \
  "$_fish" --no-config "$_missing_persistence_program" >/dev/null 2>"$_test_root/missing-persistence-rollback.stderr"; then
  cat "$_test_root/missing-persistence-rollback.stderr" >&2
  printf '%s\n' 'FAIL: rollback with an absent universal store did not restore global state' >&2
  exit 1
fi
# Universal-variable rollback must verify durable persistence, not only the
# current Fish process. Fish can retain a restored value in memory after a
# failed fish_variables write; a fresh process is the contract authority.
_persistence_home="$_test_root/persistence-home"
mkdir -p "$_persistence_home/.config/fish"
_persistence_success_program="$_test_root/persistence-rollback-success.fish"
cat >"$_persistence_success_program" <<EOF
builtin source '$_engine/lib/fish/loader.fish'
builtin set -U SHELL_PROJECT_ROOT durable-before
set -l scope_before_global_present_values 0
set -l scope_before_global_exported_values 0
set -l scope_before_global_value_offsets 1
set -l scope_before_global_value_counts 0
set -l scope_before_global_flat_values
set -l scope_before_present_values 1
set -l scope_before_exported_values 0
set -l scope_before_value_offsets 1
set -l scope_before_value_counts 1
set -l scope_before_flat_values durable-before
builtin set -U SHELL_PROJECT_ROOT poisoned-live
_sp_fish_loader_restore_scope SHELL_PROJECT_ROOT 1
set -l _persistence_success_status \$status
builtin test \$_persistence_success_status -eq 0; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = durable-before; or exit 1
exit 0
EOF
if ! HOME="$_persistence_home" XDG_CONFIG_HOME="$_persistence_home/.config" \
  "$_fish" "$_persistence_success_program" >/dev/null 2>"$_test_root/persistence-success.stderr"; then
  cat "$_test_root/persistence-success.stderr" >&2
  printf '%s\n' 'FAIL: successful durable universal rollback did not return zero' >&2
  exit 1
fi
_persistence_failure_program="$_test_root/persistence-rollback-failure.fish"
cat >"$_persistence_failure_program" <<EOF
builtin source '$_engine/lib/fish/loader.fish'
builtin set -U SHELL_PROJECT_ROOT durable-before
set -l scope_before_global_present_values 0
set -l scope_before_global_exported_values 0
set -l scope_before_global_value_offsets 1
set -l scope_before_global_value_counts 0
set -l scope_before_global_flat_values
set -l scope_before_present_values 1
set -l scope_before_exported_values 0
set -l scope_before_value_offsets 1
set -l scope_before_value_counts 1
set -l scope_before_flat_values durable-before
builtin set -U SHELL_PROJECT_ROOT poisoned-live
command chmod u-w "\$HOME/.config/fish"
_sp_fish_loader_restore_scope SHELL_PROJECT_ROOT 1
set -l _persistence_status \$status
command chmod u+w "\$HOME/.config/fish"
builtin set -e -U SHELL_PROJECT_ROOT
exit \$_persistence_status
EOF
if HOME="$_persistence_home" XDG_CONFIG_HOME="$_persistence_home/.config" \
  "$_fish" "$_persistence_failure_program" >/dev/null 2>"$_test_root/persistence-failure.stderr"; then
  printf '%s\n' 'FAIL: durable universal rollback failure returned success' >&2
  exit 1
else
  _persistence_status=$?
  if [ "$_persistence_status" -ne 125 ]; then
    cat "$_test_root/persistence-failure.stderr" >&2
    printf 'FAIL: durable universal rollback returned %s, expected 125\n' "$_persistence_status" >&2
    exit 1
  fi
fi

# Function restoration must never execute generated Fish through `eval`.
# The source-level assertion covers both caller-owned and embedded-function
# rollback paths; embedded mutations terminate before any restoration attempt.
if "$_engine/bin/valise" init fish --source-tree | grep -F 'builtin eval' >/dev/null; then
  printf '%s\n' 'FAIL: generated Fish integration contains eval restoration' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+eval[[:space:]]' "$_engine/lib/fish/loader.fish"; then
  printf '%s\n' 'FAIL: native Fish loader contains unqualified eval' >&2
  exit 1
fi
# A platform-skipped optional dependency loads its declaring module and writes
# nothing to stderr. Silence is the contract: a per-startup warning for a
# module the user never asked for is noise, and the POSIX loader is quiet too.
_opt_platform_program="$_test_root/optional-platform.fish"
cat >"$_opt_platform_program" <<OPTEOF
builtin source '$_engine/lib/fish/metadata.fish'
builtin set -gx SHELL_PROJECT_ROOT '$_fixture'
builtin set -g _sp_fish_loader_bootstrap_mode strict
builtin set -g _sp_fish_loader_bootstrap_seeds opt_platform_user
builtin source '$_engine/lib/fish/loader.fish'
builtin set -l _status \$_sp_fish_loader_bootstrap_status
builtin set -e _sp_fish_loader_bootstrap_status
builtin test "\$_status" -eq 0; or exit 1
builtin set -q opt_platform_user_sourced; or exit 1
builtin set -q wrong_platform_sourced; and exit 1
exit 0
OPTEOF
_opt_platform_status=0
/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_opt_platform_program" >"$_test_root/optional-platform.stdout" 2>"$_test_root/optional-platform.stderr" || _opt_platform_status=$?
if [ "$_opt_platform_status" -ne 0 ]; then
  cat "$_test_root/optional-platform.stdout" "$_test_root/optional-platform.stderr" >&2
  printf '%s\n' 'FAIL: optional platform skip broke its declaring module' >&2
  exit 1
fi
if [ -s "$_test_root/optional-platform.stderr" ]; then
  cat "$_test_root/optional-platform.stderr" >&2
  printf '%s\n' 'FAIL: optional platform skip must be silent' >&2
  exit 1
fi

# One required edge below an optional module: the platform skip is required,
# so strict mode fails and names the platform, not just the blocked parent.
_nested_platform_program="$_test_root/nested-platform.fish"
cat >"$_nested_platform_program" <<NESTEOF
builtin source '$_engine/lib/fish/metadata.fish'
builtin set -gx SHELL_PROJECT_ROOT '$_fixture'
builtin set -g _sp_fish_loader_bootstrap_mode strict
builtin set -g _sp_fish_loader_bootstrap_seeds nested_root
builtin source '$_engine/lib/fish/loader.fish'
builtin set -l _status \$_sp_fish_loader_bootstrap_status
builtin set -e _sp_fish_loader_bootstrap_status
builtin test "\$_status" -ne 0; or exit 1
builtin set -q nested_platform_sourced; and exit 1
exit 0
NESTEOF
_nested_platform_status=0
/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_nested_platform_program" >"$_test_root/nested-platform.stdout" 2>"$_test_root/nested-platform.stderr" || _nested_platform_status=$?
if [ "$_nested_platform_status" -ne 0 ]; then
  cat "$_test_root/nested-platform.stdout" "$_test_root/nested-platform.stderr" >&2
  printf '%s\n' 'FAIL: strict nested platform skip did not fail as expected' >&2
  exit 1
fi
if ! grep -F 'unsupported platform for nested_platform' "$_test_root/nested-platform.stderr" >/dev/null; then
  cat "$_test_root/nested-platform.stderr" >&2
  printf '%s\n' 'FAIL: strict nested platform skip must name the platform cause' >&2
  exit 1
fi

# A built release has no Fish entrypoint, no generated Fish plan and no native
# Fish loader, so its hook can load nothing. Installing it must still write the
# hook and a Fish session must start without output or an error.
_built_root="$_test_root/built-release"
mkdir -p "$_built_root/home"
cp -R "$_engine/examples/profile-project" "$_built_root/project"
if ! (cd "$_built_root/project" && "$_engine/bin/valise" build) >"$_built_root/build.stdout" 2>"$_built_root/build.stderr"; then
  cat "$_built_root/build.stdout" "$_built_root/build.stderr" >&2
  printf '%s\n' 'FAIL: example project did not build for the Fish hook test' >&2
  exit 1
fi
_built_path="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$_fish")"
if ! (cd "$_built_root/project/build/release" && /usr/bin/env -i HOME="$_built_root/home" TMPDIR="${TMPDIR:-/tmp}" PATH="$_built_path" XDG_DATA_HOME="$_built_root/home/.local/share" XDG_STATE_HOME="$_built_root/home/.local/state" "$_engine/bin/valise" install) >"$_built_root/install.stdout" 2>"$_built_root/install.stderr"; then
  cat "$_built_root/install.stdout" "$_built_root/install.stderr" >&2
  printf '%s\n' 'FAIL: built release did not install for the Fish hook test' >&2
  exit 1
fi
if [ ! -f "$_built_root/home/.config/fish/conf.d/valise.fish" ]; then
  printf '%s\n' 'FAIL: built release install wrote no Fish hook' >&2
  exit 1
fi
_built_status=0
/usr/bin/env -i HOME="$_built_root/home" TMPDIR="${TMPDIR:-/tmp}" PATH="$_built_path" XDG_DATA_HOME="$_built_root/home/.local/share" XDG_STATE_HOME="$_built_root/home/.local/state" "$_fish" -c 'true' >"$_built_root/fish.stdout" 2>"$_built_root/fish.stderr" || _built_status=$?
if [ "$_built_status" -ne 0 ]; then
  cat "$_built_root/fish.stdout" "$_built_root/fish.stderr" >&2
  printf '%s\n' 'FAIL: Fish session failed with a built release active' >&2
  exit 1
fi
if [ -s "$_built_root/fish.stdout" ] || [ -s "$_built_root/fish.stderr" ]; then
  cat "$_built_root/fish.stdout" "$_built_root/fish.stderr" >&2
  printf '%s\n' 'FAIL: Fish session with a built release active must be silent' >&2
  exit 1
fi

# The hook itself must report success. A silent-but-failing hook is still a
# broken startup path, and the no-op must not leave private helpers behind.
_built_hook_status=0
/usr/bin/env -i HOME="$_built_root/home" TMPDIR="${TMPDIR:-/tmp}" PATH="$_built_path" \
  "$_fish" --no-config -c 'source "$HOME/.config/fish/conf.d/valise.fish"; echo status=$status; for helper in (functions --all --names); string match -q "__valise_fish_*" -- $helper; and echo leak=$helper; end; exit 0' \
  >"$_built_root/hook.stdout" 2>"$_built_root/hook.stderr" || _built_hook_status=$?
if [ "$_built_hook_status" -ne 0 ] || [ "$(cat "$_built_root/hook.stdout")" != 'status=0' ] || [ -s "$_built_root/hook.stderr" ]; then
  cat "$_built_root/hook.stdout" "$_built_root/hook.stderr" >&2
  printf '%s\n' 'FAIL: built-release Fish hook must succeed, stay silent and leave no helper' >&2
  exit 1
fi

_project_adapter=$(CDPATH= cd "$_engine/../.." && pwd -P)/shell/entrypoints/fish/profile.fish
_have_public_adapter=1
if [ ! -f "$_project_adapter" ]; then
  printf 'NOTE: consuming-project Fish adapter not found at %s; skipping public-adapter coverage\n' "$_project_adapter"
  _have_public_adapter=0
fi
if [ "$_have_public_adapter" -eq 1 ]; then
_public_root="$_test_root/public"
_public_engine_lib="$_public_root/vendor/shell-profile/lib/fish"
_missing_root="$_test_root/missing-public"
mkdir -p "$_public_engine_lib" "$_public_root/module.d" "$_public_root/modules/fish/public" "$_public_root/generated" "$_missing_root/entrypoints/fish"
cp "$_engine/lib/fish/metadata.fish" "$_public_engine_lib/metadata.fish"
cp "$_engine/lib/fish/loader.fish" "$_public_engine_lib/loader.fish"
cp "$_project_adapter" "$_missing_root/entrypoints/fish/profile.fish"
_bad_root="$_test_root/bad-public"
mkdir -p "$_bad_root/vendor/shell-profile/lib/fish" "$_bad_root/entrypoints/fish"
cp "$_project_adapter" "$_bad_root/entrypoints/fish/profile.fish"
cp "$_engine/lib/fish/loader.fish" "$_bad_root/vendor/shell-profile/lib/fish/loader.fish"
# Deliberately failing metadata may forge state before returning.
printf '%s\n' 'function caller_owned_public_metadata; echo replaced-public-metadata; end; function caller_owned_generated_metadata; echo replaced-generated-metadata; end; set -gx VALISE_FISH_READY 1; set -g _sp_fish_loader_bootstrap_status 0; false' > "$_bad_root/vendor/shell-profile/lib/fish/metadata.fish"
_bad_generated_root="$_test_root/bad-generated"
mkdir -p "$_bad_generated_root/vendor/shell-profile/lib/fish"
cp "$_engine/lib/fish/loader.fish" "$_bad_generated_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_bad_root/vendor/shell-profile/lib/fish/metadata.fish" "$_bad_generated_root/vendor/shell-profile/lib/fish/metadata.fish"
# The public adapter must ignore this untrusted generated plan and use the
# source-driven loader instead.
printf '%s\n' 'set -g public_plan_sourced 1' >"$_public_root/generated/installed-modules.fish"
# This same-user attacker path deliberately ends in the historical loader
# suffix. It copies the trusted implementation body onto that path so the
# provenance check must reject the exact mismatch without sourcing it again.
_loader_suffix_attack_dir="$_test_root/loader-suffix-attack/vendor/shell-profile/lib/fish"
mkdir -p "$_loader_suffix_attack_dir"
cat >"$_loader_suffix_attack_dir/loader.fish" <<'EOF'
if builtin set -q _loader_suffix_source_count
  builtin set -g _loader_suffix_source_count (builtin math $_loader_suffix_source_count + 1)
else
  builtin set -g _loader_suffix_source_count 1
end
builtin functions --copy _sp_fish_loader_load_ordered_impl _sp_fish_loader_suffix_copy
builtin functions --erase _sp_fish_loader_load_ordered_impl
builtin functions --copy _sp_fish_loader_suffix_copy _sp_fish_loader_load_ordered_impl
EOF
_meta "$_public_root/module.d/fish_path.meta" fish_path fish any read-only public_fish_path_loaded modules/fish/public/fish_path.fish
_body "$_public_root/modules/fish/public/fish_path.fish" 'set -g public_fish_path_loaded 1; function public_fish_path_loaded; end'
_meta "$_public_root/module.d/fish_environment.meta" fish_environment fish any read-only public_fish_environment_loaded modules/fish/public/fish_environment.fish fish_path
_body "$_public_root/modules/fish/public/fish_environment.fish" 'set -g public_fish_environment_loaded 1; function public_fish_environment_loaded; end'
_meta "$_public_root/module.d/fish_secure_local_bin.meta" fish_secure_local_bin fish any read-only public_fish_secure_local_bin_loaded modules/fish/public/fish_secure_local_bin.fish fish_path
_body "$_public_root/modules/fish/public/fish_secure_local_bin.fish" 'set -g public_fish_secure_local_bin_loaded 1; function public_fish_secure_local_bin_loaded; end'
mkdir -p "$_test_home/.config/valise"
ln -s "$_public_root" "$_test_home/.config/valise/active"
HOME="$_test_home" XDG_CONFIG_HOME="$_test_home/.config" XDG_DATA_HOME="$_test_home/.local/share" XDG_STATE_HOME="$_test_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish.fish"
# Exercise the emitted fallback in a fresh Fish process, before any adapter
# source can establish a readiness marker in the caller.
_init_program="$_test_root/init-runtime.fish"
cat >"$_init_program" <<EOF
builtin source '$_test_root/valise-init-fish.fish'
set -l _init_status \$status
builtin test \$_init_status -eq 0; or exit 1
builtin set -q VALISE_FISH_READY; or exit 1
set -l _init_expected_root (builtin path resolve -- '$_public_root')
builtin test "\$SHELL_PROJECT_ROOT" = "\$_init_expected_root"; or exit 1
builtin set -q public_plan_sourced; and exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
  exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_init_program" >"$_test_root/init.stdout" 2>"$_test_root/init.stderr"; then
  cat "$_test_root/init.stdout" >&2
  cat "$_test_root/init.stderr" >&2
  exit 1
fi

# The default generated integration is an installed-release surface. An
# arbitrary active symlink must be rejected before any entrypoint or generated
# plan can execute. Source-tree fixtures opt into the explicit --source-tree
# mode above; they must not silently weaken the installed authentication path.
_unauthenticated_root="$_test_root/unauthenticated-active"
_unauthenticated_marker="$_test_root/unauthenticated-active.marker"
mkdir -p "$_unauthenticated_root/entrypoints/fish"
printf '%s\n' 'builtin printf "%s\\n" unverified > "$UNAUTHENTICATED_MARKER"; return 0' >"$_unauthenticated_root/entrypoints/fish/profile.fish"
_unauthenticated_home="$_test_root/unauthenticated-home"
mkdir -p "$_unauthenticated_home/.config/valise"
ln -s "$_unauthenticated_root" "$_unauthenticated_home/.config/valise/active"
HOME="$_unauthenticated_home" XDG_CONFIG_HOME="$_unauthenticated_home/.config" XDG_DATA_HOME="$_unauthenticated_home/.local/share" XDG_STATE_HOME="$_unauthenticated_home/.local/state" "$_engine/bin/valise" init fish >"$_test_root/valise-init-fish-unauthenticated.fish"
_unauthenticated_program="$_test_root/init-unauthenticated.fish"
cat >"$_unauthenticated_program" <<EOF
builtin source '$_test_root/valise-init-fish-unauthenticated.fish'
set -l _unauthenticated_status \$status
builtin test \$_unauthenticated_status -ne 0; or exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_unauthenticated_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" UNAUTHENTICATED_MARKER="$_unauthenticated_marker" "$_fish" "$_unauthenticated_program" >"$_test_root/init-unauthenticated.stdout" 2>"$_test_root/init-unauthenticated.stderr"; then
  cat "$_test_root/init-unauthenticated.stdout" >&2
  cat "$_test_root/init-unauthenticated.stderr" >&2
  exit 1
fi
test ! -e "$_unauthenticated_marker" || {
  printf '%s\n' 'FAIL: unauthenticated active release executed an entrypoint' >&2
  exit 1
}

# Installed ownership ledgers authenticate source provenance against the
# already-authenticated release root, not merely an entrypoint filename suffix.
# Build a small sealed release with the real adapter and engine primitives so a
# regular attacker file cannot erase a caller-owned function before dispatch.
_installed_payload="$_test_root/installed-payload"
_installed_releases="$_test_root/installed-releases"
_installed_home="$_test_root/installed-home"
mkdir -p "$_installed_payload/entrypoints/fish" "$_installed_payload/vendor/shell-profile/lib/fish" "$_installed_payload/module.d" "$_installed_payload/modules/fish/public" "$_installed_payload/generated" "$_installed_releases" "$_installed_home/.config/valise"
cp "$_project_adapter" "$_installed_payload/entrypoints/fish/profile.fish"
cp "$_engine/lib/fish/loader.fish" "$_installed_payload/vendor/shell-profile/lib/fish/loader.fish"
cp "$_engine/lib/fish/metadata.fish" "$_installed_payload/vendor/shell-profile/lib/fish/metadata.fish"
cp "$_public_root/module.d/"* "$_installed_payload/module.d/"
cp "$_public_root/modules/fish/public/"* "$_installed_payload/modules/fish/public/"
printf '%s\n' 'return 0' >"$_installed_payload/generated/installed-modules.fish"
_installed_manifest="$_test_root/installed-manifest"
{
  printf '%s\n' shell-profile-release-manifest-v1
  printf '%s\n' 'destination\tsource\tsource_mode\tinstall_mode\tbytes\tsha256'
  find "$_installed_payload" -type f -print | sort | while IFS= read -r _installed_file; do
    _installed_dest=${_installed_file#"$_installed_payload"/}
    _installed_bytes=$(wc -c <"$_installed_file" | tr -d '[:space:]')
    _installed_sha=$(shasum -a 256 "$_installed_file" | awk '{print $1}')
    printf '%s\t%s\t0644\t0444\t%s\t%s\n' "$_installed_dest" "shell-test/$_installed_dest" "$_installed_bytes" "$_installed_sha"
  done
} >"$_installed_manifest"
_installed_id=$(shasum -a 256 "$_installed_manifest" | awk '{print $1}')
_installed_root="$_installed_releases/$_installed_id"
mkdir -p "$_installed_root"
cp -R "$_installed_payload/." "$_installed_root/"
cp "$_installed_manifest" "$_installed_root/.valise-manifest"
find "$_installed_root" -type d -exec chmod 0555 {} +
find "$_installed_root" -type f -exec chmod 0444 {} +
ln -s "$_installed_root" "$_installed_home/.config/valise/active"
HOME="$_installed_home" XDG_CONFIG_HOME="$_installed_home/.config" XDG_DATA_HOME="$_test_root/installed-data" XDG_STATE_HOME="$_test_root/installed-state" "$_engine/bin/valise" init fish >"$_test_root/valise-init-fish-installed.fish"
_installed_suffix_attacker="$_test_root/installed-suffix-attacker"
mkdir -p "$_installed_suffix_attacker/entrypoints/fish"
printf '%s\n' 'function installed_suffix_caller_owned; echo installed-suffix-caller; end' >"$_installed_suffix_attacker/entrypoints/fish/profile.fish"
_installed_suffix_program="$_test_root/installed-suffix.fish"
cat >"$_installed_suffix_program" <<EOF
builtin source '$_installed_suffix_attacker/entrypoints/fish/profile.fish'
builtin set -g _sp_fish_entrypoint_owned_exports installed_suffix_caller_owned
builtin set -g _sp_fish_entrypoint_owned_sources (builtin functions --details installed_suffix_caller_owned)
builtin source '$_test_root/valise-init-fish-installed.fish'
set -l _installed_suffix_status \$status
builtin test \$_installed_suffix_status -eq 125; or exit 1
functions -q installed_suffix_caller_owned; or exit 1
for _installed_suffix_ledger in _sp_fish_entrypoint_owned_exports _sp_fish_entrypoint_owned_sources
  builtin set -q \$_installed_suffix_ledger; and exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_installed_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_installed_suffix_program" >"$_test_root/installed-suffix.stdout" 2>"$_test_root/installed-suffix.stderr"; then
  cat "$_test_root/installed-suffix.stdout" >&2
  cat "$_test_root/installed-suffix.stderr" >&2
  exit 1
fi

# A syntactically valid metadata source that mutates loader-protected state
# must be rejected transactionally even when it returns success. This guards
# the generated public adapter's metadata phase before native loader startup.
_metadata_poison_root="$_test_root/metadata-poison"
mkdir -p "$_metadata_poison_root/vendor/shell-profile/lib/fish" "$_metadata_poison_root/module.d" "$_metadata_poison_root/modules/fish/public" "$_metadata_poison_root/generated"
cp "$_engine/lib/fish/loader.fish" "$_metadata_poison_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_engine/lib/fish/metadata.fish" "$_metadata_poison_root/vendor/shell-profile/lib/fish/metadata.fish"
cp "$_engine/lib/fish/metadata.fish" "$_test_root/metadata-poison-clean.fish"
cp "$_public_root/module.d/"* "$_metadata_poison_root/module.d/"
cp "$_public_root/modules/fish/public/"* "$_metadata_poison_root/modules/fish/public/"
printf '%s\n' 'set -gx SHELL_PROJECT_ROOT metadata-poisoned-root; set -U SHELL_PROJECT_ROOT metadata-poisoned-universal; set -gx _sp_fish_loader_expected_source forged-loader-anchor; set -Ux _sp_fish_metadata_expected_source forged-metadata-anchor; set -g _sp_fish_loader_bootstrap_mode metadata-poisoned; return 0' >>"$_metadata_poison_root/vendor/shell-profile/lib/fish/metadata.fish"
_metadata_poison_home="$_test_root/metadata-poison-home"
mkdir -p "$_metadata_poison_home/.config/valise"
ln -s "$_metadata_poison_root" "$_metadata_poison_home/.config/valise/active"
HOME="$_metadata_poison_home" XDG_CONFIG_HOME="$_metadata_poison_home/.config" XDG_DATA_HOME="$_metadata_poison_home/.local/share" XDG_STATE_HOME="$_metadata_poison_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-poison.fish"
_metadata_poison_program="$_test_root/init-metadata-poison.fish"
cat >"$_metadata_poison_program" <<EOF
builtin set -U SHELL_PROJECT_ROOT metadata-caller-universal
builtin set -gx SHELL_PROJECT_ROOT metadata-caller-root
builtin source '$_test_root/valise-init-fish-metadata-poison.fish'
set -l _metadata_poison_status \$status
builtin test \$_metadata_poison_status -ne 0; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = metadata-caller-root; or exit 1
builtin set -q -g SHELL_PROJECT_ROOT; or exit 1
builtin set -q -U SHELL_PROJECT_ROOT; or exit 1
builtin set -e -g SHELL_PROJECT_ROOT
builtin test "\$SHELL_PROJECT_ROOT" = metadata-caller-universal; or exit 1
builtin set -gx SHELL_PROJECT_ROOT metadata-caller-root
set -l _metadata_poison_canonical_root (builtin path resolve -- '$_metadata_poison_root')
builtin test "\$_sp_fish_loader_expected_source" = "\$_metadata_poison_canonical_root/vendor/shell-profile/lib/fish/loader.fish"; or exit 1
builtin test "\$_sp_fish_metadata_expected_source" = "\$_metadata_poison_canonical_root/vendor/shell-profile/lib/fish/metadata.fish"; or exit 1
builtin set -q -U _sp_fish_loader_expected_source; and exit 1
builtin set -q -U _sp_fish_metadata_expected_source; and exit 1
builtin set -q _sp_fish_loader_bootstrap_mode; and exit 1
for _metadata_alias in (builtin functions --all --names | string match -r '^__valise_fish_metadata_(capture|restore|snapshot|source)_')
    exit 1
end
command cp "\$METADATA_POISON_CLEAN" '$_metadata_poison_root/vendor/shell-profile/lib/fish/metadata.fish'; or exit 1
builtin set -gx SHELL_PROJECT_ROOT metadata-caller-root-second
builtin source '$_test_root/valise-init-fish-metadata-poison.fish'
or exit 1
builtin set -q VALISE_FISH_READY; or exit 1
for _metadata_alias in (builtin functions --all --names | string match -r '^__valise_fish_metadata_(capture|restore|snapshot|source)_')
    exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_metadata_poison_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" METADATA_POISON_CLEAN="$_test_root/metadata-poison-clean.fish" "$_fish" "$_metadata_poison_program" >"$_test_root/init-metadata-poison.stdout" 2>"$_test_root/init-metadata-poison.stderr"; then
  cat "$_test_root/init-metadata-poison.stdout" >&2
  cat "$_test_root/init-metadata-poison.stderr" >&2
  exit 1
fi

# Generated metadata is executable Fish source. Build the namespace command
# and erase option dynamically so lexical preflight cannot identify them; the
# post-source indexed provenance check must terminate the child with 125.
_metadata_dynamic_root="$_test_root/metadata-dynamic"
mkdir -p "$_metadata_dynamic_root/vendor/shell-profile/lib/fish"
cp "$_engine/lib/fish/loader.fish" "$_metadata_dynamic_root/vendor/shell-profile/lib/fish/loader.fish"
cat >"$_metadata_dynamic_root/vendor/shell-profile/lib/fish/metadata.fish" <<'EOF'
function metadata_cd_replacer
    set -l _function_command (string join "" func tions)
    set -l _erase_word (string join "" era se)
    set -l _erase_option --$_erase_word
    set -l _critical_name (string join "" c d)
    $_function_command $_erase_option $_critical_name
    function $_critical_name
        builtin printf '%s\n' attacker > "$METADATA_DYNAMIC_MARKER"
    end
end
metadata_cd_replacer
return 0
EOF
_metadata_dynamic_home="$_test_root/metadata-dynamic-home"
mkdir -p "$_metadata_dynamic_home/.config/valise"
ln -s "$_metadata_dynamic_root" "$_metadata_dynamic_home/.config/valise/active"
HOME="$_metadata_dynamic_home" XDG_CONFIG_HOME="$_metadata_dynamic_home/.config" XDG_DATA_HOME="$_metadata_dynamic_home/.local/share" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-dynamic.fish"
_metadata_dynamic_program="$_test_root/init-metadata-dynamic.fish"
cat >"$_metadata_dynamic_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT metadata-dynamic-caller-root
builtin source '$_test_root/valise-init-fish-metadata-dynamic.fish'
EOF
_metadata_dynamic_marker="$_test_root/metadata-dynamic-marker"
if /usr/bin/env -i HOME="$_metadata_dynamic_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" METADATA_DYNAMIC_MARKER="$_metadata_dynamic_marker" "$_fish" "$_metadata_dynamic_program" >"$_test_root/init-metadata-dynamic.stdout" 2>"$_test_root/init-metadata-dynamic.stderr"; then
  printf '%s\n' 'FAIL: generated dynamic metadata replacement did not terminate Fish with status 125' >&2
  exit 1
else
  _metadata_dynamic_status=$?
  if [ "$_metadata_dynamic_status" -ne 125 ]; then
    cat "$_test_root/init-metadata-dynamic.stdout" >&2
    cat "$_test_root/init-metadata-dynamic.stderr" >&2
    printf 'FAIL: generated dynamic metadata replacement status was %s, expected 125\n' "$_metadata_dynamic_status" >&2
    exit 1
  fi
fi
if [ -e "$_metadata_dynamic_marker" ]; then
  printf '%s\n' 'FAIL: generated dynamic metadata marker was created before fail-closed exit' >&2
  exit 1
fi

# A source-tree adapter failure must not export a derived root when the caller
# did not provide one. This exercises the early infrastructure-failure path in
# a fresh Fish process rather than relying on a pre-seeded root.
_derived_missing_program="$_test_root/derived-missing-runtime.fish"
cat >"$_derived_missing_program" <<EOF
builtin source '$_missing_root/entrypoints/fish/profile.fish'
set -l _derived_missing_status \$status
builtin test \$_derived_missing_status -ne 0; or exit 1
builtin set -q SHELL_PROJECT_ROOT; and exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_derived_missing_program" >"$_test_root/derived-missing.stdout" 2>"$_test_root/derived-missing.stderr"; then
  cat "$_test_root/derived-missing.stdout" >&2
  cat "$_test_root/derived-missing.stderr" >&2
  exit 1
fi

# A failed emitted integration must clear a caller's stale readiness marker in
# a fresh process. Generate the snippet against a separate home with no active
# release, then seed readiness before sourcing it.
_missing_home="$_test_root/missing-home"
mkdir -p "$_missing_home/.config/valise"
HOME="$_missing_home" XDG_CONFIG_HOME="$_missing_home/.config" XDG_DATA_HOME="$_missing_home/.local/share" XDG_STATE_HOME="$_missing_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-missing.fish"
_missing_init_program="$_test_root/init-missing-runtime.fish"
cat >"$_missing_init_program" <<EOF
builtin set -gx VALISE_FISH_READY 1
builtin set -g _sp_fish_loader_bootstrap_status 0
builtin source '$_test_root/valise-init-fish-missing.fish'
set -l _missing_init_status \$status
builtin test \$_missing_init_status -ne 0; or exit 1
builtin set -q VALISE_FISH_READY; and exit 1
builtin set -q _sp_fish_loader_bootstrap_status; and exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
  exit 1
end
# Repeated early failure must not accumulate a fresh random legacy runner.
builtin source '$_test_root/valise-init-fish-missing.fish'
set -l _missing_init_repeat_status \$status
builtin test \$_missing_init_repeat_status -ne 0; or exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
  exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_missing_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_missing_init_program" >"$_test_root/init-missing.stdout" 2>"$_test_root/init-missing.stderr"; then
  cat "$_test_root/init-missing.stdout" >&2
  cat "$_test_root/init-missing.stderr" >&2
  exit 1
fi

# Independently exercise metadata-source failure through the generated
# integration fallback. This root has no project entrypoint, so the fallback
# itself must clear forged readiness and stale handshake state.
_bad_generated_home="$_test_root/bad-generated-home"
mkdir -p "$_bad_generated_home/.config/valise"
ln -s "$_bad_generated_root" "$_bad_generated_home/.config/valise/active"
HOME="$_bad_generated_home" XDG_CONFIG_HOME="$_bad_generated_home/.config" XDG_DATA_HOME="$_bad_generated_home/.local/share" XDG_STATE_HOME="$_bad_generated_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-bad-metadata.fish"
_bad_generated_program="$_test_root/init-bad-metadata.fish"
cat >"$_bad_generated_program" <<EOF
function caller_owned_generated_metadata
  echo caller-generated-metadata
end
builtin set -gx VALISE_FISH_READY 1
builtin set -g _sp_fish_loader_bootstrap_status 0
builtin source '$_test_root/valise-init-fish-bad-metadata.fish'
EOF
if /usr/bin/env -i HOME="$_bad_generated_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_bad_generated_program" >"$_test_root/init-bad-metadata.stdout" 2>"$_test_root/init-bad-metadata.stderr"; then
  printf '%s\n' 'FAIL: generated metadata caller replacement did not terminate' >&2
  exit 1
else
  _bad_generated_status=$?
  if [ "$_bad_generated_status" -ne 125 ]; then
    cat "$_test_root/init-bad-metadata.stdout" >&2
    cat "$_test_root/init-bad-metadata.stderr" >&2
    printf 'FAIL: generated metadata caller replacement status was %s, expected 125\n' "$_bad_generated_status" >&2
    exit 1
  fi
fi

# Generated Fish init must restore every caller-owned SHELL_PROJECT_ROOT
# scope when metadata activation fails: exported global, universal-only, and a
# local shadow inside the caller function.
for _root_scope in global universal local; do
  _root_scope_home="$_test_root/generated-root-rollback-${_root_scope}-home"
  mkdir -p "$_root_scope_home/.config"
  _root_scope_program="$_test_root/generated-root-rollback-$_root_scope.fish"
  case "$_root_scope" in
    global)
      cat >"$_root_scope_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT generated-caller-global
builtin source '$_test_root/valise-init-fish-bad-metadata.fish'
set -l _root_scope_status \$status
builtin test \$_root_scope_status -ne 0; or exit 1
builtin set -q -g SHELL_PROJECT_ROOT; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = generated-caller-global; or exit 1
builtin set -q -U SHELL_PROJECT_ROOT; and exit 1
exit 0
EOF
      ;;
    universal)
      cat >"$_root_scope_program" <<EOF
builtin set -e -g SHELL_PROJECT_ROOT
builtin set -U SHELL_PROJECT_ROOT generated-caller-universal
builtin source '$_test_root/valise-init-fish-bad-metadata.fish'
set -l _root_scope_status \$status
builtin test \$_root_scope_status -ne 0; or exit 1
builtin set -q -g SHELL_PROJECT_ROOT; and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = generated-caller-universal; or exit 1
set -l _fresh_fish_path (status fish-path)
set -l _fresh_universal_value ("\$_fresh_fish_path" -c 'if builtin set -q -U SHELL_PROJECT_ROOT; builtin printf "%s\n" \$SHELL_PROJECT_ROOT; end')
builtin test "\$_fresh_universal_value" = generated-caller-universal; or exit 1
builtin set -e -U SHELL_PROJECT_ROOT
exit 0
EOF
      ;;
    local)
      cat >"$_root_scope_program" <<EOF
function _generated_root_local_source --no-scope-shadowing
  builtin source '$_test_root/valise-init-fish-bad-metadata.fish'
end
function _generated_root_local_probe
  set -l SHELL_PROJECT_ROOT generated-caller-local
  _generated_root_local_source
  set -l _root_scope_status \$status
  builtin test \$_root_scope_status -ne 0; or return 1
  builtin test "\$SHELL_PROJECT_ROOT" = generated-caller-local; or return 1
  builtin set -q -g SHELL_PROJECT_ROOT; and return 1
  builtin set -q -U SHELL_PROJECT_ROOT; and return 1
  return 0
end
_generated_root_local_probe
EOF
      ;;
  esac
  if ! /usr/bin/env -i HOME="$_root_scope_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_root_scope_program" >"$_test_root/generated-root-rollback-$_root_scope.stdout" 2>"$_test_root/generated-root-rollback-$_root_scope.stderr"; then
    cat "$_test_root/generated-root-rollback-$_root_scope.stdout" >&2
    cat "$_test_root/generated-root-rollback-$_root_scope.stderr" >&2
    exit 1
  fi
done

# Generated universal-root rollback must fail closed when Fish reports an
# ordinary metadata failure after the metadata has durably poisoned the
# universal store and then made its parent unwritable. The source-tree
# integration is run in a child so the shell test can restore the disposable
# directory permissions after a deliberate status-125 exit.
_generated_persistence_root="$_test_root/generated-persistence"
_generated_persistence_home="$_test_root/generated-persistence-home"
mkdir -p "$_generated_persistence_root/vendor/shell-profile/lib/fish" "$_generated_persistence_home/.config/valise" "$_generated_persistence_home/.config/fish"
cp "$_engine/lib/fish/loader.fish" "$_generated_persistence_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_engine/lib/fish/metadata.fish" "$_generated_persistence_root/vendor/shell-profile/lib/fish/metadata.fish"
ln -s "$_generated_persistence_root" "$_generated_persistence_home/.config/valise/active"
printf '%s\n' 'builtin set -U SHELL_PROJECT_ROOT generated-durable-poison; builtin set -gx XDG_CONFIG_HOME "$HOME/alternate-config"; command chmod u-w "$HOME/.config/fish"; return 7' >"$_generated_persistence_root/vendor/shell-profile/lib/fish/metadata.fish"
HOME="$_generated_persistence_home" XDG_CONFIG_HOME="$_generated_persistence_home/.config" XDG_DATA_HOME="$_generated_persistence_home/.local/share" XDG_STATE_HOME="$_generated_persistence_home/.local/state" \
  "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-generated-persistence.fish"
_generated_persistence_program="$_test_root/generated-persistence-rollback-failure.fish"
cat >"$_generated_persistence_program" <<EOF
builtin set -U SHELL_PROJECT_ROOT generated-durable-before
builtin source '$_test_root/valise-init-fish-generated-persistence.fish'
exit \$status
EOF
if HOME="$_generated_persistence_home" XDG_CONFIG_HOME="$_generated_persistence_home/.config" \
  TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" \
  "$_fish" "$_generated_persistence_program" >"$_test_root/generated-persistence-failure.stdout" 2>"$_test_root/generated-persistence-failure.stderr"; then
  command chmod u+w "$_generated_persistence_home/.config/fish"
  printf '%s\n' 'FAIL: generated durable universal rollback failure returned success' >&2
  exit 1
else
  _generated_persistence_failure_status=$?
  command chmod u+w "$_generated_persistence_home/.config/fish"
  if [ "$_generated_persistence_failure_status" -ne 125 ]; then
    cat "$_test_root/generated-persistence-failure.stdout" >&2
    cat "$_test_root/generated-persistence-failure.stderr" >&2
    printf 'FAIL: generated durable universal rollback returned %s, expected 125\n' "$_generated_persistence_failure_status" >&2
    exit 1
  fi
fi

# The same generated root rollback must fail closed when the universal
# before-image is absent. The poison still reaches fish_variables, so checking
# only current-process presence would incorrectly report success.
command chmod u+w "$_generated_persistence_home/.config/fish"
rm -f "$_generated_persistence_home/.config/fish/fish_variables"
_generated_absent_persistence_program="$_test_root/generated-absent-persistence-rollback.fish"
cat >"$_generated_absent_persistence_program" <<EOF
builtin set -e -g SHELL_PROJECT_ROOT 2>/dev/null
builtin set -e -U SHELL_PROJECT_ROOT 2>/dev/null
builtin source '$_test_root/valise-init-fish-generated-persistence.fish'
exit \$status
EOF
if HOME="$_generated_persistence_home" XDG_CONFIG_HOME="$_generated_persistence_home/.config" \
  TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" \
  "$_fish" "$_generated_absent_persistence_program" >"$_test_root/generated-absent-persistence.stdout" 2>"$_test_root/generated-absent-persistence.stderr"; then
  command chmod u+w "$_generated_persistence_home/.config/fish"
  printf '%s\n' 'FAIL: generated absent-universal rollback failure returned success' >&2
  exit 1
else
  _generated_absent_persistence_status=$?
  command chmod u+w "$_generated_persistence_home/.config/fish"
  if [ "$_generated_absent_persistence_status" -ne 125 ]; then
    cat "$_test_root/generated-absent-persistence.stdout" >&2
    cat "$_test_root/generated-absent-persistence.stderr" >&2
    printf 'FAIL: generated absent-universal rollback returned %s, expected 125\n' "$_generated_absent_persistence_status" >&2
    exit 1
  fi
fi

# VALISE_MODULE_ROOT is restored through the generated scratch helper,
# not the project-root helper. Its universal before-image must receive the
# same durable rollback guarantee.
_generated_module_persistence_root="$_test_root/generated-module-persistence"
_generated_module_persistence_home="$_test_root/generated-module-persistence-home"
mkdir -p "$_generated_module_persistence_root/vendor/shell-profile/lib/fish" "$_generated_module_persistence_home/.config/valise" "$_generated_module_persistence_home/.config/fish"
cp "$_engine/lib/fish/loader.fish" "$_generated_module_persistence_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_engine/lib/fish/metadata.fish" "$_generated_module_persistence_root/vendor/shell-profile/lib/fish/metadata.fish"
ln -s "$_generated_module_persistence_root" "$_generated_module_persistence_home/.config/valise/active"
printf '%s\n' 'builtin set -U VALISE_MODULE_ROOT generated-module-poison; command chmod u-w "$HOME/.config/fish"; return 7' >"$_generated_module_persistence_root/vendor/shell-profile/lib/fish/metadata.fish"
HOME="$_generated_module_persistence_home" XDG_CONFIG_HOME="$_generated_module_persistence_home/.config" XDG_DATA_HOME="$_generated_module_persistence_home/.local/share" XDG_STATE_HOME="$_generated_module_persistence_home/.local/state" \
  "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-generated-module-persistence.fish"
_generated_module_persistence_program="$_test_root/generated-module-persistence-rollback-failure.fish"
cat >"$_generated_module_persistence_program" <<EOF
builtin set -U VALISE_MODULE_ROOT generated-module-before
builtin source '$_test_root/valise-init-fish-generated-module-persistence.fish'
exit \$status
EOF
if HOME="$_generated_module_persistence_home" XDG_CONFIG_HOME="$_generated_module_persistence_home/.config" \
  TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" \
  "$_fish" "$_generated_module_persistence_program" >"$_test_root/generated-module-persistence.stdout" 2>"$_test_root/generated-module-persistence.stderr"; then
  command chmod u+w "$_generated_module_persistence_home/.config/fish"
  printf '%s\n' 'FAIL: generated module-root rollback failure returned success' >&2
  exit 1
else
  _generated_module_persistence_status=$?
  command chmod u+w "$_generated_module_persistence_home/.config/fish"
  if [ "$_generated_module_persistence_status" -ne 125 ]; then
    cat "$_test_root/generated-module-persistence.stdout" >&2
    cat "$_test_root/generated-module-persistence.stderr" >&2
    printf 'FAIL: generated module-root rollback returned %s, expected 125\n' "$_generated_module_persistence_status" >&2
    exit 1
  fi
fi

# A valid project entrypoint publishes the exact readiness contract and is
# accepted by the emitted integration.
_good_entry_root="$_test_root/good-entrypoint"
mkdir -p "$_good_entry_root/entrypoints/fish"
printf '%s\n' 'set -gx VALISE_FISH_READY 1; return 0' > "$_good_entry_root/entrypoints/fish/profile.fish"
_good_entry_home="$_test_root/good-entry-home"
mkdir -p "$_good_entry_home/.config/valise"
ln -s "$_good_entry_root" "$_good_entry_home/.config/valise/active"
HOME="$_good_entry_home" XDG_CONFIG_HOME="$_good_entry_home/.config" XDG_DATA_HOME="$_good_entry_home/.local/share" XDG_STATE_HOME="$_good_entry_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-good-entrypoint.fish"
_good_entry_program="$_test_root/init-good-entrypoint.fish"
cat >"$_good_entry_program" <<EOF
builtin source '$_test_root/valise-init-fish-good-entrypoint.fish'
set -l _good_entry_status \$status
builtin test \$_good_entry_status -eq 0; or exit 1
builtin set -q VALISE_FISH_READY; or exit 1
builtin test \$VALISE_FISH_READY = 1; or exit 1
set -l _good_entry_expected_root (builtin path resolve -- '$_good_entry_root')
builtin test "\$SHELL_PROJECT_ROOT" = "\$_good_entry_expected_root"; or exit 1
for _persistence_helper in (builtin functions --all --names | string match -r '^__valise_fish_verify_[0-9]+$')
  printf 'FAIL: generated persistence verifier leaked: %s\n' "\$_persistence_helper" >&2
  exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_good_entry_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_good_entry_program" >"$_test_root/init-good-entrypoint.stdout" 2>"$_test_root/init-good-entrypoint.stderr"; then
  cat "$_test_root/init-good-entrypoint.stdout" >&2
  cat "$_test_root/init-good-entrypoint.stderr" >&2
  exit 1
fi

# A successful generated entrypoint owns the functions it creates until the
# next activation. Switching the same active pointer to a second release must
# remove only the first release's owned functions, retain an unrelated caller
# function, and publish the second release's ownership ledger. This exercises
# the real generated-entrypoint route rather than the metadata-only switch
# fixture below.
_entrypoint_switch_a="$_test_root/entrypoint-switch-a"
_entrypoint_switch_b="$_test_root/entrypoint-switch-b"
mkdir -p "$_entrypoint_switch_a/entrypoints/fish" "$_entrypoint_switch_b/entrypoints/fish"
printf '%s\n' 'function entrypoint_release_a_only; echo release-a; end; set -gx VALISE_FISH_READY 1; return 0' >"$_entrypoint_switch_a/entrypoints/fish/profile.fish"
printf '%s\n' 'function entrypoint_release_b_only; echo release-b; end; set -gx VALISE_FISH_READY 1; return 0' >"$_entrypoint_switch_b/entrypoints/fish/profile.fish"
_entrypoint_switch_home="$_test_root/entrypoint-switch-home"
mkdir -p "$_entrypoint_switch_home/.config/valise"
ln -s "$_entrypoint_switch_a" "$_entrypoint_switch_home/.config/valise/active"
HOME="$_entrypoint_switch_home" XDG_CONFIG_HOME="$_entrypoint_switch_home/.config" XDG_DATA_HOME="$_entrypoint_switch_home/.local/share" XDG_STATE_HOME="$_entrypoint_switch_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-switch-a.fish"
rm "$_entrypoint_switch_home/.config/valise/active"
ln -s "$_entrypoint_switch_b" "$_entrypoint_switch_home/.config/valise/active"
HOME="$_entrypoint_switch_home" XDG_CONFIG_HOME="$_entrypoint_switch_home/.config" XDG_DATA_HOME="$_entrypoint_switch_home/.local/share" XDG_STATE_HOME="$_entrypoint_switch_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-switch-b.fish"
rm "$_entrypoint_switch_home/.config/valise/active"
ln -s "$_entrypoint_switch_a" "$_entrypoint_switch_home/.config/valise/active"
_entrypoint_switch_program="$_test_root/entrypoint-switch.fish"
cat >"$_entrypoint_switch_program" <<EOF
function caller_owned_entrypoint_switch
    echo caller-entrypoint-switch
end
builtin source '$_test_root/valise-init-fish-entrypoint-switch-a.fish'
or exit 1
functions -q entrypoint_release_a_only; or exit 1
builtin set -q _sp_fish_entrypoint_owned_exports; or exit 1
builtin contains -- entrypoint_release_a_only \$_sp_fish_entrypoint_owned_exports; or exit 1
test (caller_owned_entrypoint_switch) = caller-entrypoint-switch; or exit 1
command rm "$_entrypoint_switch_home/.config/valise/active"
command ln -s "$_entrypoint_switch_b" "$_entrypoint_switch_home/.config/valise/active"
builtin source '$_test_root/valise-init-fish-entrypoint-switch-b.fish'
or exit 1
functions -q entrypoint_release_a_only; and exit 1
functions -q entrypoint_release_b_only; or exit 1
builtin contains -- entrypoint_release_b_only \$_sp_fish_entrypoint_owned_exports; or exit 1
test (caller_owned_entrypoint_switch) = caller-entrypoint-switch; or exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_entrypoint_switch_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_entrypoint_switch_program" >"$_test_root/entrypoint-switch.stdout" 2>"$_test_root/entrypoint-switch.stderr"; then
  cat "$_test_root/entrypoint-switch.stdout" >&2
  cat "$_test_root/entrypoint-switch.stderr" >&2
  exit 1
fi

# A caller cannot pre-seed the generated entrypoint ownership ledger with a
# caller-owned function. The runner must reject the ledger before any deletion,
# clear it, and preserve the function it names.
_entrypoint_forged_home="$_test_root/entrypoint-forged-home"
mkdir -p "$_entrypoint_forged_home/.config/valise"
ln -s "$_entrypoint_switch_a" "$_entrypoint_forged_home/.config/valise/active"
HOME="$_entrypoint_forged_home" XDG_CONFIG_HOME="$_entrypoint_forged_home/.config" XDG_DATA_HOME="$_entrypoint_forged_home/.local/share" XDG_STATE_HOME="$_entrypoint_forged_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-forged.fish"
_entrypoint_forged_program="$_test_root/entrypoint-forged.fish"
cat >"$_entrypoint_forged_program" <<EOF
function caller_owned_entrypoint_ledger
    echo caller-entrypoint-ledger
end
builtin set -g _sp_fish_entrypoint_owned_exports caller_owned_entrypoint_ledger
builtin set -g _sp_fish_entrypoint_owned_sources (builtin functions --details caller_owned_entrypoint_ledger)
builtin source '$_test_root/valise-init-fish-entrypoint-forged.fish'
set -l _entrypoint_forged_status \$status
builtin test \$_entrypoint_forged_status -eq 125; or exit 1
functions -q caller_owned_entrypoint_ledger; or exit 1
builtin set -q _sp_fish_entrypoint_owned_exports; and exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_entrypoint_forged_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_entrypoint_forged_program" >"$_test_root/entrypoint-forged.stdout" 2>"$_test_root/entrypoint-forged.stderr"; then
  cat "$_test_root/entrypoint-forged.stdout" >&2
  cat "$_test_root/entrypoint-forged.stderr" >&2
  exit 1
fi

# An entrypoint that otherwise publishes readiness but forges generated
# rollback names is not a valid success. The integration must fail closed
# before attempting any in-process restoration of compromised critical helpers.
_hostile_good_entry_root="$_test_root/hostile-good-entrypoint"
mkdir -p "$_hostile_good_entry_root/entrypoints/fish"
cat >"$_hostile_good_entry_root/entrypoints/fish/profile.fish" <<'EOF'
for _visible_scratch_name in (set --names | string match -r '^__valise_fish_scratch_state_.*$')
    set -gx "$_visible_scratch_name" forged-visible-scratch
end
for _cleanup_helper in (builtin functions --all --names)
    if builtin string match -q -r '^__valise_fish_(restore|scratch_restore|entrypoint_backup|metadata_backup)_' -- "$_cleanup_helper"
        function $_cleanup_helper
            return 0
        end
    end
end
set -gx _valise_fish_root_global_set forged-entry-global
set -Ux _valise_fish_root_global_set forged-entry-universal
set -gx VALISE_FISH_READY 1
return 23
EOF
_hostile_good_entry_home="$_test_root/hostile-good-entry-home"
mkdir -p "$_hostile_good_entry_home/.config/valise"
ln -s "$_hostile_good_entry_root" "$_hostile_good_entry_home/.config/valise/active"
HOME="$_hostile_good_entry_home" XDG_CONFIG_HOME="$_hostile_good_entry_home/.config" XDG_DATA_HOME="$_hostile_good_entry_home/.local/share" XDG_STATE_HOME="$_hostile_good_entry_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-hostile-good-entrypoint.fish"
_hostile_good_entry_program="$_test_root/init-hostile-good-entrypoint.fish"
cat >"$_hostile_good_entry_program" <<EOF
builtin set -gx _valise_fish_root_global_set preexisting-global
builtin set -Ux _valise_fish_root_global_set preexisting-universal
builtin set -gx _valise_fish_scratch_state__valise_fish_root_global_set_global_present preexisting-state-global
builtin set -Ux _valise_fish_scratch_state__valise_fish_root_global_set_global_present preexisting-state-universal
builtin source '$_test_root/valise-init-fish-hostile-good-entrypoint.fish'
set -l _hostile_good_status \$status
builtin test \$_hostile_good_status -eq 125; or exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_hostile_good_entry_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_hostile_good_entry_program" >"$_test_root/init-hostile-good-entrypoint.stdout" 2>"$_test_root/init-hostile-good-entrypoint.stderr"; then
  cat "$_test_root/init-hostile-good-entrypoint.stdout" >&2
  cat "$_test_root/init-hostile-good-entrypoint.stderr" >&2
  exit 1
fi

# A successful project entrypoint cannot forge the trusted active root. The
# transaction rejects the replacement, removes its helper, and the outer
# rollback restores the caller-owned root.
_forged_root_entry_root="$_test_root/forged-root-entrypoint"
mkdir -p "$_forged_root_entry_root/entrypoints/fish"
printf '%s\n' 'function forged_root_entrypoint_helper; end; set -gx SHELL_PROJECT_ROOT forged-entrypoint-root; set -gx VALISE_FISH_READY 1; return 0' >"$_forged_root_entry_root/entrypoints/fish/profile.fish"
_forged_root_entry_home="$_test_root/forged-root-entrypoint-home"
mkdir -p "$_forged_root_entry_home/.config/valise"
ln -s "$_forged_root_entry_root" "$_forged_root_entry_home/.config/valise/active"
HOME="$_forged_root_entry_home" XDG_CONFIG_HOME="$_forged_root_entry_home/.config" XDG_DATA_HOME="$_forged_root_entry_home/.local/share" XDG_STATE_HOME="$_forged_root_entry_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-forged-root-entrypoint.fish"
_forged_root_entry_program="$_test_root/init-forged-root-entrypoint.fish"
cat >"$_forged_root_entry_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT caller-forged-root
builtin source '$_test_root/valise-init-fish-forged-root-entrypoint.fish'
set -l _forged_root_entry_status \$status
builtin test \$_forged_root_entry_status -ne 0; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = caller-forged-root; or exit 1
functions -q forged_root_entrypoint_helper; and exit 1
builtin set -q VALISE_FISH_READY; and exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_forged_root_entry_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_forged_root_entry_program" >"$_test_root/init-forged-root-entrypoint.stdout" 2>"$_test_root/init-forged-root-entrypoint.stderr"; then
  cat "$_test_root/init-forged-root-entrypoint.stdout" >&2
  cat "$_test_root/init-forged-root-entrypoint.stderr" >&2
  exit 1
fi

# A successful project entrypoint cannot forge the loader handshake, module
# ledgers, or metadata-provider state to smuggle a false activation through.
_forged_state_entry_root="$_test_root/forged-state-entrypoint"
mkdir -p "$_forged_state_entry_root/entrypoints/fish"
printf '%s\n' 'function forged_state_entrypoint_helper; end; set -gx _sp_fish_loader_bootstrap_mode forged-mode; set -Ux _sp_fish_loader_bootstrap_seeds forged-seeds; set -gx _sp_fish_loader_bootstrap_status 0; set -gx _sp_fish_loaded_modules forged-modules; set -Ux _sp_fish_module_roots forged-roots; set -gx _sp_fish_metadata_provider forged-provider; set -gx _sp_fish_loader_owned_exports forged-loader-exports; set -Ux _sp_fish_loader_owned_sources forged-loader-sources; set -gx _sp_fish_legacy_owned_exports forged-legacy-exports; set -Ux _sp_fish_legacy_owned_sources forged-legacy-sources; set -gx VALISE_FISH_READY 1; return 0' >"$_forged_state_entry_root/entrypoints/fish/profile.fish"
_forged_state_entry_home="$_test_root/forged-state-entrypoint-home"
mkdir -p "$_forged_state_entry_home/.config/valise"
ln -s "$_forged_state_entry_root" "$_forged_state_entry_home/.config/valise/active"
HOME="$_forged_state_entry_home" XDG_CONFIG_HOME="$_forged_state_entry_home/.config" XDG_DATA_HOME="$_forged_state_entry_home/.local/share" XDG_STATE_HOME="$_forged_state_entry_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-forged-state-entrypoint.fish"
_forged_state_entry_program="$_test_root/init-forged-state-entrypoint.fish"
cat >"$_forged_state_entry_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT caller-forged-state-root
builtin source '$_test_root/valise-init-fish-forged-state-entrypoint.fish'
set -l _forged_state_entry_status \$status
builtin test \$_forged_state_entry_status -ne 0; or exit 1
builtin test "\$SHELL_PROJECT_ROOT" = caller-forged-state-root; or exit 1
functions -q forged_state_entrypoint_helper; and exit 1
for _forged_state_name in _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status _sp_fish_loaded_modules _sp_fish_module_roots _sp_fish_metadata_provider _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_legacy_owned_exports _sp_fish_legacy_owned_sources VALISE_FISH_READY
  builtin set -q -g \$_forged_state_name; and exit 1
  builtin set -q -U \$_forged_state_name; and exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_forged_state_entry_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_forged_state_entry_program" >"$_test_root/init-forged-state-entrypoint.stdout" 2>"$_test_root/init-forged-state-entrypoint.stderr"; then
  cat "$_test_root/init-forged-state-entrypoint.stdout" >&2
  cat "$_test_root/init-forged-state-entrypoint.stderr" >&2
  exit 1
fi

# A project entrypoint that replaces a caller-owned function cannot be restored
# without losing exact Fish provenance, so the integration fails closed before
# returning control to the caller.
_entrypoint_replace_root="$_test_root/entrypoint-replace"
mkdir -p "$_entrypoint_replace_root/entrypoints/fish"
printf '%s\n' 'function caller_owned_entrypoint; echo replaced-entrypoint; end; function leaked_entrypoint_helper; end; set -gx VALISE_FISH_READY 1; return 0' >"$_entrypoint_replace_root/entrypoints/fish/profile.fish"
_entrypoint_replace_home="$_test_root/entrypoint-replace-home"
mkdir -p "$_entrypoint_replace_home/.config/valise"
ln -s "$_entrypoint_replace_root" "$_entrypoint_replace_home/.config/valise/active"
HOME="$_entrypoint_replace_home" XDG_CONFIG_HOME="$_entrypoint_replace_home/.config" XDG_DATA_HOME="$_entrypoint_replace_home/.local/share" XDG_STATE_HOME="$_entrypoint_replace_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-replace.fish"
_entrypoint_replace_program="$_test_root/init-entrypoint-replace.fish"
cat >"$_entrypoint_replace_program" <<EOF
function caller_owned_entrypoint
  echo caller-entrypoint
end
builtin set -gx SHELL_PROJECT_ROOT caller-entrypoint-root
builtin source '$_test_root/valise-init-fish-entrypoint-replace.fish'
set -l _entrypoint_replace_status \$status
builtin test \$_entrypoint_replace_status -eq 125; or exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_entrypoint_replace_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_entrypoint_replace_program" >"$_test_root/init-entrypoint-replace.stdout" 2>"$_test_root/init-entrypoint-replace.stderr"; then
  cat "$_test_root/init-entrypoint-replace.stdout" >&2
  cat "$_test_root/init-entrypoint-replace.stderr" >&2
  exit 1
fi

# A project entrypoint that declares critical functions, including the
# embedded `cd`, is rejected before sourcing. The embedded original remains
# intact and neither critical shadow nor helper leaks into the caller.
_entrypoint_critical_root="$_test_root/entrypoint-critical"
mkdir -p "$_entrypoint_critical_root/entrypoints/fish"
printf '%s\n' 'function contains; set -g entrypoint_contains_leaked 1; end; function cd; set -g entrypoint_cd_leaked 1; end; function entrypoint_critical_helper; end; set -g VALISE_FISH_READY 1; return 0' >"$_entrypoint_critical_root/entrypoints/fish/profile.fish"
_entrypoint_critical_home="$_test_root/entrypoint-critical-home"
mkdir -p "$_entrypoint_critical_home/.config/valise"
ln -s "$_entrypoint_critical_root" "$_entrypoint_critical_home/.config/valise/active"
HOME="$_entrypoint_critical_home" XDG_CONFIG_HOME="$_entrypoint_critical_home/.config" XDG_DATA_HOME="$_entrypoint_critical_home/.local/state" XDG_STATE_HOME="$_entrypoint_critical_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-critical.fish"
_entrypoint_critical_program="$_test_root/init-entrypoint-critical.fish"
cat >"$_entrypoint_critical_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT caller-entrypoint-critical-root
builtin source '$_test_root/valise-init-fish-entrypoint-critical.fish'
EOF
_entrypoint_critical_status=0
/usr/bin/env -i HOME="$_entrypoint_critical_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_entrypoint_critical_program" >"$_test_root/init-entrypoint-critical.stdout" 2>"$_test_root/init-entrypoint-critical.stderr" || _entrypoint_critical_status=$?
if [ "$_entrypoint_critical_status" -ne 125 ]; then
  cat "$_test_root/init-entrypoint-critical.stdout" >&2
  cat "$_test_root/init-entrypoint-critical.stderr" >&2
  printf 'FAIL: static critical entrypoint status was %s, expected 125\n' "$_entrypoint_critical_status" >&2
  exit 1
fi
# Dynamic namespace mutation bypasses lexical preflight in a generated
# entrypoint. The post-source integrity check must kill the child rather than
# attempting to restore embedded Fish provenance in-process.
_entrypoint_indirect_root="$_test_root/entrypoint-indirect-critical"
mkdir -p "$_entrypoint_indirect_root/entrypoints/fish"
cat >"$_entrypoint_indirect_root/entrypoints/fish/profile.fish" <<'EOF'
function indirect_cd_replacer
    set -l _function_command (string join "" func tions)
    set -l _erase_word (string join "" era se)
    set -l _erase_option --$_erase_word
    set -l _critical_name (string join "" c d)
    $_function_command $_erase_option $_critical_name
    function $_critical_name
        builtin printf '%s\n' attacker > "$ENTRYPOINT_DYNAMIC_MARKER"
    end
end
indirect_cd_replacer
set -gx VALISE_FISH_READY 1
return 0
EOF
_entrypoint_indirect_home="$_test_root/entrypoint-indirect-critical-home"
mkdir -p "$_entrypoint_indirect_home/.config/valise"
ln -s "$_entrypoint_indirect_root" "$_entrypoint_indirect_home/.config/valise/active"
HOME="$_entrypoint_indirect_home" XDG_CONFIG_HOME="$_entrypoint_indirect_home/.config" XDG_DATA_HOME="$_entrypoint_indirect_home/.local/share" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-indirect.fish"
_entrypoint_indirect_program="$_test_root/init-entrypoint-indirect.fish"
cat >"$_entrypoint_indirect_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT caller-entrypoint-indirect-root
builtin source '$_test_root/valise-init-fish-entrypoint-indirect.fish'
EOF
_entrypoint_indirect_marker="$_test_root/entrypoint-indirect-marker"
if /usr/bin/env -i HOME="$_entrypoint_indirect_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" ENTRYPOINT_DYNAMIC_MARKER="$_entrypoint_indirect_marker" "$_fish" "$_entrypoint_indirect_program" >"$_test_root/init-entrypoint-indirect.stdout" 2>"$_test_root/init-entrypoint-indirect.stderr"; then
  printf '%s\n' 'FAIL: generated dynamic embedded replacement did not terminate Fish with status 125' >&2
  exit 1
else
  _entrypoint_indirect_status=$?
  if [ "$_entrypoint_indirect_status" -ne 125 ]; then
    cat "$_test_root/init-entrypoint-indirect.stdout" >&2
    cat "$_test_root/init-entrypoint-indirect.stderr" >&2
    printf 'FAIL: generated dynamic embedded replacement status was %s, expected 125\n' "$_entrypoint_indirect_status" >&2
    exit 1
  fi
fi
if [ -e "$_entrypoint_indirect_marker" ]; then
  printf '%s\n' 'FAIL: generated dynamic replacement marker was created before fail-closed exit' >&2
  exit 1
fi

# A failing project entrypoint must remove new functions even when it does not
# collide with a caller function, and must restore the caller-owned root.
_entrypoint_fail_root="$_test_root/entrypoint-fail"
mkdir -p "$_entrypoint_fail_root/entrypoints/fish"
printf '%s\n' 'function failed_entrypoint_helper; end; return 23' >"$_entrypoint_fail_root/entrypoints/fish/profile.fish"
_entrypoint_fail_home="$_test_root/entrypoint-fail-home"
mkdir -p "$_entrypoint_fail_home/.config/valise"
ln -s "$_entrypoint_fail_root" "$_entrypoint_fail_home/.config/valise/active"
HOME="$_entrypoint_fail_home" XDG_CONFIG_HOME="$_entrypoint_fail_home/.config" XDG_DATA_HOME="$_entrypoint_fail_home/.local/share" XDG_STATE_HOME="$_entrypoint_fail_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-entrypoint-fail.fish"
_entrypoint_fail_program="$_test_root/init-entrypoint-fail.fish"
cat >"$_entrypoint_fail_program" <<EOF
builtin set -gx SHELL_PROJECT_ROOT caller-failing-entrypoint-root
builtin source '$_test_root/valise-init-fish-entrypoint-fail.fish'
set -l _entrypoint_fail_status \$status
builtin test \$_entrypoint_fail_status -eq 23; or exit 1
functions -q failed_entrypoint_helper; and exit 1
builtin test "\$SHELL_PROJECT_ROOT" = caller-failing-entrypoint-root; or exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
  exit 1
end
exit 0
EOF
if ! /usr/bin/env -i HOME="$_entrypoint_fail_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_entrypoint_fail_program" >"$_test_root/init-entrypoint-fail.stdout" 2>"$_test_root/init-entrypoint-fail.stderr"; then
  cat "$_test_root/init-entrypoint-fail.stdout" >&2
  cat "$_test_root/init-entrypoint-fail.stderr" >&2
  exit 1
fi

# An existing project entrypoint is accepted only when it publishes the same
# readiness contract; a zero-status no-op entrypoint must fail closed.
_bad_entry_root="$_test_root/bad-entrypoint"
mkdir -p "$_bad_entry_root/entrypoints/fish"
printf '%s\n' 'function invalid_readiness_helper; end; set -gx VALISE_FISH_READY 0; return 0' > "$_bad_entry_root/entrypoints/fish/profile.fish"
_bad_entry_home="$_test_root/bad-entry-home"
mkdir -p "$_bad_entry_home/.config/valise"
ln -s "$_bad_entry_root" "$_bad_entry_home/.config/valise/active"
HOME="$_bad_entry_home" XDG_CONFIG_HOME="$_bad_entry_home/.config" XDG_DATA_HOME="$_bad_entry_home/.local/share" XDG_STATE_HOME="$_bad_entry_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-bad-entrypoint.fish"
_bad_entry_program="$_test_root/init-bad-entrypoint.fish"
cat >"$_bad_entry_program" <<EOF
builtin source '$_test_root/valise-init-fish-bad-entrypoint.fish'
set -l _bad_entry_status \$status
builtin test \$_bad_entry_status -ne 0; or exit 1
builtin set -q VALISE_FISH_READY; and exit 1
functions -q invalid_readiness_helper; and exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_bad_entry_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_bad_entry_program" >"$_test_root/init-bad-entrypoint.stdout" 2>"$_test_root/init-bad-entrypoint.stderr"; then
  cat "$_test_root/init-bad-entrypoint.stdout" >&2
  cat "$_test_root/init-bad-entrypoint.stderr" >&2
  exit 1
fi

# A valid release switch may replace functions owned by the previous trusted
# metadata source, while an unrelated caller-owned function remains protected.
_switch_a="$_test_root/metadata-switch-a"
_switch_b="$_test_root/metadata-switch-b"
for _switch_root in "$_switch_a" "$_switch_b"; do
  mkdir -p "$_switch_root/vendor/shell-profile/lib/fish" "$_switch_root/module.d" "$_switch_root/modules/fish/public"
  cp "$_engine/lib/fish/loader.fish" "$_switch_root/vendor/shell-profile/lib/fish/loader.fish"
  cp "$_public_root/module.d/"* "$_switch_root/module.d/"
  cp "$_public_root/modules/fish/public/"* "$_switch_root/modules/fish/public/"
done
sed 's/metadata: /metadata-a: /' "$_engine/lib/fish/metadata.fish" >"$_switch_a/vendor/shell-profile/lib/fish/metadata.fish"
sed 's/metadata: /metadata-b: /' "$_engine/lib/fish/metadata.fish" >"$_switch_b/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' 'function metadata_release_a_only; end' >>"$_switch_a/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' 'function metadata_release_b_only; end' >>"$_switch_b/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' "for _metadata_backup_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_(entrypoint|metadata)_backup_'); function \$_metadata_backup_helper; return 0; end; end; true" >>"$_switch_b/vendor/shell-profile/lib/fish/metadata.fish"
_switch_home="$_test_root/metadata-switch-a-home"
mkdir -p "$_switch_home/.config/valise"
ln -s "$_switch_a" "$_switch_home/.config/valise/active"
HOME="$_switch_home" XDG_CONFIG_HOME="$_switch_home/.config" XDG_DATA_HOME="$_switch_home/.local/share" XDG_STATE_HOME="$_switch_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-switch-a.fish"
_switch_home="$_test_root/metadata-switch-b-home"
mkdir -p "$_switch_home/.config/valise"
ln -s "$_switch_b" "$_switch_home/.config/valise/active"
HOME="$_switch_home" XDG_CONFIG_HOME="$_switch_home/.config" XDG_DATA_HOME="$_switch_home/.local/share" XDG_STATE_HOME="$_switch_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-switch-b.fish"
_switch_program="$_test_root/metadata-switch.fish"
cat >"$_switch_program" <<EOF
function caller_owned_metadata_switch
    echo caller-metadata-switch
end
builtin source '$_test_root/valise-init-fish-metadata-switch-a.fish'
or exit 1
test (caller_owned_metadata_switch) = caller-metadata-switch; or exit 1
builtin source '$_test_root/valise-init-fish-metadata-switch-b.fish'
or exit 1
test (caller_owned_metadata_switch) = caller-metadata-switch; or exit 1
functions -q metadata_release_a_only; and exit 1
functions -q metadata_release_b_only; or exit 1
for _metadata_backup_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_(entrypoint|metadata)_backup_')
  exit 1
end
builtin string match -q "*$_switch_b/vendor/shell-profile/lib/fish/metadata.fish" -- (builtin functions --details sp_fish_metadata_error)
exit 0
EOF
if ! /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_switch_program" >"$_test_root/metadata-switch.stdout" 2>"$_test_root/metadata-switch.stderr"; then
  cat "$_test_root/metadata-switch.stdout" >&2
  cat "$_test_root/metadata-switch.stderr" >&2
  exit 1
fi

# Metadata ownership is transactional across a native-loader failure. A
# helper claimed by metadata must be removed when the downstream body fails,
# while an unrelated caller-owned function remains untouched.
_metadata_downstream_root="$_test_root/metadata-downstream-failure"
mkdir -p "$_metadata_downstream_root/vendor/shell-profile/lib/fish" "$_metadata_downstream_root/module.d" "$_metadata_downstream_root/modules/fish/public"
cp "$_engine/lib/fish/loader.fish" "$_metadata_downstream_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_engine/lib/fish/metadata.fish" "$_metadata_downstream_root/vendor/shell-profile/lib/fish/metadata.fish"
cp "$_public_root/module.d/"* "$_metadata_downstream_root/module.d/"
cp "$_public_root/modules/fish/public/"* "$_metadata_downstream_root/modules/fish/public/"
printf '%s\n' 'function metadata_downstream_owned; end' >>"$_metadata_downstream_root/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' 'function downstream_created_before_failure; end; return 29' >"$_metadata_downstream_root/modules/fish/public/fish_path.fish"
_metadata_downstream_home="$_test_root/metadata-downstream-failure-home"
mkdir -p "$_metadata_downstream_home/.config/valise"
ln -s "$_metadata_downstream_root" "$_metadata_downstream_home/.config/valise/active"
HOME="$_metadata_downstream_home" XDG_CONFIG_HOME="$_metadata_downstream_home/.config" XDG_DATA_HOME="$_metadata_downstream_home/.local/share" XDG_STATE_HOME="$_metadata_downstream_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-downstream.fish"
_metadata_downstream_program="$_test_root/metadata-downstream-failure.fish"
cat >"$_metadata_downstream_program" <<EOF
function caller_owned_metadata_downstream
    echo caller-metadata-downstream
end
builtin source '$_test_root/valise-init-fish-metadata-downstream.fish'
set -l _metadata_downstream_status \$status
builtin test \$_metadata_downstream_status -ne 0; or exit 1
functions -q metadata_downstream_owned; and exit 1
functions -q downstream_created_before_failure; and exit 1
test (caller_owned_metadata_downstream) = caller-metadata-downstream; or exit 1
builtin set -q _sp_fish_metadata_owned_exports; and test (builtin count \$_sp_fish_metadata_owned_exports) -ne 0; and exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_metadata_downstream_program" >"$_test_root/metadata-downstream.stdout" 2>"$_test_root/metadata-downstream.stderr"; then
  cat "$_test_root/metadata-downstream.stdout" >&2
  cat "$_test_root/metadata-downstream.stderr" >&2
  exit 1
fi

# A metadata-defined `cd` shadow is rejected before the embedded Fish
# function can be replaced. Switching immediately to a clean release proves
# that the failed transaction did not poison subsequent activation.
_metadata_cd_bad_root="$_test_root/metadata-cd-bad"
_metadata_cd_clean_root="$_test_root/metadata-cd-clean"
for _metadata_cd_root in "$_metadata_cd_bad_root" "$_metadata_cd_clean_root"; do
  mkdir -p "$_metadata_cd_root/vendor/shell-profile/lib/fish" "$_metadata_cd_root/module.d" "$_metadata_cd_root/modules/fish/public"
  cp "$_engine/lib/fish/loader.fish" "$_metadata_cd_root/vendor/shell-profile/lib/fish/loader.fish"
  cp "$_engine/lib/fish/metadata.fish" "$_metadata_cd_root/vendor/shell-profile/lib/fish/metadata.fish"
  cp "$_public_root/module.d/"* "$_metadata_cd_root/module.d/"
  cp "$_public_root/modules/fish/public/"* "$_metadata_cd_root/modules/fish/public/"
done
printf '%s\n' 'function cd; set -g metadata_cd_shadow_leaked 1; end' >>"$_metadata_cd_bad_root/vendor/shell-profile/lib/fish/metadata.fish"
_metadata_cd_home="$_test_root/metadata-cd-bad-home"
mkdir -p "$_metadata_cd_home/.config/valise"
ln -s "$_metadata_cd_bad_root" "$_metadata_cd_home/.config/valise/active"
HOME="$_metadata_cd_home" XDG_CONFIG_HOME="$_metadata_cd_home/.config" XDG_DATA_HOME="$_metadata_cd_home/.local/share" XDG_STATE_HOME="$_metadata_cd_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-cd-bad.fish"
_metadata_cd_home="$_test_root/metadata-cd-clean-home"
mkdir -p "$_metadata_cd_home/.config/valise"
ln -s "$_metadata_cd_clean_root" "$_metadata_cd_home/.config/valise/active"
HOME="$_metadata_cd_home" XDG_CONFIG_HOME="$_metadata_cd_home/.config" XDG_DATA_HOME="$_metadata_cd_home/.local/share" XDG_STATE_HOME="$_metadata_cd_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-cd-clean.fish"
_metadata_cd_program="$_test_root/metadata-cd.fish"
cat >"$_metadata_cd_program" <<EOF
builtin source '$_test_root/valise-init-fish-metadata-cd-bad.fish'
EOF
_metadata_cd_bad_status=0
/usr/bin/env -i HOME="$_metadata_cd_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_metadata_cd_program" >"$_test_root/metadata-cd-bad.stdout" 2>"$_test_root/metadata-cd-bad.stderr" || _metadata_cd_bad_status=$?
if [ "$_metadata_cd_bad_status" -ne 125 ]; then
  cat "$_test_root/metadata-cd-bad.stdout" >&2
  cat "$_test_root/metadata-cd-bad.stderr" >&2
  printf 'FAIL: metadata critical cd status was %s, expected 125\n' "$_metadata_cd_bad_status" >&2
  exit 1
fi
_metadata_cd_clean_program="$_test_root/metadata-cd-clean.fish"
cat >"$_metadata_cd_clean_program" <<EOF
builtin source '$_test_root/valise-init-fish-metadata-cd-clean.fish'
or exit 1
functions -q cd; or exit 1
builtin test (builtin functions --details cd) = embedded:functions/cd.fish; or exit 1
exit 0
EOF
if ! /usr/bin/env -i HOME="$_metadata_cd_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_metadata_cd_clean_program" >"$_test_root/metadata-cd-clean.stdout" 2>"$_test_root/metadata-cd-clean.stderr"; then
  cat "$_test_root/metadata-cd-clean.stdout" >&2
  cat "$_test_root/metadata-cd-clean.stderr" >&2
  exit 1
fi

# Metadata cannot use a visible backup helper to restore an indirectly
# replaced embedded critical function. Namespace mutation is rejected before
# source, and the historical backup namespace is absent.
_metadata_indirect_root="$_test_root/metadata-indirect-critical"
mkdir -p "$_metadata_indirect_root/vendor/shell-profile/lib/fish" "$_metadata_indirect_root/module.d" "$_metadata_indirect_root/modules/fish/public"
cp "$_engine/lib/fish/loader.fish" "$_metadata_indirect_root/vendor/shell-profile/lib/fish/loader.fish"
cp "$_public_root/module.d/"* "$_metadata_indirect_root/module.d/"
cp "$_public_root/modules/fish/public/"* "$_metadata_indirect_root/modules/fish/public/"
cp "$_engine/lib/fish/metadata.fish" "$_metadata_indirect_root/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' 'function indirect_metadata_cd_replacer; set -l _critical_name cd; builtin functions --erase $_critical_name; function $_critical_name; set -g indirect_metadata_cd_leaked 1; end; end; indirect_metadata_cd_replacer' >>"$_metadata_indirect_root/vendor/shell-profile/lib/fish/metadata.fish"
_metadata_indirect_home="$_test_root/metadata-indirect-critical-home"
mkdir -p "$_metadata_indirect_home/.config/valise"
ln -s "$_metadata_indirect_root" "$_metadata_indirect_home/.config/valise/active"
HOME="$_metadata_indirect_home" XDG_CONFIG_HOME="$_metadata_indirect_home/.config" XDG_DATA_HOME="$_metadata_indirect_home/.local/share" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-metadata-indirect.fish"
_metadata_indirect_program="$_test_root/metadata-indirect.fish"
cat >"$_metadata_indirect_program" <<EOF
builtin source '$_test_root/valise-init-fish-metadata-indirect.fish'
EOF
_metadata_indirect_status=0
/usr/bin/env -i HOME="$_metadata_indirect_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_metadata_indirect_program" >"$_test_root/metadata-indirect.stdout" 2>"$_test_root/metadata-indirect.stderr" || _metadata_indirect_status=$?
if [ "$_metadata_indirect_status" -ne 125 ]; then
  cat "$_test_root/metadata-indirect.stdout" >&2
  cat "$_test_root/metadata-indirect.stderr" >&2
  printf 'FAIL: metadata indirect critical status was %s, expected 125\n' "$_metadata_indirect_status" >&2
  exit 1
fi

# A caller function sourced from an attacker path ending in the historical
# metadata suffix is still caller-owned. The generated metadata transaction
# must reject the active metadata replacement without trusting the suffix or
# attempting provenance-losing restoration.
_metadata_suffix_attack_dir="$_test_root/metadata-suffix-attack/vendor/shell-profile/lib/fish"
mkdir -p "$_metadata_suffix_attack_dir"
_metadata_suffix_attack_file="$_metadata_suffix_attack_dir/metadata.fish"
printf '%s\n' 'function sp_fish_metadata_error; echo attacker-metadata-error; end' >"$_metadata_suffix_attack_file"
_metadata_suffix_attack_program="$_test_root/metadata-suffix-attack.fish"
cat >"$_metadata_suffix_attack_program" <<EOF
builtin source '$_metadata_suffix_attack_file'
builtin string match -q "*vendor/shell-profile/lib/fish/metadata.fish" -- (builtin functions --details sp_fish_metadata_error); or exit 1
builtin source '$_test_root/valise-init-fish.fish'
EOF
_metadata_suffix_attack_status=0
/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" "$_fish" "$_metadata_suffix_attack_program" >"$_test_root/metadata-suffix-attack.stdout" 2>"$_test_root/metadata-suffix-attack.stderr" || _metadata_suffix_attack_status=$?
if [ "$_metadata_suffix_attack_status" -ne 125 ]; then
  cat "$_test_root/metadata-suffix-attack.stdout" >&2
  cat "$_test_root/metadata-suffix-attack.stderr" >&2
  printf 'FAIL: metadata suffix caller replacement status was %s, expected 125\n' "$_metadata_suffix_attack_status" >&2
  exit 1
fi

# Fish --copy changes the restored function's provenance to the loader source.
# Caller-owned replacements therefore terminate the child with the fail-closed
# status instead of returning with a poisoned caller function.
for _caller_fixture in caller_collision local_snapshot_attack private_collision; do
  _caller_program="$_test_root/native-${_caller_fixture}.fish"
  cat >"$_caller_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
builtin set -gx SHELL_PROJECT_ROOT '$_fixture'
builtin set -g _sp_fish_loader_bootstrap_mode strict
builtin set -g _sp_fish_loader_bootstrap_seeds $_caller_fixture
if test '$_caller_fixture' = caller_collision
  function caller_owned_collision
    echo caller
  end
else if test '$_caller_fixture' = local_snapshot_attack
  function caller_owned_snapshot
    echo caller-snapshot
  end
else
  function _caller_owned_private
    echo caller-private
  end
end
builtin source '$_engine/lib/fish/loader.fish'
EOF
  _caller_status=0
  /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_caller_program" >"$_test_root/native-$_caller_fixture.stdout" 2>"$_test_root/native-$_caller_fixture.stderr" || _caller_status=$?
  if [ "$_caller_status" -ne 125 ]; then
    cat "$_test_root/native-$_caller_fixture.stdout" >&2
    cat "$_test_root/native-$_caller_fixture.stderr" >&2
    printf 'FAIL: native %s caller replacement status was %s, expected 125\n' "$_caller_fixture" "$_caller_status" >&2
    exit 1
  fi
done

# Poison only the in-process adapter case; the fresh emitted-init success case
# above must exercise a clean release independently.
_body "$_public_root/modules/fish/public/fish_path.fish" 'set -gx VALISE_FISH_READY 1; set -U VALISE_FISH_READY 1; set -U SHELL_PROJECT_ROOT poisoned-universal; function contains; return 0; end; set -g public_fish_path_loaded 1; function public_fish_path_loaded; end'

# Prepare a second installed-style root with a disjoint export. Re-sourcing the
# adapter after switching roots must remove exports owned by the old root.
_public_second_root="$_test_root/public-second"
mkdir -p "$_public_second_root/vendor/shell-profile/lib/fish" "$_public_second_root/module.d" "$_public_second_root/modules/fish/public"
cp "$_engine/lib/fish/metadata.fish" "$_public_second_root/vendor/shell-profile/lib/fish/metadata.fish"
cp "$_engine/lib/fish/loader.fish" "$_public_second_root/vendor/shell-profile/lib/fish/loader.fish"
_meta "$_public_second_root/module.d/fish_path.meta" fish_path fish any read-only second_fish_path_loaded modules/fish/public/fish_path.fish
_body "$_public_second_root/modules/fish/public/fish_path.fish" 'set -g second_fish_path_loaded 1; function second_fish_path_loaded; end'
_meta "$_public_second_root/module.d/fish_environment.meta" fish_environment fish any read-only second_fish_environment_loaded modules/fish/public/fish_environment.fish fish_path
_body "$_public_second_root/modules/fish/public/fish_environment.fish" 'function second_fish_environment_loaded; end'
_meta "$_public_second_root/module.d/fish_secure_local_bin.meta" fish_secure_local_bin fish any read-only second_fish_secure_loaded modules/fish/public/fish_secure_local_bin.fish fish_path
_body "$_public_second_root/modules/fish/public/fish_secure_local_bin.fish" 'function second_fish_secure_loaded; end'

# The public native route has the same provenance boundary as direct loading:
# an entrypoint/module replacement of a caller function must terminate rather
# than return with a Fish --copy provenance mismatch.
_body "$_public_root/modules/fish/public/fish_path.fish" 'function caller_owned_public; echo replaced-public; end; set -g public_fish_path_loaded 1; function public_fish_path_loaded; end'
_public_caller_program="$_test_root/public-caller-replacement.fish"
cat >"$_public_caller_program" <<EOF
function caller_owned_public
  echo caller-public
end
builtin set -gx SHELL_PROJECT_ROOT '$_public_root'
builtin source '$_project_adapter'
EOF
_public_caller_status=0
/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_public_caller_program" >"$_test_root/public-caller-replacement.stdout" 2>"$_test_root/public-caller-replacement.stderr" || _public_caller_status=$?
if [ "$_public_caller_status" -ne 125 ]; then
  cat "$_test_root/public-caller-replacement.stdout" >&2
  cat "$_test_root/public-caller-replacement.stderr" >&2
  printf 'FAIL: public caller replacement status was %s, expected 125\n' "$_public_caller_status" >&2
  exit 1
fi
_body "$_public_root/modules/fish/public/fish_path.fish" 'set -gx VALISE_FISH_READY 1; set -U VALISE_FISH_READY 1; set -U SHELL_PROJECT_ROOT poisoned-universal; function contains; return 0; end; set -g public_fish_path_loaded 1; function public_fish_path_loaded; end'

# A prior installed release has the old loader ABI and a generated plan but no
# source-driven handshake. The compatibility branch must activate that sealed
# plan only for the legacy loader identity.
_legacy_root="$_test_root/legacy"
mkdir -p "$_legacy_root/vendor/shell-profile/lib/fish" "$_legacy_root/generated"
cp "$_engine/lib/fish/metadata.fish" "$_legacy_root/vendor/shell-profile/lib/fish/metadata.fish"
printf '%s\n' 'function sp_fish_loader_load_ordered; end' > "$_legacy_root/vendor/shell-profile/lib/fish/loader.fish"
printf '%s\n' 'if test -z "$VALISE_MODULE_ROOT"; return 7; end; set -U _sp_fish_loader_bootstrap_status 77; set -U _sp_fish_loader_bootstrap_mode poisoned; set -U _sp_fish_loader_bootstrap_seeds poisoned; set -U SHELL_PROJECT_ROOT poisoned-universal; set -U VALISE_FISH_READY 99; set -g _sp_fish_loader_bootstrap_status 77; set -g _sp_fish_loader_bootstrap_mode poisoned; set -g _sp_fish_loader_bootstrap_seeds poisoned; set -gx SHELL_PROJECT_ROOT poisoned; set -g legacy_plan_sourced 1; function legacy_plan_loaded; end' > "$_legacy_root/generated/installed-modules.fish"
_legacy_home="$_test_root/legacy-home"
mkdir -p "$_legacy_home/.config/valise"
ln -s "$_legacy_root" "$_legacy_home/.config/valise/active"
HOME="$_legacy_home" XDG_CONFIG_HOME="$_legacy_home/.config" XDG_DATA_HOME="$_legacy_home/.local/share" XDG_STATE_HOME="$_legacy_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-legacy.fish"
_legacy_program="$_test_root/init-legacy.fish"
cat >"$_legacy_program" <<EOF
builtin set -gx VALISE_MODULE_ROOT caller-module-global
builtin set -Ux VALISE_MODULE_ROOT caller-module-universal
builtin source '$_test_root/valise-init-fish-legacy.fish'
set -l _legacy_status \$status
builtin test \$_legacy_status -eq 0; or exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
    exit 1
end
builtin set -q legacy_plan_sourced; or exit 1
builtin set -q VALISE_FISH_READY; or exit 1
builtin test \$VALISE_FISH_READY = 1; or exit 1
builtin set -q _sp_fish_loader_bootstrap_status; and exit 1
builtin set -q _sp_fish_loader_bootstrap_mode; and exit 1
builtin set -q _sp_fish_loader_bootstrap_seeds; and exit 1
set -l _legacy_expected_root (builtin path resolve -- '$_legacy_root')
builtin test "\$SHELL_PROJECT_ROOT" = "\$_legacy_expected_root"; or exit 1
for _legacy_state in _sp_fish_loader_bootstrap_status _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds VALISE_FISH_READY SHELL_PROJECT_ROOT
    builtin set -q -U \$_legacy_state; and exit 1
end
builtin set -q -g VALISE_MODULE_ROOT; or exit 1
builtin test "\$VALISE_MODULE_ROOT" = caller-module-global; or exit 1
builtin set -q -gx VALISE_MODULE_ROOT; or exit 1
builtin set -q -U VALISE_MODULE_ROOT; or exit 1
builtin set -q -Ux VALISE_MODULE_ROOT; or exit 1
builtin set -e -g VALISE_MODULE_ROOT
builtin set -e -U VALISE_MODULE_ROOT
exit 0
EOF
if ! /usr/bin/env -i HOME="$_legacy_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_legacy_program" >"$_test_root/init-legacy.stdout" 2>"$_test_root/init-legacy.stderr"; then
  cat "$_test_root/init-legacy.stdout" >&2
  cat "$_test_root/init-legacy.stderr" >&2
  exit 1
fi

# A release containing only the historical generated plan (no native Fish
# infrastructure) must remain activatable through the compatibility branch.
_legacy_minimal_root="$_test_root/legacy-minimal"
mkdir -p "$_legacy_minimal_root/generated" "$_legacy_minimal_root/modules/fish"
printf '%s\n' 'if test -z "$VALISE_MODULE_ROOT"; return 7; end; set -U _sp_fish_loader_bootstrap_status 77; set -U _sp_fish_loader_bootstrap_mode poisoned; set -U _sp_fish_loader_bootstrap_seeds poisoned; set -U SHELL_PROJECT_ROOT poisoned-universal; set -U VALISE_FISH_READY 99; set -g _sp_fish_loader_bootstrap_status 77; set -g _sp_fish_loader_bootstrap_mode poisoned; set -g _sp_fish_loader_bootstrap_seeds poisoned; set -gx SHELL_PROJECT_ROOT poisoned; set -g legacy_minimal_plan_sourced 1; function legacy_minimal_plan_loaded; end' >"$_legacy_minimal_root/generated/installed-modules.fish"
_legacy_minimal_home="$_test_root/legacy-minimal-home"
mkdir -p "$_legacy_minimal_home/.config/valise"
ln -s "$_legacy_minimal_root" "$_legacy_minimal_home/.config/valise/active"
HOME="$_legacy_minimal_home" XDG_CONFIG_HOME="$_legacy_minimal_home/.config" XDG_DATA_HOME="$_legacy_minimal_home/.local/share" XDG_STATE_HOME="$_legacy_minimal_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-legacy-minimal.fish"
_legacy_minimal_program="$_test_root/init-legacy-minimal.fish"
cat >"$_legacy_minimal_program" <<EOF
builtin set -gx VALISE_MODULE_ROOT minimal-module-global
builtin set -Ux VALISE_MODULE_ROOT minimal-module-universal
builtin source '$_test_root/valise-init-fish-legacy-minimal.fish'
set -l _legacy_minimal_status \$status
builtin test \$_legacy_minimal_status -eq 0; or exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
    exit 1
end
builtin set -q legacy_minimal_plan_sourced; or exit 1
builtin set -q VALISE_FISH_READY; or exit 1
builtin test \$VALISE_FISH_READY = 1; or exit 1
builtin set -q _sp_fish_loader_bootstrap_status; and exit 1
builtin set -q _sp_fish_loader_bootstrap_mode; and exit 1
builtin set -q _sp_fish_loader_bootstrap_seeds; and exit 1
set -l _legacy_minimal_expected_root (builtin path resolve -- '$_legacy_minimal_root')
builtin test "\$SHELL_PROJECT_ROOT" = "\$_legacy_minimal_expected_root"; or exit 1
for _legacy_state in _sp_fish_loader_bootstrap_status _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds VALISE_FISH_READY SHELL_PROJECT_ROOT
    builtin set -q -U \$_legacy_state; and exit 1
end
builtin set -q -g VALISE_MODULE_ROOT; or exit 1
builtin test "\$VALISE_MODULE_ROOT" = minimal-module-global; or exit 1
builtin set -q -gx VALISE_MODULE_ROOT; or exit 1
builtin set -q -U VALISE_MODULE_ROOT; or exit 1
builtin set -q -Ux VALISE_MODULE_ROOT; or exit 1
builtin set -e -g VALISE_MODULE_ROOT
builtin set -e -U VALISE_MODULE_ROOT
exit 0
EOF
if ! /usr/bin/env -i HOME="$_legacy_minimal_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_legacy_minimal_program" >"$_test_root/init-legacy-minimal.stdout" 2>"$_test_root/init-legacy-minimal.stderr"; then
  cat "$_test_root/init-legacy-minimal.stdout" >&2
  cat "$_test_root/init-legacy-minimal.stderr" >&2
  exit 1
fi

# A failed legacy activation must remove functions created by the plan and
# must not publish the failed root or readiness marker. The plan also attempts
# to replace the runner's snapshot list and source an attacker-controlled
# function; the plan is sourced in an isolated helper scope, so this must have
# no effect on trusted rollback metadata.
_legacy_failed_root="$_test_root/legacy-failed"
mkdir -p "$_legacy_failed_root/generated"
_legacy_failed_tmp="$_test_root/legacy-failed-tmp"
mkdir -p "$_legacy_failed_tmp"
_legacy_snapshot_attack="$_test_root/legacy-snapshot-attack.fish"
printf '%s\n' 'function legacy_snapshot_attack_loaded; end' >"$_legacy_snapshot_attack"
printf 'function legacy_failed_helper; end; function legacy_indirect_cd_attack; set -l _function_command (string join "" func tions); set -l _erase_word (string join "" era se); set -l _erase_option --$_erase_word; set -l _critical_name (string join "" c d); $_function_command $_erase_option $_critical_name; function $_critical_name; set -g legacy_cd_leaked 1; end; end; legacy_indirect_cd_attack; for _former_snapshot_dir in "$TMPDIR"/valise-fish-*; if test -d "$_former_snapshot_dir"; for _former_snapshot_file in "$_former_snapshot_dir"/*; test -f "$_former_snapshot_file"; and printf "poisoned\n" >"$_former_snapshot_file"; end; end; end; set -U SHELL_PROJECT_ROOT poisoned-universal; set -U VALISE_FISH_READY 99; set -g _valise_fish_root_global_set 1; set -g _valise_fish_root_global_exported 1; set -g _valise_fish_root_global_values forged-global-root; set -g _valise_fish_root_universal_set 1; set -g _valise_fish_root_universal_exported 0; set -g _valise_fish_root_universal_values forged-universal-root; set _legacy_snapshot_pairs %s; return 11\n' "$_legacy_snapshot_attack" >"$_legacy_failed_root/generated/installed-modules.fish"
_legacy_failed_home="$_test_root/legacy-failed-home"
mkdir -p "$_legacy_failed_home/.config/valise"
ln -s "$_legacy_failed_root" "$_legacy_failed_home/.config/valise/active"
HOME="$_legacy_failed_home" XDG_CONFIG_HOME="$_legacy_failed_home/.config" XDG_DATA_HOME="$_legacy_failed_home/.local/share" XDG_STATE_HOME="$_legacy_failed_home/.local/state" "$_engine/bin/valise" init fish --source-tree >"$_test_root/valise-init-fish-legacy-failed.fish"
_legacy_failed_program="$_test_root/init-legacy-failed.fish"
cat >"$_legacy_failed_program" <<EOF
builtin set -gx VALISE_FISH_READY 1
builtin set -gx VALISE_MODULE_ROOT failed-module-global
builtin set -Ux VALISE_MODULE_ROOT failed-module-universal
builtin source '$_test_root/valise-init-fish-legacy-failed.fish'
set -l _legacy_failed_status \$status
builtin test \$_legacy_failed_status -ne 0; or exit 1
for _legacy_helper in (builtin functions --all --names | builtin string match -r '^__valise_fish_legacy_(run|source)_')
    exit 1
end
functions -q legacy_failed_helper; and exit 1
functions -q legacy_indirect_cd_attack; and exit 1
functions -q legacy_snapshot_attack_loaded; and exit 1
builtin set -q legacy_cd_leaked; and exit 1
functions -q cd; or exit 1
cd "$_legacy_failed_home"; or exit 1
builtin test (builtin pwd) = "$_legacy_failed_home"; or exit 1
builtin set -q VALISE_FISH_READY; and exit 1
builtin set -q SHELL_PROJECT_ROOT; and exit 1
builtin set -q -U VALISE_FISH_READY; and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; and exit 1
for _former_snapshot_dir in "\$TMPDIR"/valise-fish-*
    test -d "\$_former_snapshot_dir"; and exit 1
end
builtin set -q -g VALISE_MODULE_ROOT; or exit 1
builtin test "\$VALISE_MODULE_ROOT" = failed-module-global; or exit 1
builtin set -q -gx VALISE_MODULE_ROOT; or exit 1
builtin set -q -U VALISE_MODULE_ROOT; or exit 1
builtin set -q -Ux VALISE_MODULE_ROOT; or exit 1
builtin set -e -g VALISE_MODULE_ROOT
builtin set -e -U VALISE_MODULE_ROOT
exit 0
EOF
_legacy_failed_status=0
/usr/bin/env -i HOME="$_legacy_failed_home" TMPDIR="$_legacy_failed_tmp" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_legacy_failed_program" >"$_test_root/init-legacy-failed.stdout" 2>"$_test_root/init-legacy-failed.stderr" || _legacy_failed_status=$?
if [ "$_legacy_failed_status" -eq 0 ]; then
  cat "$_test_root/init-legacy-failed.stdout" >&2
  cat "$_test_root/init-legacy-failed.stderr" >&2
  printf '%s\n' 'FAIL: legacy embedded critical mutation returned success' >&2
  exit 1
fi

# Dynamic namespace mutation in the native loader cannot restore an embedded
# Fish function with provenance. The child must terminate with the fail-closed
# status, and the replacement body must never run to create its marker.
_native_dynamic_marker="$_test_root/native-dynamic-marker"
_native_dynamic_program="$_test_root/native-dynamic.fish"
cat >"$_native_dynamic_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
set -g _sp_fish_loader_bootstrap_mode strict
set -g _sp_fish_loader_bootstrap_seeds indirect_cd
builtin source '$_engine/lib/fish/loader.fish'
EOF
if /usr/bin/env -i HOME="$_test_root/native-dynamic-home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin}" NATIVE_DYNAMIC_MARKER="$_native_dynamic_marker" "$_fish" "$_native_dynamic_program" >"$_test_root/native-dynamic.stdout" 2>"$_test_root/native-dynamic.stderr"; then
  printf '%s\n' 'FAIL: native dynamic embedded replacement did not terminate Fish with status 125' >&2
  exit 1
else
  _native_dynamic_status=$?
  if [ "$_native_dynamic_status" -ne 125 ]; then
    cat "$_test_root/native-dynamic.stdout" >&2
    cat "$_test_root/native-dynamic.stderr" >&2
    printf 'FAIL: native dynamic embedded replacement status was %s, expected 125\n' "$_native_dynamic_status" >&2
    exit 1
  fi
fi
if [ -e "$_native_dynamic_marker" ]; then
  printf '%s\n' 'FAIL: native dynamic replacement marker was created before fail-closed exit' >&2
  exit 1
fi

# Native rollback must reject a mutable XDG_CONFIG_HOME redirect instead of
# verifying a different empty store. The child makes the authenticated store
# unwritable after poisoning it, then the parent restores permissions.
_native_path_home="$_test_root/native-durable-path-home"
_native_path_program="$_test_root/native-durable-path.fish"
mkdir -p "$_native_path_home/.config/fish"
cat >"$_native_path_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
set -g _sp_fish_loader_bootstrap_mode strict
set -g _sp_fish_loader_bootstrap_seeds durable_path_attack
builtin source '$_engine/lib/fish/loader.fish'
EOF
_native_path_status=0
HOME="$_native_path_home" XDG_CONFIG_HOME="$_native_path_home/.config" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin}" \
  "$_fish" "$_native_path_program" >"$_test_root/native-durable-path.stdout" 2>"$_test_root/native-durable-path.stderr" || _native_path_status=$?
command chmod u+w "$_native_path_home/.config/fish"
if [ "$_native_path_status" -ne 125 ]; then
  cat "$_test_root/native-durable-path.stdout" >&2
  cat "$_test_root/native-durable-path.stderr" >&2
  printf 'FAIL: native mutable XDG_CONFIG_HOME rollback status was %s, expected 125\n' "$_native_path_status" >&2
  exit 1
fi

# Any reserved-function mutation is fail-closed and terminates the Fish
# process. Keep this hostile path in its own child so later clean activations
# cannot accidentally rely on in-process restoration of critical functions.
_hijack_program="$_test_root/hijack.fish"
cat >"$_hijack_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
set -g _sp_fish_loader_bootstrap_mode strict
set -g _sp_fish_loader_bootstrap_seeds hijack
builtin source '$_engine/lib/fish/loader.fish'
EOF
_hijack_status=0
/usr/bin/env -i HOME="$_test_root/hijack-home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_hijack_program" >"$_test_root/hijack.stdout" 2>"$_test_root/hijack.stderr" || _hijack_status=$?
if [ "$_hijack_status" -ne 125 ]; then
  cat "$_test_root/hijack.stdout" >&2
  cat "$_test_root/hijack.stderr" >&2
  printf 'FAIL: reserved-function hijack status was %s, expected 125\n' "$_hijack_status" >&2
  exit 1
fi

# Keep the suffix-authentication attack in a quarantined child: once a caller
# has replaced a loader helper, that process is intentionally fail-closed and
# must not be reused for a later activation.
_loader_suffix_attack_program="$_test_root/loader-suffix-attack.fish"
cat >"$_loader_suffix_attack_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
set -g _sp_fish_loader_bootstrap_mode strict
set -g _sp_fish_loader_bootstrap_seeds clean
builtin source '$_engine/lib/fish/loader.fish'
set -l _initial_status \$status
builtin test \$_initial_status -eq 0; or exit 1
builtin set -e _loader_suffix_source_count
builtin source '$_loader_suffix_attack_dir/loader.fish'
test "\$_loader_suffix_source_count" = 1; or exit 1
_sp_fish_loader_load_ordered_impl strict clean
set -l _loader_suffix_status \$status
printf '%s:%s\n' \$_loader_suffix_status \$_loader_suffix_source_count >"\$LOADER_SUFFIX_MARKER"
exit 0
EOF
_loader_suffix_marker="$_test_root/loader-suffix-attack.marker"
if ! /usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/usr/local/bin}" LOADER_SUFFIX_MARKER="$_loader_suffix_marker" "$_fish" "$_loader_suffix_attack_program" >"$_test_root/loader-suffix-attack.stdout" 2>"$_test_root/loader-suffix-attack.stderr"; then
  cat "$_test_root/loader-suffix-attack.stdout" >&2
  cat "$_test_root/loader-suffix-attack.stderr" >&2
  exit 1
fi
if [ "$(cat "$_loader_suffix_marker")" != 1:1 ]; then
  cat "$_test_root/loader-suffix-attack.stdout" >&2
  cat "$_test_root/loader-suffix-attack.stderr" >&2
  printf '%s\n' 'FAIL: loader suffix attack was not rejected without a second source' >&2
  exit 1
fi

fi
if [ "$_have_public_adapter" -eq 0 ]; then
  # The adapter-dependent part of the program below is guarded off; bind its
  # path variables so the unquoted heredoc can still expand.
  _missing_root="$_test_root/absent-public/missing"
  _public_root="$_test_root/absent-public/public"
  _public_second_root="$_test_root/absent-public/second"
fi

cat >"$_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'

function bootstrap
    set -g _sp_fish_loader_bootstrap_mode \$argv[1]
    set -g _sp_fish_loader_bootstrap_seeds \$argv[2..-1]
    builtin source '$_engine/lib/fish/loader.fish'
    set -l _rc \$_sp_fish_loader_bootstrap_status
    set -e _sp_fish_loader_bootstrap_status
    return \$_rc
end

# A caller can replace both historical names, but source-driven bootstrap
# removes them and executes freshly sourced private definitions.
function sp_fish_loader_load_ordered; return 0; end
function sp_fish_loader_dispatch; return 0; end
bootstrap strict clean
or exit 1
functions -q sp_fish_loader_load_ordered; and exit 1
functions -q sp_fish_loader_dispatch; and exit 1
functions -q clean_loaded; or exit 1

# Native provider precedence and generic-only discovery.
bootstrap strict precedence
or exit 1
test "\$precedence_provider" = native; or exit 1
functions -q precedence_native_loaded; or exit 1
bootstrap strict generic_only
or exit 1
test "\$generic_provider" = generic; or exit 1
functions -q generic_only_loaded; or exit 1
# Conflicting same-name providers fail closed before either body executes.
set -e conflict_sourced
bootstrap strict conflict
and exit 1
set -q conflict_sourced; and exit 1
set -e shell_skip_sourced
bootstrap strict gated_app
or exit 1
functions -q gated_app_loaded; or exit 1
set -q shell_skip_sourced; and exit 1
# POSIX local-state and dependency-only meta nodes are valid graph records.
bootstrap strict meta_dependent
or exit 1
functions -q meta_dependent_loaded; or exit 1

# Directly-requested non-Fish seeds follow the ABI mode contract, aligned
# with the POSIX loader's strict-required failure for shell-mismatched
# requested modules: strict fails closed before any body runs, permissive
# reports the module and continues with nothing loaded.
set -e posix_only_sourced
bootstrap strict posix_only_seed
and exit 1
set -q posix_only_sourced; and exit 1
functions -q posix_only_seed_loaded; and exit 1
bootstrap permissive posix_only_seed
or exit 1
set -q posix_only_sourced; and exit 1
functions -q posix_only_seed_loaded; and exit 1

# Optional-only cycle contract (native Fish surface): no optional-relaxed
# fallback pass exists here, so the stall is fatal to the requested seed in
# strict mode; permissive quarantines the cycle and continues with neither
# body sourced. The POSIX loader resolves the same graph through its
# fallback pass and loads both modules — the divergence is pinned on both
# surfaces by their respective suites.
set -e opt_cycle_a_sourced
set -e opt_cycle_b_sourced
bootstrap strict opt_cycle_a
and exit 1
set -q opt_cycle_a_sourced; and exit 1
set -q opt_cycle_b_sourced; and exit 1
bootstrap permissive opt_cycle_a
or exit 1
set -q opt_cycle_a_sourced; and exit 1
set -q opt_cycle_b_sourced; and exit 1

# Unsupported platform fails closed before body execution.
bootstrap permissive wrong_platform
or exit 1
test "\$wrong_platform_sourced" != 1; or exit 1

# Required runtime failure is not a satisfied dependency in permissive mode.
set -e runtime_dep_seen
bootstrap permissive runtime_app
or exit 1
set -q runtime_dep_seen; or exit 1
functions -q runtime_app_loaded; and exit 1

# Cycles fail in strict mode, while a later independent request still works.
bootstrap strict cycle_a
and exit 1
bootstrap strict independent
or exit 1

# Strict failures are transactional: an earlier successful module export and
# loader state must not survive a later required body failure.
bootstrap strict partial_b
and exit 1
functions -q partial_a_loaded; and exit 1
functions -q partial_b_loaded; and exit 1
functions -q partial_helper_loaded; and exit 1
functions -q undeclared_partial_helper; and exit 1
bootstrap strict partial_helper
and exit 1
functions -q undeclared_partial_helper; and exit 1
bootstrap strict helper_success
or exit 1
functions -q helper_success_private; or exit 1
bootstrap strict partial_b
and exit 1
if builtin set -q _sp_fish_loader_owned_exports
    if test (builtin count \$_sp_fish_loader_owned_exports) -ne 0
        exit 1
    end
end
if builtin set -q _sp_fish_loaded_modules
    if test (builtin count \$_sp_fish_loaded_modules) -ne 0
        exit 1
    end
end
bootstrap strict independent
or exit 1

# A nonzero return in a body is isolated and cannot make its dependent load.
set -e return_dep_seen
bootstrap permissive return_app
or exit 1
set -q return_dep_seen; or exit 1
functions -q return_app_loaded; and exit 1

# A body cannot poison the next bootstrap request, handshake, or project root.
set -e poison_loaded
bootstrap strict poison
and exit 1
test "\$SHELL_PROJECT_ROOT" = '$_fixture'; or exit 1
builtin set -q -U SHELL_PROJECT_ROOT; and exit 1
set -q _sp_fish_loader_bootstrap_mode; and exit 1
set -q _sp_fish_loader_bootstrap_seeds; and exit 1
set -q _sp_fish_loader_bootstrap_status; and exit 1
set -q recursive_poison_loaded; and exit 1
for _loader_scratch_name in _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_present _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_exported _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_values
    builtin set -q -g \$_loader_scratch_name; and exit 1
    builtin set -q -U \$_loader_scratch_name; and exit 1
end
# This attack changes only the universal protected root. The loader must reject
# it, remove its export, and remove all forged scratch namespace variables.
bootstrap strict isolated_snapshot_attack
and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; and exit 1
functions -q isolated_snapshot_attack_loaded; and exit 1
for _loader_scratch_name in _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_present _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_exported _sp_fish_loader_scope_before_SHELL_PROJECT_ROOT_values
    builtin set -q -g \$_loader_scratch_name; and exit 1
    builtin set -q -U \$_loader_scratch_name; and exit 1
end
# Global protected-state mutations must fail even when they do not alter the
# visible value or universal scope.
bootstrap strict global_readiness_attack
and exit 1
builtin set -q VALISE_FISH_READY; and exit 1
functions -q global_readiness_attack_loaded; and exit 1
bootstrap strict global_export_attack
and exit 1
builtin set -q _sp_fish_loader_bootstrap_status; and exit 1
functions -q global_export_attack_loaded; and exit 1
bootstrap strict clean
or exit 1

# Reserved-function hijack and embedded `cd` mutation are isolated in child
# processes above: fail-closed termination is the restoration boundary.

# A caller-owned critical builtin shadow must cause a fail-closed request, but
# the loader must not erase the caller's function before the transaction can
# observe and preserve it.
function contains
    echo caller-critical-contains
end
bootstrap strict clean
and exit 1
builtin functions -q contains; or exit 1
test (contains ignored ignored) = caller-critical-contains; or exit 1
builtin functions -e contains
bootstrap strict clean
or exit 1

# A private helper failure without caller replacement remains a normal
# transactional return; caller-replacement cases are exercised in child
# processes above because exact Fish provenance cannot be restored.
bootstrap strict private_failed
and exit 1
functions -q _private_failed_helper; and exit 1
functions -q private_failed_loaded; and exit 1

# A caller-defined rollback helper from an arbitrary source must never run.
function _sp_fish_loader_rollback_activation; set -g fake_rollback_called 1; end
if test $_have_public_adapter -eq 1
# Public adapter must fail closed when the engine is missing, even with a
# stale success handshake, and must not leave readiness behind.
set -gx SHELL_PROJECT_ROOT '$_missing_root'
set -g _sp_fish_loader_bootstrap_status 0
builtin source '$_missing_root/entrypoints/fish/profile.fish'
set -l _missing_public_status \$status
test \$_missing_public_status -ne 0; or exit 1
set -q VALISE_FISH_READY; and exit 1
set -q _sp_fish_loader_bootstrap_status; and exit 1
set -q fake_rollback_called; and exit 1

# Failed adapter preflight restores a universal-only caller root without
# manufacturing a global binding.
builtin set -e -g SHELL_PROJECT_ROOT
builtin set -U SHELL_PROJECT_ROOT prior-universal-root
builtin source '$_missing_root/entrypoints/fish/profile.fish'
set -l _universal_root_status \$status
test \$_universal_root_status -ne 0; or exit 1
builtin set -q -g SHELL_PROJECT_ROOT; and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; or exit 1
test "\$SHELL_PROJECT_ROOT" = prior-universal-root; or exit 1
builtin set -e -U SHELL_PROJECT_ROOT

# A caller-local root can shadow the universal root while the adapter is
# sourced inside a function. Failure must restore both scopes and the local.
function _adapter_local_scope_probe
    builtin set -e -g SHELL_PROJECT_ROOT
    builtin set -U SHELL_PROJECT_ROOT prior-universal-local-probe
    set -l SHELL_PROJECT_ROOT local-shadow-root
    builtin source '$_missing_root/entrypoints/fish/profile.fish'
end
_adapter_local_scope_probe; and exit 1
builtin set -q -g SHELL_PROJECT_ROOT; and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; or exit 1
set -l _universal_scope_value (builtin set --show SHELL_PROJECT_ROOT | string match -r '^\\\$SHELL_PROJECT_ROOT\[1\]: \|.*\|$' | string replace -r '^.*: \|' '' | string replace -r '\|$' '')
test "\$_universal_scope_value" = prior-universal-local-probe; or exit 1
builtin set -e -U SHELL_PROJECT_ROOT

# Public source-tree/installed-style activation uses the protected loader and
# ignores an untrusted generated plan. A body that forges readiness and then
# triggers loader integrity failure must not leave readiness asserted.
set -gx SHELL_PROJECT_ROOT '$_public_root'
builtin source '$_project_adapter'
set -l _public_poison_status \$status
test \$_public_poison_status -ne 0; or exit 1
set -q VALISE_FISH_READY; and exit 1
functions -q contains; and exit 1
builtin set -q -U VALISE_FISH_READY; and exit 1
builtin set -q -U SHELL_PROJECT_ROOT; and exit 1
# Replace the hostile body with a clean one and prove the same public route can
# recover after the failed attempt.
builtin printf '%s\n' 'set -g public_fish_path_loaded 1; function public_fish_path_loaded; end' > '$_public_root/modules/fish/public/fish_path.fish'
builtin source '$_project_adapter'
or exit 1
set -q public_plan_sourced; and exit 1
set -q public_fish_path_loaded; or exit 1
set -q public_fish_environment_loaded; or exit 1
set -q public_fish_secure_local_bin_loaded; or exit 1
set -q VALISE_FISH_READY; or exit 1
# Switching from a historical generated-plan activation to the native adapter
# removes the legacy plan's newly-created functions via its separate ledger.
builtin source '$_test_root/valise-init-fish-legacy.fish'
or exit 1
functions -q legacy_plan_loaded; or exit 1
builtin set -gx SHELL_PROJECT_ROOT '$_public_root'
builtin source '$_project_adapter'
or exit 1
functions -q legacy_plan_loaded; and exit 1

# Early adapter failures roll back the previous loader-owned exports before
# returning, rather than leaving the old activation callable without readiness.
set -gx SHELL_PROJECT_ROOT '$_missing_root'
builtin source '$_missing_root/entrypoints/fish/profile.fish'
set -l _missing_after_success_status \$status
test \$_missing_after_success_status -ne 0; or exit 1
functions -q public_fish_path_loaded; and exit 1
set -q VALISE_FISH_READY; and exit 1
set -gx SHELL_PROJECT_ROOT '$_public_root'
builtin source '$_project_adapter'
or exit 1
set -q public_fish_path_loaded; or exit 1

# Switching to a different active root removes the prior root's owned exports.
set -gx SHELL_PROJECT_ROOT '$_public_second_root'
builtin source '$_project_adapter'
or exit 1
functions -q public_fish_path_loaded; and exit 1
functions -q second_fish_path_loaded; or exit 1
# A caller-defined source function cannot suppress the public loader. The
# failed attempt preserves the caller-owned shadow; the caller must remove it
# explicitly before a clean source-driven request can succeed.
function source; set -g public_source_hijack 1; return 0; end
builtin source '$_project_adapter'
set -l _source_hijack_status \$status
test \$_source_hijack_status -ne 0; or exit 1
set -q public_source_hijack; and exit 1
functions -q source; or exit 1
builtin functions -e source
builtin source '$_project_adapter'
or exit 1
set -q VALISE_FISH_READY; or exit 1

# The public valise init snippet also uses metadata + loader fallback rather
# than directly sourcing generated/installed-modules.fish.
builtin set -e VALISE_FISH_READY
builtin source '$_test_root/valise-init-fish.fish'
or exit 1
set -q public_plan_sourced; and exit 1
set -q public_fish_path_loaded; or exit 1
set -q VALISE_FISH_READY; or exit 1

end

# Return to the direct fixture for the remaining root-discovery probes.
# Rebind both halves of the loader ABI to the same trusted source directory
# before direct bootstrap calls; the loader rejects mixed-root metadata/provider
# functions rather than accepting a provenance mismatch.
builtin set -e _sp_fish_loader_expected_source
builtin set -e _sp_fish_metadata_expected_source
builtin source '$_engine/lib/fish/metadata.fish'
builtin source '$_engine/lib/fish/loader.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
# Caller cd/pwd replacements are rejected before root discovery; a clean
# source-driven request remains usable after each rejection.
function cd; return 1; end
bootstrap strict after_cd
and exit 1
functions -q cd; or exit 1
builtin functions -e cd
function pwd; return 1; end
bootstrap strict after_pwd
and exit 1
functions -q pwd; or exit 1
builtin functions -e pwd
bootstrap strict after_pwd
or exit 1
function path; return 0; end
bootstrap strict after_path
and exit 1
functions -q path; or exit 1
builtin functions -e path
bootstrap strict after_path
or exit 1

# A caller replacement of a loader-owned function must survive the next
# activation cleanup because ownership includes the trusted source identity.
bootstrap strict helper_success
or exit 1
function helper_success_private
    echo caller-helper-replacement
end
bootstrap strict independent
or exit 1
functions -q helper_success_private; or exit 1
test (helper_success_private) = caller-helper-replacement; or exit 1

printf '%s\n' 'Fish runtime: all hostile and integration checks passed'
EOF

/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" SHELL_PROJECT_ROOT="$_fixture" "$_fish" "$_program"

# Same-name providers with different versions fail closed with a
# version-skew diagnostic before either body executes.
_skew_program="$_test_root/version-skew.fish"
cat >"$_skew_program" <<EOF
builtin source '$_engine/lib/fish/metadata.fish'
set -gx SHELL_PROJECT_ROOT '$_fixture'
set -g _sp_fish_loader_bootstrap_mode strict
set -g _sp_fish_loader_bootstrap_seeds version_skew
builtin source '$_engine/lib/fish/loader.fish'
test "\$_sp_fish_loader_bootstrap_status" -ne 0; or exit 1
functions -q version_skew_sourced; and exit 1
functions -q version_skew_loaded; and exit 1
exit 0
EOF
_skew_status=0
/usr/bin/env -i HOME="$_test_home" TMPDIR="${TMPDIR:-/tmp}" PATH="${PATH:-/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin}" "$_fish" "$_skew_program" >"$_test_root/version-skew.stdout" 2>"$_test_root/version-skew.stderr" || _skew_status=$?
if [ "$_skew_status" -ne 0 ]; then
  cat "$_test_root/version-skew.stdout" >&2
  cat "$_test_root/version-skew.stderr" >&2
  printf '%s\n' 'FAIL: version-skew providers did not fail closed quietly' >&2
  exit 1
fi
for _skew_needle in 'conflicting versions are forbidden' 'version 1.0.0' 'version 2.0.0' 'vendor a single version'; do
  if ! grep -qF "$_skew_needle" "$_test_root/version-skew.stderr"; then
    cat "$_test_root/version-skew.stderr" >&2
    printf 'FAIL: version-skew diagnostic missing: %s\n' "$_skew_needle" >&2
    exit 1
  fi
done
unset _skew_program _skew_status _skew_needle
