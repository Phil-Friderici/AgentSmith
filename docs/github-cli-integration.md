# GitHub CLI Integration Design

## Overview

Phase 6 introduces controlled GitHub repository access for AgentForge.

The implementation follows ADR-0007 and is intentionally split into two stages:

- Phase 6a: Read-only GitHub metadata access.
- Phase 6b: Controlled contribution workflows.

Phase 6a is implemented and operationally validated. Phase 6b is specified by [Proposed ADR-0008](adr/0008-controlled-contribution-workflow.md), but is not accepted or implemented; no remote write capability is enabled.

## Security Model

GitHub credential permissions are the primary security boundary.

AgentForge wrappers provide:

- workflow control
- repository allowlist enforcement
- environment sanitization
- auditability

Wrappers are not considered authorization boundaries.

All authenticated Phase 6a access must use credentials that are inherently restricted to read-only repository metadata access.

## Image and Profile Layout

### Level 0

Characteristics:

- No GitHub CLI.
- No network access.
- No GitHub authentication.
- No GitHub configuration.

### Level 1

Characteristics:

- GitHub CLI installed.
- GitHub CLI version pinned.
- Ephemeral configuration.
- Read-only metadata wrapper installed.
- `agentforge-gh-auth` accepts and manages an operator-provided fine-grained PAT in ephemeral storage.
- The metadata wrapper passes the stored PAT only to the GitHub CLI process.
- No PAT permissions or repository scope are verified by AgentForge; the operator must ensure the PAT is read-only and repository-scoped.

## GitHub CLI Configuration

Phase 6a uses:

```text
GH_CONFIG_DIR=/tmp/agentforge-gh/config
```

Requirements:

- Directory created automatically.
- Mode 0700.
- Located on tmpfs.
- Removed when the container is recreated.

No GitHub configuration is persisted.

The PAT, when stored, is kept separately at `/tmp/agentforge-gh/pat` on the same `/tmp` tmpfs. The file is created atomically with mode 0600 and is removed when the container is recreated. It is never stored in `GH_CONFIG_DIR`, a bind mount, cache, image, or command argument.

## Repository Allowlist

Location:

```text
/etc/agentforge/github-allowlist.yml
```

Example:

```yaml
github:
  allowed_repositories:
    - Phil-Friderici/puppetlabs-mysql
    - Phil-Friderici/puppetlabs-concat
```

Requirements:

- Exact owner/repository matches only.
- No wildcards.
- No URL-based matching.
- No implicit repository selection.

Repositories not listed are denied.

The current checked-in allowlist contains only the two public validation repositories shown above. To change it, edit the version-controlled file and rebuild the Level 1 image. The container copy is root-owned and read-only.

## Wrapper Interface

Phase 6a exposes only these forms through `agentforge-gh`:

```text
agentforge-gh repo view OWNER/REPO
agentforge-gh issue list OWNER/REPO
agentforge-gh issue view OWNER/REPO NUMBER
agentforge-gh pr list OWNER/REPO
agentforge-gh pr view OWNER/REPO NUMBER
agentforge-gh release view OWNER/REPO [TAG]
```

The wrapper translates these inputs to GitHub CLI's supported argument forms. It accepts no extra flags or arguments. Repository matching is exact and case-sensitive; URLs, wildcards, invalid issue/PR numbers, and option-like release tags are denied. A denied request never invokes `gh`.

Unsupported commands are rejected.

## PAT lifecycle

The Level 1 operator may use the following commands in an interactive terminal:

```text
agentforge-gh-auth store
agentforge-gh-auth status
agentforge-gh-auth clear
```

`store` prompts with terminal echo disabled; the PAT is not accepted as an argument or environment variable. The command accepts only the fine-grained PAT prefix format and stores it in `/tmp/agentforge-gh/pat` with owner-only permissions. `status` reports only whether the local file passes format and permission checks; it does not contact GitHub or verify the token. `clear` removes the stored file. Container recreation clears both the PAT and GitHub CLI configuration.

The auth helper does not verify that a PAT is fine-grained, read-only, or scoped to the allowlisted repositories. Verify those permissions and scope in GitHub before storing it. Do not use a classic PAT. The token is exposed to the `gh` child process as `GH_TOKEN` only for an allowlisted metadata request; do not run direct `gh` commands or place credentials in shell history, chat, logs, Compose configuration, workspace, or cache.

## Denied GitHub Operations

Phase 6a does not permit:

```text
gh api
gh pr create
gh pr merge
gh issue create
gh issue close
gh repo fork
gh workflow run
gh secret set
```

Write operations are outside the scope of Phase 6a.

## Authentication Model

AgentForge supports operator-supplied PAT storage for authenticated metadata requests. This does not enable private-repository access unless the repository is allowlisted and the PAT is explicitly scoped to it. OAuth and `gh auth login` are not used.

### Public Repositories

Preferred model:

```text
No authentication
```

### Private Repositories

Permitted model:

```text
Fine-grained PAT
```

Requirements:

- Read-only.
- Repository scoped.
- Ephemeral local storage.
- Never persisted.

Classic PATs are prohibited.

## Environment Sanitization

AgentForge wrappers must reject or sanitize:

```text
GH_TOKEN
GITHUB_TOKEN
GH_ENTERPRISE_TOKEN
GITHUB_ENTERPRISE_TOKEN
GH_HOST
GH_REPO
```

Repository selection must originate from the wrapper and allowlist only.

The wrapper starts with a clean environment, rejects inherited token/host/repository overrides, and forces `GH_CONFIG_DIR=/tmp/agentforge-gh/config`. For an allowlisted request, it reads the PAT from the validated ephemeral file and supplies it to `gh` as `GH_TOKEN`. It disables interactive prompts and pagers. The allowlist governs AgentForge-managed calls; it is not an authorization boundary against direct CLI use.

## Diagnostics

Level 0 checks:

- GitHub CLI absent.
- GitHub auth helper absent.
- No GitHub configuration.
- No PAT storage.

Level 1 checks:

- Expected GitHub CLI version.
- GH_CONFIG_DIR location.
- tmpfs placement.
- 0700 permissions.
- Allowlist presence.
- PAT file presence and mode 0600, without reading its contents.

Credential values must never be displayed.

## Validation Requirements

Phase 6a acceptance requires:

- GitHub CLI installation verified.
- Exact wrapper command mapping and allowlist enforcement verified using a mocked CLI invocation.
- Environment sanitization.
- Ephemeral configuration verification.
- Authenticated metadata command validation using an operator-provided PAT with verified read-only repository scope.
- Denied-command verification.

The PAT lifecycle was validated with an operator-provided token. AgentForge verifies only the PAT prefix and storage protections; it does not verify GitHub permissions or repository scope.

### Public-repository validation status

The 2026-11-20 public-repository validation found that GitHub CLI 2.105.0 requires authenticated state for the requested metadata commands, including public repository views. No authentication or token was used; see the [validation report](phase6a-public-validation-report.md). The wrapper and allowlist checks passed, but live metadata retrieval remains unverified.

Authenticated repository views succeeded for both allowlisted repositories. Issue listing was unavailable because both repositories disable issues; PR listing succeeded with no results, and no releases were found. See the [authenticated validation report](phase6a-authenticated-validation-report.md). The operator specified that the PAT is read-only and repository-scoped, but those settings were not independently inspected.
