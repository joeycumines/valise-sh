# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' cwd_mover_started >>"${SP_LOADER_TEST_TRACE:?}"
cwd_mover_loaded() { :; }
cd "$SP_LOADER_TEST_STATE_CWD" || return 32
