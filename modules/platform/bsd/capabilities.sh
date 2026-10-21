#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# BSD-family platform capability module.

sp_platform_bsd_available() {
  case "$(sp_cap_os 2>/dev/null)" in
  bsd | freebsd | openbsd | netbsd) : ;;
  *) false ;;
  esac
}
sp_platform_bsd_cpu_count() { sp_cap_cpu_count "$@"; }
sp_platform_bsd_file_mtime() { sp_cap_file_mtime "$@"; }
