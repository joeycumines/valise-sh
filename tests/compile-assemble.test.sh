#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Contract test for the compiled-plan consumer workflow: package-install
# symlink resolution, bundle roots without a Python release compiler, the
# assembled release tree, compiled-plan cleanup, and the integration targets
# that the consumer owns.
set -eu

_total=0
_pass=0
_fail=0
_skip=0
_require_tooling=${VALISE_REQUIRE_TOOLING:-0}

pass() { _total=$((_total + 1)); _pass=$((_pass + 1)); printf '  PASS: %s\n' "$1"; }
fail() { _total=$((_total + 1)); _fail=$((_fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
skip() { _total=$((_total + 1)); _skip=$((_skip + 1)); printf '  SKIP: %s\n' "$1"; }

_test_root=$(mktemp -d "${TMPDIR:-/tmp}/valise-compile.XXXXXX")
_cleanup_done=0
_cleanup() {
  [ "$_cleanup_done" -eq 0 ] || return 0
  _cleanup_done=1
  chmod -R u+w "$_test_root" 2>/dev/null || :
  rm -rf -- "$_test_root"
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

_repo=$(cd "$(dirname "$0")/.." && pwd -P)
_project="$_test_root/project"
_pkg="$_test_root/pkg"
_link="$_test_root/bin/valise"

mkdir -p "$_project/shell/module.d" "$_project/shell/modules" \
  "$_project/shell/layers/vendor/module.d" "$_project/shell/layers/vendor/modules" \
  "$_project/shell/release" "$_pkg/bin" "$_pkg/lib" "$_test_root/bin"

cp "$_repo/bin/valise" "$_pkg/bin/valise"
cp "$_repo/lib/compiler.awk" "$_pkg/lib/compiler.awk"
cp "$_repo/lib/capabilities.sh" "$_pkg/lib/capabilities.sh"
chmod 0755 "$_pkg/bin/valise"
ln -s "$_pkg/bin/valise" "$_link"

# A valid source tree above the package must not win over the project root.
# Compile resolves from the working tree first so assemble packages the same
# prelude the plan was built against.
mkdir -p "$_test_root/shell/release"
printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'   >"$_test_root/shell/release/module-registry.tsv"
printf 'variant_name\tdescription\texcluded_modules\nworkstation-full\tDecoy\t\n'   >"$_test_root/shell/release/install-variants"

cat >"$_project/shell/module.d/root.meta" <<'EOF'
name=root
version=
side_effect=read-only
requires=contrib_vendor_tool
optional=
shells=bash zsh ksh
platforms=any
exports=root_ready
updates=
load=modules/root.sh
EOF
cat >"$_project/shell/modules/root.sh" <<'EOF'
root_ready() { :; }
EOF
cat >"$_project/shell/layers/vendor/module.d/contrib_vendor_tool.meta" <<'EOF'
name=contrib_vendor_tool
version=1.0.0
side_effect=read-only
requires=
optional=
shells=bash zsh ksh
platforms=any
exports=vendor_tool_ready
updates=
load=modules/contrib_vendor_tool.sh
EOF
cat >"$_project/shell/layers/vendor/modules/contrib_vendor_tool.sh" <<'EOF'
vendor_tool_ready() { :; }
EOF
for _shell in bash zsh ksh; do
  cat >"$_project/shell/module.d/${_shell}_only.meta" <<EOF
name=${_shell}_only
version=
side_effect=read-only
requires=
optional=
shells=$_shell
platforms=any
exports=${_shell}_plan_ready
updates=
load=modules/${_shell}_only.sh
EOF
  cat >"$_project/shell/modules/${_shell}_only.sh" <<EOF
${_shell}_plan_ready() { :; }
EOF
done

{
  printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'
  printf 'root\t\tread-only\tcontrib_vendor_tool\t\tbash zsh ksh\tany\troot_ready\tmodules/root.sh\t\tshell/module.d\n'
  printf 'contrib_vendor_tool\t1.0.0\tread-only\t\t\tbash zsh ksh\tany\tvendor_tool_ready\tmodules/contrib_vendor_tool.sh\t\tshell/layers/vendor/module.d\n'
  printf 'bash_only\t\tread-only\t\t\tbash\tany\tbash_plan_ready\tmodules/bash_only.sh\t\tshell/module.d\n'
  printf 'zsh_only\t\tread-only\t\t\tzsh\tany\tzsh_plan_ready\tmodules/zsh_only.sh\t\tshell/module.d\n'
  printf 'ksh_only\t\tread-only\t\t\tksh\tany\tksh_plan_ready\tmodules/ksh_only.sh\t\tshell/module.d\n'
} >"$_project/shell/release/module-registry.tsv"

{
  printf '# bundle\tshell\troots\n'
  printf 'default\tbash\troot bash_only\n'
  printf 'default\tzsh\troot zsh_only\n'
  printf 'default\tksh\troot ksh_only\n'
} >"$_project/shell/release/bundle-roots"

{
  printf 'variant_name\tdescription\texcluded_modules\n'
  printf 'workstation-full\tAll\t\n'
} >"$_project/shell/release/install-variants"

printf '=== valise compile/assemble consumer contract ===\n'
printf '  project: %s\n\n' "$_project"

# Compile through a symlink, with no hack/compile-shell-profile-release.py,
# from a relative output directory, using bare bundle seeds. The vendor layer
# must land under layers/vendor/ rather than the contrib default.
if (cd "$_project" && "$_link" compile --bundle=default rel-out) >"$_test_root/compile.out" 2>"$_test_root/compile.err"; then
  pass "compile resolves ../lib through a package-style symlink"
else
  fail "compile resolves ../lib through a package-style symlink"
  cat "$_test_root/compile.err" >&2
fi
if [ -f "$_project/rel-out/installed-modules.bash" ] &&
  [ -f "$_project/rel-out/installed-modules.zsh" ] &&
  [ -f "$_project/rel-out/installed-modules.ksh" ]; then
  pass "relative compile output receives a plan for every requested shell"
else
  fail "relative compile output receives a plan for every requested shell"
fi
_plan="$_project/rel-out/installed-modules.bash"
if [ -f "$_plan" ] && grep -F '# roots=root' "$_plan" >/dev/null 2>&1 &&
  grep -F '. "${VALISE_MODULE_ROOT%/}/modules/root.sh"' "$_plan" >/dev/null 2>&1; then
  pass "bare bundle seed compiles to the primary module body"
else
  fail "bare bundle seed compiles to the primary module body"
fi
if [ -f "$_plan" ] &&
  grep -F '. "${VALISE_MODULE_ROOT%/}/layers/vendor/modules/contrib_vendor_tool.sh"' "$_plan" >/dev/null 2>&1; then
  pass "non-contrib provider layer compiles to its own release prefix"
else
  fail "non-contrib provider layer compiles to its own release prefix"
fi

# Compile without a bundle exercises the default bundle row and the same
# root-qualification path.
if (cd "$_project" && "$_link" compile default-out) >"$_test_root/compile-default.out" 2>&1 &&
  grep -F '# roots=root' "$_project/default-out/installed-modules.bash" >/dev/null 2>&1; then
  pass "default bundle resolves without --bundle"
else
  fail "default bundle resolves without --bundle"
fi

# Dot segments must normalize before staging; otherwise publish targets a
# stage path containing an already-removed ".." component.
if (cd "$_project" && "$_link" compile "dot-out/.") >"$_test_root/compile-dot.out" 2>"$_test_root/compile-dot.err" &&
  [ -f "$_project/dot-out/installed-modules.bash" ]; then
  pass "compile normalizes dot segments in an output path"
else
  fail "compile normalizes dot segments in an output path"
  cat "$_test_root/compile-dot.err" >&2
fi

mkdir -p "$_project/empty-compile"
if (cd "$_project" && "$_link" compile "empty-compile/.") >"$_test_root/compile-empty.out" 2>"$_test_root/compile-empty.err" &&
  [ -f "$_project/empty-compile/installed-modules.bash" ]; then
  pass "compile accepts an existing empty dot-path destination"
else
  fail "compile accepts an existing empty dot-path destination"
  cat "$_test_root/compile-empty.err" >&2
fi
if (cd "$_project" && "$_link" compile "$_project/a/b/../../nested-out")   >"$_test_root/compile-nested.out" 2>"$_test_root/compile-nested.err" &&
  [ -f "$_project/nested-out/installed-modules.bash" ]; then
  pass "compile normalizes nested parent segments"
else
  fail "compile normalizes nested parent segments"
  cat "$_test_root/compile-nested.err" >&2
fi
mkdir -p "$_project/globZZout"
if (cd "$_project" && "$_link" compile 'glob*out')   >"$_test_root/compile-glob.out" 2>"$_test_root/compile-glob.err" &&
  [ -f "$_project/glob*out/installed-modules.bash" ] &&
  [ ! -e "$_project/globZZout/installed-modules.bash" ]; then
  pass "compile does not expand glob characters in an output path"
else
  fail "compile does not expand glob characters in an output path"
  cat "$_test_root/compile-glob.err" >&2
fi
if (cd "$_project" && "$_link" compile /tmp/..)   >"$_test_root/compile-root.out" 2>"$_test_root/compile-root.err"; then
  fail "compile rejects a normalized root destination"
elif grep -F 'output directory must not be /' "$_test_root/compile-root.err" >/dev/null 2>&1; then
  pass "compile rejects a normalized root destination"
else
  fail "compile rejects a normalized root destination"
  cat "$_test_root/compile-root.err" >&2
fi

# Assemble the whole release tree twice. The plans must load, and the two
# manifests must be byte-identical.
for _n in 1 2; do
  if (cd "$_project" && "$_link" assemble --bundle=default "build/release$_n") \
    >"$_test_root/assemble$_n.out" 2>"$_test_root/assemble$_n.err"; then
    pass "assemble builds release tree $_n"
  else
    fail "assemble builds release tree $_n"
    cat "$_test_root/assemble$_n.err" >&2
  fi
done
if (cd "$_project" && "$_link" assemble --bundle=default "build/../dot-release") \
  >"$_test_root/assemble-dot.out" 2>"$_test_root/assemble-dot.err" &&
  [ -f "$_project/dot-release/generated/installed-modules.bash" ]; then
  pass "assemble normalizes dot segments in an output path"
else
  fail "assemble normalizes dot segments in an output path"
  cat "$_test_root/assemble-dot.err" >&2
fi

mkdir -p "$_project/empty-assemble"
if (cd "$_project" && "$_link" assemble --bundle=default "empty-assemble/../empty-assemble")   >"$_test_root/assemble-empty.out" 2>"$_test_root/assemble-empty.err" &&
  [ -f "$_project/empty-assemble/generated/installed-modules.bash" ]; then
  pass "assemble accepts an existing empty dot-path destination"
else
  fail "assemble accepts an existing empty dot-path destination"
  cat "$_test_root/assemble-empty.err" >&2
fi
if (cd "$_project" && "$_link" assemble --bundle=default "$_project/absolute-release")   >"$_test_root/assemble-absolute.out" 2>"$_test_root/assemble-absolute.err" &&
  [ -f "$_project/absolute-release/generated/installed-modules.bash" ]; then
  pass "assemble accepts an absolute output path"
else
  fail "assemble accepts an absolute output path"
  cat "$_test_root/assemble-absolute.err" >&2
fi

_release="$_project/build/release1"
for _file in \
  generated/installed-modules.bash \
  vendor/shell-profile/lib/capabilities.sh \
  module.d/root.meta \
  modules/root.sh \
  layers/vendor/module.d/contrib_vendor_tool.meta \
  layers/vendor/modules/contrib_vendor_tool.sh \
  shell/release/bundle-roots \
  shell/install/profile-release.manifest; do
  if [ -f "$_release/$_file" ]; then
    pass "assembled tree contains $_file"
  else
    fail "assembled tree contains $_file"
  fi
done
if cmp -s "$_release/shell/install/profile-release.manifest" \
  "$_project/build/release2/shell/install/profile-release.manifest"; then
  pass "repeated assemble produces a byte-identical manifest"
else
  fail "repeated assemble produces a byte-identical manifest"
fi

# Registry names index paths. A traversal name must fail before any copy can
# write outside the staged release.
cp "$_project/shell/release/module-registry.tsv" "$_test_root/registry.saved"
# Make the traversal target real, so only name validation can prevent it from
# being copied outside the release.
cat >"$_project/pwned.meta" <<'EOF'
name=pwned
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
updates=
load=modules/root.sh
EOF
printf '../../pwned\t\tread-only\t\t\tbash\tany\tpwned\tpwned.meta\t\tshell/module.d\n' \
  >>"$_project/shell/release/module-registry.tsv"
if (cd "$_project" && "$_link" assemble --bundle=default build/escape) \
  >"$_test_root/assemble-escape.out" 2>"$_test_root/assemble-escape.err"; then
  fail "assemble rejects a registry module name containing path traversal"
elif ! grep -F 'invalid module name in registry: ../../pwned' \
  "$_test_root/assemble-escape.err" >/dev/null 2>&1; then
  fail "assemble rejects a registry module name containing path traversal (wrong diagnostic)"
  cat "$_test_root/assemble-escape.err" >&2
elif [ -e "$_project/build/escape" ] || [ -e "$_project/build/pwned.meta" ]; then
  fail "assemble rejects a registry module name containing path traversal (published output)"
else
  pass "assemble rejects a registry module name containing path traversal"
fi
cp "$_test_root/registry.saved" "$_project/shell/release/module-registry.tsv"
cat >"$_project/shell/module.d/trav.meta" <<'EOF'
name=trav
version=
side_effect=read-only
requires=
optional=
shells=bash
platforms=any
exports=
updates=
load=modules/evil.sh
EOF
cat >"$_project/shell/modules/evil.sh" <<'EOF'
evil_loaded() { :; }
EOF
printf 'trav\t\tread-only\t\t\tbash\tany\t\tmodules/../evil.sh\t\tshell/module.d\n' \
  >>"$_project/shell/release/module-registry.tsv"
if (cd "$_project" && "$_link" assemble --bundle=default build/load-escape) \
  >"$_test_root/assemble-load-escape.out" 2>"$_test_root/assemble-load-escape.err"; then
  fail "assemble rejects a registry load path containing a parent segment"
elif ! grep -F 'invalid load path in registry for trav: modules/../evil.sh' \
  "$_test_root/assemble-load-escape.err" >/dev/null 2>&1; then
  fail "assemble rejects a registry load path containing a parent segment (wrong diagnostic)"
  cat "$_test_root/assemble-load-escape.err" >&2
else
  pass "assemble rejects a registry load path containing a parent segment"
fi
cp "$_test_root/registry.saved" "$_project/shell/release/module-registry.tsv"

# A consumer may vendor the prelude as a submodule. Compile uses it, so
# assemble must package that same file rather than the engine copy.
mkdir -p "$_project/submodule/valise-sh/lib"
cat >"$_project/submodule/valise-sh/lib/capabilities.sh" <<'EOF'
sp_cap_submodule_marker() { :; }
EOF
if (cd "$_project" && "$_link" assemble --bundle=default build/submodule) \
  >"$_test_root/assemble-submodule.out" 2>"$_test_root/assemble-submodule.err" &&
  grep -F 'sp_cap_submodule_marker' "$_project/build/submodule/vendor/shell-profile/lib/capabilities.sh" >/dev/null 2>&1 &&
  ! grep -F 'sp_cap_os()' "$_project/build/submodule/vendor/shell-profile/lib/capabilities.sh" >/dev/null 2>&1; then
  pass "assemble packages the submodule prelude selected by compile"
else
  fail "assemble packages the submodule prelude selected by compile"
  cat "$_test_root/assemble-submodule.err" >&2
fi
if VALISE_MODULE_ROOT="$_project/build/submodule" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash" || exit 1
  if command -v sp_cap_submodule_marker >/dev/null 2>&1; then exit 2; fi
' >"$_test_root/plan-submodule.out" 2>"$_test_root/plan-submodule.err"; then
  pass "compiled plan cleans up the submodule prelude"
else
  fail "compiled plan cleans up the submodule prelude"
  cat "$_test_root/plan-submodule.err" >&2
fi

# Source the compiled plan directly. Every capability prelude function must be
# gone afterwards; this is the current compiled-plan contract.
if VALISE_MODULE_ROOT="$_release" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash" || exit 1
  command -v root_ready >/dev/null 2>&1 || exit 2
  command -v vendor_tool_ready >/dev/null 2>&1 || exit 3
  command -v bash_plan_ready >/dev/null 2>&1 || exit 4
  if command -v zsh_plan_ready >/dev/null 2>&1; then exit 5; fi
' >"$_test_root/plan-bash.out" 2>"$_test_root/plan-bash.err"; then
  pass "compiled bash plan loads its own bodies"
else
  fail "compiled bash plan loads its own bodies"
  cat "$_test_root/plan-bash.err" >&2
fi
_prelude_fns=$(sed -n 's/^\(sp_cap_[a-zA-Z0-9_]*\)().*/\1/p' "$_pkg/lib/capabilities.sh")
if [ -n "$_prelude_fns" ]; then
  pass "capability prelude exposes functions to clean up"
else
  fail "capability prelude exposes functions to clean up"
fi
_leaked=
for _shell in bash zsh ksh; do
  case "$_shell" in
    bash) _bin=/bin/bash ;;
    zsh) _bin=/bin/zsh ;;
    ksh) _bin=/bin/ksh ;;
  esac
  if [ ! -x "$_bin" ]; then
    if [ "$_require_tooling" -eq 1 ]; then
      fail "$_shell plan removes every sp_cap_* prelude function ($_bin unavailable)"
    else
      skip "$_shell plan removes every sp_cap_* prelude function ($_bin unavailable)"
    fi
    continue
  fi
  if VALISE_MODULE_ROOT="$_release" "$_bin" -c '
    . "$VALISE_MODULE_ROOT/generated/installed-modules.$1" || exit 1
    shift
    for _fn do
      if command -v "$_fn" >/dev/null 2>&1; then
        printf "%s\n" "$_fn"
        exit 2
      fi
    done
  ' sh "$_shell" $_prelude_fns >"$_test_root/plan-clean-$_shell.out" 2>"$_test_root/plan-clean-$_shell.err"; then
    pass "$_shell plan removes every sp_cap_* prelude function"
  else
    _leaked="$_leaked $(cat "$_test_root/plan-clean-$_shell.out")"
    fail "$_shell plan removes every sp_cap_* prelude function:$_leaked"
  fi
done

# install --no-shell-integration must write neither a POSIX startup file nor a
# Fish hook, while still installing and activating the release.
_no_int_home="$_test_root/home-no-int"
mkdir -p "$_no_int_home"
if (cd "$_release" && HOME="$_no_int_home" XDG_DATA_HOME="$_no_int_home/.local/share" \
  XDG_CONFIG_HOME="$_no_int_home/.config" XDG_STATE_HOME="$_no_int_home/.local/state" \
  SHELL=/bin/bash "$_link" install --no-shell-integration) \
  >"$_test_root/install-no-int.out" 2>"$_test_root/install-no-int.err"; then
  pass "install --no-shell-integration succeeds"
else
  fail "install --no-shell-integration succeeds"
  cat "$_test_root/install-no-int.err" >&2
fi
if [ -f "$_no_int_home/.bashrc" ] || [ -f "$_no_int_home/.bash_profile" ] ||
  [ -f "$_no_int_home/.zprofile" ] || [ -f "$_no_int_home/.zshrc" ] ||
  [ -f "$_no_int_home/.kshrc" ] || [ -f "$_no_int_home/.profile" ] ||
  [ -f "$_no_int_home/.config/fish/conf.d/valise.fish" ]; then
  fail "install --no-shell-integration writes no startup file or Fish hook"
else
  pass "install --no-shell-integration writes no startup file or Fish hook"
fi

# The profile target is shared by several shells. It must select the plan for
# the running shell and load nothing in dash.
_int_home="$_test_root/home-profile"
mkdir -p "$_int_home"
if (cd "$_release" && HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  SHELL=/bin/bash "$_link" install --no-shell-integration) \
  >"$_test_root/install-profile.out" 2>&1 &&
  HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
    XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
    "$_link" init profile --compiled >"$_int_home/.profile"; then
  pass "init profile --compiled emits an integration snippet"
else
  fail "init profile --compiled emits an integration snippet"
fi

if SHELL=/bin/bash HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  "$_link" init --compiled >"$_test_root/init-auto.out" 2>&1 &&
  grep -F '_valise_plan=bash' "$_test_root/init-auto.out" >/dev/null 2>&1; then
  pass "init --compiled accepts options before the detected shell"
else
  fail "init --compiled accepts options before the detected shell"
  cat "$_test_root/init-auto.out" >&2
fi
if HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  "$_link" init sh --compiled >"$_test_root/init-sh.out" 2>&1 &&
  grep -F 'BASH_VERSION' "$_test_root/init-sh.out" >/dev/null 2>&1; then
  pass "init sh --compiled uses the shared profile selector"
else
  fail "init sh --compiled uses the shared profile selector"
  cat "$_test_root/init-sh.out" >&2
fi

for _shell in bash zsh ksh; do
  case "$_shell" in
    bash) _bin=/bin/bash ;;
    zsh) _bin=/bin/zsh ;;
    ksh) _bin=/bin/ksh ;;
  esac
  if [ ! -x "$_bin" ]; then
    if [ "$_require_tooling" -eq 1 ]; then
      fail "profile snippet loads the compiled plan in $_shell ($_bin unavailable)"
    else
      skip "profile snippet loads the compiled plan in $_shell ($_bin unavailable)"
    fi
  elif HOME="$_int_home" XDG_CONFIG_HOME="$_int_home/.config" \
    "$_bin" -c '. "$HOME/.profile"; command -v root_ready >/dev/null 2>&1; command -v vendor_tool_ready >/dev/null 2>&1; command -v "$1" >/dev/null 2>&1' \
    sh "${_shell}_plan_ready" >"$_test_root/profile-$_shell.out" 2>"$_test_root/profile-$_shell.err"; then
    pass "profile snippet loads the matching compiled plan in $_shell"
  else
    fail "profile snippet loads the matching compiled plan in $_shell"
    cat "$_test_root/profile-$_shell.err" >&2
  fi
