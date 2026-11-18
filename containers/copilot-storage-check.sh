#!/usr/bin/env bash
set -uo pipefail

fail() {
    printf 'FAIL: Copilot storage policy: %s\n' "$1" >&2
    return 1
}

contains_github_token() {
    local path="$1"
    local status

    if grep --recursive --files-with-matches --binary-files=without-match \
        --extended-regexp \
        'gh[pousr]_[[:alnum:]]{20,}|github_pat_[[:alnum:]_]{20,}' \
        "$path" >/dev/null 2>&1; then
        fail "GitHub token-like content found under a protected path"
        return 1
    else
        status=$?
        if (( status != 1 )); then
            fail "unable to inspect a protected path"
            return 1
        fi
    fi
}

contains_auth_settings() {
    local path="$1"
    local status

    if grep --recursive --files-with-matches --binary-files=without-match \
        --include='*.json' --include='*.yaml' --include='*.yml' --exclude='*.schema.json' \
        --ignore-case --extended-regexp \
        '"[^"]*(access|refresh|oauth|copilot|github)[_-]?(token|credential|account)[^"]*"[[:space:]]*:|^[[:space:]]*(access|refresh|oauth|copilot|github)[_-]?(token|credential|account)[[:space:]]*:|"signed[_-]?in[_-]?accounts"[[:space:]]*:|^[[:space:]]*signed[_-]?in[_-]?accounts[[:space:]]*:' \
        "$path" >/dev/null 2>&1; then
        fail "authentication-token setting found under a protected path"
        return 1
    else
        status=$?
        if (( status != 1 )); then
            fail "unable to inspect structured authentication settings"
            return 1
        fi
    fi
}

