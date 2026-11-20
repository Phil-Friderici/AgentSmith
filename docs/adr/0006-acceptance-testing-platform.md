# ADR-0006: Acceptance Testing Platform

- Status: Accepted
- Date: 2026-11-18
- Deciders: AgentForge maintainers

## Context

Phase 4 supports PDK validation and unit tests, but not Puppet acceptance tests.

Acceptance testing requirements differ significantly between Puppet modules.

Most modern Puppet modules can be validated with containerized targets using Litmus.

A smaller subset of modules requires:

- existing Beaker suites
- Vagrant-based workflows
- Windows targets
- Solaris targets
- FreeBSD targets
- reboot testing
- full virtual-machine fidelity

AgentForge should prefer the simplest provider capable of executing the required acceptance test workload.

The workstation must continue to preserve:

- ADR-0004 BuildKit secret boundaries
- ADR-0005 authentication boundaries
- least-privilege operation
- no Docker daemon access from the normal workstation

## Decision

Acceptance testing is divided into two implementation stages.

### Phase 5a – Local Container Acceptance Testing

Goal:

```text
Operator
    ↓ explicit invocation
Isolated acceptance runner (Litmus)
    ↓ rootless Podman API over owner-restricted Unix socket
Rootless Podman
    ↓
Disposable container target
```

Characteristics:

- Litmus 2.8.2 is the selected acceptance-testing framework.
- Litmus's built-in `docker_exp` provisioner is the selected provider.
- Podman 4.9.3+ds1-1ubuntu0.2 is the validated container runtime.
- The provider connects to rootless Podman through a run-scoped Unix API socket.
- The socket is available only within the explicitly invoked acceptance boundary.
- The socket is never exposed over TCP.
- The socket is never mounted into targets.
- The socket is never available to normal Level 0 or Level 1 workstation services.
- Acceptance execution uses a dedicated unprivileged identity.
- Acceptance execution uses private Podman storage.
- The acceptance identity receives no Copilot authentication state.
- The acceptance identity receives no GitHub authentication.
- The acceptance identity receives no Puppet repository credentials.
- Only a staged, credential-free module snapshot and selected test artifacts cross the boundary.
- Socket access is considered a high-impact capability and must remain run-scoped and owner-restricted.
- Docker daemon access remains prohibited.
- Containers use a validated delegated absolute cgroup parent.
- Containers use a validated finite PIDs limit of 1024.

This phase is intended for:

- Ubuntu
- Debian
- Rocky Linux
- AlmaLinux
- other container-compatible Linux distributions

The objective is to support the majority of Puppet Forge modules without requiring additional infrastructure.

### Phase 5b – External VM Acceptance Testing

Used only when container targets are insufficient.

Goal:

```text
AgentForge
    ↓
External Validation Host
    ↓
Vagrant / Beaker / EC2
    ↓
Virtual Machine Target
```

Characteristics:

- Separate validation infrastructure.
- Not part of the normal workstation lifecycle.
- Explicit operator invocation.
- Disposable validation environment.
- No shared home directories.
- No shared secrets.
- No workstation credential propagation.

Candidate technologies:

- Beaker
- Vagrant
- EC2-backed targets
- Nested virtualization

This phase is intended for:

- Windows
- Solaris
- FreeBSD
- reboot validation
- virtualization-specific modules
- legacy Beaker suites
- modules requiring full-system behaviour

## Validation Strategy

### Phase 5a Validation

Required before acceptance:

- User namespaces available
- Rootless Podman operational
- Litmus operational
- Target provisioning succeeds
- Puppet apply succeeds
- Acceptance tests execute
- Cleanup succeeds
- Repeated runs show no environment drift

Additional validation requirements:

- Verify the Podman API socket is rootless.
- Verify the Podman API socket is Unix-only.
- Verify the Podman API socket is owner-restricted.
- Verify the Podman API socket is unavailable to Level 0 services.
- Verify the Podman API socket is unavailable to Level 1 services.
- Verify the Podman API socket is unavailable to acceptance targets.
- Verify the socket is removed after the acceptance run completes.

API compatibility alone is insufficient.

Validation must demonstrate:

- target provisioning
- Puppet apply execution
- acceptance assertions
- target destruction
- repeat execution

Validation completed on 2026-11-20 demonstrated:

- Rootless Podman operation
- Litmus 2.8.2 operation
- `docker_exp` provisioning
- Puppet apply execution
- Acceptance assertion execution
- Successful target teardown
- Controlled-failure cleanup
- Repeated successful execution
- Cleanup after failure
- Cleanup after success

