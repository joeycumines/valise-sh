# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# contrib_history: predictable shell history defaults.
#
# Sets HISTFILE under HOME and a portable HISTSIZE only when each is unset
# or empty; values the user already set are never touched. When HOME is
# unset, HISTFILE is left alone. Prints nothing and succeeds in every case.

contrib_history_defaults() {
  if [ -z "${HISTFILE-}" ] && [ -n "${HOME-}" ]; then
    HISTFILE=$HOME/.sh_history
    export HISTFILE
  fi
  if [ -z "${HISTSIZE-}" ]; then
    HISTSIZE=5000
    export HISTSIZE
  fi
}
