# Implementation Roadmap

## Status

The architecture baseline and Phase 2 workstation foundation are complete.

Phase 3 Copilot CLI integration and selective persistent state are implemented and operationally validated under ADR-0005.

Phase 4 Puppet module workflows are implemented and operationally validated, including the protected PDK package build workflow under ADR-0004.

Phase 5a local container acceptance testing is implemented and operationally validated under ADR-0006 using Litmus 2.8.2, the docker_exp provisioner, and rootless Podman 4.9.3+ds1-1ubuntu0.2.

Phase 5b external VM-based acceptance testing remains future work.

GitHub CLI integration, MCP integration, and higher permission levels remain unimplemented.

## Phase 0 — Architecture baseline

**Goal:** Establish shared project intent, boundaries, and security requirements.

**Deliverables:** Vision, architecture, permission model, MCP and secret strategy, directory contracts, ADR framework, and an implementation sequence.

**Exit criteria:** Open decisions are identified; maintainers agree that default access is read-only, state is external to replaceable containers, and credentials are scoped to a single operation. Puppet package credentials are BuildKit-only under ADR-0004 and never available at runtime.

## Phase 1 — Resolve implementation decisions

**Goal:** Make the minimum decisions needed for a secure reproducible workstation.

**Decisions already made (ADR-0002 and subsequent approved ADRs):**

- Workspace root: `~/AgentForge/workspace`, separate from this source checkout.
- Bind-mount identity: match host UID/GID; never recursively change ownership at startup.
- Puppet credentials: external and used only as a BuildKit secret during PDK package download; never passed via `ARG`/`ENV`, written into image layers, or mounted at runtime. PDK image rebuilds require the external credential.
- GitHub CLI/Git: no authentication in the initial workstation baseline; remote write access is a later, separately approved feature. Copilot authentication and session-state rules follow ADR-0005: authentication is ephemeral, while approved non-secret settings and sessions may persist separately.
- MCP: disabled in the initial baseline; add only reviewed integrations for a concrete need.
- Versions: exact pins with deliberate, compatibility-tested updates.
- Caches: selected per-user/per-project Ruby/Bundler and PDK caches; no credentials and no writable sharing across permission levels.
- Acceptance testing architecture is governed by ADR-0006. Phase 5a has been implemented and validated using Litmus 2.8.2, the docker_exp provisioner, and isolated rootless Podman targets. Phase 5b remains future work.

**Status:** Policy choices are recorded in ADR-0002 through ADR-0005. Exact pins are recorded for Ubuntu/Git/Ruby, Bundler 2.4.20, and PDK 4.0.1 (`4.0.1.1-1noble`). PDK package metadata has no declared Puppet Agent dependency; an exact Agent version remains target-module-dependent. The BuildKit secret workflow has been implemented and operationally validated using real operator-provided Puppet repository credentials. Validation confirmed successful protected package retrieval, absence of credentials in runtime images, absence of credentials in image layers, and absence of credential leakage in build logs.

ADR-0005 rejects persistent Copilot authentication and approves separately persistent session/settings state. Phase 5a acceptance testing is implemented and validated under ADR-0006. Phase 5b remains future work.

**Remaining roadmap items:**

- Select and document compatible exact versions for GitHub CLI before Phase 6 implementation. Phase 3 targets the studied Copilot CLI 1.0.112 release and pins its Node.js runtime.
- Select and document an exact Puppet Agent version when a concrete module workflow establishes its runtime requirement.
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

**Status:** Phase 2 foundation is implemented: digest-pinned Ubuntu 24.04, pinned Git/Ruby/Bundler/PDK versions, Level 0/Level 1 Compose profiles, explicit host UID/GID, read-only root filesystem for normal profiles, no Docker socket, and per-profile mount health checks. Level 0 has a read-only workspace and no network. Level 1 has a writable workspace and selected cache, with network access but no runtime credentials. Host bind mounts preserve workspace state across container recreation. Host-path initialization, startup diagnostics, and setup/operations/troubleshooting guides are included. The PDK build-only secret workflow is implemented and operationally validated using real operator-provided credentials. Validation confirmed successful protected package retrieval without credential leakage into runtime images, image layers, or build logs. MCP remains disabled.

**Exit criteria:** Met for the Phase 2 base. The PDK image's BuildKit-secret package flow is configured and operationally validated. The environment is replaceable without losing host-mounted workspace state, runs unprivileged in normal profiles, and has no runtime Puppet credentials, Docker socket, or broad host mounts.

### Phase 2 architecture compliance

The implementation follows ADR-0001 through ADR-0004: one replaceable unprivileged workstation image, external bind-mounted workspace/cache, Level 0/1 capability separation, no runtime Puppet credentials or Docker socket, and a BuildKit-only PDK package secret. ADR-0005 additionally governs future Copilot authentication and session/settings state. The host initializer, diagnostic, documentation, `.gitignore`, and build-context allowlist are implementation details that reinforce those decisions.

