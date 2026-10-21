#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Generic POSIX platform capability module.

sp_platform_os() { sp_cap_os "$@"; }
sp_platform_cpu_count() { sp_cap_cpu_count "$@"; }
sp_platform_file_mtime() { sp_cap_file_mtime "$@"; }
sp_platform_mktemp_dir() { sp_cap_mktemp_dir "$@"; }
sp_platform_canonical_path() { sp_cap_canonical_path "$@"; }
sp_platform_path_under() { sp_cap_path_under "$@"; }
sp_platform_command_path() { sp_cap_command_path "$@"; }
