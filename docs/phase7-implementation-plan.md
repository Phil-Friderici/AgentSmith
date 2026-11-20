# Phase 7 Implementation Plan: Level 3 Maintainer Operations

## Status and boundaries

This plan decomposes [ADR-0010](adr/0010-maintainer-operations-strategy.md) into implementation and validation phases. It does not itself authorize maintainer operations, issue credentials, enable a capability, or change the paused status of Phase 6b.

ADR-0010 is Accepted, satisfying the formal governance gate for implementation planning and Phase 7a. This acceptance does not enable any Level 3 operation. Each operation remains disabled until its own phase exit criteria pass and a maintainer separately authorizes its use.

The implementation must preserve the boundaries in ADR-0004 through ADR-0009. The Level 3 broker is separate from the workstation, Phase 6b contribution broker, acceptance controller, worker, and targets. It receives no persistent workstation state, workspace, repository checkout, or unrelated credentials.

**Current implementation state:** The disabled Phase 7a boundary and Phase 7b control framework are implemented in [`containers/maintainer-broker/`](../containers/maintainer-broker/), with a separate [Compose profile](../compose/phase7a-broker.yaml). Fail-closed contracts now exist for Team membership, approval evidence/replay verification, credential issue/revocation, durable audit, and emergency-stop supervision. The preferred identity/approval provider stack and Entra fallback are documented in the [Phase 7 provider selection](phase7-identity-approval-provider-selection.md); integration work packages and contracts are defined in the [Phase 7 provider integration plan](phase7-provider-integration-plan.md), with safe provider validation in the [Phase 7 provider integration validation plan](phase7-provider-integration-validation-plan.md). No production provider is connected. Phases 7a and 7b are not complete: the approval service, GitHub/Entra clients, provider permission/API-action mapping, credential issuer, durable primary and emergency audit services, external stop/revocation supervisor, and a non-production test repository remain blockers.

## Recommended implementation order

1. **Governance gate (complete):** ADR-0010 has been accepted, and the identity/approval provider selection is documented. Select a non-production test repository and the owners for approval-service integration, credential issuance, audit, and emergency stop before mutation testing.
2. **Phase 7a:** Build the disabled broker foundation, operation policy, approval-evidence contract, and credential lifecycle adapters.
3. **Phase 7b:** Connect human approvals, tamper-evident audit, emergency stop, and revocation/recovery orchestration following the [provider integration work packages](phase7-provider-integration-plan.md). Keep all remote mutations disabled.
4. **Phase 7c:** Implement and validate only PR merge and text-only draft release creation against the non-production repository.
5. **Phase 7d:** If separately approved, add the other operations already listed in ADR-0010, one operation at a time.
6. **Phase 7e:** Consider per-operation, per-repository enablement only after all applicable gates pass and a maintainer makes a separate explicit decision.

Do not parallelize phases that share the approval, credential, or audit trust boundary. Unit tests and isolated test harnesses may be developed independently, but integration and mutation testing follow the order above.

## Phase 7a — Broker and authorization foundation

**Objective:** Establish the smallest deny-by-default execution foundation without enabling a maintainer action.

**Scope and work packages**

- **7a.1 Broker boundary:** Create a disposable, one-operation execution boundary with a read-only root filesystem, private ephemeral writable storage, non-root identity, and no workspace, home, `.git`, Docker socket, virtualization device, or inherited workstation configuration.
- **7a.2 Operation policy:** Implement a versioned, trusted policy format with an empty default allowlist. Bind a request to an exact repository, operation, resource, and expected revision. Reject wildcards, unknown operations, unknown fields, and policy supplied by a repository or prompt.
- **7a.3 Operation handlers:** Define a separate handler interface for each operation. Each handler has a static provider method/endpoint/parameter allowlist; do not expose a generic `gh`, raw API, shell, or user-controlled method/path/flags.
- **7a.4 Permission mapping:** Record the provider permission set and API actions required per operation. Identify permissions that span multiple actions. If the handler cannot prove and test denial of other actions covered by a permission, mark the operation unsupported and disabled.
- **7a.5 Approval evidence contract:** Define how handlers consume action-bound, single-use approval evidence, including operation, repository, resource, expected revision, approver identity, expiry (at most 10 minutes), request ID, and policy version. Do not create a custom cryptographic token format; use an independently verifiable identity/approval mechanism selected under ADR-0010.
- **7a.6 Credential lifecycle adapter:** Define issue, use, revoke, and expiry-verification interfaces. Enforce exact repository and minimum provider permissions, a provider-enforced lifetime of no more than one hour, and access only by the selected handler. Use mock/test credentials until the approval and external issuer gates are complete; no production maintainer credential is issued.

