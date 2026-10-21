# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# valise compile: pure POSIX awk static plan compiler.
# Input: single preprocessed stream from sh wrapper.
#   Lines starting with SEED: space-separated seed module names
#   Lines starting with MOD: identity<TAB>requires<TAB>load_path
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
    if (n >= 3) {
        name = fields[1]
        mod_req[name] = fields[2]
        mod_load[name] = fields[3]
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

    # --- Render plan ---
    printf "# shell-profile-installed-modules-v1\n"
    printf "# Generated by hack/compile-shell-profile-release.py; DO NOT EDIT.\n"
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
    if (prelude_fn_count > 0) {
        printf ". \"${VALISE_MODULE_ROOT%%/}/%s\" || %sstatus=$?\n", prelude_dest, prefix
    }
    for (i = 1; i <= ordered_count; i++) {
        name = ordered[i]
        printf "if [ \"${%sstatus}\" -eq 0 ]; then\n", prefix
        printf "  . \"${VALISE_MODULE_ROOT%%/}/%s\"\n", mod_load[name]
        printf "  %sstatus=$?\n", prefix
        printf "fi\n"
    }
    if (prelude_fn_count > 0) {
        printf "unset -f"
        for (i = 1; i <= prelude_fn_count; i++) {
            printf " %s", prelude_fns[i]
        }
        printf " 2>/dev/null || :\n"
    }
    printf "%sreturn=$%sstatus\n", prefix, prefix
    printf "unset %sstatus\n", prefix
    printf "eval \"unset %sreturn; return $%sreturn\"\n", prefix, prefix
}
