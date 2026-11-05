# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: project commands: compile, registry, new, module, build, apply,
# status, explain-variant, explain-bundles, layer-lint.
# Sourced by bin/valise; not executable on its own.
#
# A valise project is the directory that holds valise.conf:
#
#   valise.conf                 variant=, bundle=, requires_valise=
#   bundles.tsv                 bundle<TAB>shell<TAB>space-separated roots
#   variants.tsv                variant<TAB>description<TAB>excluded modules
#   module.d/<name>.meta        primary modules; bodies resolve against the root
#   layers/<p>/module.d/*.meta  contribution layers; bodies resolve in layers/<p>
#
# The engine's own modules (module.d/valise_*.meta in the engine) are always
# available to a build under the registry source "valise". The registry is an
# internal, generated table; nothing in the project commits it.

VALISE_PROJECT_SHELLS="sh bash zsh ksh"

# project_find_root [start]
# Print the nearest ancestor of start (default: the working directory) that
# holds valise.conf.
project_find_root() {
  _pfr_dir=${1:-}
  if [ -z "$_pfr_dir" ]; then
    _pfr_dir=$(pwd -P) || return 1
  fi
  while :; do
    if [ -f "$_pfr_dir/valise.conf" ] && [ ! -L "$_pfr_dir/valise.conf" ]; then
      printf '%s\n' "$_pfr_dir"
      return 0
    fi
    [ "$_pfr_dir" != "/" ] && [ -n "$_pfr_dir" ] || return 1
    _pfr_dir=$(path_parent "$_pfr_dir")
  done
}

# version_at_least <have> <want>
# Succeed when the dotted numeric version have is >= want.
version_at_least() {
  _val_awk=$(trusted_utility_path awk) || return 1
  "$_val_awk" -v have="$1" -v want="$2" 'BEGIN {
    nh = split(have, h, "."); nw = split(want, w, ".")
    n = nh > nw ? nh : nw
    for (i = 1; i <= n; i++) {
      a = (i <= nh) ? h[i] + 0 : 0; b = (i <= nw) ? w[i] + 0 : 0
      if (a > b) exit 0
      if (a < b) exit 1
    }
    exit 0
  }'
}

# project_config_load
# Find the project and read valise.conf. Sets _project_root, _project_variant,
# _project_bundle and _project_requires.
project_config_load() {
  _project_root=$(project_find_root) ||
    die "not inside a valise project: no valise.conf in $(pwd -P) or any parent (run 'valise new' or pass -C <dir>)"
  [ -n "${HOME:-}" ] || die "HOME is required for project commands"
  _project_variant=default
  _project_bundle=default
  _project_requires=
  _project_lint_forbid=
  _pc_seen=" "
  while IFS= read -r _pc_line || [ -n "$_pc_line" ]; do
    case "$_pc_line" in
    '' | '#'*) continue ;;
    *=*) ;;
    *) die "valise.conf: invalid line: $_pc_line" ;;
    esac
    _pc_key=${_pc_line%%=*}
    case "$_pc_seen" in
    *" $_pc_key "*) die "valise.conf: duplicate key: $_pc_key" ;;
    esac
    _pc_seen="$_pc_seen$_pc_key "
    case "$_pc_key" in
    variant) _project_variant=${_pc_line#*=} ;;
    bundle) _project_bundle=${_pc_line#*=} ;;
    requires_valise) _project_requires=${_pc_line#*=} ;;
    lint_layer_forbid) _project_lint_forbid=${_pc_line#*=} ;;
    *) die "valise.conf: unknown key: $_pc_key (known: variant, bundle, requires_valise, lint_layer_forbid)" ;;
    esac
  done <"$_project_root/valise.conf"
  [ -n "$_project_variant" ] || die "valise.conf: variant must not be empty"
  [ -n "$_project_bundle" ] || die "valise.conf: bundle must not be empty"
  if [ -n "$_project_requires" ]; then
    case "$_project_requires" in
    *[!0-9.]* | .* | *. | *..*) die "valise.conf: requires_valise must be a dotted version: $_project_requires" ;;
    esac
    version_at_least "$VALISE_VERSION" "$_project_requires" ||
      die "this project requires valise >= $_project_requires (this is valise $VALISE_VERSION)"
  fi
  [ -f "$_project_root/bundles.tsv" ] && [ ! -L "$_project_root/bundles.tsv" ] ||
    die "project has no bundles.tsv: $_project_root"
  if [ -e "$_project_root/variants.tsv" ] || [ -L "$_project_root/variants.tsv" ]; then
    [ -f "$_project_root/variants.tsv" ] && [ ! -L "$_project_root/variants.tsv" ] ||
      die "variants.tsv must be a regular file: $_project_root/variants.tsv"
  fi
  unset _pc_line _pc_key _pc_seen
}

# project_source_dir <project-root> <registry-source>
# Directory a module's load, executables and tests paths resolve against.
project_source_dir() {
  case "$2" in
  module.d) printf '%s\n' "$1" ;;
  valise) engine_root ;;
  layers/*/module.d) _psd_layer=${2#layers/}; printf '%s\n' "$1/layers/${_psd_layer%/module.d}" ;;
  *) return 1 ;;
  esac
}

# project_release_prefix <registry-source>
# Release-relative directory holding a module's files.
project_release_prefix() {
  case "$1" in
  module.d) printf '%s\n' '' ;;
  valise) printf '%s\n' 'valise/' ;;
  layers/*/module.d) _prp_layer=${1#layers/}; printf '%s\n' "layers/${_prp_layer%/module.d}/" ;;
  *) return 1 ;;
  esac
}

