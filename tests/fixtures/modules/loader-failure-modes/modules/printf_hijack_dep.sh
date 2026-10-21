# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

command printf '%s\n' printf_hijack_dep_started >>"$SP_LOADER_TEST_TRACE"
printf_hijack_dep_loaded() { :; }
printf() {
  if [ "${SP_LOADER_TEST_SUPPRESS_PRINTF_MARKER:-0}" != 1 ]; then
    command printf '%s\n' printf_hijack_marker >>"$SP_LOADER_TEST_TRACE"
  fi
  command printf "$@"
}
return 34
