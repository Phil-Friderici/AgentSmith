# Phase 5 Litmus/Rootless Podman Compatibility Spike

## Result

**Blocked before implementation; compatibility is not established.** This environment does not have Podman or Litmus installed, and the kernel rejects creation of an unprivileged user namespace (`unshare -Ur true` returns `Operation not permitted`). Rootless Podman cannot be exercised reliably here. No packages were installed, no socket was enabled or accessed, no Docker daemon was used, and no acceptance target or credential was created.

This report is experimental evidence only. It does not modify or approve the architecture, change ADR-0004/ADR-0005, select provider versions, or enable an acceptance profile.

## Environment observations

| Check | Observation |
| --- | --- |
| OS | Ubuntu 24.04 |
| Podman | Not installed |
| Litmus gem | Not installed |
| Rootless helpers | `newuidmap`, `newgidmap`, `slirp4netns`, `fuse-overlayfs`, and `crun` are absent |
| Subordinate IDs | `ubuntu` has `100000:65536` entries in both `/etc/subuid` and `/etc/subgid` |
| User namespaces | `unshare -Ur true` fails with `write failed /proc/self/uid_map: Operation not permitted` |
| User Podman socket | `systemctl --user is-active podman.socket` reports `inactive`; no Podman socket was found under `/run/user/1000` |
| Cgroups | cgroup v2 |
| Test execution | Not run: rootless Podman cannot start, and Litmus is absent |
| Performance | Not measured |

The package index lists these Ubuntu 24.04 candidates; none were installed:

| Package | Candidate |
| --- | --- |
| `podman` | `4.9.3+ds1-1ubuntu0.2` |
| `uidmap` | `1:4.13+dfsg1-4ubuntu3.2` |
| `slirp4netns` | `1.2.1-1build2` |
| `fuse-overlayfs` | `1.13-1` |
| `crun` | `1.14.1-1` |

These are environment observations, not recommended AgentForge pins. The compatible Litmus, Puppet Agent, target OS, and provider versions remain unselected.

## Commands used

The following checks were read-only and did not connect to either daemon:

```sh
id
. /etc/os-release && printf '%s %s\n' "$NAME" "$VERSION_ID"
for tool in podman litmus bundle ruby pdk docker; do command -v "$tool" || true; done
podman info --format '{{.Host.Security.Rootless}} {{.Host.OCIRuntime.Name}} {{.Store.GraphRoot}}'
systemctl --user is-active podman.socket
for helper in newuidmap newgidmap slirp4netns pasta fuse-overlayfs crun runc; do command -v "$helper" || true; done
grep -E '^ubuntu:' /etc/subuid /etc/subgid
cat /proc/sys/user/max_user_namespaces
unshare -Ur true
apt-cache policy podman slirp4netns uidmap fuse-overlayfs crun
gem list --local | grep -Ei 'litmus|beaker|puppetlabs_spec_helper|rspec' || true
find "/run/user/$(id -u)" -maxdepth 2 -type s -iname '*podman*' -o -iname '*docker*'
```

`podman info` could not run because Podman is not installed. The Litmus provisioning, Puppet apply, RSpec acceptance, artifact collection, teardown, and multi-run reproducibility checks were not run.

## Requirements for a valid rerun

Run the spike only on a disposable Ubuntu 24.04 host or VM that permits unprivileged user namespaces. Do not weaken the current host's security policy to make this environment pass.

The rootless account needs:

- Podman plus `uidmap`, rootless networking (`slirp4netns` or an explicitly approved alternative), a rootless storage driver (`fuse-overlayfs` or a verified native configuration), and a compatible OCI runtime such as `crun`.
- Valid `/etc/subuid` and `/etc/subgid` ranges and functioning `newuidmap`/`newgidmap`.
- Kernel permission for unprivileged user namespaces and cgroup v2 resource controls.
- Ruby/Bundler and an exact Litmus/provider dependency lockfile, along with a disposable Puppet module fixture and a pinned Puppet Agent target image.
- No `sudo`, Docker group, Docker socket, Podman socket, `/dev/kvm`, host home mount, Copilot state, GitHub credentials, or Puppet repository credentials at runtime.