# registry_generate <project-root> <output-file>
# Write the module registry implied by the project's and the engine's
# metadata. Columns: name version side_effect requires optional shells
# platforms exports load commands executables tests source.
registry_generate() {
  _rg_root=$1
  _rg_out=$2
  _rg_engine=$(engine_root) || die "cannot locate the valise engine"
  _rg_metadata="$_rg_engine/lib/metadata.sh"
  [ -r "$_rg_metadata" ] || die "metadata library not found: $_rg_metadata"
  (
    export LC_ALL=C
    # shellcheck disable=SC1090
    . "$_rg_metadata"
    printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tcommands\texecutables\ttests\tsource\n'
    for _rg_meta in "$_rg_root"/module.d/*.meta "$_rg_root"/layers/*/module.d/*.meta "$_rg_engine"/module.d/*.meta; do
      [ -f "$_rg_meta" ] || continue
      case "$_rg_meta" in
      "$_rg_engine"/module.d/*)
        _rg_base=$_rg_engine
        _rg_source=valise
        ;;
      *)
        _rg_base=$_rg_root
        _rg_source=${_rg_meta#"$_rg_root"/}
        _rg_source=${_rg_source%/*}
        ;;
      esac
      _rg_rel=${_rg_meta#"$_rg_base"/}
      source_path_is_physical "$_rg_base" "$_rg_rel" || {
        printf 'valise: error: metadata path contains a symlink: %s\n' "$_rg_rel" >&2
        exit 1
      }
      case "$_rg_source" in
      module.d | valise) ;;
      layers/*/module.d)
        _rg_layer=${_rg_source#layers/}
        _rg_layer=${_rg_layer%/module.d}
        case "$_rg_layer" in
        '' | */* | *..* | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*)
          printf 'valise: error: invalid layer directory name: %s\n' "$_rg_rel" >&2
          exit 1
          ;;
        esac
        ;;
      *)
        printf 'valise: error: unsupported metadata location: %s\n' "$_rg_rel" >&2
        exit 1
        ;;
      esac
      _rg_record=$(sp_metadata_read "$_rg_meta" 2>&1) || {
        printf 'valise: error: %s: %s\n' "$_rg_rel" "${_rg_record:-invalid metadata}" >&2
        exit 1
      }
      _rg_name= _rg_version= _rg_side_effect= _rg_requires= _rg_optional= _rg_shells=
      _rg_platforms= _rg_exports= _rg_load= _rg_commands= _rg_executables= _rg_tests=
      while IFS= read -r _rg_line; do
        case "$_rg_line" in
        name=*) _rg_name=${_rg_line#name=} ;;
        version=*) _rg_version=${_rg_line#version=} ;;
        side_effect=*) _rg_side_effect=${_rg_line#side_effect=} ;;
        requires=*) _rg_requires=${_rg_line#requires=} ;;
        optional=*) _rg_optional=${_rg_line#optional=} ;;
        shells=*) _rg_shells=${_rg_line#shells=} ;;
        platforms=*) _rg_platforms=${_rg_line#platforms=} ;;
        exports=*) _rg_exports=${_rg_line#exports=} ;;
        load=*) _rg_load=${_rg_line#load=} ;;
        commands=*) _rg_commands=${_rg_line#commands=} ;;
        executables=*) _rg_executables=${_rg_line#executables=} ;;
        tests=*) _rg_tests=${_rg_line#tests=} ;;
        esac
      done <<EOF
$_rg_record
EOF
      _rg_file_name=${_rg_meta##*/}
      _rg_file_name=${_rg_file_name%.meta}
      if [ "$_rg_name" != "$_rg_file_name" ]; then
        printf 'valise: error: %s: metadata name %s does not match file name %s\n' "$_rg_rel" "$_rg_name" "$_rg_file_name" >&2
        exit 1
      fi
      case "$_rg_source:$_rg_name" in
      valise:valise_*) ;;
      valise:*)
        printf 'valise: error: %s: engine module %s must use the valise_ prefix\n' "$_rg_rel" "$_rg_name" >&2
        exit 1
        ;;
      *:valise_*)
        printf 'valise: error: %s: the valise_ prefix is reserved for engine modules: %s\n' "$_rg_rel" "$_rg_name" >&2
        exit 1
        ;;
      layers/*:contrib_*) ;;
      layers/*)
        printf 'valise: error: %s: layer module name %s must use the contrib_ prefix\n' "$_rg_rel" "$_rg_name" >&2
        exit 1
        ;;
      esac
      _rg_dir=${_rg_rel%/module.d/*}
      [ "$_rg_dir" != "$_rg_rel" ] || _rg_dir=
      # Every file the module names must exist inside its own source
      # directory, as a regular file reached without a symlink.
      for _rg_path in $_rg_load $_rg_executables $_rg_tests; do
        _rg_path_rel=${_rg_dir:+$_rg_dir/}$_rg_path
        if ! source_path_is_physical "$_rg_base" "$_rg_path_rel"; then
          printf 'valise: error: %s: path contains a symlink: %s\n' "$_rg_rel" "$_rg_path" >&2
          exit 1
        fi
        if [ ! -f "$_rg_base/$_rg_path_rel" ]; then
          printf 'valise: error: %s: file does not exist: %s\n' "$_rg_rel" "$_rg_path" >&2
          exit 1
        fi
      done
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_rg_name" "$_rg_version" "$_rg_side_effect" "$_rg_requires" \
        "$_rg_optional" "$_rg_shells" "$_rg_platforms" "$_rg_exports" \
        "$_rg_load" "$_rg_commands" "$_rg_executables" "$_rg_tests" "$_rg_source"
    done
  ) >"$_rg_out" || die "cannot generate module registry"
  unset _rg_root _rg_out _rg_engine _rg_metadata
}

cmd_registry() {
  _registry_out=""
  for _registry_arg do
    case "$_registry_arg" in
    --help | -h) usage_registry; return 0 ;;
    --*) die "unknown registry option: $_registry_arg" ;;
    *) [ -z "$_registry_out" ] || die "usage: valise registry [path]"; _registry_out=$_registry_arg ;;
    esac
  done
  project_config_load
  if [ -z "$_registry_out" ]; then
    _rg_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-registry.XXXXXX") ||
      die "cannot create registry scratch file"
    registry_generate "$_project_root" "$_rg_tmp"
    _registry_cat=$(trusted_utility_path cat) || die "no trusted cat utility available"
    "$_registry_cat" "$_rg_tmp"
    _registry_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_registry_rm" -f "$_rg_tmp"
    _rg_tmp=""
    return 0
  fi
  _registry_out=$(path_normalize "$_registry_out") || die "cannot resolve registry output path"
  if [ -e "$_registry_out" ] || [ -L "$_registry_out" ]; then
    [ -f "$_registry_out" ] && [ ! -L "$_registry_out" ] || die "registry output path is not a regular file: $_registry_out"
  fi
  _registry_parent=$(path_parent "$_registry_out")
  [ -d "$_registry_parent" ] || die "registry output directory does not exist: $_registry_parent"
  _rg_tmp=$(trusted_mktemp_at "$_registry_parent" file "$_registry_parent/.valise-registry.XXXXXX") ||
    die "cannot create registry staging file"
  registry_generate "$_project_root" "$_rg_tmp"
  _registry_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_registry_chmod" 0644 "$_rg_tmp" || die "cannot set registry file mode"
  _registry_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_registry_mv" -f "$_rg_tmp" "$_registry_out" || die "cannot publish registry: $_registry_out"
  _rg_tmp=""
}

# project_bundle_roots <project-root> <shell> <bundle>
# Print the roots bundles.tsv gives the shell in the bundle (possibly none).
# An unknown bundle, an unknown shell name, or a malformed row is an error.
project_bundle_roots() {
  _pbr_awk=$(trusted_utility_path awk) || return 1
  "$_pbr_awk" -F '\t' -v b="$3" -v s="$2" -v file="$1/bundles.tsv" '
    /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
    !header_done { header_done = 1; if ($1 == "bundle" && $2 == "shell") next }
    {
      if (NF < 2 || NF > 3 || $1 == "" || $2 !~ /^(sh|bash|zsh|ksh|fish)$/) {
        printf "valise: error: %s:%d: expected bundle<TAB>shell<TAB>roots with shell one of sh bash zsh ksh fish\n", file, NR > "/dev/stderr"
        bad = 1; exit 1
      }
      if ($1 == b) {
        known = 1
        if ($2 == s && $3 != "") out = out (out == "" ? "" : " ") $3
      }
    }
    END {
      if (bad) exit 1
      if (!known) { print "valise: error: unknown bundle: " b > "/dev/stderr"; exit 1 }
      if (out != "") print out
    }
  ' "$1/bundles.tsv"
}

# project_bundle_names <project-root>
project_bundle_names() {
  _pbn_awk=$(trusted_utility_path awk) || return 1
  "$_pbn_awk" -F '\t' '
    /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
    !header_done { header_done = 1; if ($1 == "bundle" && $2 == "shell") next }
    !seen[$1]++ { print $1 }
  ' "$1/bundles.tsv"
}

# project_variant_field <project-root> <variant> <description|excluded>
# Print a variant's field. Without variants.tsv the only variant is default,
# which excludes nothing. An unknown or duplicated variant is an error.
project_variant_field() {
  if [ ! -f "$1/variants.tsv" ]; then
    [ "$2" = default ] || { printf 'valise: error: unknown variant: %s (the project has no variants.tsv)\n' "$2" >&2; return 1; }
    [ "$3" != description ] || printf '%s\n' 'All modules'
    return 0
  fi
  _pvf_awk=$(trusted_utility_path awk) || return 1
  "$_pvf_awk" -F '\t' -v v="$2" -v field="$3" '
    /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
    !header_done { header_done = 1; if ($1 == "variant" || $1 == "variant_name") next }
    $1 == v { count++; desc = $2; excl = $3 }
    END {
      if (count != 1) {
        printf "valise: error: %s variant: %s\n", (count ? "duplicated" : "unknown"), v > "/dev/stderr"
        exit 1
      }
      print (field == "description" ? desc : excl)
    }
  ' "$1/variants.tsv"
}

# project_variant_names <project-root>
project_variant_names() {
  if [ ! -f "$1/variants.tsv" ]; then
    printf '%s\n' default
    return 0
  fi
  _pvn_awk=$(trusted_utility_path awk) || return 1
  "$_pvn_awk" -F '\t' '
    /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
    !header_done { header_done = 1; if ($1 == "variant" || $1 == "variant_name") next }
    { print $1 }
  ' "$1/variants.tsv"
}

# project_prelude_functions
# Print the sp_cap_ functions the capability prelude defines.
project_prelude_functions() {
  _ppf_prelude="$(engine_root)/lib/capabilities.sh"
  [ -r "$_ppf_prelude" ] || die "capabilities prelude not found: $_ppf_prelude"
  _ppf_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _ppf_fns=$("$_ppf_awk" '
    match($0, /^sp_cap_[A-Za-z0-9_]*\(\)[[:space:]]*[({]/) {
      name = substr($0, 1, index($0, "(") - 1)
      out = out (out == "" ? "" : " ") name
    }
    END { print out }
  ' "$_ppf_prelude")
  [ -n "$_ppf_fns" ] || die "capabilities prelude contains no sp_cap_ functions"
  printf '%s\n' "$_ppf_fns"
}

# project_preprocess <registry> <shell> <seeds> <excludes> <prelude-fns>
# Print the compiler input stream for one shell. Seeds and exclusions are
# module references: name@source names one registry row exactly; a bare name
# means the primary module of that name, else the only module of that name.
# Dependencies resolve within the requiring module's source first, then to the
# only module of that name. Excluded modules are reported, not dropped, so a
# dependency on one is diagnosed by name.
project_preprocess() {
  _pp_awk=$(trusted_utility_path awk) || return 1
  "$_pp_awk" -F '\t' -v shell="$2" -v seeds="$3" -v excludes="$4" -v prelude="$5" '
    function shell_ok(shells,   n, i, v) {
      n = split(shells, v, " ")
      for (i = 1; i <= n; i++) {
        if (v[i] == shell) return 1
        if (v[i] == "posix" && shell != "fish") return 1
      }
      return 0
    }
    function resolve_ref(ref, what,   count, key, found) {
      if (index(ref, "@") > 0) {
        if (ref in row) return ref
        printf "valise: error: unknown %s: %s\n", what, ref > "/dev/stderr"
        failed = 1
        return ""
      }
      if ((ref "@module.d") in row) return ref "@module.d"
      count = 0
      for (key in row) if (row_name[key] == ref) { count++; found = key }
      if (count == 1) return found
      printf "valise: error: %s %s: %s\n", (count ? "ambiguous" : "unknown"), what, ref > "/dev/stderr"
      if (count) printf "valise: error: qualify it as name@source (see valise registry)\n" > "/dev/stderr"
      failed = 1
      return ""
    }
    function resolve_dep(dep, src,   count, key, found) {
      if ((dep "@" src) in avail) return dep "@" src
      count = 0
      for (key in avail) if (row_name[key] == dep) { count++; found = key }
      return count == 1 ? found : dep
    }
    function prefix_of(src,   layer) {
      if (src == "module.d") return ""
      if (src == "valise") return "valise/"
      layer = src; sub(/^layers\//, "", layer); sub(/\/module\.d$/, "", layer)
      return "layers/" layer "/"
    }
    NR == 1 { next }
    {
      id = $1 "@" $13
      row[id] = 1; row_name[id] = $1; row_src[id] = $13
      row_req[id] = $4; row_opt[id] = $5; row_load[id] = $9
      row_platforms[id] = $7; row_side[id] = $3; row_exports[id] = $8
      if (shell_ok($6)) avail[id] = 1
    }
    END {
      n = split(excludes, ex, " ")
      for (i = 1; i <= n; i++) {
        if (ex[i] == "") continue
        r = resolve_ref(ex[i], "excluded module")
        if (r != "") excluded[r] = 1
      }
      seed_out = ""
      n = split(seeds, sd, " ")
      for (i = 1; i <= n; i++) {
        if (sd[i] == "") continue
        r = resolve_ref(sd[i], "bundle root")
        if (r == "" || (r in excluded)) continue
        if (!(r in avail)) {
          printf "valise: error: bundle root %s does not support shell %s\n", sd[i], shell > "/dev/stderr"
          failed = 1
          continue
        }
        seed_out = seed_out (seed_out == "" ? "" : " ") r
      }
      if (failed) exit 1
      print "SEED:" seed_out
      print "PRELUDE:" prelude
      for (id in avail) {
        if (id in excluded) { printf "EXCLUDED:%s\t%s\n", id, row_name[id]; continue }
        req = ""
        m = split(row_req[id], parts, " ")
        for (j = 1; j <= m; j++) if (parts[j] != "") req = req (req == "" ? "" : " ") resolve_dep(parts[j], row_src[id])
        opt = ""
        m = split(row_opt[id], parts, " ")
        for (j = 1; j <= m; j++) {
          if (parts[j] == "") continue
          dep = resolve_dep(parts[j], row_src[id])
          if ((dep in avail) && !(dep in excluded)) opt = opt (opt == "" ? "" : " ") dep
        }
        load = row_load[id]
        if (load != "") load = prefix_of(row_src[id]) load
        printf "MOD:%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, req, load, row_platforms[id], row_side[id], row_exports[id], opt
      }
    }
  ' "$1"
}

# project_effective_roots <registry> <shell> <roots> <excludes>
# Print the qualified roots that remain for the shell once the variant's
# exclusions apply: the seeds the compiler starts from.
project_effective_roots() {
  _per_prelude=$(project_prelude_functions) || exit 1
  _per_stream=$(project_preprocess "$1" "$2" "$3" "$4" "$_per_prelude") ||
    die "cannot resolve the $2 module graph"
  _per_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  printf '%s\n' "$_per_stream" | "$_per_awk" '/^SEED:/ { print substr($0, 6); exit }'
  unset _per_prelude _per_stream _per_awk
}

# project_compile <registry> <shell> <seeds> <excludes> <output> [plan|closure]
# Compile one plan (or print its ordered closure) into output.
project_compile() {
  _pcm_engine=$(engine_root) || die "cannot locate the valise engine"
  _pcm_compiler="$_pcm_engine/lib/compiler.awk"
  [ -r "$_pcm_compiler" ] || die "compiler not found: $_pcm_compiler"
  _pcm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _pcm_stream="$5.stream"
  _pcm_prelude=$(project_prelude_functions) || exit 1
  project_preprocess "$1" "$2" "$3" "$4" "$_pcm_prelude" >"$_pcm_stream" ||
    die "cannot resolve the $2 module graph"
  if ! "$_pcm_awk" -v target_shell="$2" -v plan_name="$2" -v mode="${6:-plan}" -f "$_pcm_compiler" \
    "$_pcm_stream" >"$5"; then
    die "cannot compile the $2 module graph"
  fi
  _pcm_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  "$_pcm_rm" -f "$_pcm_stream" || die "cannot remove compiler scratch file"
  unset _pcm_engine _pcm_compiler _pcm_awk _pcm_stream _pcm_rm _pcm_prelude
}

# project_output_check <out> <replace>
# Validate a build or compile destination. Sets _poc_existed (0 none, 1 empty
# directory, 2 non-empty directory that may be replaced).
project_output_check() {
  _poc_existed=0
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -d "$1" ] && [ ! -L "$1" ] || die "output path is not a directory: $1"
    _poc_existed=1
    for _poc_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
      if [ -e "$_poc_entry" ] || [ -L "$_poc_entry" ]; then
        _poc_existed=2
        break
      fi
    done
    [ "$_poc_existed" -eq 1 ] || [ "$2" -eq 1 ] || die "output directory must be empty: $1"
  fi
}

# project_publish <stage> <out>
# Move a finished stage to out. A previous tree at out is renamed aside first
# and restored if the move fails, so a failed publication never loses it.
project_publish() {
  _pub_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  _pub_parent=$(path_parent "$2")
  case "$_poc_existed" in
  0) ;;
  1)
    _pub_rmdir=$(trusted_utility_path rmdir) || die "no trusted rmdir utility available"
    "$_pub_rmdir" "$2" || die "cannot clear empty output directory: $2"
    ;;
  2)
    _publish_previous=$(trusted_mktemp_at "$_pub_parent" dir "$_pub_parent/.valise-previous.XXXXXX") ||
      die "cannot reserve a place for the previous output"
    "$_pub_mv" "$2" "$_publish_previous/tree" || die "cannot move the previous output aside: $2"
    ;;
  esac
  if ! "$_pub_mv" "$1" "$2"; then
    if [ -n "${_publish_previous:-}" ] && [ ! -e "$2" ] &&
      "$_pub_mv" "$_publish_previous/tree" "$2" 2>/dev/null; then
      remove_tree "$_publish_previous" || :
      _publish_previous=""
    fi
    die "cannot publish $2"
  fi
  if [ -n "${_publish_previous:-}" ]; then
    remove_tree "$_publish_previous" || info "warning: cannot remove the previous output: $_publish_previous"
    _publish_previous=""
  fi
  unset _pub_mv _pub_parent _pub_rmdir
}

cmd_compile() {
  _co_out=""
  _co_variant=""
  _co_bundle=""
  for _co_arg do
    case "$_co_arg" in
    --variant=*) _co_variant=${_co_arg#--variant=}; [ -n "$_co_variant" ] || die "variant name must not be empty" ;;
    --bundle=*) _co_bundle=${_co_arg#--bundle=}; [ -n "$_co_bundle" ] || die "bundle name must not be empty" ;;
    --help | -h) usage_compile; return 0 ;;
    --*) die "unknown compile option: $_co_arg" ;;
    *) [ -z "$_co_out" ] || die "usage: valise compile [--bundle=<name>] [--variant=<name>] <output-dir>"; _co_out=$_co_arg ;;
    esac
  done
  [ -n "$_co_out" ] || die "usage: valise compile [--bundle=<name>] [--variant=<name>] <output-dir>"
  project_config_load
  [ -n "$_co_variant" ] || _co_variant=$_project_variant
  [ -n "$_co_bundle" ] || _co_bundle=$_project_bundle
  _co_out=$(path_normalize "$_co_out") || die "cannot resolve output path"
  [ "$_co_out" != "/" ] || die "output directory must not be /"
  project_output_check "$_co_out" 0
  _co_excludes=$(project_variant_field "$_project_root" "$_co_variant" excluded) || die "cannot read variant $_co_variant"
  _co_parent=$(path_parent "$_co_out")
  _co_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  [ -d "$_co_parent" ] || "$_co_mkdir" -p "$_co_parent" || die "cannot create output parent: $_co_parent"
  _stage=$(trusted_mktemp_at "$_co_parent" dir "$_co_parent/.valise-compile.XXXXXX") ||
    die "cannot create compile staging directory"
  registry_generate "$_project_root" "$_stage/.registry"
  for _co_shell in $VALISE_PROJECT_SHELLS; do
    _co_roots=$(project_bundle_roots "$_project_root" "$_co_shell" "$_co_bundle") ||
      die "cannot read bundle $_co_bundle"
    [ -n "$_co_roots" ] || continue
    project_compile "$_stage/.registry" "$_co_shell" "$_co_roots" "$_co_excludes" "$_stage/$_co_shell.sh"
    info "compiled plan for $_co_shell"
  done
  _co_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  "$_co_rm" -f "$_stage/.registry" || die "cannot remove registry scratch file"
  project_publish "$_stage" "$_co_out"
  _stage=""
}

# project_meta_add_require <meta> <module>
project_meta_add_require() {
  _pm_meta=$1
  _pm_module=$2
  [ -f "$_pm_meta" ] && [ ! -L "$_pm_meta" ] || die "metadata file is missing or unsafe: $_pm_meta"
  _pm_parent=$(path_parent "$_pm_meta")
  _pm_tmp=$(trusted_mktemp_at "$_pm_parent" file "$_pm_parent/.valise-meta.XXXXXX") ||
    die "cannot create metadata staging file"
  _pm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_pm_awk" -v module="$_pm_module" '
    BEGIN { have = 0 }
    /^requires=/ {
      count = split(substr($0, 10), parts, " ")
      output = ""
      seen = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] == "") continue
        if (parts[i] == module) seen = 1
        output = output (output == "" ? "" : " ") parts[i]
      }
      if (!seen) output = output (output == "" ? "" : " ") module
      print "requires=" output
      have = 1
      next
    }
    { print }
    END { if (!have) print "requires=" module }
  ' "$_pm_meta" >"$_pm_tmp" || die "cannot update metadata: $_pm_meta"
  project_meta_publish "$_pm_meta"
}

# project_meta_remove_module <meta> <module>
project_meta_remove_module() {
  _pm_meta=$1
  _pm_module=$2
  [ -f "$_pm_meta" ] && [ ! -L "$_pm_meta" ] || die "metadata file is missing or unsafe: $_pm_meta"
  _pm_parent=$(path_parent "$_pm_meta")
  _pm_tmp=$(trusted_mktemp_at "$_pm_parent" file "$_pm_parent/.valise-meta.XXXXXX") ||
    die "cannot create metadata staging file"
  _pm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_pm_awk" -v module="$_pm_module" '
    /^(requires|optional)=/ {
      key = substr($0, 1, index($0, "=") - 1)
      count = split(substr($0, index($0, "=") + 1), parts, " ")
      output = ""
      for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == module) continue
        output = output (output == "" ? "" : " ") parts[i]
      }
      print key "=" output
      next
    }
    { print }
  ' "$_pm_meta" >"$_pm_tmp" || die "cannot update metadata: $_pm_meta"
  project_meta_publish "$_pm_meta"
}

# project_meta_publish <meta>: replace meta with _pm_tmp, keeping its mode.
project_meta_publish() {
  _pm_mode=$(file_mode "$1")
  [ -n "$_pm_mode" ] || die "cannot read metadata mode: $1"
  _pm_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pm_chmod" "$_pm_mode" "$_pm_tmp" || die "cannot preserve metadata mode"
  _pm_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_pm_mv" "$_pm_tmp" "$1" || die "cannot publish metadata: $1"
  _pm_tmp=""
  unset _pm_meta _pm_module _pm_parent _pm_awk _pm_mode _pm_chmod _pm_mv
}

# project_meta_loses_all_targets <meta> <module>
# Succeed when removing module from requires= would leave no load target at all.
project_meta_loses_all_targets() {
  _pl_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_pl_awk" -v module="$2" '
    /^load=./ { target = 1 }
    /^requires=/ {
      count = split(substr($0, 10), parts, " ")
      for (i = 1; i <= count; i++) {
        if (parts[i] == module) named = 1
        else if (parts[i] != "") other = 1
      }
    }
    END { exit (named && !other && !target) ? 0 : 1 }
  ' "$1"
}

# project_release_filter <file> <column> <module> <source>
# Print a project table without the module's names in the given column. A bare
# name means the module itself; a layer module may also be named
# module@source. Exit 3 when a row that named the module is left with no names.
project_release_filter() {
  _rf_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_rf_awk" -F '\t' -v OFS='\t' -v column="$2" -v module="$3" -v source="$4" '
    /^[[:space:]]*#/ || NF < column { print; next }
    {
      count = split($column, parts, " ")
      output = ""
      hit = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] == "") continue
        if (parts[i] == module "@" source || parts[i] == module) {
          hit = 1
          continue
        }
        output = output (output == "" ? "" : " ") parts[i]
      }
      if (hit) {
        $column = output
        if (output == "") emptied = 1
      }
      print
    }
    END { if (emptied) exit 3 }
  ' "$1"
}

# project_release_strip <file> <column> <module> <source>
project_release_strip() {
  [ -f "$1" ] || return 0
  _rs_parent=$(path_parent "$1")
  _rr_tmp=$(trusted_mktemp_at "$_rs_parent" file "$_rs_parent/.valise-table.XXXXXX") ||
    die "cannot create table staging file"
  _rs_status=0
  project_release_filter "$1" "$2" "$3" "$4" >"$_rr_tmp" || _rs_status=$?
  case "$_rs_status" in
  0 | 3) ;;
  *) die "cannot update $1" ;;
  esac
  _rs_mode=$(file_mode "$1")
  [ -n "$_rs_mode" ] || die "cannot read file mode: $1"
  _rs_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_rs_chmod" "$_rs_mode" "$_rr_tmp" || die "cannot preserve file mode"
  _rs_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_rs_mv" "$_rr_tmp" "$1" || die "cannot publish $1"
  _rr_tmp=""
  unset _rs_parent _rs_status _rs_mode _rs_chmod _rs_mv
}

# integration_render <target> <block>
# Print the startup file as install would leave it: the block replaces the
# first managed block, or is appended when there is none. Every other line is
# kept, so removing the block restores the file.
integration_render() {
  if [ -f "$1" ]; then
    _ir_awk=$(trusted_utility_path awk) || return 1
    _ir_tail=$(trusted_utility_path tail) || return 1
    # A file whose last line has no newline gets one before an appended
    # block. The block then carries a note line, so uninstall can take that
    # newline away again and restore the file exactly.
    _ir_nonl=0
    [ ! -s "$1" ] || [ -z "$("$_ir_tail" -c 1 "$1")" ] || _ir_nonl=1
    # The block travels through ENVIRON: awk -v would interpret its backslashes.
    _VALISE_BLOCK=$2 _VALISE_NOTE=$VALISE_NONL_NOTE "$_ir_awk" -v nonl="$_ir_nonl" '
      function emit(with_note,   at) {
        if (!with_note) { print ENVIRON["_VALISE_BLOCK"]; return }
        at = index(ENVIRON["_VALISE_BLOCK"], "\n")
        print substr(ENVIRON["_VALISE_BLOCK"], 1, at - 1)
        print ENVIRON["_VALISE_NOTE"]
        print substr(ENVIRON["_VALISE_BLOCK"], at + 1)
      }
      /^# BEGIN valise managed block$/ { inblock = 1; had_note = 0; next }
      inblock && $0 == ENVIRON["_VALISE_NOTE"] { had_note = 1; next }
      inblock && /^# END valise managed block$/ {
        inblock = 0
        if (!written) emit(had_note)
        written = 1
        next
      }
      inblock { next }
      { print }
      END { if (!written) emit(nonl) }
    ' "$1"
  else
    printf '%s\n' "$2"
  fi
}

# project_write_integration <file> <block>
# Replace the valise managed block in place, or append one. A symlink belongs to
# whatever manages it, so it is reported and left alone. Unpaired markers mean the
# file was edited by hand: rewriting could delete the user's lines, so refuse.
# A file install creates is recorded so uninstall can delete it again.
project_write_integration() {
  _pi_target=$1
  _pi_snippet=$2
  if [ -L "$_pi_target" ]; then
    info "warning: $_pi_target is a symlink; add the output of 'valise init' to it yourself"
    unset _pi_target _pi_snippet
    return 0
  fi
  if [ -f "$_pi_target" ]; then
    integration_markers_paired "$_pi_target" ||
      die "unpaired valise managed block markers in $_pi_target (restore or remove the BEGIN and END lines, then retry)"
  elif [ -e "$_pi_target" ]; then
    die "startup path is not a regular file: $_pi_target"
  fi
  _pi_parent=$(path_parent "$_pi_target")
  _pi_tmp=$(trusted_mktemp_at "$_pi_parent" file "$_pi_parent/.valise-integration.XXXXXX") ||
    die "cannot create integration staging file"
  integration_render "$_pi_target" "$_pi_snippet" >"$_pi_tmp" || die "cannot read startup file: $_pi_target"
  if [ -f "$_pi_target" ]; then
    _pi_cmp=$(trusted_utility_path cmp) || die "no trusted cmp utility available"
    if "$_pi_cmp" -s "$_pi_tmp" "$_pi_target"; then
      _pi_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
      "$_pi_rm" -f "$_pi_tmp" || die "cannot remove unchanged integration staging file"
      _pi_tmp=""
      info "shell integration current: $_pi_target"
      unset _pi_target _pi_snippet _pi_parent _pi_cmp _pi_rm
      return 0
    fi
    _pi_mode=$(file_mode "$_pi_target")
    [ -n "$_pi_mode" ] || die "cannot read startup file mode: $_pi_target"
  else
    _pi_mode=0644
    startup_created_add "$_pi_target"
  fi
  _pi_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pi_chmod" "$_pi_mode" "$_pi_tmp" || die "cannot set startup file mode"
  _pi_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_pi_mv" "$_pi_tmp" "$_pi_target" || die "cannot publish startup file: $_pi_target"
  _pi_tmp=""
  _txn_changed="$_txn_changed $_pi_target"
  info "shell integration written: $_pi_target"
  unset _pi_target _pi_snippet _pi_parent _pi_cmp _pi_rm _pi_mode _pi_chmod _pi_mv
}

cmd_new() {
  _new_target=
  for _new_arg do
    case "$_new_arg" in
    --help | -h) usage_new; return 0 ;;
    --*) die "unknown new option: $_new_arg" ;;
    *) [ -z "$_new_target" ] || die "usage: valise new [dir]"; _new_target=$_new_arg ;;
    esac
  done
  [ -n "$_new_target" ] || _new_target=.
  _new_target=$(path_normalize "$_new_target") || die "cannot resolve new project path"
  [ "$_new_target" != "/" ] || die "new project path must not be /"
  if [ -e "$_new_target" ] || [ -L "$_new_target" ]; then
    [ -d "$_new_target" ] && [ ! -L "$_new_target" ] || die "new project path is not a directory: $_new_target"
    for _new_entry in "$_new_target"/* "$_new_target"/.[!.]* "$_new_target"/..?*; do
      if [ -e "$_new_entry" ] || [ -L "$_new_entry" ]; then
        die "new project directory must be empty: $_new_target"
      fi
    done
  fi
  _new_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  "$_new_mkdir" -p "$_new_target/module.d" "$_new_target/modules" ||
    die "cannot create project directories: $_new_target"
  printf '%s\n' \
    '# valise project configuration.' \
    'bundle=default' \
    'variant=default' \
    "requires_valise=$VALISE_VERSION" \
    >"$_new_target/valise.conf"
  printf '%s\n' \
    'name=profile_main' \
    'version=' \
    'side_effect=read-only' \
    'requires=' \
    'optional=' \
    'shells=posix' \
    'platforms=any' \
    'exports=profile_main_loaded' \
    'load=modules/profile_main.sh' \
    >"$_new_target/module.d/profile_main.meta"
  printf '%s\n' \
    '# Shared project initialization. Add shell functions or exports here.' \
    'profile_main_loaded() { :; }' \
    >"$_new_target/modules/profile_main.sh"
  "$_new_mkdir" -p "$_new_target/modules/fish" ||
    die "cannot create project directories: $_new_target"
  printf '%s\n' \
    'name=profile_main_fish' \
    'version=' \
    'side_effect=read-only' \
    'requires=' \
    'optional=' \
    'shells=fish' \
    'platforms=any' \
    'exports=profile_main_loaded' \
    'load=modules/fish/profile_main.fish' \
    >"$_new_target/module.d/profile_main_fish.meta"
  printf '%s\n' \
    '# Fish project initialization. Add Fish functions here.' \
    'function profile_main_loaded; end' \
    >"$_new_target/modules/fish/profile_main.fish"
  printf 'variant\tdescription\texcluded\ndefault\tAll project modules\t\n' \
    >"$_new_target/variants.tsv"
  printf 'bundle\tshell\troots\ndefault\tsh\tprofile_main\ndefault\tbash\tprofile_main\ndefault\tzsh\tprofile_main\ndefault\tksh\tprofile_main\ndefault\tfish\tprofile_main_fish\n' \
    >"$_new_target/bundles.tsv"
  printf '%s\n' '/build/' >"$_new_target/.gitignore"
  printf '%s\n' \
    "created valise project: $_new_target" \
    "next steps:" \
    "  cd ${_new_target#"$(pwd -P)"/}" \
    "  valise module new hello --exports=hello" \
    "  valise apply"
  unset _new_target _new_arg _new_entry _new_mkdir
}

# project_default_wire_targets <project-root> <bundle>
# Print the module a new module is wired into: the single distinct root of the
# bundle across its POSIX shells. A new module is a POSIX module, so the Fish
# row never takes it. Fail, listing the candidates, when there is not exactly
# one.
project_default_wire_targets() {
  _pdw_all=
  for _pdw_shell in $VALISE_PROJECT_SHELLS; do
    _pdw_roots=$(project_bundle_roots "$1" "$_pdw_shell" "$2") || return 1
    for _pdw_root in $_pdw_roots; do
      case " $_pdw_all " in
      *" $_pdw_root "*) ;;
      *) _pdw_all="${_pdw_all:+$_pdw_all }$_pdw_root" ;;
      esac
    done
  done
  _pdw_bundle=$2
  # shellcheck disable=SC2086
  set -- $_pdw_all
  if [ "$#" -ne 1 ]; then
    if [ "$#" -eq 0 ]; then
      printf 'valise: error: bundle %s has no roots to wire the module into; use --into=<module> or --no-wire\n' "$_pdw_bundle" >&2
    else
      printf 'valise: error: bundle %s has several roots (%s); use --into=<module>[,<module>...] or --no-wire\n' "$_pdw_bundle" "$_pdw_all" >&2
    fi
    return 1
  fi
  printf '%s\n' "$1"
}

# project_meta_path <project-root> <module-ref>
# Print the metadata file of a project or layer module named by reference.
project_meta_path() {
  _pmp_name=${2%@*}
  _pmp_found=
  _pmp_count=0
  case "$2" in
  *@*)
    _pmp_source=${2#*@}
    case "$_pmp_source" in
    module.d | layers/*/module.d) ;;
    *) printf 'valise: error: not a project module: %s\n' "$2" >&2; return 1 ;;
    esac
    _pmp_found="$1/$_pmp_source/$_pmp_name.meta"
    [ -f "$_pmp_found" ] || { printf 'valise: error: module not found: %s\n' "$2" >&2; return 1; }
    ;;
  *)
    if [ -f "$1/module.d/$_pmp_name.meta" ]; then
      _pmp_found="$1/module.d/$_pmp_name.meta"
    else
      for _pmp_candidate in "$1"/layers/*/module.d/"$_pmp_name".meta; do
        [ -f "$_pmp_candidate" ] || continue
        _pmp_found=$_pmp_candidate
        _pmp_count=$((_pmp_count + 1))
      done
      [ "$_pmp_count" -le 1 ] || { printf 'valise: error: ambiguous module %s; qualify it as name@layers/<provider>/module.d\n' "$2" >&2; return 1; }
      [ -n "$_pmp_found" ] || { printf 'valise: error: module not found in the project: %s\n' "$2" >&2; return 1; }
    fi
    ;;
  esac
  [ ! -L "$_pmp_found" ] || { printf 'valise: error: metadata file is a symlink: %s\n' "$_pmp_found" >&2; return 1; }
  printf '%s\n' "$_pmp_found"
}

cmd_module() {
  _module_subcmd=${1:-}
  [ -n "$_module_subcmd" ] || die "usage: valise module <new|list|remove> [args]"
  case "$_module_subcmd" in
  --help | -h) usage_module; return 0 ;;
  new)
    shift
    _module_name=
    _module_exports=
    _module_into=
    _module_wire=1
    for _module_arg do
      case "$_module_arg" in
      --exports=*) _module_exports=${_module_arg#--exports=} ;;
      --into=*) _module_into=${_module_arg#--into=}; [ -n "$_module_into" ] || die "--into needs a module name" ;;
      --no-wire) _module_wire=0 ;;
      --help | -h) usage_module; return 0 ;;
      --*) die "unknown module new option: $_module_arg" ;;
      *) [ -z "$_module_name" ] || die "usage: valise module new <name> [--exports=<list>] [--into=<module>[,...] | --no-wire]"; _module_name=$_module_arg ;;
      esac
    done
    [ -n "$_module_name" ] || die "module new requires a module name"
    [ "$_module_wire" -eq 1 ] || [ -z "$_module_into" ] || die "--into and --no-wire are mutually exclusive"
    case "$_module_name" in
    [abcdefghijklmnopqrstuvwxyz_]*) ;;
    *) die "invalid module name: $_module_name" ;;
    esac
    case "$_module_name" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "invalid module name: $_module_name" ;;
    valise_*) die "the valise_ prefix is reserved for engine modules: $_module_name" ;;
    esac
    project_config_load
    _module_targets=
    _module_target_metas=
    if [ "$_module_wire" -eq 1 ]; then
      if [ -n "$_module_into" ]; then
        _module_targets=$(printf '%s\n' "$_module_into" | tr ',' ' ')
      else
        _module_targets=$(project_default_wire_targets "$_project_root" "$_project_bundle") || exit 1
      fi
      for _module_target in $_module_targets; do
        _module_target_meta=$(project_meta_path "$_project_root" "$_module_target") || exit 1
        [ -w "$_module_target_meta" ] || die "metadata file is not writable: $_module_target_meta"
        _module_target_metas="$_module_target_metas $_module_target_meta"
      done
    fi
    [ -d "$_project_root/modules" ] || die "module body directory is missing: $_project_root/modules"
    [ -w "$_project_root/module.d" ] && [ -w "$_project_root/modules" ] ||
      die "module directories are not writable: $_project_root"
    _module_meta="$_project_root/module.d/$_module_name.meta"
    _module_body="$_project_root/modules/$_module_name.sh"
    [ ! -e "$_module_meta" ] && [ ! -L "$_module_meta" ] || die "module metadata already exists: $_module_name"
    [ ! -e "$_module_body" ] && [ ! -L "$_module_body" ] || die "module body already exists: $_module_name"
    _module_export_words=
    if [ -n "$_module_exports" ]; then
      for _module_export in $(printf '%s\n' "$_module_exports" | tr ',' ' '); do
        case "$_module_export" in
        [abcdefghijklmnopqrstuvwxyz_]*) ;;
        *) die "invalid export name: $_module_export" ;;
        esac
        case "$_module_export" in
        *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "invalid export name: $_module_export" ;;
        case | do | done | elif | else | esac | fi | for | if | in | then | until | while | time)
          die "invalid export name (reserved word): $_module_export"
          ;;
        esac
        _module_export_words="${_module_export_words:+$_module_export_words }$_module_export"
      done
    fi
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    for _module_export in $_module_export_words; do
      for _module_candidate in "$_project_root"/module.d/*.meta "$_project_root"/layers/*/module.d/*.meta; do
        [ -f "$_module_candidate" ] || continue
        if "$_module_awk" -F= -v wanted="$_module_export" '
          $1 == "exports" {
            count = split(substr($0, length($1) + 2), words, " ")
            for (i = 1; i <= count; i++) if (words[i] == wanted) found = 1
          }
          END { exit found ? 0 : 1 }
        ' "$_module_candidate" >/dev/null 2>&1; then
          die "export already exists in another module: $_module_export"
        fi
      done
    done
    printf '%s\n' \
      "name=$_module_name" \
      'version=' \
      'side_effect=read-only' \
      'requires=' \
      'optional=' \
      'shells=posix' \
      'platforms=any' \
      "exports=$_module_export_words" \
      "load=modules/$_module_name.sh" \
      >"$_module_meta"
    {
      printf '%s\n' "# Edit this module body; valise apply reloads it."
      if [ -n "$_module_export_words" ]; then
        for _module_export in $_module_export_words; do
          printf '%s() {\n  printf "%%s\\n" "hello from %s"\n}\n\n' "$_module_export" "$_module_name"
        done
      else
        printf '%s\n' "# This module has no declared exports."
      fi
    } >"$_module_body"
    if [ "$_module_wire" -eq 1 ]; then
      for _module_target_meta in $_module_target_metas; do
        project_meta_add_require "$_module_target_meta" "$_module_name"
      done
      info "created module $_module_name and wired it into $_module_targets"
    else
      info "created module $_module_name (not wired; add it to a module's requires= or a bundle root)"
    fi
    ;;
  list)
    shift
    [ "$#" -eq 0 ] || die "usage: valise module list"
    project_config_load
    _module_list_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-module-list.XXXXXX") ||
      die "cannot create module list staging file"
    registry_generate "$_project_root" "$_module_list_tmp"
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    "$_module_awk" -F '\t' 'NR > 1 && $13 != "valise" { print $1 }' "$_module_list_tmp"
    _module_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_module_rm" -f "$_module_list_tmp" || die "cannot remove module list staging file"
    _module_list_tmp=""
    ;;
  remove)
    shift
    _module_name=${1:-}
    [ -n "$_module_name" ] || die "module remove requires a module name"
    project_config_load
    _module_meta=$(project_meta_path "$_project_root" "$_module_name") || exit 1
    _module_name=${_module_name%@*}
    _module_source=$(path_parent "$_module_meta")
    # Everything that would make the removal fail is checked here, before any
    # file changes: a half-applied removal leaves a project that cannot build.
    _module_registry_source=${_module_source#"$_project_root"/}
    _module_bundles=$_project_root/bundles.tsv
    _module_variants=$_project_root/variants.tsv
    for _module_candidate in "$_project_root"/module.d/*.meta "$_project_root"/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      [ "$_module_candidate" != "$_module_meta" ] || continue
      if project_meta_loses_all_targets "$_module_candidate" "$_module_name"; then
        _module_candidate_name=${_module_candidate##*/}
        die "cannot remove $_module_name: ${_module_candidate_name%.meta} requires only this module and would have nothing to load; add another dependency or remove ${_module_candidate_name%.meta} first"
      fi
    done
    _module_status=0
    project_release_filter "$_module_bundles" 3 "$_module_name" "$_module_registry_source" >/dev/null || _module_status=$?
    case "$_module_status" in
    0) ;;
    3) die "cannot remove $_module_name: it is the only root of a bundle in bundles.tsv; add another root first" ;;
    *) die "cannot read $_module_bundles" ;;
    esac
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    _module_load=$("$_module_awk" -F= '$1 == "load" { print substr($0, length($1) + 2); exit }' "$_module_meta")
    _module_body_path=
    _module_body_shared=0
    if [ -n "$_module_load" ]; then
      case "$_module_load" in
      '' | /* | . | .. | ./* | ../* | */. | */.. | */./* | */../* | *//*)
        die "invalid module load path: $_module_load"
        ;;
      esac
      _module_root=$(path_parent "$_module_source")
      source_path_is_physical "$_module_root" "$_module_load" ||
        die "module load path contains a symlink: $_module_load"
      _module_body_path="$_module_root/$_module_load"
      [ ! -d "$_module_body_path" ] || die "module load path is a directory: $_module_load"
      [ -f "$_module_body_path" ] || die "module body is missing: $_module_load"
      # Another module in the same source may load the same body. Keep it then:
      # removing the metadata is enough, and deleting the body would break the
      # module that still loads it.
      for _module_candidate in "$_module_source"/*.meta; do
        [ -f "$_module_candidate" ] || continue
        [ "$_module_candidate" != "$_module_meta" ] || continue
        _module_candidate_load=$("$_module_awk" -F= '$1 == "load" { print substr($0, length($1) + 2); exit }' "$_module_candidate")
        if [ "$_module_candidate_load" = "$_module_load" ]; then
          _module_body_shared=1
          break
        fi
      done
      [ -w "$(path_parent "$_module_body_path")" ] ||
        die "module body directory is not writable: $(path_parent "$_module_body_path")"
    fi
    [ -w "$_module_source" ] || die "module metadata directory is not writable: $_module_source"
    for _module_candidate in "$_project_root"/module.d/*.meta "$_project_root"/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      _module_candidate_parent=$(path_parent "$_module_candidate")
      [ -w "$_module_candidate_parent" ] || die "metadata directory is not writable: $_module_candidate_parent"
    done
    for _module_candidate in "$_module_bundles" "$_module_variants"; do
      if [ -f "$_module_candidate" ]; then
        [ -w "$_module_candidate" ] || die "project file is not writable: $_module_candidate"
      fi
    done
    _module_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    if [ -n "$_module_body_path" ] && [ "$_module_body_shared" -eq 0 ]; then
      "$_module_rm" -f "$_module_body_path" || die "cannot remove module body: $_module_load"
    fi
    "$_module_rm" -f "$_module_meta" || die "cannot remove module metadata: $_module_name"
    for _module_candidate in "$_project_root"/module.d/*.meta "$_project_root"/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      project_meta_remove_module "$_module_candidate" "$_module_name"
    done
    project_release_strip "$_module_bundles" 3 "$_module_name" "$_module_registry_source"
    project_release_strip "$_module_variants" 3 "$_module_name" "$_module_registry_source"
    info "removed module $_module_name"
    ;;
  *)
    die "unknown module subcommand: $_module_subcmd (use new, list, or remove)"
    ;;
  esac
}

cmd_build() {
  _build_out=
  _build_variant=
  _build_bundle=
  for _build_arg do
    case "$_build_arg" in
    --variant=*) _build_variant=${_build_arg#--variant=}; [ -n "$_build_variant" ] || die "variant name must not be empty" ;;
    --bundle=*) _build_bundle=${_build_arg#--bundle=}; [ -n "$_build_bundle" ] || die "bundle name must not be empty" ;;
    --help | -h) usage_build; return 0 ;;
    --*) die "unknown build option: $_build_arg" ;;
    *) [ -z "$_build_out" ] || die "usage: valise build [--variant=<name>] [--bundle=<name>] [out]"; _build_out=$_build_arg ;;
    esac
  done
  project_config_load
  [ -n "$_build_variant" ] || _build_variant=$_project_variant
  [ -n "$_build_bundle" ] || _build_bundle=$_project_bundle
  [ -n "$_build_out" ] || _build_out=$_project_root/build/release
  _build_out=$(path_normalize "$_build_out") || die "cannot resolve build output path"
  # The default output is replaced; any other output must be new or empty.
  _build_replace=0
  [ "$_build_out" != "$_project_root/build/release" ] || _build_replace=1
  project_build "$_build_variant" "$_build_bundle" "$_build_out" "$_build_replace"
  unset _build_out _build_arg _build_variant _build_bundle _build_replace
}

# project_command_class <shells>
# Print the POSIX shell class a module's commands run under: sh when the
# module supports every POSIX shell, else the first of bash, zsh, ksh it
# names. Fail for a Fish-only module.
project_command_class() {
  for _pcc_class in sh bash zsh ksh; do
    case " $1 " in
    *" $_pcc_class "*) printf '%s\n' "$_pcc_class"; unset _pcc_class; return 0 ;;
    *" posix "*) printf 'sh\n'; unset _pcc_class; return 0 ;;
    esac
  done
  unset _pcc_class
  return 1
}

# project_write_launcher <file> <class> <command> <module> <plan>
# Write the bin/ launcher for one published command: it loads the module's
# command plan from the release that contains it, in strict mode, then runs
# the function with the caller's arguments.
project_write_launcher() {
  case "$2" in
  sh) _pwl_interpreter='#!/bin/sh' ;;
  *) _pwl_interpreter="#!/usr/bin/env $2" ;;
  esac
  {
    printf '%s\n' \
      "$_pwl_interpreter" \
      "# valise command $3 from module $4; generated by valise build; do not edit." \
      'case "$0" in' \
      '*/*) _valise_launcher=$0 ;;' \
      '*)' \
      '  if [ -f "$0" ]; then _valise_launcher=./$0; else _valise_launcher=$(command -v -- "$0") || _valise_launcher=; fi' \
      '  ;;' \
      'esac' \
      'case "$_valise_launcher" in' \
      '*/*) ;;' \
      "*) printf '%s\\n' 'valise: $3: cannot locate the command launcher' >&2; exit 127 ;;" \
      'esac' \
      'VALISE_MODULE_ROOT=$(cd -P -- "${_valise_launcher%/*}/.." 2>/dev/null && pwd -P) || {' \
      "  printf '%s\\n' 'valise: $3: cannot locate the release' >&2" \
      '  exit 127' \
      '}' \
      'unset _valise_launcher' \
      '_valise_command_mode_set=${VALISE_MODE+x}' \
      '_valise_command_mode=${VALISE_MODE-}' \
      'VALISE_MODE=strict' \
      ". \"\$VALISE_MODULE_ROOT/$5\" || {" \
      "  printf '%s\\n' 'valise: $3: cannot load module $4' >&2" \
      '  exit 1' \
      '}' \
      'if [ -n "$_valise_command_mode_set" ]; then VALISE_MODE=$_valise_command_mode; else unset VALISE_MODE; fi' \
      'unset VALISE_MODULE_ROOT _valise_command_mode _valise_command_mode_set' \
      "$3 \"\$@\""
  } >"$1" || die "cannot write command launcher: $3"
  unset _pwl_interpreter
}

# project_build_commands <registry> <excludes> <stage> <scratch>
# Publish the commands and executables of every module in the closure
# recorded in <scratch>/closure. Each module with commands gets a plan for its
# command class at plans/commands/<module>.sh, whose closure joins the release; that
# can pull in more modules, so the scan repeats until no module is new. Sets
# _pb_commands to the published names.
project_build_commands() {
  _pbc_registry=$1
  _pbc_excludes=$2
  _pbc_stage=$3
  _pbc_scratch=$4
  _pbc_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _pbc_sort=$(trusted_utility_path sort) || die "no trusted sort utility available"
  _pbc_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _pbc_cp=$(trusted_utility_path cp) || die "no trusted cp utility available"
  _pbc_done=
  _pb_commands=
  while :; do
    LC_ALL=C "$_pbc_sort" -u "$_pbc_scratch/closure" >"$_pbc_scratch/closure.scan" || die "cannot order the closure"
    _pbc_new=0
    while IFS= read -r _pbc_id; do
      [ -n "$_pbc_id" ] || continue
      case " $_pbc_done " in *" $_pbc_id "*) continue ;; esac
      _pbc_done="$_pbc_done $_pbc_id"
      _pbc_name=${_pbc_id%%@*}
      _pbc_source=${_pbc_id#*@}
      _pbc_row=$("$_pbc_awk" -F '\t' -v n="$_pbc_name" -v s="$_pbc_source" \
        'NR > 1 && $1 == n && $13 == s { print $6 "\t" $10 "\t" $11; exit }' "$_pbc_registry")
      _pbc_shells=${_pbc_row%%"	"*}
      _pbc_rest=${_pbc_row#*"	"}
      _pbc_cmds=${_pbc_rest%%"	"*}
      _pbc_exes=${_pbc_rest#*"	"}
      [ -n "$_pbc_cmds$_pbc_exes" ] || continue
      "$_pbc_mkdir" -p "$_pbc_stage/bin" || die "cannot create the release bin directory"
      if [ -n "$_pbc_cmds" ]; then
        _pbc_class=$(project_command_class "$_pbc_shells") ||
          die "module $_pbc_name declares commands but supports no POSIX shell (Fish-only modules cannot publish commands)"
        _pbc_plan="plans/commands/$_pbc_name.sh"
        [ ! -e "$_pbc_stage/$_pbc_plan" ] || die "two modules named $_pbc_name publish commands; rename one"
        "$_pbc_mkdir" -p "$_pbc_stage/plans/commands" || die "cannot create the command plan directory"
        project_compile "$_pbc_registry" "$_pbc_class" "$_pbc_id" "$_pbc_excludes" "$_pbc_scratch/closure.cmd" closure
        "$_pbc_awk" '{ print }' "$_pbc_scratch/closure.cmd" >>"$_pbc_scratch/closure" ||
          die "cannot record the command closure of $_pbc_name"
        _pbc_new=1
        project_compile "$_pbc_registry" "$_pbc_class" "$_pbc_id" "$_pbc_excludes" "$_pbc_stage/$_pbc_plan"
        for _pbc_cmd in $_pbc_cmds; do
          case " $_pb_commands " in *" $_pbc_cmd "*) die "command $_pbc_cmd is published by more than one module" ;; esac
          _pb_commands="${_pb_commands:+$_pb_commands }$_pbc_cmd"
          project_write_launcher "$_pbc_stage/bin/$_pbc_cmd" "$_pbc_class" "$_pbc_cmd" "$_pbc_name" "$_pbc_plan"
        done
      fi
      if [ -n "$_pbc_exes" ]; then
        _pbc_dir=$(project_source_dir "$_project_root" "$_pbc_source") || die "unsupported registry source: $_pbc_source"
        for _pbc_exe in $_pbc_exes; do
          _pbc_cmd=${_pbc_exe##*/}
          case "$_pbc_cmd" in
          [A-Za-z0-9_]*) ;;
          *) die "module $_pbc_name: invalid executable name: $_pbc_cmd" ;;
          esac
          case "$_pbc_cmd" in
          *[!A-Za-z0-9_.-]*) die "module $_pbc_name: invalid executable name: $_pbc_cmd" ;;
          esac
          case " $_pb_commands " in *" $_pbc_cmd "*) die "command $_pbc_cmd is published by more than one module" ;; esac
          _pb_commands="${_pb_commands:+$_pb_commands }$_pbc_cmd"
          [ -f "$_pbc_dir/$_pbc_exe" ] && [ ! -L "$_pbc_dir/$_pbc_exe" ] ||
            die "executable missing or a symlink: $_pbc_dir/$_pbc_exe"
          "$_pbc_cp" "$_pbc_dir/$_pbc_exe" "$_pbc_stage/bin/$_pbc_cmd" || die "cannot copy executable $_pbc_exe"
        done
      fi
    done <"$_pbc_scratch/closure.scan"
    [ "$_pbc_new" -eq 1 ] || break
  done
  unset _pbc_registry _pbc_excludes _pbc_stage _pbc_scratch _pbc_awk _pbc_sort _pbc_mkdir _pbc_cp _pbc_done \
    _pbc_new _pbc_id _pbc_name _pbc_source _pbc_row _pbc_shells _pbc_rest _pbc_cmds _pbc_exes _pbc_class \
    _pbc_plan _pbc_cmd _pbc_dir _pbc_exe
}

