#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
    printf '%s\n' "Run this script as the workstation host user, not as root." >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
workspace="${AGENTFORGE_WORKSPACE:-${HOME:?HOME must be set}/AgentForge/workspace}"
cache="${AGENTFORGE_CACHE:-${HOME}/AgentForge/cache/agentforge/level1}"
state="${AGENTFORGE_COPILOT_STATE:-${HOME}/AgentForge/state/copilot}"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

is_within() {
    [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

for path in "$workspace" "$cache" "$state"; do
    [[ "$path" == /* ]] || fail "State, workspace, and cache paths must be absolute."
done

[[ ! -L "$state" ]] || fail "Copilot state root must not be a symbolic link."
workspace="$(realpath -m -- "$workspace")"
cache="$(realpath -m -- "$cache")"
state="$(realpath -m -- "$state")"

for path in "$workspace" "$cache" "$state"; do
    if is_within "$path" "$repo_root" || is_within "$repo_root" "$path"; then
        fail "Copilot state, workspace, and cache must be separate from the AgentForge source repository."
    fi
done
if is_within "$workspace" "$cache" || is_within "$cache" "$workspace"; then
    fail "Workspace and cache paths must not contain or overlap each other."
fi
if is_within "$state" "$workspace" || is_within "$workspace" "$state" \
    || is_within "$state" "$cache" || is_within "$cache" "$state"; then
    fail "Copilot state must not overlap the workspace or cache."
fi

[[ -d "$workspace" && -d "$cache" ]] \
    || fail "Initialize the workspace and cache with scripts/init-workspace.sh first."
[[ "$(stat -c '%u' -- "$workspace")" == "$EUID" && "$(stat -c '%u' -- "$cache")" == "$EUID" ]] \
    || fail "Workspace and cache must be owned by the current user."

umask 077
mkdir -p -- "$state/session-state"
[[ ! -L "$state" && ! -L "$state/session-state" ]] \
    || fail "Copilot state paths must not be symbolic links."

if [[ ! -e "$state/settings.json" ]]; then
    install -m 600 /dev/null "$state/settings.json"
    printf '{}\n' > "$state/settings.json"
fi
if [[ ! -e "$state/session-store.db" ]]; then
    install -m 600 /dev/null "$state/session-store.db"
fi

check_private_path() {
    local path="$1"
    local expected_type="$2"
    local owner mode

    [[ ! -L "$path" ]] || fail "$path must not be a symbolic link."
    if [[ "$expected_type" == directory ]]; then
        [[ -d "$path" && -r "$path" && -w "$path" && -x "$path" ]] \
            || fail "$path must be a readable, writable directory."
    else
        [[ -f "$path" && -r "$path" && -w "$path" ]] \
            || fail "$path must be a readable, writable regular file."
    fi

    owner="$(stat -c '%u' -- "$path")"
    mode="$(stat -c '%a' -- "$path")"
    [[ "$owner" == "$EUID" ]] || fail "$path is not owned by the current user."
    (( (8#$mode & 077) == 0 )) || fail "$path must not grant group or other permissions."
}

check_private_path "$state" directory
check_private_path "$state/settings.json" file
check_private_path "$state/session-state" directory
check_private_path "$state/session-store.db" file

bash "$repo_root/containers/copilot-storage-check.sh" state-root "$state"
bash "$repo_root/containers/copilot-storage-check.sh" workspace-cache "$workspace" "$cache"

printf 'Copilot state ready: %s\n' "$state"
printf '%s\n' "Persisted paths are limited to settings.json, session-state/, and session-store.db."
printf '%s\n' "Authentication files, logs, and the rest of COPILOT_HOME are not mounted."