**Security gates**

- ADR-0010 is Accepted before implementation begins.
- Operation allowlists default empty and cannot be changed through agent input.
- The broker cannot read workstation or repository state and cannot invoke arbitrary commands or network destinations.
- Provider permission scope is not misrepresented as operation scope; shared-permission actions fail closed unless handler isolation is demonstrated.
- No real remote mutation or production credential is available in this phase.

**Validation requirements**

- Unit tests for strict request schema, policy versioning, exact target binding, and default-deny behavior.
- Authorization tests for unknown operation, repository/resource mismatch, wildcard target, changed revision, unsupported API route, and cross-operation dispatch under shared token permissions.
- Broker isolation tests for effective user, mounts, environment, filesystem writes, process execution, and outbound destinations.
- Credential isolation tests using test credentials: only the handler receives the credential; it is absent from environment dumps, logs, audit, process output, workspace, and persistent storage.
- Lifecycle state-machine tests for issuance only after valid approval evidence, one operation, immediate revoke, expiry, failure, timeout, and unverifiable revocation.

**Exit criteria**

- The broker and handler skeleton passes isolation and denial tests.
- The versioned operation-to-provider-permission/API-action matrix is reviewed.
- Approval evidence can be validated through a selected, independently verifiable mechanism or remains an explicit integration blocker.
- Credential lifecycle behavior is proven with test credentials and provider/test doubles.
- All remote operations remain disabled.

## Phase 7b — Approval, audit, stop, and recovery controls

**Objective:** Connect trusted human authorization and operational controls before implementing mutation handlers.

**Scope and work packages**

- **7b.1 Approval workflow:** Implement the action display, identity verification, approval collection, evidence issuance, expiry, single-use, and replay prevention required by ADR-0010. Bind every approval to the exact operation, target, and revision.
- **7b.2 Audit pipeline:** Write an intent record durably before credential issuance. Record outcomes, denials, expired/replayed requests, revocation status, emergency stops, and post-action verification without secrets or unbounded output.
- **7b.3 Audit integrity:** Configure a sink outside AgentForge and the broker with provider-enforced immutable retention or equivalent tamper-evident records. Give the broker append-only access; separate sink administration; test periodic integrity checks and the independent emergency audit path.
- **7b.4 Emergency stop:** Provide an operator-controlled stop outside the agent session. It must deny new work, terminate active brokers, prevent resumption, initiate credential revocation, preserve audit evidence, and require review before re-enable.
- **7b.5 Revocation orchestration:** Track active credentials by operation/request ID; revoke on success, failure, timeout, suspected exposure, broker termination, or stop. Verify revocation or provider expiry. Reconcile ambiguous remote outcomes read-only; never blindly retry or auto-rollback.

**Security gates**

- The audit intent and emergency audit path are available before credentials can be issued.
- Approver identities are independently verified; an agent cannot approve its own request.
- Single- and dual-approval rules are enforced by trusted code, not prompts.
- The emergency stop and revocation path do not depend on the agent session or broker remaining healthy.
- If audit, approval verification, revocation, or state reconciliation is unavailable, the operation fails closed.

**Validation requirements**

