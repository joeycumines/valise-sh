# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_utility_started >>"$SP_LOADER_TEST_TRACE"
clobber_utility_loaded() { :; }
grep() { return 1; }
rm() { printf '%s\n' utility_rm_hijack >>"$SP_LOADER_TEST_TRACE"; return 0; }
return 33
