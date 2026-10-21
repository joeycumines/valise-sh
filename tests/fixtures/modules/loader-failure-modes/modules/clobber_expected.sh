# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

command printf '%s\n' clobber_expected_started >>"$SP_LOADER_TEST_TRACE"
clobber_expected_loaded() { :; }
_spl_mode=permissive
_spl_expected_mode=permissive
_spl_exports_to_cleanup=
_spl_expected_exports_to_cleanup=
return 36
