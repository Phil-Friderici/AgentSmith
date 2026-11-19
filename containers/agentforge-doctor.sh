#!/usr/bin/env bash
set -uo pipefail

failures=0
level="${AGENTFORGE_LEVEL:-unknown}"

report() {
    local status="$1"
    local name="$2"
    local detail="$3"
    printf '%-9s %-25s %s\n' "$status" "$name" "$detail"
    if [[ "$status" == "FAIL" ]]; then
        failures=$((failures + 1))
    fi
}

check_tool() {
    local label="$1"
    local command_name="$2"
    local phase="$3"
    shift 3

    if ! command -v "$command_name" >/dev/null 2>&1; then
        report "DEFERRED" "$label" "not installed; planned for $phase"
        return
    fi

    local output
    if output=$("$@" 2>/dev/null); then
        output="${output%%$'\n'*}"
        report "PASS" "$label" "${output:-installed}"
    else
        report "WARN" "$label" "installed; version check did not succeed"
    fi
}

check_required_tool() {
    local label="$1"
    local command_name="$2"
    shift 2

    if ! command -v "$command_name" >/dev/null 2>&1; then
        report "FAIL" "$label" "required tool is not installed"
        return
    fi

    local output
    if output=$("$@" 2>/dev/null); then
        output="${output%%$'\n'*}"
        report "PASS" "$label" "${output:-installed}"
    else
        report "FAIL" "$label" "required version check did not succeed"
    fi
}

check_ruby_gem() {
    local name="$1"
    local phase="$2"

    if command -v gem >/dev/null 2>&1 && gem list --local --exact "$name" 2>/dev/null | grep -Eq "^${name} \("; then
        report "PASS" "$name gem" "installed"
    else
        report "DEFERRED" "$name gem" "not installed; planned for $phase"
    fi
}

is_mountpoint() {
    local path="$1"
    awk -v target="$path" '$2 == target { found = 1 } END { exit !found }' /proc/mounts
}

is_tmpfs_mount() {
    local path="$1"
    awk -v target="$path" '$2 == target && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts
}

is_exec_tmpfs_mount() {
    local path="$1"
    awk -v target="$path" '
        $2 == target && $3 == "tmpfs" {
            count = split($4, options, ",")
            has_noexec = 0
            for (i = 1; i <= count; i++) {
                if (options[i] == "noexec") has_noexec = 1
            }
            if (!has_noexec) found = 1
        }
        END { exit !found }
    ' /proc/mounts
}

copilot_mounts_allowed() {
    awk '
        $2 ~ /^\/copilot\// \
        && $2 != "/copilot/settings.json" \
        && $2 != "/copilot/session-state" \
        && $2 != "/copilot/session-store.db" { invalid = 1 }
        END { exit invalid }
    ' /proc/mounts
}

copilot_has_no_submounts() {
    awk '$2 ~ /^\/copilot\// { invalid = 1 } END { exit invalid }' /proc/mounts
}

has_minimum_tmpfs_capacity() {
    local path="$1"
    local minimum_kib="$2"
    df -Pk "$path" 2>/dev/null \
        | awk -v minimum="$minimum_kib" 'NR == 2 { if ($2 >= minimum) adequate = 1 } END { exit !adequate }'
}

printf '%s\n' "AgentForge workstation diagnostic"
printf 'Permission profile: %s\n' "$level"
printf '%s\n' "Protected paths are checked for authentication artifacts; matched contents are never displayed."
printf '\n'

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == "24.04" ]]; then
        report "PASS" "Operating system" "Ubuntu 24.04"
    else
        report "FAIL" "Operating system" "expected Ubuntu 24.04"
    fi
else
    report "FAIL" "Operating system" "/etc/os-release is unavailable"
fi

check_required_tool "Git" git git --version
if [[ "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)" == "3.2.3" ]]; then
    report "PASS" "Ruby" "3.2.3"
else
    report "FAIL" "Ruby" "expected version 3.2.3"
fi
if [[ "$(bundle --version 2>/dev/null || true)" == "Bundler version 2.4.20" ]]; then
    report "PASS" "Bundler" "2.4.20"
else
    report "FAIL" "Bundler" "expected version 2.4.20"
fi
if [[ "$(pdk --version 2>/dev/null || true)" == "4.0.1" ]]; then
    report "PASS" "PDK" "4.0.1"
