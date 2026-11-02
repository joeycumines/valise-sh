# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' tab_function_hijack_started >>"${SP_LOADER_TEST_TRACE:?}"
tab_function_hijack_loaded() { :; }
function	unset { return 0; }
