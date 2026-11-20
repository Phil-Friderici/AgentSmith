# Maintainer Broker Foundations

The broker contains Phase 7a and Phase 7b control foundations. It performs no GitHub operation, issues no production credential, and is not an approval or audit service.

## Enforced runtime state

- The operation allowlist is empty and is not loaded from a file, environment variable, repository, prompt, or stdin. Catalog entries have no provider permission/API-action mapping and cannot be enabled.
- The GitHub Team membership adapter, approval identity/provider, evidence verifier, and external replay store are unconfigured. Requests cannot supply approval evidence directly.
- The runtime credential issuer and revoker are unconfigured and no production handler exists. Test-only handlers use a synthetic no-op and placeholder credentials.
- The durable audit services, external emergency-stop state, and independent process supervisor are unconfigured; local test doubles are not production controls.
- The image has no Git, GitHub CLI, SSH client, workspace, repository checkout, or credential mounts.
- The image runs as UID/GID 65532 with a read-only root filesystem, no network, dropped capabilities, and only an ephemeral audit tmpfs in the Compose profile.

`--self-check` reports these integration gates as unconfigured. `--request-stdin` accepts one bounded request envelope and denies it under the empty runtime policy.

## Approval workflow

`GitHubTeamMembershipAdapter` accepts only numeric GitHub user IDs and uses organization and team IDs fixed at construction; it does not accept a repository, host, or team scope from the request. `ApprovalEvidenceVerifier` delegates signature verification to a trusted verifier client, then checks the exact issuer, audience, claim schema, and validity window. `ApprovalWorkflow` requires an external atomic replay store; the unconfigured default denies rather than relying on process-local state. No token format or cryptographic mechanism is invented.

## Audit and emergency stop

`AuditPipeline` requires separate primary and emergency sink adapters with distinct declared failure domains. It appends and verifies both sinks, including when one fails, and fails closed unless both succeed. Sink adapters must return literal `true` only after a successful append and integrity verification, and normalize known storage failures to `AuditFailure`; false or indeterminate results deny the operation. The adapter contract requires durable, append-only, tamper-evident storage; no production sink or retention policy is configured. The local JSONL adapter used by the isolated CLI is diagnostic only: it fsyncs a restricted ephemeral file but is not durable or tamper-evident.

`EmergencyStopController` has a non-resettable process latch, persists the stop through a state-store adapter, asks an independent supervisor to deny admission and terminate active brokers, records stop and revocation outcomes through the audit pipeline, and attempts revocation of every active credential. State-store and supervisor adapters must return literal booleans; indeterminate results deny work. The in-memory registry tracks credentials by request ID but is not crash recovery. The external stop store, supervisor, operator identity, and crash-surviving revocation coordinator remain unconfigured; test adapters and chained audit sinks are fakes, not production controls.

## Remaining blockers

- Select and integrate independently verifiable requester identity and human approval services.
- Select durable primary and independent emergency audit services with immutable retention and separate administration.
- Integrate an operator-controlled stop and revocation coordinator that can act independently of the broker, including after broker failure.
- Validate the external issuer's repository/permission scope, hard expiry, revocation, and failure recovery.
- Complete the provider permission/API-action matrix and dedicated handlers before considering any operation.
- Select an eligible non-production repository for later operation-specific validation.

No merge, release, approval, branch, issue, repository, or organization operation is enabled by this foundation.

## Validation

From the repository root, run:

```sh
scripts/test-maintainer-broker.sh
```

The Ruby tests use only the standard library and test-only placeholder credentials. The Docker Compose service is isolated and does not inherit workstation mounts or secrets.
