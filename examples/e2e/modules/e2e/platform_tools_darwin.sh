# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_platform_tools_darwin: macOS-specific tooling and path setup.
# Uses engine capabilities for Homebrew discovery.

_e2e_darwin_homebrew_prefix=""

e2e_darwin_tools_ready() {
  _e2e_darwin_homebrew_prefix=$(sp_cap_homebrew_prefix 2>/dev/null || printf '')
  if [ -n "$_e2e_darwin_homebrew_prefix" ]; then
    printf 'macOS tools ready: homebrew=%s\n' "$_e2e_darwin_homebrew_prefix"
  else
    printf 'macOS tools ready: homebrew not found (non-Homebrew system)\n'
  fi
}
