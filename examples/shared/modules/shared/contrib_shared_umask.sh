# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# contrib_shared_umask: opt-in secure umask.
#
# Sets umask 077 so newly created files are owner-only by default. This
# changes process state for the calling shell, so it is deliberately a
# work-only module: nothing happens at load time, and the restrictive
# mask applies only when the caller explicitly invokes this function.
# Prints nothing and succeeds in every case.

contrib_shared_umask_secure() {
  umask 077
}
