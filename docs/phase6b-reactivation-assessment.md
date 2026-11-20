# Phase 6b Reactivation Assessment

- Date: 2026-11-23
- Status: Assessment; does not accept ADR-0008 or authorize remote writes

## Context and decision boundary

The [primary operating model decision](../decisions/primary-operating-model-decision.md) makes fork-based contribution ending at draft pull-request creation AgentSmith's primary objective. Phase 7 is a future capability; merge, release, and maintainer operations are not prerequisites for this workflow.

[ADR-0008](adr/0008-controlled-contribution-workflow.md) is still Proposed and Phase 6b remains paused. This assessment identifies the minimum ADR-0008 control set for a fork workflow. It does not relax its no-merge requirement, approve a repository, or enable any operation.

## Minimum ADR-0008 controls that remain mandatory

The scope can omit maintainer features, but not the contribution boundary and safety controls:

1. **Credential separation and least privilege.** Levels 0 and 1 remain unable to write remotely. Do not elevate or reuse the Phase 6a read-only credential. A disposable Phase 6b broker alone handles a short-lived or otherwise revocable, narrowly scoped Level 2 credential. Keep it out of the workstation, checkout, image, cache, session state, and logs; revoke it or verify expiry after success and failure.
2. **Fork and upstream allowlisting.** Bind the permitted head fork, upstream repository, and base branch as an explicit tuple. Reject redirects, aliases, inferred remotes, and any unapproved repository or branch. Permit pushes only to a newly validated contribution branch in the operator-owned fork; prohibit force-push and branch deletion.
3. **Isolated, validated transfer.** Run credential-free validation first. Bind its evidence to the exact commit/tree, then transfer only that validated content to a fresh broker repository as a data-only bundle. Do not use the workstation `.git`, Git configuration, hooks, helpers, remotes, or executable overrides.
4. **Explicit operator intent.** Require a clear, target-specific confirmation before each remote action: one for pushing the named branch to the named fork, and a separate one for creating the draft PR from that branch to the named upstream/base branch. Do not turn either approval into a session-wide grant.
5. **No merge authority.** The broker has no merge or approval handler. More importantly, the actual identity and credential used for each remote step must be tested against the exact upstream and permitted base branch to prove it cannot merge, bypass protection, or approve—even when checks and reviews would otherwise allow a merge. Broker command denial alone is insufficient.
6. **Workflow exposure review.** Review the upstream's `push`, `pull_request`, `pull_request_target`, reusable, and downstream workflow paths before allowing a fork contribution. Deny by default changes to `.github/workflows/**`. Do not execute contributed code with privileged credentials or expose secrets to it.
7. **Fail-closed audit and validation.** Record each attempt and outcome without credentials or secret-bearing output. Audit unavailability, failed validation, uncertain target identity, or a broker failure must prevent or halt the remote action. Verify cleanup and credential revocation/expiry on success and failure.
8. **Repository-specific eligibility.** An exact non-production fork/upstream pair must pass the workflow review, branch-protection review, push/PR tests, and merge-denial tests before any production repository is allowlisted.

These are Level 2 controls already inherent in ADR-0008, narrowed to fork contribution. A fork workflow does not make repository-event risks or the distinction between branch push and PR creation disappear.

## Level 3 controls not required

The following are not prerequisites for branch push and draft-PR creation and must not be imported into Phase 6b:

- Two distinct maintainer approvals or Level 3's 10-minute, signed approval-evidence model. Phase 6b still requires explicit operator approval for each action.
- GitHub Team membership as an authorization source, an external maintainer approval service, or a Level 3 credential issuer.
- The dedicated Level 3 broker, maintainer credential lifecycle, or its operation-specific approval and audit-intent pipeline.
- Merge, PR approval, release or tag creation, branch deletion, issue moderation, repository maintenance, or organization administration.
- Level 3's emergency-stop control plane or external revocation coordinator. Phase 6b still needs a practical stop/cleanup path and tested credential revocation or expiry.
- An external immutable Level 3 audit service solely to satisfy Phase 7. Phase 6b must meet ADR-0008's audit availability, completeness, and failure-denial requirements; its selected journal must be durable enough for its documented operational use.

