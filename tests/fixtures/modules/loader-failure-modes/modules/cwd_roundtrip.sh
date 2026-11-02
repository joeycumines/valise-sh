# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' cwd_roundtrip_started >>"${SP_LOADER_TEST_TRACE:?}"
cwd_roundtrip_loaded() { :; }
cd "$SP_LOADER_TEST_STATE_CWD" || return 32
cd "$OLDPWD" || return 33
