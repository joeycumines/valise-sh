# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: project commands: compile, registry, new, module, build, apply, status, explain, layer-lint.
# Sourced by bin/valise; not executable on its own.

# release_bundle_roots <src-root> <shell> [bundle]
# Print the seed modules for <shell> from shell/release/bundle-roots, a
# tab-separated file of: bundle, shell, space-separated roots ("default" is
# the bundle used when none is requested). A bundle with no rows is an error;
# a shell with no row has no roots.
release_bundle_roots() {
  _rbr_file="$1/shell/release/bundle-roots"
  [ -f "$_rbr_file" ] || { printf 'valise: error: missing %s\n' "$_rbr_file" >&2; return 1; }
  awk -F '\t' -v b="${3:-default}" -v s="$2" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == b { known = 1; if ($2 == s && $3 != "") print $3 }
    END { if (!known) { print "valise: error: unknown bundle: " b > "/dev/stderr"; exit 1 } }
  ' "$_rbr_file"
}

cmd_compile() {
  _out_dir=""
  _variant="default"
  _bundle=""
  _bundle_requested=0
  for _arg do
    case "$_arg" in
      --variant=*) _variant="${_arg#--variant=}" ;;
      --bundle=*) _bundle="${_arg#--bundle=}"; _bundle_requested=1 ;;
      --help|-h) usage_compile; return 0 ;;
      --*) die "unknown compile option: $_arg" ;;
      *) [ -z "$_out_dir" ] || die "usage: valise compile [--bundle=<name>] [--variant=<name>] <output-dir>"; _out_dir=$_arg ;;
    esac
  done
  [ -n "$_out_dir" ] || die "usage: valise compile [--bundle=<name>] [--variant=<name>] <output-dir>"
  _out_dir=$(path_normalize "$_out_dir")
  [ "$_out_dir" != "/" ] || die "output directory must not be /"
  _script_dir=$(valise_script_dir)
  _awk_compiler="$_script_dir/../lib/compiler.awk"
  [ -f "$_awk_compiler" ] || die "compiler.awk not found at $_awk_compiler"

  # Find source tree root (look for shell/release/ relative to script or cwd)
  _src_root=""
  # A project invoking the CLI from its root must win over a source tree that
  # happens to contain the package. Build resolves its prelude from the
  # working tree, so compile and build must agree on this root.
  for _candidate in "." "$_script_dir/.." "$_script_dir/../.." "$_script_dir/../../.."; do
    if [ -f "$_candidate/shell/release/module-registry.tsv" ]; then
      _src_root=$(cd "$_candidate" && pwd -P)
      break
    fi
  done
  [ -n "$_src_root" ] || die "cannot find source tree (need shell/release/module-registry.tsv)"

  _registry="$_src_root/shell/release/module-registry.tsv"
  _prelude="$_script_dir/../lib/capabilities.sh"
  _variants_file="$_src_root/shell/release/install-variants"
  [ -f "$_variants_file" ] || die "install-variants not found: $_variants_file"
  _variant_matches=$(awk -F'\t' -v v="$_variant" '$1 == v { count++ } END { print count + 0 }' "$_variants_file")
  [ "$_variant_matches" -eq 1 ] || die "unknown or ambiguous variant: $_variant"
  # Extract prelude function names
  # Extract sp_cap_ functions matching Python SHELL_FUNCTION_DEFINITION regex
  # Pattern: ^name() { (file-appearance order, no sorting)
  [ -r "$_prelude" ] || die "capabilities prelude not found: $_prelude"
  _prelude_fns=$(sed -n 's/^\([a-z_][a-zA-Z0-9_]*\)()[[:space:]]*[({].*/\1/p' "$_prelude" | grep '^sp_cap_' | tr '\n' ' ')
  [ -n "$_prelude_fns" ] || die "capabilities prelude contains no sp_cap_ functions"

  # Extract exclusion list and validate each exclusion against the identity
  # represented by install-variants. Bare names are project module identities;
  # qualified names may explicitly name another registry source. Do this before
  # creating output so all fail-closed validation paths are transactional.
  _exclude_list=""
  if [ -f "$_variants_file" ]; then
    _exclude_list=$(awk -F'	' -v v="$_variant" '$1 == v { print $3 }' "$_variants_file")
  fi
  for _excluded_module in $_exclude_list; do
    _excluded_count=$(awk -F '	' -v wanted="$_excluded_module" '
      NR > 1 {
        if (index(wanted, "@")) {
          split(wanted, parts, "@"); match_row = ($1 == parts[1] && $11 == parts[2])
        } else { match_row = ($1 == wanted && $11 == "shell/module.d") }
        if (match_row) count++
      }
      END { print count + 0 }' "$_registry")
    [ "$_excluded_count" -eq 1 ] ||
      die "variant $_variant excludes unknown or ambiguous registry module: $_excluded_module"
  done

  if [ "$_bundle_requested" -eq 1 ]; then
    [ -n "$_bundle" ] || die "bundle name must not be empty"
    # Validate bundle identity before creating the output transaction.
    release_bundle_roots "$_src_root" bash "$_bundle" >/dev/null ||
      die "failed to resolve bundle roots for bash"
  fi

  # Compile into a private sibling directory. A non-empty destination is
  # rejected before any plan is generated, so a failed compile can never leave
  # a partially replaced output tree. An empty existing directory is supported
  # for callers that pre-create their destination; it is replaced only after
  # every plan has compiled successfully. Dot segments and trailing slashes
  # were normalized above so one destination always has one staging path.
  _out_parent=$(path_parent "$_out_dir")
  _mkdir_path=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  if [ ! -d "$_out_parent" ]; then
    "$_mkdir_path" -p "$_out_parent" || die "cannot create output parent directory"
  fi
  _compile_output_existed=0
  if [ -e "$_out_dir" ] || [ -L "$_out_dir" ]; then
    [ -d "$_out_dir" ] && [ ! -L "$_out_dir" ] || die "output path is not a directory: $_out_dir"
    _compile_output_existed=1
    _compile_output_empty=1
    for _existing_entry in "$_out_dir"/* "$_out_dir"/.[!.]* "$_out_dir"/..?*; do
      if [ -e "$_existing_entry" ] || [ -L "$_existing_entry" ]; then
        _compile_output_empty=0
        break
      fi
    done
    [ "$_compile_output_empty" -eq 1 ] || die "output directory must be empty: $_out_dir"
  fi
  _stage=$(trusted_mktemp_at "$_out_parent" dir "$_out_parent/.valise-compile.XXXXXX") ||
    die "cannot create compile staging directory"

  # Fish plans require native Fish syntax; the plan compiler emits POSIX sh
  # only. A Fish integration uses the native Fish loader instead.
  info "fish plans are not generated; a Fish session uses the native Fish loader only when the release provides one"
  for _shell in bash zsh ksh; do
    # Extract roots for this shell from JSON using POSIX tools
    if [ "$_bundle_requested" -eq 1 ]; then
      _roots=$(release_bundle_roots "$_src_root" "$_shell" "$_bundle") || die "failed to resolve bundle roots for $_shell"
    else
      _roots=$(release_bundle_roots "$_src_root" "$_shell") || die "failed to resolve bundle roots for $_shell"
    fi

    [ -n "$_roots" ] || continue

    _plan_file="installed-modules.$_shell"

    # Filter registry for modules matching this shell and build the compiler's
    # input stream. The preprocessor runs to a file first so a validation
    # failure is not hidden by the following compiler stage.
    _preprocessed="$_stage/.preprocessed.$_shell"
    {
      # Filter seeds through exclusion list
      _filtered_roots=""
      for _seed in $_roots; do
        _seed_name=${_seed%@*}
        _seed_source="shell/module.d"
        case "$_seed" in *@*) _seed_source=${_seed#*@} ;; esac
        _excluded=0
        for _ex in $_exclude_list; do
          case "$_ex" in
            *@*) [ "$_seed" = "$_ex" ] && _excluded=1 ;;
            *) [ "$_seed_name" = "$_ex" ] && [ "$_seed_source" = "shell/module.d" ] && _excluded=1 ;;
          esac
          [ "$_excluded" -eq 1 ] && break
        done
        # Bare seed names are project modules, as for exclusions above.
        case "$_seed" in *@*) ;; *) _seed="$_seed@shell/module.d" ;; esac
        [ "$_excluded" -eq 1 ] || _filtered_roots="$_filtered_roots $_seed"
      done
      _filtered_roots="${_filtered_roots# }"
      printf 'SEED:%s
' "$_filtered_roots"
      printf 'PRELUDE:%s
' "$_prelude_fns"
      # Preprocess the registry with source-qualified identities. This keeps
      # duplicate module names distinct and gives contribution bodies their
      # installed layer prefix.
      awk -F'	' -v shell="$_shell" -v excludes="$_exclude_list" '
        function shell_matches(shells, wanted, count, i, values) {
          if (shells == "any") return 1
          count = split(shells, values, " ")
          for (i = 1; i <= count; i++) {
            if (values[i] == wanted) return 1
            # posix names every POSIX shell class; never Fish.
            if (values[i] == "posix" && wanted != "fish") return 1
          }
          return 0
        }
        NR == 1 { next }
        {
          name = $1; msrc = $11
          if (name == "" || !shell_matches($6, shell)) next
          if (name !~ /^[a-z_][a-zA-Z0-9_]*$/) {
            print "valise: error: invalid module name in registry: " name > "/dev/stderr"
            exit 1
          }
          if ($7 == "") {
            print "valise: error: missing platforms for registry module: " name > "/dev/stderr"
            exit 1
          }
          platform_count = split($7, platform_values, " ")
          for (platform_i = 1; platform_i <= platform_count; platform_i++) {
            if (platform_values[platform_i] !~ /^(any|darwin|linux|bsd|freebsd|openbsd|netbsd)$/) {
              print "valise: error: invalid platform for registry module " name ": " platform_values[platform_i] > "/dev/stderr"
              exit 1
            }
          }
          if ($3 !~ /^(read-only|path-env|generated-file|update-network|install-time|local-secret|local-state|work-only)$/) {
            print "valise: error: invalid side_effect for registry module " name ": " $3 > "/dev/stderr"
            exit 1
          }
          if (msrc != "shell/module.d") {
            if (msrc !~ /^shell\/layers\/[^\/]+\/module\.d$/) {
              print "valise: error: invalid registry source for module " name ": " msrc > "/dev/stderr"
              exit 1
            }
            layer = msrc
            sub(/^shell\/layers\//, "", layer)
            sub(/\/module\.d$/, "", layer)
            if (layer !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || layer ~ /\.\./) {
              print "valise: error: invalid layer source in registry for module " name ": " msrc > "/dev/stderr"
              exit 1
            }
          }
          export_count = split($8, export_values, " ")
          for (export_i = 1; export_i <= export_count; export_i++) {
            if (export_values[export_i] !~ /^[a-z_][a-zA-Z0-9_]*$/ ||
                export_values[export_i] ~ /^(case|do|done|elif|else|esac|fi|for|if|in|then|until|while|time)$/) {
              print "valise: error: invalid export for registry module " name ": " export_values[export_i] > "/dev/stderr"
              exit 1
            }
          }
          identity = name "@" msrc
          row_exists[identity] = 1
          row_name[identity] = name
          row_source[identity] = msrc
          row_req[identity] = $4
          row_opt[identity] = $5
          row_load[identity] = $9
          row_platforms[identity] = $7
          row_side_effect[identity] = $3
          row_exports[identity] = $8
        }
        function excluded_by_variant(identity, name, source,   ei, ex) {
          # An exclusion names a module identity. A qualified exclusion
          # (name@source) matches that exact source; a bare exclusion names a
          # primary module. Both forms apply to every registry source, so a
          # layer module can be excluded by its qualified identity.
          for (ei = 1; ei <= n_ex; ei++) {
            ex = ex_arr[ei]
            if (ex == "") continue
            if (index(ex, "@") > 0) {
              if (ex == identity) return 1
            } else {
              if (ex == name && source == "shell/module.d") return 1
            }
          }
          return 0
        }
        END {
          # Excluded modules are reported to the compiler rather than silently
          # dropped, so an exclusion that breaks a required dependency is
          # diagnosed by name instead of surfacing as "unknown module".
          n_ex = 0
          if (excludes != "") n_ex = split(excludes, ex_arr, " ")
          for (identity in row_exists) {
            name = row_name[identity]; source = row_source[identity]
            if (excluded_by_variant(identity, name, source)) {
              printf "EXCLUDED:%s\t%s\n", identity, name
              continue
            }
            req = ""
            n_req = split(row_req[identity], req_arr, " ")
            for (ri = 1; ri <= n_req; ri++) {
              dep = req_arr[ri]
              if (dep == "") continue
              candidate = dep "@" source
              if (candidate in row_exists) { resolved = candidate }
              else {
                resolved = dep; candidate_count = 0
                for (candidate_key in row_exists) {
                  if (row_name[candidate_key] == dep) { resolved = candidate_key; candidate_count++ }
                }
                if (candidate_count != 1) resolved = dep
              }
              req = req (req == "" ? "" : " ") resolved
            }
            # An optional dependency that is absent for this shell or removed by
            # the variant is simply not there; only a present one joins the plan.
            opt = ""
            n_opt = split(row_opt[identity], opt_arr, " ")
            for (ri = 1; ri <= n_opt; ri++) {
              dep = opt_arr[ri]
              if (dep == "") continue
              resolved = ""
              candidate = dep "@" source
              if ((candidate in row_exists) && !excluded_by_variant(candidate, dep, source)) {
                resolved = candidate
              } else if (!(candidate in row_exists)) {
                candidate_count = 0
                for (candidate_key in row_exists) {
                  if (row_name[candidate_key] == dep) { resolved = candidate_key; candidate_count++ }
                }
                if (candidate_count != 1 || excluded_by_variant(resolved, dep, row_source[resolved])) resolved = ""
              }
              if (resolved != "") opt = opt (opt == "" ? "" : " ") resolved
            }
            load_path = row_load[identity]
            # A meta module has no body, so it has no installed path to prefix.
            if (load_path != "" && source ~ /^shell\/layers\/[^\/]+\/module\.d$/) {
              layer = source
              sub(/^shell\/layers\//, "", layer)
              sub(/\/module\.d$/, "", layer)
              load_path = "layers/" layer "/" load_path
            }
            printf "MOD:%s\t%s\t%s\t%s\t%s\t%s\t%s\n", identity, req, load_path, row_platforms[identity], row_side_effect[identity], row_exports[identity], opt
          }
        }
      ' "$_registry"
    } >"$_preprocessed" || die "cannot preprocess registry for $_shell"
    awk -v target_shell="$_shell" -v plan_name="$_shell" -f "$_awk_compiler" \
      "$_preprocessed" >"$_stage/$_plan_file" || die "cannot compile plan for $_shell"
    _rm_path=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_rm_path" -f "$_preprocessed" || die "cannot remove compiler preprocessing file"
    _preprocessed=""

    info "compiled plan for $_shell"
  done

  _mv_path=$(trusted_utility_path mv) || die "no trusted mv utility available"
  if [ "$_compile_output_existed" -eq 1 ]; then
    _rmdir_path=$(trusted_utility_path rmdir) || die "no trusted rmdir utility available"
    "$_rmdir_path" "$_out_dir" || die "cannot clear empty output directory"
  fi
  if ! "$_mv_path" "$_stage" "$_out_dir"; then
    if [ "$_compile_output_existed" -eq 1 ] && [ ! -e "$_out_dir" ] && [ ! -L "$_out_dir" ]; then
      "$_mkdir_path" "$_out_dir" 2>/dev/null || :
    fi
    die "cannot publish compiled plans"
  fi
  _stage=""
}


# registry_generate <project-root> <output-file> [check]
# Write the deterministic module registry implied by the project's metadata.
# With check=1, compare the generated bytes with output-file and fail on drift.
registry_generate() {
  _rg_root=$1
  _rg_out=$2
  _rg_check=${3:-0}
  export LC_ALL=C
  _rg_script_dir=$(valise_script_dir) || return 1
  _rg_metadata="$_rg_script_dir/../lib/metadata.sh"
  [ -r "$_rg_metadata" ] || die "metadata library not found: $_rg_metadata"
  _rg_out=$(path_normalize "$_rg_out") || return 1
  _rg_parent=$(path_parent "$_rg_out")
  _rg_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _rg_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  _rg_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  _rg_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  _rg_cmp=$(trusted_utility_path cmp) || die "no trusted cmp utility available"
  if [ "$_rg_check" = 1 ]; then
    [ -d "$_rg_parent" ] || die "module registry is missing: $_rg_out"
    [ -f "$_rg_out" ] && [ ! -L "$_rg_out" ] || die "module registry is missing: $_rg_out"
    _rg_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-registry.XXXXXX") ||
      die "cannot create registry comparison file"
  else
    if [ -e "$_rg_out" ] || [ -L "$_rg_out" ]; then
      [ -f "$_rg_out" ] && [ ! -L "$_rg_out" ] || die "registry output path is not a regular file: $_rg_out"
    fi
    [ -d "$_rg_parent" ] || "$_rg_mkdir" -p "$_rg_parent" || die "cannot create registry output parent: $_rg_parent"
    _rg_tmp=$(trusted_mktemp_at "$_rg_parent" file "$_rg_parent/.valise-registry.XXXXXX") ||
      die "cannot create registry staging file"
  fi
  (
    # shellcheck disable=SC1090
    . "$_rg_metadata"
    printf 'name\tversion\tside_effect\trequires\toptional\tshells\tplatforms\texports\tload\tupdates\tsource\n'
    for _rg_meta in "$_rg_root"/shell/module.d/*.meta "$_rg_root"/shell/layers/*/module.d/*.meta; do
      [ -f "$_rg_meta" ] || continue
      source_path_is_physical "$_rg_root" "${_rg_meta#"$_rg_root"/}" || {
        printf 'valise: error: registry metadata path contains a symlink: %s\n' "${_rg_meta#"$_rg_root"/}" >&2
        exit 1
      }
      _rg_rel=${_rg_meta#"$_rg_root"/}
      _rg_source=${_rg_rel%/*}
      case "$_rg_source" in
      shell/module.d) ;;
      shell/layers/*/module.d)
        _rg_layer=${_rg_source#shell/layers/}
        _rg_layer=${_rg_layer%/module.d}
        case "$_rg_layer" in
        [A-Za-z0-9_]*) ;;
        *)
          printf 'valise: error: invalid layer source for registry: %s\n' "$_rg_rel" >&2
          exit 1
          ;;
        esac
        case "$_rg_layer" in
        */*|*..*|*[!A-Za-z0-9_.-]*)
          printf 'valise: error: invalid layer source for registry: %s\n' "$_rg_rel" >&2
          exit 1
          ;;
        esac
        ;;
      *)
        printf 'valise: error: unsupported metadata source for registry: %s\n' "$_rg_rel" >&2
        exit 1
        ;;
      esac
      _rg_record=$(sp_metadata_read "$_rg_meta") || {
        printf 'valise: error: %s: %s\n' "$_rg_rel" "${_rg_record:-invalid metadata}" >&2
        exit 1
      }
      _rg_name=
      _rg_version=
      _rg_side_effect=
      _rg_requires=
      _rg_optional=
      _rg_shells=
      _rg_platforms=
      _rg_exports=
      _rg_load=
      _rg_updates=
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
        updates=*) _rg_updates=${_rg_line#updates=} ;;
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
      if [ "$_rg_source" != "shell/module.d" ]; then
        case "$_rg_name" in
        contrib_*) ;;
        *)
          printf 'valise: error: %s: layer module name %s must use the contrib_ prefix\n' "$_rg_rel" "$_rg_name" >&2
          exit 1
          ;;
        esac
      fi
      if [ -n "$_rg_load" ]; then
        _rg_module_root=${_rg_source%/module.d}
        if ! source_path_is_physical "$_rg_root" "$_rg_module_root/$_rg_load"; then
          printf 'valise: error: %s: load path contains a symlink: %s\n' "$_rg_rel" "$_rg_load" >&2
          exit 1
        fi
        if [ ! -f "$_rg_root/$_rg_module_root/$_rg_load" ]; then
          printf 'valise: error: %s: load path does not exist: %s\n' "$_rg_rel" "$_rg_load" >&2
          exit 1
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_rg_name" "$_rg_version" "$_rg_side_effect" "$_rg_requires" \
        "$_rg_optional" "$_rg_shells" "$_rg_platforms" "$_rg_exports" \
        "$_rg_load" "$_rg_updates" "$_rg_source"
    done
  ) >"$_rg_tmp" || {
    "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
    die "cannot generate module registry"
  }
  "$_rg_chmod" 0644 "$_rg_tmp" || {
    "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
    die "cannot set registry file mode"
  }
  if [ "$_rg_check" = 1 ]; then
    if [ ! -f "$_rg_out" ]; then
      "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
      die "module registry is missing: $_rg_out"
    fi
    if ! "$_rg_cmp" -s "$_rg_tmp" "$_rg_out"; then
      "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
      die "module registry is out of date: $_rg_out"
    fi
    "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
    _rg_tmp=""
    return 0
  fi
  "$_rg_mv" "$_rg_tmp" "$_rg_out" || {
    "$_rg_rm" -f "$_rg_tmp" 2>/dev/null || :
    die "cannot publish module registry"
  }
  _rg_tmp=""
}

cmd_registry() {
  _registry_out=""
  _registry_check=0
  for _registry_arg do
    case "$_registry_arg" in
      --check) _registry_check=1 ;;
      --help|-h) usage_registry; return 0 ;;
      --*) die "unknown registry option: $_registry_arg" ;;
      *) [ -z "$_registry_out" ] || die "usage: valise registry [--check] [registry-path]"; _registry_out=$_registry_arg ;;
    esac
  done
  _registry_root=$(pwd -P) || die "cannot resolve working directory"
  [ -d "$_registry_root/shell" ] || die "run from the consuming project root (need shell/)"
  [ -n "$_registry_out" ] || _registry_out="$_registry_root/shell/release/module-registry.tsv"
  registry_generate "$_registry_root" "$_registry_out" "$_registry_check"
}


project_config_load() {
  _pc_root=$(pwd -P) || die "cannot resolve working directory"
  [ -d "$_pc_root/shell/module.d" ] || die "run from the consuming project root (need shell/module.d)"
  _project_root=$_pc_root
  _project_variant=default
  _project_bundle=default
  [ -n "${HOME:-}" ] || die "HOME is required for project commands"
  _project_conf="$_project_root/shell/release/project.conf"
  if [ -f "$_project_conf" ]; then
    [ ! -L "$_project_conf" ] || die "project.conf must not be a symlink: $_project_conf"
    while IFS= read -r _pc_line || [ -n "$_pc_line" ]; do
      case "$_pc_line" in
      '' | '#'*) continue ;;
      variant=*) _project_variant=${_pc_line#variant=} ;;
      bundle=*) _project_bundle=${_pc_line#bundle=} ;;
      *) die "invalid project.conf line: $_pc_line" ;;
      esac
    done <"$_project_conf"
  fi
  [ -n "$_project_variant" ] || die "project variant must not be empty"
  [ -n "$_project_bundle" ] || die "project bundle must not be empty"
  unset _pc_root _pc_line _project_conf
}

project_meta_add_require() {
  _pm_meta=$1
  _pm_module=$2
  [ -f "$_pm_meta" ] && [ ! -L "$_pm_meta" ] || die "seed metadata file is missing or unsafe: $_pm_meta"
  _pm_parent=$(path_parent "$_pm_meta")
  _pm_tmp=$(trusted_mktemp_at "$_pm_parent" file "$_pm_parent/.valise-meta.XXXXXX") ||
    die "cannot create seed metadata staging file"
  _pm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_pm_awk" -v module="$_pm_module" '
    BEGIN { have = 0 }
    /^requires=/ {
      value = substr($0, 10)
      count = split(value, parts, " ")
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
  ' "$_pm_meta" >"$_pm_tmp" || {
    _pm_rm=$(trusted_utility_path rm) || _pm_rm=""
    [ -z "$_pm_rm" ] || "$_pm_rm" -f "$_pm_tmp" 2>/dev/null || :
    die "cannot update seed metadata: $_pm_meta"
  }
  _pm_mode=$(file_mode "$_pm_meta")
  [ -n "$_pm_mode" ] || die "cannot read seed metadata mode: $_pm_meta"
  _pm_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pm_chmod" "$_pm_mode" "$_pm_tmp" || die "cannot preserve seed metadata mode"
  _pm_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_pm_mv" "$_pm_tmp" "$_pm_meta" || die "cannot publish seed metadata: $_pm_meta"
  _pm_tmp=""
  unset _pm_meta _pm_module _pm_parent _pm_awk _pm_mode _pm_chmod _pm_mv _pm_rm
}

project_meta_remove_module() {
  _pm_meta=$1
  _pm_module=$2
  [ -f "$_pm_meta" ] && [ ! -L "$_pm_meta" ] || die "metadata file is missing or unsafe: $_pm_meta"
  _pm_parent=$(path_parent "$_pm_meta")
  _pm_tmp=$(trusted_mktemp_at "$_pm_parent" file "$_pm_parent/.valise-meta.XXXXXX") ||
    die "cannot create metadata staging file"
  _pm_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  "$_pm_awk" -v module="$_pm_module" '
    /^requires=/ {
      value = substr($0, 10)
      count = split(value, parts, " ")
      output = ""
      for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == module) continue
        output = output (output == "" ? "" : " ") parts[i]
      }
      print "requires=" output
      next
    }
    /^optional=/ {
      value = substr($0, 10)
      count = split(value, parts, " ")
      output = ""
      for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == module) continue
        output = output (output == "" ? "" : " ") parts[i]
      }
      print "optional=" output
      next
    }
    { print }
  ' "$_pm_meta" >"$_pm_tmp" || {
    _pm_rm=$(trusted_utility_path rm) || _pm_rm=""
    [ -z "$_pm_rm" ] || "$_pm_rm" -f "$_pm_tmp" 2>/dev/null || :
    die "cannot update metadata: $_pm_meta"
  }
  _pm_mode=$(file_mode "$_pm_meta")
  [ -n "$_pm_mode" ] || die "cannot read metadata mode: $_pm_meta"
  _pm_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pm_chmod" "$_pm_mode" "$_pm_tmp" || die "cannot preserve metadata mode"
  _pm_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_pm_mv" "$_pm_tmp" "$_pm_meta" || die "cannot publish metadata: $_pm_meta"
  _pm_tmp=""
  unset _pm_meta _pm_module _pm_parent _pm_awk _pm_mode _pm_chmod _pm_mv _pm_rm
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
# Print a release file without the module's names in the given column. Bare names
# in these files mean primary modules; a layer module is named module@source.
# Exit 3 when a row that named the module is left with no names.
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
        if (parts[i] == module "@" source || (source == "shell/module.d" && parts[i] == module)) {
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
  _rr_tmp=$(trusted_mktemp_at "$_rs_parent" file "$_rs_parent/.valise-release.XXXXXX") ||
    die "cannot create release file staging file"
  _rs_status=0
  project_release_filter "$1" "$2" "$3" "$4" >"$_rr_tmp" || _rs_status=$?
  case "$_rs_status" in
  0 | 3) ;;
  *) die "cannot update release file: $1" ;;
  esac
  _rs_mode=$(file_mode "$1")
  [ -n "$_rs_mode" ] || die "cannot read release file mode: $1"
  _rs_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_rs_chmod" "$_rs_mode" "$_rr_tmp" || die "cannot preserve release file mode"
  _rs_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_rs_mv" "$_rr_tmp" "$1" || die "cannot publish release file: $1"
  _rr_tmp=""
  unset _rs_parent _rs_status _rs_mode _rs_chmod _rs_mv
}

# project_write_integration <file> <block>
# Replace the valise managed block in place, or append one. A symlink belongs to
# whatever manages it, so it is reported and left alone. Unpaired markers mean the
# file was edited by hand: rewriting could delete the user's lines, so refuse.
project_write_integration() {
  _pi_target=$1
  _pi_snippet=$2
  if [ -L "$_pi_target" ]; then
    info "warning: $_pi_target is a symlink; add the output of 'valise init' to it yourself"
    unset _pi_target _pi_snippet
    return 0
  fi
  _pi_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  if [ -f "$_pi_target" ]; then
    "$_pi_awk" '
      BEGIN { open = 0; bad = 0 }
      /^# BEGIN valise managed block$/ { if (open) bad = 1; open = 1; next }
      /^# END valise managed block$/ { if (!open) bad = 1; open = 0; next }
      END { exit (bad || open) ? 1 : 0 }
    ' "$_pi_target" ||
      die "unpaired valise managed block markers in $_pi_target (restore or remove the BEGIN and END lines, then retry)"
  elif [ -e "$_pi_target" ]; then
    die "startup path is not a regular file: $_pi_target"
  fi
  _pi_parent=$(path_parent "$_pi_target")
  _pi_tmp=$(trusted_mktemp_at "$_pi_parent" file "$_pi_parent/.valise-integration.XXXXXX") ||
    die "cannot create integration staging file"
  if [ -f "$_pi_target" ]; then
    # The block travels through ENVIRON: awk -v would interpret its backslashes.
    _VALISE_BLOCK=$_pi_snippet "$_pi_awk" '
      /^# BEGIN valise managed block$/ {
        if (!written) print ENVIRON["_VALISE_BLOCK"]
        written = 1
        skip = 1
        next
      }
      /^# END valise managed block$/ { skip = 0; next }
      !skip { print; last = $0; lines++ }
      END {
        if (!written) {
          if (lines > 0 && last != "") print ""
          print ENVIRON["_VALISE_BLOCK"]
        }
      }
    ' "$_pi_target" >"$_pi_tmp" || die "cannot read startup file: $_pi_target"
    _pi_cmp=$(trusted_utility_path cmp) || die "no trusted cmp utility available"
    if "$_pi_cmp" -s "$_pi_tmp" "$_pi_target"; then
      _pi_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
      "$_pi_rm" -f "$_pi_tmp" || die "cannot remove unchanged integration staging file"
      _pi_tmp=""
      info "shell integration current: $_pi_target"
      unset _pi_target _pi_snippet _pi_parent _pi_awk _pi_cmp _pi_rm
      return 0
    fi
    _pi_mode=$(file_mode "$_pi_target")
    [ -n "$_pi_mode" ] || die "cannot read startup file mode: $_pi_target"
  else
    printf '%s\n' "$_pi_snippet" >"$_pi_tmp" || die "cannot write integration staging file"
    _pi_mode=0644
  fi
  _pi_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  "$_pi_chmod" "$_pi_mode" "$_pi_tmp" || die "cannot set startup file mode"
  _pi_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  "$_pi_mv" "$_pi_tmp" "$_pi_target" || die "cannot publish startup file: $_pi_target"
  _pi_tmp=""
  info "shell integration written: $_pi_target"
  unset _pi_target _pi_snippet _pi_parent _pi_awk _pi_cmp _pi_rm _pi_mode _pi_chmod _pi_mv
}

cmd_new() {
  _new_target=
  for _new_arg do
    case "$_new_arg" in
      --help|-h) usage_new; return 0 ;;
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
  "$_new_mkdir" -p "$_new_target/shell/module.d" "$_new_target/shell/modules" "$_new_target/shell/release" ||
    die "cannot create project directories: $_new_target"
  printf '%s\n' \
    'name=profile_main' \
    'version=' \
    'side_effect=read-only' \
    'requires=' \
    'optional=' \
    'shells=bash zsh ksh' \
    'platforms=any' \
    'exports=profile_main_loaded' \
    'load=modules/profile_main.sh' \
    >"$_new_target/shell/module.d/profile_main.meta"
  printf '%s\n' \
    '# Shared project initialization. Add shell functions or exports here.' \
    'profile_main_loaded() { :; }' \
    >"$_new_target/shell/modules/profile_main.sh"
  printf 'variant_name\tdescription\texcluded_modules\ndefault\tAll project modules\t\n' \
    >"$_new_target/shell/release/install-variants"
  printf '# bundle\tshell\troots\ndefault\tbash\tprofile_main\ndefault\tzsh\tprofile_main\ndefault\tksh\tprofile_main\n' \
    >"$_new_target/shell/release/bundle-roots"
  printf 'variant=default\nbundle=default\n' \
    >"$_new_target/shell/release/project.conf"
  printf '%s\n' \
    "created valise project: $_new_target" \
    "next steps:" \
    "  cd ${_new_target#"$(pwd -P)"/}" \
    "  valise module new hello --exports=hello" \
    "  valise apply"
  unset _new_target _new_arg _new_entry _new_mkdir
}

cmd_module() {
  _module_subcmd=${1:-}
  [ -n "$_module_subcmd" ] || die "usage: valise module <new|list|remove> [args]"
  case "$_module_subcmd" in
  --help|-h) usage_module; return 0 ;;
  new)
    shift
    _module_name=
    _module_exports=
    for _module_arg do
      case "$_module_arg" in
        --exports=*) _module_exports=${_module_arg#--exports=} ;;
        --help|-h) usage_module; return 0 ;;
        --*) die "unknown module new option: $_module_arg" ;;
        *) [ -z "$_module_name" ] || die "usage: valise module new <name> [--exports=<list>]"; _module_name=$_module_arg ;;
      esac
    done
    [ -n "$_module_name" ] || die "module new requires a module name"
    case "$_module_name" in
      [abcdefghijklmnopqrstuvwxyz_]*) ;;
      *) die "invalid module name: $_module_name" ;;
    esac
    case "$_module_name" in
      *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "invalid module name: $_module_name" ;;
    esac
    project_config_load
    _module_seed="$_project_root/shell/module.d/profile_main.meta"
    [ -f "$_module_seed" ] && [ ! -L "$_module_seed" ] ||
      die "seed metadata file is missing or unsafe: $_module_seed"
    [ -d "$_project_root/shell/modules" ] ||
      die "module body directory is missing: $_project_root/shell/modules"
    [ -w "$_project_root/shell/module.d" ] && [ -w "$_project_root/shell/modules" ] ||
      die "module directories are not writable: $_project_root/shell"
    _module_meta="$_project_root/shell/module.d/$_module_name.meta"
    _module_body="$_project_root/shell/modules/$_module_name.sh"
    [ ! -e "$_module_meta" ] && [ ! -L "$_module_meta" ] || die "module metadata already exists: $_module_name"
    [ ! -e "$_module_body" ] && [ ! -L "$_module_body" ] || die "module body already exists: $_module_name"
    _module_export_words=
    if [ -n "$_module_exports" ]; then
      _module_old_ifs=${IFS-}
      IFS=', '
      for _module_export in $_module_exports; do
        [ -n "$_module_export" ] || continue
        case "$_module_export" in
          [abcdefghijklmnopqrstuvwxyz_]*) ;;
          *) die "invalid export name: $_module_export" ;;
        esac
        case "$_module_export" in
          *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "invalid export name: $_module_export" ;;
        esac
        case "$_module_export" in
          case|do|done|elif|else|esac|fi|for|if|in|then|until|while|time)
            die "invalid export name (reserved word): $_module_export"
            ;;
        esac
        _module_export_words="$_module_export_words $_module_export"
      done
      if [ "${_module_old_ifs+x}" = x ]; then
        IFS=$_module_old_ifs
      else
        unset IFS
      fi
    fi
    _module_export_words=${_module_export_words# }
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    for _module_export in $_module_export_words; do
      for _module_candidate in "$_project_root"/shell/module.d/*.meta "$_project_root"/shell/layers/*/module.d/*.meta; do
        [ -f "$_module_candidate" ] || continue
        if "$_module_awk" -F= -v wanted="$_module_export" '
          $1 == "exports" {
            count = split(substr($0, length($1) + 2), words, " ")
            for (i = 1; i <= count; i++) {
              if (words[i] == wanted) found = 1
            }
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
        _module_old_ifs=${IFS-}
        IFS=' '
        for _module_export in $_module_export_words; do
          printf '%s() {\n  printf "%%s\\n" "hello from %s"\n}\n\n' "$_module_export" "$_module_name"
        done
        if [ "${_module_old_ifs+x}" = x ]; then
          IFS=$_module_old_ifs
        else
          unset IFS
        fi
      else
        printf '%s\n' "# This module has no declared exports."
      fi
    } >"$_module_body"
    project_meta_add_require "$_project_root/shell/module.d/profile_main.meta" "$_module_name"
    info "created module $_module_name and wired it into profile_main"
    ;;
  list)
    shift
    [ "$#" -eq 0 ] || die "usage: valise module list"
    project_config_load
    _module_list_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-module-list.XXXXXX") ||
      die "cannot create module list staging file"
    registry_generate "$_project_root" "$_module_list_tmp"
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    "$_module_awk" -F '\t' 'NR > 1 { print $1 }' "$_module_list_tmp"
    _module_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_module_rm" -f "$_module_list_tmp" || die "cannot remove module list staging file"
    _module_list_tmp=""
    ;;
  remove)
    shift
    _module_name=${1:-}
    [ -n "$_module_name" ] || die "module remove requires a module name"
    project_config_load
    _module_meta=
    _module_source=
    for _module_candidate in "$_project_root"/shell/module.d/*.meta "$_project_root"/shell/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      _module_candidate_name=${_module_candidate##*/}
      _module_candidate_name=${_module_candidate_name%.meta}
      if [ "$_module_candidate_name" = "$_module_name" ]; then
        _module_meta=$_module_candidate
        _module_source=${_module_candidate%/*}
        break
      fi
    done
    [ -n "$_module_meta" ] || die "module not found: $_module_name"
    # Everything that would make the removal fail is checked here, before any
    # file changes: a half-applied removal leaves a project that cannot build.
    _module_registry_source=${_module_source#"$_project_root"/}
    _module_bundle_roots=$_project_root/shell/release/bundle-roots
    _module_variants=$_project_root/shell/release/install-variants
    for _module_candidate in "$_project_root"/shell/module.d/*.meta "$_project_root"/shell/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      [ "$_module_candidate" != "$_module_meta" ] || continue
      if project_meta_loses_all_targets "$_module_candidate" "$_module_name"; then
        _module_candidate_name=${_module_candidate##*/}
        die "cannot remove $_module_name: ${_module_candidate_name%.meta} requires only this module and would have nothing to load; add another dependency or remove ${_module_candidate_name%.meta} first"
      fi
    done
    for _module_candidate in "$_module_bundle_roots" "$_module_variants"; do
      if [ -e "$_module_candidate" ] || [ -L "$_module_candidate" ]; then
        [ -f "$_module_candidate" ] && [ ! -L "$_module_candidate" ] || die "release file is missing or unsafe: $_module_candidate"
      fi
    done
    if [ -f "$_module_bundle_roots" ]; then
      _module_status=0
      project_release_filter "$_module_bundle_roots" 3 "$_module_name" "$_module_registry_source" >/dev/null || _module_status=$?
      case "$_module_status" in
      0) ;;
      3) die "cannot remove $_module_name: it is the only root of a bundle in shell/release/bundle-roots; add another root first" ;;
      *) die "cannot read release file: $_module_bundle_roots" ;;
      esac
    fi
    _module_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
    _module_load=$("$_module_awk" -F= '$1 == "load" { print substr($0, length($1) + 2); exit }' "$_module_meta")
    _module_body_path=
    _module_body_shared=0
    if [ -n "$_module_load" ]; then
      case "$_module_load" in
      ''|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*)
        die "invalid module load path: $_module_load"
        ;;
      esac
      _module_root=${_module_source%/module.d}
      source_path_is_physical "$_module_root" "$_module_load" ||
        die "module load path contains a symlink: $_module_load"
      _module_body_path="$_module_root/$_module_load"
      [ ! -d "$_module_body_path" ] || die "module load path is a directory: $_module_load"
      [ -f "$_module_body_path" ] || die "module body is missing: $_module_load"
      # Another module in the same source may declare the same body. Keep it
      # when that is true: removing the metadata is enough, and deleting the
      # body would break the module that still loads it.
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
    # Every path the removal rewrites must be writable before the first change.
    [ -w "$_module_source" ] || die "module metadata directory is not writable: $_module_source"
    [ -w "$_project_root/shell/release" ] || die "release directory is not writable: $_project_root/shell/release"
    for _module_candidate in "$_project_root"/shell/module.d/*.meta "$_project_root"/shell/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      _module_candidate_parent=$(path_parent "$_module_candidate")
      [ -w "$_module_candidate_parent" ] ||
        die "metadata directory is not writable: $_module_candidate_parent"
    done
    for _module_candidate in "$_module_bundle_roots" "$_module_variants"; do
      if [ -f "$_module_candidate" ]; then
        [ -w "$_module_candidate" ] || die "release file is not writable: $_module_candidate"
      fi
    done
    _module_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    if [ -n "$_module_body_path" ] && [ "$_module_body_shared" -eq 0 ]; then
      "$_module_rm" -f "$_module_body_path" || die "cannot remove module body: $_module_load"
    fi
    "$_module_rm" -f "$_module_meta" || die "cannot remove module metadata: $_module_name"
    for _module_candidate in "$_project_root"/shell/module.d/*.meta "$_project_root"/shell/layers/*/module.d/*.meta; do
      [ -f "$_module_candidate" ] || continue
      project_meta_remove_module "$_module_candidate" "$_module_name"
    done
    project_release_strip "$_module_bundle_roots" 3 "$_module_name" "$_module_registry_source"
    project_release_strip "$_module_variants" 3 "$_module_name" "$_module_registry_source"
    registry_generate "$_project_root" "$_project_root/shell/release/module-registry.tsv"
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
      --variant=*) _build_variant=${_build_arg#--variant=} ;;
      --bundle=*) _build_bundle=${_build_arg#--bundle=} ;;
      --help|-h) usage_build; return 0 ;;
      --*) die "unknown build option: $_build_arg" ;;
      *) [ -z "$_build_out" ] || die "usage: valise build [--variant=<name>] [--bundle=<name>] [out]"; _build_out=$_build_arg ;;
    esac
  done
  project_config_load
  [ -n "$_build_variant" ] || _build_variant=$_project_variant
  [ -n "$_build_bundle" ] || _build_bundle=$_project_bundle
  [ -n "$_build_out" ] || _build_out=$_project_root/build/release
  _build_out=$(path_normalize "$_build_out") || die "cannot resolve build output path"
  # The previous default output stays in place until the new tree has compiled
  # and been manifested, so a failed build never destroys a good one.
  if [ "$_build_out" = "$_project_root/build/release" ]; then
    _build_release_tree --replace-default --variant="$_build_variant" --bundle="$_build_bundle" "$_build_out"
  else
    _build_release_tree --variant="$_build_variant" --bundle="$_build_bundle" "$_build_out"
  fi
  unset _build_out _build_arg _build_variant _build_bundle
}

cmd_apply() {
  _apply_variant=
  _apply_bundle=
  _apply_install_arg=
  for _apply_arg do
    case "$_apply_arg" in
      --variant=*) _apply_variant=${_apply_arg#--variant=} ;;
      --bundle=*) _apply_bundle=${_apply_arg#--bundle=} ;;
      --no-integration) _apply_install_arg=--no-integration ;;
      --help|-h) usage_apply; return 0 ;;
      *) die "unknown apply option: $_apply_arg" ;;
    esac
  done
  project_config_load
  [ -n "$_apply_variant" ] || _apply_variant=$_project_variant
  [ -n "$_apply_bundle" ] || _apply_bundle=$_project_bundle
  cmd_build --variant="$_apply_variant" --bundle="$_apply_bundle"
  _apply_build_out=$_project_root/build/release
  _apply_old_pwd=$(pwd -P) || die "cannot resolve current directory"
  cd "$_apply_build_out" || die "cannot enter build output: $_apply_build_out"
  cmd_install $_apply_install_arg || die "valise install failed"
  cd "$_apply_old_pwd" || die "cannot restore project directory: $_apply_old_pwd"
  cmd_verify_active
  info "applied project: $_project_root"
  unset _apply_arg _apply_variant _apply_bundle _apply_install_arg _apply_build_out _apply_old_pwd
}

cmd_status() {
  for _status_arg do
    case "$_status_arg" in
      --help|-h) usage_status; return 0 ;;
      *) die "unknown status option: $_status_arg" ;;
    esac
  done
  project_config_load
  printf 'project: %s\n' "$_project_root"
  printf 'variant: %s\n' "$_project_variant"
  printf 'bundle: %s\n' "$_project_bundle"
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
  unset _status_home _status_targets _status_target
  if (registry_generate "$_project_root" "$_project_root/shell/release/module-registry.tsv" 1) >/dev/null 2>&1; then
    printf 'registry: up to date\n'
  else
    printf 'registry: out of date\n'
  fi
  if [ -L "$VALISE_ACTIVE_LINK" ]; then
    _status_active_target=$(active_release_dir 2>/dev/null || :)
    if [ -n "$_status_active_target" ]; then
      _status_active_id=${_status_active_target##*/}
      printf 'active release: %s\n' "$_status_active_id"
    else
      printf 'active release: broken symlink\n'
    fi
  else
    printf 'active release: none\n'
  fi
  _status_build_manifest="$_project_root/build/release/shell/install/profile-release.manifest"
  if [ -f "$_status_build_manifest" ]; then
    _status_build_hash=$(file_sha256 "$_status_build_manifest") || die "cannot hash build manifest"
    printf 'build output: %s\n' "$_project_root/build/release"
    if [ -n "${_status_active_target:-}" ] && [ -d "$_status_active_target" ]; then
      if [ -f "$_status_active_target/.valise-manifest" ]; then
        _status_active_manifest="$_status_active_target/.valise-manifest"
      else
        _status_active_manifest="$_status_active_target/shell/install/profile-release.manifest"
      fi
      if [ -f "$_status_active_manifest" ]; then
        _status_active_hash=$(file_sha256 "$_status_active_manifest") || die "cannot hash active manifest"
        if [ "$_status_build_hash" = "$_status_active_hash" ]; then
          printf 'drift: active release matches build output\n'
        else
          printf 'drift: active release differs from build output\n'
        fi
      else
        printf 'drift: active manifest missing\n'
      fi
    else
      printf 'drift: no active release to compare\n'
    fi
  else
    printf 'build output: not built\n'
  fi
  unset _status_awk _status_active_target _status_active_id _status_build_manifest _status_build_hash _status_active_manifest _status_active_hash
}


