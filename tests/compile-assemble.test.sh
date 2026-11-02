#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# Contract test for the compiled-plan consumer workflow: package-install
# symlink resolution, bundle roots without a Python release compiler, the
# built release tree, compiled-plan cleanup, and the integration targets
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
cp "$_repo/lib/metadata.sh" "$_pkg/lib/metadata.sh"
chmod 0755 "$_pkg/bin/valise"
ln -s "$_pkg/bin/valise" "$_link"

# A valid source tree above the package must not win over the project root.
# Compile resolves from the working tree first so build packages the same
# prelude the plan was built against.
mkdir -p "$_test_root/shell/release"
printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'   >"$_test_root/shell/release/module-registry.tsv"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tDecoy\t\n'   >"$_test_root/shell/release/install-variants"

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
  printf 'default\tAll\t\n'
} >"$_project/shell/release/install-variants"

printf '=== valise compile/build consumer contract ===\n'
printf '  project: %s\n\n' "$_project"

# Compile through a symlink, with no consumer compiler fallback,
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

# Build the whole release tree twice. The plans must load, and the two
# manifests must be byte-identical.
for _n in 1 2; do
  if (cd "$_project" && "$_link" build --bundle=default "build/release$_n") \
    >"$_test_root/build$_n.out" 2>"$_test_root/build$_n.err"; then
    pass "build builds release tree $_n"
  else
    fail "build builds release tree $_n"
    cat "$_test_root/build$_n.err" >&2
  fi
done
if (cd "$_project" && "$_link" build --bundle=default "build/../dot-release") \
  >"$_test_root/build-dot.out" 2>"$_test_root/build-dot.err" &&
  [ -f "$_project/dot-release/generated/installed-modules.bash" ]; then
  pass "build normalizes dot segments in an output path"
else
  fail "build normalizes dot segments in an output path"
  cat "$_test_root/build-dot.err" >&2
fi

mkdir -p "$_project/empty-build"
if (cd "$_project" && "$_link" build --bundle=default "empty-build/../empty-build")   >"$_test_root/build-empty.out" 2>"$_test_root/build-empty.err" &&
  [ -f "$_project/empty-build/generated/installed-modules.bash" ]; then
  pass "build accepts an existing empty dot-path destination"
else
  fail "build accepts an existing empty dot-path destination"
  cat "$_test_root/build-empty.err" >&2
fi
if (cd "$_project" && "$_link" build --bundle=default "$_project/absolute-release")   >"$_test_root/build-absolute.out" 2>"$_test_root/build-absolute.err" &&
  [ -f "$_project/absolute-release/generated/installed-modules.bash" ]; then
  pass "build accepts an absolute output path"
else
  fail "build accepts an absolute output path"
  cat "$_test_root/build-absolute.err" >&2
fi

_release="$_project/build/release1"
_scratch_preprocessed=$(find "$_release/generated" -name '.preprocessed.*' -print 2>/dev/null || :)
if [ -z "$_scratch_preprocessed" ]; then
  pass "compiled output contains no preprocessing scratch files"
else
  fail "compiled output contains no preprocessing scratch files"
  printf '%s\n' "$_scratch_preprocessed" >&2
fi
if grep -F '.preprocessed.' "$_release/shell/install/profile-release.manifest" >/dev/null 2>&1; then
  fail "release manifest excludes preprocessing scratch files"
else
  pass "release manifest excludes preprocessing scratch files"
fi
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
    pass "built tree contains $_file"
  else
    fail "built tree contains $_file"
  fi
done
if cmp -s "$_release/shell/install/profile-release.manifest" \
  "$_project/build/release2/shell/install/profile-release.manifest"; then
  pass "repeated build produces a byte-identical manifest"
else
  fail "repeated build produces a byte-identical manifest"
fi

# Metadata is the source of truth. An invalid module name must fail before any
# copy can write outside the staged release.
cat >"$_project/shell/module.d/pwned.meta" <<'EOF'
name=../pwned
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
if (cd "$_project" && "$_link" build --bundle=default build/escape) \
  >"$_test_root/build-escape.out" 2>"$_test_root/build-escape.err"; then
  fail "build rejects an invalid metadata module name"
