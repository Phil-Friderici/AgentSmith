# MCP Tool Design

## Purpose

MCP is an optional, explicit interface between the agent and approved tools or services. It must not become a general-purpose bridge to the host, shell, credentials, or unrestricted GitHub administration.

This document describes design constraints and a capability model. It does not configure or implement an MCP server.

## Design principles

- **Allowlist:** Enable only the MCP servers and tools needed for a task. Do not load arbitrary community servers by default.
- **Least privilege:** Give each server a dedicated, minimally scoped credential where possible. Do not reuse a maintainer token for routine development.
- **Task-scoped capabilities:** Separate read operations from write operations. Disable write-capable tools at Level 0 and expose remote write tools only at Level 2 or explicitly approved Level 3.
- **Narrow inputs:** Prefer operations with constrained repository, branch, path, and resource identifiers over arbitrary shell or unrestricted API calls.
- **Human approval:** Require operator confirmation for pushes, pull request creation when not covered by an explicit task grant, merging, releases, permission changes, or destructive operations.
- **Output hygiene:** Treat tool output as untrusted input. Avoid returning credential data or unbounded sensitive repository content to chat.
- **Visibility:** Document enabled tools, their permissions, credentials, and network destinations. Keep useful audit metadata without logging secret values.

## Proposed capability groups

These are logical groups, not a commitment to a specific MCP server or product.

| Group | Examples | Intended minimum level |
| --- | --- | --- |
| Local inspection | Read files in the approved workspace; inspect repository status and metadata. | Level 0 |
| Local development | Edit workspace files; run approved validation and test commands. | Level 1 |
| GitHub read | Read repository metadata, issues, pull requests, and permitted code context. | Level 0, if configured |
| GitHub collaboration | Push an authorized branch; create or update a pull request. | Level 2 |
| Maintainer | Merge, release, change repository settings, or administer access. | Level 3, per operation |

For local development, prefer bounded tools or the workstation's normal CLI over a broad remote execution MCP server. An MCP tool that runs arbitrary commands is effectively shell access and must be treated as such in the permission model.

## GitHub CLI and Git

MCP is not the only route to GitHub. `gh`, Git remotes, credential helpers, and direct network access can provide equivalent capabilities. Permission enforcement must therefore account for the complete set of routes available inside the container.

At Level 0, GitHub access should be read-only and local repository paths should be mounted read-only. At Level 1, local edits and commits may be available without any remote write credential. At Level 2, use a short-lived or narrowly scoped credential and allow pushes only to authorized destinations. At Level 3, use a separately controlled elevation path; do not leave broad administrator credentials in a persistent environment.

## Tool review checklist

Before enabling an MCP server or tool, document:

1. Its owner, source, version, and update process.
2. The exact tools and remote endpoints it exposes.
3. Filesystem, network, and credential access it requires.
4. Whether it can mutate state, execute arbitrary commands, or expose unbounded data.
5. Its permission-level availability and approval behavior.
6. What it logs, how outputs are bounded, and how failures are surfaced.
7. How to disable and revoke it.

Do not enable a tool whose behavior, credential use, or permission scope cannot be understood.

## Initial configuration direction

Start with MCP disabled: the initial workstation baseline must not start or configure an MCP server. Add integrations incrementally after verifying server provenance and behavior, beginning with a separately approved read-only capability if one is needed. Keep per-level configuration explicit. A server should not gain write permissions merely because it is available in a session, and agent-visible instructions must never contain secret values.

**Phase 2 status:** MCP remains disabled in all Compose profiles. The repository has no MCP server process, client configuration, tool allowlist, or MCP credential mount. This is intentional; selecting and reviewing a concrete server remains part of Phase 6, after the first usable Copilot workstation, Puppet development workflow, and acceptance-testing boundary.

## Future interface boundaries

The following are extension contracts, not implementations or approvals to enable servers:

| Interface | Intended responsibility | Boundary |
| --- | --- | --- |
| Filesystem | Operate on explicitly approved repository paths. | Level 0 read-only; Level 1 writes only within the selected workspace; never expose host home, secrets, or caches as arbitrary paths. |
| Git | Inspect local status/history and, at Level 1, create local commits. | Push and pull-request actions remain Level 2 with explicit repository/branch confirmation. |
| Shell | Run narrowly approved local development commands. | Arbitrary command execution is equivalent to shell access; it is not a safe generic MCP tool and must not bypass Compose restrictions. |
| Docker | No workstation-side daemon operations in the current design. | Do not mount the Docker socket or provide a Docker MCP server without a new accepted ADR and security review. |
| GitHub | Read approved metadata when a reviewed server is selected; collaboration actions only at elevated levels. | No GitHub auth or server is configured in Phase 2. |
| Test | Invoke validation/unit tests in the workspace; optionally request acceptance testing later. | Acceptance tests are proposed for Phase 5 and require an approved provider, disposable targets, and explicit authorization; see [Puppet Acceptance Testing Design](acceptance-testing.md). |

An implementation proposal must specify provenance/version, exact enabled tools, paths/endpoints, credentials, permission level, approval behavior, output limits, logs, revocation, and failure handling before any server configuration is added.

## Open questions

The first MCP server and whether local filesystem tools are supplied by MCP or native tools remain future decisions. Select them only when a concrete workflow requires them, and define how human confirmation is enforced for remote actions.
