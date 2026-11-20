# Phase 7 Provider Integration Plan

## Status and phase boundary

This plan defines the external integrations required to complete the Phase 7b control foundation before Phase 7c begins. The existing [Phase 7 implementation plan](phase7-implementation-plan.md) remains authoritative: Phase 7c is PR merge and text-only draft-release implementation. This document does not rename phases, implement providers, enable an operation, or amend [ADR-0010](adr/0010-maintainer-operations-strategy.md).

The preferred GitHub-backed identity and approval provider, with an Entra ID fallback, is selected in the [Phase 7 Identity and Approval Provider Selection](phase7-identity-approval-provider-selection.md). No production integration is configured. Until every Phase 7b exit criterion passes, the broker must remain fail-closed and all Level 3 operations disabled.

## Control flow and ordering

```text
Immutable operation request
    ↓
Approval service authenticates humans and checks GitHub Team eligibility
    ↓
Short-lived, action-bound approval evidence
    ↓
Broker verifies evidence and records durable audit intent
    ↓
External issuer supplies one-operation credential
    ↓
Isolated handler performs one allowlisted action and verifies remote state
    ↓
Audit completion and verified credential revocation/expiry

External operator stop ──→ shared stop state, broker termination,
                           independent audit, credential revocation
```

Audit, emergency stop, and revocation integrations must be in place and failure-tested before the production credential issuer can issue a credential. Provider integration tests use fakes or a non-production environment. The production issuer remains disabled until all components and denial paths pass.

## Component contracts

### 1. GitHub Team membership adapter

**Responsibility:** Determine whether a human approver's authenticated GitHub account is currently eligible by membership in the configured maintainer Team. It answers eligibility only; it does not represent consent to a request.

**Trust boundary:** Approval service to GitHub API through a dedicated read-only GitHub App identity. The organization ID, team ID, and permitted GitHub host are service-owned configuration, not request fields. Do not reuse the operation execution identity or an agent-provided token.

**Inputs:** Immutable GitHub numeric user ID; configured organization and Team IDs; request/correlation ID; check time.

**Outputs:** A fresh eligible/not-eligible decision, checked identity and Team identifiers, check timestamp, and provider request/correlation metadata. Return a typed unavailable/indeterminate result separately from “not a member”; both deny approval.

**Failure behavior:** Fail closed on timeout, rate limit, permission error, unknown team, identity mismatch, stale mapping, or incomplete provider response. Do not use cached positive membership. If identity-provider Team synchronization may lag, require an operator-controlled denylist/stop path and keep Level 3 disabled until removals are confirmed.

**Validation tests:**

- Confirm an eligible numeric user ID is accepted only for the configured organization and Team.
- Deny a non-member, outside collaborator, wrong-organization user, wrong Team, and mutable-login-only identity.
- Deny on timeout, 403/404 ambiguity, rate limiting, malformed response, and stale identity mapping.
- Prove positive membership is not reused after a removal or Team change.
- Verify the adapter identity can read membership but cannot modify Teams, repositories, rulesets, or settings.
- Test membership removal and the emergency denylist when Team synchronization is delayed.

### 2. Approval evidence service

**Responsibility:** Authenticate each human approver, present the exact operation challenge, check current eligibility, collect explicit per-operation consent, and issue evidence only after every required distinct approver has approved.

**Trust boundary:** A separately operated service outside the broker, AgentForge workstation, target repository, and agent session. It uses individual GitHub authentication and the Team adapter; an App installation identity is never treated as a person. The Entra fallback must satisfy the same contract and map the authenticated person to an immutable GitHub user ID.

**Inputs:** Immutable challenge containing operation, canonical repository, resource, expected revision, request ID, policy version, requester, required approver count, and deadline; authenticated user identity; current Team eligibility result.

**Outputs:** Independently verifiable evidence with issuer, audience, approver user IDs, exact challenge bindings, issue/expiry times (at most 10 minutes), policy version, and a single-use nonce. It contains no GitHub credential or secret. Each approval and denial receives a durable correlation ID.

**Failure behavior:** Denial, identity-provider outage, membership uncertainty, mismatched/stale challenge, insufficient or duplicate approvers, requester/agent self-approval, PR-author approval where prohibited, audit failure, or expiry produces no usable evidence. Never silently downgrade dual approval to single approval or fall back to local confirmation.

**Validation tests:**

- Verify the approval display exactly matches the request fields, including commit/tag/revision and consequential metadata.
- Deny edited or changed challenges, stale revisions, expired approvals, wrong audience/issuer, and incomplete approval counts.
- Require distinct human IDs; test requester, agent, and PR-author denial rules from ADR-0010.
- Prove two approvals are independent, tied to the same immutable challenge, and cannot be combined across requests.
- Test cancellation, denial, identity-provider outage, Team-adapter outage, audit outage, and approval-service restart.
- Prove Entra fallback requires explicit configuration and the same controls; no automatic source switching.

