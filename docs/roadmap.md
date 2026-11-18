# Implementation Roadmap

## Status

The architecture baseline and Phase 2 workstation foundation are complete. Phase 3 Copilot CLI integration and selective persistent state are implemented. Phase 4 Puppet module workflows are implemented. The protected PDK package build and successful Copilot login/recreation behavior remain unverified operational tasks.

## Phase 0 — Architecture baseline

**Goal:** Establish shared project intent, boundaries, and security requirements.

**Deliverables:** Vision, architecture, permission model, MCP and secret strategy, directory contracts, ADR framework, and an implementation sequence.

**Exit criteria:** Open decisions are identified; maintainers agree that default access is read-only, state is external to replaceable containers, and credentials are scoped to a single operation. Puppet package credentials are BuildKit-only under ADR-0004 and never available at runtime.

## Phase 1 — Resolve implementation decisions

**Goal:** Make the minimum decisions needed for a secure reproducible workstation.

**Decisions already made (ADR-0002):**

- Workspace root: `~/AgentForge/workspace`, separate from this source checkout.
- Bind-mount identity: match host UID/GID; never recursively change ownership at startup.
- Puppet credentials: external and used only as a BuildKit secret during PDK package download; never passed via `ARG`/`ENV`, written into image layers, or mounted at runtime. PDK image rebuilds require the external credential.
- GitHub CLI/Git: no authentication in the initial workstation baseline; remote write access is a later, separately approved feature. Copilot authentication and session-state rules follow ADR-0005: authentication is ephemeral, while approved non-secret settings and sessions may persist separately.
- MCP: disabled in the initial baseline; add only reviewed integrations for a concrete need.
- Versions: exact pins with deliberate, compatibility-tested updates.
- Caches: selected per-user/per-project Ruby/Bundler and PDK caches; no credentials and no writable sharing across permission levels.
- Acceptance tests: no provider is enabled. Proposed ADR-0006 recommends Litmus with isolated rootless Podman targets, subject to a compatibility spike; the normal workstation receives no Docker daemon access.

**Status:** Policy choices are recorded in ADR-0002 through ADR-0005. Exact pins are recorded for Ubuntu/Git/Ruby, Bundler 2.4.20, and PDK 4.0.1 (`4.0.1.1-1noble`). PDK package metadata has no declared Puppet Agent dependency; an exact Agent version remains target-module-dependent. The BuildKit secret override is implemented, but the private package fetch, APT auth format, and leak checks remain unverified because no external credential source is available in this environment. ADR-0005 rejects persistent Copilot authentication and approves separately persistent session/settings state. Acceptance testing has a proposed design in ADR-0006; no provider has been selected or implemented.

**Remaining work before Puppet toolchain integration:**

- Select and document compatible exact versions for GitHub CLI and any acceptance framework/provider after the Phase 5 compatibility spike. Phase 3 targets the studied Copilot CLI 1.0.112 release and pins its Node.js runtime.
- Select a Puppet Agent version only when a concrete module workflow establishes its runtime requirement.
- Build and validate the PDK 4.0.1 image against the private package source with operator-controlled credentials; no protected package fetch has been run yet.
- Test that Levels 0 and 1 cannot push or create pull requests using any available route.

**Exit criteria:** Exact remaining tool versions and the secret/permission mechanisms are validated before adding those tools. Acceptance provider implementation is not an exit criterion for the initial workstation.

## Phase 2 — Minimal workstation and Compose

**Goal:** Create a reproducible, least-privilege development environment.

**Work:**

- Add a container image definition and a minimal Compose configuration.
- Create a non-root workstation user and narrow, explicit workspace and cache mounts.
- Add health/readiness and operator-facing startup guidance without publishing unnecessary ports.
- Use a BuildKit secret for the protected PDK package download; ensure credentials never enter image layers, runtime configuration, logs, or generated artifacts.
- Add explicit Level 0 and Level 1 profiles/configuration; do not enable remote write by default.

**Status:** Phase 2 foundation is implemented: digest-pinned Ubuntu 24.04, pinned Git/Ruby/Bundler/PDK versions, Level 0/Level 1 Compose profiles, explicit host UID/GID, read-only root filesystem for normal profiles, no Docker socket, and per-profile mount health checks. Level 0 has a read-only workspace and no network. Level 1 has a writable workspace and selected cache, with network access but no runtime credentials. Host bind mounts preserve workspace state across container recreation. Host-path initialization, startup diagnostics, and setup/operations/troubleshooting guides are included. The PDK build-only secret overlay is implemented, but the private-package build has not been run because no external credential source is available. MCP remains disabled.

