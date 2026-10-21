# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# contrib_editor: predictable EDITOR/VISUAL defaults.
#
# Respects values the user already set; otherwise uses the first available
# of nvim, vim, vi. vi is POSIX-mandated and present on conforming systems,
# so a default is always found there. Prints nothing and succeeds in every
# case, including when nothing is available.

contrib_editor_defaults() {
  if [ -n "${EDITOR-}" ] && [ -n "${VISUAL-}" ]; then
    return 0
  fi
  _contrib_editor_choice=
  for _contrib_editor_candidate in nvim vim vi; do
    if command -v "$_contrib_editor_candidate" >/dev/null 2>&1; then
      _contrib_editor_choice=$_contrib_editor_candidate
      break
    fi
  done
  if [ -z "$_contrib_editor_choice" ]; then
    unset _contrib_editor_choice _contrib_editor_candidate
    return 0
  fi
  if [ -z "${EDITOR-}" ]; then
    EDITOR=$_contrib_editor_choice
    export EDITOR
  fi
  if [ -z "${VISUAL-}" ]; then
    VISUAL=$_contrib_editor_choice
    export VISUAL
  fi
  unset _contrib_editor_choice _contrib_editor_candidate
}