elif ! grep -F 'metadata: invalid module name: ../pwned' \
  "$_test_root/build-escape.err" >/dev/null 2>&1 ||
  ! grep -F 'valise: error: shell/module.d/pwned.meta: invalid metadata' \
  "$_test_root/build-escape.err" >/dev/null 2>&1; then
  fail "build rejects an invalid metadata module name (wrong diagnostic)"
  cat "$_test_root/build-escape.err" >&2
elif [ -e "$_project/build/escape" ]; then
  fail "build rejects an invalid metadata module name (published output)"
else
  pass "build rejects an invalid metadata module name"
fi
rm -f "$_project/shell/module.d/pwned.meta"

# A load path with a parent segment must fail before the release can copy it.
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
load=modules/../evil.sh
EOF
cat >"$_project/shell/modules/evil.sh" <<'EOF'
evil_loaded() { :; }
EOF
if (cd "$_project" && "$_link" build --bundle=default build/load-escape) \
  >"$_test_root/build-load-escape.out" 2>"$_test_root/build-load-escape.err"; then
  fail "build rejects a metadata load path containing a parent segment"
elif ! grep -F 'metadata: invalid relative path: modules/../evil.sh' \
  "$_test_root/build-load-escape.err" >/dev/null 2>&1 ||
  ! grep -F 'valise: error: shell/module.d/trav.meta: invalid metadata' \
  "$_test_root/build-load-escape.err" >/dev/null 2>&1; then
  fail "build rejects a metadata load path containing a parent segment (wrong diagnostic)"
  cat "$_test_root/build-load-escape.err" >&2
else
  pass "build rejects a metadata load path containing a parent segment"
fi
rm -f "$_project/shell/module.d/trav.meta"
rm -f "$_project/shell/modules/evil.sh"

# Source the compiled plan directly. Capability prelude functions remain
# available to module functions after the plan finishes.
if VALISE_MODULE_ROOT="$_release" /bin/bash -c '
  . "$VALISE_MODULE_ROOT/generated/installed-modules.bash" || exit 1
  command -v root_ready >/dev/null 2>&1 || exit 2
  command -v vendor_tool_ready >/dev/null 2>&1 || exit 3
  command -v bash_plan_ready >/dev/null 2>&1 || exit 4
  if command -v zsh_plan_ready >/dev/null 2>&1; then exit 5; fi
  command -v sp_cap_os >/dev/null 2>&1 || exit 6
' >"$_test_root/plan-bash.out" 2>"$_test_root/plan-bash.err"; then
  pass "compiled bash plan loads its own bodies and keeps capabilities"
else
  fail "compiled bash plan loads its own bodies and keeps capabilities"
  cat "$_test_root/plan-bash.err" >&2
fi
_prelude_fns=$(sed -n 's/^\(sp_cap_[a-zA-Z0-9_]*\)().*/\1/p' "$_pkg/lib/capabilities.sh")
if [ -n "$_prelude_fns" ]; then
  pass "capability prelude exposes runtime functions"
else
  fail "capability prelude exposes runtime functions"
fi
_missing=
for _shell in bash zsh ksh; do
  case "$_shell" in
    bash) _bin=/bin/bash ;;
    zsh) _bin=/bin/zsh ;;
    ksh) _bin=/bin/ksh ;;
  esac
  if [ ! -x "$_bin" ]; then
    if [ "$_require_tooling" -eq 1 ]; then
      fail "$_shell plan keeps every sp_cap_* prelude function ($_bin unavailable)"
    else
      skip "$_shell plan keeps every sp_cap_* prelude function ($_bin unavailable)"
    fi
    continue
  fi
  if VALISE_MODULE_ROOT="$_release" "$_bin" -c '
    . "$VALISE_MODULE_ROOT/generated/installed-modules.$1" || exit 1
    shift
    for _fn do
      if ! command -v "$_fn" >/dev/null 2>&1; then
        printf "%s\n" "$_fn"
        exit 2
      fi
    done
  ' sh "$_shell" $_prelude_fns >"$_test_root/plan-clean-$_shell.out" 2>"$_test_root/plan-clean-$_shell.err"; then
    pass "$_shell plan keeps every sp_cap_* prelude function"
  else
    _missing="$_missing $(cat "$_test_root/plan-clean-$_shell.out")"
    fail "$_shell plan keeps every sp_cap_* prelude function:$_missing"
  fi
