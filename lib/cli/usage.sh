# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT
# valise CLI: per-command usage text.
# Sourced by bin/valise; not executable on its own.

usage() {
  printf '%s\n' \
    "Usage: valise <command> [options]" \
    "" \
    "Global option:" \
    "  -C <dir>                  Run as if valise was started in dir" \
    "" \
    "Project commands (run anywhere inside a directory holding valise.conf):" \
    "  new [dir]                 Scaffold a new valise project" \
    "  module <new|list|remove>  Create, list, or remove project modules" \
    "  build [--variant=<name>] [--bundle=<name>] [out]" \
    "                            Build a release tree (default: build/release)" \
    "  apply [--variant=<name>] [--bundle=<name>] [--no-integration] [--dry-run]" \
    "                            Build the project, install it, and integrate it" \
    "  status                    Show project, active release, integration, and drift" \
    "  lint [--require-parsers] [module...]  Check metadata, layers, bundles, and syntax" \
    "  test [--shell=<class>] [--require-shells] [module...]  Run module tests" \
    "  run [--shell=<class>] [--module=<m>]... -- <script>  Run a script with modules loaded" \
    "  env [export <format>]     Print storage paths, or render the GUI env bridge" \
    "" \
    "Release commands:" \
    "  install [--no-integration]  Install the release tree in the current directory" \
    "  release <list|use|rollback|prune|verify>  Manage installed releases" \
    "  uninstall [--keep-releases]  Remove the integration, commands, and releases" \
    "  init [posix|fish]         Print the shell integration snippet" \
    "  doctor [--pre-install] [--no-integration]  Run environment diagnostics" \
    "" \
    "Plumbing:" \
    "  compile [--bundle=<name>] [--variant=<name>] <output-dir>  Compile plans only" \
    "  registry [path]           Print the module table generated from metadata" \
    "  make-manifest <tree> [--output <file>]  Write a release manifest for a tree" \
    "  explain-variant [--bundle=<name>] [name]  Show a variant and its per-shell impact" \
    "  explain-bundles [--bundle=<name>] [--variant=<name>]  Show each bundle's closure" \
    "  layer-lint <name>         Validate a contribution layer structure" \
    "  version                   Print version" \
    "" \
    "Install writes a two-stage managed block to ~/.profile and the other startup" \
    "files (~/.bashrc, ~/.zprofile, ~/.zshenv, ~/.zshrc as appropriate), plus the" \
    "sh/ksh \$ENV shim, and compiles plans/<shell>.sh and plans/<shell>-interactive.sh." \
    "A project that sets gui_env also gets an environment.d or LaunchAgent bridge;" \
    "'valise env export <format>' renders the same file without installing." \
    "" \
    "Environment:" \
    "  XDG_DATA_HOME    Release storage root (default: ~/.local/share)" \
    "  XDG_CONFIG_HOME  Active pointer, shim, and bridge root (default: ~/.config)" \
    "  XDG_STATE_HOME   Lock and journal state (default: ~/.local/state)" \
    "  VALISE_RELOAD    Set to 1 to force a plan reload in the current shell" \
    "" \
    "Run 'valise <command> --help' for command-specific usage."
}

# Per-command usage. Each command prints its own contract instead of the
# global list, so `valise compile --help` names the arguments that command
# actually accepts.

usage_init() {
  printf '%s\n' \
    "usage: valise init [posix|fish] [--source-tree]" \
    "" \
    "Print the shell integration snippet for the active release. valise install" \
    "and valise apply write it for you; use this to wire a startup file by hand." \
    "" \
    "  posix         A managed block for any POSIX shell. It loads the plan for" \
    "                the running shell class: ksh, zsh, bash, or sh for any other." \
    "  fish          The Fish conf.d hook." \
    "  --source-tree Skip release verification in the Fish hook (development only)." \
    "" \
    "With no argument, fish when \$SHELL names fish, otherwise posix."
}

