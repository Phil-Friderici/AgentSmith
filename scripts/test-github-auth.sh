#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
image="${AGENTFORGE_LEVEL1_TEST_IMAGE:-agentforge-workstation-level1:local}"
level0_image="${AGENTFORGE_LEVEL0_TEST_IMAGE:-agentforge-workstation:local}"

for command_name in docker python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Required test command is unavailable: %s\n' "$command_name" >&2
        exit 1
    fi
done
if ! docker image inspect "$image" >/dev/null 2>&1; then
    printf 'Level 1 image is unavailable: %s\n' "$image" >&2
    exit 1
fi
if ! docker image inspect "$level0_image" >/dev/null 2>&1; then
    printf 'Level 0 image is unavailable: %s\n' "$level0_image" >&2
    exit 1
fi

temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT
mkdir -p "$temporary_root/workspace" "$temporary_root/cache" "$temporary_root/copilot/session-state"
printf '{}\n' > "$temporary_root/copilot/settings.json"
touch "$temporary_root/copilot/session-store.db"
chmod 700 "$temporary_root/copilot" "$temporary_root/copilot/session-state"
chmod 600 "$temporary_root/copilot/settings.json" "$temporary_root/copilot/session-store.db"

mock_gh="$temporary_root/gh"
cat > "$mock_gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    printf 'gh version 2.105.0 (auth-test mock)\n'
    exit 0
fi

[[ "${GH_TOKEN:-}" == "github_pat_test_only_abcdefghijklmnopqrstuvwxyz0123456789" ]]
[[ "${GITHUB_TOKEN+x}" == "" ]]
[[ "${GH_ENTERPRISE_TOKEN+x}" == "" ]]
[[ "${GITHUB_ENTERPRISE_TOKEN+x}" == "" ]]
[[ "${GH_HOST+x}" == "" ]]
[[ "${GH_REPO+x}" == "" ]]
[[ "${GH_CONFIG_DIR:-}" == "/tmp/agentforge-gh/config" ]]
[[ ! -e "$GH_CONFIG_DIR/hosts.yml" ]]
printf '%s\n' "mock-gh-authenticated"
MOCK
chmod 0555 "$mock_gh"

env -u PUPPET_REPO_CREDENTIALS \
    -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    -u GH_HOST -u GH_REPO \
    HOST_UID="$(id -u)" \
    HOST_GID="$(id -g)" \
    AGENTFORGE_WORKSPACE="$temporary_root/workspace" \
    AGENTFORGE_CACHE="$temporary_root/cache" \
    AGENTFORGE_COPILOT_STATE="$temporary_root/copilot" \
    python3 - "$repo_root" "$image" "$mock_gh" "$temporary_root" <<'PY'
import os
import pty
import select
import subprocess
import sys
import termios
import time

repo_root, image, mock_gh, temporary_root = sys.argv[1:]
pat = "github_pat_test_only_abcdefghijklmnopqrstuvwxyz0123456789"
prompt = b"Fine-grained GitHub PAT (input hidden):"

environment = os.environ.copy()
for name in (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
    "GH_HOST",
    "GH_REPO",
    "PUPPET_REPO_CREDENTIALS",
):
    environment.pop(name, None)

def run_container(command, store_pat=False, level=1):
    profile = "level1" if level == 1 else "level0"
    service = "agent-level1" if level == 1 else "agent-level0"
    docker_command = [
        "docker", "compose", "--profile", profile,
        "-f", os.path.join(repo_root, "compose", "compose.yaml"),
        "run", "--rm", "--no-deps",
    ]
    if level == 1:
        docker_command.extend(["-v", f"{mock_gh}:/usr/bin/gh:ro"])
    docker_command.extend([
        service, "bash", "-c", command,
    ])
    master, slave = pty.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    process = subprocess.Popen(
        docker_command,
        cwd=repo_root,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 180

    while True:
        if time.monotonic() > deadline:
            process.terminate()
            raise SystemExit("Docker authentication test timed out.")
        ready, _, _ = select.select([master], [], [], 0.25)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                output.extend(data)
        if store_pat and not sent and prompt in output:
            os.write(master, pat.encode("ascii") + b"\n")
            sent = True
        if process.poll() is not None:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    pass
            break
        if not store_pat and process.poll() is None:
            continue

    os.close(master)
    text = bytes(output).decode("utf-8", errors="replace")
    if pat in text:
        raise SystemExit("Test PAT appeared in terminal output or diagnostics.")
    if store_pat and not sent:
        raise SystemExit("Hidden PAT prompt was not reached.")
    if process.returncode != 0:
        print(text, file=sys.stderr)
        raise SystemExit(f"Docker authentication test failed with status {process.returncode}.")
    return text

session_a = run_container(
    "set -e; "
    "agentforge-gh-auth store; "
    "agentforge-gh-auth status; "
    "test \"$(stat -c %a /tmp/agentforge-gh/pat)\" = 600; "
    "agentforge-doctor; "
    "env GH_TOKEN=ignored GITHUB_TOKEN=ignored GH_HOST=example.invalid "
    "GH_REPO=attacker/repository agentforge-gh repo view Phil-Friderici/puppetlabs-mysql; "
    "agentforge-gh-auth clear; "
    "agentforge-gh-auth status",
    store_pat=True,
)
for expected in (
    "PAT stored for this container lifetime.",
    "PAT stored in ephemeral storage (mode 0600).",
    "GitHub PAT storage",
    "mock-gh-authenticated",
    "PAT cleared.",
    "PAT not stored.",
):
    if expected not in session_a:
        raise SystemExit(f"Authentication test output lacked expected status: {expected}")

session_b = run_container(
    "set -e; "
    "agentforge-gh-auth store; "
    "agentforge-gh-auth status; "
    "test \"$(stat -c %a /tmp/agentforge-gh/pat)\" = 600; "
    "rm /tmp/agentforge-gh/pat; "
    "ln -s /etc/passwd /tmp/agentforge-gh/pat; "
    "if agentforge-gh-auth status >/dev/null 2>&1; then exit 1; fi; "
    "agentforge-gh-auth clear; "
    "agentforge-gh-auth status",
    store_pat=True,
)
if "PAT stored in ephemeral storage (mode 0600)." not in session_b:
    raise SystemExit("PAT did not survive the current container lifetime.")
if "PAT not stored." not in session_b:
    raise SystemExit("PAT helper did not reject and clear a symlinked storage file.")

session_c = run_container(
    "set -e; "
    "agentforge-gh-auth status; "
    "test ! -e /tmp/agentforge-gh/pat",
)
if "PAT not stored." not in session_c:
    raise SystemExit("PAT state remained after container recreation.")

level0_output = run_container(
    "set -e; "
    "! command -v gh; "
    "test ! -e /usr/local/bin/agentforge-gh-auth; "
    "test ! -e /usr/local/lib/agentforge-gh-auth.rb; "
    "test ! -e /tmp/agentforge-gh/pat",
    level=0,
)
if "GitHub CLI" not in level0_output:
    raise SystemExit("Level 0 diagnostic did not run.")

print("GitHub authentication foundation checks passed with a synthetic PAT and mocked gh.")
PY
