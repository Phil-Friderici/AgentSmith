#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

workspace_root="${AGENTFORGE_WORKSPACE_ROOT:-/workspace}"
cache_mount_root="${AGENTFORGE_CACHE_ROOT:-/cache}"
bundler_cache_root="${AGENTFORGE_BUNDLER_CACHE_ROOT:-$cache_mount_root/bundler}"
bundler_config_root="${AGENTFORGE_BUNDLER_CONFIG_ROOT:-/tmp/agentforge-bundler-config}"
bundle_project_cache=""

fail() {
    printf 'ERROR: Puppet workflow: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  agentforge-puppet toolchain [MODULE_DIR]
  agentforge-puppet bootstrap MODULE_NAME [LICENSE]
  agentforge-puppet bundle-install [MODULE_DIR]
  agentforge-puppet validate [MODULE_DIR] [-- PDK_ARGS...]
  agentforge-puppet unit [MODULE_DIR] [-- PDK_ARGS...]

Run module commands from Level 1. Modules must be located in /workspace.
USAGE
}

check_toolchain() {
    local ruby_version bundler_version pdk_version

    ruby_version="$(ruby -e 'print RUBY_VERSION' 2>/dev/null)" \
        || fail "Ruby is unavailable; expected 3.2.3."
    [[ "$ruby_version" == "3.2.3" ]] \
        || fail "Ruby $ruby_version is installed; expected 3.2.3."

    bundler_version="$(bundle --version 2>/dev/null)" \
        || fail "Bundler is unavailable; expected 2.4.20."
    [[ "$bundler_version" == "Bundler version 2.4.20" ]] \
        || fail "$bundler_version is installed; expected Bundler 2.4.20."

    pdk_version="$(pdk --version 2>/dev/null)" \
        || fail "PDK is unavailable; expected 4.0.1."
    [[ "$pdk_version" == "4.0.1" ]] \
        || fail "PDK $pdk_version is installed; expected 4.0.1."

    printf 'Ruby %s, Bundler 2.4.20, PDK 4.0.1\n' "$ruby_version"
}

resolve_workspace() {
    [[ -d "$workspace_root" ]] || fail "workspace $workspace_root is missing."
    workspace_root="$(realpath -e -- "$workspace_root")"
}

resolve_module() {
    local start="$1"
    local current parent

    resolve_workspace
    [[ -d "$start" ]] || fail "module directory $start does not exist."
    current="$(realpath -e -- "$start")"
    case "$current/" in
        "$workspace_root/"*) ;;
        *) fail "module directories must be inside $workspace_root." ;;
    esac

    while :; do
        if [[ -f "$current/metadata.json" ]]; then
            module_root="$current"
            break
        fi
        [[ "$current" != "$workspace_root" ]] \
            || fail "no metadata.json found between $start and $workspace_root."
        parent="$(dirname -- "$current")"
        [[ "$parent" != "$current" ]] \
            || fail "no Puppet module root found for $start."
        current="$parent"
    done

}

check_module_ruby() {
    local ruby_file="$module_root/.ruby-version"
    local declared_version

    if [[ ! -f "$ruby_file" ]]; then
        printf 'WARN: %s has no .ruby-version; using the pinned workstation Ruby 3.2.3.\n' "$module_root" >&2
        return
    fi
    [[ ! -L "$ruby_file" ]] || fail "$ruby_file must not be a symbolic link."

    declared_version="$(tr -d '[:space:]' < "$ruby_file")"
    [[ "$declared_version" == "3.2.3" ]] \
        || fail "$ruby_file declares Ruby $declared_version; this workstation supports 3.2.3."
}

