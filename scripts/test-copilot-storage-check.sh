#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/containers/copilot-storage-check.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT

state="$temporary_root/state"
workspace="$temporary_root/workspace"
cache="$temporary_root/cache"
copilot_cache="$temporary_root/copilot-cache"
mkdir -p "$state/session-state" "$workspace/.github/copilot" "$cache" "$copilot_cache"
printf '{}\n' > "$state/settings.json"
: > "$state/session-store.db"
printf '{}\n' > "$workspace/.github/copilot/settings.json"

bash "$checker" state-root "$state"
bash "$checker" workspace-cache "$workspace" "$cache" "$copilot_cache"

mkdir -p "$workspace/.github/workflows"
cat > "$workspace/.github/workflows/ci.yml" <<'YAML'
permissions:
  contents: read
steps:
  - env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    run: echo "$GITHUB_TOKEN"
YAML
cat > "$workspace/example.rb" <<'RUBY'
token = ENV["GITHUB_TOKEN"]
RUBY
bash "$checker" workspace-cache "$workspace" "$cache"
rm -rf -- "$workspace/.github/workflows" "$workspace/example.rb"

printf '{"accessToken":{"type":"string"}}\n' > "$workspace/api.schema.json"
bash "$checker" workspace-cache "$workspace" "$cache"
rm -- "$workspace/api.schema.json"

touch "$state/config.json"
if bash "$checker" state-root "$state" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: persistent config.json was accepted" >&2
    exit 1
fi
rm -- "$state/config.json"

printf '{"accessToken":"placeholder"}\n' > "$state/settings.json"
if bash "$checker" state-root "$state" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: auth-like settings key was accepted" >&2
    exit 1
fi
printf '{}\n' > "$state/settings.json"

printf '%s\n' 'gho_TESTTOKENNOTREAL12345678901234567890' > "$state/session-state/events.jsonl"
if bash "$checker" state-root "$state" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: token-like session content was accepted" >&2
    exit 1
fi
rm -- "$state/session-state/events.jsonl"

printf '%s\n' 'ghp_0123456789abcdefghijklmnopqrstuvwxyz' > "$workspace/example.txt"
if bash "$checker" workspace-cache "$workspace" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: token-like workspace content was accepted" >&2
    exit 1
fi
rm -- "$workspace/example.txt"

mkdir "$workspace/.copilot"
touch "$workspace/.copilot/config.json"
if bash "$checker" workspace-cache "$workspace" "$cache" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: Copilot home in workspace was accepted" >&2
    exit 1
fi
rm -- "$workspace/.copilot/config.json"
rmdir "$workspace/.copilot"

printf '{"access_token":"placeholder"}\n' > "$cache/auth.json"
if bash "$checker" workspace-cache "$workspace" "$cache" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: authentication file in cache was accepted" >&2
    exit 1
fi
rm -- "$cache/auth.json"

printf '{"signedInAccounts":[]}\n' > "$cache/config.json"
if bash "$checker" workspace-cache "$workspace" "$cache" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: signed-in account state in cache was accepted" >&2
    exit 1
fi
rm -- "$cache/config.json"

printf '{"accessToken":{"type":"string"}}\n' > "$copilot_cache/api.schema.json"
bash "$checker" runtime-cache "$copilot_cache"
touch "$copilot_cache/auth.json"
if bash "$checker" runtime-cache "$copilot_cache" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: authentication file in the ephemeral Copilot cache was accepted" >&2
    exit 1
fi

printf '%s\n' "Copilot storage checks passed."
