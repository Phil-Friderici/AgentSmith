#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
    printf '%s\n' "Refusing to start the workstation as root; configure a non-root host UID." >&2
    exit 1
fi

umask 077

/usr/local/bin/agentforge-doctor

exec "$@"
