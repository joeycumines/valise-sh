# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' tab_name_hijack_started >>"${SP_LOADER_TEST_TRACE:?}"
tab_name_hijack_loaded() { :; }
command	() { return 0; }
