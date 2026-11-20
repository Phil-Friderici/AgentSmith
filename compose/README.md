# Docker Compose

`compose.yaml` is the runtime orchestration entry point. It defines separate, explicit Level 0 and Level 1 services; neither is started by default. Neither service receives Puppet repository credentials, GitHub CLI credentials, or the Docker socket. Level 1 permits manually initiated ephemeral Copilot login; Level 0 is offline and has no persistent Copilot state.

## Build the PDK image

Building the image requires the external Puppet APT auth file. Use the build-only override, which grants the credential to BuildKit but does not add a runtime service secret:

```sh
export PUPPET_REPO_CREDENTIALS="/absolute/path/to/puppet-apt-auth.conf"
docker compose \
  -f compose/compose.yaml \
  -f compose/pdk-build.yaml \
  build agent-level1
unset PUPPET_REPO_CREDENTIALS
```

The Dockerfile mounts the BuildKit secret only while downloading the pinned PDK package. It installs that package in a later stage without the secret. The build context is restricted to `containers/`; project workspaces and caches are not sent to the builder. The normal runtime Compose file does not reference the credential path; do not include `pdk-build.yaml` when starting a session.

## Runtime topology

The workstation image is replaceable; repositories and selected rebuildable caches persist through host bind mounts outside its writable layer. Mount configuration read-only where possible. No ports are published.

Permission profiles correspond to actual capability changes: filesystem access, credentials, enabled tools, and network access. Compose profiles alone are not security controls. The default must not expose remote write credentials, broad host paths, or the Docker socket.

The host UID/GID must be supplied explicitly. Level 0 mounts the workspace read-only, has no network, and uses a read-only container filesystem. Level 1 mounts the workspace writable and uses the configured cache path, defaulting to `~/AgentForge/cache/agentforge/level1`; override it with a project- and trust-level-specific path. It has network access but no remote credentials. Both services drop all Linux capabilities, prohibit privilege escalation, and have no Docker socket. MCP is not configured or started in either profile.

No acceptance-testing profile currently exists. Proposed Phase 5 uses Litmus with an isolated rootless Podman provider, but no provider service, Podman socket, Docker socket, `/dev/kvm`, target image, or acceptance credential is configured. See [Puppet Acceptance Testing Design](../docs/acceptance-testing.md) and Proposed [ADR-0006](../docs/adr/0006-acceptance-testing-platform.md).

The disabled Phase 7a/7b maintainer broker uses a separate, opt-in Compose file and is not part of the workstation profiles:

```sh
docker compose -f compose/phase7a-broker.yaml --profile phase7a-broker run --rm maintainer-broker --self-check
```

This image is deny-by-default and reports no enabled operation or configured production control provider. Its profile has no network, host mounts, secrets, or workstation state; it is a foundation harness, not a maintainer-operation service. Run `scripts/test-maintainer-broker.sh` for unit and isolation checks.

Copilot CLI 1.0.112 is installed in the workstation image. Both profiles provide a 512 MiB `noexec` `/tmp` tmpfs for scratch data. Level 1 additionally uses a dedicated 512 MiB executable `/copilot-cache` tmpfs: the CLI's `cli-native` shared library must be executable-mappable, while general `/tmp` remains `noexec`. The diagnostic checks the dedicated mount type, absence of `noexec`, capacity, and storage contents. Level 0 keeps its cache under non-executable `/tmp`, is offline, and does not support Copilot login. Level 1 uses `COPILOT_HOME=/copilot` on tmpfs and `COPILOT_AUTO_UPDATE=false`; the operator initiates login manually. A dedicated host path, `~/AgentForge/state/copilot` by default, persists only `settings.json` (read-only), `session-state/`, and `session-store.db`, mounted individually. The entire host state directory and Copilot home are never bind-mounted.

Example:

```sh
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
export AGENTFORGE_WORKSPACE="$HOME/AgentForge/workspace"
mkdir -p "$AGENTFORGE_WORKSPACE"
docker compose -f compose/compose.yaml --profile level0 run --rm agent-level0
```

For Level 1, set a project-specific cache path before running:

```sh
export AGENTFORGE_CACHE="$HOME/AgentForge/cache/my-module/level1"
mkdir -p "$AGENTFORGE_CACHE"
docker compose -f compose/compose.yaml --profile level1 run --rm agent-level1
```

Create mount directories as the host user before starting Compose. Run both `scripts/init-workspace.sh` and `scripts/init-copilot-state.sh`; the latter creates and validates owner-only state paths and scans for known auth artifacts. Compose does not auto-create missing bind paths, avoiding root-owned directories that the mapped user cannot write.

The bind-mounted workspace is the persistent source of truth: files written there survive `docker compose run --rm` and image/container replacement. Container-local `/tmp`, `/copilot` (except the three explicit Level 1 state mounts), `/copilot-cache`, and the writable container layer are disposable. The host Level 1 development cache is separate from workspace/state, scoped by project and trust level, and must remain rebuildable and credential-free. The Copilot runtime cache is ephemeral tmpfs, not persistent. Session data is a separate sensitive state class and requires owner-only permissions and retention/cleanup controls.

Inside Level 1, use `agentforge-puppet` for module dependency and test operations. It derives a distinct Bundler cache path for each module under `/cache/bundler/`; do not rely on a shared `BUNDLE_PATH`.

The local Docker Compose version previously demonstrated that file-backed runtime secret `uid`, `gid`, and `mode` settings are ignored. AgentForge no longer uses runtime Compose secrets for Puppet package access. BuildKit secret behavior and private package access still require an authorized build on the target host.

See [Setup](../docs/setup.md) for first startup, [Operations](../docs/operations.md) for rebuild and persistence behavior, and [Troubleshooting](../docs/troubleshooting.md) for startup and package-access failures.
