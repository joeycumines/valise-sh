# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' tab_readonly_hijack_started >>"${SP_LOADER_TEST_TRACE:?}"
tab_readonly_hijack_loaded() { :; }
readonly	-f	command
