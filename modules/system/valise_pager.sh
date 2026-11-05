# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise_pager: predictable PAGER default.
#
# Respects a value the user already set; otherwise uses the first available
# of less, more. When neither exists, PAGER is left unset. Prints nothing
# and succeeds in every case.

valise_pager_defaults() {
  if [ -n "${PAGER-}" ]; then
    return 0
  fi
  _contrib_pager_choice=
  for _contrib_pager_candidate in less more; do
    if command -v "$_contrib_pager_candidate" >/dev/null 2>&1; then
      _contrib_pager_choice=$_contrib_pager_candidate
      break
    fi
  done
  if [ -z "$_contrib_pager_choice" ]; then
    unset _contrib_pager_choice _contrib_pager_candidate
    return 0
  fi
  PAGER=$_contrib_pager_choice
  export PAGER
  unset _contrib_pager_choice _contrib_pager_candidate
}