done

# install --no-integration must write neither a POSIX startup file nor a
# Fish hook, while still installing and activating the release.
_no_int_home="$_test_root/home-no-int"
mkdir -p "$_no_int_home"
if (cd "$_release" && HOME="$_no_int_home" XDG_DATA_HOME="$_no_int_home/.local/share" \
  XDG_CONFIG_HOME="$_no_int_home/.config" XDG_STATE_HOME="$_no_int_home/.local/state" \
  SHELL=/bin/bash "$_link" install --no-integration) \
  >"$_test_root/install-no-int.out" 2>"$_test_root/install-no-int.err"; then
  pass "install --no-integration succeeds"
else
  fail "install --no-integration succeeds"
  cat "$_test_root/install-no-int.err" >&2
fi
if [ -f "$_no_int_home/.bashrc" ] || [ -f "$_no_int_home/.bash_profile" ] ||
  [ -f "$_no_int_home/.zprofile" ] || [ -f "$_no_int_home/.zshrc" ] ||
  [ -f "$_no_int_home/.kshrc" ] || [ -f "$_no_int_home/.profile" ] ||
  [ -f "$_no_int_home/.config/fish/conf.d/valise.fish" ]; then
  fail "install --no-integration writes no startup file or Fish hook"
else
  pass "install --no-integration writes no startup file or Fish hook"
fi

# A bash user gets ~/.profile and ~/.bashrc. Nothing is created that could change
# what the shell reads: no ~/.bash_profile, and no zsh file without zsh in use.
_mode_home="$_test_root/home-mode-bash"
mkdir -p "$_mode_home"
if (cd "$_release" && HOME="$_mode_home" XDG_DATA_HOME="$_mode_home/.local/share" \
  XDG_CONFIG_HOME="$_mode_home/.config" XDG_STATE_HOME="$_mode_home/.local/state" \
  PATH=/usr/bin:/bin SHELL=/bin/bash "$_link" install --no-integration) >/dev/null 2>&1 &&
  (cd "$_release" && HOME="$_mode_home" XDG_DATA_HOME="$_mode_home/.local/share" \
  XDG_CONFIG_HOME="$_mode_home/.config" XDG_STATE_HOME="$_mode_home/.local/state" \
  SHELL=/bin/bash "$_link" install) \
  >"$_test_root/install-mode.out" 2>"$_test_root/install-mode.err" &&
  grep -F '# BEGIN valise managed block' "$_mode_home/.profile" >/dev/null &&
  grep -F '# BEGIN valise managed block' "$_mode_home/.bashrc" >/dev/null &&
  [ ! -e "$_mode_home/.bash_profile" ] &&
  [ ! -e "$_mode_home/.bash_login" ] &&
  [ ! -e "$_mode_home/.zshrc" ] &&
  [ ! -e "$_mode_home/.kshrc" ]; then
  pass "install writes ~/.profile and ~/.bashrc for a bash user and creates no shadowing file"
else
  fail "install writes ~/.profile and ~/.bashrc for a bash user and creates no shadowing file"
  cat "$_test_root/install-mode.err" >&2
fi

# Doctor checks the startup files the running shell reads.
_doctor_out=$(HOME="$_mode_home" XDG_DATA_HOME="$_mode_home/.local/share" \
  XDG_CONFIG_HOME="$_mode_home/.config" XDG_STATE_HOME="$_mode_home/.local/state" \
  SHELL=/bin/bash "$_link" doctor 2>"$_test_root/doctor-mode.err")
