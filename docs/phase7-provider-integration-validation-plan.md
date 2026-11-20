# Phase 7 Provider Integration Validation Plan

## Status and boundaries

This plan evaluates real provider choices and defines safe pre-operation validation. It does not configure providers, use production credentials, enable merge/release, or perform repository mutations. Phase 7a, Phase 7b, and the Phase 7c prerequisite interfaces are implemented, but all runtime providers remain test doubles or fail-closed placeholders.

The plan preserves [ADR-0010](adr/0010-maintainer-operations-strategy.md): approvals are explicit, action-bound, single-use, and no longer than 10 minutes; credentials are one-operation, repository-scoped, and provider-expire within one hour; audit, stop, and revocation failures deny or halt work. Phase 7c remains PR merge and text-only draft-release implementation, and is not authorized by this validation plan.

## Provider decision summary

| Integration | Preferred provider | Fallback | Decision |
|---|---|---|---|
| GitHub Team eligibility | GitHub REST API using a dedicated read-only GitHub App identity; the approval service resolves the authenticated GitHub user to an immutable account ID and checks active membership in a fixed, non-nested Team. | GitHub GraphQL only if REST permissions or required fields cannot be supported; independently validate query completeness, IDs, pagination, and membership semantics. | REST is the simplest auditable path for the Team membership state. GitHub App is the authentication identity, not an alternative to REST. |
| Approval evidence | GitHub-authenticated external approval service, with a standard signed or opaque verifiable evidence envelope and external atomic replay store. | Entra ID OIDC for human authentication into the same service; no automatic failover. | Signed evidence is a transport/verification mechanism, not an identity source. GitHub Actions OIDC alone is not human approval. |
| Credential issuance | External issuer mints GitHub App installation tokens for an exact repository and explicit permission subset. | No PAT fallback. If an App token cannot support a specific operation, leave that operation unsupported until a separately reviewed credential design exists. | GitHub App installation tokens best fit the short-lived and scoped requirements; app private keys remain outside AgentForge. |
| Audit storage | External append-only audit writer backed by S3 Object Lock in a separately administered account, with versioning and compliance-mode retention of at least 365 days. | Another independently administered external audit service with equivalent immutable retention, integrity verification, and emergency path. | Local files and SQLite may be diagnostic/spool storage only, never the authoritative audit record. AWS account, ownership, and deployment are not yet selected. |
| Emergency stop | External operator-controlled control plane with durable shared stop state, process supervision, and direct revocation coordination. | Host-level operator-owned supervisor plus protected local stop signal, only for a single-host deployment and only if it can stop all broker instances and reach the independent revocation service. | A file or GitHub-hosted signal alone is insufficient. No concrete control-plane product is selected. |
| Revocation | GitHub App installation-token revoke endpoint plus an external durable coordinator that tracks issued credentials independently of the broker. | Provider-enforced expiry, no later than one hour, followed by read-only verification; unresolved status keeps Level 3 disabled. | Local secret deletion is not revocation. External issuer and coordinator remain unconfigured. |

These are recommended integration patterns, not evidence that the required GitHub organization, Entra tenant, AWS account, App registrations, or operational owners exist. Provider deployment remains gated on those prerequisites.

## Evaluation by integration

### 1. GitHub Team eligibility

**Preferred approach:** Authenticate the human in the external approval service using GitHub user authentication. Resolve the authenticated account to its numeric GitHub user ID and current login; do not accept a login or organization/team identifier supplied by the agent. Use a separate read-only GitHub App installation token for Team lookup against a fixed organization and Team configuration.

Use the REST membership endpoint and accept only `state: active`; `pending`, missing, malformed, or indeterminate membership denies approval. The endpoint is username-addressed, so the approval service must derive the login from the authenticated GitHub account and bind the result back to its numeric user ID. Keep the eligibility Team non-nested and disallow inherited membership ambiguity. The membership check must be performed at approval time and again immediately before credential issuance/action.