- Approval tests for exact-target/revision binding, 10-minute expiry, single use, replay, changed state, distinct identities, and requester/author restrictions.
- Audit integrity tests for attempted record alteration/deletion, chain/signature or immutable-retention verification, duplicate/missing records, sink outage before action, and failure after remote mutation.
- Secret-scanning tests covering audit records, broker output, logs, process environment, and artifacts.
- Emergency-stop tests during idle, credential-issued, and in-flight states; verify no new work, termination, audit, and no automatic restart.
- Revocation tests for success, failure, timeout, broker crash, issuer outage, remote ambiguity, and expired-but-unconfirmed tokens.
- Recovery tests verify that unresolved actions require read-only inspection and fresh approval before any further mutation.

**Exit criteria**

- Approval evidence is trusted, operation-bound, short-lived, and replay-resistant.
- Primary and emergency audit paths pass integrity and failure-injection tests.
- Emergency stop works independently and leaves Level 3 disabled pending review.
- Credential revocation or expiry is verified across all tested termination and failure paths.
- No merge or release action is enabled yet.

## Phase 7c — Merge and draft-release operations

**Objective:** Implement and validate the first two consequential operation classes using the approved broker and controls.

**Entry gate:** All Phase 7b integration packages and exit criteria must pass, the provider integration validation plan must be satisfied, and an eligible non-production repository must be available. The integration plans do not rename Phase 7c or authorize mutations.

**Scope and work packages**

- **7c.1 Merge:** Implement explicit PR merge only. Require two distinct maintainer approvals bound to the exact PR and head SHA; neither approver may be the PR author, and the second approver cannot be the request initiator. Re-read PR head, checks, reviews, and branch-protection/ruleset state immediately before the action. The Level 3 identity must not be a bypass actor.
- **7c.2 Draft release:** Implement creation of a text-only draft from a pre-existing, verified tag protected against mutation and resolving to the approved commit. Require two distinct maintainer approvals bound to the exact tag, commit, and release metadata.
- **7c.3 Release workflow eligibility:** Review release-event, tag-push, reusable, and downstream workflow paths, permissions, third-party actions, and secret access for the non-production repository. Test the applicable event path before enabling draft creation.
- **7c.4 Failure recovery:** Exercise provider errors, changed state, timeouts, uncertain results, audit failure, broker termination, and failed revocation for each operation.

**Explicit exclusions:** No auto-merge, merge queue automation, branch-protection bypass, tag creation/movement/deletion, release publication, assets/artifacts, package publication, release deletion/withdrawal, rollback, or production repository use.

**Security gates**

- Only a disposable, non-production repository with owner-configured protections is eligible.
- No merge occurs unless required independent review, checks, and protection rules are present and freshly verified.
- No draft release is created unless its tag and commit are verified and the repository's event workflow review passes.
- Shared provider permissions cannot bypass the handler's static action allowlist.
- Every attempt is audited; failure, ambiguity, or loss of a required control stops the operation and leaves the capability disabled.

**Validation requirements**

- Positive and negative authorization tests for merge and draft creation, including wrong repository/PR/tag, changed head/tag target, expired/replayed approval, and insufficient approvers.
- Merge denial tests for missing/failed checks, missing/invalid independent review, PR-author approver, changed head SHA, protected-state mismatch, and bypass-capable identity.
- Draft-release denial tests for mutable/unprotected/mismatched tag, changed metadata, unsafe/unreviewed workflow, and any request to publish or attach assets.
- End-to-end audit, credential confinement, revocation, and post-operation state verification for both successful and failed operations.
- Failure-path and emergency-stop tests with test credentials in the non-production environment.

**Exit criteria**

- Each operation passes its positive, denial, failure, recovery, isolation, audit, and credential-lifecycle tests independently.
- Non-production evidence is reviewed by maintainers and records exact policy, broker, issuer, repository-rule, and workflow versions.
- The operations remain unavailable to normal workstation profiles and Phase 6b.
- Production enablement requires a separate explicit approval; this phase does not grant it.

