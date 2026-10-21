# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_completions_zsh: zsh-specific tab completion for e2e commands.

_e2e_zsh_completions_state=0

_e2e_zsh_complete() {
  local -a commands
  commands=('status:show environment status' 'info:show configuration info' 'net:show network status' 'help:show help')
  _describe 'command' commands
}

if type compdef >/dev/null 2>&1; then
  compdef _e2e_zsh_complete e2e-status 2>/dev/null || :
  compdef _e2e_zsh_complete e2e-info 2>/dev/null || :
  _e2e_zsh_completions_state=1
fi

e2e_zsh_completions_loaded() {
  if [ "$_e2e_zsh_completions_state" -eq 1 ]; then
    printf 'zsh completions registered for e2e commands\n'
  else
    printf 'zsh completions skipped (not in zsh)\n'
  fi
}
