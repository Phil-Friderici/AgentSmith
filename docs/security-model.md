# Security Model

## Security objectives

AgentForge must preserve the operator's control over files, credentials, remote Git operations, host resources, and maintainer actions. The default environment is read-only and unprivileged. A higher permission level must be an explicit change to available capabilities, not merely a prompt instruction.

The agent, its tools, repositories, package downloads, MCP servers, and test targets are treated as potentially fallible or untrusted. A prompt or tool result must not override host-enforced controls.

## Permission levels

| Level | Name | Intended capabilities | Prohibited unless separately elevated |
| --- | --- | --- | --- |
| **0** | Read only | Read approved repository files and documentation; inspect local Git state; run only explicitly allowed non-mutating inspection. | Editing files, creating commits, pushing, creating pull requests, maintainer actions. |
| **1** | Development | Level 0 plus modify workspace files, run tests and development tools, and create local commits. | Pushes, pull requests, changes to remote settings, merging, releases, and other maintainer actions. |
| **2** | Remote collaboration | Level 1 plus push authorized branches and create pull requests, with an explicit target repository/branch policy. | Merge, release, administrative changes, or other Level 3 actions unless separately authorized. |
| **3** | Maintainer operations | Specifically approved maintainer capabilities such as merging, release actions, or repository administration. | Any operation not explicitly included in the operator's grant. |

Levels describe maximum intended capability sets, not automatic trust. A task may receive a narrower set than its level. Level 3 is not a general unrestricted mode; each maintainer operation should be named and approved.

## Enforcement requirements

The implementation must enforce permissions using multiple controls:

- **Filesystem:** Mount only approved paths; use read-only mounts at Level 0; keep host home directories, SSH agent sockets, and unrelated repositories out of the container.
- **Identity:** Run as a non-root user. Do not grant Linux capabilities or host namespace access unless an ADR justifies a narrowly scoped requirement.
- **Credentials:** Provide only the credential for the intended operation, only at the required level, with the narrowest available scope and lifetime. Puppet package credentials are build-only BuildKit secrets and must never be mounted into development containers.
- **Network:** Restrict outbound access where practical, especially for Level 0. Remote GitHub and acceptance-test access must be deliberate. Network isolation complements but does not replace credential and tool restrictions.
- **Tools:** Expose an allowlist of MCP tools and commands. Remove or disable write-capable integrations at lower levels where feasible.
- **Review and approval:** Require explicit operator intent before Level 2 and Level 3 actions. Display the action and target without disclosing credential values.
- **Auditability:** Record useful operational metadata (action, target, time, result) without recording tokens, passwords, secret contents, or sensitive command output.

No single control is sufficient. Prompt instructions are not an authorization boundary; Compose profiles alone are not a security boundary; read-only mounts do not prevent network exfiltration; and disabling one MCP tool does not remove equivalent CLI access.

## Default and elevation policy

1. Start at Level 0 with no remote write credential, no broad host mount, and no Docker socket.
2. Elevate only for a specific task and only to the minimum level required.
3. For Level 1, give write access only to the designated workspace. Local commits must not silently trigger pushes.
4. For Level 2, provide a credential scoped to the intended repository and operation. Confirm the remote and branch before pushing or opening a pull request.
5. For Level 3, require explicit operator approval per operation and prefer a separate, short-lived execution context. Do not leave administrator credentials in the persistent workstation.
6. Revoke elevated credentials and mounts after use; preserve only intended repository and cache state.

## Initial workstation defaults

- The initial workstation has no GitHub CLI/Git remote authentication and no MCP servers enabled.
- Copilot CLI authentication is separate from GitHub CLI authentication. Under ADR-0005, the operator initiates it manually in Level 1; authentication state remains ephemeral and is not preserved across container recreation.
- Copilot session history and approved user settings may persist only under a dedicated state path, separate from authentication state, workspace, cache, and repositories. Do not persist `config.json`, token-bearing files, logs, or unreviewed Copilot configuration.
- The default persistent workspace is `~/AgentForge/workspace`; bind-mounted files use the host user's UID/GID. Startup must not recursively change ownership.
- Persistent caches are limited to selected, per-user/per-project Ruby/Bundler and PDK caches. They are not shared across permission levels.
- Puppet repository credentials are supplied only to the BuildKit package-download step from an external host-managed source. They are not runtime mounts, environment variables, build arguments, or files in the final image.
- Exact tool versions are pinned and updated deliberately.
- The implemented Level 0 profile has no network, sets `COPILOT_OFFLINE=true`, and receives no persistent Copilot state. Level 1 supports explicitly initiated ephemeral Copilot authentication, but no GitHub CLI or remote-write credential. Level 1 is not a sandbox for untrusted project code.

These are architecture decisions. Phase 2 verifies the Level 0/1 filesystem, identity, network, and socket defaults; later-level and remote-write controls remain unimplemented and unverified.

## Threats and mitigations