usage_install() {
  printf '%s\n' \
    "usage: valise install [--no-integration]" \
    "" \
    "Install the release tree in the current directory and make it active, then" \
    "write the shell integration." \
    "" \
    "A two-stage managed block is written to ~/.profile; to the first of" \
    "~/.bash_profile and ~/.bash_login that exists, because it shadows ~/.profile" \
    "for bash; to ~/.bashrc and ~/.zshrc when that shell is \$SHELL or the file" \
    "exists; to ~/.zprofile when zsh is installed or the file exists; and to" \
    "~/.zshenv, because every zsh invocation reads it. Stage 1 (the env plan) goes" \
    "into all of them; stage 2 (the interactive plan) goes into the shell's" \
    "rc-stage file - ~/.bashrc, ~/.zshrc, or the \$ENV shim - and into the bash" \
    "login file, placed last, so an interactive login reaches it. Stage 2 never" \
    "goes into ~/.zshenv or ~/.zprofile, so interactive setup cannot run before" \
    "your own rc file. Symlinked files are left alone. The \$ENV" \
    "shim is written to \$XDG_CONFIG_HOME/valise/env.sh and points an sh/ksh" \
    "subshell at itself. A Fish conf.d hook is written when Fish is installed." \
    "Each install replaces the block in place, keeping every other byte. Each" \
    "command the release publishes gets a stub in the command directory (see" \
    "valise doctor)." \
    "" \
    "When the release declares gui_env=systemd (Linux) or gui_env=launchd" \
    "(macOS), the matching environment.d or LaunchAgent bridge is written from the" \
    "release's env plan, mode 0600, and prepared before the active release" \
    "changes; gui_env=off removes a bridge an earlier release wrote. PATH and the" \
    "XDG root variables are deliberately not bridged (a GUI session sets its own)" \
    "and are reported as excluded." \
    "" \
    "Every startup file, the shim, and the bridge directory are checked before the" \
    "active release changes. If a later step fails, the previous active release is" \
    "restored." \
    "" \
    "  --no-integration  Write no startup file, shim, Fish hook, bridge, or command stubs."
}

usage_doctor() {
  printf '%s\n' \
    "usage: valise doctor [--pre-install] [--no-integration]" \
    "" \
    "Report the environment, the active release, and the shell integration." \
    "" \
    "Warnings name archetype pitfalls: a legacy single-stage managed block in any" \
    "startup file valise manages, a sh/ksh login shell whose \$ENV is unset or does" \
    "not point at the valise shim, a missing ~/.zshenv block when zsh is installed," \
    "and a GUI-session bridge the active release asked for but that is missing. A" \
    "release with gui_env=off is not warned about: that is the deliberate default." \
    "" \
    "  --pre-install     Skip the active-release and integration checks, for use" \
    "                    before the first install." \
    "  --no-integration  Check the environment and active release only."
}

usage_lint() {
  printf '%s\n' \
    "usage: valise lint [--require-parsers] [module...]" \
    "" \
    "Check the project: every metadata record and the files it names, each layer" \
    "(contrib_ names, version=, dependencies inside the layer or the engine), the" \
    "lint_layer_forbid pattern from valise.conf, every bundle compiled for every" \
    "variant and shell, and the syntax of each body and test with the parser of" \
    "every shell it declares. A body that assigns PATH directly is rejected in" \
    "every phase - use valise_path_prepend/valise_path_append instead - because" \
    "both plans can be re-sourced. Listing modules limits the syntax checks to them." \
    "" \
    "  --require-parsers  Fail instead of skipping when a shell's parser is missing."
}

usage_test() {
  printf '%s\n' \
    "usage: valise test [--shell=<class>[,<class>...]] [--require-shells] [module...]" \
    "" \
    "Run the tests= scripts of each module (default: every module that has them)" \
    "in every shell class it declares whose interpreter is installed: dash (or a" \
    "plain sh) for sh, bash, zsh, ksh, and fish. Each run builds a release with" \
    "the module as its only root, starts the shell with env -i, a fresh HOME," \
    "TMPDIR and XDG directories, and PATH=\${VALISE_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "plus the interpreter's directory, loads the module in strict mode, then runs" \
    "the test. A test passes when it exits 0. Fish tests (*.fish) run only in" \
    "Fish, other tests only in POSIX shells. A test can write fixtures and call" \
    "valise_test_reload to load the module again. VALISE_TEST_ROOT, VALISE_TEST_MODULE," \
    "VALISE_TEST_MODULE_DIR, VALISE_TEST_SHELL and VALISE_PROJECT_ROOT are set." \
    "" \
    "  --shell=<class>   Run only these shell classes." \
    "  --require-shells  Fail instead of skipping when an interpreter is missing."
}

