# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_invalid_dep >>"${SP_LOADER_TEST_TRACE:?}"
optional_invalid_dep_loaded() { :; }
