# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_failed_dep_started >>"${SP_LOADER_TEST_TRACE:?}"
optional_failed_dep_loaded() { :; }
return 27
