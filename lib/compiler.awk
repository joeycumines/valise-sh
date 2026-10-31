# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise compile: pure POSIX awk static plan compiler.
# Input: single preprocessed stream from sh wrapper.
#   Lines starting with SEED: space-separated seed module names
#   Lines starting with MOD: identity<TAB>requires<TAB>load_path<TAB>platforms<TAB>side_effect<TAB>exports
#   identity is module@meta_source when registry sources are qualified.
#   Lines starting with PRELUDE: sp_cap function names (space-separated)
# Output: complete installed plan on stdout.

BEGIN {
    prefix = "_shell_installed_plan_"
    prelude_dest = "vendor/shell-profile/lib/capabilities.sh"
    seed_count = 0
    mod_count = 0
    prelude_fn_count = 0
    if (plan_name == "") plan_name = target_shell
}

/^SEED:/ {
    line = substr($0, 6)
    n = split(line, arr, " ")
    for (i = 1; i <= n; i++) {
        if (arr[i] != "") {
            seed_count++
            seeds[seed_count] = arr[i]
        }
    }
    next
}

/^MOD:/ {
    line = substr($0, 5)
    n = split(line, fields, "\t")
    if (n >= 6) {
        name = fields[1]
        mod_req[name] = fields[2]
        mod_load[name] = fields[3]
        mod_platforms[name] = fields[4]
        mod_side_effect[name] = fields[5]
        mod_exports[name] = fields[6]
        display_name = name
        at = index(name, "@")
        if (at > 0) display_name = substr(name, 1, at - 1)
        mod_display[name] = display_name
        mod_exists[name] = 1
        mod_count++
        mod_names[mod_count] = name
    }
    next
}

/^EXCLUDED:/ {
    # A module removed by the active build variant. It is not part of the
    # closure, but it is named so a required dependency that points at it can
    # be diagnosed precisely instead of as an unknown module. The record is
    # "<identity>\t<name>"; the bare name is how a dependency refers to it.
    line = substr($0, 10)
    n = split(line, fields, "\t")
    if (n >= 2) {
        excluded_id[fields[1]] = fields[2]
    }
    next
}

/^PRELUDE:/ {
    line = substr($0, 9)
    n = split(line, arr, " ")
    for (i = 1; i <= n; i++) {
        if (arr[i] != "" && !(arr[i] in prelude_seen)) {
            prelude_seen[arr[i]] = 1
            prelude_fn_count++
            prelude_fns[prelude_fn_count] = arr[i]
        }
    }
    next
}

