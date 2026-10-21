# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_platform_tools_linux: Linux-specific tooling detection.

e2e_linux_tools_ready() {
  _e2e_linux_pkg_manager=""
  if command -v apt-get >/dev/null 2>&1; then
    _e2e_linux_pkg_manager="apt"
  elif command -v dnf >/dev/null 2>&1; then
    _e2e_linux_pkg_manager="dnf"
  elif command -v pacman >/dev/null 2>&1; then
    _e2e_linux_pkg_manager="pacman"
  elif command -v apk >/dev/null 2>&1; then
    _e2e_linux_pkg_manager="apk"
  fi
  printf 'Linux tools ready: package_manager=%s\n' "${_e2e_linux_pkg_manager:-unknown}"
  unset _e2e_linux_pkg_manager
}
