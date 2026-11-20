# Puppet Acceptance Testing Design

## Status and scope

This document records the Phase 5 design and current validation. The Phase 5a acceptance identity, transient delegated Podman API helper, and synthetic Litmus fixture are present. A finite `--pids-limit=1024` resolved the observed zero-limit behavior; four serial minimal Puppet apply/assertion runs passed, a controlled assertion failure was detected and torn down, and a fresh subsequent run passed. The [Phase 5a validation report](phase5a-validation-report.md) records the cleanup evidence. ADR-0006 remains Proposed pending the maintainers' acceptance decision. The design preserves ADR-0004's build-only Puppet repository secret boundary and ADR-0005's ephemeral Copilot authentication.

The dedicated VM specification, provisioning guide, validation checklist, diagnostics, and ADR-0006 acceptance gate are in [Acceptance Testing Validation Phase 1](acceptance-validation-phase1.md). The current Phase 5a validation does not change ADR-0006's Proposed status.

The assessment is qualitative, not a current market-share survey. Litmus and Beaker are test frameworks; Docker, Podman, nested KVM, and EC2 are target or provisioning technologies. A framework does not itself isolate the code or target it runs.

## Goals and boundaries

Phase 5 should make acceptance tests available as an explicitly invoked development capability, not turn AgentForge into a CI runner. A run must use disposable, versioned targets, have a clear teardown path, and leave the default Level 0/Level 1 workstation unchanged.

The acceptance environment must:

- Keep the normal workstation free of Docker sockets, Podman sockets, `/dev/kvm`, cloud credentials, and Puppet repository credentials.
- Keep Copilot authentication ephemeral and separate from any test-session state.
- Run against explicitly selected, disposable targets only; never infer or target production systems.
- Avoid mounting the full writable project workspace into target systems or provider services. Stage a reviewed, credential-free module snapshot for a run.
- Pin the framework, provider, target operating-system image, and Puppet Agent version. Do not install Puppet Agent at target startup using protected-repository credentials.
- Make provisioning and teardown visible, bounded, and repeatable. Use run identifiers, resource/time limits, and cleanup verification.
- Treat module code, tests, target images, and provider responses as untrusted.

Level 1 is not a security sandbox for arbitrary module/test code. Acceptance execution therefore needs a separate, opt-in boundary and must not inherit Copilot state, broad host paths, or unrelated caches.

## Option comparison

Risk and complexity labels are relative to the existing unprivileged workstation. Community-adoption comments are qualitative and do not imply that every Forge module supports the option.

| Option | Complexity | Security | Performance | Puppet community adoption | Forge module compatibility |
| --- | --- | --- | --- | --- | --- |
| **Litmus** | Medium: Puppet-focused tasks and fixtures, but a provider and target lifecycle still need configuration. | Framework is not a boundary; risk is determined by the provider, credentials, mounts, and target isolation. | Low framework overhead; target boot/provisioning dominates. | Strong current alignment with Puppet module development and PDK workflows. | Best default for new acceptance workflows that already use Litmus; not universal across Forge modules. |
| **Beaker** | High: legacy harness and provider-specific configuration can be substantial. | Similar provider-dependent risks; often requires SSH and provisioning credentials that must be scoped per run. | Medium to low; VM/cloud provisioning and test setup can dominate. | Established and widely represented in older Puppet module suites; ongoing use varies by module. | Strong for modules already carrying Beaker specs and provider configuration; do not assume drop-in compatibility with Litmus. |
| **Docker targets** | Low to medium for common local container targets and Litmus Docker workflows. | High risk if the workstation receives a general Docker socket: control of the daemon can expose host files and resources. A rootless, isolated provider reduces but does not remove risk. | High for short-lived Linux targets; usually the fastest local loop. | Broad container adoption; Litmus commonly uses container-oriented targets. | Good where the module's acceptance suite and provider support Docker; not every module supports container targets or the required init/system behavior. |
| **Podman targets** | Medium to high: rootless operation is attractive, but provider/API compatibility and lifecycle behavior must be proven. | Better host boundary potential with a dedicated rootless identity and isolated storage; its API socket remains a powerful capability and is not safe to expose generally. | High for ordinary Linux containers, with some setup/network differences from Docker. | Growing general Linux adoption, but less established as a Puppet acceptance provider than Docker. | Conditional: likely useful for compatible Litmus Docker-style providers, but compatibility is not assumed. Test module behavior, service management, networking, and cleanup. |
| **Nested KVM virtualization** | Very high: requires VM images, host virtualization support, resource management, networking, and likely a separate privileged provider boundary. | Strong target isolation when configured correctly, but exposing `/dev/kvm`, libvirt, or host control to the workstation materially expands its privileges. | High target fidelity and good repeated-run speed after image preparation; boot and resource costs remain material. | Familiar in VM-based testing, particularly legacy Beaker/Vagrant-style workflows; not the simplest default. | Broad OS/service fidelity for modules that require a full system, but provider-specific configuration is needed. |
| **EC2-backed targets** | High: requires cloud account setup, IAM scope, network access, image lifecycle, quotas, and reliable teardown. | Good separation from the workstation when using short-lived, narrowly scoped credentials and isolated disposable instances; credential and cloud-resource controls are essential. | Low to medium: provisioning and network latency make the inner loop slower. | Common in cloud CI and realistic multi-OS testing; Puppet provider support is module/framework-dependent. | High potential for modules requiring real system behavior or supported OS matrices, provided the suite has a compatible provider. Cost and cloud assumptions limit portability. |