# project_build <variant> <bundle> <out> <replace>
# Build a release tree from the loaded project. The tree holds only the
# modules some shell's closure loads, under the paths their plans source:
#
#   valise-release.conf                 build selection and closure
#   manifest.tsv                        release manifest
#   plans/<shell>.sh                    static plans for sh bash zsh ksh
#   plans/commands/<module>.sh          plans for modules that publish commands
#   bin/<command>                       command launchers and executables
#   runtime/capabilities.sh             the capability prelude
#   runtime/fish/{metadata,loader,profile}.fish  the Fish runtime, when the
#                                       bundle has Fish roots
#   module.d/, modules/...              primary modules in the closure
#   layers/<p>/module.d, layers/<p>/... layer modules in the closure
#   valise/module.d, valise/modules/... engine modules in the closure
project_build() {
  _pb_variant=$1
  _pb_bundle=$2
  _pb_out=$3
  [ "$_pb_out" != "/" ] || die "output directory must not be /"
  case "$_pb_out" in
  "$_project_root") die "output directory must not be the project root" ;;
  "$_project_root"/*)
    source_path_is_physical "$_project_root" "${_pb_out#"$_project_root"/}" ||
      die "output path contains a symlink: $_pb_out"
    ;;
  esac
  project_output_check "$_pb_out" "$4"
  # The developer commands build throwaway releases from explicit roots:
  # with _pb_override=1 the roots for each shell come from _pbo_<shell> and
  # no variant exclusions apply.
  if [ "${_pb_override:-0}" -eq 1 ]; then
    _pb_excludes=
  else
    _pb_excludes=$(project_variant_field "$_project_root" "$_pb_variant" excluded) || die "cannot read variant $_pb_variant"
  fi
  _pb_engine=$(engine_root) || die "cannot locate the valise engine"
  _pb_parent=$(path_parent "$_pb_out")
  _pb_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _pb_cp=$(trusted_utility_path cp) || die "no trusted cp utility available"
  _pb_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _pb_sort=$(trusted_utility_path sort) || die "no trusted sort utility available"
  [ -d "$_pb_parent" ] || "$_pb_mkdir" -p "$_pb_parent" || die "cannot create output parent: $_pb_parent"
  # Build beside the destination and publish only after the complete tree and
  # manifest exist, so a failed build never leaves a partial release.
  _stage=$(trusted_mktemp_at "$_pb_parent" dir "$_pb_parent/.valise-build.XXXXXX") ||
    die "cannot create build staging directory"
  _pb_scratch="$_stage/.scratch"
  "$_pb_mkdir" -p "$_pb_scratch" "$_stage/plans" "$_stage/runtime" || die "cannot create release tree"
  _pb_registry="$_pb_scratch/registry"
  registry_generate "$_project_root" "$_pb_registry"
  : >"$_pb_scratch/closure"
  _pb_conf_roots=
  _pb_any=0
  _pb_fish=0
  for _pb_shell in $VALISE_PROJECT_SHELLS fish; do
    if [ "${_pb_override:-0}" -eq 1 ]; then
      # _pb_shell is one of the fixed shell names, so the expansion is safe.
      eval "_pb_roots=\${_pbo_$_pb_shell:-}"
    else
      _pb_roots=$(project_bundle_roots "$_project_root" "$_pb_shell" "$_pb_bundle") ||
        die "cannot read bundle $_pb_bundle"
    fi
    if [ -z "$_pb_roots" ]; then
      _pb_conf_roots="$_pb_conf_roots${_pb_conf_roots:+
}roots_$_pb_shell="
      continue
    fi
    # The release records the roots that survive the variant, qualified, so
    # the Fish adapter seeds exactly what the closure contains.
    _pb_effective=$(project_effective_roots "$_pb_registry" "$_pb_shell" "$_pb_roots" "$_pb_excludes") || exit 1
    _pb_conf_roots="$_pb_conf_roots${_pb_conf_roots:+
}roots_$_pb_shell=$_pb_effective"
    _pb_any=1
    project_compile "$_pb_registry" "$_pb_shell" "$_pb_roots" "$_pb_excludes" "$_pb_scratch/closure.$_pb_shell" closure
    "$_pb_awk" '{ print }' "$_pb_scratch/closure.$_pb_shell" >>"$_pb_scratch/closure" ||
      die "cannot record the $_pb_shell closure"
    if [ "$_pb_shell" = fish ]; then
      _pb_fish=1
    else
      project_compile "$_pb_registry" "$_pb_shell" "$_pb_roots" "$_pb_excludes" "$_stage/plans/$_pb_shell.sh"
      info "compiled plan for $_pb_shell"
    fi
  done
  [ "$_pb_any" -eq 1 ] || die "bundle $_pb_bundle has no roots for any shell"
  project_build_commands "$_pb_registry" "$_pb_excludes" "$_stage" "$_pb_scratch"
  "$_pb_cp" "$_pb_engine/lib/capabilities.sh" "$_stage/runtime/capabilities.sh" || die "cannot copy the capability prelude"
  # A bundle with Fish roots gets the native Fish runtime: the metadata
  # reader, the loader, and the release adapter the Fish hook sources. The
  # loader resolves the closure copied below at Fish startup.
  if [ "$_pb_fish" -eq 1 ]; then
    "$_pb_mkdir" -p "$_stage/runtime/fish" || die "cannot create the Fish runtime directory"
    for _pb_fish_file in metadata loader profile; do
      "$_pb_cp" "$_pb_engine/lib/fish/$_pb_fish_file.fish" "$_stage/runtime/fish/$_pb_fish_file.fish" ||
        die "cannot copy the Fish runtime: lib/fish/$_pb_fish_file.fish"
    done
  fi

  # Copy every module in the union closure: its metadata and its body, under
  # the release prefix of its source.
  LC_ALL=C "$_pb_sort" -u "$_pb_scratch/closure" >"$_pb_scratch/closure.sorted" || die "cannot order the closure"
  _pb_modules=
  while IFS= read -r _pb_id; do
    [ -n "$_pb_id" ] || continue
    _pb_modules="${_pb_modules:+$_pb_modules }$_pb_id"
    _pb_name=${_pb_id%%@*}
    _pb_source=${_pb_id#*@}
    _pb_load=$("$_pb_awk" -F '\t' -v n="$_pb_name" -v s="$_pb_source" 'NR > 1 && $1 == n && $13 == s { print $9; exit }' "$_pb_registry")
    _pb_dir=$(project_source_dir "$_project_root" "$_pb_source") || die "unsupported registry source: $_pb_source"
    _pb_prefix=$(project_release_prefix "$_pb_source") || die "unsupported registry source: $_pb_source"
    _pb_pairs="$_pb_dir/module.d/$_pb_name.meta:${_pb_prefix}module.d/$_pb_name.meta"
    [ -z "$_pb_load" ] || _pb_pairs="$_pb_pairs $_pb_dir/$_pb_load:$_pb_prefix$_pb_load"
    for _pb_pair in $_pb_pairs; do
      _pb_from=${_pb_pair%%:*}
      _pb_to="$_stage/${_pb_pair#*:}"
      [ -f "$_pb_from" ] && [ ! -L "$_pb_from" ] || die "module file missing or a symlink: $_pb_from"
      # Several modules of one source may share a body.
      [ ! -e "$_pb_to" ] && [ ! -L "$_pb_to" ] || continue
      "$_pb_mkdir" -p "$(path_parent "$_pb_to")" && "$_pb_cp" "$_pb_from" "$_pb_to" ||
        die "cannot copy $_pb_from"
    done
  done <"$_pb_scratch/closure.sorted"

  {
    printf '%s\n' \
      '# valise release; generated by valise build; do not edit.' \
      'format=2' \
      "valise_version=$VALISE_VERSION" \
      "bundle=$_pb_bundle" \
      "variant=$_pb_variant" \
      "$_pb_conf_roots"
    printf 'modules=%s\n' "$_pb_modules"
    printf 'commands=%s\n' "$_pb_commands"
  } >"$_stage/valise-release.conf" || die "cannot write valise-release.conf"
  remove_tree "$_pb_scratch" || die "cannot remove build scratch files"
  _pb_find=$(trusted_utility_path find) || die "no trusted find utility available"
  _pb_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pb_find" "$_stage" -type d -exec "$_pb_chmod" 0755 {} + || die "cannot normalise directory modes"
  "$_pb_find" "$_stage" -type f -exec "$_pb_chmod" 0644 {} + || die "cannot normalise file modes"
  if [ -d "$_stage/bin" ]; then
    "$_pb_find" "$_stage/bin" -type f -exec "$_pb_chmod" 0755 {} + || die "cannot make release commands executable"
  fi
  cmd_make_manifest "$_stage" >/dev/null
  project_publish "$_stage" "$_pb_out"
  _stage=""
  info "built release: $_pb_out (bundle $_pb_bundle, variant $_pb_variant)"
  unset _pb_variant _pb_bundle _pb_out _pb_excludes _pb_engine _pb_parent _pb_scratch _pb_registry \
    _pb_conf_roots _pb_effective _pb_any _pb_fish _pb_fish_file _pb_shell _pb_roots _pb_modules _pb_id _pb_name _pb_source _pb_load \
    _pb_dir _pb_prefix _pb_pairs _pb_pair _pb_from _pb_to _pb_commands
}

cmd_apply() {
  _apply_variant=
  _apply_bundle=
  _apply_install_arg=
  _apply_dry_run=0
  for _apply_arg do
    case "$_apply_arg" in
    --variant=*) _apply_variant=${_apply_arg#--variant=}; [ -n "$_apply_variant" ] || die "variant name must not be empty" ;;
    --bundle=*) _apply_bundle=${_apply_arg#--bundle=}; [ -n "$_apply_bundle" ] || die "bundle name must not be empty" ;;
    --no-integration) _apply_install_arg=--no-integration ;;
    --dry-run) _apply_dry_run=1 ;;
    --help | -h) usage_apply; return 0 ;;
    *) die "unknown apply option: $_apply_arg" ;;
    esac
  done
  project_config_load
  [ -n "$_apply_variant" ] || _apply_variant=$_project_variant
  [ -n "$_apply_bundle" ] || _apply_bundle=$_project_bundle
  _apply_build_out=$_project_root/build/release
  project_build "$_apply_variant" "$_apply_bundle" "$_apply_build_out" 1
  _apply_old_pwd=$(pwd -P) || die "cannot resolve current directory"
  cd "$_apply_build_out" || die "cannot enter build output: $_apply_build_out"
  if [ "$_apply_dry_run" -eq 1 ]; then
    # Only build/ has changed; describe the install without performing it.
    _apply_integration=1
    [ -z "$_apply_install_arg" ] || _apply_integration=0
    install_preview "$_apply_integration"
    cd "$_apply_old_pwd" || die "cannot restore project directory: $_apply_old_pwd"
    unset _apply_arg _apply_variant _apply_bundle _apply_install_arg _apply_build_out _apply_old_pwd \
      _apply_dry_run _apply_integration
    return 0
  fi
  cmd_install $_apply_install_arg || die "valise install failed"
  cd "$_apply_old_pwd" || die "cannot restore project directory: $_apply_old_pwd"
  cmd_verify_active
  info "applied project: $_project_root"
  unset _apply_arg _apply_variant _apply_bundle _apply_install_arg _apply_build_out _apply_old_pwd _apply_dry_run
}

# release_conf_value <release-dir> <key>
# Print one key of a release's valise-release.conf, or fail.
release_conf_value() {
  [ -f "$1/valise-release.conf" ] || return 1
  _rcv_awk=$(trusted_utility_path awk) || return 1
  "$_rcv_awk" -v key="$2" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1/valise-release.conf"
}

cmd_status() {
  for _status_arg do
    case "$_status_arg" in
    --help | -h) usage_status; return 0 ;;
    *) die "unknown status option: $_status_arg" ;;
    esac
  done
  project_config_load
  printf 'project: %s\n' "$_project_root"
  printf 'project default bundle: %s\n' "$_project_bundle"
  printf 'project default variant: %s\n' "$_project_variant"
  _status_home=$(path_normalize "$HOME") || die "cannot resolve HOME"
  _status_targets=$(posix_startup_targets "$_status_home")
  while IFS= read -r _status_target; do
    [ -n "$_status_target" ] || continue
    if [ -L "$_status_target" ]; then
      printf 'integration: %s: symlink, not managed by valise\n' "$_status_target"
    elif [ ! -f "$_status_target" ]; then
      printf 'integration: %s: missing\n' "$_status_target"
    elif integration_has_managed_block "$_status_target"; then
      printf 'integration: %s: managed block present\n' "$_status_target"
    else
      printf 'integration: %s: managed block missing\n' "$_status_target"
    fi
  done <<EOF
$_status_targets
EOF
  _status_active_target=
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _status_active_target=$(active_release_dir 2>/dev/null || :)
    if [ -n "$_status_active_target" ]; then
      printf 'active release: %s\n' "${_status_active_target##*/}"
      printf 'active bundle: %s\n' "$(release_conf_value "$_status_active_target" bundle 2>/dev/null || printf unknown)"
      printf 'active variant: %s\n' "$(release_conf_value "$_status_active_target" variant 2>/dev/null || printf unknown)"
      printf 'active built by valise: %s\n' "$(release_conf_value "$_status_active_target" valise_version 2>/dev/null || printf unknown)"
    else
      printf 'active release: broken symlink\n'
    fi
  else
    printf 'active release: none\n'
  fi
  _status_build="$_project_root/build/release"
  if [ -f "$_status_build/manifest.tsv" ]; then
    printf 'build output: %s (bundle %s, variant %s)\n' "$_status_build" \
      "$(release_conf_value "$_status_build" bundle 2>/dev/null || printf unknown)" \
      "$(release_conf_value "$_status_build" variant 2>/dev/null || printf unknown)"
    if [ -n "$_status_active_target" ] && [ -f "$_status_active_target/.valise-manifest" ]; then
      _status_build_hash=$(file_sha256 "$_status_build/manifest.tsv") || die "cannot hash build manifest"
      _status_active_hash=$(file_sha256 "$_status_active_target/.valise-manifest") || die "cannot hash active manifest"
      if [ "$_status_build_hash" = "$_status_active_hash" ]; then
        printf 'drift: active release matches build output\n'
      else
        printf 'drift: active release differs from build output\n'
      fi
    else
      printf 'drift: no active release to compare\n'
    fi
  else
    printf 'build output: not built\n'
  fi
  unset _status_home _status_targets _status_target _status_active_target \
    _status_build _status_build_hash _status_active_hash
}

