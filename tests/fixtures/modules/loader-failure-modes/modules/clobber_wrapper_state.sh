# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

printf '%s\n' clobber_wrapper_state_started >>"${SP_LOADER_TEST_TRACE:?}"
clobber_wrapper_state_loaded() { :; }
_spl_wrapper_exports=
cd "$SP_LOADER_TEST_STATE_CWD" || return 34
_spl_expected_pwd_physical=$(command pwd -P 2>/dev/null)
_spl_expected_pwd=$PWD
_spl_expected_pwd_was_set=1
_spl_expected_pwd_status=0
_spl_expected_oldpwd=$OLDPWD
_spl_expected_oldpwd_was_set=1
return 0