if printf '%s\n' "$_doctor_out" | grep -F "startup file contains the valise managed block: $_mode_home/.profile" >/dev/null &&
  printf '%s\n' "$_doctor_out" | grep -F "startup file contains the valise managed block: $_mode_home/.bashrc" >/dev/null; then
  pass "doctor finds the block in the files bash reads"
else
  fail "doctor finds the block in the files bash reads"
  printf '%s\n' "$_doctor_out" >&2
  cat "$_test_root/doctor-mode.err" >&2
fi
unset _doctor_out

# An engine-shaped release carries entrypoints/profile.sh and the loader
# behind it, but no compiled plans. The integration snippet must fall back
# to the loader entrypoint so installing it never leaves a startup file that
# loads nothing.
_engine_release="$_test_root/engine-release"
mkdir -p "$_engine_release/entrypoints" "$_engine_release/lib" \
  "$_engine_release/module.d" "$_engine_release/modules"
cp "$_repo/entrypoints/profile.sh" "$_engine_release/entrypoints/profile.sh"
cp "$_repo/lib/metadata.sh" "$_repo/lib/capabilities.sh" "$_repo/lib/loader.sh" \
  "$_engine_release/lib/"
cat >"$_engine_release/module.d/engine_root.meta" <<'EOF'
name=engine_root
version=1.0.0
side_effect=read-only
requires=
optional=
shells=bash zsh ksh
platforms=any
exports=engine_root_ready
updates=
load=modules/engine_root.sh
EOF
cat >"$_engine_release/modules/engine_root.sh" <<'EOF'
engine_root_ready() { :; }
EOF
chmod 0644 "$_engine_release/entrypoints/profile.sh" "$_engine_release/lib/"*.sh \
  "$_engine_release/module.d/engine_root.meta" "$_engine_release/modules/engine_root.sh"
if (cd "$_engine_release" && "$_link" make-manifest .) >"$_test_root/engine-manifest.out" 2>&1; then
  pass "engine-shaped release tree is manifestable"
else
  fail "engine-shaped release tree is manifestable"
  cat "$_test_root/engine-manifest.out" >&2
fi

_engine_home="$_test_root/home-engine-release"
mkdir -p "$_engine_home"
if (cd "$_engine_release" && HOME="$_engine_home" XDG_DATA_HOME="$_engine_home/.local/share" \
  XDG_CONFIG_HOME="$_engine_home/.config" XDG_STATE_HOME="$_engine_home/.local/state" \
  "$_link" install) >"$_test_root/install-engine.out" 2>&1; then
  pass "install succeeds for an engine-shaped release"
else
  fail "install succeeds for an engine-shaped release"
  cat "$_test_root/install-engine.out" >&2
fi
if HOME="$_engine_home" XDG_CONFIG_HOME="$_engine_home/.config" \
  VALISE_MODULES=engine_root /bin/bash -c '. "$HOME/.profile"; command -v engine_root_ready' \
  >"$_test_root/engine-profile-bash.out" 2>"$_test_root/engine-profile-bash.err"; then
  pass "profile integration falls back to the loader entrypoint for an engine-shaped release"
else
  fail "profile integration falls back to the loader entrypoint for an engine-shaped release"
  cat "$_test_root/engine-profile-bash.err" >&2
fi

# The same fallback must work in the shell-specific startup file that the
# default (auto) integration writes.
_engine_auto_home="$_test_root/home-engine-auto"
mkdir -p "$_engine_auto_home"
if (cd "$_engine_release" && HOME="$_engine_auto_home" XDG_DATA_HOME="$_engine_auto_home/.local/share" \
  XDG_CONFIG_HOME="$_engine_auto_home/.config" XDG_STATE_HOME="$_engine_auto_home/.local/state" \
  SHELL=/bin/bash "$_link" install) >"$_test_root/install-engine-auto.out" 2>&1; then
  pass "install succeeds for an engine-shaped release"
else
  fail "install succeeds for an engine-shaped release"
  cat "$_test_root/install-engine-auto.out" >&2
