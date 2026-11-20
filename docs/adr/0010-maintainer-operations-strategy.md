# ADR-0010: Maintainer Operations Strategy

- Status: Accepted
- Date: 2026-11-23
- Deciders: AgentForge maintainers

## Context

Phase 5a, Phase 5b, and Phase 6a are validated. Phase 6b remains paused because no eligible repository has passed the repository and workflow-safety review in ADR-0008.

Phase 7 would introduce Level 3 actions that can change the authoritative state of a repository. Such actions have more impact than local development or Level 2 branch contribution and must not be enabled by extending the Level 2 contribution broker or by adding a general-purpose maintainer token to the workstation.

This ADR preserves the boundaries and requirements of:

- [ADR-0004: PDK Installation Strategy](0004-pdk-installation-strategy.md)
- [ADR-0005: Copilot Authentication and State Management](0005_copilot_authentication_and_state_management.md)
- [ADR-0006: Acceptance Testing Platform](0006-acceptance-testing-platform.md)
- [ADR-0007: GitHub CLI Integration Strategy](0007-github_cli_integration_strategy.txt)
- [ADR-0008: Controlled Contribution Workflow](0008-controlled-contribution-workflow.md)
- [ADR-0009: External VM Acceptance Testing Strategy](0009-external-vm-acceptance-testing-strategy.md)

In particular:

- Puppet repository credentials remain BuildKit-only under ADR-0004.
- Copilot authentication remains ephemeral and separate from session state under ADR-0005.
- Acceptance hosts and targets receive no maintainer credentials under ADR-0006 and ADR-0009.
- Phase 6a remains read-only; its read-only PAT is never elevated or reused for maintainer actions under ADR-0007.
- ADR-0008 remains Proposed; its Phase 6b broker cannot merge, approve, create releases, or administer repositories.

This ADR defines the accepted governance model. Its acceptance does not enable any Level 3 capability or resolve the Phase 6b repository eligibility blocker.

## Decision

Level 3 maintainer actions will use a separate, deny-by-default, one-operation execution boundary. No Level 3 credential or broker will be added to the persistent workstation, Level 2 contribution broker, acceptance controller, acceptance worker, or test target.

Every action must:

1. Match an explicitly supported operation and exact repository/resource allowlist.
2. Receive explicit human approval bound to the operation, repository, resource, and expected object revision.
3. Use a short-lived credential limited to the repository and minimum provider permission set required; enforce the exact operation through a separate trusted action boundary.
4. Write a durable audit intent record before credential issuance or remote mutation.
5. Execute once, verify the resulting remote state, record the result, and revoke or expire the credential.

The agent cannot approve its own request. It cannot convert a session-level grant into authority for later operations. No unrestricted shell, raw `gh api`, arbitrary GitHub CLI, or general-purpose administrative MCP tool is exposed at Level 3.

The proposed Level 3 path is:

```text
Maintainer request
    ↓
Exact operation and target displayed
    ↓
Required human approval(s)
    ↓
Durable audit intent
    ↓
Isolated one-shot maintainer broker
    ↓
Short-lived operation-scoped credential
    ↓
One remote operation and state verification
    ↓
Credential revocation/expiry and audit completion
```

Level 3 remains unavailable until Phase 7 controls pass the validation strategy and an eligible non-production repository is supplied for testing. Phase 6b remains paused and unchanged.

## Supported Operation Policy

The following is the initial operation allowlist. GitHub token permissions are coarser than individual operations and do not, by themselves, authorize exactly one row in this table. Every enabled operation also requires a dedicated broker handler with a static API/action allowlist. If the provider permission mapping and handler boundary cannot be demonstrated for an operation, that operation remains disabled.