# _build_release_tree [--variant=<name>] [--bundle=<name>] <out-dir>
# Internal implementation of valise build. Build a release tree for compiled
# plans from the consuming project in the current directory. The tree holds exactly what the plans source, at the paths
# they source it from:
#   generated/installed-modules.<shell>       valise compile output
#   vendor/shell-profile/lib/capabilities.sh  the engine capability prelude
#   <load> and layers/<provider>/<load>        every registry module body, with
#                                             its .meta beside it in module.d/
#   shell/release/                            the registry, roots and variants
_build_release_tree() {
  _as_out=""
  _as_variant=""
  _as_bundle=""
  _as_variant_set=0
  _as_bundle_set=0
  _as_replace_default=0
  for _as_arg do
    case "$_as_arg" in
      --variant=*) [ "$_as_variant_set" -eq 0 ] || die "duplicate --variant option"; _as_variant=${_as_arg#--variant=}; _as_variant_set=1 ;;
      --bundle=*) [ "$_as_bundle_set" -eq 0 ] || die "duplicate --bundle option"; _as_bundle=${_as_arg#--bundle=}; _as_bundle_set=1 ;;
      --replace-default) _as_replace_default=1 ;;
      --*) die "unknown build option: $_as_arg" ;;
      *) [ -z "$_as_out" ] || die "usage: valise build [--variant=<name>] [--bundle=<name>] [out]"; _as_out=$_as_arg ;;
    esac
  done
  [ -n "$_as_out" ] || die "usage: valise build [--variant=<name>] [--bundle=<name>] [out]"
  [ "$_as_variant_set" -eq 0 ] || [ -n "$_as_variant" ] || die "variant name must not be empty"
  [ "$_as_bundle_set" -eq 0 ] || [ -n "$_as_bundle" ] || die "bundle name must not be empty"
  _as_src=$(pwd -P) || die "cannot resolve working directory"
  [ -d "$_as_src/shell/module.d" ] || die "run from the consuming project root (need shell/module.d)"
  _as_out=$(path_normalize "$_as_out")
  [ "$_as_out" != "/" ] || die "output directory must not be /"
  case "$_as_out" in
    "$_as_src"/*)
      source_path_is_physical "$_as_src" "${_as_out#"$_as_src"/}" ||
        die "output path contains a symlink: $_as_out"
      ;;
  esac
  _as_output_existed=0
  if [ -e "$_as_out" ] || [ -L "$_as_out" ]; then
    [ -d "$_as_out" ] && [ ! -L "$_as_out" ] || die "output path is not a directory: $_as_out"
    _as_output_empty=1
    for _as_entry in "$_as_out"/* "$_as_out"/.[!.]* "$_as_out"/..?*; do
      if [ -e "$_as_entry" ] || [ -L "$_as_entry" ]; then
        _as_output_empty=0
        break
      fi
    done
    [ "$_as_output_empty" -eq 1 ] || [ "$_as_replace_default" -eq 1 ] ||
      die "output directory must be empty: $_as_out"
    _as_output_existed=1
  fi
  _as_registry="$_as_src/shell/release/module-registry.tsv"
  registry_generate "$_as_src" "$_as_registry"
  _as_script_dir=$(valise_script_dir) || die "cannot locate the valise engine"
  _as_prelude="$_as_script_dir/../lib/capabilities.sh"
  [ -r "$_as_prelude" ] || die "capabilities prelude not found: $_as_prelude"
  _as_parent=$(path_parent "$_as_out")
  _as_mkdir=$(trusted_utility_path mkdir) || die "no trusted mkdir utility available"
  _as_cp=$(trusted_utility_path cp) || die "no trusted cp utility available"
  _as_find=$(trusted_utility_path find) || die "no trusted find utility available"
  _as_chmod=$(trusted_utility_path chmod) || die "no trusted chmod utility available"
  _as_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  [ -d "$_as_parent" ] || "$_as_mkdir" -p "$_as_parent" || die "cannot create output parent: $_as_parent"
  # Build beside the destination and publish only after the complete tree and
  # manifest exist, so a failed compile or copy never leaves a partial release.
  _stage=$(trusted_mktemp_at "$_as_parent" dir "$_as_parent/.valise-build.XXXXXX") ||
    die "cannot create build staging directory"

  if [ -n "$_as_variant" ] && [ -n "$_as_bundle" ]; then
    "$0" compile --variant="$_as_variant" --bundle="$_as_bundle" "$_stage/generated" || die "valise compile failed"
  elif [ -n "$_as_variant" ]; then
    "$0" compile --variant="$_as_variant" "$_stage/generated" || die "valise compile failed"
  elif [ -n "$_as_bundle" ]; then
    "$0" compile --bundle="$_as_bundle" "$_stage/generated" || die "valise compile failed"
  else
    "$0" compile "$_stage/generated" || die "valise compile failed"
  fi
  "$_as_mkdir" -p "$_stage/vendor/shell-profile/lib" "$_stage/shell" || die "cannot create release tree"
  "$_as_cp" "$_as_prelude" "$_stage/vendor/shell-profile/lib/capabilities.sh" || die "cannot copy prelude"
  "$_as_cp" -R "$_as_src/shell/release" "$_stage/shell/release" || die "cannot copy shell/release"

  # Registry columns: 1 name, 9 load, 11 source (the directory holding the
  # .meta). A primary module resolves against the parent of its source
  # directory; a layer module under shell/layers/<provider>/module.d lands at
  # layers/<provider>/ in the release, matching the compiled plan paths.
  _as_tab=$(printf '\t')
  _as_rows="$_stage/.registry-rows"
  "$_as_awk" -F "$_as_tab" 'NR > 1 && $1 != "" { print $1 "|" $9 "|" $11 }' \
    "$_as_registry" >"$_as_rows" || die "cannot read module registry"
  while IFS='|' read -r _as_name _as_load _as_source; do
    [ -n "$_as_name" ] || continue
    # Module names index both source and destination paths. Reject anything
    # that is not a metadata identifier before either path is constructed.
    case "$_as_name" in
      [abcdefghijklmnopqrstuvwxyz_]*) ;;
      *) die "invalid module name in registry: $_as_name" ;;
    esac
    case "$_as_name" in
      *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "invalid module name in registry: $_as_name" ;;
    esac
    case "$_as_source" in
      shell/module.d) _as_prefix= ;;
      shell/layers/*/module.d)
        _as_layer=${_as_source#shell/layers/}
        _as_layer=${_as_layer%/module.d}
        case "$_as_layer" in
          [A-Za-z0-9_]*) ;;
          *) die "invalid layer source in registry: $_as_source" ;;
        esac
        case "$_as_layer" in
          */*|*..*|*[!A-Za-z0-9_.-]*) die "invalid layer source in registry: $_as_source" ;;
        esac
        _as_prefix="layers/$_as_layer/"
        ;;
      *) die "unsupported registry source: $_as_source (expected shell/module.d or shell/layers/<provider>/module.d)" ;;
    esac
    case "$_as_load" in
      /*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*) die "invalid load path in registry for $_as_name: $_as_load" ;;
    esac
    _as_root=${_as_source%/module.d}
    _as_pairs="$_as_source/$_as_name.meta:${_as_prefix}module.d/$_as_name.meta"
    if [ -n "$_as_load" ]; then
      _as_pairs="$_as_pairs $_as_root/$_as_load:$_as_prefix$_as_load"
    fi
    for _as_pair in $_as_pairs; do
      _as_from="$_as_src/${_as_pair%%:*}"
      _as_to="$_stage/${_as_pair#*:}"
      source_path_is_physical "$_as_src" "${_as_pair%%:*}" ||
        die "registry file path contains a symlink: ${_as_pair%%:*}"
      [ -f "$_as_from" ] && [ ! -L "$_as_from" ] ||
        die "registry file missing or a symlink: ${_as_pair%%:*}"
      [ ! -e "$_as_to" ] && [ ! -L "$_as_to" ] || die "release path collision: ${_as_pair#*:}"
      "$_as_mkdir" -p "$(path_parent "$_as_to")" &&
        "$_as_cp" "$_as_from" "$_as_to" || die "cannot copy ${_as_pair%%:*}"
    done
  done <"$_as_rows"
  _as_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
  "$_as_rm" -f "$_as_rows" || die "cannot remove build scratch file"
  "$_as_find" "$_stage" -type f -exec "$_as_chmod" 0644 {} + || die "cannot normalise file modes"
  "$0" make-manifest "$_stage" || die "valise make-manifest failed"

  _as_mv=$(trusted_utility_path mv) || die "no trusted mv utility available"
  if [ "$_as_output_existed" -eq 1 ]; then
    if [ "$_as_replace_default" -eq 1 ]; then
      remove_tree "$_as_out" || die "cannot clear previous build output: $_as_out"
    else
      _as_rmdir=$(trusted_utility_path rmdir) || die "no trusted rmdir utility available"
      "$_as_rmdir" "$_as_out" || die "cannot clear empty output directory"
    fi
  fi
  "$_as_mv" "$_stage" "$_as_out" || die "cannot publish release tree"
  _stage=""
}

cmd_explain_variant() {
  _variant="${1:-default}"
  case "$_variant" in
    --help|-h) usage_explain_variant; return 0 ;;
  esac
  _script_dir=$(valise_script_dir)
  _src_root=""
  for _candidate in "$_script_dir/../../.." "$_script_dir/../.." "$_script_dir/.." "."; do
    if [ -f "$_candidate/shell/release/install-variants" ]; then
      _src_root=$(cd "$_candidate" && pwd -P)
      break
    fi
  done
  [ -n "$_src_root" ] || die "cannot find source tree"

  _variants_file="$_src_root/shell/release/install-variants"
  [ -f "$_variants_file" ] || die "install-variants file not found"
  _variant_matches=$(awk -F'\t' -v v="$_variant" '$1 == v { count++ } END { print count + 0 }' "$_variants_file")
  [ "$_variant_matches" -eq 1 ] || die "unknown or ambiguous variant: $_variant"

  _exclude_list=$(awk -F'	' -v v="$_variant" '$1 == v { print $3 }' "$_variants_file")
  _desc=$(awk -F'	' -v v="$_variant" '$1 == v { print $2 }' "$_variants_file")

  printf 'Variant: %s
' "$_variant"
  printf 'Description: %s
' "${_desc:-unknown}"
  printf 'Excluded modules: %s
' "${_exclude_list:-none (default)}"
  printf '
Per-shell impact:
'

  for _shell in bash zsh ksh fish; do
    _roots=$(release_bundle_roots "$_src_root" "$_shell") || continue

    _count=0
    _excluded=0
    for _seed in $_roots; do
      _is_ex=0
      _seed_name=${_seed%@*}
      _seed_source="shell/module.d"
      case "$_seed" in *@*) _seed_source=${_seed#*@} ;; esac
      for _ex in $_exclude_list; do
        case "$_ex" in
          *@*) [ "$_seed" = "$_ex" ] && _is_ex=1 ;;
          *) [ "$_seed_name" = "$_ex" ] && [ "$_seed_source" = "shell/module.d" ] && _is_ex=1 ;;
        esac
        [ "$_is_ex" -eq 1 ] && break
      done
      if [ "$_is_ex" -eq 1 ]; then
        _excluded=$((_excluded+1))
      else
        _count=$((_count+1))
      fi
    done
    printf '  %s: %d roots (%d excluded)
' "$_shell" "$_count" "$_excluded"
  done
}

cmd_explain_bundles() {
  _eb_bundle=""
  _eb_bundle_requested=0
  for _eb_arg do
    case "$_eb_arg" in
      --bundle=*) _eb_bundle_requested=1; _eb_bundle=${_eb_arg#--bundle=} ;;
      --help|-h) usage_explain_bundles; return 0 ;;
      *) die "unknown explain-bundles option: $_eb_arg" ;;
    esac
  done
  [ "$_eb_bundle_requested" -eq 0 ] || [ -n "$_eb_bundle" ] || die "bundle name must not be empty"

  _eb_root=$(resolve_project_root) || die "cannot find source tree (need shell/release/bundle-roots)"
  _eb_roots_file="$_eb_root/shell/release/bundle-roots"

  [ -f "$_eb_roots_file" ] || die "cannot find shell/release/bundle-roots in the project"

  # The registry is the module source of truth. Generate it into a scratch
  # file when the project has not written one yet, so explain-bundles never
  # mutates the project.
  _eb_registry="$_eb_root/shell/release/module-registry.tsv"
  _eb_registry_tmp=""
  if [ ! -f "$_eb_registry" ]; then
    _eb_registry_tmp=$(trusted_mktemp file "${TMPDIR:-/tmp}/valise-explain-registry.XXXXXX") ||
      die "cannot create registry scratch file"
    registry_generate "$_eb_root" "$_eb_registry_tmp"
    _eb_registry="$_eb_registry_tmp"
  fi

  # The default variant's exclusion list applies to the closure exactly as
  # it does at compile time.
  _eb_awk=$(trusted_utility_path awk) || die "no trusted awk utility available"
  _eb_excludes=""
  _eb_variants="$_eb_root/shell/release/install-variants"
  if [ -f "$_eb_variants" ]; then
    _eb_excludes=$("$_eb_awk" -F '\t' '$1 == "default" { print $3; exit }' "$_eb_variants")
  fi

  "$_eb_awk" -F '\t' \
    -v roots_file="$_eb_roots_file" \
    -v bundle="$_eb_bundle" \
    -v bundle_requested="$_eb_bundle_requested" \
    -v excludes="$_eb_excludes" '
    function shell_matches(shells, wanted,   count, i, values) {
      if (shells == "") return 0
      count = split(shells, values, " ")
      for (i = 1; i <= count; i++) {
        if (values[i] == wanted) return 1
        # shells=posix means every POSIX shell class, not Fish.
        if (wanted != "fish" && values[i] == "posix") return 1
      }
      return 0
    }
    function is_excluded(id,   i, ex) {
      for (i = 1; i <= excl_count; i++) {
        ex = excl_list[i]
        if (index(ex, "@") > 0) {
          if (ex == id) return 1
        } else if (ex == mod_id[id] && mod_src[id] == "shell/module.d") {
          return 1
        }
      }
      return 0
    }
    function resolve_dep(dep, src,   candidate, count, found, key) {
      candidate = dep "@" src
      if (candidate in mod_id && shell_matches(mod_shells[candidate], eff_shell) && !is_excluded(candidate)) return candidate
      count = 0; found = ""
      for (key in mod_id) {
        if (mod_id[key] == dep && shell_matches(mod_shells[key], eff_shell) && !is_excluded(key)) {
          count++; found = key
        }
      }
      if (count == 1) return found
      return ""
    }
    function add_module(id,   deps, count, i, dep, resolved) {
      if (id in closure_seen) return
      if (!(id in mod_id)) {
        if (!(id in missing)) { missing[id] = 1; missing_count++ }
        return
      }
      if (!shell_matches(mod_shells[id], eff_shell)) {
        if (!(id in skipped)) { skipped[id] = 1; skipped_count++ }
        return
      }
      if (is_excluded(id)) return
      closure_seen[id] = 1
      closure_list[++closure_count] = id
      count = split(mod_req[id], deps, " ")
      for (i = 1; i <= count; i++) {
        dep = deps[i]
        if (dep == "") continue
        resolved = resolve_dep(dep, mod_src[id])
        if (resolved == "") {
          if (!(dep in unresolved)) { unresolved[dep] = 1; unresolved_count++ }
          continue
        }
        add_module(resolved)
      }
      # An optional dependency joins the closure only when it is present for
      # this shell and not excluded; an absent optional is silent.
      count = split(mod_opt[id], deps, " ")
      for (i = 1; i <= count; i++) {
        dep = deps[i]
        if (dep == "") continue
        resolved = resolve_dep(dep, mod_src[id])
        if (resolved == "") continue
        add_module(resolved)
      }
    }
    function sort_closure(   i, j, key) {
      for (i = 2; i <= closure_count; i++) {
        key = closure_list[i]
        j = i - 1
        while (j >= 1 && closure_list[j] > key) {
          closure_list[j + 1] = closure_list[j]
          j--
        }
        closure_list[j + 1] = key
      }
    }
    function seed_dropped(seed,   seed_name, seed_src, at, e) {
      seed_name = seed; seed_src = "shell/module.d"
      at = index(seed, "@")
      if (at > 0) { seed_name = substr(seed, 1, at - 1); seed_src = substr(seed, at + 1) }
      for (e = 1; e <= excl_count; e++) {
        if (index(excl_list[e], "@") > 0) {
          if (excl_list[e] == seed) return 1
        } else {
          if (excl_list[e] == seed_name && seed_src == "shell/module.d") return 1
        }
      }
      return 0
    }
    FILENAME == roots_file {
      if ($0 ~ /^[[:space:]]*#/ || NF < 2) next
      # The first row names the columns; it is not a bundle definition.
      if (!roots_header_seen) {
        roots_header_seen = 1
        if ($1 == "bundle" && $2 == "shell") next
      }
      b = $1; sh = $2; rts = $3
      if (b == "" || sh == "") next
      if (!(b in bundle_seen)) { bundle_seen[b] = 1; bundle_order[++bundle_count] = b }
      key = b SUBSEP sh
      if (key in bundle_roots) bundle_roots[key] = bundle_roots[key] " " rts
      else bundle_roots[key] = rts
      if (!(sh in shell_seen)) { shell_seen[sh] = 1; shell_order[++shell_count] = sh }
      next
    }
    FNR == 1 { next }
    {
      if (NF < 11) next
      name = $1; src = $11
      if (name == "" || src == "") next
      id = name "@" src
      mod_id[id] = name
      mod_src[id] = src
      mod_req[id] = $4
      mod_opt[id] = $5
      mod_shells[id] = $6
      mod_ver[id] = $2
      mod_exports[id] = $8
      mod_load[id] = $9
    }
    END {
      if (bundle_requested == 1 && !(bundle in bundle_seen)) {
        printf "valise: error: unknown bundle: %s\n", bundle > "/dev/stderr"
        exit 1
      }
      excl_count = 0
      if (excludes != "") {
        n = split(excludes, ex_arr, " ")
        for (i = 1; i <= n; i++) if (ex_arr[i] != "") excl_list[++excl_count] = ex_arr[i]
      }
      printf "Installed bundle resolution:\n\n"
      for (bi = 1; bi <= bundle_count; bi++) {
        b = bundle_order[bi]
        if (bundle_requested == 1 && b != bundle) continue
        printf "Bundle: %s\n", b
        for (si = 1; si <= shell_count; si++) {
          sh = shell_order[si]
          key = b SUBSEP sh
          if (!(key in bundle_roots)) continue
          eff_shell = sh
          closure_count = 0; missing_count = 0; skipped_count = 0; unresolved_count = 0
          delete closure_seen
          delete missing
          delete unresolved
          delete skipped
          root_count = 0
          n = split(bundle_roots[key], seeds, " ")
          for (i = 1; i <= n; i++) {
            seed = seeds[i]
            if (seed == "") continue
            if (seed_dropped(seed)) continue
            root_count++
            seed_name = seed; seed_src = "shell/module.d"
            at = index(seed, "@")
            if (at > 0) { seed_name = substr(seed, 1, at - 1); seed_src = substr(seed, at + 1) }
            add_module(seed_name "@" seed_src)
          }
          sort_closure()
          printf "  %s: %d root(s), %d module(s)\n", sh, root_count, closure_count
          for (i = 1; i <= closure_count; i++) {
            id = closure_list[i]
            printf "    module %s (%s)\n", mod_id[id], mod_src[id]
          }
          for (id in missing) printf "    MISSING module %s\n", id
          for (dep in unresolved) printf "    UNRESOLVED dependency %s\n", dep
        }
        printf "\n"
      }
    }
  ' "$_eb_roots_file" "$_eb_registry"
  _eb_rc=$?
  if [ -n "$_eb_registry_tmp" ]; then
    _eb_rm=$(trusted_utility_path rm) || die "no trusted rm utility available"
    "$_eb_rm" -f "$_eb_registry_tmp" || die "cannot remove registry scratch file"
  fi
  [ "$_eb_rc" -eq 0 ] || die "explain-bundles failed"
}

cmd_layer_lint() {
  _ll_name="${1:-}"
  # A failing shift is a special-builtin error: POSIX requires the shell to
  # abort, and the || guard does not prevent that. Shift only when there is
  # an argument to shift, so a bare "valise layer-lint" reaches the usage
  # check on every shell instead of dying with a shell-specific status.
  if [ "$#" -gt 0 ]; then shift; fi
  case "$_ll_name" in
    --help|-h) usage_layer_lint; return 0 ;;
  esac
  for _ll_arg do
    case "$_ll_arg" in
      --help|-h) usage_layer_lint; return 0 ;;
      *) die "unknown layer-lint option: $_ll_arg" ;;
    esac
  done
  [ -n "$_ll_name" ] || die "usage: valise layer-lint <layer-name>"

  # The layer lives in the consuming project, but the layer may also be
  # given as a path. The engine checkout supplies the module names a layer
  # may depend on.
  _ll_root=$(resolve_project_root 2>/dev/null || :)
  _ll_engine=$(resolve_engine_root 2>/dev/null || :)
  [ -n "$_ll_root" ] || [ -n "$_ll_engine" ] ||
    die "cannot find source tree (need shell/layers/ or module.d/)"
  _ll_layers="$_ll_root/shell/layers"
  [ -n "$_ll_layers" ] || _ll_layers=""

  # A layer is addressed by its provider directory name, or by a path to a
  # layer tree that contains module.d/.
  _ll_layer=""
  if [ -n "$_ll_layers" ] && [ -d "$_ll_layers/$_ll_name" ]; then
    _ll_layer="$_ll_layers/$_ll_name"
  elif [ -d "$_ll_name/module.d" ]; then
    _ll_layer=$(cd "$_ll_name" && pwd -P) || die "cannot resolve layer path: $_ll_name"
  elif [ -n "$_ll_engine" ] && [ -d "$_ll_engine/shell/layers/$_ll_name" ]; then
    _ll_layer="$_ll_engine/shell/layers/$_ll_name"
  else
    die "layer not found: $_ll_name (expected $_ll_layers/$_ll_name or a path containing module.d/)"
  fi

  [ -d "$_ll_layer/module.d" ] || die "layer has no module.d directory: $_ll_layer"

  _ll_script_dir=$(valise_script_dir)
  _ll_metadata="$_ll_script_dir/../lib/metadata.sh"
  [ -r "$_ll_metadata" ] || die "metadata library not found: $_ll_metadata"

  _ll_status=0
  _ll_fail() {
    printf '  FAIL: %s\n' "$*" >&2
    _ll_status=1
  }

  # The engine's own modules and the project's primary-root modules are the
  # ones a layer may depend on. A layer module may require another module
  # in its own layer, or one of these; anything else is a dependency the
  # layer does not own.
  # The name lists are space-delimited with a LEADING and a TRAILING space,
  # so that " $name " matches every entry including the first and the last.
  _ll_engine_names=" "
  for _ll_engine_root in "$_ll_engine" "$_ll_root"; do
    [ -n "$_ll_engine_root" ] || continue
    for _ll_engine_name in $(engine_module_names "$_ll_engine_root"); do
      case "$_ll_engine_names" in
        *" $_ll_engine_name "*) continue ;;
      esac
      _ll_engine_names="$_ll_engine_names$_ll_engine_name "
    done
  done

  _ll_meta_dir="$_ll_layer/module.d"
  _ll_count=0
  _ll_layer_names=" "
  for _ll_meta in "$_ll_meta_dir"/*.meta; do
    [ -f "$_ll_meta" ] || continue
    _ll_count=$((_ll_count + 1))
    _ll_file=${_ll_meta##*/}
    _ll_mod_name=${_ll_file%.meta}

    # Structure: the metadata file must not be a symlink and must carry a
    # safe mode.
    if [ -L "$_ll_meta" ]; then
      _ll_fail "$_ll_file: metadata file must not be a symlink"
      continue
    fi
    _ll_mode=$(file_mode "$_ll_meta") || _ll_mode=""
    case "$_ll_mode" in
      0644 | 0444) ;;
      *) _ll_fail "$_ll_file: metadata mode must be 0644 or 0444, got ${_ll_mode:-unknown}" ;;
    esac

    # Namespace: a layer-only module must carry the contrib_ prefix.
    case "$_ll_mod_name" in
      contrib_*) ;;
      *) _ll_fail "$_ll_file: layer module name must use the contrib_ prefix" ;;
    esac

    # Metadata: the record must validate as data.
    _ll_record=$(. "$_ll_metadata"; sp_metadata_read "$_ll_meta") || {
      _ll_fail "$_ll_file: invalid metadata"
      continue
    }
    _ll_m_name=
    _ll_m_version=
    _ll_m_requires=
    _ll_m_optional=
    _ll_m_load=
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
      _ll_fail "$_ll_file: metadata name $_ll_m_name does not match the file name $_ll_mod_name"
    fi
    if [ -z "$_ll_m_version" ]; then
      _ll_fail "$_ll_file: layer modules must declare a version"
    fi

    # Load target: the body must exist, must not be a symlink, and must
    # carry a safe mode.
    if [ -n "$_ll_m_load" ]; then
      _ll_body="$_ll_layer/$_ll_m_load"
      if [ -L "$_ll_body" ]; then
        _ll_fail "$_ll_file: load target must not be a symlink: $_ll_m_load"
      elif [ ! -f "$_ll_body" ]; then
        _ll_fail "$_ll_file: load target does not exist: $_ll_m_load"
      else
        _ll_body_mode=$(file_mode "$_ll_body") || _ll_body_mode=""
        case "$_ll_body_mode" in
          0644 | 0444 | 0755 | 0555) ;;
          *) _ll_fail "$_ll_file: load target mode must be 0644, 0444, 0755 or 0555, got ${_ll_body_mode:-unknown}" ;;
        esac
      fi
    else
      _ll_fail "$_ll_file: layer module must declare a load target"
    fi

    _ll_layer_names="$_ll_layer_names$_ll_mod_name "
  done

  if [ "$_ll_count" -eq 0 ]; then
    _ll_fail "$_ll_layer: layer contains no modules"
  fi

  # Dependencies: every requirement must resolve inside the layer or to an
  # engine module. An optional dependency must resolve the same way.
  for _ll_meta in "$_ll_meta_dir"/*.meta; do
    [ -f "$_ll_meta" ] || continue
    _ll_file=${_ll_meta##*/}
    _ll_record=$(. "$_ll_metadata"; sp_metadata_read "$_ll_meta") || continue
    _ll_m_requires=
    _ll_m_optional=
    while IFS= read -r _ll_line; do
      case "$_ll_line" in
        requires=*) _ll_m_requires=${_ll_line#requires=} ;;
        optional=*) _ll_m_optional=${_ll_line#optional=} ;;
      esac
    done <<EOF
$_ll_record
EOF
    for _ll_kind in requires optional; do
      if [ "$_ll_kind" = requires ]; then
        _ll_deps=$_ll_m_requires
      else
        _ll_deps=$_ll_m_optional
      fi
      [ -n "$_ll_deps" ] || continue
      _ll_ifs_was_set=0
      if [ "${IFS+x}" = x ]; then
        _ll_ifs_was_set=1
        _ll_ifs=${IFS-}
      fi
      IFS=' '
      for _ll_dep in $_ll_deps; do
        [ -n "$_ll_dep" ] || continue
        case "$_ll_layer_names" in
          *" $_ll_dep "*) continue ;;
        esac
        case "$_ll_engine_names" in
          *" $_ll_dep "*) continue ;;
        esac
        _ll_fail "$_ll_file: $_ll_kind dependency $_ll_dep is neither in this layer nor an engine module"
      done
      if [ "$_ll_ifs_was_set" -eq 1 ]; then
        IFS=$_ll_ifs
      else
        unset IFS
      fi
    done
  done

  if [ "$_ll_status" -eq 0 ]; then
    printf 'layer %s: %d module(s) validated\n' "$_ll_name" "$_ll_count"
    return 0
  fi
  die "layer $_ll_name failed validation"
}
