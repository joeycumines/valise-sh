# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_required_cycle_b >>"${SP_LOADER_TEST_TRACE:?}"
optional_required_cycle_b_loaded() { :; }
