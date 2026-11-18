#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
    printf '%s\n' "Run this script as the workstation host user, not as root." >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
workspace="${AGENTFORGE_WORKSPACE:-${HOME:?HOME must be set}/AgentForge/workspace}"
cache="${AGENTFORGE_CACHE:-${HOME}/AgentForge/cache/agentforge/level1}"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

is_within() {
    [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

for path in "$workspace" "$cache"; do
    [[ "$path" == /* ]] || fail "Mount paths must be absolute: $path"
done

workspace="$(realpath -m -- "$workspace")"
cache="$(realpath -m -- "$cache")"

if is_within "$workspace" "$repo_root" || is_within "$repo_root" "$workspace"; then
    fail "Workspace must be separate from the AgentForge source repository."
fi
if is_within "$cache" "$repo_root" || is_within "$repo_root" "$cache"; then
    fail "Cache must be separate from the AgentForge source repository."
fi
if is_within "$workspace" "$cache" || is_within "$cache" "$workspace"; then
    fail "Workspace and cache paths must not contain or overlap each other."
fi

umask 077
mkdir -p -- "$workspace" "$cache"

for path in "$workspace" "$cache"; do
    owner="$(stat -c '%u' -- "$path")"
    [[ "$owner" == "$EUID" ]] || fail "$path is not owned by the current user; correct ownership manually, without recursive startup changes."
    [[ -w "$path" ]] || fail "$path is not writable by the current user; correct permissions manually."
done

printf 'Workspace ready: %s\n' "$workspace"
printf 'Level 1 cache ready: %s\n' "$cache"
printf '%s\n' "No ownership or permission changes were made to existing directories."
