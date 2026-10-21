# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_generated_config: loads generated configuration values.
# Demonstrates a module that reads pre-generated config.

E2E_CONFIG_THEME="${E2E_CONFIG_THEME:-default}"
E2E_CONFIG_LOCALE="${E2E_CONFIG_LOCALE:-en_US.UTF-8}"
E2E_CONFIG_EDITOR="${E2E_CONFIG_EDITOR:-vi}"
export E2E_CONFIG_THEME E2E_CONFIG_LOCALE E2E_CONFIG_EDITOR

e2e_config_loaded() {
  printf 'config loaded: theme=%s locale=%s editor=%s\n' \
    "$E2E_CONFIG_THEME" "$E2E_CONFIG_LOCALE" "$E2E_CONFIG_EDITOR"
}