## Recommendation

Adopt **Litmus as the primary framework** for new AgentForge acceptance workflows. For the default local target, pursue **rootless Podman in a dedicated acceptance-provider boundary**, not a Podman or Docker socket mounted into the normal workstation. Keep Beaker as a compatibility path for a concrete module that already depends on it. Use EC2 only as an explicit opt-in for tests that need cloud fidelity, a wider OS matrix, or provider behavior unavailable locally.

The Podman choice is conditional on a Phase 5 compatibility spike. The spike must demonstrate that the pinned Litmus/provider combination can provision, connect to, and reliably remove rootless Podman targets without exposing the workstation's host Docker daemon, broad host mounts, Copilot state, or Puppet repository credentials. If this fails, do not silently substitute a Docker socket. Reassess an isolated EC2 provider or submit a separate security-reviewed proposal for a dedicated rootless Docker provider.

The acceptance provider must be separate from the normal development service. Prefer a short-lived runner/provider environment under a dedicated unprivileged identity with private Podman storage, no `sudo`, and no general host-home access. Only the staged module snapshot and required test output should cross into that environment. If the test runner must access a provider API socket, use a permission-restricted local socket confined to that disposable provider boundary; do not expose an unauthenticated API over TCP, mount the socket into the normal workstation, or expose it to Copilot sessions.

This design keeps routine module work fast and local while preserving a route to higher-fidelity targets. Podman lowers daemon/host risk compared with a shared Docker socket, but does not by itself make arbitrary test code safe. EC2 is a better isolation option for higher-risk suites, at the cost of latency, cloud setup, credentials, and spend.

## Credentials and image lifecycle

- ADR-0004 remains authoritative for Puppet repository credentials: they are never runtime credentials. If a target image requires a protected Puppet Agent package, use an approved BuildKit-secret image-build path to fetch the exact package; install it in a later secret-free stage. Do not install Agent packages from protected repositories when a test target starts.
- Select the exact Puppet Agent version from the target module's declared support matrix and record it before target-image implementation. PDK's bundled Puppet version is not a substitute for an explicit Agent pin.
- Any provider credential required by an opt-in remote backend must be short-lived, narrowly scoped, supplied only for that run, and absent from repositories, workspace, cache, persistent Copilot state, and logs. Prefer a host/operator-mediated identity flow; do not add persistent GitHub CLI authentication.
- Test-target SSH material, if required, is generated or supplied for one run and discarded with the target. It must not be copied into the module snapshot or test logs.
- ADR-0005 remains unchanged: Copilot authentication stays ephemeral; only the already approved session/settings artifacts may persist.

## Proposed execution flow

1. The operator explicitly starts the acceptance profile and names the module, target image/version, and allowed provider.
2. Preflight checks confirm the selected toolchain pins, module path, target allowlist, resource limits, and absence of forbidden mounts or credentials.
3. AgentForge stages a minimal module snapshot without Git metadata, local secrets, Copilot data, or unrelated repositories.
4. The isolated provider creates disposable targets from pinned images containing the exact Puppet Agent version required by the test.
5. Litmus provisions the module and runs its acceptance suite. Beaker is used only when a named module requires its existing harness.
6. Results are collected without secret values; targets and one-run credentials are removed even after failure or interruption. A final cleanup check reports any resource that could not be removed.

The details of artifact transport, provider API, logging, and interruption recovery are Phase 5 implementation decisions gated by the compatibility spike. No service, profile, socket, image, package, or credential flow is enabled by this proposal.

## Phase 5 implementation roadmap

1. **Compatibility spike:** Select one representative module or synthetic fixture and a pinned Litmus version. Prove the rootless Podman provider lifecycle, systemd/service behavior, network isolation, and teardown. No Docker daemon or persistent credentials.
2. **Target contract:** Choose and record the exact Puppet Agent and target OS versions from a module support requirement. Decide how the target image is built under ADR-0004 without runtime repository credentials.
3. **Isolated execution boundary:** Specify a separately invoked acceptance profile/provider identity, minimal artifact transfer, mount/network policy, resource limits, and failure-safe cleanup.
4. **Workflow and evidence:** Add repeatable commands, human-readable reports, a disposable fixture, and tests for denied mounts, target allowlists, cleanup, and credential absence.
5. **Compatibility policy:** Add Beaker only for a named Forge module need. Add EC2 only as an explicitly configured provider with per-run credentials and cost/cleanup limits.

### Phase 5 exit criteria

- A documented Litmus/Podman compatibility result and pinned versions are available.
- A disposable target can be provisioned, used, and torn down without Docker daemon access from the normal workstation.
- The acceptance boundary has no access to persistent Copilot authentication, repositories other than the staged snapshot, or Puppet repository credentials at runtime.
- The target Puppet Agent version and image build comply with ADR-0004.
- Failure and interruption paths report and clean up resources; the run leaves no credentials or unintended target state behind.
- The existing Level 0/Level 1 Compose profiles remain unchanged.

## Open decisions

- Which module or synthetic acceptance fixture should be the compatibility test?
- Does the selected Litmus release work correctly with a rootless Podman API/provider, including service startup and teardown?
- Should the isolated provider boundary be a dedicated host account/service or a separate disposable VM on operators without an external provider?
- Which target OS and exact Puppet Agent version are required by the first supported module?
- Is a Beaker compatibility harness required by a specific maintained Forge module?
- Is EC2 necessary for any module's supported target matrix, and what short-lived identity mechanism and spend limits are acceptable?
