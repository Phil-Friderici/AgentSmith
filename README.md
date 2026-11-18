# AgentForge

AgentForge is a persistent development workstation for AI agents using GitHub Copilot CLI and Puppet module tooling. It is designed to preserve useful working state across sessions, not to act as a disposable CI runner.

The repository includes the Phase 2 workstation foundation, Phase 3 Copilot workstation, and Phase 4 Puppet module workflows. PDK 4.0.1 is downloaded during the image build using a BuildKit secret; Puppet repository credentials are not available to runtime containers. Copilot CLI 1.0.112 is installed with Node.js 22.23.5. Under ADR-0005, Level 1 authentication is operator-initiated and ephemeral; only approved settings and session data persist in a separate host state path. Puppet module workflows pin Ruby 3.2.3 and Bundler 2.4.20 and scope Bundler caches per module. A global Puppet Agent, GitHub CLI authentication, Docker daemon access, and MCP servers remain absent.

## What AgentForge is intended to support

- Reusing checked-out repositories, branches, and caches across agent sessions.
- Developing Puppet modules with Ruby, PDK, Puppet Agent, Litmus, and Beaker.
- Running validation, unit tests, and acceptance tests in a reproducible environment.
- Creating commits at the development permission level, with branch pushes and pull requests explicitly elevated.
- Using GitHub Copilot CLI, GitHub CLI, and a deliberately restricted set of MCP tools.

## Start here

- [Vision](docs/vision.md) — users, goals, non-goals, and operating principles.
- [Architecture](docs/architecture.md) — components, persistence, workspace layout, and intended Compose topology.
- [Security model](docs/security-model.md) — permission levels, isolation, and approval boundaries.
- [MCP tool design](docs/mcp-tools.md) — tool exposure principles and proposed capabilities.
- [Secret management](docs/secret-management.md) — BuildKit-only handling for Puppet repository credentials and runtime credential boundaries.
- [Toolchain versions](docs/toolchain-versions.md) — selected versions, evidence, and deferred toolchain choices.
- [Setup](docs/setup.md) — prerequisites, host paths, build, and startup.
- [Puppet development](docs/puppet-development.md) — module bootstrap, Bundler, PDK validation, unit tests, version policy, and recovery.
- [Acceptance testing design](docs/acceptance-testing.md) — Phase 5 provider comparison, proposed architecture, security boundary, and roadmap.
- [Operations](docs/operations.md) — persistence, rebuilds, caches, and upgrade guidance.
- [Troubleshooting](docs/troubleshooting.md) — diagnostics and common failures.
- [Roadmap](docs/roadmap.md) — phased implementation sequence and completion criteria.
- [Architecture Decision Records](docs/adr/README.md) — how to record and revise architectural decisions.
- [ADR-0005](docs/adr/0005_copilot_authentication_and_state_management.md) — authoritative Copilot authentication and state boundary.

Each directory README describes the intended contents and persistence contract for that area.

## Workstation foundation

The image is based on a digest-pinned Ubuntu 24.04 image and installs pinned Git, Ruby, Bundler, PDK, Node.js, and Copilot CLI packages. PDK is fetched in an isolated BuildKit stage using an external APT auth file mounted only for that download step; the final image and runtime services do not receive the credential. Docker Compose provides separate Level 0 and Level 1 services with readiness checks. Both run as the host UID/GID, drop Linux capabilities, use a read-only container filesystem, and have no runtime Puppet credentials or GitHub CLI authentication. Level 0 has a read-only workspace, no network, offline Copilot mode, and no persistent Copilot state. Level 1 can write to the designated workspace/cache and approved Copilot session state, and access the network, but has no remote-write or Puppet package credentials. Copilot authentication is operator-initiated and remains in an ephemeral tmpfs home. Approved settings and session state persist separately under `~/AgentForge/state/copilot`.

A previous Compose probe showed that file-backed runtime secret metadata does not reliably enforce ownership. ADR-0004 replaces that design: the PDK build secret is supplied through BuildKit, and no secret is mounted into normal development sessions. The protected-package build still requires an operator-managed credential source and has not been exercised in this environment because no source file is available. See [Secret Management](docs/secret-management.md).

Permission levels are cumulative only when explicitly granted: read-only (Level 0), development (Level 1), remote collaboration (Level 2), and maintainer operations (Level 3). The default is Level 0. Initialize the workspace/cache and Copilot state with the scripts documented in [Setup](docs/setup.md), then start the desired profile with `docker compose -f compose/compose.yaml --profile level0 run --rm agent-level0` or Level 1. See [Compose guidance](compose/README.md).

The toolchain will use exact version pins updated deliberately. Persistent caches will be selective and scoped by user/project and trust level. Phase 5 proposes Litmus with an isolated rootless Podman target provider; this remains unimplemented and is gated on a compatibility spike. Beaker is a compatibility path for an existing module, not a default dependency.

## Contribution and source of truth

Treat the documents in `docs/` as the architectural source of truth until implementation and its tests establish more precise behavior. When implementation reveals a material design change, update the relevant documentation and add an ADR. Do not infer that a capability is implemented merely because it appears in the vision or roadmap.

The Phase 2 workstation, Phase 3 Copilot foundation, and Phase 4 Puppet module workflows are implemented, with host-path initialization and startup diagnostics. The PDK build-only secret strategy in [ADR-0004](docs/adr/0004-pdk-installation-strategy.md) supersedes the earlier runtime-install approach in ADR-0002 and ADR-0003. The protected PDK package flow still requires operator-authorized validation; successful Copilot login and reauthentication after container recreation remain future operational checks. Puppet 8 is the recommended module target major, but a system Puppet Agent remains deferred until a module requires an exact package pin. Phase 5 acceptance testing is design-only in [Proposed ADR-0006](docs/adr/0006-acceptance-testing-platform.md); no test provider is enabled. MCP remains disabled until a server and tool allowlist are explicitly reviewed.