Before provisioning, verify rootless operation without starting the Podman API service:

```sh
: "${PINNED_PROBE_IMAGE:?Set this to a preloaded image pinned by digest}"
podman info --format '{{.Host.Security.Rootless}}'
podman run --pull=never --rm "$PINNED_PROBE_IMAGE" id
podman ps -a
```

The first output must be `true`; the probe container must exit successfully and leave no containers. These commands do not establish Litmus compatibility. A Litmus provisioning command must not be selected until the exact Litmus/provider version is pinned and shown to create targets through the Podman CLI or another explicitly permitted interface without enabling a Podman socket.

The actual end-to-end rerun must preserve command output and timings for:

1. Locked Litmus installation.
2. Rootless Podman preflight and target creation.
3. Litmus target provisioning and module installation.
4. Puppet apply against the disposable target.
5. A minimal RSpec acceptance example.
6. Collection of test reports/artifacts with no credentials or Copilot state.
7. Teardown after success and after an induced failure.
8. At least two consecutive runs proving identical target selection and cleanup.

The target image must already contain the exact Puppet Agent version. If protected package access is necessary, build that image with a separately approved BuildKit-secret process following ADR-0004; never pass the package credential to a running target or test process.

## Compatibility, performance, and security findings

- **Compatibility:** Undetermined. No Litmus or Podman binaries were available, so no claim can be made about direct Podman CLI provisioning, Docker-API compatibility, systemd/service behavior, SSH transport, or Forge module compatibility.
- **Performance:** Not measured. Package installation and the blocked namespace probe provide no meaningful provisioning or test timing.
- **Security:** The required namespace operation is denied by this host. Installing packages alone would not fix that restriction. Do not fall back to rootful Podman, `sudo`, `--privileged`, Docker socket access, Podman socket access, or host mounts.
- **No credential exposure:** No GitHub, Copilot, cloud, or Puppet package credential was supplied or used. No persistent authentication was added.
- **Architecture impact:** None. No container, Compose, toolchain, permission, or secret configuration was changed.

## Alternatives and trade-offs

| Alternative | Benefit | Cost or limitation |
| --- | --- | --- |
| Rerun on a dedicated VM/host that permits rootless user namespaces | Tests the proposed local rootless path without weakening the current environment. | Requires a suitable disposable runner and still needs proof that the selected Litmus provider can work without a Podman socket. |
| Pre-provision disposable targets with a trusted host-side Podman CLI, then let Litmus connect over SSH | The test runner need not control a Podman API socket; provisioning authority can remain outside the test process. | Requires a supported Litmus workflow for existing targets, one-run SSH material, artifact transfer, and a separate orchestrator; this path is not yet validated. |
| EC2-backed disposable targets | No local container daemon; stronger separation from the workstation and better full-system fidelity. | Cloud account/IAM setup, short-lived per-run credentials, network latency, cost, image maintenance, and reliable cleanup are required. |
| Litmus with Docker targets inside a disposable QEMU test VM | Can validate Litmus acceptance behavior without access to the host Docker daemon. | Does not validate rootless Podman and uses a Docker daemon inside the guest, so it does not meet this spike's success criterion. |
| Dedicated rootless Docker provider | May offer the broadest existing Litmus provider compatibility. | Still introduces daemon API authority and is outside the current no-Docker-daemon requirement; requires a separate explicit security decision. |
| Beaker against disposable remote VMs | May preserve compatibility with a module that already has Beaker tests. | Legacy harness/provider complexity; does not establish Litmus/Podman compatibility. |

## Conclusion

The required end-to-end success criterion cannot be tested in this environment. Stop here rather than install packages that cannot overcome the user-namespace restriction or substitute a Docker-based result for a Podman result. The next valid action is to rerun this isolated spike on a disposable host/VM with rootless user namespaces enabled, then reassess Litmus provisioning without enabling either daemon socket.
