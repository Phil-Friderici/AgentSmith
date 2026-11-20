#!/usr/bin/env bash
set -Eeuo pipefail

readonly acceptance_user="agentforge-acceptance"
readonly acceptance_uid="999"
readonly acceptance_gid="987"
readonly acceptance_home="/var/lib/agentforge-acceptance"
readonly runtime_relative="agentforge-acceptance/999/phase5a"
readonly runtime_dir="/run/${runtime_relative}"
readonly socket_path="${runtime_dir}/podman.sock"
readonly storage_root="${acceptance_home}/podman-storage"
readonly service_unit="agentforge-acceptance-phase5a-podman.service"
readonly probe_unit="agentforge-acceptance-phase5a-delegation-probe"
readonly podman="/usr/bin/podman"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

require_root() {
    (( EUID == 0 )) || fail "Run this helper with sudo."
}

verify_identity() {
    local uid gid groups
    uid="$(id -u "$acceptance_user")"
    gid="$(id -g "$acceptance_user")"
    groups="$(id -Gn "$acceptance_user")"
    [[ "$uid" == "$acceptance_uid" ]] || fail "Unexpected acceptance UID: $uid."
    [[ "$gid" == "$acceptance_gid" ]] || fail "Unexpected acceptance GID: $gid."
    [[ "$groups" == "$acceptance_user" ]] || fail "The acceptance identity has supplementary groups."
}