**Exit criteria:** Met for the Phase 2 base. The PDK image's BuildKit-secret package flow is configured but its protected fetch remains unverified. The environment is replaceable without losing host-mounted workspace state, runs unprivileged in normal profiles, and has no runtime Puppet credentials, Docker socket, or broad host mounts.

### Phase 2 architecture compliance

The implementation follows ADR-0001 through ADR-0004: one replaceable unprivileged workstation image, external bind-mounted workspace/cache, Level 0/1 capability separation, no runtime Puppet credentials or Docker socket, and a BuildKit-only PDK package secret. ADR-0005 additionally governs future Copilot authentication and session/settings state. The host initializer, diagnostic, documentation, `.gitignore`, and build-context allowlist are implementation details that reinforce those decisions.

GitHub CLI, Puppet Agent, Litmus, Beaker, Level 2/3 operations, Docker daemon access, and MCP servers remain unimplemented. Copilot authentication persistence is rejected by ADR-0005, not deferred. Copilot CLI and its approved session/settings persistence are implemented in Phase 3. Acceptance testing is proposed for Phase 5; Proposed ADR-0006 does not enable a provider or change the current no-socket boundary.

## Phase 3 — First usable Copilot workstation

**Goal:** Provide an interactive Copilot CLI workstation with ephemeral authentication and persistent, approved non-secret state.

**Work:**

- Add Copilot CLI 1.0.112 to the Ubuntu 24.04 image and pin its Node.js runtime and package source. Disable automatic CLI/plugin updates so the image pin remains authoritative.
- Integrate Copilot in Level 1 only. Level 0 receives no authentication, persistent Copilot state, or network access.
- Require the operator to initiate login manually. Keep the entire authentication home, including any CLI-created `config.json`, on ephemeral storage; do not inject tokens through Compose or persist credentials. Container recreation must require a new login.
- Provide a dedicated host state path, separate from the source repository, workspace, and cache. Persist only approved `settings.json`, `session-state/`, and `session-store.db`; keep auth configuration, process logs, unreviewed configuration, plugins, and caches ephemeral unless a later ADR explicitly approves them.
- Create and validate the state path with owner-only permissions. Make approved settings read-only to the container by default; provide a reviewed host-side update path.
- Review session retention weekly and prune inactive sessions older than 30 days; process logs are not persisted.
- Extend startup diagnostics to verify the state mount, ownership/permissions, and separation from workspace/cache without reading or printing authentication data.
- Document login/logout, reauthentication after container recreation, session restore, state backup, retention, and recovery.

**Status:** Implemented. The image pins Copilot CLI 1.0.112 and Node.js 22.23.5, verifies npm dependencies from a lockfile, and sets `COPILOT_AUTO_UPDATE=false`. Level 1 uses a tmpfs `/copilot` home and individually bind-mounts only read-only `settings.json`, `session-state/`, and `session-store.db`; Level 0 is offline with no persistent Copilot mounts. Host initialization and runtime diagnostics enforce the path allowlist and scan state/workspace/cache for known authentication artifacts without displaying contents. Session retention is documented as weekly review with a 30-day maximum for inactive sessions. No successful login was performed; the CLI's help documents the `config.json` fallback, so the entire home remains ephemeral by design. Successful login and reauthentication-after-container-recreation remain future operational verification tasks and do not block this implementation.

**Exit criteria:** Copilot CLI 1.0.112 and Node.js 22.23.5 build and run; automatic updates are disabled; approved settings and sessions have separate persistent mounts; the entire authentication home and logs remain ephemeral; automated checks reject known auth artifacts in persistent state, workspace, and cache; Level 0 remains offline with no persistent Copilot state. Successful login and reauthentication after container recreation remain outstanding operational verification.

## Phase 4 — Puppet development workflow

**Goal:** Support routine Puppet module development and repeatable local validation.

**Work:**

- Validate the exact Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1 pins at startup and in the module workflow.
- Provide PDK 4.0.1 module bootstrap with a pinned template and Ruby selector.
- Install module dependencies with project-scoped Bundler caches; keep Bundler application configuration ephemeral.
- Provide PDK validation and unit-test commands with explicit module paths and optional PDK arguments.
- Recommend Puppet 8 as the module target major while using module metadata and locked dependencies as the compatibility contract.
- Keep system Puppet Agent uninstalled until a target module establishes an exact runtime requirement; keep its APT installation unpinned by default.
- Document public-fork/local-branch practices, dependency/cache behavior, and recovery without adding GitHub authentication or remote-write access.

