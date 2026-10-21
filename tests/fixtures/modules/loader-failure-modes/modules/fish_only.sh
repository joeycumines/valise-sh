# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' fish_only >>"${SP_LOADER_TEST_TRACE:?}"
fish_only_loaded() { :; }
