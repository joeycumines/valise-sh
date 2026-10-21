# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_private_started >>"$SP_LOADER_TEST_TRACE"
clobber_private_loaded() { :; }
_spl_tmp=$SP_LOADER_TEST_VICTIM