else
    report "FAIL" "PDK" "expected version 4.0.1"
fi
check_tool "GitHub CLI" gh "Phase 5" gh --version
check_tool "Docker CLI" docker "a separately approved extension" docker --version
check_tool "Puppet Agent" puppet "Phase 4 after its version is approved" puppet --version
check_ruby_gem "litmus" "Phase 6"
check_ruby_gem "beaker" "Phase 6"

if ! command -v copilot >/dev/null 2>&1; then
    report "FAIL" "Copilot CLI" "required Phase 3 tool is not installed"
elif copilot_version="$(copilot --version 2>/dev/null)" \
    && [[ "$copilot_version" == *"GitHub Copilot CLI 1.0.112."* ]]; then
    report "PASS" "Copilot CLI" "1.0.112"
else
    report "FAIL" "Copilot CLI" "expected version 1.0.112"
fi

if [[ "$(node --version 2>/dev/null || true)" == "v22.23.5" ]]; then
    report "PASS" "Node.js" "v22.23.5"
else
    report "FAIL" "Node.js" "expected v22.23.5"
fi

if [[ "${COPILOT_AUTO_UPDATE:-}" == "false" ]]; then
    report "PASS" "Copilot updates" "automatic CLI and plugin updates disabled"
else
    report "FAIL" "Copilot updates" "COPILOT_AUTO_UPDATE must be false"
fi

if [[ "${COPILOT_HOME:-}" == "/copilot" ]] \
    && [[ -d /copilot && -w /copilot ]] \
    && is_tmpfs_mount /copilot; then
    report "PASS" "Copilot home" "mounted as writable ephemeral storage"
else
    report "FAIL" "Copilot home" "expected writable ephemeral /copilot"
fi

if (( EUID == 0 )); then
    report "FAIL" "Container identity" "workstation must run as a non-root user"
else
    report "PASS" "Container identity" "uid=$EUID"
fi

if [[ -d /workspace && -r /workspace ]]; then
    case "$level" in
        0)
            if [[ -w /workspace ]]; then
                report "FAIL" "Workspace mount" "Level 0 workspace must be read-only"
            else
                report "PASS" "Workspace mount" "readable and read-only"
            fi
            ;;
        1)
            if [[ -w /workspace ]]; then
                report "PASS" "Workspace mount" "readable and writable"
            else
                report "FAIL" "Workspace mount" "Level 1 workspace must be writable"
            fi
            ;;
        *)
            report "WARN" "Workspace mount" "profile not set to 0 or 1; mount is readable"
            ;;
    esac
else
    report "FAIL" "Workspace mount" "/workspace is missing or unreadable"
fi

if [[ -d /tmp && -w /tmp ]] && is_tmpfs_mount /tmp && has_minimum_tmpfs_capacity /tmp 524288; then
    report "PASS" "Temporary storage" "writable 512 MiB ephemeral tmpfs"
else
    report "FAIL" "Temporary storage" "/tmp must be a writable tmpfs of at least 512 MiB"
fi

if [[ "$level" == "0" || "$level" == "1" ]]; then
    if [[ "$level" == "0" ]] \
        && [[ "${COPILOT_CACHE_HOME:-}" == "/tmp/copilot-cache" ]]; then
        report "PASS" "Copilot cache" "ephemeral under non-executable /tmp"
    elif [[ "$level" == "1" ]] \
        && [[ "${COPILOT_CACHE_HOME:-}" == "/copilot-cache" ]] \
        && [[ -d /copilot-cache && -w /copilot-cache ]] \
        && is_exec_tmpfs_mount /copilot-cache \
        && has_minimum_tmpfs_capacity /copilot-cache 524288; then
        report "PASS" "Copilot cache" "dedicated writable 512 MiB executable tmpfs"
    else
        report "FAIL" "Copilot cache" "expected the profile's approved ephemeral cache mount"
    fi
fi

if [[ "$level" == "1" ]]; then
    if [[ -d /cache && -w /cache ]]; then
        report "PASS" "Cache mount" "writable"
    else
        report "FAIL" "Cache mount" "Level 1 requires a writable /cache mount"
    fi
else
    report "INFO" "Cache mount" "not required by the read-only profile"
fi

