# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: Fish startup hook generator.
# Sourced by bin/valise; not executable on its own.

print_fish_integration() {
  _fish_active_literal=$(fish_quote "$VALISE_ACTIVE_LINK") || return 1
  _fish_cli_dir=$(cd "$(path_parent "$_valise_cli_path")" 2>/dev/null && pwd -P) || return 1
  _fish_cli_path="$_fish_cli_dir/${_valise_cli_path##*/}"
  _fish_cli_literal=$(fish_quote "$_fish_cli_path") || return 1
  _fish_source_tree_mode=${_fish_source_tree_mode:-0}
  printf '%s\n' \
    "# valise Fish integration. Do not edit." \
    "# This hook loads the active valise release for Fish sessions." \
    "begin" \
    "set -l _valise_fish_source_tree_mode $_fish_source_tree_mode" \
    "set -l _valise_fish_previous_root ''" \
    "if builtin set -q SHELL_PROJECT_ROOT; and builtin test (builtin count \$SHELL_PROJECT_ROOT) -eq 1" \
    "  set _valise_fish_previous_root (builtin path resolve -- \"\$SHELL_PROJECT_ROOT\" 2>/dev/null)" \
    "end" \
    "# Authenticate the universal-variable store before any untrusted release source runs." \
    "set -l _valise_fish_persistence_config_home ''" \
    "if builtin set -q XDG_CONFIG_HOME; and test -n \"\$XDG_CONFIG_HOME\"" \
    "  set _valise_fish_persistence_config_home \"\$XDG_CONFIG_HOME\"" \
    "else if builtin set -q HOME; and test -n \"\$HOME\"" \
    "  set _valise_fish_persistence_config_home \"\$HOME/.config\"" \
    "else" \
    "  builtin exit 125" \
    "end" \
    "set -l _valise_fish_persistence_durable_file \"\$_valise_fish_persistence_config_home/fish/fish_variables\"" \
    "set -g _valise_fish_persistence_path_physical_helper __valise_fish_path_(builtin random)" \
    "function \$_valise_fish_persistence_path_physical_helper --no-scope-shadowing" \
    "  set -l _persistence_path \$argv[1]" \
    "  if test -x /usr/bin/uname; and test (/usr/bin/uname -s 2>/dev/null) = Darwin" \
    "    if builtin test -L /var; and test (builtin path resolve -- /var 2>/dev/null) = /private/var" \
    "      switch \"\$_persistence_path\"" \
    "        case /var" \
    "          set _persistence_path /private/var" \
    "        case '/var/*'" \
    "          set _persistence_path (builtin string replace -r '^/var' /private/var -- \"\$_persistence_path\")" \
    "      end" \
    "    end" \
    "    if builtin test -L /tmp; and test (builtin path resolve -- /tmp 2>/dev/null) = /private/tmp" \
    "      switch \"\$_persistence_path\"" \
    "        case /tmp" \
    "          set _persistence_path /private/tmp" \
    "        case '/tmp/*'" \
    "          set _persistence_path (builtin string replace -r '^/tmp' /private/tmp -- \"\$_persistence_path\")" \
    "      end" \
    "    end" \
    "  end" \
    "  if not builtin string match -q '/*' -- \"\$_persistence_path\"; or builtin string match -q '*//*' -- \"\$_persistence_path\"" \
    "    return 1" \
    "  end" \
    "  set _persistence_prefix /" \
    "  for _persistence_component in (builtin string split '/' -- \"\$_persistence_path\")" \
    "    if test -z \"\$_persistence_component\"" \
    "      continue" \
    "    end" \
    "    switch \"\$_persistence_component\"" \
    "      case . .." \
    "        return 1" \
    "    end" \
    "    if test \"\$_persistence_prefix\" = /" \
    "      set _persistence_prefix /\$_persistence_component" \
    "    else" \
    "      set _persistence_prefix \"\$_persistence_prefix/\$_persistence_component\"" \
    "    end" \
    "    if builtin test -L \"\$_persistence_prefix\"" \
    "      return 1" \
    "    end" \
    "  end" \
    "  return 0" \
    "end" \
    "if not \$_valise_fish_persistence_path_physical_helper \"\$_valise_fish_persistence_durable_file\"" \
    "  builtin exit 125" \
    "end" \
    "# Capture an absolute, writable, searchable temp parent before untrusted source." \
    "set -l _valise_fish_persistence_tmp_parent /tmp" \
    "if builtin set -q TMPDIR; and test -n \"\$TMPDIR\"" \
    "  set _valise_fish_persistence_tmp_parent \"\$TMPDIR\"" \
    "end" \
    "set _valise_fish_persistence_tmp_parent (builtin path resolve -- \"\$_valise_fish_persistence_tmp_parent\" 2>/dev/null)" \
    "if test (builtin count \$_valise_fish_persistence_tmp_parent) -ne 1; or not test -d \"\$_valise_fish_persistence_tmp_parent\"; or not test -w \"\$_valise_fish_persistence_tmp_parent\"; or not test -x \"\$_valise_fish_persistence_tmp_parent\"" \
    "  builtin exit 125" \
    "end" \
    "# Capture persistent SHELL_PROJECT_ROOT scopes before clearing activation state." \
    "set -l _valise_fish_scratch_names _valise_fish_root_global_set _valise_fish_root_global_exported _valise_fish_root_global_values _valise_fish_root_universal_set _valise_fish_root_universal_exported _valise_fish_root_universal_values VALISE_MODULE_ROOT XDG_CONFIG_HOME TMPDIR HOME" \
    "set -l _valise_fish_scratch_prefix __valise_fish_scratch_state_(builtin random)" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_set_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_exported_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_global_values_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_set_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_exported_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"__valise_fish_root_universal_values_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_VALISE_MODULE_ROOT_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_XDG_CONFIG_HOME_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_TMPDIR_universal_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_global_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_global_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_global_values" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_universal_present" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_universal_exported" \
    "set -l \"\$_valise_fish_scratch_prefix\"_HOME_universal_values" \
    "set -l _valise_fish_scratch_capture_helper __valise_fish_scratch_capture_(builtin random)" \
    "function \$_valise_fish_scratch_capture_helper --no-scope-shadowing" \
    "  set -l _scratch_target \$argv[1]" \
    "  set -l _scratch_prefix \$argv[2]_\$_scratch_target" \
    "  set -l _scratch_global_present 0" \
    "  builtin set -q -g \"\$_scratch_target\"; and set _scratch_global_present 1" \
    "  set -l _scratch_global_exported 0" \
    "  builtin set -q -gx \"\$_scratch_target\"; and set _scratch_global_exported 1" \
    "  set -l _scratch_global_values" \
    "  if test \$_scratch_global_present -eq 1" \
    "    set _scratch_global_values \$\$_scratch_target" \
    "  end" \
    "  set -l _scratch_universal_present 0" \
    "  builtin set -q -U \"\$_scratch_target\"; and set _scratch_universal_present 1" \
    "  set -l _scratch_universal_exported 0" \
    "  builtin set -q -Ux \"\$_scratch_target\"; and set _scratch_universal_exported 1" \
    "  set -l _scratch_universal_values" \
    "  if test \$_scratch_universal_present -eq 1" \
    "    if test \$_scratch_global_present -eq 1" \
    "      builtin set -e -g \"\$_scratch_target\"" \
    "      set _scratch_universal_values \$\$_scratch_target" \
    "      if test \$_scratch_global_exported -eq 1" \
    "        builtin set -gx \"\$_scratch_target\" \$\$_scratch_global_values" \
    "      else" \
    "        builtin set -g \"\$_scratch_target\" \$\$_scratch_global_values" \
    "      end" \
    "    else" \
    "      set _scratch_universal_values \$\$_scratch_target" \
    "    end" \
    "  end" \
    "  set \"\$_scratch_prefix\"_global_present \$_scratch_global_present" \
    "  set \"\$_scratch_prefix\"_global_exported \$_scratch_global_exported" \
    "  set \"\$_scratch_prefix\"_global_values \$_scratch_global_values" \
    "  set \"\$_scratch_prefix\"_universal_present \$_scratch_universal_present" \
    "  set \"\$_scratch_prefix\"_universal_exported \$_scratch_universal_exported" \
    "  set \"\$_scratch_prefix\"_universal_values \$_scratch_universal_values" \
    "end" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_global_set \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_global_exported \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_global_values \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_universal_set \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_universal_exported \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper _valise_fish_root_universal_values \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper VALISE_MODULE_ROOT \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper XDG_CONFIG_HOME \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper TMPDIR \"\$_valise_fish_scratch_prefix\"" \
    "\$_valise_fish_scratch_capture_helper HOME \"\$_valise_fish_scratch_prefix\"" \
    "builtin functions -e \$_valise_fish_scratch_capture_helper 2>/dev/null" \
    "set -l _valise_fish_root_global_set 0" \
    "set -l _valise_fish_root_global_exported 0" \
    "set -l _valise_fish_root_global_values" \
    "set -l _valise_fish_root_universal_set 0" \
    "set -l _valise_fish_root_universal_exported 0" \
    "set -l _valise_fish_root_universal_values" \
    "set -l _valise_fish_root_capture_helper __valise_fish_capture_(builtin random)" \
    "function \$_valise_fish_root_capture_helper --no-scope-shadowing" \
    "  set _valise_fish_root_global_set 0" \
    "  set _valise_fish_root_global_exported 0" \
    "  set _valise_fish_root_global_values" \
    "  set _valise_fish_root_universal_set 0" \
    "  set _valise_fish_root_universal_exported 0" \
    "  set _valise_fish_root_universal_values" \
    "  if builtin set -q -g SHELL_PROJECT_ROOT" \
    "    set _valise_fish_root_global_set 1" \
    "    builtin set -q -gx SHELL_PROJECT_ROOT; and set _valise_fish_root_global_exported 1" \
    "    set _valise_fish_root_global_values \$SHELL_PROJECT_ROOT" \
    "  end" \
    "  if builtin set -q -U SHELL_PROJECT_ROOT" \
    "    set _valise_fish_root_universal_set 1" \
    "    builtin set -q -Ux SHELL_PROJECT_ROOT; and set _valise_fish_root_universal_exported 1" \
    "    if builtin test \$_valise_fish_root_global_set -eq 1" \
    "      builtin set -e -g SHELL_PROJECT_ROOT; or builtin exit 125" \
    "      set _valise_fish_root_universal_values \$SHELL_PROJECT_ROOT" \
    "      if builtin test \$_valise_fish_root_global_exported -eq 1" \
    "        builtin set -gx SHELL_PROJECT_ROOT \$_valise_fish_root_global_values; or builtin exit 125" \
    "      else" \
    "        builtin set -g SHELL_PROJECT_ROOT \$_valise_fish_root_global_values; or builtin exit 125" \
    "      end" \
    "    else" \
    "      set _valise_fish_root_universal_values \$SHELL_PROJECT_ROOT" \
    "    end" \
    "  end" \
    "end" \
    "\$_valise_fish_root_capture_helper" \
    "builtin functions -e \$_valise_fish_root_capture_helper" \
    "set -l _valise_fish_scratch_restore_helper __valise_fish_scratch_restore_(builtin random)" \
    "function \$_valise_fish_scratch_restore_helper --no-scope-shadowing" \
    "  set -l _scratch_target \$argv[1]" \
    "  set -l _scratch_prefix \$argv[2]_\$_scratch_target" \
    "  set -l _scratch_global_present_var \"\$_scratch_prefix\"_global_present" \
    "  set -l _scratch_global_exported_var \"\$_scratch_prefix\"_global_exported" \
    "  set -l _scratch_global_values_var \"\$_scratch_prefix\"_global_values" \
    "  set -l _scratch_universal_present_var \"\$_scratch_prefix\"_universal_present" \
    "  set -l _scratch_universal_exported_var \"\$_scratch_prefix\"_universal_exported" \
    "  set -l _scratch_universal_values_var \"\$_scratch_prefix\"_universal_values" \
    "  if builtin set -q -g \"\$_scratch_target\"" \
    "    builtin set -e -g \"\$_scratch_target\"; or return 125" \
    "  end" \
    "  if builtin set -q -U \"\$_scratch_target\"" \
    "    builtin set -e -U \"\$_scratch_target\"; or return 125" \
    "  end" \
    "  if test \$\$_scratch_global_present_var -eq 1" \
    "    set -l _scratch_global_flags -g" \
    "    if test \$\$_scratch_global_exported_var -eq 1" \
    "      set _scratch_global_flags -gx" \
    "    end" \
    "    builtin set \$_scratch_global_flags \"\$_scratch_target\" \$\$_scratch_global_values_var" \
    "    if test \$status -ne 0" \
    "      return 125" \
    "    end" \
    "  end" \
    "  if test \$\$_scratch_universal_present_var -eq 1" \
    "    set -l _scratch_universal_flags -U" \
    "    if test \$\$_scratch_universal_exported_var -eq 1" \
    "      set _scratch_universal_flags -Ux" \
    "    end" \
    "    builtin set \$_scratch_universal_flags \"\$_scratch_target\" \$\$_scratch_universal_values_var" \
    "    if test \$status -ne 0" \
    "      return 125" \
    "    end" \
    "  end" \
    "  if test \"\$_scratch_target\" = VALISE_MODULE_ROOT; or test \"\$_scratch_target\" = XDG_CONFIG_HOME; or test \"\$_scratch_target\" = TMPDIR; or test \"\$_scratch_target\" = HOME" \
    "    if not builtin functions -q \$_valise_fish_persistence_verify_helper; or not builtin test (builtin functions \$_valise_fish_persistence_verify_helper | string collect) = \"\$_valise_fish_persistence_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted universal persistence verifier was modified' >&2" \
    "      return 125" \
    "    end" \
    "    \$_valise_fish_persistence_verify_helper \"\$_valise_fish_persistence_durable_file\" \"\$_valise_fish_persistence_tmp_parent\" \"\$_scratch_target\" \"\$\$_scratch_universal_present_var\" \"\$\$_scratch_universal_exported_var\" \$\$_scratch_universal_values_var; or return 125" \
    "  end" \
    "  for _scratch_suffix in global_present global_exported global_values universal_present universal_exported universal_values" \
    "    set -l _scratch_snapshot_name \"\$_scratch_prefix\"_\$_scratch_suffix" \
    "    if builtin set -q -l \"\$_scratch_snapshot_name\"" \
    "      builtin set -e -l \"\$_scratch_snapshot_name\"; or return 125" \
    "    end" \
    "    if builtin set -q -g \"\$_scratch_snapshot_name\"" \
    "      builtin set -e -g \"\$_scratch_snapshot_name\"; or return 125" \
    "    end" \
    "    if builtin set -q -U \"\$_scratch_snapshot_name\"" \
    "      builtin set -e -U \"\$_scratch_snapshot_name\"; or return 125" \
    "    end" \
    "  end" \
    "end" \
    "set -l _valise_fish_persistence_verify_helper __valise_fish_verify_(builtin random)" \
    "function \$_valise_fish_persistence_verify_helper --no-scope-shadowing" \
    "  set -l _persistence_durable_file \$argv[1]" \
    "  set -l _persistence_tmp_parent \$argv[2]" \
    "  set -l _persistence_scope \$argv[3]" \
    "  set -l _persistence_expected_present \$argv[4]" \
    "  set -l _persistence_expected_exported \$argv[5]" \
    "  set -l _persistence_expected_values \$argv[6..-1]" \
    "  set -l _persistence_fish_path (status fish-path)" \
    "  if test (builtin count \$_persistence_fish_path) -ne 1; or not test -x \"\$_persistence_fish_path\"" \
    "    return 125" \
    "  end" \
    "  # _persistence_durable_file was captured before untrusted source execution." \
    "  if not test -f \"\$_persistence_durable_file\"" \
    "    if test \"\$_persistence_expected_present\" = 0" \
    "      return 0" \
    "    end" \
    "    return 125" \
    "  end" \
    "  if not string match -q '/*' -- \"\$_persistence_tmp_parent\"; or not test -d \"\$_persistence_tmp_parent\"; or not test -w \"\$_persistence_tmp_parent\"; or not test -x \"\$_persistence_tmp_parent\"" \
    "    return 125" \
    "  end" \
    "  set -l _persistence_checked_file \$_persistence_durable_file" \
    "  if test -x /usr/bin/uname; and test (/usr/bin/uname -s 2>/dev/null) = Darwin" \
    "    if builtin test -L /var; and test (builtin path resolve -- /var 2>/dev/null) = /private/var" \
    "      set _persistence_checked_file (builtin string replace -r '^/var' /private/var -- \"\$_persistence_checked_file\")" \
    "    end" \
    "    if builtin test -L /tmp; and test (builtin path resolve -- /tmp 2>/dev/null) = /private/tmp" \
    "      set _persistence_checked_file (builtin string replace -r '^/tmp' /private/tmp -- \"\$_persistence_checked_file\")" \
    "    end" \
    "  end" \
    "  if not builtin string match -q '/*' -- \"\$_persistence_checked_file\"; or builtin string match -q '*//*' -- \"\$_persistence_checked_file\"" \
    "    return 125" \
    "  end" \
    "  set -l _persistence_checked_prefix /" \
    "  for _persistence_checked_component in (builtin string split '/' -- \"\$_persistence_checked_file\")" \
    "    if test -z \"\$_persistence_checked_component\"" \
    "      continue" \
    "    end" \
    "    switch \"\$_persistence_checked_component\"" \
    "      case . .." \
    "        return 125" \
    "    end" \
    "    if test \"\$_persistence_checked_prefix\" = /" \
    "      set _persistence_checked_prefix /\$_persistence_checked_component" \
    "    else" \
    "      set _persistence_checked_prefix \"\$_persistence_checked_prefix/\$_persistence_checked_component\"" \
    "    end" \
    "    if builtin test -L \"\$_persistence_checked_prefix\"" \
    "      return 125" \
    "    end" \
    "  end" \
    "  set -e _persistence_checked_file _persistence_checked_prefix _persistence_checked_component" \
    "  set -l _persistence_mktemp_path ''" \
    "  for _persistence_candidate in /usr/bin/mktemp /bin/mktemp" \
    "    if test -x \"\$_persistence_candidate\"" \
    "      set _persistence_mktemp_path \"\$_persistence_candidate\"" \
    "      break" \
    "    end" \
    "  end" \
    "  set -l _persistence_mkdir_path ''" \
    "  for _persistence_candidate in /bin/mkdir /usr/bin/mkdir" \
    "    if test -x \"\$_persistence_candidate\"" \
    "      set _persistence_mkdir_path \"\$_persistence_candidate\"" \
    "      break" \
    "    end" \
    "  end" \
    "  set -l _persistence_ln_path ''" \
    "  for _persistence_candidate in /bin/ln /usr/bin/ln" \
    "    if test -x \"\$_persistence_candidate\"" \
    "      set _persistence_ln_path \"\$_persistence_candidate\"" \
    "      break" \
    "    end" \
    "  end" \
    "  set -l _persistence_rm_path ''" \
    "  for _persistence_candidate in /bin/rm /usr/bin/rm" \
    "    if test -x \"\$_persistence_candidate\"" \
    "      set _persistence_rm_path \"\$_persistence_candidate\"" \
    "      break" \
    "    end" \
    "  end" \
    "  if test -z \"\$_persistence_mktemp_path\"; or test -z \"\$_persistence_mkdir_path\"; or test -z \"\$_persistence_ln_path\"; or test -z \"\$_persistence_rm_path\"" \
    "    return 125" \
    "  end" \
    "  set -l _persistence_verify_root (\"\$_persistence_mktemp_path\" -d \"\$_persistence_tmp_parent/valise-fish-persistence.XXXXXX\" 2>/dev/null)" \
    "  if test \$status -ne 0; or test (builtin count \$_persistence_verify_root) -ne 1" \
    "    return 125" \
    "  end" \
    "  if not \"\$_persistence_mkdir_path\" -p \"\$_persistence_verify_root/fish\"; or not \"\$_persistence_ln_path\" -s \"\$_persistence_durable_file\" \"\$_persistence_verify_root/fish/fish_variables\"" \
    "    if not \"\$_persistence_rm_path\" -rf -- \"\$_persistence_verify_root\" 2>/dev/null" \
    "      return 125" \
    "    end" \
    "    return 125" \
    "  end" \
    "  set -lx XDG_CONFIG_HOME \"\$_persistence_verify_root\"" \
    "  set -l _persistence_actual (\"\$_persistence_fish_path\" -c '" \
    "    set -l _persistence_name \$argv[1]" \
    "    # Remove an inherited global shadow before reading the universal store." \
    "    if builtin set -q -g -- \$_persistence_name" \
    "      set -l _persistence_global_values \$\$_persistence_name" \
    "      builtin set -e -g -- \$_persistence_name; or exit 125" \
    "    end" \
    "    if builtin set -q -U -- \$_persistence_name" \
    "      builtin printf \"1\\n\"" \
    "      if builtin set -q -Ux -- \$_persistence_name" \
    "        builtin printf \"1\\n\"" \
    "      else" \
    "        builtin printf \"0\\n\"" \
    "      end" \
    "      string escape -- \$\$_persistence_name" \
    "    else" \
    "      builtin printf \"0\\n0\\n\"" \
    "    end" \
    "  ' -- \"\$_persistence_scope\" 2>/dev/null)" \
    "  set -l _persistence_child_status \$status" \
    "  if not \"\$_persistence_rm_path\" -rf -- \"\$_persistence_verify_root\" 2>/dev/null" \
    "    return 125" \
    "  end" \
    "  if test \$_persistence_child_status -ne 0" \
    "    return 125" \
    "  end" \
    "  set -l _persistence_expected \$_persistence_expected_present \$_persistence_expected_exported" \
    "  set -a _persistence_expected (string escape -- \$_persistence_expected_values)" \
    "  if test (builtin count \$_persistence_actual) -ne (builtin count \$_persistence_expected)" \
    "    return 125" \
    "  end" \
    "  set -l _persistence_index 1" \
    "  while test \$_persistence_index -le (builtin count \$_persistence_expected)" \
    "    if not builtin test \"\$_persistence_actual[\$_persistence_index]\" = \"\$_persistence_expected[\$_persistence_index]\"" \
    "      return 125" \
    "    end" \
    "    set _persistence_index (builtin math \$_persistence_index + 1)" \
    "  end" \
    "  return 0" \
    "end" \
    "# Restore persistent caller root scopes and remove the temporary snapshot state." \
    "set -l _valise_fish_root_restore_helper __valise_fish_restore_(builtin random)" \
    "function \$_valise_fish_root_restore_helper --no-scope-shadowing" \
    "  if builtin set -q -g SHELL_PROJECT_ROOT" \
    "    builtin set -e -g SHELL_PROJECT_ROOT; or return 125" \
    "  end" \
    "  if builtin set -q -U SHELL_PROJECT_ROOT" \
    "    builtin set -e -U SHELL_PROJECT_ROOT; or return 125" \
    "  end" \
    "  if builtin test \$_valise_fish_root_global_set -eq 1" \
    "    set -l _valise_fish_root_global_flags -g" \
    "    if builtin test \$_valise_fish_root_global_exported -eq 1" \
    "      set _valise_fish_root_global_flags -gx" \
    "    end" \
    "    builtin set \$_valise_fish_root_global_flags SHELL_PROJECT_ROOT \$_valise_fish_root_global_values" \
    "    if test \$status -ne 0" \
    "      return 125" \
    "    end" \
    "  end" \
    "  if not builtin functions -q \$_valise_fish_persistence_verify_helper; or not builtin test (builtin functions \$_valise_fish_persistence_verify_helper | string collect) = \"\$_valise_fish_persistence_helper_definition\"" \
    "    builtin printf '%s\\n' 'trusted universal persistence verifier was modified' >&2" \
    "    return 125" \
    "  end" \
    "  if builtin test \$_valise_fish_root_universal_set -eq 1" \
    "    set -l _valise_fish_root_universal_flags -U" \
    "    if builtin test \$_valise_fish_root_universal_exported -eq 1" \
    "      set _valise_fish_root_universal_flags -Ux" \
    "    end" \
    "    builtin set \$_valise_fish_root_universal_flags SHELL_PROJECT_ROOT \$_valise_fish_root_universal_values" \
    "    if test \$status -ne 0" \
    "      return 125" \
    "    end" \
    "  end" \
    "  \$_valise_fish_persistence_verify_helper \"\$_valise_fish_persistence_durable_file\" \"\$_valise_fish_persistence_tmp_parent\" SHELL_PROJECT_ROOT \"\$_valise_fish_root_universal_set\" \"\$_valise_fish_root_universal_exported\" \$_valise_fish_root_universal_values; or return 125" \
    "  for _valise_fish_root_state in _valise_fish_root_global_set _valise_fish_root_global_exported _valise_fish_root_global_values _valise_fish_root_universal_set _valise_fish_root_universal_exported _valise_fish_root_universal_values" \
    "    if builtin set -q -l \$_valise_fish_root_state" \
    "      builtin set -e -l \$_valise_fish_root_state; or return 125" \
    "    end" \
    "  end" \
    "  for _valise_fish_scratch_name in \$_valise_fish_scratch_names" \
    "    if not builtin functions -q \$_valise_fish_scratch_restore_helper; or not builtin test (builtin functions \$_valise_fish_scratch_restore_helper | string collect) = \"\$_valise_fish_scratch_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted scratch restore helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_scratch_restore_helper \"\$_valise_fish_scratch_name\" \"\$_valise_fish_scratch_prefix\"; or return 125" \
    "  end" \
    "  if builtin set -q _valise_fish_persistence_verify_helper; and builtin functions -q \"\$_valise_fish_persistence_verify_helper\"" \
    "    builtin functions -e \"\$_valise_fish_persistence_verify_helper\"; or return 125" \
    "  end" \
    "  builtin functions -e (builtin status function) 2>/dev/null" \
    "end" \
    "# Publish only the authenticated active root and readiness marker. Untrusted" \
    "# source may have left universal shadows behind, so remove them before the" \
    "# global public state is exposed." \
    "set -l _valise_fish_publish_active_helper __valise_fish_publish_(builtin random)" \
    "function \$_valise_fish_publish_active_helper --no-scope-shadowing" \
    "  if builtin set -q -U SHELL_PROJECT_ROOT" \
    "    builtin set -e -U SHELL_PROJECT_ROOT; or return 125" \
    "  end" \
    "  builtin set -gx SHELL_PROJECT_ROOT \"\$_valise_fish_active_root\"; or return 125" \
    "  if builtin set -q -U VALISE_FISH_READY" \
    "    builtin set -e -U VALISE_FISH_READY; or return 125" \
    "  end" \
    "  builtin set -gx VALISE_FISH_READY 1; or return 125" \
    "end" \
    "set -l _valise_fish_publish_active_helper_definition (builtin functions \"\$_valise_fish_publish_active_helper\" | string collect)" \
    "# Successful activation keeps the authenticated public root/readiness state." \
    "# It only removes private snapshots and trusted helper functions; rollback" \
    "# is reserved for failure paths." \
    "set -l _valise_fish_success_cleanup_helper __valise_fish_cleanup_(builtin random)" \
    "function \$_valise_fish_success_cleanup_helper --no-scope-shadowing" \
    "  if not builtin functions -q \$_valise_fish_success_cleanup_helper; or not builtin test (builtin functions \$_valise_fish_success_cleanup_helper | string collect) = \"\$_valise_fish_success_cleanup_helper_definition\"" \
    "    builtin printf '%s\\n' 'trusted success cleanup helper was modified' >&2" \
    "    return 125" \
    "  end" \
    "  for _valise_fish_root_state in _valise_fish_root_global_set _valise_fish_root_global_exported _valise_fish_root_global_values _valise_fish_root_universal_set _valise_fish_root_universal_exported _valise_fish_root_universal_values" \
    "    if builtin set -q -l \$_valise_fish_root_state" \
    "      builtin set -e -l \$_valise_fish_root_state; or return 125" \
    "    end" \
    "  end" \
    "  if not builtin functions -q \$_valise_fish_scratch_restore_helper; or not builtin test (builtin functions \$_valise_fish_scratch_restore_helper | string collect) = \"\$_valise_fish_scratch_restore_helper_definition\"" \
    "    builtin printf '%s\\n' 'trusted scratch restore helper was modified' >&2" \
    "    return 125" \
    "  end" \
    "  for _valise_fish_scratch_name in \$_valise_fish_scratch_names" \
    "    if not builtin functions -q \$_valise_fish_scratch_restore_helper; or not builtin test (builtin functions \$_valise_fish_scratch_restore_helper | string collect) = \"\$_valise_fish_scratch_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted scratch restore helper was modified' >&2" \
    "      return 125" \
    "    end" \
    "    \$_valise_fish_scratch_restore_helper \"\$_valise_fish_scratch_name\" \"\$_valise_fish_scratch_prefix\"; or return 125" \
    "  end" \
    "  if builtin set -q _valise_fish_publish_active_helper; and builtin functions -q \"\$_valise_fish_publish_active_helper\"" \
    "    if not builtin test (builtin functions \"\$_valise_fish_publish_active_helper\" | string collect) = \"\$_valise_fish_publish_active_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted active-state publisher was modified' >&2" \
    "      return 125" \
    "    end" \
    "    builtin functions -e \"\$_valise_fish_publish_active_helper\"; or return 125" \
    "  end" \
    "  if builtin set -q _valise_fish_persistence_verify_helper; and builtin functions -q \"\$_valise_fish_persistence_verify_helper\"" \
    "    if not builtin test (builtin functions \"\$_valise_fish_persistence_verify_helper\" | string collect) = \"\$_valise_fish_persistence_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted universal persistence verifier was modified' >&2" \
    "      return 125" \
    "    end" \
    "    builtin functions -e \"\$_valise_fish_persistence_verify_helper\"; or return 125" \
    "  end" \
    "  if builtin set -q _valise_fish_owned_cleanup; and builtin functions -q \"\$_valise_fish_owned_cleanup\"" \
    "    builtin functions -e \"\$_valise_fish_owned_cleanup\"; or return 125" \
    "  end" \
    "  if builtin set -q _valise_fish_persistence_path_physical_helper; and builtin functions -q \"\$_valise_fish_persistence_path_physical_helper\"" \
    "    builtin functions -e \"\$_valise_fish_persistence_path_physical_helper\"; or return 125" \
    "  end" \
    "  if builtin functions -q \"\$_valise_fish_root_restore_helper\"" \
    "    if not builtin test (builtin functions \"\$_valise_fish_root_restore_helper\" | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "      return 125" \
    "    end" \
    "    builtin functions -e \"\$_valise_fish_root_restore_helper\"; or return 125" \
    "  end" \
    "  if builtin functions -q \"\$_valise_fish_scratch_restore_helper\"" \
    "    if not builtin test (builtin functions \"\$_valise_fish_scratch_restore_helper\" | string collect) = \"\$_valise_fish_scratch_restore_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted scratch restore helper was modified' >&2" \
    "      return 125" \
    "    end" \
    "    builtin functions -e \"\$_valise_fish_scratch_restore_helper\"; or return 125" \
    "  end" \
    "  builtin functions -e (builtin status function) 2>/dev/null; or return 125" \
    "end" \
    "# Keep cleanup definitions outside the Fish function namespace while" \
    "# untrusted entrypoints and generated plans are executing. Function names" \
    "# are enumerable, so the trusted definitions stay in caller-local Fish" \
    "# variables rather than same-user-writable temporary files." \
    "set -l _valise_fish_root_helper_definition (builtin functions \"\$_valise_fish_root_restore_helper\" | string collect)" \
    "set -l _valise_fish_success_cleanup_helper_definition (builtin functions \"\$_valise_fish_success_cleanup_helper\" | string collect)" \
    "set -l _valise_fish_persistence_helper_definition (builtin functions \"\$_valise_fish_persistence_verify_helper\" | string collect)" \
    "set -l _valise_fish_scratch_helper_definition (builtin functions \"\$_valise_fish_scratch_restore_helper\" | string collect)" \
    "set -l _valise_fish_scratch_restore_helper_definition (builtin functions \"\$_valise_fish_scratch_restore_helper\" | string collect)" \
    "if test (builtin count \$_valise_fish_root_helper_definition) -ne 1; or test (builtin count \$_valise_fish_success_cleanup_helper_definition) -ne 1; or test (builtin count \$_valise_fish_publish_active_helper_definition) -ne 1; or test (builtin count \$_valise_fish_persistence_helper_definition) -ne 1; or test (builtin count \$_valise_fish_scratch_helper_definition) -ne 1; or test (builtin count \$_valise_fish_scratch_restore_helper_definition) -ne 1" \
    "  printf '%s\\n' 'valise Fish integration: trusted cleanup snapshot unavailable' >&2" \
    "  return 125" \
    "end" \
    "# Activate one historical generated Fish plan transactionally." \
    "set -l _valise_fish_legacy_runner __valise_fish_legacy_run_(builtin random)" \
    "function \$_valise_fish_legacy_runner" \
    "  set -l _legacy_root \$argv[1]" \
    "  set -l _legacy_plan \$argv[2]" \
    "  set -l _legacy_before (builtin functions --all --names)" \
    "  set -l _legacy_snapshot_names" \
    "  set -l _legacy_snapshot_definitions" \
    "  set -l _legacy_runner_name (builtin status function)" \
    "  set -l _legacy_snapshot_index 1" \
    "  set -l _legacy_critical_names contains test string source path functions set printf echo math count eval cd pwd" \
    "  set -l _legacy_snapshot_sources" \
    "  for _legacy_function in \$_legacy_before" \
    "    if builtin contains -- \"\$_legacy_function\" \"\$_legacy_runner_name\"; or not builtin functions -q \"\$_legacy_function\"" \
    "      continue" \
    "    end" \
    "    set -l _legacy_source (builtin functions --details \"\$_legacy_function\")" \
    "    if not builtin contains -- \"\$_legacy_function\" \$_legacy_critical_names; and builtin string match -q -r '^(embedded:|autoloaded:|builtin)' -- \"\$_legacy_source\"" \
    "      continue" \
    "    end" \
    "    set -l _legacy_definition (builtin functions \"\$_legacy_function\" | string collect)" \
    "    if test (builtin count \$_legacy_definition) -ne 1" \
    "      builtin printf 'valise Fish integration: unable to snapshot caller Fish function: %s\\n' \"\$_legacy_function\" >&2" \
    "      return 1" \
    "    end" \
    "    set -a _legacy_snapshot_names \"\$_legacy_function\"" \
    "    set -a _legacy_snapshot_definitions \"\$_legacy_definition\"" \
    "    set -a _legacy_snapshot_sources \"\$_legacy_source\"" \
    "    set _legacy_snapshot_index (builtin math \$_legacy_snapshot_index + 1)" \
    "  end" \
    "  builtin set -gx VALISE_MODULE_ROOT \"\$_legacy_root\"" \
    "  set -l _legacy_source_runner __valise_fish_legacy_source_(builtin random)" \
    "  function \$_legacy_source_runner" \
    "    builtin source \"\$argv[1]\"" \
    "    return \$status" \
    "  end" \
    "  \$_legacy_source_runner \"\$_legacy_plan\"" \
    "  set -l _legacy_status \$status" \
    "  builtin functions -e \$_legacy_source_runner 2>/dev/null" \
    "  set -l _legacy_after (builtin functions --all --names)" \
    "  set -l _legacy_created" \
    "  set -l _legacy_critical_created" \
    "  for _legacy_function in \$_legacy_after" \
    "    if not builtin contains -- \"\$_legacy_function\" \$_legacy_before" \
    "      set -a _legacy_created \"\$_legacy_function\"" \
    "      if builtin contains -- \"\$_legacy_function\" \$_legacy_critical_names" \
    "        set -a _legacy_critical_created \"\$_legacy_function\"" \
    "      end" \
    "    end" \
    "  end" \
    "  set -l _legacy_replaced" \
    "  set -l _legacy_embedded_replaced" \
    "  set _legacy_snapshot_index 1" \
    "  for _legacy_original in \$_legacy_snapshot_names" \
    "    set -l _legacy_definition \"\$_legacy_snapshot_definitions[\$_legacy_snapshot_index]\"" \
    "    if not builtin functions -q \"\$_legacy_original\"; or not test (builtin functions \"\$_legacy_original\" | string collect) = \"\$_legacy_definition\"" \
    "      set -a _legacy_replaced \"\$_legacy_original\"" \
    "      if builtin string match -q 'embedded:*' -- \"\$_legacy_snapshot_sources[\$_legacy_snapshot_index]\"" \
    "        set -a _legacy_embedded_replaced \"\$_legacy_original\"" \
    "      end" \
    "    end" \
    "    set _legacy_snapshot_index (builtin math \$_legacy_snapshot_index + 1)" \
    "  end" \
    "  for _legacy_state in VALISE_FISH_READY _sp_fish_loader_expected_source _sp_fish_metadata_expected_source _sp_fish_loader_bootstrap_status _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds VALISE_MODULE_ROOT SHELL_PROJECT_ROOT XDG_CONFIG_HOME TMPDIR HOME" \
    "    if builtin set -q -g \"\$_legacy_state\"; and not builtin set -e -g \"\$_legacy_state\"; builtin exit 125; end" \
    "    if builtin set -q -U \"\$_legacy_state\"; and not builtin set -e -U \"\$_legacy_state\"; builtin exit 125; end" \
    "  end" \
    "  # Embedded critical replacement cannot be restored without changing Fish provenance. Fail closed before any restoration." \
    "  if test (builtin count \$_legacy_embedded_replaced) -ne 0; or test (builtin count \$_legacy_critical_created) -ne 0" \
    "    builtin printf '%s\\n' 'valise Fish integration: legacy Fish plan mutated a critical Fish function' >&2" \
    "    builtin exit 125" \
    "  end" \
    "  if test (builtin count \$_legacy_replaced) -ne 0" \
    "    builtin printf '%s\\n' 'valise Fish integration: exact caller-function restoration is unavailable' >&2" \
    "      builtin exit 125" \
    "  end" \
    "  if test \$_legacy_status -ne 0; or test (builtin count \$_legacy_replaced) -ne 0; or test (builtin count \$_legacy_critical_created) -ne 0;" \
    "    for _legacy_function in \$_legacy_created" \
    "      if builtin functions -q \"\$_legacy_function\"" \
    "        if builtin contains -- \"\$_legacy_function\" \$_legacy_critical_created; or test \$_legacy_status -ne 0; or test (builtin count \$_legacy_replaced) -ne 0" \
    "          builtin functions -e \"\$_legacy_function\"" \
    "        end" \
    "      end" \
    "    end" \
    "    if test (builtin count \$_legacy_embedded_replaced) -ne 0; or test (builtin count \$_legacy_critical_created) -ne 0;" \
    "      builtin printf '%s\\n' 'valise Fish integration: legacy Fish plan mutated a critical Fish function' >&2" \
    "      test \$_legacy_status -ne 0; or set _legacy_status 125" \
    "    else if test (builtin count \$_legacy_replaced) -ne 0" \
    "      builtin printf '%s\\n' 'valise Fish integration: legacy Fish plan replaced a caller-owned function' >&2" \
    "      test \$_legacy_status -ne 0; or set _legacy_status 1" \
    "    else" \
    "      builtin printf 'valise Fish integration: legacy Fish plan failed with status %d\\n' \$_legacy_status >&2" \
    "    end" \
    "    return \$_legacy_status" \
    "  end" \
    "  builtin set -g _sp_fish_legacy_owned_exports \$_legacy_created" \
    "  set -l _legacy_sources" \
    "  for _legacy_function in \$_legacy_created" \
    "    set -a _legacy_sources (builtin functions --details \"\$_legacy_function\")" \
    "  end" \
    "  builtin set -g _sp_fish_legacy_owned_sources \$_legacy_sources" \
    "  if not builtin set -q _sp_fish_module_roots" \
    "    builtin set -g _sp_fish_module_roots" \
    "  end" \
    "  builtin set -ga _sp_fish_module_roots \"\$_legacy_root\"" \
    "  return 0" \
    "end" \
    "# Clear handshake and readiness in both persistent scopes before activation." \
    "for _valise_fish_state_name in VALISE_FISH_READY _sp_fish_loader_bootstrap_status _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_expected_source _sp_fish_metadata_expected_source VALISE_MODULE_ROOT" \
    "  if builtin set -q -g \"\$_valise_fish_state_name\"; and not builtin set -e -g \"\$_valise_fish_state_name\"; builtin exit 125; end" \
    "  if builtin set -q -U \"\$_valise_fish_state_name\"; and not builtin set -e -U \"\$_valise_fish_state_name\"; builtin exit 125; end" \
    "end" \
    "# Cleanup only functions whose exact current source matches an authenticated ownership ledger." \
    "# Installed ledgers are accepted only for complete, authenticated release roots; source-tree mode is intentionally broader because it is an unauthenticated development surface." \
    "set -l _valise_fish_active_root" \
    "if test \"\$_valise_fish_source_tree_mode\" = 1" \
    "  set _valise_fish_active_root (builtin path resolve -- ${_fish_active_literal})" \
    "else" \
    "  set _valise_fish_active_root (${_fish_cli_literal} release verify --print-root 2>/dev/null)" \
    "end" \
    "set -l _valise_fish_owned_cleanup __valise_fish_owned_cleanup_(builtin random)" \
    "function \$_valise_fish_owned_cleanup --no-scope-shadowing" \
    "  set -l _valise_fish_trusted_root \$_valise_fish_active_root" \
    "  set -l _valise_fish_ledger_invalid 0" \
    "  builtin test -n \"\$_valise_fish_trusted_root\"; or set _valise_fish_ledger_invalid 1" \
    "  for _valise_fish_ledger_name in _sp_fish_loader_owned_exports _sp_fish_legacy_owned_exports _sp_fish_metadata_owned_exports _sp_fish_entrypoint_owned_exports" \
    "    set -l _valise_fish_source_ledger_name ''" \
    "    switch \"\$_valise_fish_ledger_name\"" \
    "      case _sp_fish_loader_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_loader_owned_sources" \
    "      case _sp_fish_legacy_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_legacy_owned_sources" \
    "      case _sp_fish_metadata_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_metadata_owned_sources" \
    "      case _sp_fish_entrypoint_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_entrypoint_owned_sources" \
    "    end" \
    "    set -l _valise_fish_ledger_present 0" \
    "    set -l _valise_fish_source_present 0" \
    "    builtin set -q \$_valise_fish_ledger_name; and set _valise_fish_ledger_present 1" \
    "    builtin set -q \$_valise_fish_source_ledger_name; and set _valise_fish_source_present 1" \
    "    if builtin test \$_valise_fish_ledger_present -ne \$_valise_fish_source_present" \
    "      set _valise_fish_ledger_invalid 1" \
    "    else if builtin test \$_valise_fish_ledger_present -eq 1" \
    "      set -l _valise_fish_owned_names \$\$_valise_fish_ledger_name" \
    "      set -l _valise_fish_owned_sources \$\$_valise_fish_source_ledger_name" \
    "      if builtin test (builtin count \$_valise_fish_owned_names) -ne (builtin count \$_valise_fish_owned_sources)" \
    "        set _valise_fish_ledger_invalid 1" \
    "      else" \
    "        set -l _valise_fish_owned_index 1" \
    "        for _valise_fish_owned_source in \$_valise_fish_owned_sources" \
    "          set -l _valise_fish_source_valid 0" \
    "          if builtin string match -q 'embedded:*' -- \"\$_valise_fish_owned_source\"; or builtin string match -q 'autoloaded:*' -- \"\$_valise_fish_owned_source\"; or builtin string match -q 'builtin' -- \"\$_valise_fish_owned_source\"" \
    "            set _valise_fish_source_valid 1" \
    "          else if builtin test \"\$_valise_fish_source_tree_mode\" = 1; and builtin test -f \"\$_valise_fish_owned_source\"" \
    "            set -l _valise_fish_source_canonical (builtin path resolve -- \"\$_valise_fish_owned_source\" 2>/dev/null)" \
    "            if builtin string match -q \"\$_valise_fish_trusted_root/*\" -- \"\$_valise_fish_source_canonical\"" \
    "              set _valise_fish_source_valid 1" \
    "            else if builtin test -n \"\$_valise_fish_previous_root\"; and builtin string match -q \"\$_valise_fish_previous_root/*\" -- \"\$_valise_fish_source_canonical\"" \
    "              set _valise_fish_source_valid 1" \
    "            end" \
    "          else if builtin test \"\$_valise_fish_source_tree_mode\" != 1" \
    "            set -l _valise_fish_source_relative ''" \
    "            if builtin string match -q '*/entrypoints/fish/profile.fish' -- \"\$_valise_fish_owned_source\"" \
    "              set _valise_fish_source_relative entrypoints/fish/profile.fish" \
    "            else if builtin string match -q '*/vendor/shell-profile/lib/fish/loader.fish' -- \"\$_valise_fish_owned_source\"; or builtin string match -q '*/vendor/shell-profile/lib/fish/metadata.fish' -- \"\$_valise_fish_owned_source\"" \
    "              if builtin string match -q '*/loader.fish' -- \"\$_valise_fish_owned_source\"; set _valise_fish_source_relative vendor/shell-profile/lib/fish/loader.fish; else; set _valise_fish_source_relative vendor/shell-profile/lib/fish/metadata.fish; end" \
    "            else if builtin string match -q '*/generated/installed-modules.fish' -- \"\$_valise_fish_owned_source\"" \
    "              set _valise_fish_source_relative generated/installed-modules.fish" \
    "            end" \
    "            if builtin test -n \"\$_valise_fish_source_relative\"; and builtin test (builtin path resolve -- \"\$_valise_fish_owned_source\") = (builtin path resolve -- \"\$_valise_fish_trusted_root/\$_valise_fish_source_relative\")" \
    "              set _valise_fish_source_valid 1" \
    "            end" \
    "          end" \
    "          if builtin test \$_valise_fish_source_valid -ne 1" \
    "            set _valise_fish_ledger_invalid 1" \
    "            break" \
    "          end" \
    "          set _valise_fish_owned_index (builtin math \$_valise_fish_owned_index + 1)" \
    "        end" \
    "      end" \
    "    end" \
    "  end" \
    "  if builtin test \$_valise_fish_ledger_invalid -ne 0" \
    "    for _valise_fish_ledger_name in _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_legacy_owned_exports _sp_fish_legacy_owned_sources _sp_fish_metadata_owned_exports _sp_fish_metadata_owned_sources _sp_fish_entrypoint_owned_exports _sp_fish_entrypoint_owned_sources" \
    "      if builtin set -q -g \"\$_valise_fish_ledger_name\"; and not builtin set -e -g \"\$_valise_fish_ledger_name\"; builtin exit 125; end" \
    "      if builtin set -q -U \"\$_valise_fish_ledger_name\"; and not builtin set -e -U \"\$_valise_fish_ledger_name\"; builtin exit 125; end" \
    "    end" \
    "    builtin printf '%s\n' 'valise Fish integration: ownership ledger is not authenticated' >&2" \
    "    return 125" \
    "  end" \
    "  for _valise_fish_ledger_name in _sp_fish_loader_owned_exports _sp_fish_legacy_owned_exports _sp_fish_metadata_owned_exports _sp_fish_entrypoint_owned_exports" \
    "    set -l _valise_fish_source_ledger_name ''" \
    "    switch \"\$_valise_fish_ledger_name\"" \
    "      case _sp_fish_loader_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_loader_owned_sources" \
    "      case _sp_fish_legacy_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_legacy_owned_sources" \
    "      case _sp_fish_metadata_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_metadata_owned_sources" \
    "      case _sp_fish_entrypoint_owned_exports" \
    "        set _valise_fish_source_ledger_name _sp_fish_entrypoint_owned_sources" \
    "    end" \
    "    if builtin set -q \"\$_valise_fish_ledger_name\"; and builtin set -q \"\$_valise_fish_source_ledger_name\"" \
    "      set -l _valise_fish_owned_index 1" \
    "      for _valise_fish_owned_function in \$\$_valise_fish_ledger_name" \
    "        set -l _valise_fish_owned_sources \$\$_valise_fish_source_ledger_name" \
    "        set -l _valise_fish_owned_source \$_valise_fish_owned_sources[\$_valise_fish_owned_index]" \
    "        if test -n \"\$_valise_fish_owned_source\"; and builtin functions -q \"\$_valise_fish_owned_function\"; and builtin test (builtin functions --details \"\$_valise_fish_owned_function\") = \"\$_valise_fish_owned_source\"" \
    "          builtin functions -e \"\$_valise_fish_owned_function\"; or builtin exit 125" \
    "        end" \
    "        set _valise_fish_owned_index (builtin math \$_valise_fish_owned_index + 1)" \
    "      end" \
    "    end" \
    "    if builtin set -q -g \"\$_valise_fish_ledger_name\"; and not builtin set -e -g \"\$_valise_fish_ledger_name\"; builtin exit 125; end" \
    "    if builtin set -q -U \"\$_valise_fish_ledger_name\"; and not builtin set -e -U \"\$_valise_fish_ledger_name\"; builtin exit 125; end" \
    "    if builtin set -q -g \"\$_valise_fish_source_ledger_name\"; and not builtin set -e -g \"\$_valise_fish_source_ledger_name\"; builtin exit 125; end" \
    "    if builtin set -q -U \"\$_valise_fish_source_ledger_name\"; and not builtin set -e -U \"\$_valise_fish_source_ledger_name\"; builtin exit 125; end" \
    "  end" \
    "  return 0" \
    "end" \
    "set -l _valise_fish_owned_cleanup_definition (builtin functions \"\$_valise_fish_owned_cleanup\" | string collect)" \
    "if test (builtin count \"\$_valise_fish_owned_cleanup_definition\") -ne 1" \
    "  printf '%s\\n' 'valise Fish integration: trusted ownership cleanup snapshot unavailable' >&2" \
    "  return 125" \
    "end" \
    "if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "  builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "  builtin exit 125" \
    "end" \
    "\$_valise_fish_owned_cleanup \"\$_valise_fish_active_root\" \"\$_valise_fish_source_tree_mode\"" \
    "set -l _valise_fish_owned_cleanup_status \$status" \
    "if test \$_valise_fish_owned_cleanup_status -ne 0" \
    "  return \$_valise_fish_owned_cleanup_status" \
    "end" \
    "set -l _valise_fish_legacy_activation_before (builtin functions --all --names)" \
    "if test -z \"\$_valise_fish_active_root\"; or not builtin test -d \"\$_valise_fish_active_root\"" \
    "  printf '%s\\n' 'valise Fish integration: active release path cannot be resolved' >&2" \
    "  if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "    builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "    builtin exit 125" \
    "  end" \
    "  \$_valise_fish_owned_cleanup" \
    "  builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "  if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "    builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "    builtin exit 125" \
    "  end" \
    "  \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "  return 1" \
    "end" \
    "if test \"\$_valise_fish_source_tree_mode\" != 1" \
    "  set -l _valise_fish_reverified_root (${_fish_cli_literal} release verify --print-root 2>/dev/null)" \
    "  if not test -x ${_fish_cli_literal}; or not test \"\$_valise_fish_reverified_root\" = \"\$_valise_fish_active_root\"" \
    "    printf '%s\\n' 'valise Fish integration: active release authentication failed' >&2" \
    "    if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "      builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_owned_cleanup" \
    "    if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "    return 1" \
    "  end" \
    "end" \
    "if test -e \"\$_valise_fish_active_root/entrypoints/fish/profile.fish\"" \
    "  set -l _valise_fish_entrypoint_runner __valise_fish_entrypoint_runner_(builtin random)" \
    "  function \$_valise_fish_entrypoint_runner" \
    "    set -l _entrypoint_file \$argv[1]" \
    "    set -l _entrypoint_expected_root \$argv[2]" \
    "    set -l _entrypoint_source_tree_mode \$argv[3]" \
    "    set -l _entrypoint_transaction_name (builtin status function)" \
    "    set -l _entrypoint_before (builtin functions --all --names)" \
    "    set -l _entrypoint_critical_names contains test string source path functions set printf echo math count eval cd pwd" \
    "    set -l _entrypoint_snapshot_names" \
    "    set -l _entrypoint_snapshot_definitions" \
    "    set -l _entrypoint_snapshot_sources" \
    "    for _entrypoint_function in \$_entrypoint_before" \
    "      if test \"\$_entrypoint_function\" = \"\$_entrypoint_transaction_name\"; or not builtin functions -q \"\$_entrypoint_function\"" \
    "        continue" \
    "      end" \
    "      set -l _entrypoint_source (builtin functions --details \"\$_entrypoint_function\")" \
    "      if not builtin contains -- \"\$_entrypoint_function\" \$_entrypoint_critical_names; and builtin string match -q -r '^(embedded:|autoloaded:|builtin)' -- \"\$_entrypoint_source\"" \
    "        continue" \
    "      end" \
    "      set -a _entrypoint_snapshot_names \"\$_entrypoint_function\"" \
    "      set -a _entrypoint_snapshot_definitions (builtin functions \"\$_entrypoint_function\" | string collect)" \
    "      set -a _entrypoint_snapshot_sources \"\$_entrypoint_source\"" \
    "    end" \
    "    set -l _entrypoint_source_helper __valise_fish_entrypoint_source_(builtin random)" \
    "    function \$_entrypoint_source_helper" \
    "      builtin source \"\$argv[1]\"" \
    "      return \$status" \
    "    end" \
    "    \$_entrypoint_source_helper \"\$_entrypoint_file\"" \
    "    set -l _entrypoint_status \$status" \
    "    builtin functions -e \$_entrypoint_source_helper 2>/dev/null" \
    "    set -l _entrypoint_after (builtin functions --all --names)" \
    "    set -l _entrypoint_created" \
    "    for _entrypoint_function in \$_entrypoint_after" \
    "      if not builtin contains -- \"\$_entrypoint_function\" \$_entrypoint_before" \
    "        set -a _entrypoint_created \"\$_entrypoint_function\"" \
    "      end" \
    "    end" \
    "    set -l _entrypoint_replaced" \
    "    set -l _entrypoint_snapshot_index 1" \
    "    for _entrypoint_original in \$_entrypoint_snapshot_names" \
    "      set -l _entrypoint_saved \"\$_entrypoint_snapshot_definitions[\$_entrypoint_snapshot_index]\"" \
    "      set -l _entrypoint_live (builtin functions \"\$_entrypoint_original\" | string collect)" \
    "      if not builtin functions -q \"\$_entrypoint_original\"; or not test \"\$_entrypoint_live\" = \"\$_entrypoint_saved\"" \
    "        set -a _entrypoint_replaced \"\$_entrypoint_original\"" \
    "      end" \
    "      set _entrypoint_snapshot_index (builtin math \$_entrypoint_snapshot_index + 1)" \
    "    end" \
    "    set -l _entrypoint_embedded_replaced" \
    "    set _entrypoint_snapshot_index 1" \
    "    for _entrypoint_original in \$_entrypoint_snapshot_names" \
    "      if builtin contains -- \"\$_entrypoint_original\" \$_entrypoint_replaced; and builtin string match -q 'embedded:*' -- \"\$_entrypoint_snapshot_sources[\$_entrypoint_snapshot_index]\"" \
    "        set _entrypoint_embedded_replaced \"\$_entrypoint_original\"" \
    "        break" \
    "      end" \
    "      set _entrypoint_snapshot_index (builtin math \$_entrypoint_snapshot_index + 1)" \
    "    end" \
    "    if test -n \"\$_entrypoint_embedded_replaced\"" \
    "      builtin printf 'valise Fish integration: embedded Fish function was mutated: %s\\n' \"\$_entrypoint_embedded_replaced\" >&2" \
    "      test \$_entrypoint_status -ne 0; or set _entrypoint_status 125" \
    "    end" \
    "    if not test \"\$_entrypoint_expected_root\" = \"\$SHELL_PROJECT_ROOT\"" \
    "      test \$_entrypoint_status -ne 0; or set _entrypoint_status 1" \
    "    end" \
    "    if not builtin set -q VALISE_FISH_READY; or not test (builtin count \$VALISE_FISH_READY) -eq 1; or not string match -qr '^1\$' -- \"\$VALISE_FISH_READY\"" \
    "      test \$_entrypoint_status -ne 0; or set _entrypoint_status 1" \
    "    end" \
    "    if test \$_entrypoint_source_tree_mode = 1" \
    "      set -l _entrypoint_protected_names _sp_fish_loader_expected_source _sp_fish_metadata_expected_source _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status _sp_fish_loaded_modules _sp_fish_module_roots _sp_fish_metadata_provider _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_legacy_owned_exports _sp_fish_legacy_owned_sources _sp_fish_metadata_owned_exports _sp_fish_metadata_owned_sources _sp_fish_entrypoint_owned_exports _sp_fish_entrypoint_owned_sources" \
    "      set -l _entrypoint_protected_changed 0" \
    "      for _entrypoint_protected_name in \$_entrypoint_protected_names" \
    "        if builtin set -q -g \"\$_entrypoint_protected_name\"; or builtin set -q -U \"\$_entrypoint_protected_name\"" \
    "          set _entrypoint_protected_changed 1" \
    "          if builtin set -q -g \"\$_entrypoint_protected_name\"; and not builtin set -e -g \"\$_entrypoint_protected_name\"; builtin exit 125; end" \
    "          if builtin set -q -U \"\$_entrypoint_protected_name\"; and not builtin set -e -U \"\$_entrypoint_protected_name\"; builtin exit 125; end" \
    "        end" \
    "      end" \
    "      if test \$_entrypoint_protected_changed -ne 0; and test \$_entrypoint_status -eq 0" \
    "        set _entrypoint_status 1" \
    "      end" \
    "    end" \
    "    # The entrypoint is selected only after release verify authenticates its" \
    "    # immutable release. Its native metadata/loader state is therefore an" \
    "    # intentional result of authenticated activation, not caller mutation." \
    "    # Keep the exact caller-function and embedded-function checks above; those" \
    "    # are the custody boundary for this source transaction." \
    "    if test \$_entrypoint_status -ne 0; or test (builtin count \$_entrypoint_replaced) -ne 0" \
    "      for _entrypoint_function in \$_entrypoint_created" \
    "        if builtin functions -q \"\$_entrypoint_function\"" \
    "          builtin functions -e \"\$_entrypoint_function\"; or builtin exit 125" \
    "        end" \
    "      end" \
    "      if test (builtin count \$_entrypoint_replaced) -ne 0" \
    "        builtin printf '%s\\n' 'valise Fish integration: exact caller-function restoration is unavailable' >&2" \
    "        builtin exit 125" \
    "      end" \
    "    if builtin set -q -g VALISE_FISH_READY; and not builtin set -e -g VALISE_FISH_READY; builtin exit 125; end" \
    "    if builtin set -q -U VALISE_FISH_READY; and not builtin set -e -U VALISE_FISH_READY; builtin exit 125; end" \
    "      if test (builtin count \$_entrypoint_replaced) -ne 0; and test \$_entrypoint_status -eq 0" \
    "        set _entrypoint_status 1" \
    "      end" \
    "      return \$_entrypoint_status" \
    "    end" \
    "    # Publish only functions created by this authenticated entrypoint. The" \
    "    # source string is read back from Fish after sourcing; callers cannot" \
    "    # claim ownership by forging names or a parallel source ledger." \
    "    set -l _entrypoint_owned_sources" \
    "    for _entrypoint_function in \$_entrypoint_created" \
    "      if not builtin functions -q \"\$_entrypoint_function\"" \
    "        builtin printf '%s\\n' 'valise Fish integration: created entrypoint function disappeared before ownership publication' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      set -l _entrypoint_source (builtin functions --details \"\$_entrypoint_function\")" \
    "      if test -z \"\$_entrypoint_source\"" \
    "        builtin printf '%s\\n' 'valise Fish integration: created entrypoint function has no authenticated source' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      set -a _entrypoint_owned_sources \"\$_entrypoint_source\"" \
    "    end" \
    "    builtin set -g _sp_fish_entrypoint_owned_exports \$_entrypoint_created; or builtin exit 125" \
    "    builtin set -g _sp_fish_entrypoint_owned_sources \$_entrypoint_owned_sources; or builtin exit 125" \
    "    return 0" \
    "  end" \
    "    builtin set -gx SHELL_PROJECT_ROOT \"\$_valise_fish_active_root\"" \
    "    \$_valise_fish_entrypoint_runner \"\$_valise_fish_active_root/entrypoints/fish/profile.fish\" \"\$_valise_fish_active_root\" \"\$_valise_fish_source_tree_mode\"" \
    "    set -l _valise_fish_entrypoint_status \$status" \
    "    builtin functions -e \$_valise_fish_entrypoint_runner 2>/dev/null" \
    "    # The legacy runner is created before route selection; remove it on" \
    "    # every project-entrypoint return so it cannot leak into the caller." \
    "    builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "    if test \$_valise_fish_entrypoint_status -ne 0" \
    "      if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "        builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_owned_cleanup" \
    "      if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "        builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "      return \$_valise_fish_entrypoint_status" \
    "    end" \
    "    if not builtin functions -q \$_valise_fish_success_cleanup_helper; or not builtin test (builtin functions \$_valise_fish_success_cleanup_helper | string collect) = \"\$_valise_fish_success_cleanup_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted success cleanup helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_publish_active_helper; or builtin exit 125" \
    "    \$_valise_fish_success_cleanup_helper; or builtin exit 125" \
    "    return \$_valise_fish_entrypoint_status" \
    "else" \
    "  if test -f \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/metadata.fish\"; and test -f \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/loader.fish\"" \
    "  builtin set -gx SHELL_PROJECT_ROOT \"\$_valise_fish_active_root\"" \
    "  builtin set -g _sp_fish_loader_expected_source \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/loader.fish\"" \
    "  builtin set -g _sp_fish_metadata_expected_source \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/metadata.fish\"" \
    "  # Metadata is executable Fish source; load it transactionally before the" \
    "  # native loader sees its declarations. The runner serializes caller functions" \
    "  # into caller-local Fish variables and sources metadata in an isolated helper scope." \
    "  set -l _valise_fish_metadata_transaction __valise_fish_metadata_transaction_(builtin random)" \
    "  function \$_valise_fish_metadata_transaction" \
    "    set -l _metadata_runner_name (builtin status function)" \
    "    set -l _metadata_persistence_helper \$argv[2]" \
    "    set -l _metadata_persistence_definition \$argv[3]" \
    "    set -l _metadata_persistence_durable_file \$argv[4]" \
    "    set -l _metadata_persistence_tmp_parent \$argv[5]" \
    "    set -l _metadata_expected_source ''" \
    "    if builtin set -q _sp_fish_metadata_expected_source" \
    "      set _metadata_expected_source \$_sp_fish_metadata_expected_source" \
    "    end" \
    "    if test -z \"\$_metadata_expected_source\"; or not builtin test \"\$argv[1]\" = \"\$_metadata_expected_source\"" \
    "      builtin printf '%s\\n' 'metadata source is not the authenticated expected source' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    set -l _metadata_before (builtin functions --all --names)" \
    "    set -l _metadata_snapshot_names" \
    "    set -l _metadata_snapshot_definitions" \
    "    set -l _metadata_snapshot_sources" \
    "    set -l _metadata_snapshot_copy_sources" \
    "    set -l _metadata_snapshot_copies" \
    "    set -l _metadata_snapshot_nonce (builtin random)" \
    "    set -l _metadata_critical_names contains test string source path functions set printf echo math count eval cd pwd" \
    "    set -l _metadata_snapshot_status 0" \
    "    set -l _metadata_snapshot_index 1" \
    "    for _metadata_function in \$_metadata_before" \
    "      if test \"\$_metadata_function\" = \"\$_metadata_runner_name\"; or not builtin functions -q \"\$_metadata_function\"" \
    "        continue" \
    "      end" \
    "      set -l _metadata_source (builtin functions --details \"\$_metadata_function\")" \
    "      if builtin string match -q -r '^(autoloaded:|embedded:|builtin)' -- \"\$_metadata_source\"" \
    "        continue" \
    "      end" \
    "      set -l _metadata_definition (builtin functions \"\$_metadata_function\" | string collect)" \
    "      if test (builtin count \$_metadata_definition) -ne 1" \
    "        set _metadata_snapshot_status 125" \
    "        break" \
    "      end" \
    "      set -a _metadata_snapshot_names \"\$_metadata_function\"" \
    "      set -a _metadata_snapshot_definitions \"\$_metadata_definition\"" \
    "      set -l _metadata_snapshot_copy \"__valise_fish_metadata_snapshot_\"\$_metadata_snapshot_nonce\"_\"\$_metadata_snapshot_index" \
    "      if builtin functions -q \"\$_metadata_snapshot_copy\"; or not builtin functions --copy \"\$_metadata_function\" \"\$_metadata_snapshot_copy\"" \
    "        set _metadata_snapshot_status 125" \
    "        break" \
    "      end" \
    "      set -a _metadata_snapshot_sources \"\$_metadata_source\"" \
    "      set -a _metadata_snapshot_copy_sources (builtin functions --details \"\$_metadata_snapshot_copy\")" \
    "      set -a _metadata_snapshot_copies \"\$_metadata_snapshot_copy\"" \
    "      set _metadata_snapshot_index (builtin math \$_metadata_snapshot_index + 1)" \
    "    end" \
    "    # Preserve embedded critical definitions without copying them from inside this helper: Fish changes their provenance when copied here." \
    "    set -l _metadata_embedded_names" \
    "    set -l _metadata_embedded_sources" \
    "    set -l _metadata_critical_index 1" \
    "    for _metadata_critical_name in \$_metadata_critical_names" \
    "      if builtin functions -q \"\$_metadata_critical_name\"; and builtin string match -q 'embedded:*' -- (builtin functions --details \"\$_metadata_critical_name\")" \
    "        set -a _metadata_embedded_names \"\$_metadata_critical_name\"" \
    "        set -a _metadata_embedded_sources (builtin functions --details \"\$_metadata_critical_name\")" \
    "      end" \
    "      set _metadata_critical_index (builtin math \$_metadata_critical_index + 1)" \
    "    end" \
    "    # Metadata is executable Fish source. Keep the handshake, root, and" \
    "    # loader-private state transactional as well as its function namespace." \
    "    set -l _metadata_protected_names SHELL_PROJECT_ROOT VALISE_FISH_READY _sp_fish_loader_expected_source _sp_fish_metadata_expected_source _sp_fish_loader_bootstrap_mode _sp_fish_loader_bootstrap_seeds _sp_fish_loader_bootstrap_status _sp_fish_loaded_modules _sp_fish_module_roots _sp_fish_metadata_provider _sp_fish_loader_owned_exports _sp_fish_loader_owned_sources _sp_fish_legacy_owned_exports _sp_fish_legacy_owned_sources _sp_fish_metadata_owned_exports _sp_fish_metadata_owned_sources _sp_fish_entrypoint_owned_exports _sp_fish_entrypoint_owned_sources XDG_CONFIG_HOME TMPDIR HOME" \
    "    set -l _metadata_protected_prefix __valise_fish_metadata_state_(builtin random)" \
    "    set -l _metadata_capture_helper __valise_fish_metadata_capture_(builtin random)" \
    "    # Predeclare every capture slot in this transaction's local scope. The" \
    "    # The trusted capture helper writes into this transaction's local slots; metadata source" \
    "    # cannot enumerate or forge them as global rollback state." \
    "    for _metadata_slot_name in \$_metadata_protected_names" \
    "      for _metadata_slot_suffix in global_present global_exported global_values universal_present universal_exported universal_values" \
    "        set -f \"\$_metadata_protected_prefix\"_before_\"\$_metadata_slot_name\"_\"\$_metadata_slot_suffix\"" \
    "        set -f \"\$_metadata_protected_prefix\"_after_\"\$_metadata_slot_name\"_\"\$_metadata_slot_suffix\"" \
    "      end" \
    "    end" \
    "    function \$_metadata_capture_helper --no-scope-shadowing" \
    "      set -l _scope_name \$argv[1]" \
    "      set -l _scope_prefix \$argv[2]_\$_scope_name" \
    "      set -l _global_present 0" \
    "      builtin set -q -g \"\$_scope_name\"; and set _global_present 1" \
    "      set -l _global_exported 0" \
    "      builtin set -q -gx \"\$_scope_name\"; and set _global_exported 1" \
    "      set -l _global_values" \
    "      if test \$_global_present -eq 1" \
    "        set _global_values \$\$_scope_name" \
    "      end" \
    "      set -l _universal_present 0" \
    "      builtin set -q -U \"\$_scope_name\"; and set _universal_present 1" \
    "      set -l _universal_exported 0" \
    "      builtin set -q -Ux \"\$_scope_name\"; and set _universal_exported 1" \
    "      set -l _universal_values" \
    "      if test \$_universal_present -eq 1" \
    "        if test \$_global_present -eq 1" \
    "          builtin set -e -g \"\$_scope_name\"" \
    "          set _universal_values \$\$_scope_name" \
    "          set -l _restore_global_flags -g" \
    "          if test \$_global_exported -eq 1" \
    "            set _restore_global_flags -gx" \
    "          end" \
    "          builtin set \$_restore_global_flags \"\$_scope_name\" \$_global_values" \
    "          if test \$status -ne 0" \
    "            builtin exit 125" \
    "          end" \
    "        else" \
    "          set _universal_values \$\$_scope_name" \
    "        end" \
    "      end" \
    "      set \"\$_scope_prefix\"_global_present \$_global_present" \
    "      set \"\$_scope_prefix\"_global_exported \$_global_exported" \
    "      set \"\$_scope_prefix\"_global_values \$_global_values" \
    "      set \"\$_scope_prefix\"_universal_present \$_universal_present" \
    "      set \"\$_scope_prefix\"_universal_exported \$_universal_exported" \
    "      set \"\$_scope_prefix\"_universal_values \$_universal_values" \
    "    end" \
    "    set -l _metadata_restore_helper __valise_fish_metadata_restore_(builtin random)" \
    "    function \$_metadata_restore_helper --no-scope-shadowing" \
    "      set -l _restore_name \$argv[1]" \
    "      set -l _restore_prefix \$argv[2]_\$argv[1]" \
    "      set -l _expected_persistence_helper \$argv[3]" \
    "      set -l _expected_persistence_definition \$argv[4]" \
    "      set -l _global_present_var \"\$_restore_prefix\"_global_present" \
    "      set -l _global_exported_var \"\$_restore_prefix\"_global_exported" \
    "      set -l _global_values_var \"\$_restore_prefix\"_global_values" \
    "      set -l _universal_present_var \"\$_restore_prefix\"_universal_present" \
    "      set -l _universal_exported_var \"\$_restore_prefix\"_universal_exported" \
    "      set -l _universal_values_var \"\$_restore_prefix\"_universal_values" \
    "      set -l _expected_global_present \$\$_global_present_var" \
    "      set -l _expected_global_exported \$\$_global_exported_var" \
    "      set -l _expected_global_values \$\$_global_values_var" \
    "      set -l _expected_universal_present \$\$_universal_present_var" \
    "      set -l _expected_universal_exported \$\$_universal_exported_var" \
    "      set -l _expected_universal_values \$\$_universal_values_var" \
    "" \
    "      # Every persistent erase/set is conditional or checked. An absent scope" \
    "      # is an expected before-image, not a failed erase operation." \
    "      if not builtin functions -q \$_expected_persistence_helper; or not builtin test (builtin functions \$_expected_persistence_helper | string collect) = \"\$_expected_persistence_definition\"" \
    "        builtin printf '%s\\n' 'trusted universal persistence verifier was modified' >&2" \
    "        return 125" \
    "      end" \
    "      if builtin set -q -g \"\$_restore_name\"" \
    "        builtin set -e -g \"\$_restore_name\"; or return 125" \
    "      end" \
    "      if builtin set -q -U \"\$_restore_name\"" \
    "        builtin set -e -U \"\$_restore_name\"; or return 125" \
    "      end" \
    "      # Restore universal before recreating a global shadow so Fish can read the" \
    "      # universal before-image without a false mutation failure." \
    "      if test \"\$_expected_universal_present\" = 1" \
    "         set -l _restore_universal_flags -U" \
    "         if test \"\$_expected_universal_exported\" = 1" \
    "           set _restore_universal_flags -Ux" \
    "         end" \
    "         builtin set \$_restore_universal_flags \"\$_restore_name\" \$_expected_universal_values" \
    "         if test \$status -ne 0" \
    "           return 125" \
    "         end" \
    "      end" \
    "      \$_expected_persistence_helper \"\$_metadata_persistence_durable_file\" \"\$_metadata_persistence_tmp_parent\" \"\$_restore_name\" \"\$_expected_universal_present\" \"\$_expected_universal_exported\" \$_expected_universal_values; or return 125" \
    "      if test \"\$_expected_global_present\" = 1" \
    "         set -l _restore_global_flags -g" \
    "         if test \"\$_expected_global_exported\" = 1" \
    "           set _restore_global_flags -gx" \
    "         end" \
    "         builtin set \$_restore_global_flags \"\$_restore_name\" \$_expected_global_values" \
    "         if test \$status -ne 0" \
    "           return 125" \
    "         end" \
    "      end" \
    "      # Verify global presence/export/value exactly before inspecting the" \
    "      # universal binding hidden by a global binding." \
    "      set -l _actual_global_present 0" \
    "      builtin set -q -g \"\$_restore_name\"; and set _actual_global_present 1" \
    "      set -l _actual_global_exported 0" \
    "      builtin set -q -gx \"\$_restore_name\"; and set _actual_global_exported 1" \
    "      set -l _actual_global_values" \
    "      if test \"\$_actual_global_present\" = 1" \
    "        set _actual_global_values \$\$_restore_name" \
    "      end" \
    "      if test \"\$_actual_global_present\" != \"\$_expected_global_present\"; or test \"\$_actual_global_exported\" != \"\$_expected_global_exported\"; or test (builtin count \$_actual_global_values) -ne (builtin count \$_expected_global_values)" \
    "        return 125" \
    "      end" \
    "      set -l _value_index 1" \
    "      while test \$_value_index -le (builtin count \$_expected_global_values)" \
    "        if not builtin test \"\$_expected_global_values[\$_value_index]\" = \"\$_actual_global_values[\$_value_index]\"" \
    "          return 125" \
    "        end" \
    "        builtin set _value_index (builtin math \$_value_index + 1)" \
    "      end" \
    "" \
    "      set -l _hid_global 0" \
    "      if builtin set -q -g \"\$_restore_name\"" \
    "        builtin set -e -g \"\$_restore_name\"; or return 125" \
    "        set _hid_global 1" \
    "      end" \
    "      set -l _actual_universal_present 0" \
    "      builtin set -q -U \"\$_restore_name\"; and set _actual_universal_present 1" \
    "      set -l _actual_universal_exported 0" \
    "      builtin set -q -Ux \"\$_restore_name\"; and set _actual_universal_exported 1" \
    "      set -l _actual_universal_values" \
    "      if test \"\$_actual_universal_present\" = 1" \
    "        set _actual_universal_values \$\$_restore_name" \
    "      end" \
    "      if test \"\$_actual_universal_present\" != \"\$_expected_universal_present\"; or test \"\$_actual_universal_exported\" != \"\$_expected_universal_exported\"; or test (builtin count \$_actual_universal_values) -ne (builtin count \$_expected_universal_values)" \
    "        if test \$_hid_global -eq 1" \
    "           set -l _restore_global_flags -g" \
    "           if test \"\$_expected_global_exported\" = 1" \
    "             set _restore_global_flags -gx" \
    "           end" \
    "           builtin set \$_restore_global_flags \"\$_restore_name\" \$_expected_global_values" \
    "           if test \$status -ne 0" \
    "             return 125" \
    "           end" \
    "        end" \
    "        return 125" \
    "      end" \
    "      set _value_index 1" \
    "      while test \$_value_index -le (builtin count \$_expected_universal_values)" \
    "        if not builtin test \"\$_expected_universal_values[\$_value_index]\" = \"\$_actual_universal_values[\$_value_index]\"" \
    "          if test \$_hid_global -eq 1" \
    "             set -l _restore_global_flags -g" \
    "             if test \"\$_expected_global_exported\" = 1" \
    "               set _restore_global_flags -gx" \
    "             end" \
    "             builtin set \$_restore_global_flags \"\$_restore_name\" \$_expected_global_values" \
    "             if test \$status -ne 0" \
    "               return 125" \
    "             end" \
    "          end" \
    "          return 125" \
    "        end" \
    "        builtin set _value_index (builtin math \$_value_index + 1)" \
    "      end" \
    "      if test \$_hid_global -eq 1" \
    "         set -l _restore_global_flags -g" \
    "         if test \"\$_expected_global_exported\" = 1" \
    "           set _restore_global_flags -gx" \
    "         end" \
    "         builtin set \$_restore_global_flags \"\$_restore_name\" \$_expected_global_values" \
    "         if test \$status -ne 0" \
    "           return 125" \
    "         end" \
    "      end" \
    "" \
    "      # The global binding was restored after universal inspection. Verify it" \
    "      # once more so the completed rollback has an exact before-image." \
    "      set _actual_global_present 0" \
    "      builtin set -q -g \"\$_restore_name\"; and set _actual_global_present 1" \
    "      set _actual_global_exported 0" \
    "      builtin set -q -gx \"\$_restore_name\"; and set _actual_global_exported 1" \
    "      set _actual_global_values" \
    "      if test \"\$_actual_global_present\" = 1" \
    "        set _actual_global_values \$\$_restore_name" \
    "      end" \
    "      if test \"\$_actual_global_present\" != \"\$_expected_global_present\"; or test \"\$_actual_global_exported\" != \"\$_expected_global_exported\"; or test (builtin count \$_actual_global_values) -ne (builtin count \$_expected_global_values)" \
    "        return 125" \
    "      end" \
    "      set _value_index 1" \
    "      while test \$_value_index -le (builtin count \$_expected_global_values)" \
    "        if not builtin test \"\$_expected_global_values[\$_value_index]\" = \"\$_actual_global_values[\$_value_index]\"" \
    "          return 125" \
    "        end" \
    "        builtin set _value_index (builtin math \$_value_index + 1)" \
    "      end" \
    "      return 0" \
    "    end" \
    "    set -l _metadata_capture_definition (builtin functions \"\$_metadata_capture_helper\" | string collect)" \
    "    set -l _metadata_restore_definition (builtin functions \"\$_metadata_restore_helper\" | string collect)" \
    "    if test (builtin count \$_metadata_capture_definition) -ne 1; or test (builtin count \$_metadata_restore_definition) -ne 1" \
    "      set _metadata_snapshot_status 125" \
    "    end" \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      for _metadata_protected_name in \$_metadata_protected_names" \
    "        \$_metadata_capture_helper \"\$_metadata_protected_name\" \"\$_metadata_protected_prefix\"_before" \
    "      end" \
    "    end" \
    "    set -l _metadata_source_helper __valise_fish_metadata_source_(builtin random)" \
    "    set -l _metadata_status 0" \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      function \$_metadata_source_helper" \
    "        builtin source \"\$argv[1]\"" \
    "        return \$status" \
    "      end" \
    "      \$_metadata_source_helper \"\$argv[1]\"" \
    "      set _metadata_status \$status" \
    "      builtin functions -e \$_metadata_source_helper 2>/dev/null" \
    "    else" \
    "      set -l _metadata_status \$_metadata_snapshot_status" \
    "    end" \
    "    set -l _metadata_protected_changed 0" \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      if not builtin functions -q \$_metadata_capture_helper; or not builtin test (builtin functions \$_metadata_capture_helper | string collect) = \"\$_metadata_capture_definition\"" \
    "        builtin printf '%s\\n' 'metadata capture helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      if not builtin functions -q \$_metadata_restore_helper; or not builtin test (builtin functions \$_metadata_restore_helper | string collect) = \"\$_metadata_restore_definition\"" \
    "        builtin printf '%s\\n' 'metadata restore helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      for _metadata_protected_name in \$_metadata_protected_names" \
    "        \$_metadata_capture_helper \"\$_metadata_protected_name\" \"\$_metadata_protected_prefix\"_after" \
    "      end" \
    "      builtin functions -e \$_metadata_capture_helper 2>/dev/null" \
    "      for _metadata_protected_name in \$_metadata_protected_names" \
    "        set -l _metadata_before_prefix \"\$_metadata_protected_prefix\"_before_\$_metadata_protected_name" \
    "        set -l _metadata_after_prefix \"\$_metadata_protected_prefix\"_after_\$_metadata_protected_name" \
    "        for _metadata_scope in global universal" \
    "          set -l _metadata_before_present_var \"\$_metadata_before_prefix\"_\"\$_metadata_scope\"_present" \
    "          set -l _metadata_after_present_var \"\$_metadata_after_prefix\"_\"\$_metadata_scope\"_present" \
    "          set -l _metadata_before_exported_var \"\$_metadata_before_prefix\"_\"\$_metadata_scope\"_exported" \
    "          set -l _metadata_after_exported_var \"\$_metadata_after_prefix\"_\"\$_metadata_scope\"_exported" \
    "          set -l _metadata_before_values_var \"\$_metadata_before_prefix\"_\"\$_metadata_scope\"_values" \
    "          set -l _metadata_after_values_var \"\$_metadata_after_prefix\"_\"\$_metadata_scope\"_values" \
    "          if not test \$\$_metadata_before_present_var = \$\$_metadata_after_present_var; or not test \$\$_metadata_before_exported_var = \$\$_metadata_after_exported_var" \
    "            set _metadata_protected_changed 1" \
    "          else if test (builtin count \$\$_metadata_before_values_var) -ne (builtin count \$\$_metadata_after_values_var)" \
    "            set _metadata_protected_changed 1" \
    "          else" \
    "            set -l _metadata_value_index 1" \
    "            while test \$_metadata_value_index -le (builtin count \$\$_metadata_before_values_var)" \
    "              if not test \"\$\$_metadata_before_values_var[\$_metadata_value_index]\" = \"\$\$_metadata_after_values_var[\$_metadata_value_index]\"" \
    "                set _metadata_protected_changed 1" \
    "                break" \
    "              end" \
    "              set _metadata_value_index (builtin math \$_metadata_value_index + 1)" \
    "            end" \
    "          end" \
    "        end" \
    "      end" \
    "    end" \
    "    set -l _metadata_after (builtin functions --all --names)" \
    "    set -l _metadata_created" \
    "    for _metadata_function in \$_metadata_after" \
    "      if not builtin contains -- \"\$_metadata_function\" \$_metadata_before" \
    "        if not builtin contains -- \"\$_metadata_function\" \$_metadata_snapshot_copies" \
    "          set -a _metadata_created \"\$_metadata_function\"" \
    "        end" \
    "      end" \
    "    end" \
    "    set -l _metadata_critical_created" \
    "    for _metadata_function in \$_metadata_created" \
    "      if builtin contains -- \"\$_metadata_function\" \$_metadata_critical_names" \
    "        set -a _metadata_critical_created \"\$_metadata_function\"" \
    "      end" \
    "    end" \
    "    set -l _metadata_embedded_replaced" \
    "    set -l _metadata_embedded_index 1" \
    "    for _metadata_embedded_name in \$_metadata_embedded_names" \
    "      if not builtin functions -q \"\$_metadata_embedded_name\"; or not builtin test (builtin functions --details \"\$_metadata_embedded_name\") = \"\$_metadata_embedded_sources[\$_metadata_embedded_index]\"" \
    "        set -a _metadata_embedded_replaced \"\$_metadata_embedded_name\"" \
    "      end" \
    "      set _metadata_embedded_index (builtin math \$_metadata_embedded_index + 1)" \
    "    end" \
    "    if builtin functions -q cd" \
    "      set -l _metadata_cd_source (builtin functions --details cd)" \
    "      if not builtin contains -- \"\$_metadata_cd_source\" embedded:functions/cd.fish /usr/share/fish/functions/cd.fish /usr/local/share/fish/functions/cd.fish /opt/local/share/fish/functions/cd.fish /opt/homebrew/share/fish/functions/cd.fish" \
    "        set -a _metadata_embedded_replaced cd" \
    "      end" \
    "    end" \
    "    set -l _metadata_replaced" \
    "    set -l _metadata_untrusted_replaced" \
    "    set -l _metadata_snapshot_compromised 0" \
    "    # Snapshot aliases are visible Fish functions. Validate source identity and" \
    "    # the complete saved definition before trusting one for rollback." \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      set -l _metadata_snapshot_index 1" \
    "      for _metadata_function in \$_metadata_snapshot_names" \
    "        set -l _metadata_saved \"\$_metadata_snapshot_definitions[\$_metadata_snapshot_index]\"" \
    "        set -l _metadata_saved_lines (string split \\n -- \"\$_metadata_saved\")" \
    "        set -l _metadata_snapshot_copy \"\$_metadata_snapshot_copies[\$_metadata_snapshot_index]\"" \
    "        if not builtin functions -q \"\$_metadata_snapshot_copy\"" \
    "          set _metadata_snapshot_compromised 1" \
    "          break" \
    "        end" \
    "        set -l _metadata_copy_lines (string split \\n -- (builtin functions \"\$_metadata_snapshot_copy\" | string collect))" \
    "        if test (builtin functions --details \"\$_metadata_snapshot_copy\") != \"\$_metadata_snapshot_copy_sources[\$_metadata_snapshot_index]\"; or test (builtin count \$_metadata_copy_lines) -ne (builtin count \$_metadata_saved_lines)" \
    "          set _metadata_snapshot_compromised 1" \
    "          break" \
    "        end" \
    "        set -l _metadata_copy_origin (string replace -r ', copied .*' '' -- \"\$_metadata_copy_lines[1]\")" \
    "        set -l _metadata_saved_origin (string replace -r ', copied .*' '' -- \"\$_metadata_saved_lines[1]\")" \
    "        if not builtin test \"\$_metadata_copy_origin\" = \"\$_metadata_saved_origin\"" \
    "          set _metadata_snapshot_compromised 1" \
    "          break" \
    "        end" \
    "        set -l _metadata_copy_line 2" \
    "        while test \$_metadata_copy_line -le (builtin count \$_metadata_saved_lines)" \
    "          set -l _metadata_copy_expected \"\$_metadata_saved_lines[\$_metadata_copy_line]\"" \
    "          set -l _metadata_copy_actual \"\$_metadata_copy_lines[\$_metadata_copy_line]\"" \
    "          if test \$_metadata_copy_line -eq 2" \
    "            set _metadata_copy_expected (string replace -r '^function [^[:space:]]+' 'function __valise_snapshot__' -- \"\$_metadata_copy_expected\")" \
    "            set _metadata_copy_actual (string replace -r '^function [^[:space:]]+' 'function __valise_snapshot__' -- \"\$_metadata_copy_actual\")" \
    "          end" \
    "          if not builtin test \"\$_metadata_copy_actual\" = \"\$_metadata_copy_expected\"" \
    "            set _metadata_snapshot_compromised 1" \
    "            break" \
    "          end" \
    "          set _metadata_copy_line (builtin math \$_metadata_copy_line + 1)" \
    "        end" \
    "        test \$_metadata_snapshot_compromised -eq 0; or break" \
    "        set _metadata_snapshot_index (builtin math \$_metadata_snapshot_index + 1)" \
    "      end" \
    "    end" \
    "    if test \$_metadata_snapshot_compromised -ne 0" \
    "      builtin printf '%s\\n' 'valise Fish integration: metadata rollback custody was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      set -l _metadata_snapshot_index 1" \
    "      for _metadata_function in \$_metadata_snapshot_names" \
    "        set -l _metadata_saved \"\$_metadata_snapshot_definitions[\$_metadata_snapshot_index]\"" \
    "        set -l _metadata_saved_lines (string split \\n -- \"\$_metadata_saved\")" \
    "        set -l _metadata_live_lines" \
    "        set -l _metadata_changed 0" \
    "        if not builtin functions -q \"\$_metadata_function\"" \
    "          set _metadata_changed 1" \
    "        else" \
    "          set _metadata_live_lines (string split \\n -- (builtin functions \"\$_metadata_function\" | string collect))" \
    "          if test (builtin count \$_metadata_live_lines) -ne (builtin count \$_metadata_saved_lines)" \
    "            set _metadata_changed 1" \
    "          else" \
    "            set -l _metadata_line 1" \
    "            while test \$_metadata_line -le (builtin count \$_metadata_saved_lines)" \
    "              if not builtin test \"\$_metadata_saved_lines[\$_metadata_line]\" = \"\$_metadata_live_lines[\$_metadata_line]\"" \
    "                set _metadata_changed 1" \
    "                break" \
    "              end" \
    "              set _metadata_line (builtin math \$_metadata_line + 1)" \
    "            end" \
    "          end" \
    "        end" \
    "        if test \$_metadata_changed -eq 1" \
    "          set -a _metadata_replaced \"\$_metadata_function\"" \
    "          set -l _metadata_previous_owned 0" \
    "          set -l _metadata_previous_index 1" \
    "          for _metadata_previous_name in \$_sp_fish_metadata_owned_exports" \
    "            if test \"\$_metadata_previous_name\" = \"\$_metadata_function\"; and test \"\$_sp_fish_metadata_owned_sources[\$_metadata_previous_index]\" = \"\$_metadata_snapshot_sources[\$_metadata_snapshot_index]\"" \
    "              set _metadata_previous_owned 1" \
    "              break" \
    "            end" \
    "            set _metadata_previous_index (builtin math \$_metadata_previous_index + 1)" \
    "          end" \
    "          if test \$_metadata_previous_owned -eq 0" \
    "            set -a _metadata_untrusted_replaced \"\$_metadata_function\"" \
    "          end" \
    "        end" \
    "        set _metadata_snapshot_index (builtin math \$_metadata_snapshot_index + 1)" \
    "      end" \
    "    end" \
    "    # A metadata source can edit fish_variables directly without changing" \
    "    # any visible Fish binding. Verify every protected universal before" \
    "    # publishing success so that path is transactional too." \
    "    set -l _metadata_persistence_changed 0" \
    "    if test \$_metadata_snapshot_status -eq 0" \
    "      if not builtin functions -q \$_metadata_persistence_helper; or not builtin test (builtin functions \$_metadata_persistence_helper | string collect) = \"\$_metadata_persistence_definition\"" \
    "        builtin printf '%s\\n' 'metadata persistence verifier was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      for _metadata_protected_name in \$_metadata_protected_names" \
    "        set -l _metadata_after_prefix \"\$_metadata_protected_prefix\"_after_\$_metadata_protected_name" \
    "        set -l _metadata_after_present_var \"\$_metadata_after_prefix\"_universal_present" \
    "        set -l _metadata_after_exported_var \"\$_metadata_after_prefix\"_universal_exported" \
    "        set -l _metadata_after_values_var \"\$_metadata_after_prefix\"_universal_values" \
    "        \$_metadata_persistence_helper \"\$_metadata_persistence_durable_file\" \"\$_metadata_persistence_tmp_parent\" \"\$_metadata_protected_name\" \"\$\$_metadata_after_present_var\" \"\$\$_metadata_after_exported_var\" \$\$_metadata_after_values_var" \
    "        if test \$status -ne 0" \
    "          set _metadata_persistence_changed 1" \
    "          break" \
    "        end" \
    "      end" \
    "    end" \
    "    set -l _metadata_failure 0" \
    "    if test \$_metadata_snapshot_status -ne 0" \
    "      set _metadata_status \$_metadata_snapshot_status" \
    "      set _metadata_failure 1" \
    "    end" \
    "    if test \$_metadata_status -ne 0" \
    "      set _metadata_failure 1" \
    "      set _metadata_protected_changed 1" \
    "    end" \
    "    if test (builtin count \$_metadata_untrusted_replaced) -ne 0" \
    "      set _metadata_failure 1" \
    "    end" \
    "    if test (builtin count \$_metadata_embedded_replaced) -ne 0" \
    "      set _metadata_failure 1" \
    "    end" \
    "    if test \$_metadata_protected_changed -ne 0" \
    "      set _metadata_failure 1" \
    "      test \$_metadata_status -eq 0; and set _metadata_status 1" \
    "    end" \
    "    if test \$_metadata_persistence_changed -ne 0" \
    "      set _metadata_failure 1" \
    "      set _metadata_protected_changed 1" \
    "      set _metadata_status 125" \
    "    end" \
    "    if test \$_metadata_failure -ne 0" \
    "      if test \$_metadata_snapshot_status -ne 0" \
    "        builtin printf '%s\\n' 'valise Fish integration: metadata rollback snapshot unavailable' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      if test (builtin count \$_metadata_untrusted_replaced) -ne 0" \
    "        builtin printf '%s\\n' 'valise Fish integration: metadata source replaced a caller-owned function' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      if test (builtin count \$_metadata_embedded_replaced) -ne 0" \
    "        builtin printf '%s\\n' 'valise Fish integration: embedded Fish function was mutated' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      if test (builtin count \$_metadata_replaced) -ne 0" \
    "        builtin printf '%s\\n' 'valise Fish integration: exact metadata function restoration is unavailable' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      for _metadata_function in \$_metadata_created" \
    "        if not test \"\$_metadata_function\" = \"\$_metadata_restore_helper\"" \
    "          if builtin functions -q \"\$_metadata_function\"" \
    "            builtin functions -e \"\$_metadata_function\"; or builtin exit 125" \
    "          end" \
    "        end" \
    "      end" \
    "      set -l _metadata_restore_failed 0" \
    "      if test \$_metadata_protected_changed -ne 0" \
    "        for _metadata_protected_name in \$_metadata_protected_names" \
    "          \$_metadata_restore_helper \"\$_metadata_protected_name\" \"\$_metadata_protected_prefix\"_before \"\$_metadata_persistence_helper\" \"\$_metadata_persistence_definition\"" \
    "          if test \$status -ne 0" \
    "            set _metadata_restore_failed 1" \
    "          end" \
    "        end" \
    "      end" \
    "      builtin functions -e \$_metadata_restore_helper 2>/dev/null" \
    "      for _metadata_snapshot_copy in \$_metadata_snapshot_copies" \
    "        if builtin functions -q \"\$_metadata_snapshot_copy\"" \
    "          builtin functions -e \"\$_metadata_snapshot_copy\"; or builtin exit 125" \
    "        end" \
    "      end" \
    "      if test \$_metadata_restore_failed -ne 0" \
    "        set _metadata_status 125" \
    "      end" \
    "      return \$_metadata_status" \
    "    end" \
    "    for _metadata_snapshot_copy in \$_metadata_snapshot_copies" \
      "      builtin functions -q \"\$_metadata_snapshot_copy\"; and builtin functions -e \"\$_metadata_snapshot_copy\"" \
    "    end" \
    "    builtin functions -e \$_metadata_restore_helper 2>/dev/null" \
    "    builtin set -g _sp_fish_metadata_owned_exports" \
    "    builtin set -g _sp_fish_metadata_owned_sources" \
    "    for _metadata_function in \$_metadata_after" \
    "      set -l _metadata_source (builtin functions --details \"\$_metadata_function\")" \
    "      if test \"\$_metadata_source\" = \"\$_metadata_expected_source\"" \
    "        builtin set -a _sp_fish_metadata_owned_exports \"\$_metadata_function\"" \
    "        builtin set -a _sp_fish_metadata_owned_sources \"\$_metadata_source\"" \
    "      end" \
    "    end" \
    "    return \$_metadata_status" \
    "  end" \
    "  \$_valise_fish_metadata_transaction \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/metadata.fish\" \"\$_valise_fish_persistence_verify_helper\" \"\$_valise_fish_persistence_helper_definition\" \"\$_valise_fish_persistence_durable_file\" \"\$_valise_fish_persistence_tmp_parent\"" \
    "  set -l _valise_fish_metadata_status \$status" \
    "  builtin functions -e \$_valise_fish_metadata_transaction 2>/dev/null" \
    "  if test \$_valise_fish_metadata_status -ne 0" \
    "    builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "    if builtin set -q -g VALISE_FISH_READY; and not builtin set -e -g VALISE_FISH_READY; builtin exit 125; end" \
    "    if builtin set -q -U VALISE_FISH_READY; and not builtin set -e -U VALISE_FISH_READY; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_status; and not builtin set -e -g _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_status; and not builtin set -e -U _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_mode; and not builtin set -e -g _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_mode; and not builtin set -e -U _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_seeds; and not builtin set -e -g _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_seeds; and not builtin set -e -U _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "      builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_owned_cleanup" \
    "    if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "    printf 'valise Fish integration: metadata loader failed with status %d\\n' \$_valise_fish_metadata_status >&2" \
    "    return \$_valise_fish_metadata_status" \
    "  else" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_status; and not builtin set -e -g _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_status; and not builtin set -e -U _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_mode; and not builtin set -e -g _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_mode; and not builtin set -e -U _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_seeds; and not builtin set -e -g _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_seeds; and not builtin set -e -U _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    builtin set -g _sp_fish_loader_bootstrap_mode strict" \
    "    builtin set -g _sp_fish_loader_bootstrap_seeds fish_path fish_environment fish_secure_local_bin" \
    "    builtin source \"\$_valise_fish_active_root/vendor/shell-profile/lib/fish/loader.fish\"" \
    "    set -l _valise_fish_source_status \$status" \
    "    if builtin set -q -g VALISE_FISH_READY; and not builtin set -e -g VALISE_FISH_READY; builtin exit 125; end" \
    "    if builtin set -q -U VALISE_FISH_READY; and not builtin set -e -U VALISE_FISH_READY; builtin exit 125; end" \
    "    set -l _valise_fish_status_published 0" \
    "    set -l _valise_fish_loader_status 1" \
    "    if builtin set -q _sp_fish_loader_bootstrap_status" \
    "      set _valise_fish_status_published 1" \
    "      set _valise_fish_loader_status \$_sp_fish_loader_bootstrap_status" \
    "    end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_mode; and not builtin set -e -g _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_mode; and not builtin set -e -U _sp_fish_loader_bootstrap_mode; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_seeds; and not builtin set -e -g _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_seeds; and not builtin set -e -U _sp_fish_loader_bootstrap_seeds; builtin exit 125; end" \
    "    if builtin set -q -g _sp_fish_loader_bootstrap_status; and not builtin set -e -g _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if builtin set -q -U _sp_fish_loader_bootstrap_status; and not builtin set -e -U _sp_fish_loader_bootstrap_status; builtin exit 125; end" \
    "    if test \$_valise_fish_source_status -ne 0" \
    "      builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "      if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "        builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_owned_cleanup" \
    "      if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "        builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "      printf 'valise Fish integration: native loader source failed with status %d\\n' \$_valise_fish_source_status >&2" \
    "      return \$_valise_fish_source_status" \
    "    else" \
    "      if test \$_valise_fish_status_published -ne 1" \
    "      if builtin functions -q sp_fish_loader_load_ordered; and test -f \"\$_valise_fish_active_root/generated/installed-modules.fish\"" \
    "        # Legacy releases expose only the authenticated generated Fish plan." \
    "        \$_valise_fish_legacy_runner \"\$_valise_fish_active_root\" \"\$_valise_fish_active_root/generated/installed-modules.fish\"" \
    "        set -l _valise_fish_legacy_status \$status" \
    "        builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "        if test \$_valise_fish_legacy_status -ne 0" \
    "          if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "            builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "            builtin exit 125" \
    "          end" \
    "          \$_valise_fish_owned_cleanup" \
    "          if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "            builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "            builtin exit 125" \
    "          end" \
    "          \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "          return \$_valise_fish_legacy_status" \
    "        end" \
    "        \$_valise_fish_publish_active_helper; or builtin exit 125" \
    "      else" \
    "        if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "          builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "          builtin exit 125" \
    "        end" \
    "        \$_valise_fish_owned_cleanup" \
    "        builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "        if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "          builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "          builtin exit 125" \
    "        end" \
    "        \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "        printf '%s\\n' 'valise Fish integration: native loader did not publish a fresh status' >&2" \
    "        return 1" \
    "      end" \
    "      else" \
    "        if not string match -qr '^[0-9]+$' -- \"\$_valise_fish_loader_status\"; or test \$_valise_fish_loader_status -ne 0" \
    "      builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "      if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "        builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_owned_cleanup" \
    "      if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "        builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "        builtin exit 125" \
    "      end" \
    "      \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "      printf 'valise Fish integration: native loader failed with status %s\\n' \$_valise_fish_loader_status >&2" \
    "      return \$_valise_fish_loader_status" \
    "    end" \
    "      end" \
    "    builtin set -gx VALISE_FISH_READY 1" \
    "    builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "    end" \
    "  end" \
    "else" \
    "    if test -f \"\$_valise_fish_active_root/generated/installed-modules.fish\"" \
    "  # Compatibility path for releases that predate native Fish infrastructure." \
    "  \$_valise_fish_legacy_runner \"\$_valise_fish_active_root\" \"\$_valise_fish_active_root/generated/installed-modules.fish\"" \
    "  set -l _valise_fish_legacy_status \$status" \
    "  builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "  if test \$_valise_fish_legacy_status -ne 0" \
    "    if not builtin functions -q \$_valise_fish_owned_cleanup; or not builtin test (builtin functions \$_valise_fish_owned_cleanup | string collect) = \"\$_valise_fish_owned_cleanup_definition\"" \
    "      builtin printf '%s\\n' 'trusted ownership cleanup helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_owned_cleanup" \
    "    if not builtin functions -q \$_valise_fish_root_restore_helper; or not builtin test (builtin functions \$_valise_fish_root_restore_helper | string collect) = \"\$_valise_fish_root_helper_definition\"" \
    "      builtin printf '%s\\n' 'trusted root restore helper was modified' >&2" \
    "      builtin exit 125" \
    "    end" \
    "    \$_valise_fish_root_restore_helper; or builtin exit 125" \
    "    return \$_valise_fish_legacy_status" \
    "  end" \
    "  \$_valise_fish_publish_active_helper; or builtin exit 125" \
    "    else" \
    "  # No Fish entrypoint, no generated Fish plan and no native Fish loader:" \
    "  # the release has nothing this hook can load. Fall through to the shared" \
    "  # success cleanup so the hook stays silent and leaves no helper behind." \
    "  builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "end" \
    "  end" \
    "end" \
    "builtin functions -e \$_valise_fish_legacy_runner 2>/dev/null" \
    "if not builtin functions -q \$_valise_fish_success_cleanup_helper; or not builtin test (builtin functions \$_valise_fish_success_cleanup_helper | string collect) = \"\$_valise_fish_success_cleanup_helper_definition\"" \
    "  builtin printf '%s\\n' 'trusted success cleanup helper was modified' >&2" \
    "  builtin exit 125" \
    "end" \
    "\$_valise_fish_success_cleanup_helper; or builtin exit 125" \
    "end"
}