GitHub CLI, Puppet Agent, Beaker, Phase 5b VM-based acceptance testing, Level 2/3 operations, Docker daemon access, and MCP servers remain unimplemented. Copilot authentication persistence is rejected by ADR-0005, not deferred. Copilot CLI and its approved session/settings persistence are implemented in Phase 3. Phase 5a acceptance testing is implemented and validated under ADR-0006. Phase 5b remains future work.

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

**Status:** Implemented. The image pins Copilot CLI 1.0.112 and Node.js 22.23.5, verifies npm dependencies from a lockfile, and sets `COPILOT_AUTO_UPDATE=false`. Level 1 uses a tmpfs `/copilot` home and individually bind-mounts only read-only `settings.json`, `session-state/`, and `session-store.db`; Level 0 is offline with no persistent Copilot mounts. Host initialization and runtime diagnostics enforce the path allowlist and scan state/workspace/cache for known authentication artifacts without displaying contents. Session retention is documented as weekly review with a 30-day maximum for inactive sessions. Operational validation confirmed successful login, separation of authentication and persistent state, required reauthentication after container recreation, and persistence of approved session/settings state in accordance with ADR-0005.

**Exit criteria:** Copilot CLI 1.0.112 and Node.js 22.23.5 build and run; automatic updates are disabled; approved settings and sessions have separate persistent mounts; the entire authentication home and logs remain ephemeral; automated checks reject known auth artifacts in persistent state, workspace, and cache; Level 0 remains offline with no persistent Copilot state.

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

**Status:** Implemented. `agentforge-puppet` provides toolchain checks, PDK module bootstrap, per-module Bundler install, `pdk validate`, and `pdk test unit`. The workstation diagnostic requires Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1. New modules default to the PDK 4.0.1 template and `.ruby-version` 3.2.3. The Bundler cache is isolated by a hash of the canonical module path; Bundler configuration remains under `/tmp`. Puppet 8 is the recommended major, with PDK 4.0.1 reporting Puppet 8.22.0 in a local metadata-validation check; module metadata/lockfiles define exact compatibility and no system Agent is installed. `docs/puppet-development.md` defines the supported workflow, local fork workflow, version policy, and recovery. Synthetic command tests and PDK metadata validation pass; no external module repository or private source was accessed. The protected PDK package build workflow was successfully validated using authorized credentials. Image-layer inspection, runtime inspection, and build-log inspection confirmed that secrets were not retained or exposed.

**Exit criteria:** Workflow command behavior and cache isolation are tested using synthetic fixtures; PDK command compatibility is checked against the installed 4.0.1 help/version. End-to-end tests against a PDK-generated module remain an operator verification because module bootstrap fetches its template from the public PDK source. The workflow does not use or persist credentials. The protected package build workflow has been operationally validated under ADR-0004.

## Phase 5 — Acceptance testing platform

**Goal:** Add opt-in, repeatable Puppet acceptance testing against isolated disposable targets without changing the normal workstation's trust boundary.

### Completed in Phase 5a

- Litmus 2.8.2 selected and validated.
- `docker_exp` provisioner selected and validated.
- Rootless Podman 4.9.3+ds1-1ubuntu0.2 selected and validated.
- Rootless Podman Unix socket boundary validated.
- Delegated cgroup placement validated.
- Puppet apply execution validated.
- Acceptance assertion execution validated.
- Cleanup after successful execution validated.
- Cleanup after failed execution validated.
- Repeatable execution validated.

### Remaining work for Phase 5b

- Select the exact Puppet Agent and target OS versions from a concrete module's support requirements.
- Build target images without runtime Puppet repository credentials, following ADR-0004.
- Specify provider credentials as short-lived and run-scoped if a remote provider requires them.
- Keep EC2 opt-in and document cost and cleanup limits.
- Implement bounded provisioning, resource limits, explicit target allowlists, cleanup on success/failure/interruption, and human-readable run reports for VM-based targets.
- Test that Levels 0 and 1 remain unchanged and cannot access provider sockets or cloud credentials.
- Evaluate and select preferred VM-based providers (for example EC2, Vagrant, or Beaker-based workflows).
- Validate supported operating systems for Phase 5b.

**Status:** Phase 5a is implemented and operationally validated.

Validation confirmed:

- Litmus 2.8.2
- `docker_exp` provisioner
- Rootless Podman 4.9.3+ds1-1ubuntu0.2
- Run-scoped rootless Podman Unix socket
- Delegated cgroup placement
- Puppet apply execution
- Acceptance assertion execution
- Cleanup after success
- Cleanup after failure
- Repeatable execution

Four successful Litmus runs completed. A controlled failure was detected and cleaned up successfully. A subsequent clean run also passed.

Phase 5a is complete.

Phase 5b remains unimplemented.

**Design:** [Puppet Acceptance Testing Design](acceptance-testing.md); [Validation Phase 1 guide](acceptance-validation-phase1.md); [ADR-0006](adr/0006-acceptance-testing-platform.md).

Phase 5a is available only through the isolated acceptance boundary and is not available to normal Level 0 or Level 1 workstation workflows by default.

**Exit criteria status:** Phase 5a complete. Phase 5b pending.

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