END {
    # Seeds are used in their original order (matching Python compiler).
    # BFS discovery from seed queue (sorted for deterministic traversal)
    q_head = 1
    q_tail = 0
    for (i = 1; i <= seed_count; i++) {
        q_tail++
        queue[q_tail] = seeds[i]
    }
    # Sort queue for deterministic BFS traversal (Python uses sorted(wanted))
    for (i = 2; i <= q_tail; i++) {
        key = queue[i]
        j = i - 1
        while (j >= 1 && queue[j] > key) {
            queue[j + 1] = queue[j]
            j--
        }
        queue[j + 1] = key
    }

    discovered_count = 0
    while (q_head <= q_tail) {
        name = queue[q_head]
        q_head++

        if (name in discovered) continue
        if (!(name in mod_exists)) {
            if (name in excluded_id) {
                # The module was removed by the active build variant, but a
                # surviving module still requires it. Name both modules: the
                # generic "unknown module" diagnostic would point at the
                # dependency and hide the variant that caused it.
                print "ERROR: variant exclusion breaks a required dependency: " mod_display[requiring_of[name]] " requires " excluded_id[name] > "/dev/stderr"
                exit 1
            }
            print "ERROR: unknown module: " name > "/dev/stderr"
            exit 1
        }
        discovered[name] = 1
        discovered_count++
        disc_list[discovered_count] = name

        n_req = split(mod_req[name], reqs, " ")
        for (ri = 1; ri <= n_req; ri++) {
            dep = reqs[ri]
            if (dep == "") continue
            if (!(dep in discovered)) {
                in_q = 0
                for (qi = q_head; qi <= q_tail; qi++) {
                    if (queue[qi] == dep) { in_q = 1; break }
                }
                if (!in_q) {
                    q_tail++
                    queue[q_tail] = dep
                }
            }
            # Remember which module asked for a dependency, so an exclusion
            # that breaks it can name the requiring module.
            if (!(dep in requiring_of)) requiring_of[dep] = name
        }

        # Re-sort remaining queue
        for (i = q_head + 1; i <= q_tail; i++) {
            key = queue[i]
            j = i - 1
            while (j >= q_head && queue[j] > key) {
                queue[j + 1] = queue[j]
                j--
            }
            queue[j + 1] = key
        }
    }

    # Topological sort matching Python compiler exactly:
    # remaining = sorted(modules); repeatedly scan for first whose requires are all loaded
    for (di = 1; di <= discovered_count; di++) {
        remaining[di] = disc_list[di]
    }
    # Sort remaining alphabetically (insertion sort)
    for (i = 2; i <= discovered_count; i++) {
        key = remaining[i]
        j = i - 1
        while (j >= 1 && remaining[j] > key) {
            remaining[j + 1] = remaining[j]
            j--
        }
        remaining[j + 1] = key
    }
    rem_count = discovered_count
    ordered_count = 0

    while (rem_count > 0) {
        progress = 0
        next_rem_count = 0
        for (ri = 1; ri <= rem_count; ri++) {
            name = remaining[ri]
            all_loaded = 1
            n_req = split(mod_req[name], reqs, " ")
            for (rqi = 1; rqi <= n_req; rqi++) {
                dep = reqs[rqi]
                if (dep == "") continue
                if (!(dep in loaded)) {
                    all_loaded = 0
                    break
                }
            }
            if (all_loaded) {
                ordered_count++
                ordered[ordered_count] = name
                loaded[name] = 1
                progress = 1
            } else {
                next_rem_count++
                next_remaining[next_rem_count] = name
            }
        }
        if (!progress) {
            print "ERROR: cycle detected" > "/dev/stderr"
            exit 1
        }
        rem_count = next_rem_count
        for (ri = 1; ri <= rem_count; ri++) {
            remaining[ri] = next_remaining[ri]
        }
    }

    # Validate the ordered closure before rendering. Unsafe side effects are a
    # compile-time error, and a bodyless module must still be a dependency-only
    # meta module.
    for (oi = 1; oi <= ordered_count; oi++) {
        name = ordered[oi]
        side_effect = mod_side_effect[name]
        if (side_effect == "" || side_effect == "generated-file" || side_effect == "update-network" || side_effect == "install-time") {
            print "ERROR: module " mod_display[name] " has unsafe side_effect for compile: " side_effect > "/dev/stderr"
            exit 1
        }
        if (mod_load[name] == "" && mod_req[name] == "") {
            print "ERROR: module " mod_display[name] " has no load path and no dependencies" > "/dev/stderr"
            exit 1
        }
    }

    # Collect the plan's declared exports once for VALISE_RELOAD support.
    reload_export_count = 0
    for (oi = 1; oi <= ordered_count; oi++) {
        name = ordered[oi]
        n_exports = split(mod_exports[name], export_values, " ")
        for (ei = 1; ei <= n_exports; ei++) {
            export_name = export_values[ei]
            if (export_name != "" && !(export_name in reload_export_seen)) {
                reload_export_seen[export_name] = 1
                reload_export_count++
                reload_exports[reload_export_count] = export_name
            }
        }
    }

    # --- Render plan ---
    printf "# shell-profile-installed-modules-v1\n"
    printf "# Generated by valise compile; DO NOT EDIT.\n"
    printf "# plan=%s\n", plan_name
    printf "# roots="
    for (i = 1; i <= seed_count; i++) {
        if (i > 1) printf " "
        printf "%s", mod_display[seeds[i]]
    }
    printf "\n"
    printf "# order="
    for (i = 1; i <= ordered_count; i++) {
        if (i > 1) printf " "
        printf "%s", mod_display[ordered[i]]
    }
    printf "\n\n"

    printf "%sstatus=0\n", prefix
    printf "%sfailed=0\n", prefix
    printf "%sfirst_status=0\n", prefix
    printf "%sunavailable=\n", prefix
    printf "%smode=${VALISE_MODE:-strict}\n", prefix
    printf "case \"$%smode\" in\n", prefix
    printf "strict | permissive) ;;\n"
    printf "*)\n"
    printf "  printf '%%s\\n' \"valise: invalid mode: $%smode\" >&2\n", prefix
    printf "  unset %sstatus %sfailed %sfirst_status %sunavailable %smode\n", prefix, prefix, prefix, prefix, prefix
    printf "  return 1\n"
    printf "  ;;\n"
    printf "esac\n"

    printf "%splatform=$(command uname -s 2>/dev/null || printf unknown)\n", prefix
    printf "case \"$%splatform\" in\n", prefix
    printf "Darwin) %splatform=darwin ;;\n", prefix
    printf "Linux) %splatform=linux ;;\n", prefix
    printf "FreeBSD) %splatform=freebsd ;;\n", prefix
    printf "OpenBSD) %splatform=openbsd ;;\n", prefix
    printf "NetBSD) %splatform=netbsd ;;\n", prefix
    printf "*BSD) %splatform=bsd ;;\n", prefix
    printf "*) %splatform=unknown ;;\n", prefix
    printf "esac\n"

    if (reload_export_count > 0) {
        printf "if [ \"${VALISE_RELOAD:-}\" = 1 ]; then\n"
        printf "  for %sexport in", prefix
        for (i = 1; i <= reload_export_count; i++) {
            printf " %s", reload_exports[i]
        }
        printf "; do\n"
        printf "    unset -f \"$%sexport\" 2>/dev/null || :\n", prefix
        printf "  done\n"
        printf "  unset %sexport\n", prefix
        printf "fi\n"
    }

    if (prelude_fn_count > 0) {
        printf ". \"${VALISE_MODULE_ROOT%%/}/%s\" || %sstatus=$?\n", prelude_dest, prefix
        printf "if [ \"$%sstatus\" -ne 0 ]; then\n", prefix
        printf "  printf 'valise: capability prelude failed with status %%s\\n' \"\$%sstatus\" >&2\n", prefix
        printf "  %sfailed=1\n", prefix
        printf "  %sfirst_status=$%sstatus\n", prefix, prefix
        printf "fi\n"
    }

    printf "if [ \"$%sstatus\" -eq 0 ]; then\n", prefix
    printf "  for %smodule in", prefix
    for (i = 1; i <= ordered_count; i++) {
        printf " %s", ordered[i]
    }
    printf "; do\n"
    printf "    case \"$%smodule\" in\n", prefix

    for (oi = 1; oi <= ordered_count; oi++) {
        name = ordered[oi]
        display = mod_display[name]
        printf "    %s)\n", name
        platform_any = 0
        n_platforms = split(mod_platforms[name], platform_values, " ")
        for (pi = 1; pi <= n_platforms; pi++) {
            if (platform_values[pi] == "any") platform_any = 1
        }
        export_count = split(mod_exports[name], module_exports, " ")
        body_indent = platform_any == 0 ? "        " : "      "

        # A module whose required dependency is unavailable must not run: its
        # body would call functions that were never defined. In strict mode a
        # real failure has already stopped the plan, so the cause here is a
        # platform skip, and the loader fails that case too. In permissive mode
        # the module is reported and the plan continues.
        n_req = split(mod_req[name], reqs, " ")
        if (n_req > 0) {
            printf "      %sblocked_by=\n", prefix
            for (rqi = 1; rqi <= n_req; rqi++) {
                printf "      case \" $%sunavailable \" in *\" %s \"*) %sblocked_by=%s ;; esac\n", prefix, reqs[rqi], prefix, mod_display[reqs[rqi]]
            }
            printf "      if [ -n \"$%sblocked_by\" ]; then\n", prefix
            printf "        printf 'valise: module %%s skipped: required dependency unavailable: %%s\\n' '%s' \"$%sblocked_by\" >&2\n", display, prefix
            printf "        %sunavailable=\"$%sunavailable %s\"\n", prefix, prefix, name
            printf "        if [ \"$%smode\" = strict ]; then\n", prefix
            printf "          %sstatus=1\n", prefix
            printf "        fi\n"
            printf "      else\n"
            # A meta module on any platform has no statement for this branch.
            if (mod_load[name] == "" && platform_any == 1) printf "        :\n"
        }

        if (platform_any == 0) {
            printf "      %splatform_match=0\n", prefix
            for (pi = 1; pi <= n_platforms; pi++) {
                platform = platform_values[pi]
                if (platform == "bsd") {
                    printf "      case \"$%splatform\" in bsd | freebsd | openbsd | netbsd) %splatform_match=1 ;; esac\n", prefix, prefix
                } else if (platform != "any") {
                    printf "      [ \"$%splatform\" = %s ] && %splatform_match=1\n", prefix, platform, prefix
                }
            }
            printf "      if [ \"$%splatform_match\" -ne 1 ]; then\n", prefix
            printf "        %sunavailable=\"$%sunavailable %s\"\n", prefix, prefix, name
            if (mod_load[name] != "") printf "      else\n"
        }
        if (mod_load[name] != "") {
            if (export_count == 0) {
                printf "%s. \"${VALISE_MODULE_ROOT%%/}/%s\"\n", body_indent, mod_load[name]
                printf "%s%sstatus=$?\n", body_indent, prefix
                printf "%sif [ \"$%sstatus\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s  printf 'valise: module %%s failed with status %%s\\n' '%s' \"\$%sstatus\" >&2\n", body_indent, display, prefix
                printf "%sfi\n", body_indent
            } else {
                printf "%s%swrapper_exports=\n", body_indent, prefix
                printf "%sfor %sexport in", body_indent, prefix
                for (ei = 1; ei <= export_count; ei++) {
                    printf " %s", module_exports[ei]
                }
                printf "; do\n"
                printf "%s  %sconflict=0\n", body_indent, prefix
                printf "%s  if command alias \"$%sexport\" >/dev/null 2>&1; then\n", body_indent, prefix
                printf "%s    %sconflict=1\n", body_indent, prefix
                printf "%s  fi\n", body_indent
                printf "%s  if %slookup=$(command -v \"$%sexport\" 2>/dev/null); then\n", body_indent, prefix, prefix
                printf "%s    case \"$%slookup\" in\n", body_indent, prefix
                printf "%s    alias\\ *) %sconflict=1 ;;\n", body_indent, prefix
                printf "%s    */*) %swrapper_exports=\"${%swrapper_exports:+$%swrapper_exports }$%sexport\" ;;\n", body_indent, prefix, prefix, prefix, prefix, prefix
                printf "%s    *) %sconflict=1 ;;\n", body_indent, prefix
                printf "%s    esac\n", body_indent
                printf "%s  else\n", body_indent
                printf "%s    %slookup=\n", body_indent, prefix
                printf "%s  fi\n", body_indent
                printf "%s  if [ \"$%sconflict\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s    printf 'valise: %%s: declared export already exists before load: %%s\\n' '%s' \"\$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s    %sstatus=1\n", body_indent, prefix
                printf "%s  fi\n", body_indent
                printf "%sdone\n", body_indent
                printf "%sif [ \"$%sstatus\" -eq 0 ]; then\n", body_indent, prefix
                printf "%s  . \"${VALISE_MODULE_ROOT%%/}/%s\"\n", body_indent, mod_load[name]
                printf "%s  %sstatus=$?\n", body_indent, prefix
                printf "%sfi\n", body_indent
                printf "%sif [ \"$%sstatus\" -eq 0 ]; then\n", body_indent, prefix
                printf "%s  for %sexport in", body_indent, prefix
                for (ei = 1; ei <= export_count; ei++) {
                    printf " %s", module_exports[ei]
                }
                printf "; do\n"
                printf "%s    if ! %slookup=$(command -v \"$%sexport\" 2>/dev/null); then\n", body_indent, prefix, prefix
                printf "%s      printf 'valise: %%s: declared export missing: %%s\\n' '%s' \"\$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s      %sstatus=1\n", body_indent, prefix
                printf "%s    else\n", body_indent
                printf "%s      case \" $%swrapper_exports \" in\n", body_indent, prefix
                printf "%s      *\" $%sexport \"*)\n", body_indent, prefix
                printf "%s        case \"$%slookup\" in\n", body_indent, prefix
                printf "%s        */*)\n", body_indent
                printf "%s          printf 'valise: %%s: declared export was not provided by module: %%s\\n' '%s' \"\$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s          %sstatus=1\n", body_indent, prefix
                printf "%s          ;;\n", body_indent
                printf "%s        esac\n", body_indent
                printf "%s        ;;\n", body_indent
                printf "%s      esac\n", body_indent
                printf "%s    fi\n", body_indent
                printf "%s  done\n", body_indent
                printf "%sfi\n", body_indent
                printf "%sif [ \"$%sstatus\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s  printf 'valise: module %%s failed with status %%s\\n' '%s' \"\$%sstatus\" >&2\n", body_indent, display, prefix
                printf "%sfi\n", body_indent
            }
        }
        if (platform_any == 0) {
            printf "      fi\n"
        }
        if (n_req > 0) {
            printf "      fi\n"
        }
        printf "      ;;\n"
    }

    printf "    esac\n"
    printf "    if [ \"$%sstatus\" -ne 0 ]; then\n", prefix
    printf "      %sunavailable=\"$%sunavailable $%smodule\"\n", prefix, prefix, prefix
    printf "      if [ \"$%sfailed\" -eq 0 ]; then\n", prefix
    printf "        %sfailed=1\n", prefix
    printf "        %sfirst_status=$%sstatus\n", prefix, prefix
    printf "      fi\n"
    printf "      if [ \"$%smode\" = strict ]; then\n", prefix
    printf "        break\n"
    printf "      fi\n"
    printf "      %sstatus=0\n", prefix
    printf "    fi\n"
    printf "  done\n"
    printf "fi\n"

    printf "if [ \"$%sfailed\" -ne 0 ]; then\n", prefix
    printf "  %sreturn=$%sfirst_status\n", prefix, prefix
    printf "else\n"
    printf "  %sreturn=0\n", prefix
    printf "fi\n"
    printf "unset %sstatus %sfailed %sfirst_status %sunavailable %smode %splatform\n", prefix, prefix, prefix, prefix, prefix, prefix
    printf "unset %smodule %sblocked_by %splatform_match %sexport %slookup %sconflict %swrapper_exports\n", prefix, prefix, prefix, prefix, prefix, prefix, prefix
    printf "eval \"unset %sreturn; return $%sreturn\"\n", prefix, prefix
}
