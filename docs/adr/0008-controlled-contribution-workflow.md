# ADR-0008: Controlled Contribution Workflow

- Status: Proposed
- Date: 2026-11-20
- Deciders: AgentForge maintainers

## Context

Phase 6a provides validated read-only GitHub metadata access through AgentForge wrappers using repository allowlists, ephemeral configuration, and ephemeral authentication state.

AgentForge can now:

- Retrieve repository metadata.
- Inspect issues.
- Inspect pull requests.
- Inspect releases.
- Perform local development workflows.
- Execute validation and testing workflows.

However, AgentForge cannot currently contribute changes back to repositories.

Remote contribution introduces significantly greater risk than metadata retrieval:

- Repository modification.
- Branch creation.
- Pull-request creation.
- Workflow execution through repository events.
- Exposure of repository secrets.
- Branch-protection bypass.
- Unauthorized merges.
- Audit failures.
- Credential exposure.

Contribution capability must therefore remain separate from normal workstation operation and must preserve the security guarantees established by:

- ADR-0004
- ADR-0005
- ADR-0006
- ADR-0007

## Decision

Phase 6b introduces a controlled contribution workflow using an isolated one-shot contribution broker.

The broker is invoked only after successful local validation and explicit operator approval.

### Workflow

```text
Operator
    ↓ approval
AgentForge
    ↓ local validation
One-shot contribution broker
    ↓ push
Repository branch
    ↓ operator approval
Draft pull request
```

The contribution broker is:

- Disposable.
- Credential isolated.
- Repository constrained.
- Branch constrained.
- Audit logged.
- Revocable.

Broker instances must be destroyed after completion or failure.

## Security Model

### Contribution Boundary

Normal AgentForge workflows remain credential-free.

Contribution credentials exist only within the contribution broker.

The workstation:

- never receives repository write credentials
- never stores contribution credentials
- never persists contribution credentials

The contribution broker is the only component permitted to use repository write credentials.

### Credential Principle

Credential permissions are the primary authorization boundary.

AgentForge wrappers and broker controls provide workflow governance, auditing, and validation but are not relied upon for authorization.

Credentials must be restricted before use.

### Contribution Identity

The contribution identity must not possess permissions allowing:

- repository administration
- branch-protection modification
- pull-request approval
- pull-request merging
- bypass of required reviews
- bypass of required status checks
- workflow administration
- secrets administration

Contribution permissions must be limited to the minimum required for:

- branch push
- draft pull-request creation

## Validation Requirements

Before any contribution operation:

- local validation must succeed
- audit storage must be available
- repository must be allowlisted
- target branch must be allowlisted
- operator approval must be confirmed

Validation failures terminate the contribution workflow.

No remote operation may occur after validation failure.

## Repository Restrictions

Repositories must be explicitly allowlisted.

Example:

```yaml
github:
  contribution_repositories:
    - Phil-Friderici/AgentSmith
```

Repositories not present in the allowlist are denied.

Repository URLs, aliases, redirects, and inferred repositories are not permitted.

Only exact owner/repository matches are valid.

## Branch Restrictions

Branch targets must be explicitly defined.

Repository matching is exact.

Branch matching may support approved patterns.

Example:

```yaml
github:
  allowed_push_branches:
    - feature/*
    - bugfix/*
```

Protected branches should not be used directly.

The following examples are forbidden by default:

```text
main
master
release/*
production/*
```

For every permitted base branch, repository rules must require pull requests, independent review, and required checks. The contribution identity must not be a bypass actor. A repository is eligible only if a test using the contribution identity proves that it cannot merge a pull request even after all review and check requirements are satisfied. Token scopes, the broker's command allowlist, and branch protections that only require reviews/checks do not independently prove merge denial. If GitHub cannot enforce and demonstrate this restriction, the repository must not be enabled for Phase 6b.

## Workflow Exposure Review

Before a repository becomes eligible for Phase 6b, the repository must be reviewed for workflow-triggered risks.

The review must evaluate:

- `push` workflows
- `pull_request` workflows
- `pull_request_target` workflows
- reusable workflows
- workflow dispatch permissions
- repository secrets exposure
- token permissions and third-party actions used by each applicable workflow

Repositories that cannot safely execute contribution events must not be allowlisted.

The workflow exposure review must be documented and retained as part of repository onboarding records.

GitHub may automatically run workflows in response to branch pushes and pull-request events, even though the broker has no Actions permission and cannot manually invoke workflows. Workflows processing contribution branches or pull requests must not expose secrets or privileged tokens to contributed code. A `pull_request_target` workflow must not check out or execute contribution-branch code with privileged credentials. Phase 6b initially rejects changes to `.github/workflows/**`; any exception requires a separate maintainer security review before the change is pushed. If an event-triggered workflow cannot be made safe, the repository is ineligible.

Special attention must be paid to:

```text
pull_request_target
```

because it may execute with elevated privileges and access repository secrets.

## Contribution Broker

### Broker Characteristics

The contribution broker must:

- be disposable
- use isolated runtime storage
- use isolated credential storage
- use isolated Git configuration
- use isolated home directories

The broker must not inherit:

- workstation Git credentials
- workstation SSH identities
- workstation credential helpers
- workstation authentication state

### Git Isolation

The broker must execute with:

- isolated HOME
- isolated XDG configuration directories
- isolated Git configuration

The broker must never execute Git from the agent's working copy or use its `.git` directory. Transfer only the locally validated commit/tree through a data-only Git bundle, verify its commit/tree hash against the validation record, import it into a fresh broker-created repository, and configure the permitted remote from trusted policy. Repository-local Git configuration, remotes, hooks, filters, credential helpers, and executable overrides supplied by the agent must never be used.