cmd_explain_variant() {
  _ev_variant=
  _ev_bundle=
  for _ev_arg do
    case "$_ev_arg" in
    --help | -h) usage_explain_variant; return 0 ;;
    --bundle=*) _ev_bundle=${_ev_arg#--bundle=}; [ -n "$_ev_bundle" ] || die "bundle name must not be empty" ;;
    --*) die "unknown explain-variant option: $_ev_arg" ;;
    *) [ -z "$_ev_variant" ] || die "usage: valise explain-variant [--bundle=<name>] [variant]"; _ev_variant=$_ev_arg ;;
    esac
  done
  project_config_load
  [ -n "$_ev_variant" ] || _ev_variant=$_project_variant
  [ -n "$_ev_bundle" ] || _ev_bundle=$_project_bundle
  _ev_desc=$(project_variant_field "$_project_root" "$_ev_variant" description) || exit 1
  _ev_excludes=$(project_variant_field "$_project_root" "$_ev_variant" excluded) || exit 1
  printf 'Variant: %s\n' "$_ev_variant"
  printf 'Description: %s\n' "${_ev_desc:-none}"
  printf 'Excluded modules: %s\n' "${_ev_excludes:-none}"
  printf '\nPer-shell impact (bundle %s):\n' "$_ev_bundle"
  # Resolve through the compiler, so a qualified exclusion matches a bare root
  # and the module counts are the closures a build would load.
  _stage=$(trusted_mktemp dir "${TMPDIR:-/tmp}/valise-explain.XXXXXX") || die "cannot create scratch directory"
  registry_generate "$_project_root" "$_stage/registry"
  _ev_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  for _ev_shell in $VALISE_PROJECT_SHELLS fish; do
    _ev_roots=$(project_bundle_roots "$_project_root" "$_ev_shell" "$_ev_bundle") || exit 1
    [ -n "$_ev_roots" ] || continue
    _ev_total=0
    for _ev_root in $_ev_roots; do _ev_total=$((_ev_total + 1)); done
    _ev_kept=$(project_effective_roots "$_stage/registry" "$_ev_shell" "$_ev_roots" "$_ev_excludes") || exit 1
    _ev_count=0
    for _ev_root in $_ev_kept; do _ev_count=$((_ev_count + 1)); done
    project_compile "$_stage/registry" "$_ev_shell" "$_ev_roots" "" "$_stage/full" closure
    project_compile "$_stage/registry" "$_ev_shell" "$_ev_roots" "$_ev_excludes" "$_stage/kept" closure
    _ev_full=$("$_ev_awk" 'END { print NR }' "$_stage/full")
    _ev_mods=$("$_ev_awk" 'END { print NR }' "$_stage/kept")
    printf '  %s: %d of %d roots, %d of %d modules\n' "$_ev_shell" "$_ev_count" "$_ev_total" "$_ev_mods" "$_ev_full"
  done
  remove_tree "$_stage" || die "cannot remove scratch directory"
  _stage=""
}

