# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' unset_command_started >>"$SP_LOADER_TEST_TRACE"
unset_command_loaded() { :; }
unset() {
  printf '%s\n' unset_command_unset_marker >>"$SP_LOADER_TEST_TRACE"
  return 0
}
command() {
  printf '%s\n' unset_command_hijack_marker >>"$SP_LOADER_TEST_TRACE"
  "$@"
}
return 37
