# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_optional_network: optional network availability check.
# This module has an optional dependency on e2e_env_setup but works
# independently when that dependency is not loaded.

e2e_net_available() {
  _e2e_net_status="unknown"
  # Check if environment setup is available (optional dependency)
  if type e2e_env_ready >/dev/null 2>&1; then
    _e2e_net_status="env_integrated"
  else
    _e2e_net_status="standalone"
  fi
  # Check basic network connectivity (DNS resolution only, no network calls)
  if command -v getent >/dev/null 2>&1; then
    if getent hosts localhost >/dev/null 2>&1; then
      printf 'network module: status=%s dns=working\n' "$_e2e_net_status"
    else
      printf 'network module: status=%s dns=unavailable\n' "$_e2e_net_status"
    fi
  else
    printf 'network module: status=%s (no getent available)\n' "$_e2e_net_status"
  fi
  unset _e2e_net_status
}
