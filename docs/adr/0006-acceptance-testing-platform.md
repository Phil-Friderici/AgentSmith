# ADR-0006: Acceptance Testing Platform

- Status: Proposed
- Date: 2026-11-18
- Deciders: AgentForge maintainers

## Context

Phase 4 supports PDK validation and unit tests, but not Puppet acceptance tests. Acceptance testing requires a framework and disposable target environments while preserving the no-Docker-socket workstation baseline, rootless operation where practical, and the secret-management boundaries established by ADR-0004 and ADR-0005.

Litmus and Beaker are testing frameworks. Docker, Podman, KVM, and EC2 are target-provider implementations. Their suitability depends on the module under test, platform capabilities, security constraints, and operational requirements.

No acceptance-test provider has been enabled in AgentForge.

A compatibility spike was attempted to validate Litmus with rootless Podman. The spike could not be completed because the host platform prevented user namespace creation.

The observed result was:

```text
unshare -Ur true
→ Operation not permitted
```

The spike demonstrates only that the current host environment cannot validate rootless Podman. It does not demonstrate incompatibility between Litmus and rootless Podman.

## Proposed Decision

- Use Litmus as the default framework for new acceptance-testing workflows.
- Prefer rootless Podman as the default target provider.
- Run acceptance tests inside a dedicated, disposable acceptance-provider boundary.
- Do not expose Docker sockets or Podman sockets to the normal AgentForge workstation.
- Retain Beaker only for modules with an existing Beaker-based acceptance-test workflow.
- Keep EC2 as an optional provider when cloud fidelity, operating-system coverage, or isolation requirements justify the additional complexity.
- Avoid nested KVM by default. Use it only when a module explicitly requires full virtual-machine fidelity and a separate reviewed virtualization boundary is available.
- Require a successful compatibility spike before enabling any provider in the supported AgentForge workflow.

If Litmus cannot safely and reliably operate with rootless Podman after validation on a suitable platform:

- evaluate EC2 as the preferred provider, or
- create a separate architectural proposal for a dedicated rootless Docker-based provider.

Do not fall back to mounting a general-purpose Docker daemon socket into the workstation.

## Validation Status

A compatibility spike was executed on the current host platform.

The spike could not proceed because the required rootless-user-namespace functionality was unavailable.

Observed validation result:

```text
unshare -Ur true
→ Operation not permitted
```

As a result:

- Rootless Podman remains the preferred provider candidate.
- Rootless Podman is not yet validated.
- Litmus acceptance testing is not yet validated.
- No supported acceptance-testing provider has been approved.
- This ADR remains in Proposed status.

A future validation environment should provide:

- Ubuntu 24.04
- Rootless Podman
- User namespaces enabled
- Subordinate UID/GID mappings
- Litmus provisioning support
- Disposable test targets
- Automated cleanup verification

Successful validation must prove:

- Target provisioning
- Puppet apply execution
- Acceptance-test execution
- Artifact collection
- Reliable teardown
- Repeated execution without environment drift

## Alternatives Considered

### Beaker as the default

Retained only as a compatibility option.

Advantages:

- Strong support for existing legacy Puppet acceptance suites.
- Familiar workflow for older Forge modules.

Disadvantages:

- Additional complexity.
- Less aligned with modern container-based workflows.
- Does not provide a simpler security model.

### Docker socket in the workstation

Rejected.

Advantages:

- Simple integration.
- Broad ecosystem support.

Disadvantages:

- Grants broad control over the container runtime.
- Significantly expands workstation privileges.
- Contradicts the least-privilege goals of AgentForge.

### Rootless Podman exposed directly to the workstation

Rejected.

Advantages:

- Avoids a Docker daemon dependency.
- Better privilege separation than a traditional Docker socket.

Disadvantages:

- The Podman API remains a high-impact capability.
- Broadens the workstation trust boundary.
- Reduces isolation between development and test execution.

### Nested KVM

Deferred.

Advantages:

- High-fidelity operating-system testing.
- Closest approximation to production virtual-machine deployments.

Disadvantages:

- Additional infrastructure complexity.
- Requires virtualization support from the host platform.
- Increased operational overhead.

### EC2 for all testing

Rejected as the default.

Advantages:

- Strong isolation.
- Broad operating-system coverage.
- Realistic cloud execution environment.

Disadvantages:

- Cloud credentials required.
- Increased cost.
- Slower feedback loop.
- Additional provisioning complexity.

## Consequences

- Litmus and Podman versions remain unselected until provider validation succeeds.
- A target-specific Puppet Agent version will be required before provider images can be finalized.
- Provider images that require protected Puppet repositories must follow the BuildKit-secret workflow defined in ADR-0004.
- Runtime acceptance targets must never receive Puppet repository credentials.
- Provider credentials, if used, must be short-lived and scoped to a single execution.
- Authentication data must never persist in repositories, workspaces, caches, Copilot state, or generated artifacts.
- Acceptance testing remains opt-in and disabled until this ADR is accepted.
- Phase 5 implementation requires:
  - Target selection
  - Resource limits
  - Artifact handling
  - Cleanup verification
  - Failure recovery procedures

Acceptance-testing enablement supersedes only the acceptance-test deferral established in ADR-0002.

ADR-0004 and ADR-0005 remain unchanged.

## Security and Operations

Acceptance execution must be isolated from normal Level 0 and Level 1 workstation operations.

Acceptance environments must not receive:

- Docker daemon access from the workstation
- Host home-directory mounts
- Persistent Copilot state
- Broad workspace access
- Puppet repository credentials

Rootless Podman reduces privilege requirements but is not considered a security sandbox.

Provider APIs, sockets, or management interfaces are high-impact capabilities and must remain within the disposable acceptance-test boundary.

Acceptance targets must:

- Be disposable
- Be version-pinned
- Be allow-listed
- Be automatically cleaned up after execution
- Be cleaned up after interruption or failure

Any remote-provider credentials must:

- Be execution-scoped
- Be excluded from logs
- Be excluded from persistent storage
- Be excluded from session-state persistence

## Open Questions

- Does Litmus operate reliably with rootless Podman on a supported Ubuntu 24.04 host?
- Which Litmus version should be pinned?
- Which Podman version should be pinned?
- Is a dedicated acceptance-provider container sufficient, or is a separate VM boundary preferable?
- Under which conditions should EC2 become the preferred acceptance provider?
- What artifact-retention policy should apply to acceptance-test outputs?
- What resource limits should be imposed on acceptance targets?

## References

- ADR-0002: Initial Implementation Policy
- ADR-0004: PDK Installation Strategy
- ADR-0005: Copilot Authentication and State Management
- docs/acceptance-testing.md