| Operation | Policy | Approval |
| --- | --- | --- |
| Pull-request approval | A maintainer may submit a review only after inspecting the exact head commit. The reviewer must not be the PR author. GitHub review requirements remain independently enforced. | One explicit maintainer approval for the exact PR and head SHA. |
| Pull-request merge | A human may explicitly merge only after required checks and independent reviews pass. No merge queue automation, auto-merge, branch-protection bypass, or merge by the Level 2 broker. | Two distinct maintainers approve the exact PR and head SHA; GitHub branch protection is still required. |
| Release creation | Initially limited to a text-only draft from a pre-existing, verified tag and commit. Tag mutation, assets, and release publication are not supported. | Two distinct maintainers approve the exact tag, commit, and release metadata. |
| Branch creation | Only non-protected branches matching an approved naming policy may be created. It must not update or force-push an existing branch. | One explicit maintainer approval for the repository and branch name. |
| Branch deletion | Only a non-protected, non-default branch with no open PR or release dependency may be deleted. | Two distinct maintainers approve the exact branch and observed tip SHA. |
| Issue moderation | Initially limited to close/reopen, approved label changes, and lock/unlock with an explicit reason. Issue deletion, comment deletion, and arbitrary comment publication are not supported. | One explicit maintainer approval for the exact issue and action. |
| Repository maintenance | No general repository maintenance operation is enabled. Repository settings, access, rulesets, branch protection, secrets, webhooks, transfer, archive, and deletion are excluded. | Not supported by this ADR. |

Dual approval is required for operations with broad or difficult-to-reverse effects. Approvers must be distinct human identities; the second approver cannot be the request initiator. Approval does not replace GitHub review, status-check, or branch-protection requirements. If GitHub cannot enforce the required independent review or the broker cannot prove the expected object revision is unchanged, the operation is denied.

For a merge, neither operation approver may be the pull-request author. Immediately before merging, the broker must independently re-read the exact PR head, required checks, independent reviews, and applicable branch-protection/ruleset state. The Level 3 actor must not be a bypass actor. Deny the merge if any prerequisite is missing, changed, bypassable by the actor, or cannot be verified.

Every approval is:

- specific to one action and target
- single-use
- valid for no more than 10 minutes
- invalidated if the repository, resource, head SHA, tag, branch tip, or requested action changes

The broker must display the exact `owner/repository`, operation, resource identifier, relevant commit or tag, and consequential metadata before approval. It must not request approval with hidden or inferred targets.

### Release-specific boundary

The initial release operation creates only a draft release with text notes and no binary assets. Its tag must already exist, be protected against mutation by repository rules, and resolve to the approved commit when checked immediately before the action. Creating, moving, or deleting tags; uploading or publishing assets or artifacts; publishing, editing, or deleting a release; package publication; and release rollback or withdrawal are unsupported. Any future support requires an explicit operation policy, fresh approval rules, and validation before enablement. No automatic rollback or compensating mutation is permitted; remediation is a separate operation requiring fresh approval.

Before enabling any release operation for a repository, review workflows triggered by release events and tag pushes, including reusable and downstream workflows. Review their token permissions, third-party actions, and access to secrets. Validate the applicable event path in a disposable non-production repository. Deny release operations if the review or validation is incomplete or cannot establish that the workflow path is safe.

## Credential Model

Level 3 credentials must be distinct from Phase 6a read credentials, Phase 6b contribution credentials, Copilot authentication, Puppet package credentials, and all acceptance-provider credentials.

The preferred credential is a short-lived GitHub App installation token minted by an external identity/credential issuer for an exact repository and permission subset. Use a user-bound short-lived delegated credential when GitHub requires an individual maintainer identity, such as for a review action. The credential issuer and its long-lived signing material are outside AgentForge and are not implemented by this ADR.

Requirements:

- No PAT, App private key, refresh token, or other persistent maintainer credential is stored in AgentForge, a repository, image, cache, session history, or audit record.
- A credential is requested only after approval and is usable for one operation.
- The broker receives it in a private, ephemeral location or process scope and exposes it only to the reviewed operation.
- The token is limited to the exact repository and minimum GitHub permission set needed; repository or organization administration permissions are never requested. Provider permissions may cover multiple API actions, so they must not be described as operation-specific authorization.
- The broker records only non-secret issuer, credential type, permission set, expiry, and revocation confirmation metadata.
- Every credential must have a provider-enforced expiry no more than one hour after issuance, regardless of revocation support; prefer a shorter lifetime. Revoke it immediately after success, failure, timeout, or suspected exposure.
- The operation is not considered closed until revocation or expiry is verified. Local logout or deleting a file does not establish remote revocation.