**Status:** Implemented. `agentforge-puppet` provides toolchain checks, PDK module bootstrap, per-module Bundler install, `pdk validate`, and `pdk test unit`. The workstation diagnostic requires Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1. New modules default to the PDK 4.0.1 template and `.ruby-version` 3.2.3. The Bundler cache is isolated by a hash of the canonical module path; Bundler configuration remains under `/tmp`. Puppet 8 is the recommended major, with PDK 4.0.1 reporting Puppet 8.22.0 in a local metadata-validation check; module metadata/lockfiles define exact compatibility and no system Agent is installed. `docs/puppet-development.md` defines the supported workflow, local fork workflow, version policy, and recovery. Synthetic command tests and PDK metadata validation pass; no external module repository or private source was accessed. The protected PDK package build and image-layer/log leak checks remain unverified without an authorized BuildKit credential.

**Exit criteria:** Workflow command behavior and cache isolation are tested using synthetic fixtures; PDK command compatibility is checked against the installed 4.0.1 help/version. End-to-end tests against a PDK-generated module remain an operator verification because module bootstrap fetches its template from the public PDK source. The workflow does not use or persist credentials. The protected package build still requires authorized validation under ADR-0004.

## Phase 5 — Acceptance testing platform

**Goal:** Add opt-in, repeatable Puppet acceptance testing against isolated disposable targets without changing the normal workstation's trust boundary.

**Work:**

- Make Litmus the proposed primary framework for new suites; preserve Beaker only for a named module with existing Beaker tests.
- Run a compatibility spike for rootless Podman targets in a dedicated, short-lived acceptance-provider boundary. Do not mount Docker or Podman sockets into the normal workstation.
- Select the exact Puppet Agent and target OS versions from a concrete module's support requirements. Build target images without runtime Puppet repository credentials, following ADR-0004.
- Stage a minimal module snapshot, exclude Git metadata and secrets, and keep persistent Copilot state inaccessible to the acceptance environment.
- Specify provider credentials as short-lived and run-scoped if a remote provider requires them. Keep EC2 opt-in and document cost and cleanup limits.
- Implement bounded provisioning, resource limits, explicit target allowlists, cleanup on success/failure/interruption, and human-readable run reports.
- Test that Levels 0 and 1 remain unchanged and cannot access provider sockets or cloud credentials.

**Design:** [Puppet Acceptance Testing Design](acceptance-testing.md); Proposed [ADR-0006](adr/0006-acceptance-testing-platform.md). The recommendation is not yet accepted and no provider is configured.

**Exit criteria:** A pinned Litmus/provider combination provisions and removes an approved disposable target without Docker daemon access from the normal workstation; the Puppet Agent target image follows ADR-0004; no runtime Puppet credentials or persistent authentication are present; failure cleanup and credential-exclusion checks pass.

## Phase 6 — GitHub CLI and MCP integration

**Goal:** Add separately governed GitHub CLI and constrained MCP capabilities after the acceptance boundary and first usable Puppet workflows are established.

**Work:**

- Keep GitHub CLI unauthenticated by default; add an optional read-only capability only if a reviewed workflow requires it.
- Keep MCP disabled unless a concrete workflow justifies an audited, minimal allowlist; document all enabled tools and endpoints.
- Test that Levels 0 and 1 cannot push or create pull requests using any available route.

**Exit criteria:** Tool availability matches the permission profile, and default remote writes are denied.

## Phase 7 — Level 2 and Level 3 operations

**Goal:** Add explicit remote collaboration and maintainer capabilities only after lower levels are verified.

**Work:**

- Define repository and branch allowlists, credential scope/lifetime, and push/PR confirmation.
- Define per-operation Level 3 approvals and a separate, short-lived execution path.
- Add audit metadata while excluding secret values and sensitive output.
- Test revocation and denial paths.

**Exit criteria:** Remote and maintainer actions are gated, auditable, target constrained, and unavailable by default.

## Ongoing maintenance

Review base images, tool versions, MCP server provenance, credentials practices, and security tests regularly. Record material design changes in ADRs. Keep documentation aligned with the actual behavior; remove or label unsupported capabilities rather than implying they exist.