| API option | Evaluation |
|---|---|
| GitHub App | Preferred authentication identity for the read-only lookup. Grant only the organization Members read permission required by the supported endpoint. Keep this identity separate from the operation execution App. Installation tokens are scoped to granted installations and can be narrowed to repositories/permissions where supported. |
| REST API | Preferred API. The Team membership endpoint returns a state and role, including active/pending behavior; a missing membership is denied. A membership list can return immutable numeric user IDs and inherited status, but requires complete pagination and careful handling of nested teams. Use fixed IDs/slugs and an explicit API version. |
| GraphQL API | Viable fallback if it can return the same immutable user identity and membership semantics with complete pagination. It adds query/schema and cursor-completeness validation without a necessary advantage for a single membership decision. It must not be used as a fallback during an outage without an independently tested adapter. |

**Caching:** Do not cache positive membership decisions. Rate limits, timeouts, permission errors, partial pagination, or provider outages deny the request. Team synchronization may lag; an operator-owned denylist/emergency stop must provide immediate denial while membership removal propagates.

**Audit and revocation:** Record the authenticated numeric user ID, fixed organization/Team IDs, `active` decision, check time, and provider correlation metadata in the external audit system. GitHub organization audit events can help review membership changes, but the service must separately record each authorization decision. Remove membership at the authoritative identity source and invalidate outstanding approvals; deny immediately on suspected compromise or uncertain sync.

### 2. Approval evidence

**Preferred approach:** A GitHub-authenticated approval service displays the complete action challenge and captures explicit human consent. It verifies current Team eligibility and all ADR-0010 approval constraints before issuing evidence. The service is outside the broker, AgentForge workstation, target repository, and agent session.

The evidence may be a standard signed assertion or an opaque reference verified by the service. Bind issuer, audience, approver numeric IDs, requester, operation, repository, resource, exact revision, policy version, request ID, issue/expiry time, and unique nonce. Limit validity to 10 minutes. A separate shared replay service must atomically consume the nonce across broker instances; a broker-local cache is only defense in depth.

| Option | Evaluation |
|---|---|
| GitHub-authenticated approval service | Preferred. Human GitHub identity and Team membership are native to the target ecosystem. The service adds the required operation-specific consent and complete action display that GitHub identity alone does not provide. |
| Signed approval tokens | Preferred as an evidence format only when issued by the trusted service and verified against an external trust root. A signature alone does not prove identity, eligibility, or approval intent. Do not invent cryptography or accept self-signed agent evidence. |
| OIDC-backed evidence | Useful for authenticating a human to the approval service, especially through the separately selected Entra fallback. GitHub Actions OIDC represents a workflow/job identity, not a human's approval, and must not substitute for the approval UI or run the maintainer operation as CI. |

**Audit and revocation:** Persist each approval/denial and evidence issuance event without storing evidence secrets or bearer tokens. Revocation of an approver invalidates outstanding evidence where possible; otherwise its short expiry, pre-action membership recheck, and external denylist must ensure it cannot authorize a later action.

### 3. Credential issuance

**Preferred approach:** An external issuer uses a GitHub App private key protected outside AgentForge to mint installation tokens. Request an explicit repository ID and explicit minimum permission subset; do not omit permission narrowing and accidentally inherit every permission granted to the App. Verify the issuance response's repository set, permissions, and `expires_at` before handing the token to the operation handler. GitHub installation tokens expire after one hour; the broker must revoke immediately after completion or failure.

| Option | Evaluation |
|---|---|
| GitHub App installation token | Preferred for broker automation. It can be narrowed to repositories and permissions granted to the App, is provider-expiring (one hour), and is attributed to the App rather than a human. Record approver identity separately. Permission scopes are still broader than a single API action, so handler allowlists remain mandatory. |
| Fine-grained PAT brokering | Rejected as the normal issuer. PATs are user-bound and created/approved through a user lifecycle; the broker cannot safely mint a per-operation PAT as a substitute for an external issuer. Expiration and revocation remain user/org policy concerns rather than a reliable one-operation lifecycle. |
| Short-lived issuance | Satisfied by externally minted installation tokens only when the issuer verifies request approval, repository, permission subset, and provider expiry. The issuer's App private key/JWT authority is a high-impact secret and must never enter the broker, image, workspace, logs, or chat. |

**Fallback:** None for production maintainer operations. If GitHub App permissions cannot satisfy a narrowly scoped operation, disable that operation instead of substituting a PAT.

### 4. Audit storage