check_private_path() {
    local path="$1"
    local owner mode

    [[ ! -L "$path" ]] || { fail "symbolic link found in persistent session state"; return 1; }
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" \
        || { fail "unable to inspect persistent state ownership"; return 1; }
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" \
        || { fail "unable to inspect persistent state permissions"; return 1; }
    [[ "$owner" == "$EUID" ]] \
        || { fail "persistent state must be owned by the workstation user"; return 1; }
    (( (8#$mode & 077) == 0 )) \
        || { fail "persistent state must not grant group or other permissions"; return 1; }
}

check_private_tree() {
    local root="$1"
    local path

    check_private_path "$root" || return 1
    while IFS= read -r -d '' path; do
        check_private_path "$path" || return 1
    done < <(find "$root" -mindepth 1 -print0 2>/dev/null)
}

has_forbidden_auth_name() {
    local path="$1"
    local match

    if ! match="$(find "$path" \
        \( -iname 'config.json' \
        -o -iname 'auth.json' \
        -o -iname '*auth*.json' \
        -o -iname 'credentials.json' \
        -o -iname 'token.json' \
        -o -iname '*account*.json' \
        -o -iname 'copilot-auth.json' \
        -o -iname 'github-copilot.json' \
        -o -iname 'mcp-config.json' \
        -o -iname 'logs' \
        -o -iname '*credential*' \
        -o -iname '*secret*' \
        -o -iname '*token*' \) \
        -print -quit 2>/dev/null)"; then
        fail "unable to inspect persistent session paths"
        return 1
    fi
    if [[ -n "$match" ]]; then
        fail "authentication, configuration, or log artifact name found in persistent session data"
        return 1
    fi
}

check_settings() {
    local settings="$1"

    [[ -f "$settings" && ! -L "$settings" ]] \
        || { fail "approved settings file is missing or is not a regular file"; return 1; }

    if grep --ignore-case --extended-regexp \
        '"[^"]*(auth|token|credential|password|secret)[^"]*"[[:space:]]*:' \
        "$settings" >/dev/null 2>&1; then
        fail "authentication-like setting key found in persistent settings"
        return 1
    fi

    if command -v node >/dev/null 2>&1 \
        && ! node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$settings" >/dev/null 2>&1; then
        fail "persistent settings are not valid JSON"
        return 1
    fi

    contains_auth_settings "$settings" || return 1
    contains_github_token "$settings"
}

check_session_directory() {
    local sessions="$1"

    [[ -d "$sessions" && ! -L "$sessions" ]] \
        || { fail "persistent session-state directory is missing or invalid"; return 1; }
    check_private_tree "$sessions" || return 1
    if find "$sessions" -type l -print -quit 2>/dev/null | grep --quiet .; then
        fail "symbolic links are not allowed in persistent session data"
        return 1
    fi
    has_forbidden_auth_name "$sessions" || return 1
    contains_auth_settings "$sessions" || return 1
    contains_github_token "$sessions"
}

check_state_root() {
    local root="$1"
    local entry

    [[ -d "$root" && ! -L "$root" ]] \
        || { fail "persistent state root is missing or invalid"; return 1; }
    check_private_path "$root" || return 1

    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "${entry##*/}" in
            settings.json|session-state|session-store.db) ;;
            *) fail "unexpected file or directory in persistent state root"; return 1 ;;
        esac
    done

    [[ -f "$root/session-store.db" && ! -L "$root/session-store.db" ]] \
        || { fail "persistent session index is missing or invalid"; return 1; }
    check_private_path "$root/session-store.db" || return 1
    check_private_path "$root/settings.json" || return 1
    check_settings "$root/settings.json" || return 1
    check_session_directory "$root/session-state" || return 1
    contains_github_token "$root/session-store.db"
}

check_mounted_state() {
    local settings="$1"
    local sessions="$2"
    local session_db="$3"

    check_settings "$settings" || return 1
    check_private_path "$settings" || return 1
    check_session_directory "$sessions" || return 1
    [[ -f "$session_db" && ! -L "$session_db" ]] \
        || { fail "persistent session index mount is missing or invalid"; return 1; }
    check_private_path "$session_db" || return 1
    contains_github_token "$session_db"
}

check_workspace_or_cache() {
    local root="$1"
    local match

    [[ -d "$root" ]] || return 0
    if ! match="$(find "$root" \
        \( -name .copilot \
        -o -path '*/.config/github-copilot' \
        -o -iname 'auth.json' \
        -o -iname 'credentials.json' \
        -o -iname 'token.json' \
        -o -iname 'copilot-auth.json' \
        -o -iname 'github-copilot.json' \) \
        -print -quit 2>/dev/null)"; then
        fail "unable to inspect workspace or cache for Copilot authentication files"
        return 1
    fi
    if [[ -n "$match" ]]; then
        fail "Copilot authentication path or file found in workspace or cache"
        return 1
    fi
    contains_auth_settings "$root" || return 1
    contains_github_token "$root"
}

check_runtime_cache() {
    local root="$1"
    local match

    [[ -d "$root" ]] || return 0
    if ! match="$(find "$root" \
        \( -name .copilot \
        -o -path '*/.config/github-copilot' \
        -o -iname 'config.json' \
        -o -iname 'auth.json' \
        -o -iname 'credentials.json' \
        -o -iname 'token.json' \
        -o -iname '*auth*.json' \
        -o -iname '*credential*' \
        -o -iname '*secret*' \
        -o -iname '*token*' \) \
        -print -quit 2>/dev/null)"; then
        fail "unable to inspect the Copilot runtime cache"
        return 1
    fi
    if [[ -n "$match" ]]; then
        fail "authentication artifact name found in the Copilot runtime cache"
        return 1
    fi
    contains_github_token "$root"
}

case "${1:-}" in
    state-root)
        [[ $# == 2 ]] || { fail "usage: copilot-storage-check state-root PATH"; exit 2; }
        check_state_root "$2"
        ;;
    mounted-state)
        [[ $# == 4 ]] || { fail "usage: copilot-storage-check mounted-state SETTINGS SESSIONS SESSION_DB"; exit 2; }
        check_mounted_state "$2" "$3" "$4"
        ;;
    workspace-cache)
        [[ $# -ge 2 ]] || { fail "usage: copilot-storage-check workspace-cache PATH..."; exit 2; }
        shift
        for root in "$@"; do
            check_workspace_or_cache "$root" || exit 1
        done
        ;;
    runtime-cache)
        [[ $# == 2 ]] || { fail "usage: copilot-storage-check runtime-cache PATH"; exit 2; }
        check_runtime_cache "$2"
        ;;
    *)
        fail "usage: copilot-storage-check {state-root PATH|mounted-state SETTINGS SESSIONS SESSION_DB|workspace-cache PATH...}"
        exit 2
        ;;
esac