cmd_explain_bundles() {
  _eb_bundle=
  _eb_variant=
  for _eb_arg do
    case "$_eb_arg" in
    --bundle=*) _eb_bundle=${_eb_arg#--bundle=}; [ -n "$_eb_bundle" ] || die "bundle name must not be empty" ;;
    --variant=*) _eb_variant=${_eb_arg#--variant=}; [ -n "$_eb_variant" ] || die "variant name must not be empty" ;;
    --help | -h) usage_explain_bundles; return 0 ;;
    *) die "unknown explain-bundles option: $_eb_arg" ;;
    esac
  done
  project_config_load
  [ -n "$_eb_variant" ] || _eb_variant=$_project_variant
  _eb_excludes=$(project_variant_field "$_project_root" "$_eb_variant" excluded) || exit 1
  if [ -n "$_eb_bundle" ]; then
    project_bundle_roots "$_project_root" sh "$_eb_bundle" >/dev/null || exit 1
    _eb_bundles=$_eb_bundle
  else
    _eb_bundles=$(project_bundle_names "$_project_root") || die "cannot read bundles.tsv"
  fi
  _stage=$(trusted_mktemp dir "${TMPDIR:-/tmp}/valise-explain.XXXXXX") || die "cannot create scratch directory"
  registry_generate "$_project_root" "$_stage/registry"
  _eb_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  printf 'Bundle resolution (variant %s):\n\n' "$_eb_variant"
  for _eb_b in $_eb_bundles; do
    printf 'Bundle: %s\n' "$_eb_b"
    for _eb_shell in $VALISE_PROJECT_SHELLS fish; do
      _eb_roots=$(project_bundle_roots "$_project_root" "$_eb_shell" "$_eb_b") || exit 1
      [ -n "$_eb_roots" ] || continue
      project_compile "$_stage/registry" "$_eb_shell" "$_eb_roots" "$_eb_excludes" "$_stage/closure" closure
      _eb_count=$("$_eb_awk" 'END { print NR }' "$_stage/closure")
      _eb_root_count=0
      for _eb_root in $_eb_roots; do _eb_root_count=$((_eb_root_count + 1)); done
      printf '  %s: %d root(s), %d module(s)\n' "$_eb_shell" "$_eb_root_count" "$_eb_count"
      "$_eb_awk" '{ at = index($0, "@"); printf "    module %s (%s)\n", substr($0, 1, at - 1), substr($0, at + 1) }' "$_stage/closure"
    done
    printf '\n'
  done
  remove_tree "$_stage" || die "cannot remove scratch directory"
  _stage=""
}