### 3. Token/evidence verifier

**Responsibility:** Independently verify approval evidence and ensure it authorizes exactly the current request. Verify credential issuance metadata against the trusted request and operation policy before any handler can receive the credential. Do not infer identity or permission from an unverified token string.

**Trust boundary:** The verifier runs in the broker's trusted authorization path and uses a pinned verifier endpoint or trusted issuer keys configured outside repository/workspace state. Nonce consumption is atomic in an external shared store so replay protection spans broker instances; the existing in-process replay guard is defense in depth only.

**Inputs:** Evidence bytes/reference; exact typed request and operation specification; current time; trusted issuer/audience/key configuration; nonce-consumption service. For credentials: issuer response plus expected repository, permission set, lifetime, and request ID.

**Outputs:** Verified approver identities and claims, an atomic single-use decision, and a credential metadata result containing exact repository, permission set, expiration, and provider reference. The credential value is delivered only through the isolated credential channel to the selected handler.

**Failure behavior:** Reject unknown issuer/key, invalid signature or provider assertion, wrong audience, missing/extra claims, mismatched operation/target/revision/policy, invalid identity binding, expired/future evidence, replay, or unverifiable credential scope/expiry. No handler dispatch occurs.

**Validation tests:**

- Test valid evidence and each individual claim-binding mismatch.
- Test invalid signature, rotated/unknown key, wrong issuer/audience, expiry boundaries, malformed claims, and unsupported evidence format.
- Race two independent broker instances against the same nonce; at most one may succeed.
- Test verifier outage, nonce-store outage, stale key set, and credential metadata mismatch; all deny.
- Verify token values are never parsed as identity assertions, logged, audited, or returned in errors.

### 4. Credential issuer integration

**Responsibility:** After verified approval and durable audit intent, mint or obtain a provider credential limited to one operation, exact repository, minimum supported permission subset, and provider-enforced lifetime no greater than one hour. Revoke it or verify expiry at operation completion.

**Trust boundary:** External credential issuer and its signing material remain outside AgentForge, the broker, workstation, repository, and audit sinks. The broker communicates only with the fixed issuer endpoint using its narrowly scoped workload identity. The actual issuer implementation must be selected and approved before integration; this plan does not authorize persistent PATs or place App private keys in the broker.

**Inputs:** Verified request and approval reference; operation-to-permission/API-action mapping; exact repository; request ID; required expiry bound; issuer-side policy version.

**Outputs:** Ephemeral credential handle/value for the designated handler, plus independently verifiable metadata: credential type, issuer, repository scope, permissions, expiry, and revocation reference. Only non-secret metadata enters audit.

**Failure behavior:** Do not issue if approval or audit intent is unverified, scope is broader than requested, the repository cannot be pinned, expiry exceeds policy, or issuer status is uncertain. On partial/ambiguous issuance, treat a credential as potentially active and immediately reconcile/revoke it; do not dispatch the operation.

**Validation tests:**

- Prove issuance happens only after approval verification and durable intent.
- Deny broader-than-requested repository/permission scope and lifetime over one hour.
- Test issuer denial, timeout before/after mint, malformed response, duplicate request ID, and unknown credential status.
- Verify credentials reach only the selected handler, never environment dumps, logs, audit, chat, persistent storage, or unrelated processes.
- Test an actual non-production credential's repository/permission scope, hard expiry, and revocation after success, failure, timeout, and broker termination.

### 5. Audit integration

**Responsibility:** Durably record identity decisions, approval evidence metadata, intent before credential issuance, execution result, state verification, denial, credential status, stop, and recovery events. Provide a primary sink and an independently operated emergency sink with tamper-evident integrity verification.

**Trust boundary:** Both sinks are outside the broker, AgentForge repository, and target repository, and have separate failure domains and administration. The broker may append and verify but cannot alter or delete records. The credential issuer and approval service do not control sink administration.

**Inputs:** Structured, bounded, secret-free records with request/operation IDs, UTC times, actor/approver IDs, exact target and revision, policy/broker versions, decision/result, credential metadata, and verification/revocation status.

**Outputs:** Durable receipts and integrity-verification result from both sinks; no success or credential issuance without verified required audit writes.

**Failure behavior:** Before action, either required sink failing prevents credential issuance and mutation. After a possible remote action, stop new work, revoke credentials, preserve the unresolved outcome through the emergency sink/operator incident path, and require read-only reconciliation. Do not claim success or blindly retry.