usage_run() {
  printf '%s\n' \
    "usage: valise run [--shell=<class>] [--module=<m>]... [--bundle=<b>] [--variant=<v>] [--keep-env] -- <script> [args...]" \
    "" \
    "Load modules into a shell and run a script there; the exit status is the" \
    "script's. With --module the named modules are the only roots; otherwise the" \
    "bundle and variant (default: valise.conf) select them. The shell class" \
    "defaults to the one \$SHELL names, else sh. The environment is quarantined as" \
    "for valise test unless --keep-env is given."
}

usage_env() {
  printf '%s\n' \
    "usage: valise env [export <format>]" \
    "" \
    "With no arguments, print KEY=value lines, shell-quoted, for VALISE_VERSION," \
    "VALISE_ENGINE_ROOT, VALISE_PROJECT_ROOT (empty outside a project), VALISE_DATA_DIR," \
    "VALISE_CONFIG_DIR, VALISE_STATE_DIR, VALISE_RELEASES_DIR, VALISE_ACTIVE_LINK," \
    "and VALISE_BIN_DIR." \
    "" \
    "'valise env export <format>' prints the environment the active release's env" \
    "plan produces, in a GUI-session-bridging format (format: environment.d," \
    "launchd, or wsl). The capture keeps your real HOME, XDG roots and TMPDIR," \
    "isolates only the startup-file surface, evaluates the plan the way a login" \
    "shell would (module side effects included), and diffs the exported scalar" \
    "environment against a baseline. It fails naming the variable when a value" \
    "cannot be represented (a newline, or a control byte outside XML 1.0), and it" \
    "names every excluded variable on stderr - PATH and the XDG roots are not" \
    "bridged, because a GUI session sets its own. An empty value cannot be" \
    "bridged to environment.d, and is refused by name; unset the variable instead." \
    "The bridge file is written mode 0600." \
    "" \
    "environment.d emits KEY=VALUE lines for ~/.config/environment.d/," \
    "launchd emits a ~/Library/LaunchAgents plist running launchctl setenv per" \
    "variable, and wsl emits WSLENV name/flag lines."
}

usage_uninstall() {
  printf '%s\n' \
    "usage: valise uninstall [--keep-releases]" \
    "" \
    "Remove what valise install wrote: the managed block from each startup file" \
    "(every other line is kept, and a file install created is deleted when it is" \
    "left empty), the block from the \$ENV shim (your own lines in it survive), the" \
    "Fish hook, the GUI env bridge, the command stubs valise owns, the active link," \
    "and the installed releases. Files valise does not own are left alone; a" \
    "symlinked startup file or bridge is reported for you to edit." \
    "" \
    "  --keep-releases   Keep the installed releases." \
    "" \
    "The valise CLI itself is not removed."
}

usage_release() {
  printf '%s\n' \
    "usage: valise release <list|use|rollback|prune|verify> [options]" \
    "" \
    "  list                List installed releases and mark the active one." \
    "  use <sha256>        Verify a release and make it active." \
    "  rollback            Verify the release that was active before the last" \
    "                      switch and make it active again." \
    "  prune [--keep=N]    Remove older releases, keeping the active one and the" \
    "                      N newest by modification time. A release that fails" \
    "                      verification is kept, not removed." \
    "  verify [--print-root]  Verify the sealed active release and optionally" \
    "                      print its root." \
    "" \
    "prune --keep=0 keeps only the active release."
}

usage_new() {
  printf '%s\n' \
    "usage: valise new [dir]" \
    "" \
    "Scaffold a new valise project in dir (default: the current directory)." \
    "" \
    "The directory must be empty or absent. The scaffold contains valise.conf," \
    "bundles.tsv with sh, bash, zsh, ksh and fish rows, variants.tsv, the POSIX" \
    "seed module profile_main and the Fish seed module profile_main_fish."
}

usage_module() {
  printf '%s\n' \
    "usage: valise module <new|list|remove> [options]" \
    "" \
    "  new <name> [--exports=<list>] [--into=<module>[,...] | --no-wire]" \
    "                                  Create a POSIX module in module.d/ and add it" \
    "                                  to the requires= of the bundle's single POSIX" \
    "                                  root, of the named modules, or of none." \
    "  list                            List the project's and its layers' modules." \
    "  remove <name>                   Remove a module and its references in metadata," \
    "                                  bundle roots, and variant exclusions. Refuses" \
    "                                  if that would leave a bundle or module empty."
}

