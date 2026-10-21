# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_env_setup: foundational environment module.
# Sets up environment variables and platform detection using engine capabilities.

e2e_env_ready() {
  _e2e_os=$(sp_cap_os 2>/dev/null || printf 'unknown')
  _e2e_cpus=$(sp_cap_cpu_count 2>/dev/null || printf '0')
  printf 'e2e environment ready: platform=%s cpus=%s\n' "$_e2e_os" "$_e2e_cpus"
  unset _e2e_os _e2e_cpus
}

E2E_PROFILE_VERSION="1.0.0"
E2E_ENGINE_ROOT="${VALISE_ROOT:-}"
export E2E_PROFILE_VERSION E2E_ENGINE_ROOT
