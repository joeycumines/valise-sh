# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' missing_required_user >>"${SP_LOADER_TEST_TRACE:?}"
missing_required_user_loaded() { :; }
