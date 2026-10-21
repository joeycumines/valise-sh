# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_required_missing_dep >>"${SP_LOADER_TEST_TRACE:?}"
optional_required_missing_dep_loaded() { :; }
