# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' failed_hook_started >>"${SP_LOADER_TEST_TRACE:?}"
failed_hook_loaded() { :; }
return 27