If the issuer cannot produce a sufficiently short-lived, repository-scoped credential, or the required operation cannot be authorized without repository/organization administration, that operation remains disabled. Do not substitute a classic PAT, persistent fine-grained PAT, shared maintainer login, or broad credential.

The Level 3 broker must run as a fresh, disposable one-operation process or container with a read-only root filesystem and only private ephemeral writable storage. It must not inherit host Git credentials, SSH identities, credential helpers, GitHub CLI configuration, Copilot state, environment overrides, or mount the persistent workstation, workspace, home directory, `.git`, Docker socket, or virtualization devices. Supported operations use provider APIs and must not execute repository-controlled code, hooks, or configuration. If a future operation needs a checkout or repository code, this ADR must be revised before implementation.

The broker accepts only a typed operation request and approval evidence. A trusted, versioned policy outside the repository/workspace defines exact permitted repositories, operations, resources, branch/ref rules, and the provider permission/API-action mapping for each operation; prompts and repository files cannot expand it. Each operation uses a dedicated handler with a static method, endpoint, and parameter allowlist. No generic API client, arbitrary `gh` invocation, user-controlled method/path/flags, wildcard target, or arbitrary network destination is accepted. Egress is limited to the selected credential issuer, GitHub endpoints, and audit sinks.

The provider-enforced token scope limits the repository and broad capability set; the dedicated handler and trusted policy enforce the approved action within that set. For permissions that cover multiple actions, including consequential actions such as review and merge, tests must prove that a handler cannot dispatch an unapproved action even when the token permission would allow it. The credential is available only to that handler. If this separation cannot be demonstrated and maintained, disable the affected operation rather than treating token scope, a prompt, or an approval screen as sufficient isolation. A compromised credential may still exercise every action within its provider permission set until revocation or expiry, so the scope must remain minimal and the credential lifecycle and audit controls are mandatory.

## Audit Model

Audit records are written to a durable, append-only sink outside the repository and outside the disposable broker. The sink must be available before credentials are issued. Append-only behavior must be enforced independently of broker code: use provider-enforced immutable retention or equivalent tamper-evident signed/hash-chained records, with a broker identity that can append but cannot alter or delete records. Sink administration must use a separate identity, and integrity must be checked periodically.

An independent emergency audit path must be configured and tested before enabling Level 3. It must be outside AgentForge and independent of the primary sink and broker so a primary-sink outage after a mutation can still record the request/operation IDs, actor, target, timestamps, observed result, and credential status without secrets. If both audit paths fail, stop all Level 3 work, mark the remote outcome unresolved where applicable, and require an operator-owned incident record and review before re-enabling. Do not retry or compensate for a mutation during this failure.

Each operation record must include:

- unique request and operation identifiers
- UTC request, approval, start, completion, and revocation/expiry timestamps
- requester, approver, and GitHub actor identities
- exact repository, operation, and resource identifiers
- expected and observed PR head SHA, branch tip SHA, tag/commit, or other relevant state
- operation justification and approval evidence
- broker image/version and policy version
- credential type, issuer, repository/permission scope, expiry, and revocation status (never credential value)
- result, exit status, post-operation verification, cleanup status, and failure category

Audit records must not include tokens, secrets, authorization headers, private key material, full environment dumps, or unbounded command/API output. Store only the minimum excerpt or stable hash required to explain a result. Audit data is sensitive operational metadata and must have restricted access.

Retention is at least 365 days, with quarterly access and completeness review and immediate review after a failed, denied, or suspected-compromise event. A stricter repository or organizational retention requirement takes precedence. Audit retention must not require retaining the credential or full command output.

Audit failure is fail-closed:

- If the intent record cannot be durably written, do not issue a credential or perform the action.
- Record denied, expired, replayed, and emergency-stop requests as well as executed operations, without logging secrets.
- If result recording fails after a remote action, stop further Level 3 actions, revoke the credential, use a read-only path to determine remote state, and create an incident record through the independent emergency audit path.
- Never report success until the remote result and audit completion are verified.