The broker must explicitly disable:

- system and inherited global Git configuration
- credential helpers
- credential stores
- SSH command overrides
- repository-defined Git executable paths
- hooks and external transport helpers

The only credential helper permitted is a fixed broker-owned process helper. The broker must verify the effective Git configuration and exact remote URL before any push.
## Authentication Model

Contribution authentication is operator initiated.

Accepted credential candidates:

- Fine-grained GitHub Personal Access Tokens
- GitHub App installation tokens

Credentials must:

- be repository scoped
- be minimally privileged
- be time limited where possible

Rejected credential types:

- classic PATs
- repository-admin credentials
- organization-admin credentials
- workflow-administration credentials

## Credential Lifecycle

AgentForge treats contribution credentials as one-shot operational credentials.

Fine-grained PATs may technically outlive a single contribution operation and therefore require documented post-use revocation or rotation procedures.

GitHub App installation tokens more closely match the intended one-shot credential model.

After:

- successful push
- successful pull-request creation
- contribution failure
- broker failure
- audit failure
- timeout

the credential must be removed from broker storage.

Local cleanup alone is insufficient.

The selected credential model must support formal revocation, expiration, invalidation, or equivalent risk reduction after use.

For a fine-grained PAT, the operator must revoke it in GitHub immediately after success, failure, timeout, or suspected exposure and verify that revocation succeeded. The broker must not report the operation fully closed until the operator confirms revocation. Record only the confirmation and timestamp in the audit record, never the token or its value. For a credential that cannot be revoked individually, require a documented short maximum lifetime and verified expiry; a credential without a tested revocation or expiry path is not eligible.

Credential expiration, rotation, and revocation procedures must be documented and tested.

Authentication-state cleanup and credential revocation are considered separate security requirements.

## Audit Requirements

Every contribution attempt must generate audit records.

Required audit fields:

- timestamp
- repository
- branch
- operator identity
- executed action
- result status

Operator identity may be represented by a local workstation user identity, approval record, or equivalent non-secret audit identifier.

Audit records must never contain:

- access tokens
- credentials
- secrets
- authorization headers

If audit storage is unavailable:

```text
Contribution denied
```

Remote contribution must not proceed.

## Approved Operations

Phase 6b may support:

```text
push branch
create draft pull request
view pull request status
```

The following operations remain prohibited:

```text
merge pull request
approve pull request
modify issues
modify labels
modify milestones
execute workflows
manage workflows
manage secrets
manage repositories
manage branch protection
```

## Validation Strategy

### Phase 6b Validation

Required before acceptance:

- contribution broker isolation verified
- credential isolation verified
- agent-controlled Git configuration and helpers cannot affect broker Git operations
- repository allowlist enforcement verified
- branch allowlist enforcement verified
- audit generation verified
- audit-failure denial verified
- credential cleanup verified
- credential revocation process verified
- workflow-exposure review completed
- merge denial verified
- branch-protection enforcement verified
- draft pull-request creation succeeds
- remote credential revocation or expiry verified after both success and failure

### Failure Testing

Validation must demonstrate:

- push denial
- repository denial
- branch denial
- merge denial by the contribution identity after all review/check requirements are satisfied
- safe handling of push/PR-triggered workflows, including `pull_request_target`
- no use or execution of agent-controlled Git configuration, hooks, or credential helpers
- audit sink failure
- broker failure
- credential cleanup after failure
- credential revocation after failure

## Alternatives Considered

### Direct Workstation Push Access

Rejected.

Reason:

- Expands credential exposure.
- Violates least-privilege separation.
- Couples everyday development with remote modification.

### Persistent GitHub Write Authentication

Rejected.

Reason:

- Conflicts with ADR-0005.
- Expands credential lifetime.
- Increases compromise impact.

### Full Repository Contributor Permissions

Rejected.

Reason:

- Excessive privilege.
- Unnecessary for draft pull-request workflows.

### Wrapper-Only Enforcement

Rejected.

Reason:

- Wrappers do not provide authorization.
- Credentials remain the primary security boundary.

## Consequences

### Positive

- Controlled contribution workflow.
- Reduced credential exposure.
- Preserves workstation security boundaries.
- Auditable remote actions.
- Repository-scoped authorization.
- Explicit operator control.

### Negative

- Additional operational complexity.
- Additional credential lifecycle requirements.
- Repository onboarding reviews required.
- Audit infrastructure must be maintained.
- Contribution workflows require explicit governance.

## Open Questions

### Phase 6b

- Should GitHub App installation tokens replace fine-grained PATs?
- What maximum credential lifetime should be enforced?
- What audit retention period should be required?
- Which repositories are approved for contribution?
- Which branches are approved for contribution?

## Security and Operations

Contribution workflows must:

- preserve ADR-0004 boundaries
- preserve ADR-0005 boundaries
- preserve ADR-0006 boundaries
- preserve ADR-0007 boundaries
- require explicit operator intent
- remain auditable
- remain revocable
- deny unauthorized repositories
- deny unauthorized branches
- deny merge capability
- deny workflow administration
- deny repository administration
- deny credential persistence
- default to denial

## References

- ADR-0004: PDK Installation Strategy
- ADR-0005: Copilot Authentication and State Management
- ADR-0006: Acceptance Testing Platform
- ADR-0007: GitHub CLI Integration Strategy
- docs/github-cli-integration.md
