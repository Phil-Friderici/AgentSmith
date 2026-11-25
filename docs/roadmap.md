# Implementation Roadmap

## Status

The architecture baseline and Phase 2 workstation foundation are complete.

Phase 3 Copilot CLI integration and selective persistent state are implemented and operationally validated under ADR-0005.

Phase 4 Puppet module workflows are implemented and operationally validated, including the protected PDK package build workflow under ADR-0004.

Phase 5a local container acceptance testing is implemented and operationally validated under ADR-0006 using PDK-managed Litmus 2.8.2, the `docker_exp` provisioner, and rootless Podman 4.9.3+ds1-1ubuntu0.2. The validated runtime is PDK 4.0.1 / managed Ruby 3.2.11 / Bundler 2.4.20; the VS Code-to-Podman path remains inside the dedicated acceptance boundary.

Phase 5b compatibility and integration validation for the external VM path is complete. Production hardening and operational rollout remain future work; the proposed provider, credential, isolation, cost, and cleanup strategy is recorded in [ADR-0009](adr/0009-external-vm-acceptance-testing-strategy.md).

The Phase 6a GitHub CLI foundation, read-only wrapper layer, and ephemeral PAT lifecycle are implemented and authenticated metadata retrieval has been validated for both allowlisted repositories. Issues are disabled and no PRs or releases were available in those repositories. The PAT's actual permissions and scope remain operator-verified. See the [authenticated validation report](phase6a-authenticated-validation-report.md). MCP integration and higher permission levels remain unimplemented.

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
- Acceptance testing architecture is governed by Accepted ADR-0006. Phase 5a has been implemented and validated using Litmus 2.8.2, the `docker_exp` provisioner, and isolated rootless Podman targets. Phase 5b compatibility and integration validation is complete; production hardening remains future work.

**Status:** Policy choices are recorded in ADR-0002 through ADR-0005. Exact pins are recorded for Ubuntu/Git/Ruby, Bundler 2.4.20, and PDK 4.0.1 (`4.0.1.1-1noble`). PDK package metadata has no declared Puppet Agent dependency; an exact Agent version remains target-module-dependent. The BuildKit secret workflow has been implemented and operationally validated using real operator-provided Puppet repository credentials. Validation confirmed successful protected package retrieval, absence of credentials in runtime images, absence of credentials in image layers, and absence of credential leakage in build logs.

ADR-0005 rejects persistent Copilot authentication and approves separately persistent session/settings state. Phase 5a acceptance testing is implemented and validated under ADR-0006. Phase 5b compatibility and integration validation is complete; production hardening remains future work.

**Remaining roadmap items:**

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

Puppet Agent, Beaker, the production Phase 5b VM acceptance workflow, Level 2/3 operations, Docker daemon access, and MCP servers remain unimplemented. Phase 5b compatibility and integration validation is complete; its production hardening remains future work. GitHub CLI 2.105.0, `agentforge-gh`, and `agentforge-gh-auth` are installed only in the Level 1 image; the wrapper is constrained to the exact repositories in `containers/github-allowlist.yml` and only metadata read commands. Authenticated repository views, allowlist denials, ephemeral storage, non-disclosure, and recreation cleanup have been validated; repository data limitations and the operator-verified PAT scope are recorded in the Phase 6a report. Copilot authentication persistence is rejected by ADR-0005, not deferred. Copilot CLI and its approved session/settings persistence are implemented in Phase 3. Phase 5a acceptance testing is implemented and validated under ADR-0006.

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

**Status:** Implemented. `agentforge-puppet` provides toolchain checks, PDK module bootstrap, per-module Bundler install, `pdk validate`, and `pdk test unit`. The workstation diagnostic requires Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1. New modules default to the PDK 4.0.1 template and `.ruby-version` 3.2.3. The Bundler cache is isolated by a hash of the canonical module path; Bundler configuration remains under `/tmp`.

