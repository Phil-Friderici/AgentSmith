# Phase 7 Identity and Approval Provider Selection

## Status and scope

This document selects identity and human-approval providers for Phase 7 under [ADR-0010](adr/0010-maintainer-operations-strategy.md). It does not enable an operation, approve production use, or alter the ADR's approval counts, credential limits, audit requirements, or failure behavior.

The selection separates four responsibilities:

1. **Human identity:** establish which GitHub account is acting.
2. **Eligibility:** establish whether that account is currently authorized to approve Level 3 requests.
3. **Approval:** capture explicit consent to one immutable operation request.
4. **Execution identity:** authorize the broker's GitHub API calls.

These are not interchangeable. In particular, a GitHub App installation token identifies the App, not the human approvers.

## Decision

### Preferred provider

Use a **GitHub App-backed external approval service**, with:

- GitHub user authentication on behalf of each human approver.
- A dedicated, fixed GitHub organization Team as the maintainer eligibility group, identified by immutable organization and team IDs in trusted service configuration.
- A read-only App identity for membership checks and a separate, narrowly scoped App installation identity for broker execution. Neither App identity is a human approver.
- An approval service outside the broker that displays the complete action challenge, verifies the acting user and current Team membership, captures explicit approval, and supplies independently verifiable, short-lived, single-use evidence to the broker.

The service must bind each approval to the exact operation, repository, resource, expected revision, request ID, policy version, requester, and approval expiry. It must enforce the ADR-0010 distinct-human, requester, PR-author, dual-approval, and 10-minute rules. The broker must verify the evidence through a fixed verifier interface and must not accept approval claims from an agent request.

For GitHub App installation credentials, restrict each token to the exact repository and required permission subset. Use a user-bound App token only where an operation requires the action to be attributed to an individual GitHub user. In either case, keep issuance outside the workstation and broker, and honor ADR-0010's lifetime and revocation requirements.

### Fallback provider

Use **Microsoft Entra ID OIDC authentication with an Entra application role or narrowly scoped group assignment**, mapped to the approver's immutable GitHub user ID. GitHub Team membership remains a required GitHub-side eligibility check; Entra identity alone does not grant GitHub maintainer authority.

The fallback requires the same external approval service, action binding, distinct approvers, evidence verification, audit, and revocation behavior as the preferred provider. It is a separately configured and validated provider, not an automatic failover. If the selected identity source, membership lookup, mapping, or approval service is unavailable, the request is denied.

### Not selected as standalone providers

- **CODEOWNERS:** retain as repository review routing and branch-protection input only; it is not the Level 3 identity or action-approval authority.
- **Signed approval artifacts:** use only as evidence issued by the selected external approval service. A signature format does not independently establish who approved or whether that person was eligible.
- **Local operator approval:** do not use as a production fallback. It lacks the independent identity, action-bound evidence, and external audit needed for Level 3. An emergency stop remains an operator control, not an approval substitute.

## Evaluation

| Candidate | Security | Auditability | Revocation | Operational complexity | Suitability |
|---|---|---|---|---|---|
| GitHub App approvals | Installation tokens are scoped and short-lived, but actions are attributed to the App. A GitHub App alone cannot prove human approval. A user-authenticated approval service can bind the verified human to the exact request. | GitHub records App and user activity separately; the external service must write action-bound approvals to ADR-compliant audit sinks. | App installation tokens expire after one hour and can be revoked; remove approvers from the eligibility Team and recheck membership before execution. | Moderate: App registration, OAuth, membership-read permissions, approval UI/service, verifier, issuer and audit integration. | **Preferred as a provider stack**, not as a bare App token or unattended App workflow. |
| GitHub Team membership | Provides a GitHub-side eligibility group. Membership is not consent to any particular operation, so it must be combined with a fresh human approval. | Team membership changes and approval activity are represented in GitHub; the external audit pipeline must preserve decision evidence and policy context. | Remove the person from the Team and deny if membership cannot be freshly verified. Team synchronization from an IdP is available in supported GitHub Enterprise configurations, but synchronization can lag. | Low to moderate when the organization already manages Teams; requires fixed team IDs and read-only membership access. | **Preferred eligibility source**, not a standalone approval provider. |
| GitHub CODEOWNERS | Useful for code-specific review routing, but the file is branch/repository content and can change. It does not express a general maintainer allowlist or per-operation consent. | PR review history is auditable, but CODEOWNERS content alone is not proof of authorization. | Change the file or team membership, subject to normal repository/IdP controls; it is not suitable for immediate broker revocation. | Low for repository reviews, high if misused as a global authorization system. | Supplementary only. Preserve required review rules; do not make it the Level 3 identity root. |
| Entra ID group membership | Strong organizational identity and lifecycle when the organization operates Entra. Claims and group mappings must be validated; group claims can be omitted when token limits are exceeded. Prefer app roles or an authoritative membership lookup over trusting an unchecked group claim. | Entra sign-in and group events provide a separate identity audit trail; approval decisions still need operation-bound records and GitHub identity mapping. | Disable the account or remove its app-role/group assignment; recheck current eligibility at approval and before execution. Token/group-claim staleness must not silently authorize work. | Moderate to high: tenant/application setup, group or role assignment, conditional access, Graph permissions if live membership is queried, and GitHub identity mapping. | Fallback, or an upstream source for GitHub Team synchronization where already deployed. |
| Signed approval artifacts | Can provide tamper-evident, replay-resistant evidence only if a trusted issuer authenticates the approver, checks eligibility, and signs the exact request. A signature by itself is not identity proof. | Strong when issuer, claims, verification, key use, and resulting decision are independently audited. | Revoke/disable the issuer or signing key; individual membership and evidence expiry must also be checked. Previously issued artifacts remain a concern until expiry or revocation is verified. | High if a signing service, key lifecycle, verifier, and recovery path are custom-built. | Evidence mechanism only; use a vetted format and external issuer. Do not invent cryptography or a self-authenticating local token. |
| Local operator approval | A terminal prompt or local key may be controlled by the same workstation/session and is not an independent authorization boundary. | Local logs can be changed or lost and do not meet ADR-0010's external durable audit requirements. | Manual revocation and host access control are weak substitutes for provider-side identity lifecycle. | Low initially, high ongoing risk and audit burden. | Not suitable for Level 3; never use as automatic fallback. |