fi
_engine_auto_profile="$_engine_auto_home/.bashrc"
if [ -f "$_engine_auto_profile" ] &&
  HOME="$_engine_auto_home" XDG_CONFIG_HOME="$_engine_auto_home/.config" \
  VALISE_MODULES=engine_root /bin/bash -c '. "$1"; command -v engine_root_ready' \
  sh "$_engine_auto_profile" >"$_test_root/engine-auto-bash.out" 2>"$_test_root/engine-auto-bash.err"; then
  pass "auto integration loads an engine-shaped release through the loader entrypoint"
else
  fail "auto integration loads an engine-shaped release through the loader entrypoint"
  cat "$_test_root/engine-auto-bash.err" >&2
fi

# The profile target is shared by several shells. It must select the plan for
# the running shell and load nothing in dash.
_int_home="$_test_root/home-profile"
mkdir -p "$_int_home"
if (cd "$_release" && HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  SHELL=/bin/bash "$_link" install --no-integration) \
  >"$_test_root/install-profile.out" 2>&1 &&
  HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
    XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
    "$_link" init posix >"$_int_home/.profile"; then
  pass "init posix emits an integration snippet"
else
  fail "init posix emits an integration snippet"
fi

if SHELL=/bin/bash HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  "$_link" init >"$_test_root/init-auto.out" 2>&1 &&
  grep -F '# BEGIN valise managed block' "$_test_root/init-auto.out" >/dev/null 2>&1 &&
  grep -F 'BASH_VERSION' "$_test_root/init-auto.out" >/dev/null 2>&1; then
  pass "init prints the POSIX managed block by default"
else
  fail "init prints the POSIX managed block by default"
  cat "$_test_root/init-auto.out" >&2
fi
for _removed in --compiled bash profile; do
  if HOME="$_int_home" "$_link" init "$_removed" >/dev/null 2>"$_test_root/init-removed.err"; then
    fail "init rejects removed argument $_removed"
  else
    pass "init rejects removed argument $_removed"
  fi
done

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

# A built release carries compiled plans but no loader entrypoint. The
# shell-specific startup file the default (auto) integration writes must load
# the compiled plan instead of leaving a file that loads nothing.
_built_auto_home="$_test_root/home-built-auto"
mkdir -p "$_built_auto_home"
if (cd "$_release" && HOME="$_built_auto_home" XDG_DATA_HOME="$_built_auto_home/.local/share" \
  XDG_CONFIG_HOME="$_built_auto_home/.config" XDG_STATE_HOME="$_built_auto_home/.local/state" \
  SHELL=/bin/bash "$_link" install) >"$_test_root/install-built-auto.out" 2>&1; then
  pass "install succeeds for a built release"
else
  fail "install succeeds for a built release"
  cat "$_test_root/install-built-auto.out" >&2
fi
_built_auto_profile="$_built_auto_home/.bashrc"
if [ -f "$_built_auto_profile" ] &&
  HOME="$_built_auto_home" XDG_CONFIG_HOME="$_built_auto_home/.config" \
  /bin/bash -c '. "$1"; command -v root_ready >/dev/null 2>&1; command -v vendor_tool_ready >/dev/null 2>&1' \
  sh "$_built_auto_profile" >"$_test_root/built-auto-bash.out" 2>"$_test_root/built-auto-bash.err"; then
  pass "auto integration loads a built release through the compiled plan"
else
  fail "auto integration loads a built release through the compiled plan"
  cat "$_test_root/built-auto-bash.err" >&2
fi

