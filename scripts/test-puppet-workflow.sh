#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$repo_root/containers/agentforge-puppet.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT

workspace="$temporary_root/workspace"
cache="$temporary_root/cache"
temporary_config="$temporary_root/tmp/bundler-config"
bin="$temporary_root/bin"
trace="$temporary_root/commands.log"
mkdir -p "$workspace" "$cache" "$bin" "$temporary_root/tmp"

cat > "$bin/ruby" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == "-e print RUBY_VERSION" ]]; then
    printf '3.2.3'
else
    printf 'ruby 3.2.3\n'
fi
MOCK

cat > "$bin/bundle" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'Bundler version 2.4.20\n'
else
    printf 'bundle|%s|%s|%s|' "$BUNDLE_PATH" "$BUNDLE_USER_CACHE" "$BUNDLE_APP_CONFIG" >> "$AGENTFORGE_TEST_TRACE"
    printf ' <%s>' "$@" >> "$AGENTFORGE_TEST_TRACE"
    printf '\n' >> "$AGENTFORGE_TEST_TRACE"
fi
MOCK

cat > "$bin/pdk" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf '4.0.1\n'
    exit 0
fi
printf 'pdk' >> "$AGENTFORGE_TEST_TRACE"
printf ' <%s>' "$@" >> "$AGENTFORGE_TEST_TRACE"
printf '\n' >> "$AGENTFORGE_TEST_TRACE"
if [[ "${1:-}" == "new" && "${2:-}" == "module" ]]; then
    target="${@: -1}"
    mkdir -p "$target"
    printf '{}\n' > "$target/metadata.json"
    printf 'source "https://rubygems.org"\n' > "$target/Gemfile"
    printf '2.7.0\n' > "$target/.ruby-version"
fi
MOCK

chmod 755 "$bin/ruby" "$bin/bundle" "$bin/pdk"
export PATH="$bin:$PATH"
export AGENTFORGE_WORKSPACE_ROOT="$workspace"
export AGENTFORGE_CACHE_ROOT="$cache"
export AGENTFORGE_BUNDLER_CONFIG_ROOT="$temporary_config"
export AGENTFORGE_TEST_TRACE="$trace"

bash "$workflow" bootstrap example_module
module="$workspace/example_module"
[[ "$(cat "$module/.ruby-version")" == "3.2.3" ]]
bash "$workflow" toolchain "$module" >/dev/null
bash "$workflow" bundle-install "$module" >/dev/null
bash "$workflow" validate "$module" -- --parallel >/dev/null
bash "$workflow" unit "$module" -- --parallel >/dev/null

mkdir -p "$workspace/second_module"
printf '{}\n' > "$workspace/second_module/metadata.json"
printf 'source "https://rubygems.org"\n' > "$workspace/second_module/Gemfile"
printf '3.2.3\n' > "$workspace/second_module/.ruby-version"
bash "$workflow" bundle-install "$workspace/second_module" >/dev/null

[[ "$(grep -c '^bundle|' "$trace")" == "2" ]]

cache_a="$(grep '^bundle|' "$trace" | head -n 1 | cut -d '|' -f2)"
cache_b="$(grep '^bundle|' "$trace" | tail -n 1 | cut -d '|' -f2)"
[[ "$cache_a" != "$cache_b" ]]
[[ "$cache_a" == "$cache/bundler/"*/gems ]]
[[ "$cache_b" == "$cache/bundler/"*/gems ]]
[[ "$temporary_config" == "$temporary_root/tmp/"* ]]
grep --quiet 'pdk <validate> <--parallel>' "$trace"
grep --quiet 'pdk <test> <unit> <--parallel>' "$trace"
grep --quiet 'pdk <new> <module> <--skip-interview>' "$trace"

if AGENTFORGE_BUNDLER_CACHE_ROOT="$workspace/cache-root" bash "$workflow" bundle-install "$module" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: a Bundler cache outside the cache mount was accepted" >&2
    exit 1
fi
[[ ! -e "$workspace/cache-root" ]]
invalid_config_root="$repo_root/.agentforge-bundler-config-test-$$"
if AGENTFORGE_BUNDLER_CONFIG_ROOT="$invalid_config_root" bash "$workflow" bundle-install "$module" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: persistent Bundler application configuration was accepted" >&2
    exit 1
fi
[[ ! -e "$invalid_config_root" ]]

printf '3.1.0\n' > "$module/.ruby-version"
if bash "$workflow" toolchain "$module" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: an unsupported module Ruby version was accepted" >&2
    exit 1
fi

printf '%s\n' "Puppet workflow checks passed."