if [[ "$level" == "0" ]]; then
    report "PASS" "Network policy" "disabled by the Level 0 Compose profile"
elif [[ "$level" == "1" ]]; then
    report "INFO" "Network policy" "Compose network is configured; reachability was not probed"
else
    report "WARN" "Network policy" "unknown profile; inspect the Compose configuration"
fi

if [[ -S /var/run/docker.sock ]]; then
    report "FAIL" "Docker daemon access" "unexpected Docker socket is mounted"
else
    report "PASS" "Docker daemon access" "not exposed to the workstation by design"
fi

if [[ -e /etc/apt/auth.conf.d/puppet.conf \
    || -e /run/secrets/puppet_repo_credentials \
    || -n "${PUPPET_REPO_CREDENTIALS:-}" ]]; then
    report "FAIL" "Puppet credentials" "BuildKit credential must not exist in the runtime container"
else
    report "PASS" "Puppet credentials" "not present in runtime mounts, environment, or image"
fi

if [[ "$level" == "0" ]]; then
    if [[ "${COPILOT_OFFLINE:-}" == "true" ]] \
        && copilot_has_no_submounts \
        && ! is_mountpoint /copilot/settings.json \
        && ! is_mountpoint /copilot/session-state \
        && ! is_mountpoint /copilot/session-store.db; then
        report "PASS" "Level 0 Copilot" "offline with no persistent state mounts"
    else
        report "FAIL" "Level 0 Copilot" "must be offline and have no persistent state mounts"
    fi
elif [[ "$level" == "1" ]]; then
    if [[ -z "${COPILOT_OFFLINE:-}" ]] \
        && is_mountpoint /copilot/settings.json \
        && is_mountpoint /copilot/session-state \
        && is_mountpoint /copilot/session-store.db \
        && copilot_mounts_allowed \
        && [[ ! -w /copilot/settings.json && -w /copilot/session-state && -w /copilot/session-store.db ]]; then
        report "PASS" "Level 1 Copilot mounts" "approved settings and session paths only"
    else
        report "FAIL" "Level 1 Copilot mounts" "expected individual settings/session mounts with read-only settings"
    fi

    state_permissions_ok=true
    for path in /copilot/settings.json /copilot/session-state /copilot/session-store.db; do
        [[ ! -L "$path" ]] || state_permissions_ok=false
        owner="$(stat -c '%u' -- "$path" 2>/dev/null || true)"
        mode="$(stat -c '%a' -- "$path" 2>/dev/null || true)"
        [[ "$owner" == "$EUID" && -n "$mode" ]] || state_permissions_ok=false
        if [[ -n "$mode" ]] && (( (8#$mode & 077) != 0 )); then
            state_permissions_ok=false
        fi
    done
    if [[ "$state_permissions_ok" == true ]]; then
        report "PASS" "Copilot state permissions" "owner-only files and directories"
    else
        report "FAIL" "Copilot state permissions" "state mounts must be owned by the workstation user and owner-only"
    fi
else
    report "FAIL" "Copilot profile" "permission profile must be 0 or 1"
fi

if [[ "$level" == "1" ]]; then
    if /usr/local/bin/copilot-storage-check mounted-state \
        /copilot/settings.json /copilot/session-state /copilot/session-store.db \
        && /usr/local/bin/copilot-storage-check workspace-cache /workspace /cache \
        && /usr/local/bin/copilot-storage-check runtime-cache /copilot-cache; then
        report "PASS" "Copilot storage" "no authentication artifacts detected in persistent, workspace, or cache paths"
    else
        report "FAIL" "Copilot storage" "authentication artifact or invalid state detected; inspect paths without printing file contents"
    fi
else
    if /usr/local/bin/copilot-storage-check workspace-cache /workspace \
        && /usr/local/bin/copilot-storage-check runtime-cache /tmp/copilot-cache; then
        report "PASS" "Copilot storage" "no authentication artifacts detected in workspace or cache"
    else
        report "FAIL" "Copilot storage" "authentication artifact detected in workspace"
    fi
fi

report "INFO" "MCP" "disabled; no server or client configuration is loaded"

printf '\n'
if (( failures > 0 )); then
    printf 'Diagnostic failed: %d required check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '%s\n' "Diagnostic complete: all required workstation checks passed."
