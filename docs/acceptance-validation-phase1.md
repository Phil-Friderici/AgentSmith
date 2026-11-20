# Acceptance Testing Validation Phase 1

## Status and purpose

This document records the dedicated-environment requirements for the Litmus/rootless Podman compatibility validation specified by Accepted [ADR-0006](adr/0006-acceptance-testing-platform.md). The earlier `unshare -Ur true` failure (`Operation not permitted`) describes the previous host only; it is not evidence that Litmus and Podman are incompatible.

This phase provisions and validates a disposable VM and runs a bounded compatibility fixture. It does not enable acceptance testing in the normal AgentForge workstation, install an acceptance provider there, or change ADR-0004, ADR-0005, or the accepted decision in ADR-0006.

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
| Podman | `4.9.3+ds1-1ubuntu0.2` from the locally available Ubuntu Noble APT metadata | Candidate exact package pin. Confirm availability with `apt-cache policy podman`; stop rather than silently substitute a version if unavailable. |
| Litmus | `puppet_litmus` gem `1.0.0` as the initial compatibility candidate | Candidate only; not an AgentForge-supported pin. Resolve and commit a `Gemfile.lock` in the disposable fixture before the run. If it is unavailable or incompatible with Ruby 3.2.3, select another exact release, record why, and use that lockfile for every repeat. |
| Ruby / Bundler | Ruby `3.2.3`, Bundler `2.4.20` | Matches the current AgentForge workstation toolchain; record the actual versions. |
| Puppet Agent | Exact version required by the synthetic fixture, preinstalled in the pinned target image | Record the target image digest and Agent version. Do not fetch protected packages from a target at runtime. |

The Podman package candidate above was observed in the local Ubuntu Noble package metadata during preparation; it has not been installed or validated on a VM. The Litmus candidate is a starting point for the experiment, not a claim that it is the latest release. Pin every resolved Ruby dependency and target image by exact version/digest in the validation record.

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

Use a dedicated unprivileged account, for example `agentforge-validate`. It must not be UID 0 and must not have `sudo` access during test execution. Allocate non-overlapping subordinate ID ranges in `/etc/subuid` and `/etc/subgid`; the example below uses 65,536 IDs and is illustrative only:

```text
agentforge-validate:100000:65536
```

Choose ranges that do not overlap any existing mapping. Verify both files and the resulting maps before starting Podman. Rootless image storage must remain under this account's private home; do not share its home, storage, or runtime directory with the workstation.

## Provisioning guide

1. Create a clean Ubuntu Server 24.04 LTS VM with the resources above. Disable shared folders, host-home mounts, clipboard/file sharing, and nested virtualization unless separately required. Do not attach the normal workstation's Docker or Podman socket.
2. Create the dedicated validation account and assign non-overlapping subordinate UID/GID ranges. Configure only the namespace sysctls required by the kernel on this VM.
3. Install Podman and rootless dependencies. Confirm the exact package version before proceeding:

   ```sh
   sudo apt-get update
   apt-cache policy podman
   sudo apt-get install -y \
     podman=4.9.3+ds1-1ubuntu0.2 \
     uidmap slirp4netns fuse-overlayfs netavark aardvark-dns crun \
     ruby3.2 ruby3.2-dev build-essential \
     git curl ca-certificates jq
   ```

   If the exact Podman version is no longer available, stop and update this validation record with the proposed replacement; do not allow APT to silently select another version. Do not install Docker Engine, Docker CLI, `docker.io`, or a Docker socket.
4. Install Bundler `2.4.20` for the validation account. Keep gems and caches in that account's private home or a disposable VM-local path. Do not put credentials in the fixture, environment, logs, or cache.

   ```sh
   gem install --user-install bundler --version 2.4.20 --no-document
   export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
   bundle _2.4.20_ --version
   ```

5. Create a disposable fixture outside the AgentForge source checkout. Generate a minimal Puppet module, add `puppet_litmus` at the candidate exact version, resolve dependencies, and retain the generated `Gemfile.lock` with the run record. Do not add the fixture or its lockfile to this repository as an implementation change.
6. Prepare one pinned, disposable Linux target image that already contains the exact Puppet Agent version required by the fixture. The image must not require protected Puppet repository credentials at startup. Record the full image digest.
7. Allow egress only as needed for Ubuntu packages, RubyGems, and the selected OCI registry. No GitHub CLI login, GitHub token, MCP server, Copilot authentication, Puppet repository credential, or unrelated provider credential is needed for this local compatibility test.
8. Record the VM image, kernel, Podman, Ruby, Bundler, Litmus lockfile, target-image digest, and sysctl state before testing.

If the selected Litmus provider requires the Podman Docker-compatible API, start the **rootless per-user Unix socket only inside this dedicated VM**, for the duration of a run:

```sh
systemctl --user start podman.socket
test -S "$XDG_RUNTIME_DIR/podman/podman.sock"
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
```

