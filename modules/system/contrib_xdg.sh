# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# contrib_xdg: predictable XDG base directory defaults.
#
# Fills in each of XDG_DATA_HOME, XDG_CONFIG_HOME, XDG_STATE_HOME, and
# XDG_CACHE_HOME from HOME only when that variable is unset or empty;
# values the user already set are never touched. When HOME itself is
# unset, nothing is set. Prints nothing and succeeds in every case.

contrib_xdg_defaults() {
  if [ -z "${HOME-}" ]; then
    return 0
  fi
  if [ -z "${XDG_DATA_HOME-}" ]; then
    XDG_DATA_HOME=$HOME/.local/share
    export XDG_DATA_HOME
  fi
  if [ -z "${XDG_CONFIG_HOME-}" ]; then
    XDG_CONFIG_HOME=$HOME/.config
    export XDG_CONFIG_HOME
  fi
  if [ -z "${XDG_STATE_HOME-}" ]; then
    XDG_STATE_HOME=$HOME/.local/state
    export XDG_STATE_HOME
  fi
  if [ -z "${XDG_CACHE_HOME-}" ]; then
    XDG_CACHE_HOME=$HOME/.cache
    export XDG_CACHE_HOME
  fi
}
