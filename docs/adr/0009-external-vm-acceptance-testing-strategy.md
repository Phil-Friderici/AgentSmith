# ADR-0009: External VM Acceptance Testing Strategy

- Status: Proposed
- Date: 2026-11-20
- Deciders: AgentForge maintainers

## Context

Phase 5a is implemented and operationally validated using:

- Litmus 2.8.2
- `docker_exp`
- Rootless Podman 4.9.3+ds1-1ubuntu0.2

Phase 5a provides isolated disposable container targets and does not require provider credentials.

Phase 5b extends acceptance testing to external virtual-machine targets.

External VM testing introduces additional concerns:

- Provider credentials
- Provisioning control
- Resource cleanup
- Infrastructure cost
- Network exposure
- Auditability
- Long-lived resource leakage

Phase 5b must preserve the security boundaries established by:

- ADR-0004
- ADR-0005
- ADR-0006
- ADR-0007
- ADR-0008

## Decision

A separate VM acceptance-testing architecture will be used.

Phase 5b execution must occur on a dedicated validation host and must never run directly inside normal AgentForge workstation profiles.

The workstation remains:

- Credential-free
- Provider-free
- VM-management-free

The validation environment is responsible for:

- Provisioning
- Credential handling
- Resource tracking
- Cleanup verification
- Acceptance execution

## Provider Strategy

### Preferred Approach

Preferred approach:

```text
Vagrant-based VM acceptance testing
```

Rationale:

- Aligns with documented Litmus workflows.
- Avoids cloud-provider dependencies during the initial implementation.
- Avoids cloud billing exposure during initial validation.
- Provides a bounded environment suitable for repeatable testing.

### Initial Backend Candidate

Preferred backend candidate:

```text
Vagrant + libvirt/KVM
```

Evidence supporting this candidate includes:

- Ubuntu 24.04 validation host
- KVM acceleration enabled
- QEMU 8.2.2
- libvirt 10.0.0
- operational libvirt networking
- Vagrant 2.4.9
- vagrant-libvirt 0.12.2
- successful VM lifecycle validation (`vagrant up`, SSH access, `vagrant destroy`)

Litmus integration was pending when this assessment was written. Subsequent compatibility and minimal provisioning, inventory, connectivity, teardown, and cleanup-reconciliation validation is recorded in the [Litmus integration report](../phase5b-litmus-integration-report.md) and [Litmus provisioning report](../phase5b-litmus-provisioning-report.md). This evidence does not certify production workload readiness or a full module acceptance suite.

### Fallback Backend Candidate

Fallback backend candidate:

```text
Vagrant + VirtualBox
```

VirtualBox remains a supported fallback because:

- Vagrant integration is built in.
- Existing VirtualBox workflows remain available.
- It may provide an alternative path if libvirt-specific integration issues are discovered during Litmus validation.

### Deferred Providers

Deferred until Vagrant-based validation is complete:

```text
EC2
```

EC2 remains a future provider candidate but introduces:

- cloud credentials
- billing exposure
- provider-specific cleanup requirements
- additional orchestration complexity

No EC2-based implementation work should begin before Vagrant-based validation has been completed and reviewed.

### Excluded Providers

The following approaches are not currently planned:

```text
Direct VirtualBox management
Direct libvirt management
Custom hypervisor integrations
```

Phase 5b should remain based on Litmus-supported workflows wherever possible.

## Validation Host Model

The validation host must be separate from normal workstation execution.

Responsibilities:

- VM provisioning
- VM lifecycle management
- Resource inventory
- Cost enforcement
- Acceptance execution
- Cleanup verification

The validation host must not be:

- a normal AgentForge workstation
- a developer workstation
- a production system

## Security Model

### Controller and Worker Separation

Phase 5b requires a dedicated controller and worker boundary.

Controller responsibilities:

- Provider operations
- Credential handling
- Resource inventory
- Cleanup reconciliation

Worker responsibilities:

- Acceptance execution
- Puppet operations
- Target communication

Worker environments must not have access to:

- Provider credentials
- Provider APIs
- Credential caches
- Metadata services
- Controller files
- Controller configuration

### Provider Credential Isolation

Provider credentials must never be exposed to acceptance workloads.

Provider credentials may exist only within the provisioning controller boundary.

Acceptance targets and test code must never receive:

- provider credentials
- cloud credentials
- orchestration credentials
- account metadata credentials

### Host Isolation

Normal AgentForge profiles must not receive:

- hypervisor access
- VirtualBox APIs
- libvirt APIs
- provider credentials
- provisioning capabilities

## Credential Model

Provider credentials must be:

- isolated
- minimally privileged
- time limited where possible
- externally supplied
- auditable

Credentials must not be:

- stored in repositories
- stored in container images
- stored in generated artifacts
- persisted beyond operational necessity

## Resource and Cost Controls

Phase 5b requires hard enforcement of resource limits.

Configurations whose costs cannot be bounded must be rejected.

Default limits should include:

- one active validation run
- one active VM target
- bounded CPU allocation
- bounded memory allocation
- bounded storage allocation
- bounded runtime

Runs exceeding defined limits must terminate automatically.

