# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_layer_probe: cross-root composition probe.
#
# Requires e2e_env_setup and optionally follows contrib_shared_paths, so
# loading it with a shared layer present proves dependency resolution in
# both directions across the primary/layer boundary. The function reports
# whether the shared layer resolved; it prints one line and succeeds in
# every case.

e2e_layer_probe_ok() {
  if command -v contrib_shared_paths_setup >/dev/null 2>&1; then
    printf '%s\n' 'layer probe: shared layer resolved'
  else
    printf '%s\n' 'layer probe: standalone (no shared layer)'
  fi
}