**Validation tests:**

- Verify intent receipt and integrity before issuer invocation.
- Inject primary and emergency sink outages independently, plus shared-domain misconfiguration.
- Verify append, immutability, retention, integrity-check, duplicate/missing-event, and reconciliation behavior.
- Fail the audit path before action and after a simulated remote mutation; assert correct denial/stop/revoke behavior.
- Scan every sink record and error path for secrets, tokens, private claims, environment data, or unbounded output.
- Verify retained metadata meets ADR-0010's minimum 365-day retention and quarterly review requirements.

### 6. Emergency stop integration

**Responsibility:** Provide an operator-controlled, out-of-band stop independent of the agent session and broker. Deny new Level 3 work, terminate active broker instances, prevent restart/resumption, request credential revocation, and preserve incident/audit evidence.

**Trust boundary:** An external supervisor/control plane and durable shared stop-state store, operated under identities separate from the approval service, broker, and agent. Stop authority is not available through agent requests, repository files, or approval evidence.

**Inputs:** Authenticated operator identity, reason code, timestamp, stop scope, active request/credential references, and a monotonic stop generation/version.

**Outputs:** Durable latched stop state, supervisor acknowledgement of admission denial and active-process termination, revocation job references, and independently audited incident ID. Re-enable requires a separate reviewed operator action; it is not part of this phase's runtime agent interface.

**Failure behavior:** Stop locally and deny new work immediately even if persistence or audit is unavailable. Attempt revocation independently. Report the stop as incomplete unless durable state, supervisor action, audit, and revocation initiation are confirmed. No new operation may start while state is unknown.

**Validation tests:**

- Trip while idle, before credential issuance, after issuance, and during an in-flight simulated operation.
- Verify shared-state denial across broker instances, process termination, no automatic restart, and no new admissions.
- Inject stop-store, supervisor, audit, and revocation-service failures independently; assert fail-closed state and visible incomplete status.
- Test repeated stop calls are idempotent and only an authenticated, reviewed operator path can re-enable.
- Confirm stop operation logs contain no secrets and are retained through primary-audit outage.

### 7. Revocation integration

**Responsibility:** Track each issued credential by request ID and coordinate provider revocation or provider-enforced expiry verification after every terminal path, emergency stop, broker loss, or suspected exposure. Preserve unresolved entries until remote status is confirmed.

**Trust boundary:** External revocation coordinator/issuer API operates independently of the ephemeral broker and survives broker/container termination. The in-memory registry is a cache, not the source of truth or a crash-recovery mechanism.

**Inputs:** Issuer credential reference (never the secret in audit), request/operation ID, expiry, stop/incident state, and terminal reason; external issuer status/revocation response.

**Outputs:** Verified revoked/expired result and timestamp, or an explicit unresolved status with durable retry/reconciliation work item. No credential is considered closed because a local file or memory buffer was cleared.

**Failure behavior:** Retain unresolved status, deny new Level 3 operations, alert the external operator, and retry only idempotent revocation/status checks under bounded backoff. Do not retry the original remote mutation. If issuer status cannot be verified before hard expiry, keep the incident open and Level 3 disabled.

**Validation tests:**

- Verify revocation and remote confirmation after success, denial after issuance, handler failure, timeout, and emergency stop.
- Simulate broker crash between issuance and local registration; external reconciliation must discover and revoke the credential by durable request reference.
- Test issuer outage, delayed revocation, already-revoked response, expiry, duplicate revocation, and ambiguous status.
- Verify failed revocation remains visible and blocks re-enable; local destruction alone is insufficient.
- Confirm credentials are revoked or expiry is verified within the configured maximum lifetime.

## Integration work packages before Phase 7c

These are completion packages for the existing Phase 7b control phase, and are mandatory Phase 7c entry criteria.