Puppet 8 is the recommended major, with PDK 4.0.1 reporting Puppet 8.22.0 in a local metadata-validation check; module metadata and lockfiles define exact compatibility and no system Puppet Agent is installed.

`docs/puppet-development.md` defines the supported workflow, local fork workflow, version policy, and recovery.

Synthetic command tests, PDK metadata validation, and the protected PDK package build workflow have passed. The protected package build workflow was validated using authorized credentials. Image-layer inspection, runtime inspection, and build-log inspection confirmed that secrets were not retained or exposed.

Real-module validation was performed against `puppetlabs-mysql`. Direct PDK execution and the documented AgentForge wrapper workflow both completed successfully:

- `pdk validate`
- `pdk test unit`
- `agentforge-puppet validate`
- `agentforge-puppet unit`

Validation confirmed equivalent behaviour between direct PDK execution and the AgentForge wrapper workflow. No functional differences were observed in dependency preparation, validator execution, runtime selection, or unit-test execution.

The observed runtime difference between the workstation toolchain and the PDK-managed runtime is expected because PDK executes within its own managed Ruby, Puppet, and Bundler environment.

Phase 4 is operationally validated for real-world Puppet module development workflows.

**Exit criteria:**

- Workflow command behavior and cache isolation are tested using synthetic fixtures.
- PDK command compatibility is checked against the installed 4.0.1 help/version.
- The protected package build workflow has been operationally validated under ADR-0004.
- Real-module validation demonstrates successful direct PDK execution against a representative Puppet Forge module.
- Real-module validation demonstrates successful execution of the documented AgentForge wrapper workflow against a representative Puppet Forge module.
- The workflow does not use or persist credentials.

## Phase 5 — Acceptance testing platform

**Goal:** Add opt-in, repeatable Puppet acceptance testing against isolated disposable targets without changing the normal workstation's trust boundary.

### Completed in Phase 5a

- Litmus 2.8.2 selected and validated.
- PDK-managed bundle installation and Litmus task loading validated with PDK 4.0.1, Ruby 3.2.11, Bundler 2.4.20, and `build-essential` for native extensions.
- `docker_exp` provisioner selected and validated.
- Rootless Podman 4.9.3+ds1-1ubuntu0.2 selected and validated.
- Podman runroot reconciliation validated with a new disposable graphroot; existing storage was preserved.
- VS Code tasks route through the acceptance wrapper as `agentforge-acceptance`; two PDK-managed acceptance runs passed and controlled-failure cleanup succeeded.
- Rootless Podman Unix socket boundary validated.
- Delegated cgroup placement validated.
- Puppet apply execution validated.
- Acceptance assertion execution validated.
- Cleanup after successful execution validated.
- Cleanup after failed execution validated.
- Repeatable execution validated.

### Completed in Phase 5b

- ADR-0009 architecture and security model reviewed and validated.
- Vagrant selected as the VM acceptance-testing approach.
- libvirt/KVM selected as the preferred backend.
- VirtualBox retained as a fallback backend.
- Ubuntu 24.04 validation-host candidate evaluated.
- KVM acceleration validated.
- QEMU 8.2.2 validated.
- libvirt 10.0.0 validated.
- vagrant-libvirt 0.12.2 validated.
- VM lifecycle validated:
  - provision
  - boot
  - SSH connectivity
  - teardown
  - cleanup
- Litmus provisioning validated against Vagrant/libvirt.
- Litmus inventory generation validated.
- Litmus SSH connectivity validated.
- Litmus teardown validated.
- Cleanup after provisioning failure validated.
- Inventory reconciliation and stale-entry cleanup validated.

### Remaining work

- Select the exact Puppet Agent version and initial operating-system target based on the target module's support matrix.
- Establish the final dedicated validation-host operating model described by ADR-0009.
- Implement controller/worker separation for production use.
- Implement durable audit storage and run journaling.
- Implement runtime, resource, and target-allowlist enforcement.
- Implement interruption recovery and independent cleanup verification for production operation.
- Validate at least one real module-specific acceptance-test workflow using the selected operating-system target.
- Produce operational documentation and runbooks.