cmd_layer_lint() {
  _ll_name="${1:-}"
  if [ "$#" -gt 0 ]; then shift; fi
  case "$_ll_name" in
  --help | -h) usage_layer_lint; return 0 ;;
  esac
  for _ll_arg do
    case "$_ll_arg" in
    --help | -h) usage_layer_lint; return 0 ;;
    *) die "unknown layer-lint option: $_ll_arg" ;;
    esac
  done
  [ -n "$_ll_name" ] || die "usage: valise layer-lint <layer-name|layer-path>"
  # A layer is addressed by its directory name in the current project, or by a
  # path to a layer tree that contains module.d/.
  _ll_root=$(project_find_root 2>/dev/null || :)
  if [ -n "$_ll_root" ] && [ -d "$_ll_root/layers/$_ll_name/module.d" ]; then
    _ll_dir="$_ll_root/layers/$_ll_name"
  elif [ -d "$_ll_name/module.d" ]; then
    _ll_dir=$(cd "$_ll_name" && pwd -P) || die "cannot resolve layer path: $_ll_name"
  else
    die "layer not found: $_ll_name (expected layers/$_ll_name in a valise project, or a path containing module.d/)"
  fi
  layer_lint_dir "$_ll_dir" "$_ll_name" || die "layer $_ll_name failed validation"
}

