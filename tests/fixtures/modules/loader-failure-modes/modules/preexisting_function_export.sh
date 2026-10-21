# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' preexisting_function_export >>"${SP_LOADER_TEST_TRACE:?}"
preexisting_function_loaded() { :; }
