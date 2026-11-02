# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_word_state_started >>"${SP_LOADER_TEST_TRACE:?}"
clobber_word_state_loaded() { :; }
_spl_seen_words=
_spl_strict_required_words=
_spl_blocked_words=
_spl_modules_words=
_spl_order_words=
_spl_failed_words=
return 0