## Phase 7d — Remaining ADR-0010 operation classes

**Objective:** Add any remaining operations from ADR-0010 without expanding its allowlist.

Implement one operation at a time: PR approval, non-protected branch creation, eligible non-default branch deletion, and the explicitly limited issue-moderation actions. Apply each operation's approval count, exact target/revision binding, provider permission/API-action mapping, handler allowlist, audit, revocation, and denial tests. Repository/organization administration, settings changes, arbitrary comments, issue/comment deletion, and other excluded actions remain unsupported.

Each operation requires its own non-production validation and maintainer acceptance. Skipping an operation is valid; it remains disabled unless and until its own evidence and approval exist.

## Phase 7e — Per-operation enablement

**Objective:** Consider controlled enablement only after all applicable implementation and validation gates pass.

For each operation/repository pair, maintainers review the evidence, confirm repository eligibility and workflow safety, verify branch protections and provider-side permissions, confirm audit/stop/revocation readiness, and issue a fresh explicit authorization. Enable only the reviewed operation and repository. Any policy, token, GitHub, broker, workflow, or repository-rule change invalidates the relevant evidence and returns that operation to disabled pending revalidation.

This plan does not authorize or perform enablement. Phase 6b remains paused and separate.

## Cross-phase validation strategy

| Test family | Required evidence |
|---|---|
| Operation authorization | Exact operation/resource/revision grants work; unsupported routes, shared-permission cross-actions, altered targets, and stale state are denied. |
| Audit integrity | Intent precedes credential issue/action; broker cannot alter/delete records; integrity checks detect tampering; failures and denials are recorded without secrets. |
| Credential isolation | Minimum repository permission set, hard expiry of at most one hour, handler-only access, no persistence/output leakage, and verified revocation/expiry on every exit. |
| Broker isolation | Separate one-shot identity/container; no workstation/workspace/home/`.git` mounts, inherited credentials, general shell, arbitrary API, or unrestricted egress. |
| Denial paths | Expired/replayed approval, wrong identity, unsupported operation, changed SHA/tag, unprotected target, failed check, unsafe workflow, unavailable audit, or unexpected scope all fail closed. |
| Emergency stop | External stop blocks new work, terminates active work, invokes revocation, records the event, prevents restart, and requires review. |
| Revocation and recovery | Success, failure, timeout, broker death, issuer outage, and ambiguous remote outcomes reach verified revocation/expiry and safe read-only reconciliation without blind retries or rollback. |

Tests begin with unit and mocked-provider tests, then use an isolated non-production repository and test credentials. Production credentials and production repositories are not used for validation. No test may silently weaken branch protection, audit, credential scope, isolation, or cleanup to make a run pass.

## Open risks and planning dependencies

- ADR-0010 is Accepted. The external approval/identity mechanism, credential issuer, audit services, and eligible non-production repository remain implementation dependencies.
- The preferred GitHub-backed identity/approval stack is selected, but the service, GitHub Team membership adapter, evidence verifier, credential issuer, audit services, and Entra fallback remain unimplemented and unvalidated.
- GitHub permission sets are coarser than individual API actions; handler-level separation must be demonstrated for every enabled operation.
- A suitable non-production repository, independently managed branch protections, and safe release-event workflows are prerequisites for Phase 7c.
- Durable tamper-evident primary and emergency audit services, retention, ownership, and incident review responsibilities must be available before credential issuance.
- Revocation may be delayed or fail during provider/network outages; every credential therefore needs the ADR-mandated hard expiry and verified fail-closed recovery.
- A compromised handler-scoped token can still exercise actions within its provider permission set until revocation or expiry; minimize scope and keep the handler boundary small.
- Human dual approval increases latency and coordination requirements for merge and draft-release operations.

## Recommendation

**A — Phase 7a may proceed; the formal ADR-0010 acceptance gate is satisfied.** This does not issue credentials, enable a capability, authorize a maintainer operation, or unblock Phase 6b.