Validation was performed against a synthetic Ubuntu target.

Successful validation does not imply support for every Puppet module or operating system.

### Phase 5b Validation

Required before acceptance:

- Dedicated validation host available
- Provider provisioning succeeds
- Guest lifecycle succeeds
- Test execution succeeds
- Cleanup succeeds
- Costs and operational burden documented

## Alternatives Considered

### Rootless Podman API socket in the acceptance boundary

Accepted for Phase 5a.

Phase 5a validation confirmed that Litmus 2.8.2 can operate securely through a rootless Podman Unix socket confined to the acceptance boundary.

Litmus 2.8.2 does not provide a built-in Podman CLI provisioner.

The built-in `docker_exp` provisioner requires a Docker-compatible API endpoint.

Rootless Podman can provide that endpoint through a Unix socket.

This decision:

- does not authorize Docker daemon access
- does not authorize Docker socket mounts
- does not authorize TCP-exposed Podman APIs

The socket:

- must be rootless
- must be Unix-only
- must be owner-restricted
- must be run-scoped
- must exist only inside the acceptance-testing boundary

If those requirements cannot be enforced, Phase 5a must stop and be reassessed.

### Beaker as the default

Rejected.

Reason:

- Unnecessary complexity for the majority of modules.
- Requires VM-centric workflows.

### EC2 for all acceptance testing

Rejected.

Reason:

- Additional cost.
- Increased setup complexity.
- Slower development feedback cycle.

### Docker socket in the workstation

Rejected.

Reason:

- Excessive privilege.
- Violates least-privilege design.

### Rootless Podman as the only provider

Rejected.

Reason:

- Some Puppet modules require VM-level behaviour.

## Consequences

### Positive

- Lower barrier to entry.
- Faster local validation.
- Majority of modules require no cloud resources.
- Clear escalation path for complex modules.
- Preserves workstation security boundaries.

### Negative

- Two acceptance-test workflows must be maintained.
- Module maintainers must select the appropriate provider.
- Some test suites may require migration work.

## Open Questions

### Phase 5a

Closed through operational validation.

Validated selections:

- Litmus 2.8.2
- Podman 4.9.3+ds1-1ubuntu0.2
- `docker_exp` provisioner
- Rootless Podman Unix socket
- Delegated absolute cgroup parent
- PIDs limit of 1024

### Phase 5b

- Should EC2 or Vagrant be the preferred VM provider?
- Which guest operating systems should be officially supported?
- What cost controls should be enforced?

### Current Validation Findings

Operational validation completed successfully on 2026-11-20.

Validation confirmed:

- Rootless Podman operation
- Delegated cgroup placement
- Litmus 2.8.2 provisioning
- `docker_exp` operation
- Puppet apply execution
- Acceptance assertion execution
- Controlled-failure handling
- Cleanup verification
- Repeatability across multiple runs

Observed security properties:

- `Privileged=false`
- Private cgroup namespace
- No added capabilities
- No devices
- No published ports
- `network=none`
- Read-only cgroup mount
- Rootless execution
- Run-scoped Unix socket
- No Puppet repository credentials in targets
- No Copilot authentication artifacts in targets

Validation used a synthetic Ubuntu target.

Further validation may be required for additional operating systems, providers, or module-specific acceptance suites.

## Validation Status

Phase 5a was operationally validated on 2026-11-20.

Validated workflow:

```text
Provision target
↓
Apply Puppet resource
↓
Execute acceptance assertion
↓
Destroy target
↓
Verify cleanup
↓
Repeat
```

Validation included:

- Successful execution
- Controlled failure execution
- Cleanup after success
- Cleanup after failure
- Repeat execution from a clean environment

Phase 5a is considered implemented and validated.

Phase 5b remains unimplemented and subject to future validation.

## Security and Operations

Container-based acceptance testing must:

- remain rootless
- use disposable targets
- avoid Docker daemon access
- avoid workstation credential propagation

VM-based acceptance testing must:

- use isolated infrastructure
- receive no Puppet repository credentials
- receive no Copilot authentication state
- receive no workstation secrets
- be fully disposable

## References

- ADR-0004: PDK Installation Strategy
- ADR-0005: Copilot Authentication and State Management
- docs/acceptance-testing.md
- docs/acceptance-validation-phase1.md
- docs/phase5a-validation-report.md
