# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_ksh_features: ksh-specific shell features.
# Uses ksh-specific syntax that would break in other shells.

_e2e_ksh_state=0

# ksh supports typeset; use it for a typed variable
if type typeset >/dev/null 2>&1; then
  typeset -i E2E_KSH_LOAD_COUNT=0
  E2E_KSH_LOAD_COUNT=$((E2E_KSH_LOAD_COUNT + 1))
  _e2e_ksh_state=1
fi

e2e_ksh_loaded() {
  if [ "$_e2e_ksh_state" -eq 1 ]; then
    printf 'ksh features loaded: typeset available, load_count=%s\n' "${E2E_KSH_LOAD_COUNT:-1}"
  else
    printf 'ksh features loaded: basic mode (typeset not available)\n'
  fi
}
