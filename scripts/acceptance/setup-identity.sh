#!/usr/bin/env bash
set -Eeuo pipefail

readonly acceptance_user="agentforge-acceptance"
readonly acceptance_home="/var/lib/agentforge-acceptance"
readonly subid_start=165536
readonly subid_count=65536
readonly subid_end=$((subid_start + subid_count - 1))

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

if (( EUID != 0 )); then
    fail "Run this setup script with sudo; it changes only the dedicated acceptance identity and subordinate ID maps."
fi

for command_name in podman newuidmap newgidmap useradd usermod; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required; install the approved rootless Podman preflight packages first."
done

[[ "$(podman --version)" == "podman version 4.9.3" ]] || fail "Expected Podman 4.9.3."

for helper in /usr/bin/newuidmap /usr/bin/newgidmap; do
    [[ -x "$helper" ]] || fail "$helper is missing or not executable."
    [[ "$(stat -c '%u:%a' "$helper")" == "0:4755" ]] || fail "$helper must be root-owned mode 4755."
done

check_subid_range() {
    local file="$1"
    local found=0
    local owner start count end

    [[ -f "$file" ]] || fail "$file is missing."
    while IFS=: read -r owner start count; do
        [[ -n "$owner" && "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
        end=$((start + count - 1))

        if [[ "$owner" == "$acceptance_user" ]]; then
            [[ "$start" == "$subid_start" && "$count" == "$subid_count" ]] \
                || fail "$acceptance_user has an unexpected subordinate ID range in $file."
            found=1
            continue
        fi

        if (( start <= subid_end && end >= subid_start )); then
            fail "The approved subordinate ID range overlaps an existing entry in $file."
        fi
    done < "$file"

    printf '%s' "$found"
}

if ! getent passwd "$acceptance_user" >/dev/null; then
    [[ ! -e "$acceptance_home" ]] || fail "$acceptance_home exists without the dedicated account; inspect it before proceeding."
    useradd --system --user-group --home-dir "$acceptance_home" --create-home \
        --shell /usr/sbin/nologin --comment "AgentForge acceptance runner" "$acceptance_user"
fi

IFS=: read -r _ _ uid gid _ home shell < <(getent passwd "$acceptance_user")
[[ "$uid" -gt 0 ]] || fail "The acceptance identity must not be root."
[[ "$home" == "$acceptance_home" ]] || fail "The acceptance account has an unexpected home directory."
[[ "$shell" == "/usr/sbin/nologin" ]] || fail "The acceptance account must use /usr/sbin/nologin."
[[ "$(id -Gn "$acceptance_user")" == "$acceptance_user" ]] \
    || fail "The acceptance account must not belong to supplementary groups."
[[ -d "$acceptance_home" && ! -L "$acceptance_home" ]] || fail "The acceptance home is not a real directory."
[[ "$(stat -c '%u:%g' "$acceptance_home")" == "$uid:$gid" ]] || fail "The acceptance home has unexpected ownership."
chmod 0700 "$acceptance_home"

subuid_found="$(check_subid_range /etc/subuid)"
subgid_found="$(check_subid_range /etc/subgid)"
if [[ "$subuid_found" == 0 ]]; then
    usermod --add-subuids "${subid_start}-${subid_end}" "$acceptance_user"
fi
if [[ "$subgid_found" == 0 ]]; then
    usermod --add-subgids "${subid_start}-${subid_end}" "$acceptance_user"
fi

grep -Fxq "${acceptance_user}:${subid_start}:${subid_count}" /etc/subuid \
    || fail "The expected subordinate UID mapping was not configured."
grep -Fxq "${acceptance_user}:${subid_start}:${subid_count}" /etc/subgid \
    || fail "The expected subordinate GID mapping was not configured."

printf 'Acceptance identity ready: %s (uid=%s, gid=%s)\n' "$acceptance_user" "$uid" "$gid"
printf 'Private home: %s (mode 0700)\n' "$acceptance_home"
printf 'Subordinate UID/GID range: %s:%s\n' "$subid_start" "$subid_count"
printf '%s\n' "No Docker, AppArmor, sysctl, or persistent service configuration was changed."
