# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_platform_tools_bsd: BSD-family-specific tooling detection.

e2e_bsd_tools_ready() {
  _e2e_bsd_flavor=$(sp_cap_os 2>/dev/null || printf 'bsd')
  _e2e_bsd_pkg_manager=""
  if command -v pkg >/dev/null 2>&1; then
    _e2e_bsd_pkg_manager="pkg"
  elif command -v pkg_add >/dev/null 2>&1; then
    _e2e_bsd_pkg_manager="pkg_add"
  fi
  printf 'BSD tools ready: flavor=%s package_manager=%s\n' "$_e2e_bsd_flavor" "${_e2e_bsd_pkg_manager:-unknown}"
  unset _e2e_bsd_flavor _e2e_bsd_pkg_manager
}