## Failure, Revocation, and Emergency Stop

The following conditions deny or stop an operation: expired or replayed approval, target/state mismatch, failed precondition, unavailable audit sink, unexpected credential scope, timeout, uncertain remote result, or inability to verify revocation/expiry.

For an ambiguous remote failure, do not blindly retry a mutation. Re-read the exact resource through an independently constrained read-only path, record the observed state, and require a new approval before any further mutation.

The emergency stop must be operable outside the agent session. It must:

1. Deny new Level 3 requests and disable the Level 3 broker/profile.
2. Terminate active broker processes and discard ephemeral credential material.
3. Revoke active remote credentials through the external issuer or GitHub.
4. Preserve audit evidence and record the incident without copying secrets.
5. Require a maintainer review before re-enabling Level 3.

On suspected credential compromise, treat the credential as compromised even if local cleanup succeeded. Revoke it remotely, review provider-side audit events for its scope and lifetime, identify affected repositories/resources, rotate external issuer material if necessary, and keep Level 3 disabled until reviewed. AgentForge must not attempt automatic rollback or further mutations during incident handling.

## Validation Strategy

Validation uses a pre-provisioned, disposable, non-production repository with branch protections configured by its owner outside AgentForge. AgentForge must not administer or configure that repository.

Before any production use, demonstrate:

1. **Permission isolation:** Levels 0–2 cannot invoke Level 3 operations or obtain maintainer credentials. The Level 2 broker remains unable to merge, approve, release, or administer.
2. **Target and operation policy:** Exact repository/resource allowlists, unsupported commands, administration operations, protected/default branch changes, wildcard targets, and altered targets are denied. Branch/ref policy and the operation-to-provider-permission/API-action matrix come from trusted versioned broker configuration, not the workspace or repository. A handler is denied attempts to invoke any action outside its static allowlist, including other actions covered by the same token permission.
3. **Approval:** Single- and dual-approval rules, distinct identities, author self-approval denial, exact SHA binding, 10-minute expiry, single use, and replay denial. Merge tests include PR-author approver denial and changed/missing review, check, or protection prerequisites.
4. **Credential lifecycle:** Issuance occurs only after approval; scope and a maximum one-hour expiry are provider-verified; token access is confined to the broker; success, failure, timeout, broker termination, and emergency-stop paths revoke or verify expiry; no credential survives broker destruction.
5. **Audit:** Intent is durable before execution; the broker cannot alter/delete records; integrity checks and independent emergency audit-path recovery work; success, failure, denial, expiry, replay, and stop records are complete; secret scanning finds no credential values; audit failure prevents execution or safely stops post-action work.
6. **Action behavior:** Each supported operation is tested independently, including provider permission mapping, handler/API-action isolation, branch-protection enforcement, review/check prerequisites, release tag/commit binding, release/tag workflow review and event validation, and post-operation state verification. Tests attempt cross-operation calls using the same broad token permission and verify denial. Unsupported tag mutation, artifact publication, release publication, and rollback are denied. No automatic merge or unattended action occurs.
7. **Recovery:** Injected provider errors, broker termination, network interruption, uncertain outcomes, and failed revocation all stop safely, preserve audit evidence, and require explicit recovery approval.
8. **Boundary checks:** No credentials or maintainer access reach the workstation's persistent state, Phase 6b broker, Phase 5 validation host/worker, acceptance targets, repository, cache, image, logs, or chat output.

Testing must not use a production repository or production maintainer credential. Validation evidence and repository eligibility must be reviewed before enabling each operation class.

## Implementation Roadmap

