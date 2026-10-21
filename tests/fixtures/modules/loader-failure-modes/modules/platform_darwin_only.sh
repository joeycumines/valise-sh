# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' platform_darwin_only >>"${SP_LOADER_TEST_TRACE:?}"
platform_darwin_only_loaded() { :; }
