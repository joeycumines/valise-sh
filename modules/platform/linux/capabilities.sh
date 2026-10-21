#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Linux platform capability module.

sp_platform_linux_available() { [ "$(sp_cap_os 2>/dev/null)" = linux ]; }
sp_platform_linux_cpu_count() { sp_cap_cpu_count "$@"; }
sp_platform_linux_file_mtime() { sp_cap_file_mtime "$@"; }