Cost-control failures invalidate the validation run.

## Cleanup Model

Cleanup must not depend solely on provider tags.

Before provisioning begins:

```text
Run ID generated
↓
Resources recorded
↓
Resources created
```

The controller must maintain durable ownership records containing:

- run identifier
- instance identifiers
- storage identifiers
- network identifiers
- security identifiers (where applicable)

Cleanup must:

- be idempotent
- survive controller interruption
- survive partial provisioning failures
- reconcile resource journals against provider inventory

Both recorded resources and discovered resources must be checked.

If cleanup verification cannot prove removal of allocated resources:

```text
Validation result = failed
```

## Audit Requirements

Every VM acceptance run must record:

- timestamp
- run identifier
- provider type
- target platform
- provisioned resources
- execution result
- cleanup result

Audit records must not contain:

- credentials
- tokens
- secrets

## Initial Target Scope

Phase 5b begins with:

```text
One VM
One Linux target
One module-driven operating-system requirement
```

Deferred:

- Windows
- BSD
- Solaris
- Multi-provider execution
- Multi-platform matrices

These may be evaluated after initial Phase 5b validation succeeds.

## Validation Strategy

The detailed compatibility-spike procedure is documented in:

- docs/phase5b-compatibility-spike-test-protocol.md

### Provider Compatibility Spike

Before implementation:

- Validate Litmus compatibility.
- Validate provider compatibility.
- Validate provisioning workflow.
- Validate cleanup workflow.
- Validate resource tracking.
- Validate SSH key lifecycle.

### Phase 5b Validation

Required before acceptance:

- VM provisioning succeeds.
- Puppet apply succeeds.
- Acceptance assertions succeed.
- Cleanup succeeds.
- Cleanup survives interruption testing.
- Cost controls are enforced.
- Resource reconciliation succeeds.
- Provider credentials remain isolated.
- Controller/worker separation is demonstrated.

### Failure Testing

Validation must demonstrate:

- cleanup after provisioning failure
- cleanup after test failure
- cleanup after interruption
- enforcement of runtime limits
- enforcement of resource limits
- recovery from partial creation events

## Alternatives Considered

### EC2-First Strategy

Rejected as the initial implementation candidate.

Reason:

- Introduces cloud credentials immediately.
- Adds billing management requirements.
- Adds provider-specific orchestration complexity.

EC2 remains a future candidate.

### Direct Hypervisor Integration

Rejected.

Reason:

- Bypasses higher-level lifecycle controls.
- Increases implementation complexity.
- Reduces portability.

### VM Testing Inside Workstation Profiles

Rejected.

Reason:

- Violates workstation security boundaries.
- Expands privilege exposure.
- Couples development and provisioning responsibilities.

## Consequences

### Positive

- Extends acceptance testing beyond containers.
- Preserves workstation security boundaries.
- Supports future operating-system validation.
- Provides bounded resource control.
- Establishes auditable cleanup requirements.

### Negative

- Additional operational complexity.
- Dedicated infrastructure required.
- VM lifecycle management required.
- Hypervisor maintenance required.
- Cleanup verification requirements increase implementation effort.

## Open Questions

- Exact Vagrant version?
- Exact VirtualBox version?
- Exact Linux target?
- Exact Puppet Agent version?
- Whether VirtualBox compatibility can be validated for Litmus 2.8.2?
- Whether libvirt/KVM should replace VirtualBox after compatibility testing?
- Whether EC2 should be introduced after the initial Phase 5b implementation?

## Security and Operations

Phase 5b must:

- preserve ADR-0004 boundaries
- preserve ADR-0005 boundaries
- preserve ADR-0006 boundaries
- preserve ADR-0007 boundaries
- preserve ADR-0008 boundaries
- keep provider credentials isolated
- keep workstation profiles provider-free
- enforce bounded resource usage
- enforce bounded runtime
- enforce auditable cleanup
- default to denial on verification failures

## Validation Status

The following Phase 5b validation activities have completed successfully:

- KVM acceleration validation
- libvirt 10.0.0 validation
- QEMU 8.2.2 validation
- Vagrant 2.4.9 validation
- vagrant-libvirt 0.12.2 validation
- VM lifecycle validation
- Litmus provisioning validation
- Inventory generation validation
- SSH connectivity validation
- Teardown validation
- Cleanup validation
- Provisioning-failure cleanup validation

Selected backend:

```text
Vagrant + libvirt/KVM
```

Fallback backend:

```text
Vagrant + VirtualBox
```

Remaining work is operational hardening and productionization rather than architecture validation.

## References

- ADR-0006: Acceptance Testing Platform
- ADR-0008: Controlled Contribution Workflow
- Litmus 2.8.2
- Vagrant
- VirtualBox
- libvirt/KVM

## Validation Status

Phase 5b provider and Litmus integration validation completed.

Validated:

- Vagrant 2.4.9
- libvirt/KVM
- vagrant-libvirt 0.12.2
- VM lifecycle
- inventory generation
- SSH connectivity
- teardown
- cleanup reconciliation
- provisioning failure recovery

Selected backend:

- Vagrant + libvirt/KVM

VirtualBox remains available as a fallback backend.