1. **Complete:** ADR-0010 is Accepted. Keep every Level 3 operation disabled until its separate implementation and enablement gates pass.
2. Define the exact operation allowlist, protected-resource policy, provider-permission/API-action matrix, dedicated handler boundary, and eligible non-production repository. Identify permissions shared by multiple actions and prove that the handler blocks cross-operation calls; disable any operation whose separation cannot be demonstrated. Do not unblock or broaden Phase 6b by implication.
3. Select and validate an external short-lived credential issuer and tamper-evident audit sinks. Define approval identity verification, a hard maximum credential lifetime, revocation, independent emergency audit, retention, and audit review ownership.
4. Build a separate, disposable Level 3 broker with no general shell, workstation/workspace mounts, inherited state, or unbounded egress. Implement one operation at a time with action-bound approval, trusted repository/branch policy, credential scope, audit, and denial tests.
5. Validate success and failure paths in the non-production repository, including revocation, audit outage, replay, expiry, and emergency stop.
6. Enable only individually accepted operations and repositories. Require fresh evidence after policy, token, GitHub, broker, or repository-rule changes.

Repository administration, organization administration, and any operation without an independently verifiable permission and recovery boundary remain disabled.

## Alternatives Considered

### Extend the Phase 6b contribution broker

Rejected.

ADR-0008's broker is intentionally limited to Level 2 contribution actions and must not approve or merge pull requests, create releases, or administer repositories. Expanding it would weaken that authorization boundary and invalidate its merge-denial requirements.

### Use a persistent maintainer PAT in the workstation

Rejected.

It conflicts with ADR-0005 and ADR-0007, gives a long-lived credential to routine development, and cannot provide reliable per-operation revocation and target binding.

### Run unrestricted `gh` or an administrative MCP server

Rejected.

This would expose a broad mutation surface, make target/operation restrictions difficult to prove, and treat wrappers or prompt instructions as authorization.

### Automate merge or release after checks pass

Rejected and out of scope.

Automation would remove the required per-operation human decision and could act on changed or unintended state.

### Give the broker repository or organization administration

Rejected and out of scope.

The supported maintenance operations do not justify settings, access-management, secret-management, or organization-wide capabilities.

## Consequences

### Positive

- Level 3 remains distinct from read-only access and Level 2 contribution.
- Every operation is explicitly approved, scoped, short-lived, and auditable.
- Credential compromise and audit failure have defined fail-closed responses.
- GitHub branch protection remains an independent control.
- No maintainer credential is persisted in AgentForge.

### Negative

- An external credential issuer and durable audit sink are prerequisites.
- Two-person approval adds coordination for merges, releases, and branch deletion.
- GitHub operations requiring an individual identity may not support the preferred App-token flow and can remain unavailable.
- Per-operation policy and validation increase implementation and maintenance effort.
- Phase 7 cannot proceed until an eligible non-production repository and complete revocation/audit paths are available.

## Explicitly Out of Scope

- Automatic merge or automatic release publication.
- Unattended maintainer operations.
- Persistent maintainer credentials in AgentForge.
- Repository administration or settings changes.
- Organization administration.
- Permission, team, secret, webhook, branch-protection, or ruleset management.
- Tag creation, movement, or deletion; release asset/artifact publication; release publication, editing, or deletion; package publication; and automatic rollback or withdrawal.
- Enabling Phase 6b or changing its paused status.

## Validation Status

ADR-0010 completed security and consistency review.

Review outcome:

```text
Recommendation A
```

The architecture is considered ready for implementation planning.

Level 3 capabilities remain:

- unimplemented
- disabled
- unavailable by default

Before any capability may be enabled, implementation validation must demonstrate:

- operation-level authorization enforcement
- credential isolation
- broker isolation
- audit integrity
- emergency-stop behavior
- credential revocation
- failure-path handling

Phase 6b remains paused and is not a prerequisite for ADR-0010 implementation planning.

## References

- [ADR-0004: PDK Installation Strategy](0004-pdk-installation-strategy.md)
- [ADR-0005: Copilot Authentication and State Management](0005_copilot_authentication_and_state_management.md)
- [ADR-0006: Acceptance Testing Platform](0006-acceptance-testing-platform.md)
- [ADR-0007: GitHub CLI Integration Strategy](0007-github_cli_integration_strategy.txt)
- [ADR-0008: Controlled Contribution Workflow](0008-controlled-contribution-workflow.md)
- [ADR-0009: External VM Acceptance Testing Strategy](0009-external-vm-acceptance-testing-strategy.md)
- [Security Model](../security-model.md)
- [Roadmap](../roadmap.md)
