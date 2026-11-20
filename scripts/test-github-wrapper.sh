#!/usr/bin/env bash
set -Eeuo pipefail

image="${AGENTFORGE_LEVEL1_TEST_IMAGE:-agentforge-workstation-level1:local}"
if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "Docker is required to test the GitHub wrapper." >&2
    exit 1
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
    printf 'Level 1 image is unavailable: %s\n' "$image" >&2
    exit 1
fi

temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT
allowlist="$temporary_root/github-allowlist.yml"
mock_gh="$temporary_root/gh"

cat > "$allowlist" <<'YAML'
github:
  allowed_repositories:
    - Phil-Friderici/AgentSmith
YAML

cat > "$mock_gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

[[ "${GH_TOKEN:-}" == "" ]]
[[ "${GITHUB_TOKEN:-}" == "" ]]
[[ "${GH_ENTERPRISE_TOKEN:-}" == "" ]]
[[ "${GITHUB_ENTERPRISE_TOKEN:-}" == "" ]]
[[ "${GH_HOST+x}" == "" ]]
[[ "${GH_REPO+x}" == "" ]]
[[ "${GH_DEBUG+x}" == "" ]]
[[ "${GH_CONFIG_DIR:-}" == "/tmp/agentforge-gh/config" ]]

printf 'mock-gh'
printf '|%s' "$@"
printf '\n'
MOCK

chmod 0444 "$allowlist"
chmod 0555 "$mock_gh"

run_wrapper() {
    docker run --rm \
        --network none \
        --read-only \
        --user "$(id -u):$(id -g)" \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --tmpfs /tmp:rw,nosuid,nodev,size=16m,mode=1777 \
        --mount "type=bind,src=$allowlist,dst=/etc/agentforge/github-allowlist.yml,readonly" \
        --mount "type=bind,src=$mock_gh,dst=/usr/bin/gh,readonly" \
        --env GH_CONFIG_DIR=/tmp/untrusted-config \
        --env GH_TOKEN=agentforge-wrapper-test-token \
        --env GITHUB_TOKEN=agentforge-wrapper-test-token \
        --env GH_ENTERPRISE_TOKEN=agentforge-wrapper-test-token \
        --env GITHUB_ENTERPRISE_TOKEN=agentforge-wrapper-test-token \
        --env GH_HOST=example.invalid \
        --env GH_REPO=untrusted/selection \
        --env GH_DEBUG=api \
        --entrypoint /bin/bash \
        "$image" \
        -c 'umask 077; mkdir -m 700 -p /tmp/agentforge-gh/config && exec /usr/local/bin/agentforge-gh "$@"' \
        agentforge-gh "$@"
}

contains_no_test_token() {
    [[ "$1" != *"agentforge-wrapper-test-token"* ]]
}

expect_success() {
    local expected="$1"
    shift
    local output

    if ! output="$(run_wrapper "$@" 2>&1)"; then
        printf '%s\n' "Expected the allowlisted wrapper invocation to succeed." >&2
        exit 1
    fi
    [[ "$output" == "$expected" ]] || {
        printf '%s\n' "Wrapper produced an unexpected command result." >&2
        exit 1
    }
    contains_no_test_token "$output" || {
        printf '%s\n' "Wrapper output exposed a test token." >&2
        exit 1
    }
}

expect_denied() {
    local output

    if output="$(run_wrapper "$@" 2>&1)"; then
        printf '%s\n' "Expected the wrapper invocation to be denied." >&2
        exit 1
    fi
    [[ "$output" != *"mock-gh"* ]] || {
        printf '%s\n' "A denied invocation reached GitHub CLI." >&2
        exit 1
    }
    contains_no_test_token "$output" || {
        printf '%s\n' "Wrapper output exposed a test token." >&2
        exit 1
    }
}

repository="Phil-Friderici/AgentSmith"
expect_success "mock-gh|repo|view|$repository" repo view "$repository"
expect_success "mock-gh|issue|list|--repo|$repository" issue list "$repository"
expect_success "mock-gh|issue|view|42|--repo|$repository" issue view "$repository" 42
expect_success "mock-gh|pr|list|--repo|$repository" pr list "$repository"
expect_success "mock-gh|pr|view|7|--repo|$repository" pr view "$repository" 7
expect_success "mock-gh|release|view|--repo|$repository" release view "$repository"
expect_success "mock-gh|release|view|v1.2.3|--repo|$repository" release view "$repository" v1.2.3

expect_denied repo view puppetlabs/puppetlabs-concat
expect_denied repo view phil-friderici/AgentSmith
expect_denied repo view "https://github.com/$repository"
expect_denied repo view 'Phil-Friderici/*'
expect_denied repo view "$repository" --hostname example.invalid
expect_denied issue view "$repository" --help
expect_denied release view "$repository" --latest
expect_denied api repos/"$repository"
expect_denied extension list
expect_denied workflow list
expect_denied secret list
expect_denied auth login
expect_denied pr create "$repository"

chmod 0644 "$allowlist"
printf 'github:\n  allowed_repositories: [\n' > "$allowlist"
chmod 0444 "$allowlist"
expect_denied repo view "$repository"

printf '%s\n' "GitHub wrapper checks passed."
