# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_aliases: shell alias definitions.
# Defines portable aliases that work across POSIX shells.

e2e_show_aliases() {
  printf 'e2e aliases:\n'
  printf '  e2e-status  -> e2e_env_ready\n'
  printf '  e2e-info    -> e2e_config_loaded\n'
  printf '  e2e-net     -> e2e_net_available\n'
}

# Define aliases only in interactive shells
if [ -n "${PS1:-}" ]; then
  alias e2e-status='e2e_env_ready'
  alias e2e-info='e2e_config_loaded'
  alias e2e-net='e2e_net_available'
fi
