# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' optional_required_runtime_req_started >>"${SP_LOADER_TEST_TRACE:?}"
optional_required_runtime_req_loaded() { :; }
return 31