| Threat | Baseline mitigation |
| --- | --- |
| Agent modifies host files outside its task | Narrow mounts; read-only by default; no home-directory or root filesystem mounts. |
| Prompt injection requests credential disclosure or privilege escalation | Treat repository content and tool output as untrusted; enforce permissions outside the model; never place secrets in prompts or chat. |
| Secret appears in image, build output, logs, or chat | BuildKit secret mount limited to the package-download command; never use build args or environment variables; install the downloaded package in a separate stage; inspect build output and final image with an authorized build. |
| Compromised dependency or test fixture accesses host | Non-root container, minimal mounts/capabilities, pinned dependencies, and isolated acceptance-test targets. |
| Accidental remote write | No write credential at Levels 0–1; explicit Level 2 grant and target confirmation. |
| MCP integration performs unintended actions | Small allowlist, narrow schemas, least-privileged credentials, explicit approvals for consequential operations. |
| Persistent cache leaks private data or is poisoned | Treat caches as sensitive and untrusted; scope, inspect, and clear selectively; never use cache as secret storage. |
| Copilot authentication survives container recreation or enters a persistent state mount | Put the entire `COPILOT_HOME` on tmpfs; individually mount only `settings.json`, `session-state/`, and `session-store.db`; reject known auth files, auth-like settings, and GitHub token patterns. |
| Session history exposes prompts or tool output | Store session files with owner-only permissions, apply retention and cleanup, and do not persist process logs or authentication state with them. |
| Acceptance test damages a real system | Use disposable, isolated targets; require explicit target authorization; do not run against production by default. |

## Proposed acceptance-test boundary

Acceptance testing is not implemented. Proposed ADR-0006 recommends an explicitly invoked Litmus workflow with rootless Podman targets in a separate, disposable provider boundary. The normal workstation receives no Docker or Podman socket, `/dev/kvm`, cloud credentials, or Puppet repository credentials. Test targets must be disposable and allowlisted; only a minimal module snapshot may cross into the provider. Any provider API socket or run-scoped cloud credential is a high-impact capability and must remain confined to the separate acceptance environment. This proposal does not change current Level 0/Level 1 profiles and remains subject to a Litmus/Podman compatibility spike. See [Puppet Acceptance Testing Design](acceptance-testing.md).

## Copilot authentication and session state

ADR-0005 is authoritative. Copilot authentication is operator-initiated in Level 1 and exists only for the lifetime of the ephemeral `/copilot` tmpfs home. Copilot CLI 1.0.112 documents that `config.json` can include signed-in account state and that token information may fall back to plaintext there if no credential store is available; therefore that file is never mounted or persisted. Authentication is not injected through Compose configuration and is not stored in an image, repository, workspace, cache, or persistent state mount. Container recreation intentionally requires authentication again. Level 0 is offline, has `COPILOT_OFFLINE=true`, and has no persistent Copilot mounts.

Only `settings.json`, `session-state/`, and `session-store.db` persist, from the dedicated `~/AgentForge/state/copilot` path. Settings mount read-only; session data is writable. Process logs, unreviewed configuration, credential caches, MCP configuration, personal instructions, plugins, and all other Copilot-home files remain ephemeral. The host initializer and container diagnostic reject unexpected persistent files, known authentication artifact names, auth-like settings, and recognizable GitHub token patterns in persistent state/workspace/cache paths. The ephemeral Copilot runtime cache is separately checked for authentication-like filenames and recognizable GitHub token patterns. JSON schema files are not treated as credentials merely because they describe auth-related fields. These checks do not claim to recognize every possible future opaque token format; the primary control is that the CLI's entire home is ephemeral and only the three named state paths are mounted. Session history is sensitive project data and requires owner-only permissions, retention, and cleanup. Never paste credentials into Copilot prompts or commands whose output may be captured in session history.

## Operational requirements

- The operator must be able to inspect active mounts, environment variables, enabled MCP tools, credentials availability (without revealing values), and permission level.
- Logs and chat output must not contain secret values. If a tool can echo a secret-bearing file, do not expose that file to the agent.
- Security incidents or unexpected permission behavior should stop the relevant workflow; do not silently continue with a weaker fallback.
- Permission changes must be documented and tested. The Phase 2 diagnostic checks workspace/cache access and rejects an exposed default Docker socket; remote write credentials and MCP servers are absent from the current profiles. Level 2/3 and remote-write denial tests remain future work.

## Validation status

The Level 0/Level 1 Compose services implement the documented mount, identity, capability, network, and Puppet runtime-credential defaults and include mount readiness checks. The host initializers validate external paths without changing existing ownership; `agentforge-doctor` checks for the Puppet credential and known Copilot auth artifacts in protected paths without displaying content. The host workspace, approved settings, and selected sessions survive container replacement. The authentication home and logs do not. Successful Copilot login and reauthentication-after-recreation have not been operationally verified; this remains a future check, not an implementation prerequisite. These controls do not make Level 1 a sandbox for untrusted code, and Compose profiles are not authorization boundaries. The BuildKit PDK package flow remains unverified against the private repository and real credentials. MCP remains disabled; no MCP server or configuration is present. Revalidate these guarantees when the host Docker/Compose version or deployment configuration changes.