# release list must mark the release the active link names, not merely any
# installed release.
_active_target=$(readlink "$_int_home/.config/valise/active") || _active_target=
_active_name=${_active_target##*/}
mkdir -p "$_int_home/.local/share/valise/releases/inactive-release"
if HOME="$_int_home" XDG_DATA_HOME="$_int_home/.local/share" \
  XDG_CONFIG_HOME="$_int_home/.config" XDG_STATE_HOME="$_int_home/.local/state" \
  "$_link" release list >"$_test_root/variant-list.out" 2>&1 &&
  grep -F "* $_active_name (active)" "$_test_root/variant-list.out" >/dev/null 2>&1 &&
  grep -F '  inactive-release' "$_test_root/variant-list.out" >/dev/null 2>&1; then
  pass "release list marks the active release"
else
  fail "release list marks the active release"
  cat "$_test_root/variant-list.out" >&2
fi

# A build variant excludes modules from the resolved graph. The exclusion
# names a module identity: a qualified name (name@source) matches that exact
# source, and a bare name matches a primary module. A layer module must be
# excludable by its qualified identity, and a bare exclusion must never
# remove a layer module that happens to share the name.
_exclude_project="$_test_root/exclude-project"
mkdir -p "$_exclude_project/shell/module.d" "$_exclude_project/shell/modules" \
  "$_exclude_project/shell/release" \
  "$_exclude_project/shell/layers/vendor/module.d" \
  "$_exclude_project/shell/layers/vendor/modules/shared"
cat >"$_exclude_project/shell/module.d/root.meta" <<'EOF'
name=root
version=
side_effect=read-only
requires=
optional=
shells=bash zsh ksh
platforms=any
exports=root_ready
updates=
load=modules/root.sh
EOF
printf 'root_ready() { :; }\n' >"$_exclude_project/shell/modules/root.sh"
cat >"$_exclude_project/shell/layers/vendor/module.d/contrib_shared_name.meta" <<'EOF'
name=contrib_shared_name
version=1.0.0
side_effect=read-only
requires=
optional=
shells=bash zsh ksh
platforms=any
exports=vendor_ready
updates=
load=modules/shared/contrib_shared_name.sh
EOF
printf 'vendor_ready() { :; }\n' >"$_exclude_project/shell/layers/vendor/modules/shared/contrib_shared_name.sh"
printf '# bundle\tshell\troots\ndefault\tbash\troot contrib_shared_name@shell/layers/vendor/module.d\ndefault\tzsh\troot contrib_shared_name@shell/layers/vendor/module.d\ndefault\tksh\troot contrib_shared_name@shell/layers/vendor/module.d\n' \
  >"$_exclude_project/shell/release/bundle-roots"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\nworkstation-lean\tNo provider layer\tcontrib_shared_name@shell/layers/vendor/module.d\n' \
  >"$_exclude_project/shell/release/install-variants"

(cd "$_exclude_project" && "$_link" registry) >/dev/null 2>&1
if (cd "$_exclude_project" && "$_link" compile --variant=default full-out) >"$_test_root/exclude-full.out" 2>&1 &&
  grep -F '# order=contrib_shared_name root' "$_exclude_project/full-out/installed-modules.bash" >/dev/null 2>&1; then
  pass "the full variant keeps the provider layer module"
else
  fail "the full variant keeps the provider layer module"
  cat "$_test_root/exclude-full.out" >&2
fi

# The qualified exclusion must actually remove the layer module. The layer
# module is a bundle root here, so the seed filter removes it.
if (cd "$_exclude_project" && "$_link" compile --variant=workstation-lean lean-out) >"$_test_root/exclude-lean.out" 2>&1 &&
  grep -F '# order=root' "$_exclude_project/lean-out/installed-modules.bash" >/dev/null 2>&1 &&
  ! grep -F 'contrib_shared_name' "$_exclude_project/lean-out/installed-modules.bash" >/dev/null 2>&1; then
  pass "a qualified variant exclusion removes the provider layer module"
else
  fail "a qualified variant exclusion removes the provider layer module"
  cat "$_test_root/exclude-lean.out" >&2
fi

# A qualified exclusion must also remove a layer module that is reached as a
# DEPENDENCY of a surviving module rather than as a bundle root. The seed
# filter only sees roots, so this is the case the registry row filter has to
# handle. Before the fix the row filter was gated on the primary source, so
# the excluded layer module stayed in the plan.
printf '# bundle\tshell\troots\ndefault\tbash\tneeds_layer\ndefault\tzsh\tneeds_layer\ndefault\tksh\tneeds_layer\n' \
  >"$_exclude_project/shell/release/bundle-roots"
cat >"$_exclude_project/shell/module.d/needs_layer.meta" <<'EOF'
name=needs_layer
version=
side_effect=read-only
requires=contrib_shared_name
optional=
shells=bash zsh ksh
platforms=any
exports=needs_layer_ready
updates=
load=modules/needs_layer.sh
EOF
printf 'needs_layer_ready() { :; }\n' >"$_exclude_project/shell/modules/needs_layer.sh"
(cd "$_exclude_project" && "$_link" registry) >/dev/null 2>&1
if (cd "$_exclude_project" && "$_link" compile --variant=workstation-lean lean-dep-out) >"$_test_root/exclude-lean-dep.out" 2>&1; then
  if grep -F 'contrib_shared_name' "$_exclude_project/lean-dep-out/installed-modules.bash" >/dev/null 2>&1; then
    fail "a qualified variant exclusion removes a layer module reached as a dependency"
    cat "$_test_root/exclude-lean-dep.out" >&2
  else
    pass "a qualified variant exclusion removes a layer module reached as a dependency"
  fi
else
  # A compile failure is acceptable here only if it names the exclusion as the
  # cause; silently excluding the dependency would leave a broken profile.
  if grep -F 'variant exclusion breaks a required dependency' "$_test_root/exclude-lean-dep.out" >/dev/null 2>&1; then
    pass "a qualified variant exclusion removes a layer module reached as a dependency"
  else
    fail "a qualified variant exclusion removes a layer module reached as a dependency"
    cat "$_test_root/exclude-lean-dep.out" >&2
  fi
fi

# A bare exclusion names a primary module. It must not remove a layer module
# that happens to share the name, and it must not remove a primary module
# that the exclusion did not name.
printf '# bundle\tshell\troots\ndefault\tbash\troot contrib_shared_name@shell/layers/vendor/module.d\ndefault\tzsh\troot contrib_shared_name@shell/layers/vendor/module.d\ndefault\tksh\troot contrib_shared_name@shell/layers/vendor/module.d\n' \
  >"$_exclude_project/shell/release/bundle-roots"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\nworkstation-lean\tNo primary root\troot\n' \
  >"$_exclude_project/shell/release/install-variants"
if (cd "$_exclude_project" && "$_link" compile --variant=workstation-lean lean-bare-out) >"$_test_root/exclude-bare.out" 2>&1; then
  if grep -F '# order=contrib_shared_name' "$_exclude_project/lean-bare-out/installed-modules.bash" >/dev/null 2>&1 &&
    ! grep -F 'root_ready' "$_exclude_project/lean-bare-out/installed-modules.bash" >/dev/null 2>&1; then
    pass "a bare variant exclusion removes only the named primary module"
  else
    fail "a bare variant exclusion removes only the named primary module"
    cat "$_test_root/exclude-bare.out" >&2
  fi
else
  fail "a bare variant exclusion removes only the named primary module"
  cat "$_test_root/exclude-bare.out" >&2
fi

# An exclusion that breaks a required dependency must name both modules, not
# surface as the compiler's generic "unknown module".
cat >"$_exclude_project/shell/module.d/needs_vendor.meta" <<'EOF'
name=needs_vendor
version=
side_effect=read-only
requires=contrib_shared_name
optional=
shells=bash zsh ksh
platforms=any
exports=needs_vendor_ready
updates=
load=modules/needs_vendor.sh
EOF
printf 'needs_vendor_ready() { :; }\n' >"$_exclude_project/shell/modules/needs_vendor.sh"
printf '# bundle\tshell\troots\ndefault\tbash\tneeds_vendor\ndefault\tzsh\tneeds_vendor\ndefault\tksh\tneeds_vendor\n' \
  >"$_exclude_project/shell/release/bundle-roots"
printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll\t\nworkstation-lean\tNo provider layer\tcontrib_shared_name@shell/layers/vendor/module.d\n' \
  >"$_exclude_project/shell/release/install-variants"
(cd "$_exclude_project" && "$_link" registry) >/dev/null 2>&1
if (cd "$_exclude_project" && "$_link" compile --variant=workstation-lean broken-out) >"$_test_root/exclude-broken.out" 2>&1; then
  fail "an exclusion that breaks a required dependency fails the compile"
  cat "$_test_root/exclude-broken.out" >&2
else
  pass "an exclusion that breaks a required dependency fails the compile"
fi
if grep -F 'variant exclusion breaks a required dependency' "$_test_root/exclude-broken.out" >/dev/null 2>&1 &&
  grep -F 'needs_vendor requires contrib_shared_name' "$_test_root/exclude-broken.out" >/dev/null 2>&1; then
  pass "the broken-dependency diagnostic names both modules"
else
  fail "the broken-dependency diagnostic names both modules"
  cat "$_test_root/exclude-broken.out" >&2
fi

# A previous successful build must survive a bad variant or bundle: the
# default output is replaced only after the new tree has compiled.
if (cd "$_project" && "$_link" build --variant=default >/dev/null 2>&1); then
  _kept_plan="$_project/build/release/generated/installed-modules.bash"
  if (cd "$_project" && "$_link" build --variant=no-such-variant) >"$_test_root/typo-variant.out" 2>"$_test_root/typo-variant.err"; then
    fail "a typo variant does not build"
  elif [ -f "$_kept_plan" ]; then
    pass "a typo variant preserves the previous build output"
  else
    fail "a typo variant preserves the previous build output"
  fi
  printf 'broken\tBroken\tno_such_module\n' >>"$_project/shell/release/install-variants"
  if (cd "$_project" && "$_link" build --variant=broken) >"$_test_root/typo-exclusion.out" 2>"$_test_root/typo-exclusion.err"; then
    fail "a variant with a bad exclusion does not build"
  elif [ -f "$_kept_plan" ]; then
    pass "a variant with a bad exclusion preserves the previous build output"
  else
    fail "a variant with a bad exclusion preserves the previous build output"
  fi
  printf 'broken-bundle\tbash\tmissing_root\nbroken-bundle\tzsh\tmissing_root\nbroken-bundle\tksh\tmissing_root\n' >>"$_project/shell/release/bundle-roots"
  if (cd "$_project" && "$_link" build --bundle=broken-bundle) >"$_test_root/typo-bundle.out" 2>"$_test_root/typo-bundle.err"; then
    fail "a bundle with a missing root does not build"
  elif [ -f "$_kept_plan" ]; then
    pass "a bundle with a missing root preserves the previous build output"
  else
    fail "a bundle with a missing root preserves the previous build output"
  fi
else
  fail "baseline build before the failed-build tests"
fi

# An explicit output inside the project must not traverse a symlink.
_external_explicit="$_test_root/external-explicit-parent"
mkdir -p "$_external_explicit/out"
ln -sfn "$_external_explicit" "$_project/explicit-link"
if (cd "$_project" && "$_link" build explicit-link/out) >"$_test_root/explicit-symlink.out" 2>"$_test_root/explicit-symlink.err"; then
  fail "build refuses an explicit output through a symlink"
elif [ -d "$_external_explicit/out" ]; then
  pass "build refuses an explicit output through a symlink"
else
  fail "build refuses an explicit output through a symlink"
fi
rm -f "$_project/explicit-link"

# Clearing build/release must not follow a symlinked build parent outside the
# project: the default output is validated as a physical path first.
_external_build="$_test_root/external-build-parent"
mkdir -p "$_external_build/release"
printf '%s\n' keep >"$_external_build/release/sentinel"
rm -rf "$_project/build"
ln -sfn "$_external_build" "$_project/build"
if (cd "$_project" && "$_link" build) >"$_test_root/symlink-build.out" 2>"$_test_root/symlink-build.err"; then
  fail "build refuses a symlinked build parent"
elif [ -f "$_external_build/release/sentinel" ]; then
  pass "build refuses a symlinked build parent and preserves its data"
else
  fail "build refuses a symlinked build parent and preserves its data"
fi
rm -f "$_project/build"

printf '\n=== valise compile/build summary ===\n'
printf 'Total: %d  Pass: %d  Skip: %d  Fail: %d\n' "$_total" "$_pass" "$_skip" "$_fail"
[ "$_fail" -eq 0 ] || exit 1
