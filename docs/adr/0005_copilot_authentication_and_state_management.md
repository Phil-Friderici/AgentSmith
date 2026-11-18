# ADR-0005: Copilot Authentication and State Management

## Status

Accepted

## Context

AgentForge aims to provide a persistent AI-assisted development workstation for GitHub Copilot CLI while maintaining strong separation between:

- authentication data
- project workspaces
- cached development artifacts
- persistent session history

A review of GitHub Copilot CLI 1.0.112 identified the following concerns:

- Copilot CLI stores authentication tokens in a system credential store when available.
- When no supported credential store is available, Copilot CLI can fall back to storing token information within the Copilot home directory.
- The Linux credential-store implementation is not sufficiently documented for AgentForge's security requirements.
- The fallback behavior cannot currently be proven to fail closed.
- Persistent authentication data inside the development container conflicts with AgentForge's least-privilege security model.

The review also showed that Copilot session data and authentication data are separate concerns and should be managed independently.

AgentForge's primary goal is secure development workflows, not permanently authenticated containers.

## Decision

AgentForge will use ephemeral Copilot authentication.

Persistent authentication state is explicitly out of scope for the initial workstation implementation.

Users must authenticate GitHub Copilot CLI manually when required.

Authentication data must not be persisted across container recreation.

Container images, repositories, workspaces, caches, and persistent state directories must not contain Copilot authentication credentials.

AgentForge will support persistence of approved non-secret Copilot state, including:

- reviewed user settings
- session history
- session metadata
- planning artifacts

Authentication state and session state must remain separated.

## Requirements

### Authentication

Authentication must:

- be initiated explicitly by the operator
- remain outside the repository
- remain outside the project workspace
- remain outside persistent cache volumes
- be removable through standard logout procedures

Authentication must not:

- be embedded in container images
- be stored in Git repositories
- be committed to source control
- be injected through Docker Compose configuration
- be stored in AgentForge configuration files

### Persistent State

The following categories may be persisted after review:

- session-state data
- session metadata
- approved user settings
- planning artifacts
- execution history required for workspace continuity

The following categories must not be persisted:

- authentication tokens
- credential caches
- token-bearing configuration files
- GitHub access credentials
- OAuth refresh tokens
- unreviewed Copilot configuration data

### Workspace Separation

Copilot state must never be stored under:

```text
/workspace
```

or any Git-managed repository path.

Copilot state must be stored in dedicated AgentForge state locations separated from:

- repositories
- caches
- secrets
- container images

## Alternatives Considered

### Option A: Persistent Copilot Login Using Native CLI Authentication

Rejected.

Reasons:

- Credential-store implementation is insufficiently documented.
- Plaintext fallback behavior cannot currently be proven safe.
- Authentication data could become persistent inside the container.
- Increases security review complexity.

### Option B: Host-Managed Vault Integration (KeePassXC)

Deferred.

Reasons:

- Additional infrastructure complexity.
- Requires launcher tooling.
- Requires lifecycle management of vault access.
- Introduces additional failure modes and operational dependencies.

This option may be reconsidered in a future ADR.

### Option C: Ephemeral Authentication with Persistent Session State

Accepted.

Reasons:

- Simplest architecture.
- Aligns with least-privilege principles.
- Minimizes credential persistence risk.
- Compatible with rootless Docker.
- No dependency on host keyrings or D-Bus integration.
- Easier auditing and incident response.

## Consequences

### Positive

- No long-lived Copilot credentials inside AgentForge.
- Reduced attack surface.
- Simpler security model.
- Reduced dependence on host-specific credential systems.
- Easier container rebuild and recovery workflows.
- Clear separation between project data and authentication data.

### Negative

- Re-authentication may be required after container recreation.
- Operators may need to perform periodic logins.
- Slightly less convenient than persistent authentication.

## Security Considerations

Session history is considered sensitive project data.

Persisted session artifacts may contain:

- prompts
- plans
- tool output
- repository metadata
- diagnostic information

Session data must therefore:

- use owner-only file permissions
- be excluded from Git repositories
- follow documented retention policies
- be removable without affecting project workspaces

Authentication credentials and session history must never share the same storage location.

## Future Considerations

A future ADR may revisit persistent authentication if:

- GitHub Copilot CLI provides a documented fail-closed credential-store implementation for Linux, or
- AgentForge adopts a dedicated credential-management architecture that satisfies all security requirements.

Any future proposal must demonstrate:

- absence of plaintext token fallback
- secure container recreation behavior
- auditable credential lifecycle management
- compatibility with AgentForge's least-privilege model

## Follow-up Actions

- Implement session-state persistence separately from authentication.
- Define retention and cleanup policies for session history.
- Validate logout procedures during workstation testing.
- Verify that authentication artifacts do not survive container recreation.
- Verify that no authentication data enters repositories, workspace mounts, or cache volumes.
- Reassess persistent authentication only through a future ADR.