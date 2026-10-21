# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

command printf '%s\n' clobber_unset_started >>"$SP_LOADER_TEST_TRACE"
clobber_unset_loaded() { :; }
unset _spl_mode
set -u
