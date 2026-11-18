# ADR-0002: Initial implementation policy

- Status: Accepted; Puppet credential policy partially superseded by [ADR-0004](0004-pdk-installation-strategy.md)
- Date: 2026-11-18
- Deciders: Project operator

## Context

The architecture baseline identified choices that affect persistence, security, reproducibility, and the first implementation. The project needs defaults that do not assume an MCP server, GitHub write credential, acceptance-test provider, or image-build access to Puppet repository credentials.

## Decision

- Use `~/AgentForge/workspace` as the default host workspace root, separate from the AgentForge source checkout. Use `~/AgentForge/cache` as the default host cache root; both can be overridden at runtime.
- Match the workstation container process UID/GID to the host user for bind-mounted files. Never recursively change workspace ownership at startup.
- Keep Puppet repository credentials outside the repository and image. ADR-0004 supersedes the original runtime-mount plan: provide them only as BuildKit secrets during PDK package download; never make them available to runtime containers.
- Do not configure GitHub CLI or Git remote authentication in the initial workstation baseline. Add remote collaboration later through a separately approved, narrowly scoped mechanism. Copilot authentication and session-state rules are governed by [ADR-0005](0005_copilot_authentication_and_state_management.md), which supersedes any broader interpretation of this initial policy.
- Disable MCP in the initial baseline. Add only reviewed integrations required by a concrete workflow.
- Pin exact base-image and toolchain versions; update pins deliberately after compatibility testing.
- Persist only selected Ruby/Bundler and PDK caches, scoped by user and project. Do not share writable caches across permission levels or store credentials in caches.
- Defer Litmus and Beaker provider selection until a concrete target module defines its acceptance-test requirements. Do not assume Docker socket access.

## Alternatives considered

- **Store repositories under this source checkout:** Rejected as the default because user data should not be coupled to the architecture repository or accidentally committed.
- **Use a fixed container UID and recursively `chown` mounted content:** Rejected because recursive ownership changes can alter unrelated user data and add risky startup behavior.
- **Pass Puppet credentials through `ARG`, `ENV`, or copied files:** Rejected because those mechanisms can expose values in image metadata, layers, logs, or generated artifacts. BuildKit secret mounts are selected by ADR-0004 for the protected package download.
- **Mount the host's GitHub credential directory:** Rejected as the default because it grants a persistent credential surface broader than the initial read-only/development need.
- **Enable MCP and acceptance testing from day one:** Rejected because server capabilities and target-provider requirements are not yet established.
- **Use floating tool versions:** Rejected because it undermines reproducibility and makes regressions harder to diagnose.
- **Persist broad shared caches:** Rejected because cache contents may be private or untrusted and broad sharing crosses project/trust boundaries.

## Consequences

The initial workstation can focus on local development without remote GitHub writes or MCP integration. Operators must provide compatible external package credentials when building the PDK image. The cache and workspace paths are defaults, not mandatory host locations.

Deferring acceptance providers keeps the initial workstation independent of unverified infrastructure. A later provider decision must account for disposable targets, credential scope, teardown, and the no-Docker-socket baseline.

## Security and operations

The build-only PDK credential flow and its verification requirements are defined by ADR-0004. A Compose v5.7.1 probe found that file-backed runtime secret `uid`, `gid`, and `mode` settings are ignored; this is one reason the runtime-mount design was replaced. No real credential was accessed during that probe. Level 0/1 must have no Puppet package credential or remote write credential at runtime. All implementation claims require tests against the actual deployed configuration.
