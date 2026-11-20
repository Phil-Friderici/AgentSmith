# Architecture

## Status and scope

This document defines the architecture for AgentForge, a persistent local development workstation on Ubuntu 24.04. The Phase 2 container/Compose foundation and Phase 3 Copilot workstation are implemented; Puppet Agent and the acceptance-test toolchain remain deferred.

## System context

The human operator controls the Ubuntu host, Docker Engine, workspace directories, credential sources, and permission level. Docker Compose will coordinate the workstation container and any deliberately introduced supporting services. The agent runs within the workstation and interacts with repositories and external systems only through granted filesystem, network, CLI, and MCP capabilities.

```text
Operator
  ├── selects permission level and supplies operation-scoped credentials
  ├── Ubuntu 24.04 host
  │     ├── Docker Engine / Compose
  │     ├── persistent workspace (repositories and local state)
  │     ├── persistent cache (non-secret, rebuildable data)
  │     ├── persistent Copilot session/settings state (selected, non-secret)
  │     └── secret source (outside repository and image)
  └── AgentForge workstation container
        ├── Copilot CLI (Phase 3; Level 1, ephemeral authentication)
        ├── GitHub CLI (later phase; unauthenticated by default)
        ├── Git, Ruby, PDK, Puppet Agent, test tooling
        ├── MCP client configuration / approved MCP connections
        └── mounted workspace and selected cache paths
              └── GitHub, package repositories, test targets (as authorized)
```

The diagram is conceptual. Supporting services, MCP servers, network policy, and exact mount wiring are implementation decisions to be validated before they are introduced.

## Component responsibilities

### Host

The host provides Docker, Compose, durable storage, and the operator-controlled boundary for permissions and secrets. Host paths exposed to containers must be explicit and narrow. Host administration remains outside the agent's default capabilities.

### Workstation container

The intended baseline is one primary, unprivileged workstation container with the interactive agent and development toolchain. It should be replaceable: its filesystem is not the authoritative store for repositories or user work. It should run as a non-root user, have a defined working directory, and receive only the mounts and network access necessary for its active permission level.

The container image is for reproducible software and configuration, not credentials or user work. PDK is downloaded in a dedicated BuildKit stage with an external APT auth file mounted as a BuildKit secret for that command only. The package is installed in a separate stage without the secret. Puppet credentials must not enter build arguments, environment variables, image layers, image metadata, runtime configuration, or logs. Copilot authentication is a separate, operator-initiated runtime flow in Level 1; its state is transient and is never part of a persistent mount or image.

### MCP and external tools

MCP connections are an explicit capability surface, not an implicit administrator interface. Prefer a small allowlist of tools with narrow parameters and auditable results. GitHub CLI and Git operations use separate permission boundaries; giving an agent a tool does not authorize every operation that tool can perform.

### Persistent workspace and cache