**Status:** Phase 5a and Phase 5b compatibility validation are complete.

Validation confirmed:

Phase 5a:

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

Phase 5b:

- Vagrant 2.4.9
- libvirt/KVM
- QEMU 8.2.2
- libvirt 10.0.0
- vagrant-libvirt 0.12.2
- VM provisioning
- SSH connectivity
- VM teardown
- Cleanup verification
- Litmus provisioning workflow
- Inventory generation
- Failure cleanup and reconciliation

Phase 5 acceptance testing is operationally validated across both container-based and VM-based execution paths.

**Design:** [Puppet Acceptance Testing Design](acceptance-testing.md); [Validation Phase 1 guide](acceptance-validation-phase1.md); [ADR-0006](adr/0006-acceptance-testing-platform.md); [ADR-0009](adr/0009-external-vm-acceptance-testing-strategy.md); [Phase 5b Compatibility Spike Protocol](phase5b-compatibility-spike-test-protocol.md); [Phase 5b Compatibility Report](phase5b-compatibility-report.md); [Phase 5b Litmus Integration Report](phase5b-litmus-integration-report.md).

Phase 5 acceptance testing remains available only through dedicated acceptance-testing boundaries and is not available to normal Level 0 or Level 1 workstation workflows by default.

**Exit criteria status:** Phase 5a complete. Phase 5b compatibility and integration validation complete. Remaining work is operational hardening and productionization rather than architecture validation.

## Phase 6a — GitHub CLI read-only foundation

**Goal:** Provide Level 1-only GitHub CLI access and a constrained read-only metadata workflow using ephemeral authentication state and repository allowlists.

**Status:** Implemented and operationally validated.

Validation confirmed:

- GitHub CLI 2.105.0 installation and version pinning.
- Level 0 exclusion from GitHub CLI access.
- Level 1 ephemeral GitHub configuration using `GH_CONFIG_DIR` on tmpfs.
- Repository allowlist enforcement.
- Read-only `agentforge-gh` wrapper enforcement.
- Environment sanitization and override rejection.
- Ephemeral PAT storage using `agentforge-gh-auth`.
- Authentication-state removal after container recreation.
- Denial of unsupported and write operations.

Operational validation was completed using:

- `Phil-Friderici/puppetlabs-mysql`
- `Phil-Friderici/puppetlabs-concat`

Validated operations:

- `repo view`
- `pr list`

Repositories not present in the allowlist were denied as expected.

No GitHub credentials were stored in persistent locations, logs, diagnostics, generated files, workspace storage, or container images.

**Remaining work:** No Phase 6a implementation work remains. Verify fine-grained PAT permissions and repository scope before storing new credentials. Future GitHub functionality beyond read-only metadata retrieval is part of Phase 6b.

**Exit criteria:** Met.

Validated properties:

- Level 0 has no GitHub CLI and no GitHub integration capability.
- Level 1 uses only ephemeral GitHub configuration and authentication state.
- Only approved read-only metadata commands are available through the AgentForge wrapper.
- Repository allowlists are enforced.
- Unsupported and write operations are denied.
- Authentication state is removed through container recreation.
- No GitHub credentials are persisted.

## Phase 6b — Controlled contribution workflow

**Goal:** Enable an opt-in workflow from issue context through validated local commit to a controlled draft pull request, without merge or maintainer capabilities.

**Status:** Design proposed in [ADR-0008](adr/0008-controlled-contribution-workflow.md); not accepted or implemented.

Phase 6b is currently paused.

Repository eligibility reviews completed during ADR-0008 validation did not identify a repository that currently satisfies the required contribution controls. As a result, no contribution broker implementation, write credential workflow, branch push workflow, or draft pull-request workflow has been approved for implementation.

