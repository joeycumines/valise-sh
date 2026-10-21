# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_shell_state_started >>"$SP_LOADER_TEST_TRACE"
clobber_shell_state_loaded() { :; }
cd "$SP_LOADER_TEST_STATE_CWD" || return 32
IFS=:
set -e
set -f
set +u
