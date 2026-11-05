# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# contrib_shared_paths: team-standard development directories on PATH.
#
# Puts $HOME/.local/bin and $HOME/.go/bin on PATH through
# valise_path_prepend (provided by the engine's valise_path module,
# which this module requires), keeping PATH duplicate-free. When HOME is
# unset, nothing is added. Prints nothing and succeeds in every case.

contrib_shared_paths_setup() {
  if [ -z "${HOME-}" ]; then
    return 0
  fi
  valise_path_prepend "$HOME/.local/bin" "$HOME/.go/bin"
}
