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
    "  apply [--variant=<name>] [--bundle=<name>] [--no-integration]" \
    "                            Build the project, install it, and integrate it" \
    "  status                    Show project, active release, integration, and drift" \
    "" \
    "Release commands:" \
    "  install [--no-integration]  Install the release tree in the current directory" \
    "  release <list|use|prune|verify>  Manage installed releases" \
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
    "Environment:" \
    "  XDG_DATA_HOME    Release storage root (default: ~/.local/share)" \
    "  XDG_CONFIG_HOME  Active pointer symlink (default: ~/.config)" \
    "  XDG_STATE_HOME   Lock and journal state (default: ~/.local/state)" \
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
    "A managed block is written to ~/.profile; to the first of ~/.bash_profile and" \
    "~/.bash_login that exists, because it shadows ~/.profile for bash; to ~/.bashrc" \
    "and ~/.zshrc when that shell is \$SHELL or the file exists; and to ~/.zprofile" \
    "when zsh is installed or the file exists. Symlinked files are left alone. A" \
    "Fish conf.d hook is written when Fish is installed. Each install replaces the" \
    "block in place." \
    "" \
    "  --no-integration  Write no startup file and no Fish hook."
}

usage_doctor() {
  printf '%s\n' \
    "usage: valise doctor [--pre-install] [--no-integration]" \
    "" \
    "Report the environment, the active release, and the shell integration." \
    "" \
    "  --pre-install     Skip the active-release and integration checks, for use" \
    "                    before the first install." \
    "  --no-integration  Check the environment and active release only."
}

usage_release() {
  printf '%s\n' \
    "usage: valise release <list|use|prune|verify> [options]" \
    "" \
    "  list                List installed releases and mark the active one." \
    "  use <sha256>        Verify a release and make it active." \
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
    "runtime/capabilities.sh, valise-release.conf, manifest.tsv, and the metadata" \
    "and bodies of exactly the modules some plan loads. Engine modules are copied" \
    "under valise/, layer modules under layers/<provider>/."
}

usage_apply() {
  printf '%s\n' \
    "usage: valise apply [--variant=<name>] [--bundle=<name>] [--no-integration]" \
    "" \
    "Build the project, install the result, write the shell integration, and verify" \
    "the active release. See 'valise install --help' for the files it writes." \
    "" \
    "  --no-integration  Write no startup file and no Fish hook."
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
    "POSIX shells the bundle names. Use build for an installable release." \
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