The workspace is the durable home of repositories and their local working state. Cache paths may retain downloaded dependencies or other rebuildable data, but must be scoped, treated as potentially sensitive, and never used as a credential store. See [workspace layout](#workspace-layout).

## Lifecycle and persistence

1. The operator builds the workstation image with an explicitly supplied BuildKit secret, then starts it with a chosen permission profile and required workspace/cache mounts.
2. Repositories are cloned into the persistent workspace and checked out at operator-approved branches.
3. The agent reads or modifies those files according to its granted level.
4. Toolchain and test commands run inside the workstation. Acceptance tests may also interact with external targets and therefore require additional scrutiny.
5. On shutdown or image replacement, workspace and selected cache state remain; the container itself can be recreated.
6. The operator can revoke a permission by removing its mount, credential, tool, or network capability and recreating the environment.

Do not treat all process state as persistent. Temporary files, container writable layers, authentication state, and process logs may disappear. Persist only reviewed Copilot settings and selected session data, separately from authentication state, repositories, and caches.

## Workspace layout

The repository root reserves these areas:

| Path | Intended purpose | Persistence and handling |
| --- | --- | --- |
| `workspace/` | Documentation for the host-side root used by checked-out repositories and per-project working state. | Compose bind-mounts a host-managed path here at runtime. Runtime repository data should remain separate from this AgentForge repository. |
| `cache/` | Documentation for explicitly selected, rebuildable caches such as Bundler data. | Level 1 bind-mounts a selected host path. Cache contents are untrusted and may contain private project metadata; never store credentials here. |
| Host `~/AgentForge/state/copilot/` | Selected Copilot session history and approved, non-secret settings. | Contains only `settings.json`, `session-state/`, and `session-store.db`; owner-only permissions. Each item is mounted individually into the ephemeral Copilot home. |
| `containers/` | Container strategy and workstation image. | Contains the pinned Ubuntu/Git/Ruby/Bundler/PDK image and startup diagnostic; the PDK download stage receives a BuildKit secret, while the final image contains no credential. |
| `compose/` | Compose topology, profiles, mounts, and operational guidance. | Normal Level 0/1 services have no secrets or remote credentials; a build-only Compose overlay provides the external package credential to BuildKit. |
| `scripts/` | Operator-facing host setup helpers. | Initializers safely create and validate external workspace/cache and Copilot-state paths. |
| `docs/adr/` | Accepted, proposed, superseded, or rejected architecture decisions. | Version-controlled documentation. |

Within the future workspace root, use one directory per repository and avoid sharing a writable checkout between unrelated agents or permission profiles. If concurrent work becomes a requirement, isolate worktrees or clones and specify locking and cleanup behavior before enabling it.

### Host path and ownership

The default runtime workspace root is `~/AgentForge/workspace`, separate from the AgentForge source checkout. The default cache root is `~/AgentForge/cache`. Both paths are host-managed and may be overridden by the operator through runtime configuration; neither path should be committed to this repository as runtime data.

The workstation process should use the host user's UID/GID for bind-mounted files. Do not recursively change ownership of existing workspace content at startup. If the mounted paths are not writable/readable as required, fail with a clear permissions error and require the operator to correct ownership or configuration.

## Container strategy

The baseline is a single-purpose development container, not a fleet of privileged services. Keep the workstation container unprivileged and avoid host PID/network namespaces, privileged mode, broad host mounts, and the Docker socket. Add supporting containers only when a clear need exists and each can be isolated independently.

Build-time dependencies should be explicit and reproducible. The PDK image rebuild requires the external package credential, supplied only through a BuildKit secret mount; do not copy it into a layer or expose it in build arguments, environment variables, build output, or runtime configuration. Runtime workspace/cache mounts, user identity, and network policy remain separate from image construction.

Phase 5a has an opt-in validation implementation using Litmus and rootless Podman in a separate acceptance identity; four serial synthetic Puppet apply/assertion runs passed, controlled-failure cleanup passed, and a fresh subsequent run passed. Validation is complete for the synthetic Ubuntu target, while ADR-0006 remains Proposed pending the maintainers' decision. The normal workstation must not receive Docker or Podman sockets, `/dev/kvm`, cloud credentials, persistent Copilot authentication, or Puppet repository credentials. Beaker is a compatibility path for a concrete legacy module; EC2 is opt-in. See [Puppet Acceptance Testing Design](acceptance-testing.md) and the [Phase 5a validation report](phase5a-validation-report.md).

The current implementation uses one Ubuntu 24.04 image for two explicit Compose services: Level 0 mounts the workspace read-only, has no network, and uses a read-only root filesystem; Level 1 can write to the workspace and selected cache and has network access, but no remote-write credentials. Both run as the configured host UID/GID, drop all Linux capabilities, disallow privilege escalation, and health-check their required mounts. The host bind-mounted workspace is the durable source of repository state across container replacement.

The image installs Git, Ruby 3.2.3, Bundler 2.4.20, PDK 4.0.1 (`4.0.1.1-1noble` package), Node.js 22.23.5, and Copilot CLI 1.0.112. Node.js is SHA-256 verified per architecture, and npm dependencies are locked. The PDK package-download stage receives only the BuildKit secret; the final runtime image does not include Puppet repository credentials. GitHub CLI, Puppet Agent, Litmus, and Beaker remain uninstalled in the workstation image. Litmus 2.8.2 is pinned in the separate Phase 5a fixture; its rootless Podman provider candidate uses `--pids-limit=1024` and passed final synthetic-target validation. The private-package operation has not been tested with credentials. The image base digest and directly installed package versions are pinned in `containers/Dockerfile` and [Toolchain Versions](toolchain-versions.md).

## High-level Docker Compose design

The initial Compose topology has:

- A shared workstation image exposed through explicit Level 0 and Level 1 services.
- Named or explicit host-mounted persistent paths for workspace and selected caches.
- Read-only configuration mounts wherever possible.
- Optional profiles or separately invoked configurations for features that need additional providers or network access.
- No published ports unless a specific workflow requires one.
- No Docker socket mount and no privileged mode.
- No Puppet runtime secret mounts. The separate `pdk-build.yaml` overlay grants BuildKit-only access to the Puppet package credential during image build.
- An explicit permission profile that changes available capabilities rather than relying solely on prompt instructions.

Compose profiles may improve usability, but they are not a security boundary by themselves. Enforcement must include mounts, credentials, container identity, tool availability, and network access. Runtime Compose services do not declare Puppet credentials. BuildKit receives the external auth file only when the build-only override is used.

The baseline uses no GitHub CLI authentication and exposes no MCP server. Under ADR-0005, Level 1 Copilot authentication is initiated manually in `/copilot`, which is tmpfs. The CLI's `config.json` may contain signed-in account state and remains ephemeral. Only `settings.json` (read-only), `session-state/`, and `session-store.db` are bind-mounted individually from the dedicated host state path. Authentication files, logs, caches, and the rest of the Copilot home remain ephemeral. Level 1's native-addon cache uses a dedicated executable 512 MiB tmpfs at `/copilot-cache`; general `/tmp` remains `noexec`. Level 0 sets `COPILOT_OFFLINE=true`, has no persistent Copilot mounts, and has no network. `COPILOT_AUTO_UPDATE=false` disables automatic CLI and plugin updates.

The local baseline was validated with Docker Engine 29.9.3 and Docker Compose v5.7.1 on `linux/amd64`. Compose runtime secrets are not used. The BuildKit secret source is an external APT auth file; its contents are mounted read-only only in the package-download build command. Level 0 has no network; Level 1 uses the default Compose network for development and tests. Level 1 is not an isolation boundary for running untrusted project code.

## Version and cache policy

Pin the Ubuntu image and core toolchain to exact versions, recorded in [Toolchain Versions](toolchain-versions.md). Update pins deliberately after compatibility checks; do not resolve floating `latest` versions at build time. The base digest, Git/Ruby package pins, PDK package version, Puppet release package hash, source list, keyring, and no-unpinned-Agent preference are in `containers/Dockerfile`; the build secret is defined only in `compose/pdk-build.yaml`. Copilot CLI 1.0.112 and Node.js 22.23.5 are pinned, and automatic updates are disabled. GitHub CLI, Puppet Agent, Litmus, and Beaker remain uninstalled; proposed acceptance versions and provider compatibility must be established before implementation. PDK 4.0.1 has no declared Puppet Agent package dependency; Agent installation remains deferred until a module workflow establishes its version.

Persist only selected, rebuildable Ruby/Bundler and PDK caches under the host cache root. The Puppet workflow hashes each canonical module path to place Bundler gems and package cache in a distinct `/cache/bundler/<module-id>/` directory; Bundler application configuration remains under ephemeral `/tmp`. Scope host cache mounts by user, project, and trust level, and do not share writable caches across permission levels or unrelated trust domains. Do not persist credentials or general-purpose APT authentication/configuration in caches.

The in-container `agentforge-puppet` workflow performs pinned toolchain checks, PDK module bootstrap, Bundler dependency installation, PDK static validation, and unit tests. Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1 are fixed image versions. Puppet 8 is the recommended module target major, but module metadata and lockfiles define actual compatibility; the image does not install a global Puppet Agent without a module-specific version decision. This workflow does not provide GitHub remote-write authentication, Docker daemon access, MCP, Litmus, or Beaker.

## Toolchain and test strategy

The intended toolchain is Ubuntu 24.04, Docker, Docker Compose, GitHub Copilot CLI, MCP, GitHub CLI, Git, Ruby, PDK, Litmus, Beaker compatibility where required, and a module-specific Puppet Agent for acceptance targets. Ubuntu/Git/Ruby/Bundler/PDK and the Copilot CLI/Node.js pair are pinned; proposed acceptance components and unselected versions are recorded in [Toolchain Versions](toolchain-versions.md) and [Puppet Acceptance Testing Design](acceptance-testing.md).

Validation should be layered: static PDK validation and unit tests first, followed by acceptance tests only when an explicitly selected provider and disposable target are configured. Acceptance testing is potentially destructive and must be restricted to allowlisted targets with a verified teardown path. The default provider recommendation remains proposed and does not change current Compose profiles.

## Remaining implementation validations

The initial policy choices are recorded in ADR-0002 and ADR-0003; the runtime Puppet-secret approach is superseded by [ADR-0004](adr/0004-pdk-installation-strategy.md). [ADR-0005](adr/0005_copilot_authentication_and_state_management.md) governs Copilot: authentication is ephemeral, while approved settings and session data may persist separately. The host UID/GID, Level 0 read-only/no-network behavior, Level 1 workspace/cache writes, package version pins, readiness checks, host path initializers, and startup diagnostics are implemented. Bind-mounted workspace and approved Copilot state survive container recreation; the Copilot home remains tmpfs. The BuildKit secret configuration is implemented, but the protected PDK package build remains unverified because no external credential source is available in this environment. Successful Copilot login and reauthentication after container recreation remain future operational verification tasks; they do not block the isolated state implementation. Select exact versions for the remaining tools and verify that Level 0/1 cannot perform remote writes. Acceptance testing is proposed for Phase 5 under ADR-0006; provider selection and implementation remain gated on its acceptance and the Litmus/Podman compatibility spike.