| Option | Tamper evidence | Retention and recovery | Decision |
|---|---|---|---|
| Append-only file logs | `fsync`, restrictive ownership, and hash chaining can detect some damage, but a host/root operator can edit, replace, or delete the file. | Simple local recovery only; no independent failure domain or enforced 365-day retention. | Diagnostic or temporary spool only. |
| SQLite | Transactions provide atomic updates and crash recovery under documented filesystem assumptions; they do not prevent an administrator from modifying the database or replacing the file. | Convenient query and local recovery, but database and audit sink share the broker/host failure domain unless independently replicated. | Local index/spool only, never authoritative audit. |
| S3/Object Lock | Object Lock provides WORM protection on object versions when bucket versioning is enabled. Compliance mode prevents protected versions from being overwritten/deleted during retention, including by account root; it does not prevent a new version or delete marker. | Configure at least 365-day retention, unique event keys, version IDs, separate account administration, writer-only append access, no delete/bypass permission, and independent integrity/readback checks. | Preferred storage backend if an approved isolated AWS account and owner are available. |
| External audit service | Can provide independently operated append-only ingestion, immutable retention, access separation, and emergency write path, depending on service guarantees. | Requires explicit retention, export/recovery, outage behavior, and audit-review evidence. | Required service boundary; use an S3 Object Lock-backed writer or a service with equivalent guarantees. |

**Failure behavior:** If primary or emergency audit intent cannot be durably acknowledged and integrity-verified, do not issue credentials. If result logging fails after a possible remote operation, stop new work, revoke, record the unresolved state through the independent path, and require read-only reconciliation. No success-shaped fallback is allowed.

### 5. Emergency stop

| Option | Reliability and failure behavior | Decision |
|---|---|---|
| Local file control | A root-owned, no-follow file can be a host-local signal, but does not stop another host/container unless an independent supervisor polls it. Broker-controlled storage is mutable, polling introduces delay, and host failure/outage is not covered. | Not a standalone emergency stop. At most a local secondary break-glass signal consumed by an operator-owned supervisor. |
| GitHub-hosted control | A protected repository setting, issue, or workflow signal depends on GitHub API/network availability and may not terminate a local/in-flight broker. It also shares an identity and provider failure domain with the target operations. | Not selected as the sole stop. It may provide a secondary operator signal. |
| External control plane | An operator-owned service can hold durable shared stop state, deny admissions, terminate broker processes, call the independent revocation coordinator, and emit an emergency audit record. | Preferred. Select a concrete host/control-plane service with separate credentials and administration before integration. |

The stop must deny if state is unavailable or indeterminate. On trip, latch locally, persist the shared stop, terminate active brokers, attempt revocation even if audit/supervisor confirmation fails, write to the emergency audit path, and require a reviewed operator action to re-enable. No agent request can trip or clear the external stop.

### 6. Revocation

**Preferred approach:** Revoke each GitHub App installation token through GitHub's installation-token revocation API and verify the token is unusable with a safe read-only request where possible. Maintain a durable external issuance/revocation record keyed by request and credential reference so a broker crash cannot lose the revocation obligation. Never log the token itself.

**Expiry fallback:** The issuer must retain GitHub's provider-returned `expires_at`. If revocation cannot be confirmed, keep the request unresolved, stop new Level 3 work, and verify provider-enforced expiry/unusability; installation-token expiry is at most one hour. If GitHub is unavailable and expiry cannot yet be verified, keep the incident open. Local buffer destruction is not proof of revocation.

**Broker coordination:** Persist the credential reference before returning issuance success; register it with the external coordinator; revoke on success, failure, timeout, stop, broker death, or suspected exposure. Make revoke/status reconciliation idempotent and ensure the supervisor can act independently of broker memory. Any unknown token status denies re-enable.

## Safe non-production validation strategy

Validation uses only dedicated test identities, test App registrations/private keys, an eligible non-production organization/repository, and non-production storage/service credentials. No production credentials or production repositories are used. No merge, release, branch, issue, review, tag, or other repository mutation endpoint may be called.

