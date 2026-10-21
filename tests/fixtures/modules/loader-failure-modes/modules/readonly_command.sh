# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' readonly_command_started >>"$SP_LOADER_TEST_TRACE"
readonly_command_loaded() { :; }
command() {
  printf '%s\n' readonly_command_hijack_marker >>"$SP_LOADER_TEST_TRACE"
  "$@"
}
readonly -f command
return 36
