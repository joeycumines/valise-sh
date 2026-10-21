# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_state_started >>"$SP_LOADER_TEST_TRACE"
clobber_state_loaded() { :; }
_spl_mode=permissive
_spl_exports_to_cleanup=
return 31