1. **Contract and default-deny tests:** Keep the existing fakes for schema, scope, signature/client response, replay, sink failure, stop, and revocation tests. Verify every external adapter is unconfigured by default and fails closed.
2. **GitHub membership test:** Create a disposable Team with test members. Exercise active, pending, removed, wrong-Team, and invalid-identity cases using only read endpoints. Verify fixed org/team scope, permission denial for membership writes, fresh checks, rate-limit/timeout denial, and membership audit evidence.
3. **Approval-service test:** Use test GitHub accounts (and a separate test Entra tenant only if the fallback is being qualified). Test exact challenge display/binding, distinct approvers, requester/PR-author denial, expiry, nonce replay across two verifier instances, membership removal, signing-key rotation, and approval-service/audit outages. Do not route evidence to a production broker.
4. **Credential test:** Use a test GitHub App installed only on a disposable test repository, with the narrowest possible permission set. Mint a token, verify returned installation/repository/permissions/expiry metadata, make only safe read-only calls, revoke it, and verify it becomes unusable. Network policy must deny all repository mutation endpoints throughout the test.
5. **Audit test:** Use a dedicated test bucket/service. Verify versioning, retention configuration, separate write/read/admin identities, append/readback, integrity checks, and denial of object-version deletion/bypass. Object Lock compliance retention is difficult or impossible to shorten; obtain explicit approval before creating any long-retention test records.
6. **Emergency-stop/revocation test:** Run a disposable broker process with test-only credentials and no mutation handler. Trip the external stop while idle and while a simulated operation is active; verify no new admission, process termination, token revoke, external audit, crash recovery, and blocked re-enable after any failed acknowledgement.
7. **Integrated read-only gate:** Run the isolated broker with an empty operation allowlist and network egress restricted to the exact membership, verifier, issuer, audit, stop, and revocation endpoints. Verify no GitHub write route is reachable, no secret appears in logs/audit/chat, and provider outages deny work.

Provider test output must capture provider versions/configuration IDs, policy and adapter versions, test identities (non-sensitive IDs only), timestamps, scope/expiry/revocation receipts, audit integrity receipts, and failure-path results. Review evidence before any later operation-specific test. Mutation testing is a separate Phase 7c decision and is not part of this plan.

## Implementation prerequisites

- Name accountable owners for the GitHub organization/Team, approval service and signing/verification keys, external credential issuer, primary/emergency audit, emergency stop, and revocation coordinator.
- Confirm the GitHub product/organization supports the required App Members read permission and approval authentication flow; provision fixed Team IDs and an isolated non-production repository.
- Select the actual approval-service hosting, verifier trust roots, atomic replay store, key rotation/revocation procedure, and Entra fallback decision.
- Select an approved external audit service/account, immutable retention policy (at least 365 days), separate administration, and recovery/incident-review ownership.
- Select the control-plane/supervisor deployment and prove it can terminate brokers and revoke credentials independently of GitHub availability and broker health.
- Select an issuer capable of exact repository/permission narrowing, provider-enforced expiry, and remote revocation; keep all App private-key material outside AgentForge.
- Configure read-only network egress for provider validation, while keeping mutation routes blocked and all operations disabled.
- Pass the component and integrated validation requirements above; review all evidence and remaining provider-specific limits with maintainers.

## Recommendation

**B — Additional provider research and deployment decisions are required.** GitHub REST Team membership, GitHub App installation tokens, short-lived action-bound approval evidence, and an Object Lock-backed audit service are technically suitable. However, the required organization/App permissions, approval-service deployment, AWS or equivalent immutable audit account, external stop supervisor, and crash-surviving revocation coordinator have no selected owners or test configuration. The interfaces are ready for controlled, non-production integration once those prerequisites are supplied; no maintainer operation is ready or enabled.

## References

- [Phase 7 provider selection](phase7-identity-approval-provider-selection.md)
- [Phase 7 provider integration plan](phase7-provider-integration-plan.md)
- [Phase 7 implementation plan](phase7-implementation-plan.md)
- [ADR-0010: Maintainer Operations Strategy](adr/0010-maintainer-operations-strategy.md)
- [GitHub REST API: Team members](https://docs.github.com/en/rest/teams/members)
- [GitHub App installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [GitHub REST API: App installations and token revocation](https://docs.github.com/en/rest/apps/installations)
- [GitHub App authentication on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user)
- [GitHub Actions OpenID Connect](https://docs.github.com/en/actions/concepts/security/openid-connect)
- [Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [Amazon S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [SQLite atomic commit](https://sqlite.org/atomiccommit.html)
