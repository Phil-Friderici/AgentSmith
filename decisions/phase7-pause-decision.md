# Decision Note: Pause of Phase 7 Provider Integration Work

- Date: 2026-11-23
- Status: Accepted
- Related ADRs:
  - ADR-0010: Maintainer Operations Strategy
- Related Plans:
  - docs/phase7-implementation-plan.md
  - docs/phase7-provider-integration-plan.md
  - docs/phase7-provider-integration-validation-plan.md

## Context

Phase 7 planning activities have completed successfully.

The following work has been completed:

- ADR-0010 creation and review.
- Security review and remediation.
- Phase 7 implementation planning.
- Phase 7a broker foundation implementation.
- Phase 7b approval, audit, revocation, and emergency-stop framework implementation.
- Identity and approval provider selection.
- Provider integration planning.
- Provider integration validation planning.

No Level 3 maintainer capability has been enabled.

All implemented controls currently operate in fail-closed mode and use test doubles or placeholder integrations.

## Decision

Phase 7 implementation work is paused after completion of the planning, foundation, and control-framework phases.

No further implementation work will occur until operational decisions are made regarding the external services required by ADR-0010.

## Reasoning

The remaining blockers are no longer architecture or implementation-planning problems.

The project now requires operational ownership and deployment decisions for externally provided trust anchors.

Remaining dependencies include:

- GitHub App ownership and lifecycle management.
- Maintainer Team definition and governance.
- Approval evidence service deployment.
- Credential issuer deployment.
- Durable audit sink deployment.
- Emergency-stop service deployment.
- Revocation service deployment.

Further implementation work would provide little additional value until these dependencies are available or intentionally deferred.

## Current Status

### Completed

```text
Phase 2
Phase 3
Phase 4

Phase 5a
Phase 5b

Phase 6a

Phase 7a
Phase 7b

Identity and approval provider selection
Provider integration planning
Provider integration validation planning
```

### Paused

```text
Phase 6b
Phase 7 provider integration work
Phase 7c
Phase 7d
Phase 7e
```

## Conditions for Resumption

Phase 7 may resume when all of the following are available:

### Identity

- Approved GitHub maintainer team.
- Defined maintainer eligibility process.

### Credential Issuance

- Selected credential issuer.
- Non-production credential issuance environment.

### Approval Evidence

- Deployable approval evidence service.
- Approval retention policy.

### Audit

- Durable audit sink.
- Retention policy.
- Integrity verification strategy.

### Emergency Controls

- External emergency-stop mechanism.
- Revocation coordination process.

## Explicitly Deferred

The following remain disabled:

- Pull-request merge operations.
- Release creation.
- Release publication.
- Tag creation.
- Tag movement.
- Operation approval.
- Repository-maintainer actions.
- Organization-maintainer actions.

No production credentials are configured.

No maintainer operation handlers are enabled.

No repository mutations may occur through Level 3 workflows.

## Re-evaluation Trigger

Revisit this decision when one of the following occurs:

- A GitHub App is approved for non-production validation.
- An approval evidence service becomes available.
- A durable audit service becomes available.
- Phase 6b resumes and requires alignment with Level 3 controls.
- A new operational sponsor accepts responsibility for the external provider stack.

## Outcome

The architecture, security model, implementation planning, and control-framework work for Phase 7 are considered complete.

Future progress depends on operational deployment decisions rather than additional design work.

Until those decisions are made, Phase 7 remains paused.
