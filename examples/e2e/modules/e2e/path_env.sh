# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_path_env: a PATH-mutating env-phase module.
#
# It prepends one directory through valise_path_prepend (the engine's
# idempotent helper, which this module requires) so the end-to-end suite can
# prove two things the metadata alone cannot: that PATH mutation belongs in
# the env plan, and that the block re-asserts it AFTER macOS runs path_helper
# in /etc/zprofile. Without that second pass a login zsh would end up with the
# compiled entry last instead of first.

E2E_BIN_DIR="${HOME:-}/e2e-bin"
export E2E_BIN_DIR

e2e_bin_dir() {
  printf '%s\n' "$E2E_BIN_DIR"
}

valise_path_prepend "$E2E_BIN_DIR"