Not requiring these Level 3 components does not waive ADR-0008 audit, approval, isolation, revocation, or denial requirements.

## Minimal architecture

```text
Level 1 workstation
  ├─ local changes and validation; no remote-write credential
  └─ tree-bound validation evidence + data-only Git bundle
          ↓
Disposable Level 2 contribution broker
  ├─ independently checks policy, evidence, and exact fork/upstream/base tuple
  ├─ operator confirms fork branch push
  ├─ pushes only the validated branch to the user-owned fork
  ├─ operator separately confirms draft PR creation
  └─ creates one draft PR to the allowlisted upstream/base branch
          ↓
Upstream workflow and repository controls
  └─ no broker merge, approval, release, or administration path
```

The broker must remain separate from the workstation and any Level 3 broker. Prefer distinct credentials for fork push and PR creation if provider behavior permits. If one credential is proposed for both actions, test its exact permissions and effective authorization. Do not assume that a broker allowlist or a UI/API command filter removes provider-granted merge authority.

## Implementation scope if reactivated

**In scope:** one-shot fork branch push; draft PR creation from that fork branch to one explicitly mapped upstream/base branch; per-action operator confirmation; minimal durable audit; ephemeral/revocable credential handling; repository onboarding and safe failure behavior.

**Out of scope:** upstream branch writes, merge or approval, releases/tags, issue or label changes, workflow dispatch/management, repository or organization settings, unattended actions, arbitrary GitHub CLI/API, force-push, and branch deletion.

## Validation plan

Validate first against a disposable non-production fork and upstream with no production credentials:

| Area | Required proof |
|---|---|
| Destination policy | Reject an unapproved fork, upstream, base branch, redirect, remote URL, and branch name; prove push reaches only the approved fork. |
| Evidence and approval | Reject stale or mismatched tree/commit evidence; prove push and draft PR each require explicit confirmation bound to their exact action and target. |
| Git/broker isolation | Prove workstation credentials/configuration, hooks, helpers, remotes, and `.git` are not used; verify the broker is destroyed after completion and failure. |
| Credential isolation/lifecycle | Prove the credential is absent from the workstation and persistent storage; verify least privilege and revocation or expiry after success, timeout, and failure. |
| No-merge boundary | Using the actual push and PR identities, attempt merge and approval against the upstream PR after checks/reviews are satisfied; verify denial and that no bypass is possible. If the provider cannot demonstrate this, do not enable the workflow. |
| Workflow exposure | Review and safely exercise relevant fork push and upstream PR event paths, especially `pull_request_target`; verify contributed code cannot access privileged tokens or secrets. |
| Audit/fail-closed behavior | Verify complete secret-free records for success and denial; make audit unavailable and inject validation, broker, and network failures to prove remote operations are denied or halted. |
| End-to-end behavior | Create a non-protected branch on the fork and a draft PR to the intended upstream/base; verify resulting refs and PR metadata, with no merge or other mutation. |

Any inability to prove the no-merge boundary, workflow safety, or credential revocation/expiry is a release blocker, not a reason to rely on broker allowlisting alone.

## Recommendation

**B — Keep Phase 6b paused for now.** A simplified fork workflow is within the intended Level 2 purpose and does not require Phase 7. However, the current record says no repository has passed ADR-0008 eligibility, and no fork/upstream identity-and-permission configuration has demonstrated both draft PR creation and merge denial. Reactivate implementation only after a disposable fork/upstream pair passes the validation above and the applicable repository is approved. No ADR-0008 revision is needed merely to exclude Level 3 features; revise ADR-0008 if the chosen provider cannot meet its existing no-merge or credential-boundary requirements.
