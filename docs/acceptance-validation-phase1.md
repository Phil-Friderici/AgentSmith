# Acceptance Testing Validation Phase 1

## Status and purpose

This document records the dedicated-environment requirements for the Litmus/rootless Podman compatibility validation specified by Accepted [ADR-0006](adr/0006-acceptance-testing-platform.md). The earlier `unshare -Ur true` failure (`Operation not permitted`) describes the previous host only; it is not evidence that Litmus and Podman are incompatible.

This phase provisions and validates a disposable VM and runs a bounded compatibility fixture. It does not enable acceptance testing in the normal AgentForge workstation, install an acceptance provider there, or change ADR-0004, ADR-0005, or the accepted decision in ADR-0006.

**Current Phase 5a status:** The configured workflow is operationally validated with PDK 4.0.1, PDK-managed Ruby 3.2.11, Bundler 2.4.20, Litmus 2.8.2, `docker_exp`, and the existing target configuration. The recorded system-Ruby/Bundler validation remains historical; the subsequent PDK-managed runs, wrapper behavior, native extension build, and Podman runroot reconciliation are additional evidence in the [Phase 5a report](phase5a-validation-report.md). The normal workstation remains outside the acceptance boundary.

## Environment specification

Use a dedicated Ubuntu Server 24.04 LTS x86_64 VM. Do not run this experiment inside the normal workstation container or on a shared host whose user-namespace policy is outside the operator's control. Ordinary VM virtualization is sufficient; nested KVM is not required.

| Resource | Minimum for a serial compatibility run | Recommended |
| --- | --- | --- |
| vCPU | 4 | 8 |
| Memory | 8 GiB | 16 GiB |
| Root disk | 40 GiB SSD | 80 GiB SSD |
| Architecture | amd64/x86_64 | amd64/x86_64 |
| Network | Outbound access to approved Ubuntu package, RubyGems, and OCI registries; no public inbound ports | Same, with egress allowlisting |

These are conservative preparation values, not benchmark results. Do not run targets in parallel during the initial compatibility test. Increase resources only if recorded measurements show a need.

### Version baseline

| Component | Phase 1 baseline | Status |
| --- | --- | --- |
| Ubuntu | 24.04 LTS, current patched point release | Recommended environment; record image ID and kernel version. |
| Podman | `4.9.3+ds1-1ubuntu0.2` | Validated rootless with the `docker_exp` provider and the owner-restricted Phase 5a API service. |
| Litmus | `puppet_litmus` gem `2.8.2` | Locked in the Phase 5a fixture and validated with PDK-managed Bundler. |
| PDK / Ruby / Bundler | PDK `4.0.1`; observed managed Ruby `3.2.11` / Puppet `8.22.0`; Bundler `2.4.20` | Record the versions reported by the tested PDK and locked fixture; PDK's managed runtime is distinct from system Ruby. |
| Native build tools | `build-essential` `12.10ubuntu1` | Required to compile native gem extensions during `pdk bundle install`; system `ruby-dev` packages are not required. |
| Puppet Agent | Exact version required by the synthetic fixture, preinstalled in the pinned target image | Record the target image digest and Agent version. Do not fetch protected packages from a target at runtime. |

The exact Podman, PDK, Ruby, Bundler, Litmus, and target-image findings are recorded in the [Phase 5a validation report](phase5a-validation-report.md). Pin every resolved Ruby dependency and target image by exact version/digest in the validation record.

## Required kernel and host configuration

The VM must provide:

- User, mount, PID, IPC, UTS, and network namespaces, with unprivileged user-namespace creation permitted for the dedicated operator account.
- cgroup v2 with systemd as the cgroup manager.
- Seccomp support.
- OverlayFS support, or `fuse-overlayfs` as the rootless storage fallback.
- Rootless networking through `slirp4netns` or `pasta`/`passt`.
- `newuidmap` and `newgidmap` from the `uidmap` package.

Check the running kernel and cgroup mode:

```sh
uname -a
stat -fc '%T' /sys/fs/cgroup
grep -E '^(CONFIG_USER_NS|CONFIG_NAMESPACES|CONFIG_SECCOMP|CONFIG_SECCOMP_FILTER|CONFIG_OVERLAY_FS)=' "/boot/config-$(uname -r)" 2>/dev/null || true
```

`stat` should report `cgroup2fs`. Kernel config files may not be installed; successful rootless namespace and Podman checks below are authoritative.

Inspect relevant sysctls before changing anything:

```sh
sysctl kernel.unprivileged_userns_clone user.max_user_namespaces \
  kernel.apparmor_restrict_unprivileged_userns 2>&1 || true
```

For this dedicated VM only:

