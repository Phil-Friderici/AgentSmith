#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
    printf '%s\n' "Refusing to start the workstation as root; configure a non-root host UID." >&2
    exit 1
fi

umask 077

fail() {
    printf 'Workstation startup failed: %s\n' "$1" >&2
    exit 1
}

if [[ "${AGENTFORGE_LEVEL:-}" == "1" ]]; then
    [[ "${GH_CONFIG_DIR:-}" == "/tmp/agentforge-gh/config" ]] \
        || fail "Level 1 requires GH_CONFIG_DIR=/tmp/agentforge-gh/config."

    for path in /tmp/agentforge-gh /tmp/agentforge-gh/config; do
        [[ ! -L "$path" ]] || fail "GitHub CLI runtime path must not be a symbolic link."
        if [[ ! -d "$path" ]]; then
            [[ ! -e "$path" ]] || fail "GitHub CLI runtime path is not a directory."
            mkdir -m 0700 -- "$path"
        fi
        [[ "$(stat -c '%u' -- "$path")" == "$EUID" ]] \
            || fail "GitHub CLI runtime path must be owned by the workstation user."
        chmod 0700 -- "$path"
    done
fi

/usr/local/bin/agentforge-doctor

exec "$@"
