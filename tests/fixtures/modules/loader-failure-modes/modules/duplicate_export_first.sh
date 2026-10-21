# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' duplicate_export_first >>"${SP_LOADER_TEST_TRACE:?}"
duplicate_shared_loaded() { :; }