- If `kernel.unprivileged_userns_clone` exists, it must be `1`.
- `user.max_user_namespaces` must be nonzero and large enough for the test; use at least `65536`.
- Ubuntu 24.04 may restrict unprivileged user namespaces through AppArmor. Prefer a narrowly scoped AppArmor rule for the validation account/programs. If that cannot be made reliable, `kernel.apparmor_restrict_unprivileged_userns=0` may be used only on this disposable VM after recording the security trade-off. Never apply this change to a shared host or the normal AgentForge workstation.
- Do not change unrelated namespace, network, or privilege sysctls to make a failing test pass.

Use the dedicated unprivileged `agentforge-acceptance` account (UID/GID `999:987`) prepared by `scripts/acceptance/setup-identity.sh`. It uses `/var/lib/agentforge-acceptance` with mode `0700`, has no supplementary groups or interactive login, and does not receive `sudo` access. The operator invokes the wrapper with `sudo`; the wrapper stages the fixture and switches to this account for PDK and Podman API client work. Its non-overlapping subordinate UID/GID ranges are `165536:65536`:

```text
agentforge-acceptance:165536:65536
```

Verify both files and the resulting maps before starting Podman. The Phase 5a graphroot is `/var/lib/agentforge-acceptance/podman-storage-phase5a-reconcile`; do not reuse, delete, or migrate the previous graphroot.

## Provisioning guide

1. Create a clean Ubuntu Server 24.04 LTS VM with the resources above. Disable shared folders, host-home mounts, clipboard/file sharing, and nested virtualization unless separately required. Do not attach the normal workstation's Docker or Podman socket.
2. Create the dedicated validation account and assign non-overlapping subordinate UID/GID ranges. Configure only the namespace sysctls required by the kernel on this VM.
3. Use the approved PDK-enabled host/validation environment (PDK 4.0.1 and `build-essential` must be available to the wrapper), then install Podman and rootless dependencies. Confirm the exact package version before proceeding:

   ```sh
   sudo apt-get update
   apt-cache policy podman
   sudo apt-get install -y \
     podman=4.9.3+ds1-1ubuntu0.2 \
     uidmap slirp4netns fuse-overlayfs netavark aardvark-dns crun \
     build-essential=12.10ubuntu1 \
     git curl ca-certificates jq
   ```

   If the exact Podman version is no longer available, stop and update this validation record with the proposed replacement; do not allow APT to silently select another version. Do not install Docker Engine, Docker CLI, `docker.io`, or a Docker socket.
4. Stage the locked fixture and install its bundle through the acceptance wrapper. The wrapper copies only `acceptance/fixture` into the acceptance identity's private home and invokes PDK as that identity. Do not run PDK directly from the normal workstation context or modify the repository lockfile.

   ```sh
   sudo scripts/acceptance/run-pdk-litmus.sh stage
   sudo scripts/acceptance/run-pdk-litmus.sh install
   sudo scripts/acceptance/run-pdk-litmus.sh versions
   ```

5. Keep the staged fixture disposable and outside the AgentForge source checkout. Use its existing `Gemfile.lock` with `puppet_litmus` 2.8.2; do not resolve a different dependency set or change the committed lockfile.
6. Prepare one pinned, disposable Linux target image that already contains the exact Puppet Agent version required by the fixture. The image must not require protected Puppet repository credentials at startup. Record the full image digest.
7. Allow egress only as needed for Ubuntu packages, RubyGems, and the selected OCI registry. No GitHub CLI login, GitHub token, MCP server, Copilot authentication, Puppet repository credential, or unrelated provider credential is needed for this local compatibility test.
8. Record the VM image, kernel, Podman, Ruby, Bundler, Litmus lockfile, target-image digest, and sysctl state before testing.

For the Phase 5a fixture, start the **rootless Unix API socket only inside the dedicated acceptance environment** using the wrapper. It invokes the existing service helper, which uses a fresh disposable graphroot and matching runroot; do not reuse or delete the previous graphroot:

```sh
sudo scripts/acceptance/run-pdk-litmus.sh start-provider
```

The wrapper gives the staged Litmus process only the fixed `DOCKER_HOST` for this Podman socket; it does not inherit workstation environment variables. Do not bind the socket to TCP, forward it to another host, mount it into a normal workstation service or target, or enable a persistent/lingering service. Stop the service after teardown. If the provider cannot use the local rootless socket without Docker Engine or a privileged daemon, record the blocker and stop; do not weaken the boundary.

## Validation checklist

### A. Host prerequisites

- [ ] Confirm the validation account is unprivileged and not in a Docker-admin group.
- [ ] Confirm Podman package version equals the recorded pin.
- [ ] Confirm subordinate UID and GID ranges are present and non-overlapping.
- [ ] Confirm cgroup v2 and the required namespace policy.
- [ ] Confirm no Docker Engine, Docker socket, GitHub CLI authentication, MCP service, Puppet repository credential, or Copilot state is present.
- [ ] Record all installed component versions and target image digest.

