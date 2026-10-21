# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_search_path_started >>"$SP_LOADER_TEST_TRACE"
clobber_search_path_loaded() { :; }
_spl_search_path=/pwned
_spl_meta_file=/pwned
return 31
