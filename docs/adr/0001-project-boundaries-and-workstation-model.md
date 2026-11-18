# ADR-0001: Project boundaries and workstation model

- Status: Accepted
- Date: 2026-11-18
- Deciders: Project architecture baseline

## Context

AgentForge needs to support persistent AI-agent development for GitHub Copilot CLI and Puppet modules. Repositories and useful local state should survive separate sessions and container replacement. The environment also handles private package access and can perform remote GitHub actions, so the boundary between the workstation, host, and external services must be explicit.

The project is in its architecture phase. It must establish direction without prematurely committing to unverified container configuration, secret behavior, MCP integrations, or acceptance-test providers.

## Decision

- AgentForge is a persistent development workstation, not a CI runner.
- The initial runtime target is Ubuntu 24.04 managed locally with Docker Compose.
- The baseline will use a replaceable, unprivileged primary workstation container.
- Repositories and selected non-secret caches will live in explicit persistent host-managed paths or volumes, not in the container image.
- Permission defaults to read-only. Development, remote collaboration, and maintainer capabilities are separate levels and require explicit grants.
- Secrets are external to the repository and final image and are supplied only through an operation-scoped mechanism. Puppet package credentials use the BuildKit-only flow defined by ADR-0004; they are never runtime mounts.
- The architecture phase produces documentation only; implementation details remain subject to later ADRs and verification.

## Alternatives considered

- **Disposable CI-style job container:** Rejected because it loses useful working state and does not meet the multi-session reuse requirement.
- **Privileged container with broad host access:** Rejected because persistence does not justify host-equivalent access and would undermine the permission model.
- **Credentials embedded through build arguments or copied files:** Rejected because it risks exposure in layers, build cache, logs, and artifacts. A BuildKit secret mount for the PDK package download is defined later by ADR-0004 and does not embed the credential in the resulting image.
- **Implementing a full runtime before resolving credential and permission boundaries:** Rejected because it would encode security assumptions before they are tested.

## Consequences

The design favors persistent host-managed storage and explicit runtime configuration. This requires careful ownership, path, cache, and container lifecycle decisions during implementation. Docker Compose is a local orchestration choice; exact secret support and service topology must be validated on the target environment.

No Dockerfile, Compose configuration, code, or workflow is implied by acceptance of this ADR. Future decisions should cover toolchain versioning, credential mounts, MCP integrations, and acceptance-test providers.

## Security and operations

The workstation must not mount the Docker socket or broad host directories by default. Lower permission levels must not receive remote write credentials. Credentials must remain outside source control, images, logs, caches, and chat. Acceptance tests must use authorized targets and must not silently widen host or remote privileges.
