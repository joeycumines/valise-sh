# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' local_state_started >>"${SP_LOADER_TEST_TRACE:?}"
mkdir -p "$XDG_STATE_HOME/shell-profile" || return 33
local_state_loaded() { :; }
