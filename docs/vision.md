# Project Vision

## Purpose

AgentForge provides a persistent, reproducible development workstation for AI agents working with GitHub Copilot CLI and Puppet modules. It combines an agent-facing interface with a reusable development environment so work can continue across separate sessions without repeatedly cloning repositories, rebuilding caches, or losing useful local state.

AgentForge is a workstation for supervised development. It is not a CI runner, a general-purpose remote execution service, or an autonomous maintainer.

## Intended users

- A human developer supervising one or more AI-agent sessions.
- An AI agent that needs a stable repository, branch, and tool environment over multiple sessions.
- A maintainer who selectively authorizes operations beyond local development.

The human operator owns the environment, supplies any required credentials through mechanisms outside the repository, and decides when to grant permissions above read-only access.

## User outcomes

An authorized agent should be able to:

1. Reopen a workspace and continue with the same repositories, branches, and local working state.
2. Inspect code and project metadata without modifying them at Level 0.
3. At Level 1, edit files, run development commands and tests, and create local commits.
4. At Level 2, push branches and create pull requests after explicit authorization.
5. Run Puppet module validation and unit tests, followed by opt-in Litmus acceptance tests on isolated disposable targets; retain Beaker compatibility where a module requires it.
6. Use supported MCP and GitHub CLI capabilities without receiving broader host access than the task requires.

## Principles

### Persistence without privileged access

Persist repositories and intentional state in explicit host-managed workspace paths or named volumes. Do not use a privileged container, host namespace, or Docker socket as a shortcut to persistence.

### Least privilege by default

Start at Level 0. Grant write, network, remote GitHub, and maintainer capabilities only at the permission level required for a task. Permission elevation must be visible, intentional, and reversible.

### Reproducible, inspectable environment

Pin and document runtime and toolchain versions as implementation begins. Keep image construction separate from runtime secret availability; when a build needs a credential, use a scoped BuildKit secret and keep it out of runtime services.

### No secrets in the repository or image

Credentials are operator-managed external inputs. Use only a mechanism scoped to the operation: Puppet package credentials are supplied as a BuildKit secret for the package-download build step, never mounted into a runtime container, and never written to an image layer. Prevent them from being printed to terminals, logs, chat, or build output.

### Human responsibility for consequential actions

Local test execution and local commits are distinct from publishing changes. Pushing, opening pull requests, and maintainer operations must remain gated by the permission model and operator intent.

## Non-goals

- Replacing GitHub-hosted CI or providing a CI scheduling system.
- Running untrusted agent workloads as host-equivalent processes.
- Storing or provisioning an operator's GitHub or Puppet credentials.
- Automatically merging pull requests, changing repository settings, or performing maintainer actions.
- Guaranteeing acceptance-test availability: providers, credentials, network access, and target systems are operator-configured.

## Success criteria

The first usable release should retain repository state and approved Copilot session/settings state across container recreation, while requiring Copilot authentication to be re-established after recreation. It should start with no remote write capability by default, support repeatable PDK validation and unit tests, and document an explicit path for optional acceptance tests. It may require the operator-managed Puppet package credential during the PDK image build, but must use BuildKit secret mounts so that credential does not enter image layers, runtime configuration, logs, or chat. It must not rely on a mounted Docker socket.

## Scope status

The repository includes the Phase 2 workstation foundation, Phase 3 Copilot CLI 1.0.112 integration with Node.js 22.23.5, a PDK 4.0.1 BuildKit-secret image path, and the Phase 6a GitHub CLI foundation, read-only wrapper, and ephemeral PAT lifecycle. GitHub CLI 2.105.0, `agentforge-gh`, and `agentforge-gh-auth` are installed only in Level 1; authenticated repository views, denials, ephemeral storage, non-disclosure, and recreation cleanup were validated for the two allowlisted targets. Both repositories disable issues and contain no PRs or releases. The operator states the PAT is read-only and repository-scoped; those settings were not independently inspected. See the [Phase 6a authenticated validation report](phase6a-authenticated-validation-report.md). The protected PDK BuildKit flow was previously validated with authorized credentials; it has not been rerun in the current environment because no external credential source is available. ADR-0005 is implemented as an ephemeral Copilot home with selective persistence for settings and session state. The Copilot CLI has not been successfully logged in during implementation; successful login/recreation behavior remains an operational verification. Puppet Agent remains uninstalled. Phase 5a is operationally validated; Phase 5b compatibility and integration validation is complete, while production hardening remains future work. Neither acceptance path is enabled in the normal workstation profiles. MCP capabilities remain unimplemented.