# layer_lint_dir <layer-dir> <label>
# Validate a contribution layer: contrib_ names, versions, bodies, safe modes,
# and dependencies that stay inside the layer or the engine. Returns nonzero
# after reporting every problem.
layer_lint_dir() {
  _ll_layer=$1
  _ll_label=$2
  _ll_engine=$(engine_root) || die "cannot locate the valise engine"
  _ll_metadata="$_ll_engine/lib/metadata.sh"
  [ -r "$_ll_metadata" ] || die "metadata library not found: $_ll_metadata"
  _ll_status=0
  # The name lists are space-delimited with a leading and a trailing space, so
  # " $name " matches every entry including the first and the last.
  _ll_known=" "
  for _ll_meta in "$_ll_engine"/module.d/*.meta "$_ll_layer"/module.d/*.meta; do
    [ -f "$_ll_meta" ] || continue
    _ll_file=${_ll_meta##*/}
    _ll_known="$_ll_known${_ll_file%.meta} "
  done
  _ll_count=0
  for _ll_meta in "$_ll_layer"/module.d/*.meta; do
    [ -e "$_ll_meta" ] || [ -L "$_ll_meta" ] || continue
    _ll_count=$((_ll_count + 1))
    _ll_file=${_ll_meta##*/}
    _ll_mod_name=${_ll_file%.meta}
    if [ -L "$_ll_meta" ]; then
      printf '  FAIL: %s: metadata file must not be a symlink\n' "$_ll_file" >&2
      _ll_status=1
      continue
    fi
    _ll_mode=$(file_mode "$_ll_meta") || _ll_mode=""
    case "$_ll_mode" in
    0644 | 0444) ;;
    *) printf '  FAIL: %s: metadata mode must be 0644 or 0444, got %s\n' "$_ll_file" "${_ll_mode:-unknown}" >&2; _ll_status=1 ;;
    esac
    case "$_ll_mod_name" in
    contrib_*) ;;
    *) printf '  FAIL: %s: layer module name must use the contrib_ prefix\n' "$_ll_file" >&2; _ll_status=1 ;;
    esac
    _ll_record=$(. "$_ll_metadata"; sp_metadata_read "$_ll_meta" 2>&1) || {
      printf '  FAIL: %s: invalid metadata: %s\n' "$_ll_file" "$_ll_record" >&2
      _ll_status=1
      continue
    }
    _ll_m_name= _ll_m_version= _ll_m_requires= _ll_m_optional= _ll_m_load=
    while IFS= read -r _ll_line; do
      case "$_ll_line" in
      name=*) _ll_m_name=${_ll_line#name=} ;;
      version=*) _ll_m_version=${_ll_line#version=} ;;
      requires=*) _ll_m_requires=${_ll_line#requires=} ;;
      optional=*) _ll_m_optional=${_ll_line#optional=} ;;
      load=*) _ll_m_load=${_ll_line#load=} ;;
      esac
    done <<EOF
$_ll_record
EOF
    if [ "$_ll_m_name" != "$_ll_mod_name" ]; then
      printf '  FAIL: %s: metadata name %s does not match the file name %s\n' "$_ll_file" "$_ll_m_name" "$_ll_mod_name" >&2
      _ll_status=1
    fi
    if [ -z "$_ll_m_version" ]; then
      printf '  FAIL: %s: layer modules must declare a version\n' "$_ll_file" >&2
      _ll_status=1
    fi
    if [ -n "$_ll_m_load" ]; then
      _ll_body="$_ll_layer/$_ll_m_load"
      if [ -L "$_ll_body" ]; then
        printf '  FAIL: %s: load target must not be a symlink: %s\n' "$_ll_file" "$_ll_m_load" >&2
        _ll_status=1
      elif [ ! -f "$_ll_body" ]; then
        printf '  FAIL: %s: load target does not exist: %s\n' "$_ll_file" "$_ll_m_load" >&2
        _ll_status=1
      else
        _ll_body_mode=$(file_mode "$_ll_body") || _ll_body_mode=""
        case "$_ll_body_mode" in
        0644 | 0444 | 0755 | 0555) ;;
        *) printf '  FAIL: %s: load target mode must be 0644, 0444, 0755 or 0555, got %s\n' "$_ll_file" "${_ll_body_mode:-unknown}" >&2; _ll_status=1 ;;
        esac
      fi
    fi
    for _ll_dep in $_ll_m_requires $_ll_m_optional; do
      case "$_ll_known" in
      *" $_ll_dep "*) ;;
      *) printf '  FAIL: %s: dependency %s is neither in this layer nor an engine module\n' "$_ll_file" "$_ll_dep" >&2; _ll_status=1 ;;
      esac
    done
  done
  if [ "$_ll_count" -eq 0 ]; then
    printf '  FAIL: %s: layer contains no modules\n' "$_ll_layer" >&2
    _ll_status=1
  fi
  [ "$_ll_status" -eq 0 ] || return 1
  printf 'layer %s: %d module(s) validated\n' "$_ll_label" "$_ll_count"
}
