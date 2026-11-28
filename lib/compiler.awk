# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise compile: pure POSIX awk static plan compiler.
# Input: single preprocessed stream from sh wrapper.
#   Lines starting with SEED: space-separated seed module names
#   Lines starting with MOD: identity<TAB>requires<TAB>load_path<TAB>platforms<TAB>side_effect<TAB>exports<TAB>optional<TAB>phase
#   identity is module@meta_source when registry sources are qualified.
#   Lines starting with PRELUDE: sp_cap function names (space-separated)
# Output: complete installed plan on stdout. With -v mode=closure the
# compiler validates and orders the closure, then prints one module identity
# per line in load order instead of rendering a plan.
# With -v phase=interactive the rendered plan contains only the interactive
# modules of the same closure; the default phase=env renders the env plan
# (plans/<shell>.sh). With -v phase=all the filter is disabled and the whole
# closure renders - that is what a command plan needs, since a module's own
# body has to be present for its published command to run whatever phase it
# declares. The closure is computed once from the full module set, so every
# plan shares dependency order and validation.

# Render an exact membership test for a space-delimited runtime ledger. The
# arguments list and needle are already quoted shell expressions. Parameter
# stripping avoids native zsh's different word-splitting rules; [ = ] avoids
# Bash nocasematch changing identities. Keep this in the generator so plans
# need no persistent helper function in the caller's shell.
function emit_token_lookup(indent, list, needle, found) {
    printf "%s%stoken_rest=%s\n", indent, prefix, list
    printf "%s%s=0\n", indent, found
    printf "%swhile [ -n \"$%stoken_rest\" ]; do\n", indent, prefix
    printf "%s  case $%stoken_rest in\n", indent, prefix
    printf "%s  *' '*)\n", indent
    printf "%s    %stoken=${%stoken_rest%%%% *}\n", indent, prefix, prefix
    printf "%s    %stoken_rest=${%stoken_rest#* }\n", indent, prefix, prefix
    printf "%s    ;;\n", indent
    printf "%s  *) %stoken=$%stoken_rest; %stoken_rest= ;;\n", indent, prefix, prefix, prefix
    printf "%s  esac\n", indent
    printf "%s  if [ \"$%stoken\" = %s ]; then %s=1; break; fi\n", indent, prefix, needle, found
    printf "%sdone\n", indent
    printf "%sunset %stoken_rest %stoken\n", indent, prefix, prefix
}