configure_bundle_cache() {
    local cache_id config_dir cache_root_candidate cache_root_real mount_root_real
    local config_root_candidate config_root_real tmp_root_real
    local jobs="${AGENTFORGE_BUNDLE_JOBS:-4}"

    [[ "$jobs" =~ ^[1-9][0-9]?$ ]] \
        || fail "AGENTFORGE_BUNDLE_JOBS must be an integer from 1 to 99."
    [[ -d "$cache_mount_root" && -w "$cache_mount_root" ]] \
        || fail "the Level 1 cache mount is missing or not writable."
    [[ "$bundler_cache_root" == /* && "$bundler_config_root" == /* ]] \
        || fail "Bundler cache and configuration paths must be absolute."

    cache_id="$(printf '%s' "$module_root" | sha256sum | cut -c1-16)"
    mount_root_real="$(realpath -e -- "$cache_mount_root")"
    tmp_root_real="$(realpath -e -- /tmp)"
    cache_root_candidate="$(realpath -m -- "$bundler_cache_root")"
    config_root_candidate="$(realpath -m -- "$bundler_config_root")"
    [[ "$cache_root_candidate" != "$mount_root_real" && "$cache_root_candidate/" == "$mount_root_real/"* ]] \
        || fail "Bundler cache root must be a child of the configured cache mount."
    [[ "$config_root_candidate" != "$tmp_root_real" && "$config_root_candidate/" == "$tmp_root_real/"* ]] \
        || fail "Bundler application configuration must remain under ephemeral /tmp."

    mkdir -p -- "$cache_root_candidate" "$config_root_candidate"
    cache_root_real="$(realpath -e -- "$cache_root_candidate")"
    config_root_real="$(realpath -e -- "$config_root_candidate")"
    [[ "$cache_root_real" != "$mount_root_real" && "$cache_root_real/" == "$mount_root_real/"* ]] \
        || fail "Bundler cache root must remain under the configured cache mount."
    [[ "$config_root_real" != "$tmp_root_real" && "$config_root_real/" == "$tmp_root_real/"* ]] \
        || fail "Bundler application configuration must remain under ephemeral /tmp."

    bundle_project_cache="$cache_root_real/$cache_id"
    config_dir="$config_root_real/$cache_id"
    mkdir -p -m 700 -- "$bundle_project_cache/gems" "$bundle_project_cache/user-cache" "$config_dir"
    chmod 700 -- "$bundle_project_cache" "$bundle_project_cache/gems" "$bundle_project_cache/user-cache" "$config_dir"

    export BUNDLE_PATH="$bundle_project_cache/gems"
    export BUNDLE_USER_CACHE="$bundle_project_cache/user-cache"
    export BUNDLE_APP_CONFIG="$config_dir"
    export BUNDLE_GEMFILE="$module_root/Gemfile"
    export AGENTFORGE_BUNDLE_JOBS="$jobs"
}

install_module_bundle() {
    [[ -f "$module_root/Gemfile" ]] \
        || fail "module $module_root has no Gemfile."
    configure_bundle_cache
    cd -- "$module_root"
    printf 'Installing dependencies with project-scoped Bundler cache %s\n' "$bundle_project_cache"
    bundle install --jobs "$AGENTFORGE_BUNDLE_JOBS" --retry 2
}

module_and_args() {
    module_dir="$PWD"
    if [[ $# -gt 0 && "$1" != "--" ]]; then
        module_dir="$1"
        shift
    fi
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    module_args=("$@")

    resolve_module "$module_dir"
    check_toolchain
    check_module_ruby
}

bootstrap_module() {
    local name="$1"
    local license="${2:-Apache-2.0}"
    local target

    resolve_workspace
    [[ -w "$workspace_root" ]] || fail "Level 1 workspace is not writable."
    [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] \
        || fail "module name must start with a lowercase letter and contain only lowercase letters, digits, or underscores."
    [[ "$license" =~ ^[A-Za-z0-9.-]+$ ]] \
        || fail "license must be an SPDX identifier."
    target="$workspace_root/$name"
    [[ ! -e "$target" && ! -L "$target" ]] \
        || fail "target $target already exists."

    check_toolchain
    pdk new module \
        --skip-interview \
        --template-ref="pdk-default#4.0.1" \
        --license="$license" \
        "$name" "$target"

    [[ -d "$target" && ! -L "$target" \
        && -f "$target/metadata.json" && ! -L "$target/metadata.json" \
        && -f "$target/Gemfile" && ! -L "$target/Gemfile" ]] \
        || fail "PDK returned without creating a complete module at $target."
    [[ ! -L "$target/.ruby-version" ]] \
        || fail "generated .ruby-version must not be a symbolic link."
    printf '3.2.3\n' > "$target/.ruby-version"
    printf 'Created Puppet module at %s\n' "$target"
    printf 'Next: agentforge-puppet validate %s, then agentforge-puppet unit %s.\n' "$target" "$target"
}

command="${1:-}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$command" in
    toolchain)
        check_toolchain
        if [[ $# -gt 0 ]]; then
            module_and_args "$@"
            printf 'Module Ruby selection is compatible: %s\n' "$module_root"
        fi
        ;;
    bootstrap)
        [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
        bootstrap_module "$@"
        ;;
    bundle-install)
        module_and_args "$@"
        install_module_bundle
        ;;
    validate)
        module_and_args "$@"
        cd -- "$module_root"
        pdk validate "${module_args[@]}"
        ;;
    unit)
        module_and_args "$@"
        cd -- "$module_root"
        pdk test unit "${module_args[@]}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
