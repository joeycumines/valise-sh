# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_completions_bash: bash-specific tab completion for e2e commands.

_e2e_bash_completions_state=0

_e2e_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "status info net help" -- "$cur"))
}

if type complete >/dev/null 2>&1; then
  complete -F _e2e_complete e2e-status 2>/dev/null || :
  complete -F _e2e_complete e2e-info 2>/dev/null || :
  _e2e_bash_completions_state=1
fi

e2e_bash_completions_loaded() {
  if [ "$_e2e_bash_completions_state" -eq 1 ]; then
    printf 'bash completions registered for e2e commands\n'
  else
    printf 'bash completions skipped (not in bash)\n'
  fi
}