done
if [ ! -x /bin/dash ]; then
  if [ "$_require_tooling" -eq 1 ]; then
    fail "profile snippet loads nothing in dash (/bin/dash unavailable)"
  else
    skip "profile snippet loads nothing in dash (/bin/dash unavailable)"
  fi
elif HOME="$_int_home" XDG_CONFIG_HOME="$_int_home/.config" \
  /bin/dash -c '. "$HOME/.profile"' \
  >"$_test_root/profile-dash-source.out" 2>"$_test_root/profile-dash-source.err"; then
  if HOME="$_int_home" XDG_CONFIG_HOME="$_int_home/.config" \
    /bin/dash -c '. "$HOME/.profile"; command -v root_ready >/dev/null 2>&1 || command -v bash_plan_ready >/dev/null 2>&1' \
    >"$_test_root/profile-dash.out" 2>"$_test_root/profile-dash.err"; then
    fail "profile snippet loads nothing in dash"
  else
    pass "profile snippet loads nothing in dash"
  fi
else
  fail "profile snippet sources cleanly in dash"
  cat "$_test_root/profile-dash-source.err" >&2
fi

# variant list must mark the release the active link names, not merely any
# installed release.
_active_target=$(readlink "$_int_home/.config/valise/active") || _active_target=
_active_name=${_active_target##*/}
mkdir -p "$_int_home/.local/share/valise/releases/inactive-release"
if HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  "$_link" variant list >"$_test_root/variant-list.out" 2>&1 &&
  grep -F "* $_active_name (active)" "$_test_root/variant-list.out" >/dev/null 2>&1 &&
  grep -F '  inactive-release' "$_test_root/variant-list.out" >/dev/null 2>&1; then
  pass "variant list marks the active release"
else
  fail "variant list marks the active release"
  cat "$_test_root/variant-list.out" >&2
fi

printf '\n=== valise compile/assemble summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