GitHub documents that installation-token API requests are attributed to the App, while user-authenticated App requests are attributed to a user. Installation tokens expire after one hour and can be restricted by repository and permission. GitHub Teams represent organization members and can be synchronized from an identity provider in supported Enterprise configurations. CODEOWNERS requests code-owner reviews and can be made a branch-protection requirement, but is tied to repository branches and file paths. Microsoft Entra group claims have token-size limits, so group membership must not depend on an unchecked token claim.

## Integration strategy

1. **Provision identity configuration externally.** Create the dedicated maintainer Team, decide its ownership and membership-change process, and record immutable organization/team IDs in service-owned configuration. No repository file, prompt, or agent-provided username can change eligibility.
2. **Separate user approval from App execution.** Approvers authenticate as individual GitHub users through the approval service. Use a read-only GitHub App installation for membership checks and a separate, operation-scoped App identity for execution. Never interpret an App-authored review or comment as human approval.
3. **Verify identity and eligibility.** Bind the authenticated GitHub account to its immutable numeric user ID. Check that ID against the configured Team at approval time and again immediately before credential issuance or action. Fail closed on API errors, stale identity mapping, team-sync uncertainty, or unavailable membership data; do not use a cached positive result.
4. **Display and capture the exact action.** The approval UI must display the canonical repository, operation, resource, expected revision, requester, consequential metadata, and expiry. The requester cannot supply or alter the challenge after approval begins. Require the exact distinct approver count in ADR-0010.
5. **Issue and verify evidence externally.** The approval service issues evidence using a vetted, independently verifiable mechanism and keys outside AgentForge and the broker. Bind the evidence to all request fields, issuer, audience, approver IDs, policy version, issue/expiry times, and a single-use nonce. Consume the nonce atomically in the external verifier so replay prevention spans broker instances; the broker's in-process replay guard is only defense in depth. Use no custom cryptography. The evidence is authorization evidence, never a GitHub credential.
6. **Revalidate before acting.** Immediately before the action, re-read target state and approver eligibility. Reject changed revisions, expired/replayed evidence, or unavailable identity, audit, issuer, or verifier services. GitHub branch protection and required reviews remain independent controls.
7. **Revoke and audit.** Record the approval and identity decision through the independent audit pipeline without tokens or private claims. Revoke the operation credential or verify provider-enforced expiry. Remove a user from the Team and invalidate outstanding approvals on revocation or suspected compromise. If Team synchronization can delay removal, an operator-owned denylist/emergency stop must deny that identity immediately, and Level 3 must remain disabled until membership removal is confirmed.
8. **Qualify the Entra fallback separately.** Use Entra OIDC for human identity and app roles or a live, least-privilege membership check for eligibility. Map users to GitHub numeric IDs through an operator-reviewed, auditable binding. Do not trust display name, mutable email, or an unbounded token group claim as the mapping. The same approval and audit gates apply.

Native pull-request reviews may contribute GitHub review evidence for the merge preconditions in ADR-0010. They do not replace the per-operation approval challenge, approval identity checks, independent audit, or approval of release metadata.

## Readiness and recommendation

The provider choice is made, but no approval identity provider, human approval UI/service, Team membership adapter, external evidence verifier, issuer, or production audit sink is configured. The current Phase 7a/7b framework remains fail-closed and cannot authorize an operation. The Entra fallback is also unconfigured and must not be treated as ready merely because the tenant uses Entra.

**Recommendation B — Additional provider work required.** Implement and validate the preferred GitHub-backed identity/approval service and its integration contracts before starting Phase 7c mutation work. Phase 7c remains blocked until Phase 7b exit criteria, an eligible non-production repository, the external issuer, audit sinks, and emergency-stop/revocation integrations are independently validated. Do not enable merge or release operations as part of provider selection.

## References

- [ADR-0010: Maintainer Operations Strategy](adr/0010-maintainer-operations-strategy.md)
- [Phase 7 implementation plan](phase7-implementation-plan.md)
- [GitHub App installation access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
- [GitHub App authentication modes](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app)
- [About organization teams](https://docs.github.com/en/organizations/organizing-members-into-teams/about-teams)
- [Synchronizing a GitHub Team with an identity provider](https://docs.github.com/en/enterprise-cloud@latest/organizations/organizing-members-into-teams/synchronizing-a-team-with-an-identity-provider-group)
- [About CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [Configure group claims for applications with Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims)