verify_delegation() {
    local unit="$1"
    local control_group cgroup_path owner

    [[ "$(systemctl show "$unit" -p Delegate --value)" == "yes" ]] \
        || fail "$unit does not have Delegate=yes."
    control_group="$(systemctl show "$unit" -p ControlGroup --value)"
    [[ "$control_group" == /system.slice/* ]] || fail "Unexpected delegated cgroup path: $control_group."
    cgroup_path="/sys/fs/cgroup${control_group}"
    owner="$(stat -c '%u:%g' "$cgroup_path")"
    [[ "$owner" == "${acceptance_uid}:${acceptance_gid}" ]] \
        || fail "Delegated cgroup has unexpected ownership: $owner."
    printf 'delegated_cgroup=%s owner=%s\n' "$cgroup_path" "$owner"
}

probe_delegated_cgroup() {
    systemd-run \
        --unit="$probe_unit" \
        --collect \
        --wait \
        --pipe \
        --property="User=${acceptance_user}" \
        --property="Group=${acceptance_user}" \
        --property="Delegate=yes" \
        --property="RuntimeDirectory=${runtime_relative}-probe" \
        --property="RuntimeDirectoryMode=0700" \
        --property="RuntimeMaxSec=30s" \
        --property="Environment=HOME=${acceptance_home}" \
        --property="Environment=XDG_RUNTIME_DIR=/run/${runtime_relative}-probe" \
        /usr/bin/bash -c '
            set -eu
            relative="$$(cut -d: -f3 /proc/self/cgroup)"
            case "$$relative" in
                /system.slice/agentforge-acceptance-phase5a-delegation-probe.service) ;;
                *) printf "Unexpected cgroup path: %s\n" "$$relative" >&2; exit 1 ;;
            esac
            cgroup="/sys/fs/cgroup$${relative}"
            owner="$$(stat -c "%u:%g" "$$cgroup")"
            [[ "$$owner" == "999:987" ]]
            child="$${cgroup}/agentforge-delegation-probe"
            mkdir "$$child"
            rmdir "$$child"
            printf "acceptance_uid=999 delegated_cgroup=%s child_cgroup=create/remove passed\n" "$$cgroup"
        '
}

verify_service() {
    local pid socket_metadata runtime_metadata

    verify_delegation "$service_unit"
    pid="$(systemctl show "$service_unit" -p MainPID --value)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "0" ]] || fail "Podman API service has no main process."
    [[ "$(ps -o uid= -p "$pid" | tr -d ' ')" == "$acceptance_uid" ]] \
        || fail "Podman API service is not running as the acceptance identity."

    runtime_metadata="$(stat -c '%u:%g:%a' "$runtime_dir")"
    [[ "$runtime_metadata" == "${acceptance_uid}:${acceptance_gid}:700" ]] \
        || fail "Runtime directory has unexpected ownership or mode: $runtime_metadata."
    socket_metadata="$(stat -c '%u:%g:%a' "$socket_path")"
    [[ "$socket_metadata" == "${acceptance_uid}:${acceptance_gid}:600" ]] \
        || fail "Podman socket has unexpected ownership or mode: $socket_metadata."

    if ss -H -ltnp 2>/dev/null | grep -Fq "pid=${pid},"; then
        fail "Podman API service has a TCP listener."
    fi

    runuser --user "$acceptance_user" -- \
        curl --fail --silent --show-error --unix-socket "$socket_path" http://d/_ping >/dev/null
    printf 'podman_socket=%s mode=0600 owner=%s:%s unix_api=responsive\n' \
        "$socket_path" "$acceptance_uid" "$acceptance_gid"
}

cleanup_failed_start() {
    local status=$?
    trap - EXIT
    if (( status != 0 )) && systemctl is-active --quiet "$service_unit"; then
        systemctl stop "$service_unit" || true
    fi
}

start_service() {
    trap cleanup_failed_start EXIT
    systemctl is-active --quiet "$service_unit" && fail "The Phase 5a Podman service is already active."
    [[ ! -e "$runtime_dir" ]] || fail "Runtime directory already exists; inspect it before starting."

    if [[ -e "$storage_root" ]]; then
        [[ -d "$storage_root" && ! -L "$storage_root" ]] || fail "Podman storage path is not a real directory."
        [[ "$(stat -c '%u:%g:%a' "$storage_root")" == "${acceptance_uid}:${acceptance_gid}:700" ]] \
            || fail "Podman storage path has unexpected ownership or mode."
    else
        install -d -o "$acceptance_uid" -g "$acceptance_gid" -m 0700 "$storage_root"
    fi

    verify_identity
    probe_delegated_cgroup

    systemd-run \
        --unit="$service_unit" \
        --collect \
        --property="User=${acceptance_user}" \
        --property="Group=${acceptance_user}" \
        --property="Delegate=yes" \
        --property="RuntimeDirectory=${runtime_relative}" \
        --property="RuntimeDirectoryMode=0700" \
        --property="RuntimeDirectoryPreserve=no" \
        --property="RuntimeMaxSec=2h" \
        --property="UMask=0077" \
        --property="Environment=HOME=${acceptance_home}" \
        --property="Environment=XDG_RUNTIME_DIR=${runtime_dir}" \
        "$podman" \
        --runtime=/usr/bin/runc \
        --cgroup-manager=cgroupfs \
        --runroot="${runtime_dir}/containers" \
        --root="$storage_root" \
        system service --time=0 "unix://${socket_path}"

    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -S "$socket_path" ]] && break
        if ! systemctl is-active --quiet "$service_unit"; then
            systemctl status "$service_unit" --no-pager >&2 || true
            fail "Transient Podman API service exited before creating its socket."
        fi
        sleep 0.1
    done
    [[ -S "$socket_path" ]] || fail "Timed out waiting for the Podman API socket."

    verify_service
    trap - EXIT
}

stop_service() {
    if systemctl is-active --quiet "$service_unit"; then
        systemctl stop "$service_unit"
    fi
    systemctl reset-failed "$service_unit" >/dev/null 2>&1 || true
    [[ ! -e "$runtime_dir" ]] || fail "Transient runtime directory remains after stopping the service."
    printf 'stopped=%s runtime_directory_removed=yes\n' "$service_unit"
}

status_service() {
    systemctl is-active --quiet "$service_unit" || fail "The Phase 5a Podman service is not active."
    verify_service
}

require_root
case "${1:-}" in
    start) start_service ;;
    stop) stop_service ;;
    status) status_service ;;
    *) fail "Usage: $0 {start|status|stop}" ;;
esac
