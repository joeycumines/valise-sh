#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# macOS platform capability module.

sp_platform_macos_available() { [ "$(sp_cap_os 2>/dev/null)" = darwin ]; }
sp_platform_macos_homebrew_prefix() { sp_cap_homebrew_prefix "$@"; }
sp_platform_macos_homebrew_gnubin() { sp_cap_homebrew_opt_gnubin "$@"; }
sp_platform_macos_cpu_count() { sp_cap_cpu_count "$@"; }