| Package | Scope and dependency | Exit evidence |
|---|---|---|
| **7b-I0: Service ownership and contracts** | Name owners for GitHub Apps/Teams, approval service, issuer, audit sinks, stop supervisor, and incident review. Approve service endpoints, trust roots, data retention, fixed configuration, and the non-production repository. | Reviewed data-flow/trust-boundary diagram; fixed adapter contracts; no runtime credentials in the repository or broker image. |
| **7b-I1: GitHub identity and Team adapter** | Provision separate read-only membership identity, bind immutable org/team IDs, implement fresh membership checks and revocation/denylist path. | Membership, outage, permission-boundary, and stale-sync tests pass. |
| **7b-I2: Human approval service** | Implement GitHub-authenticated approval display and collection; implement the Entra adapter only if deliberately selected for fallback testing. | Challenge binding, distinct-approver, denial, expiry, and audit tests pass; no auto-failover. |
| **7b-I3: Evidence verifier and replay service** | Integrate the independent verifier, trust roots/key rotation, typed claims, and atomic cross-instance nonce consumption. | Positive, tamper, binding, expiry, replay-race, and outage tests pass. |
| **7b-I4: Primary and emergency audit** | Integrate independent append-only sinks, retention, integrity checks, receipts, and incident path. | Pre-action and post-action sink-failure tests pass; intent is verified before any issuer request. |
| **7b-I5: Revocation coordinator and stop supervisor** | Integrate durable credential tracking, external stop state, active-worker termination, and crash-surviving revocation. | Crash, in-flight stop, issuer outage, and unresolved-revocation tests pass; re-enable remains operator-gated. |
| **7b-I6: Credential issuer** | Integrate the approved external issuer only after I1-I5 controls are operational. Keep issuance feature-disabled until the complete integration suite passes. | Non-production proof of exact repository/permission scope, hard expiry, handler-only access, and verified revocation. |
| **7b-I7: Phase 7b acceptance** | Run integrated denial, failure, recovery, isolation, audit, emergency-stop, and revocation scenarios in the eligible non-production environment. | Maintainer-reviewed evidence satisfies all Phase 7b exit criteria; Level 3 remains disabled pending separate Phase 7c operation acceptance. |

No package may skip its exit evidence because a mock or interface test passed. Fakes remain useful for unit and failure-injection tests but do not validate provider identity, permissions, durability, expiry, revocation, or independent control.

## Phase 7c implementation work packages

Phase 7c starts only after all 7b-I packages pass and an eligible non-production repository has independently configured protections.

1. **7c.0 Common execution gate:** Freeze the policy and handler versions; verify the approval, audit, issuer, stop, and revocation dependencies are healthy. Keep each operation disabled by default and select one operation/repository at a time.
2. **7c.1 PR merge handler:** Implement only explicit merge. Require two distinct action-bound approvals; reject PR-author approvals and requester as second approver; re-read exact head SHA, independent reviews, checks, and ruleset state; deny bypass-capable identity and any uncertainty.
3. **7c.2 Draft-release handler:** Implement text-only draft creation from an existing protected tag and verified commit. Bind approval to exact tag, commit, and release metadata; prohibit tag mutation, publication, assets, and package operations.
4. **7c.3 Release workflow eligibility:** Review tag/release-triggered and downstream workflow paths, permissions, third-party actions, and secrets. Validate in the non-production repository; keep release creation disabled if any path is unreviewed.
5. **7c.4 Operation-specific failure/recovery:** Test changed state, provider timeout, ambiguous mutation, audit failure, stop during execution, and failed/uncertain revocation separately for merge and draft release. Require read-only reconciliation and fresh approval; never blindly retry or auto-rollback.
6. **7c.5 Evidence review and capability decision:** Have maintainers review exact repository rules, policy, handler, provider scope, audit records, stop/revocation evidence, and test results. Any enablement is a separate explicit decision; this plan itself does not authorize it.

## Cross-component integration tests

Before Phase 7c:

- **Ordering:** Approval and identity checks precede audit intent; verified intent precedes credential issuance; credentials are revoked/expired and audit completion verified before the request closes.
- **Fail closed:** Independently fail every provider, verifier, audit sink, stop store, supervisor, issuer, and revocation dependency. Confirm no mutation starts if a prerequisite is unavailable.
- **Race and replay:** Concurrently submit the same evidence to separate broker instances and revoke approver membership between approval and action. No stale/replayed approval may authorize.
- **Compromise:** Simulate approval-key rotation/compromise, approver removal, credential exposure, broker crash, and stop activation. Confirm external revocation, durable incident records, and disabled Level 3.
- **Isolation and non-disclosure:** Scan broker output, logs, audit, environment, temporary storage, and test artifacts. No credential or private key may appear; only the designated handler receives the credential.
- **Recovery:** For any uncertain remote outcome, verify read-only reconciliation, no mutation retry, fresh approval, and explicit operator review before re-enable.

## Remaining blockers

- Owners and actual service deployments for the approval provider, issuer, audit sinks, stop supervisor, and revocation coordinator have not been selected or configured.
- The production GitHub organization, fixed Team IDs, App registrations/permissions, Entra tenant/fallback decision, and eligible non-production repository must be supplied and reviewed.
- Provider-level proof of immutable audit retention, hard credential expiry, immediate stop, and crash-surviving revocation is outstanding.
- No Phase 7c merge or release handler may be enabled until all Phase 7b integration packages and operation-specific tests pass.
