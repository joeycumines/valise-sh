# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' builtin_hijack_started >>"${SP_LOADER_TEST_TRACE:?}"
builtin() { return 0; }
builtin_hijack_loaded() { :; }
cd "$SP_LOADER_TEST_STATE_CWD" || return 34