Normal Level 1 remains read-only for GitHub metadata and has no write credential.

The proposed design requires:

- A separate, empty-by-default contribution allowlist with exact repositories and base branches.
- A credential-free validation runner whose evidence is bound to the exact staged tree and resulting commit.
- An isolated, one-shot contribution broker that alone receives a short-lived repository-scoped write credential.
- Separate operator approvals before branch push and draft PR creation.
- A host-side persistent audit journal containing action metadata but no credentials or full output.
- Protected base branches, no bypass for the contribution identity, and no merge operation in the broker.
- Repository workflow-exposure review and eligibility approval before any repository may participate in Phase 6b.
- Verified merge denial, branch protection, credential lifecycle controls, and workflow-trigger safety for each approved repository.
- No issue modification, workflow execution, repository administration, arbitrary GitHub CLI/API access, force-push, or branch deletion.

**Current blocker:** No repository has yet passed the ADR-0008 eligibility review. Existing candidate repositories require additional workflow hardening, branch-protection controls, or contribution-safety verification before Phase 6b can proceed.

**Implementation roadmap:** Phase 6b remains paused pending an eligible repository. Resume only after a repository successfully completes the ADR-0008 eligibility review, workflow-exposure review, merge-denial validation, and branch-protection validation. Once an eligible repository exists, implement audit/approval orchestration, credential-free validation and tree-bound evidence, the isolated broker, the ephemeral write-credential lifecycle, and then complete mocked, failure-path, security-boundary, and repository-specific validation before enabling contributions.

## Phase 7 — Level 3 maintainer operations

**Goal:** Provide an optional future path for maintainer-level operations after lower levels are verified. Phase 6b defines the constrained Level 2 contribution workflow.

**Status:** ADR-0010 is Accepted. Phase 7 architecture, security review, implementation planning, provider selection, provider integration planning, and Phase 7a/7b implementation foundations are complete.

Level 3 remains a future capability and is not required for the current AgentSmith operating model.

AgentSmith currently targets:

- Local Puppet module development
- Validation and testing
- Branch creation in controlled repositories
- Fork-based contribution workflows
- Draft pull-request creation

AgentSmith does not currently target:

- Pull-request merge automation
- Release automation
- Repository maintainer workflows
- Organization administration

No production provider is connected. All Level 3 operations remain disabled.

Implementation sequencing and validation gates are defined in the [Phase 7 implementation plan](phase7-implementation-plan.md), [provider integration plan](phase7-provider-integration-plan.md), and [provider integration validation plan](phase7-provider-integration-validation-plan.md).

ADR-0010 acceptance satisfies the architecture and governance gates. Any future Level 3 enablement requires separate implementation, validation, and operational approval.

**Implemented Foundations:**

- Broker foundation
- Operation allowlisting
- Approval framework
- Audit framework
- Revocation framework
- Emergency-stop framework
- Fail-closed enforcement
- Identity and approval provider selection
- Provider integration planning
- Provider integration validation planning

**Deferred Work:**

- Production provider deployment
- Credential issuance services
- Durable audit infrastructure
- External emergency-stop services
- Provider-backed validation
- Merge operations
- Release operations
- Additional maintainer operations

**Exit criteria:** Remote and maintainer actions are gated, auditable, target constrained, explicitly authorized per operation, validated against real providers, and disabled by default until explicitly enabled.

**Current status:**

- Phase 7 implementation planning completed.
- Phase 7 provider integration work paused.
- Level 3 remains disabled.
- No maintainer operations are enabled.

Phase 7 remains paused; see the [Phase 7 implementation plan](phase7-implementation-plan.md) for its current scope and gates.

## Ongoing maintenance

Review base images, tool versions, MCP server provenance, credentials practices, and security tests regularly. Record material design changes in ADRs. Keep documentation aligned with the actual behavior; remove or label unsupported capabilities rather than implying they exist.