### B. Rootless Podman

Run the identity check and inspect the configured rootless API through the wrapper:

```sh
sudo runuser --user agentforge-acceptance -- /usr/bin/unshare -Ur true
sudo scripts/acceptance/run-pdk-litmus.sh start-provider
sudo scripts/acceptance/run-pdk-litmus.sh info
```

Confirm that the API reports rootless operation, the expected UID/GID mappings, graphroot `/var/lib/agentforge-acceptance/podman-storage-phase5a-reconcile`, and runroot `/run/agentforge-acceptance/999/phase5a/containers`. The service helper verifies the owner-only Unix socket, delegated cgroup, and API response. Do not query or mutate the previous graphroot.

The runroot mismatch is resolved for the validated service configuration by pairing the new disposable graphroot with its configured runroot. `podman info` passed before and after the service restart; startup and shutdown passed, and the existing graphroot was not modified or deleted.

The service remains active for the Litmus run. Stop it only after Litmus teardown and after the wrapper confirms the target inventory is empty. Never use a TCP listener.

### C. Litmus lifecycle

Use only the disposable fixture and the locked dependency set. First list the tasks provided by the pinned release:

```sh
sudo scripts/acceptance/run-pdk-litmus.sh install
sudo scripts/acceptance/run-pdk-litmus.sh list
```

The pinned fixture exposes these lifecycle operations:

1. Provision one target using rootless Podman with `sudo scripts/acceptance/run-pdk-litmus.sh provision`.
2. Check connectivity with `sudo scripts/acceptance/run-pdk-litmus.sh connectivity`.
3. Apply the fixture and run its RSpec acceptance example with `sudo scripts/acceptance/run-pdk-litmus.sh acceptance`.
4. Collect the test report and relevant target output.
5. Tear down the target with `sudo scripts/acceptance/run-pdk-litmus.sh teardown`. The wrapper attempts teardown automatically when the acceptance task fails; verify that cleanup succeeded and invoke the explicit teardown action if it did not.
6. After confirming teardown, remove only the staged fixture with the wrapper's `clean` action, then stop the provider service with `stop-provider`.

Record the exact commands, provider configuration, task names, duration, exit status, target ID, and artifact paths. The test should assert one harmless managed resource and verify the resulting state on the target. Do not use production module code or real secrets.

The underlying PDK-managed Litmus task sequence is:

```sh
pdk bundle install
pdk bundle exec rake 'litmus:provision[provisioner,platform,inventory_vars]'
pdk bundle exec rake litmus:install_agent
pdk bundle exec rake litmus:install_module
pdk bundle exec rake litmus:acceptance:parallel
pdk bundle exec rake litmus:tear_down
```

Run these only as the dedicated acceptance identity inside the wrapper-controlled boundary, never directly from the normal workstation. The configured Phase 5a fixture uses the `provision.yaml` target list, so the wrapper maps its `provision` action to `pdk bundle exec rake 'litmus:provision_list[phase5a]'`. Its `acceptance` action invokes `pdk bundle exec rake litmus:acceptance:parallel`, and `teardown` invokes `pdk bundle exec rake litmus:tear_down`; a failed acceptance task triggers an automatic teardown attempt. The wrapper exposes the configured workflow, not separate `install_agent` or `install_module` actions.

### D. Reproducibility and boundaries

- [ ] Complete three serial provision/apply/acceptance/teardown runs with the same pins.
- [ ] Repeat one run with a deliberate test failure and verify teardown still completes.
- [ ] Verify there are no leftover containers, networks, volumes, provider processes, or sockets after each run.
- [ ] Verify logs/artifacts contain no credentials, tokens, private keys, or host paths outside the disposable fixture.
- [ ] Verify the normal workstation Compose configuration and Level 0/Level 1 boundaries were not changed.
- [ ] Record timing and resource peaks; do not claim performance targets from a single run.

## Expected outputs

| Check | Expected result |
| --- | --- |
| `unshare -Ur true` | Exit status `0`; no `Operation not permitted`. |
| `run-pdk-litmus.sh info` | Rootless API reports graphroot `/var/lib/agentforge-acceptance/podman-storage-phase5a-reconcile`, runroot `/run/agentforge-acceptance/999/phase5a/containers`, and cgroup v2. |
| UID/GID maps | Container UID/GID 0 maps to `agentforge-acceptance`; subordinate range begins at 165536. |
| Litmus target | The fixture target provisions through the rootless Podman API; no Docker service is used. |
| Litmus provision/apply/test | One target provisions; Puppet apply succeeds; the focused RSpec acceptance test passes; artifacts are collected. |
| Teardown | Target and its run-specific resources are absent after success and induced failure. |
| Repeated runs | Three serial runs pass with identical versions/digests and no unexplained resource or state drift. |
| Security boundary | No Docker daemon/socket, persistent credential, normal workstation mount, GitHub authentication, MCP, or Copilot state is used. |

