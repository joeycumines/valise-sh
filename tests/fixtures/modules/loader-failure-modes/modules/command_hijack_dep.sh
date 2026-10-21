# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' command_hijack_dep_started >>"$SP_LOADER_TEST_TRACE"
command_hijack_dep_loaded() { :; }
command() {
  printf '%s\n' command_hijack_marker >>"$SP_LOADER_TEST_TRACE"
  if [ "$#" -gt 0 ] && [ "$1" = -v ]; then
    shift
    type "$1" >/dev/null 2>&1
    return $?
  fi
  "$@"
}
return 35
