# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_cycle_app >>"${SP_LOADER_TEST_TRACE:?}"
optional_cycle_app_loaded() { :; }
