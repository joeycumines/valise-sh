# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' cwd_readonly_builtin_started >>"${SP_LOADER_TEST_TRACE:?}"
cwd_readonly_builtin_loaded() { :; }
eval 'builtin() { return 0; }'
eval 'readonly -f builtin' 2>/dev/null || :
cd "$SP_LOADER_TEST_STATE_CWD" || return 35
return 0
