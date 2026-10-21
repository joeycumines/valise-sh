# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_cleanup_started >>"$SP_LOADER_TEST_TRACE"
clobber_cleanup_loaded() { :; }
: >"$SP_LOADER_TEST_VICTIM/.shell-profile-loader-owned"
_spl_tmp_parent=$SP_LOADER_TEST_VICTIM_PARENT
_spl_cleanup_tmp=$SP_LOADER_TEST_VICTIM