## Failure diagnostics

| Symptom | Likely area | Safe diagnostic |
| --- | --- | --- |
| `unshare -Ur true` returns `Operation not permitted` | User namespaces blocked by kernel, sysctl, AppArmor, or VM policy | Check `sysctl` values, kernel namespace support, audit/AppArmor denial logs, and whether the command runs as the dedicated non-root user. Do not test by disabling host security globally. |
| `newuidmap` / `newgidmap` fails or maps only one ID | Missing `uidmap`, missing/non-overlapping `/etc/subuid` or `/etc/subgid` entry | Check `command -v newuidmap newgidmap`, exact account entries, overlap, and `podman unshare ..._map`. |
| Podman says `cannot clone`, `cannot setup namespace`, or `permission denied` | Namespace restrictions or rootless identity/mapping setup | Run `unshare` first; inspect sysctls and audit logs. Do not use `sudo podman` as a workaround. |
| Storage fails with overlay mount errors | Kernel OverlayFS support or rootless storage driver | Capture `sudo scripts/acceptance/run-pdk-litmus.sh info`, inspect `fuse-overlayfs` and the configured storage paths, and record any change before retrying. |
| Network target cannot resolve or connect | Missing/incompatible `slirp4netns`, `pasta`, `netavark`, or `aardvark-dns`; egress policy | Record the selected backend and test an isolated disposable target. Do not add broad host networking or privileged mode. |
| Litmus has no provision task/provider or cannot connect | Litmus version/provider mismatch or Podman API incompatibility | Capture `sudo scripts/acceptance/run-pdk-litmus.sh list`, locked gem versions, provider config, and sanitized error. Stop if resolution requires Docker Engine, a privileged daemon, or workstation socket access. |
| Puppet apply or RSpec fails after successful provisioning | Fixture, target image, Puppet Agent, or module compatibility issue | Preserve sanitized task output, target image digest, Agent version, and collected artifacts; classify separately from Podman provisioning. |
| Target remains after teardown or interrupted run | Cleanup/recovery defect | Record target/container/network/volume IDs and remove only the run-specific resources. If cleanup cannot be proven, destroy the disposable VM. |

Never include secrets or authentication output in diagnostics. Redact environment values and token-shaped strings before saving logs.

## Rollback and cleanup

1. Run Litmus teardown even after a test failure, then clean the staged fixture and stop the transient Phase 5a Podman API service:

   ```sh
   sudo scripts/acceptance/run-pdk-litmus.sh teardown
   sudo scripts/acceptance/run-pdk-litmus.sh clean
   sudo scripts/acceptance/run-pdk-litmus.sh stop-provider
   ```

2. The wrapper's `clean` and `stop-provider` actions verify that no containers remain. Preserve the reconciled graphroot and target image; do not remove or migrate the previous graphroot.
3. Use the wrapper to remove only the staged fixture after exporting sanitized reports and version/digest records. Keep the private PDK gem cache unless its cleanup is separately approved.
4. Revert any VM-local sysctl or AppArmor override. Confirm no override was applied to the hypervisor or another shared host.
5. If the VM will not be reused, delete the VM, attached disks, snapshots, and any temporary firewall rules. Do not retain snapshots containing test artifacts.
6. If subordinate ID entries are to be removed from a reused VM, first stop all rootless processes and verify no container storage or processes remain for that account.

## ADR-0006 acceptance gate

ADR-0006 is Accepted.

The validation record demonstrated all of the following:

- Exact Ubuntu, kernel, Podman, Ruby, Bundler, Litmus dependency-lock, target-image, and Puppet Agent versions are recorded.
- Rootless namespace and Podman checks pass without `sudo`, Docker Engine, Docker socket access, or privileged mode.
- Litmus can provision and connect to a disposable rootless Podman target within the dedicated boundary.
- Puppet apply and an RSpec acceptance test pass, and required artifacts are collected without secret values.
- Teardown succeeds after both a passing test and an induced failure; no run resources remain.
- Three serial runs are reproducible with no unexplained drift.
- No Puppet repository credentials, GitHub authentication, MCP servers, persistent Copilot state, or normal workstation sockets/mounts are involved.
- Remaining compatibility limitations, resource use, failure handling, and any Podman API dependency are documented and explicitly accepted.

A failure caused only by a specific test-VM configuration is not proof of Litmus/Podman incompatibility. Conversely, success on this VM does not make rootless Podman a security sandbox or authorize exposing its API to the normal workstation.