`DOCKER_HOST` must point only to this Podman socket; it must not be used to configure or reach Docker Engine. Do not bind the socket to TCP, forward it to the host, mount it into an AgentForge workstation, or enable a persistent/lingering service. Stop the socket after the run. If the provider cannot use the local rootless socket without Docker Engine or a privileged daemon, record the blocker and stop; do not weaken the boundary.

## Validation checklist

### A. Host prerequisites

- [ ] Confirm the validation account is unprivileged and not in a Docker-admin group.
- [ ] Confirm Podman package version equals the recorded pin.
- [ ] Confirm subordinate UID and GID ranges are present and non-overlapping.
- [ ] Confirm cgroup v2 and the required namespace policy.
- [ ] Confirm no Docker Engine, Docker socket, GitHub CLI authentication, MCP service, Puppet repository credential, or Copilot state is present.
- [ ] Record all installed component versions and target image digest.

### B. Rootless Podman

Run as `agentforge-validate`, never through `sudo`:

```sh
unshare -Ur true
podman info --format '{{.Host.Security.Rootless}}'
podman info --debug
podman unshare cat /proc/self/uid_map
podman unshare cat /proc/self/gid_map
podman run --rm --pull=never --network=none "$PINNED_TEST_IMAGE" id
podman ps -a
```

Pull the already selected digest-pinned test image before the `--pull=never` run. Confirm that Podman reports rootless mode, the UID/GID maps include the account and its subordinate range, and the container runs without root privileges on the host. Record the storage driver and rootless network backend. Confirm no target remains after `--rm`.

If Litmus needs the Podman API, start the user socket on demand and verify its path is under `$XDG_RUNTIME_DIR/podman/`. Stop it after the Litmus run. Never use a TCP listener.

### C. Litmus lifecycle

Use only the disposable fixture and the locked dependency set. First list the tasks provided by the pinned release:

```sh
export BUNDLE_PATH="$HOME/.cache/agentforge-litmus"
bundle check
bundle exec rake -T litmus
```

The fixture must expose the equivalent of these lifecycle operations; exact task names are release-defined and must be taken from `rake -T litmus` rather than assumed:

1. Provision one target using rootless Podman.
2. Install/use the pinned Puppet Agent in that target.
3. Install the fixture module and apply its minimal manifest.
4. Run its RSpec acceptance example.
5. Collect the test report and relevant target output.
6. Tear down the target, including after a deliberately induced test failure.

Record the exact commands, provider configuration, task names, duration, exit status, target ID, and artifact paths. The test should assert one harmless managed resource and verify the resulting state on the target. Do not use production module code or real secrets.

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
| `podman info --format '{{.Host.Security.Rootless}}'` | `true`. |
| `podman info --debug` | Rootless store under the validation account's home; supported storage and network backends; cgroup v2/systemd reported. |
| UID/GID maps | Container UID/GID 0 maps to the unprivileged validation account; additional range maps from the allocated subordinate IDs. |
| Pinned test container | Starts and exits successfully; host process remains owned by the validation account; no Docker service is used. |
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
| Storage fails with overlay mount errors | Kernel OverlayFS support or rootless storage driver | Check `podman info --debug`, `fuse-overlayfs`, and the account's private storage permissions. Retry with the supported rootless fallback only after recording the change. |
| Network target cannot resolve or connect | Missing/incompatible `slirp4netns`, `pasta`, `netavark`, or `aardvark-dns`; egress policy | Record the selected backend and test an isolated disposable target. Do not add broad host networking or privileged mode. |
| Litmus has no provision task/provider or cannot connect | Litmus version/provider mismatch or Podman API incompatibility | Capture `bundle exec rake -T litmus`, locked gem versions, provider config, and sanitized error. Stop if resolution requires Docker Engine, a privileged daemon, or workstation socket access. |
| Puppet apply or RSpec fails after successful provisioning | Fixture, target image, Puppet Agent, or module compatibility issue | Preserve sanitized task output, target image digest, Agent version, and collected artifacts; classify separately from Podman provisioning. |
| Target remains after teardown or interrupted run | Cleanup/recovery defect | Record target/container/network/volume IDs and remove only the run-specific resources. If cleanup cannot be proven, destroy the disposable VM. |

Never include secrets or authentication output in diagnostics. Redact environment values and token-shaped strings before saving logs.

## Rollback and cleanup

1. Stop Litmus, acceptance-test, and Podman API processes. Stop the rootless socket if it was started:

   ```sh
   if systemctl --user is-active --quiet podman.socket; then
     systemctl --user stop podman.socket
   fi
   ```

2. Remove only resources labeled or named for this validation run. Verify `podman ps -a`, `podman network ls`, and `podman volume ls` show no run resources. If their ownership is unclear, do not delete unrelated resources; destroy the dedicated VM instead.
3. Remove the disposable fixture and its temporary gem cache after exporting sanitized reports and version/digest records.
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