usage_build() {
  printf '%s\n' \
    "usage: valise build [--variant=<name>] [--bundle=<name>] [out]" \
    "" \
    "Build a release tree from the project in the current directory." \
    "" \
    "  --variant=<name>  Build variant whose exclusion list applies (default:" \
    "                    valise.conf variant=)." \
    "  --bundle=<name>   Bundle whose roots seed each plan (default: valise.conf" \
    "                    bundle=)." \
    "  out               Output directory (default: build/release). An existing" \
    "                    default output is replaced after a successful build." \
    "                    An explicit output must be empty or absent." \
    "" \
    "The tree holds plans/<shell>.sh for each POSIX shell the bundle names," \
    "plans/<shell>-interactive.sh for a shell whose closure has interactive-phase" \
    "modules, runtime/capabilities.sh, valise-release.conf (including the bundle," \
    "variant, and gui_env the build used), manifest.tsv, and the metadata and" \
    "bodies of exactly the modules some plan loads. Engine modules are copied under" \
    "valise/, layer modules under layers/<provider>/. A module that publishes" \
    "commands adds plans/commands/<module>.sh and bin/<command>; Fish roots add" \
    "runtime/fish/."
}

usage_apply() {
  printf '%s\n' \
    "usage: valise apply [--variant=<name>] [--bundle=<name>] [--no-integration] [--dry-run]" \
    "" \
    "Build the project, install the result, write the shell integration, and verify" \
    "the active release. See 'valise install --help' for the files it writes." \
    "" \
    "  --no-integration  Write no startup file, shim, Fish hook, bridge, or" \
    "                    command stubs." \
    "  --dry-run         Build, then print what install would change: the release," \
    "                    each startup file, the shim, the Fish hook, the GUI env" \
    "                    bridge, and the command stubs. Nothing outside build/ is" \
    "                    written, and module bodies are NOT executed, so the" \
    "                    bridge is reported as would-create/would-regenerate" \
    "                    rather than rendered."
}

usage_status() {
  printf '%s\n' \
    "usage: valise status" \
    "" \
    "Report the project defaults, the integration in each startup file, the bundle," \
    "variant and valise version the active release was built with, and whether the" \
    "active release matches build/release."
}

usage_compile() {
  printf '%s\n' \
    "usage: valise compile [--bundle=<name>] [--variant=<name>] <output-dir>" \
    "" \
    "Compile the project's modules into <output-dir>/<shell>.sh plans for the" \
    "POSIX shells the bundle names, plus <output-dir>/<shell>-interactive.sh for a" \
    "shell whose closure contains interactive-phase modules. Use build for an" \
    "installable release." \
    "" \
    "  --bundle=<name>   Bundle whose roots seed each plan (default: valise.conf)." \
    "  --variant=<name>  Variant whose exclusion list applies (default: valise.conf)." \
    "  output-dir        Destination directory. It must be empty or absent."
}

usage_registry() {
  printf '%s\n' \
    "usage: valise registry [path]" \
    "" \
    "Print the module table valise builds from metadata: the project's module.d/," \
    "each layers/<provider>/module.d/, then the engine's own modules under the" \
    "source valise. The table is internal; nothing needs to commit it." \
    "" \
    "  path  Write the table to this file instead of standard output."
}

usage_explain_bundles() {
  printf '%s\n' \
    "usage: valise explain-bundles [--bundle=<name>] [--variant=<name>]" \
    "" \
    "Show the roots and the ordered module closure each bundle resolves to, per" \
    "shell, with each module's source." \
    "" \
    "  --bundle=<name>   Report one bundle instead of all of them." \
    "  --variant=<name>  Apply this variant's exclusions (default: valise.conf)."
}

usage_layer_lint() {
  printf '%s\n' \
    "usage: valise layer-lint <layer-name>" \
    "" \
    "Validate a contribution layer's structure, namespace, metadata, load paths," \
    "file modes, and dependency closure." \
    "" \
    "  layer-name  Provider directory under layers/, or a path to a layer" \
    "              tree containing module.d/."
}

usage_explain_variant() {
  printf '%s\n' \
    "usage: valise explain-variant [--bundle=<name>] [variant-name]" \
    "" \
    "Show a variant's description, excluded modules, and how many of the bundle's" \
    "roots it removes per shell." \
    "" \
    "  --bundle=<name>  Bundle to measure against (default: valise.conf)." \
    "  variant-name     Variant from variants.tsv (default: valise.conf)."
}
