# Architecture Decision Records

Architecture Decision Records (ADRs) preserve the context and rationale for decisions that materially affect AgentForge's structure, security, operations, or compatibility.

## When to write an ADR

Write an ADR when a choice is costly to reverse or affects multiple components, including:

- Container boundaries, host mounts, persistence, or network access.
- Permission enforcement or credential/authentication mechanisms.
- Supported toolchain versions and upgrade strategy.
- MCP server selection or exposed capabilities.
- Acceptance-test provider topology.
- A change to a previously accepted architectural constraint.

Small implementation details that follow an accepted decision do not need a separate ADR.

## Process

1. Search this directory for an existing decision before proposing a new one.
2. Add the next sequential filename: `NNNN-short-title.md`.
3. Mark it `Proposed` while alternatives or consequences are under review.
4. Record the decision only after its owner accepts it; preserve the rationale and relevant security implications.
5. Do not rewrite history when a decision changes. Mark the old ADR `Superseded by ADR-NNNN` and link to the replacement.
6. Use `Rejected` for a considered option that should remain documented because it may otherwise be proposed again.
7. Update related architecture and operational documentation when a decision becomes accepted.

An ADR should be concise but sufficient for a future contributor to understand why the choice was made. Include links to repository-local documents where useful; do not put credentials or sensitive operational details in ADRs.

## Template

```markdown
# ADR-NNNN: <Short title>

- Status: Proposed | Accepted | Rejected | Superseded
- Date: YYYY-MM-DD
- Deciders: <roles or names>

## Context
What problem, constraints, and forces require a decision?

## Decision
What is being decided? State the chosen option precisely.

## Alternatives considered
- Option A — benefits and costs.
- Option B — benefits and costs.

## Consequences
What improves, what becomes harder, and what follow-up work is required?

## Security and operations
What permissions, credentials, persistence, monitoring, or recovery implications follow?
```

## Initial decision

[ADR-0001](0001-project-boundaries-and-workstation-model.md) records the project's initial boundary and workstation-model decision.

[ADR-0002](0002-initial-implementation-policy.md) records the initial workspace, credential, toolchain, MCP, cache, and acceptance-test policies.

[ADR-0003](0003-puppet-package-source-and-runtime-setup.md) records the Puppet 8 package source, signing key, and PDK version. Its runtime credential setup is superseded by [ADR-0004](0004-pdk-installation-strategy.md), which requires a build-only BuildKit secret.

[ADR-0004](0004-pdk-installation-strategy.md) requires BuildKit-secret PDK installation and credential-free runtime images. [ADR-0005](0005_copilot_authentication_and_state_management.md) rejects persistent Copilot authentication while allowing reviewed session history and settings to persist separately.

[Proposed ADR-0006](0006-acceptance-testing-platform.md) recommends Litmus and an isolated rootless Podman target provider for Phase 5. It is not accepted and does not enable acceptance testing or supersede ADR-0002 until accepted.
