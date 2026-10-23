# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

if [ "${SP_LOADER_TEST_RELOAD_STAGE:-first}" = second ]; then
  reload_probe_loaded() { printf 'second\n'; }
else
  reload_probe_loaded() { printf 'first\n'; }
fi
