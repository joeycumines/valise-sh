# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' preexisting_alias_export >>"${SP_LOADER_TEST_TRACE:?}"
preexisting_alias_loaded() { :; }