BEGIN {
    prefix = "_valise_plan_"
    prelude_dest = "runtime/capabilities.sh"
    seed_count = 0
    mod_count = 0
    prelude_fn_count = 0
    if (plan_name == "") plan_name = target_shell
    if (phase == "") phase = "env"
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
    if (n >= 7) {
        name = fields[1]
        mod_req[name] = fields[2]
        mod_load[name] = fields[3]
        mod_platforms[name] = fields[4]
        mod_side_effect[name] = fields[5]
        mod_exports[name] = fields[6]
        mod_opt[name] = fields[7]
        mod_phase[name] = (n >= 8 && fields[8] != "") ? fields[8] : "env"
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

        # The preprocessor keeps only optional dependencies that exist for this
        # shell and variant, so each of these is a module the plan must attempt.
        n_opt = split(mod_opt[name], opts, " ")
        for (ri = 1; ri <= n_opt; ri++) {
            dep = opts[ri]
            if (dep in discovered) continue
            in_q = 0
            for (qi = q_head; qi <= q_tail; qi++) {
                if (queue[qi] == dep) { in_q = 1; break }
            }
            if (!in_q) {
                q_tail++
                queue[q_tail] = dep
            }
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

    # The required closure is the roots and everything they require. A module
    # reached only through an optional edge may be unavailable without failing
    # the plan. Compute it before ordering so a stall can distinguish a cycle
    # inside the required closure from an optional-only cycle.
    for (i = 1; i <= seed_count; i++) {
        required_stack[++required_top] = seeds[i]
    }
    while (required_top > 0) {
        name = required_stack[required_top--]
        if (name in required) continue
        required[name] = 1
        n_req = split(mod_req[name], reqs, " ")
        for (rqi = 1; rqi <= n_req; rqi++) {
            required_stack[++required_top] = reqs[rqi]
        }
    }

    # Order by required and optional edges. When that stalls, retry on required
    # edges alone, as the loader does, so an optional edge can never deadlock the
    # graph. Only a stall on required edges is a cycle.
    relaxed = 0
    while (rem_count > 0) {
        progress = 0
        next_rem_count = 0
        for (ri = 1; ri <= rem_count; ri++) {
            name = remaining[ri]
            all_loaded = 1
            n_req = split(mod_req[name], reqs, " ")
            for (rqi = 1; rqi <= n_req; rqi++) {
                if (!(reqs[rqi] in loaded)) {
                    all_loaded = 0
                    break
                }
            }
            if (all_loaded && !relaxed) {
                n_opt = split(mod_opt[name], opts, " ")
                for (rqi = 1; rqi <= n_opt; rqi++) {
                    if (!(opts[rqi] in loaded)) {
                        all_loaded = 0
                        break
                    }
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
            if (!relaxed) {
                relaxed = 1
                continue
            }
            # Every remaining module is in a cycle. The loader quarantines a
            # cycle that lies wholly outside the required closure and still
            # loads the rest, so only a cycle containing a required module is
            # a compile error.
            stalled_required = 0
            for (ri = 1; ri <= rem_count; ri++) {
                if (remaining[ri] in required) {
                    stalled_required = 1
                    break
                }
            }
            if (stalled_required) {
                print "ERROR: cycle detected" > "/dev/stderr"
                exit 1
            }
            for (ri = 1; ri <= rem_count; ri++) {
                print "warning: optional dependency cycle ignored: " remaining[ri] > "/dev/stderr"
            }
            rem_count = 0
            break
        }
        relaxed = 0
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
        if (mod_load[name] == "" && mod_exports[name] != "") {
            print "ERROR: meta module " mod_display[name] " declares exports without a body" > "/dev/stderr"
            exit 1
        }
        # Defence in depth: metadata validation rejects an unknown phase before
        # a registry exists, so this only fires for a stream that bypassed it.
        # Without it a bogus phase would silently drop the module from every
        # plan.
        if (mod_phase[name] != "env" && mod_phase[name] != "interactive") {
            print "ERROR: module " mod_display[name] " has invalid phase: " mod_phase[name] > "/dev/stderr"
            exit 1
        }
    }

    # A required dependency in the other phase is only broken in ONE direction.
    # An interactive module may require an env module: the env plan loads first
    # at every entry point, so the dependency is always present. The reverse is
    # a contradiction - the env plan never contains an interactive dependency,
    # so the env module would load with it permanently absent (before it in an
    # interactive shell, never in a non-interactive one). An OPTIONAL
    # cross-phase edge is fine in either direction: the dependency simply
    # belongs to the other plan.
    for (oi = 1; oi <= ordered_count; oi++) {
        name = ordered[oi]
        if (mod_phase[name] != "env") continue
        n_req = split(mod_req[name], reqs, " ")
        for (rqi = 1; rqi <= n_req; rqi++) {
            dep = reqs[rqi]
            if (dep == "") continue
            if (mod_phase[dep] != "env") {
                print "ERROR: env module " mod_display[name] " requires " mod_phase[dep] " module " mod_display[dep] > "/dev/stderr"
                exit 1
            }
        }
    }

    # The export-ownership ledger names a provider by its display name, so two
    # different modules that share one display name cannot share a closure: the
    # ledger could not tell them apart on reload.
    for (oi = 1; oi <= ordered_count; oi++) {
        closure_display = mod_display[ordered[oi]]
        if (closure_display in closure_display_seen) {
            print "ERROR: two modules are named " closure_display " in one closure; qualified providers must not share a display name" > "/dev/stderr"
            exit 1
        }
        closure_display_seen[closure_display] = 1
    }

    # Partition the closure by phase. Every plan shares this dependency order;
    # a module renders only into the plan of its own phase (phase=all disables
    # the filter). The interactive plan stays empty when no module opts in, and
    # the caller skips writing it.
    plan_count = 0
    for (oi = 1; oi <= ordered_count; oi++) {
        name = ordered[oi]
        if (phase == "all" || mod_phase[name] == phase) {
            plan_count++
            plan_ordered[plan_count] = name
        }
    }

    # Collect the plan's declared exports once for VALISE_RELOAD support.
    reload_export_count = 0
    for (oi = 1; oi <= plan_count; oi++) {
        name = plan_ordered[oi]
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

    if (mode == "closure") {
        for (oi = 1; oi <= ordered_count; oi++) print ordered[oi]
        exit 0
    }

    # --- Render plan ---
    printf "# valise-plan-v2\n"
    printf "# Generated by valise compile; DO NOT EDIT.\n"
    printf "# plan=%s phase=%s\n", plan_name, phase
    printf "# roots="
    for (i = 1; i <= seed_count; i++) {
        if (i > 1) printf " "
        printf "%s", mod_display[seeds[i]]
    }
    printf "\n"
    printf "# order="
    for (i = 1; i <= plan_count; i++) {
        if (i > 1) printf " "
        printf "%s", mod_display[plan_ordered[i]]
    }
    printf "\n\n"

    printf "%sstatus=0\n", prefix
    printf "%sfailed=0\n", prefix
    printf "%sfirst_status=0\n", prefix
    # A module this process already found unavailable in the OTHER phase is
    # carried in here, so a required cross-phase dependency stays enforceable
    # after the closure was partitioned into two plans. The managed block seeds
    # this empty at each evaluation; the plan writes its own result back.
    printf "%sunavailable=\"${%scarried:-}\"\n", prefix, prefix
    printf "%smode=${VALISE_MODE:-strict}\n", prefix
    printf "if [ \"$%smode\" != strict ] && [ \"$%smode\" != permissive ]; then\n", prefix, prefix
    printf "  printf '%%s\\n' \"valise: invalid mode: $%smode\" >&2\n", prefix
    printf "  unset %sstatus %sfailed %sfirst_status %sunavailable %smode\n", prefix, prefix, prefix, prefix, prefix
    printf "  return 1\n"
    printf "fi\n"

    printf "%splatform=$(command uname -s 2>/dev/null || printf unknown)\n", prefix
    printf "if [ \"$%splatform\" = Darwin ]; then %splatform=darwin\n", prefix, prefix
    printf "elif [ \"$%splatform\" = Linux ]; then %splatform=linux\n", prefix, prefix
    printf "elif [ \"$%splatform\" = FreeBSD ]; then %splatform=freebsd\n", prefix, prefix
    printf "elif [ \"$%splatform\" = OpenBSD ]; then %splatform=openbsd\n", prefix, prefix
    printf "elif [ \"$%splatform\" = NetBSD ]; then %splatform=netbsd\n", prefix, prefix
    printf "elif [ \"${%splatform#\"${%splatform%%???}\"}\" = BSD ]; then %splatform=bsd\n", prefix, prefix, prefix
    printf "else %splatform=unknown; fi\n", prefix

    # The reload prelude clears ONLY exports valise itself installed in this
    # process. _valise_plan_owned is written below as each module loads, so an
    # automatic retry over our own previous definitions is quiet, while a
    # CALLER function that collided with a module export is reported again on
    # every pass instead of being silently replaced. An ATTEMPTED load does not
    # establish ownership, which is what an unconditional unset assumed.
    if (reload_export_count > 0) {
        printf "if [ \"${VALISE_RELOAD:-}\" = 1 ]; then\n"
        for (oi = 1; oi <= plan_count; oi++) {
            name = plan_ordered[oi]
            n_pe = split(mod_exports[name], pe_values, " ")
            for (pei = 1; pei <= n_pe; pei++) {
                if (pe_values[pei] == "") continue
                # The token leaves the ledger with the function. Ownership is
                # re-established below only when the module loads successfully,
                # so a module that FAILS on this reload cannot leave a token
                # claiming a function valise no longer provides - which would
                # make the next reload silently unset a caller's replacement
                # instead of reporting the collision.
                #
                # Walk the space-delimited ledger one token at a time using
                # parameter stripping and `[ = ]` comparison:
                #   * avoids unquoted `for tok in $ledger` (zsh does not
                #     word-split by default)
                #   * avoids `case` pattern matching over provider/export names
                #     (Bash `shopt -s nocasematch` makes `case` case-insensitive,
                #     conflating distinct providers like caseMod vs casemod).
                printf "  _valise_owned_rem=${_valise_plan_owned:-}\n"
                printf "  _valise_owned_new=\n"
                printf "  _valise_owned_hit=0\n"
                printf "  while [ -n \"$_valise_owned_rem\" ]; do\n"
                printf "    case $_valise_owned_rem in\n"
                printf "    *' '*)\n"
                printf "      _valise_owned_tok=${_valise_owned_rem%%%% *}\n"
                printf "      _valise_owned_rem=${_valise_owned_rem#* }\n"
                printf "      ;;\n"
                printf "    *)\n"
                printf "      _valise_owned_tok=$_valise_owned_rem\n"
                printf "      _valise_owned_rem=\n"
                printf "      ;;\n"
                printf "    esac\n"
                printf "    if [ \"$_valise_owned_tok\" = '%s:%s' ]; then\n", mod_display[name], pe_values[pei]
                printf "      _valise_owned_hit=1\n"
                printf "    elif [ -n \"$_valise_owned_tok\" ]; then\n"
                printf "      _valise_owned_new=\"${_valise_owned_new:+$_valise_owned_new }$_valise_owned_tok\"\n"
                printf "    fi\n"
                printf "  done\n"
                printf "  if [ \"$_valise_owned_hit\" -eq 1 ]; then\n"
                printf "    unset -f %s 2>/dev/null || :\n", pe_values[pei]
                printf "    _valise_plan_owned=$_valise_owned_new\n"
                printf "  fi\n"
                printf "  unset _valise_owned_rem _valise_owned_new _valise_owned_tok _valise_owned_hit\n"
            }
        }
        printf "fi\n"
    }

    if (prelude_fn_count > 0) {
        printf ". \"${VALISE_MODULE_ROOT%%/}/%s\" || %sstatus=$?\n", prelude_dest, prefix
        printf "if [ \"$%sstatus\" -ne 0 ]; then\n", prefix
        printf "  printf 'valise: capability prelude failed with status %%s\\n' \"$%sstatus\" >&2\n", prefix
        printf "  %sfailed=1\n", prefix
        printf "  %sfirst_status=$%sstatus\n", prefix, prefix
        printf "fi\n"
    }

    printf "if [ \"$%sstatus\" -eq 0 ]; then\n", prefix
    # Numeric dispatch labels cannot be conflated by nocasematch. Preserve the
    # real identity in module for availability tracking and diagnostics.
    printf "  for %smodule_index in", prefix
    for (i = 1; i <= plan_count; i++) {
        printf " %d", i
    }
    printf "; do\n"
    printf "    %srequired=1\n", prefix
    printf "    case \"$%smodule_index\" in\n", prefix

    for (oi = 1; oi <= plan_count; oi++) {
        name = plan_ordered[oi]
        display = mod_display[name]
        printf "    %d)\n", oi
        printf "      %smodule='%s'\n", prefix, name
        platform_any = 0
        n_platforms = split(mod_platforms[name], platform_values, " ")
        for (pi = 1; pi <= n_platforms; pi++) {
            if (platform_values[pi] == "any") platform_any = 1
        }
        export_count = split(mod_exports[name], module_exports, " ")
        body_indent = platform_any == 0 ? "        " : "      "

        # An optional-only module is expected to be unavailable on some hosts,
        # so it fails quietly; the loop below does not treat it as a plan failure.
        if (!(name in required)) printf "      %srequired=0\n", prefix

        # A module whose required dependency is unavailable must not run: its
        # body would call functions that were never defined.
        n_req = split(mod_req[name], reqs, " ")
        if (n_req > 0) {
            printf "      %sblocked_by=\n", prefix
            printf "      for %sdependency in", prefix
            for (rqi = 1; rqi <= n_req; rqi++) {
                printf " %s", reqs[rqi]
            }
            printf "; do\n"
            emit_token_lookup("        ", "\"$" prefix "unavailable\"", "\"$" prefix "dependency\"", prefix "dependency_missing")
            printf "        if [ \"$%sdependency_missing\" -eq 1 ]; then\n", prefix
            printf "          %sblocked_by=${%sdependency%%%%@*}\n", prefix, prefix
            printf "          break\n"
            printf "        fi\n"
            printf "      done\n"
            printf "      unset %sdependency %sdependency_missing\n", prefix, prefix
            printf "      if [ -n \"$%sblocked_by\" ]; then\n", prefix
            if (name in required) {
                printf "        printf 'valise: module %%s skipped: required dependency unavailable: %%s\\n' '%s' \"$%sblocked_by\" >&2\n", display, prefix
            }
            printf "        %sstatus=1\n", prefix
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
            if (name in required) {
                printf "        printf 'valise: module %%s skipped: unsupported platform: %%s\\n' '%s' \"$%splatform\" >&2\n", display, prefix
            }
            printf "        %sstatus=1\n", prefix
            if (mod_load[name] != "") printf "      else\n"
        }
        if (mod_load[name] != "") {
            if (export_count == 0) {
                printf "%s. \"${VALISE_MODULE_ROOT%%/}/%s\"\n", body_indent, mod_load[name]
                printf "%s%sstatus=$?\n", body_indent, prefix
                printf "%sif [ \"$%sstatus\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s  printf 'valise: module %%s failed with status %%s\\n' '%s' \"$%sstatus\" >&2\n", body_indent, display, prefix
                printf "%sfi\n", body_indent
            } else {
                printf "%s%scleanup_exports=\n", body_indent, prefix
                printf "%sfor %sexport in", body_indent, prefix
                for (ei = 1; ei <= export_count; ei++) {
                    printf " %s", module_exports[ei]
                }
                printf "; do\n"
                printf "%s  %sconflict=0\n", body_indent, prefix
                # Restrict lookup to shell definitions inside a subshell. An
                # external command may be wrapped, but an existing function,
                # alias or builtin is a conflict. /dev/null is not a directory;
                # unlike an empty PATH, it cannot search the current directory.
                # Bash needs the explicit alias query when expand_aliases is off;
                # native zsh's command -v also reports aliases without executing
                # them, although its command prefix bypasses builtins.
                printf "%s  if (\n", body_indent
                printf "%s    PATH=/dev/null\n", body_indent
                printf "%s    \\command 'alias' \"$%sexport\" || \\command -v \"$%sexport\"\n", body_indent, prefix, prefix
                printf "%s  ) >/dev/null 2>&1; then\n", body_indent
                printf "%s    %sconflict=1\n", body_indent, prefix
                printf "%s  fi\n", body_indent
                printf "%s  if [ \"$%sconflict\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s    printf 'valise: %%s: declared export already exists before load: %%s\\n' '%s' \"$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s    %sstatus=1\n", body_indent, prefix
                printf "%s  else\n", body_indent
                printf "%s    %scleanup_exports=\"${%scleanup_exports:+$%scleanup_exports }$%sexport\"\n", body_indent, prefix, prefix, prefix, prefix, prefix
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
                # With external lookup disabled, a function is reported as its
                # exact name. Alias descriptions are not function definitions.
                # This also rejects executables added to PATH by the module,
                # without keeping a second ledger of pre-existing executables.
                printf "%s    if ! %slookup=$(PATH=/dev/null \\command -v \"$%sexport\" 2>/dev/null); then\n", body_indent, prefix, prefix
                printf "%s      printf 'valise: %%s: declared export missing: %%s\\n' '%s' \"$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s      %sstatus=1\n", body_indent, prefix
                printf "%s    elif [ \"$%slookup\" != \"$%sexport\" ]; then\n", body_indent, prefix, prefix
                printf "%s      printf 'valise: %%s: declared export was not provided by module: %%s\\n' '%s' \"$%sexport\" >&2\n", body_indent, display, prefix
                printf "%s      %sstatus=1\n", body_indent, prefix
                printf "%s    fi\n", body_indent
                printf "%s  done\n", body_indent
                printf "%sfi\n", body_indent
                printf "%sif [ \"$%sstatus\" -ne 0 ]; then\n", body_indent, prefix
                printf "%s  printf 'valise: module %%s failed with status %%s\\n' '%s' \"$%sstatus\" >&2\n", body_indent, display, prefix
                # Split explicitly so every created function is cleaned up in
                # native zsh too, while pre-existing caller definitions survive.
                printf "%s  while [ -n \"$%scleanup_exports\" ]; do\n", body_indent, prefix
                printf "%s    case $%scleanup_exports in\n", body_indent, prefix
                printf "%s    *' '*)\n", body_indent
                printf "%s      %sexport=${%scleanup_exports%%%% *}\n", body_indent, prefix, prefix
                printf "%s      %scleanup_exports=${%scleanup_exports#* }\n", body_indent, prefix, prefix
                printf "%s      ;;\n", body_indent
                printf "%s    *)\n", body_indent
                printf "%s      %sexport=$%scleanup_exports\n", body_indent, prefix, prefix
                printf "%s      %scleanup_exports=\n", body_indent, prefix
                printf "%s      ;;\n", body_indent
                printf "%s    esac\n", body_indent
                printf "%s    unset -f \"$%sexport\" 2>/dev/null || :\n", body_indent, prefix
                printf "%s  done\n", body_indent
                printf "%sfi\n", body_indent
                # A module that succeeded owns its exports for the lifetime of
                # the process. Each token is <module>:<export>, so the VALISE_RELOAD
                # prelude clears an export only for the SAME provider that
                # installed it: another module's export, and a caller's colliding
                # function, are reported on load instead of being replaced.
                printf "%sif [ \"$%sstatus\" -eq 0 ]; then\n", body_indent, prefix
                printf "%s  for %sexport in", body_indent, prefix
                for (ei = 1; ei <= export_count; ei++) {
                    printf " %s", module_exports[ei]
                }
                printf "; do\n"
                emit_token_lookup(body_indent "    ", "\"${_valise_plan_owned:-}\"", "\"" mod_display[name] ":$" prefix "export\"", "_valise_owned_hit")
                printf "%s    if [ \"$_valise_owned_hit\" -eq 0 ]; then\n", body_indent
                printf "%s      _valise_plan_owned=\"${_valise_plan_owned:+$_valise_plan_owned }%s:$%sexport\"\n", body_indent, mod_display[name], prefix
                printf "%s    fi\n", body_indent
                printf "%s    unset _valise_owned_hit\n", body_indent
                printf "%s  done\n", body_indent
                printf "%s  unset %sexport\n", body_indent, prefix
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
    # Strict mode stops at the first failure in the required closure. Anything
    # else is recorded so its dependents are blocked, and the plan continues.
    printf "    if [ \"$%sstatus\" -ne 0 ]; then\n", prefix
    printf "      %sunavailable=\"$%sunavailable $%smodule\"\n", prefix, prefix, prefix
    printf "      if [ \"$%smode\" = strict ] && [ \"$%srequired\" -eq 1 ]; then\n", prefix, prefix
    printf "        %sfailed=1\n", prefix
    printf "        %sfirst_status=$%sstatus\n", prefix, prefix
    printf "        break\n"
    printf "      fi\n"
    printf "      %sstatus=0\n", prefix
    printf "    fi\n"
    printf "  done\n"
    printf "fi\n"

    # Hand this phase's availability on to the NEXT plan sourced in the same
    # evaluation (env -> interactive). The managed block clears the carrier at
    # the start of each evaluation, so it never leaks across a release switch.
    printf "%scarried=${%sunavailable# }\n", prefix, prefix
    printf "if [ \"$%sfailed\" -ne 0 ]; then\n", prefix
    printf "  %sreturn=$%sfirst_status\n", prefix, prefix
    printf "else\n"
    printf "  %sreturn=0\n", prefix
    printf "fi\n"
    printf "unset %sstatus %sfailed %sfirst_status %sunavailable %smode %splatform\n", prefix, prefix, prefix, prefix, prefix, prefix
    printf "unset %smodule %smodule_index %srequired %sblocked_by %splatform_match %sexport %slookup %sconflict %scleanup_exports\n", prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix
    # _valise_plan_carried deliberately survives this plan: the interactive
    # plan sourced next in the same evaluation reads it. The managed block
    # resets it at the start of each evaluation.
    printf "eval \"unset %sreturn; return $%sreturn\"\n", prefix, prefix
}
