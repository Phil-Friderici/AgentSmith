# Phase 5a Validation Report

## Status

**The final Phase 5a validation gates passed.** Four successful serial Litmus runs each provisioned a target, applied a harmless Puppet file resource, passed the acceptance assertion, and tore down successfully. A controlled assertion failure was detected and its target was removed by the cleanup trap; run-scoped socket, storage, and staged fixture were then removed. A fresh subsequent successful run also passed.

ADR-0006 is Accepted. The successful completion of the Phase 5a validation program provided the evidence required for acceptance of the acceptance-testing platform strategy.

Validation was performed on Ubuntu 24.04 with Podman 4.9.3, systemd 255, cgroup v2, Ruby 3.2.3, and `puppet_litmus` 2.8.2.

## Implementation and preflight

`scripts/acceptance/podman-api-service.sh` now starts a transient systemd service for UID/GID 999 with `Delegate=yes`, a private runtime directory, explicit rootless storage/runroot paths, and a Unix-only Podman API socket. The service and socket were owned by the acceptance identity; the runtime directory was mode `0700`, the socket mode `0600`, and the API ping succeeded. The service had no TCP listener, and the calling operator could not access the private runtime directory.

The delegated cgroup probe passed: the acceptance identity owned its service cgroup and created and removed a child cgroup. `podman info` reported rootless operation, cgroup v2, the `cgroupfs` manager, and `/usr/bin/runc`. `podman unshare` showed UID/GID 0 mapped to host UID/GID 999/987 and the subordinate range beginning at 165536. The provider configuration now sets a finite PIDs ceiling of 1024; this avoids the observed zero-limit behavior without removing resource limits.

Litmus 2.8.2 and its locked Ruby dependencies installed in the acceptance identity's private bundle. The credential-free target image built successfully from digest-pinned Ruby bases. No GitHub CLI authentication, MCP server, Puppet repository credential, Docker socket, or Docker daemon was used.

## Provisioner and effective canary configuration

The fixture selects Litmus 2.8.2's `docker_exp` provisioner. It invokes the Docker CLI against the run-scoped Podman Unix socket; it does not use SSH. The effective canary command was:

```text
docker run -d -it --privileged --privileged=false --cap-drop=ALL --security-opt=no-new-privileges --network=none --pids-limit=1024 --cgroupns=private --cgroup-parent=/system.slice/agentforge-acceptance-phase5a-podman.service/agentforge-containers --volume /sys/fs/cgroup:/sys/fs/cgroup:ro localhost/agentforge-phase5a:validation
```

Podman inspection showed the configured `HostConfig.CgroupParent` and `HostConfig.PidsLimit=1024`; the canary reached `Running` below the delegated service subtree. Its leaf cgroup reported `pids.max=1024` (with `pids.current=3` during inspection). The provider prepended `--privileged`; the final `--privileged=false` was reflected in the created container configuration. `CapAdd` was empty, all available capabilities were dropped, devices and port bindings were empty, networking was disabled, and `/sys/fs/cgroup` was mounted read-only. The host and target cgroup namespace inode values differed, confirming a private cgroup namespace.

The canary's TTY shell started, a child `sleep` process was forked and waited for, and `puppet --version` returned `8.10.0`. `sshd` was absent and the root password field was locked. The host UID/GID mapping showed container root mapped to UID/GID 999/987. No Puppet repository credentials, Copilot authentication, or GitHub authentication were mounted or passed into the target.

An initial `docker build` attempt selected Docker Buildx's `docker-container` driver and failed while starting its BuildKit helper outside the delegated subtree (`mkdir /sys/fs/cgroup/docker: permission denied`). No such host cgroup was created. The unstarted helper and its volume were removed; the target image was then built successfully with the rootless Podman Buildah path. No Docker daemon or Docker socket was used.

## End-to-end Litmus results

The locked fixture bundle used `puppet_litmus` 2.8.2, and the target image contained Puppet 8.10.0. Four successful runs completed:

| Run | Provision | Puppet apply and assertion | Result collection | Teardown |
| --- | --- | --- | --- | --- |
| 1 | Target `aa16040c1964` reached `Running` with `pids.max=1024`. | One RSpec example; `1 example, 0 failures`. The manifest created `/tmp/agentforge-phase5a-marker`, and the assertion read its expected content. | Litmus reported success on one node and connectivity passed. | `litmus:tear_down` succeeded; no container remained. |
| 2 | Target `5a960cab5bf3` reached `Running` with `pids.max=1024`. | One RSpec example; `1 example, 0 failures`. The same Puppet apply and content assertion passed. | Litmus reported success on one node and connectivity passed. | `litmus:tear_down` succeeded; no container remained. |
| 3 | Target `226ca7868e49` reached `Running` with `pids.max=1024`. | One RSpec example; `1 example, 0 failures`. The Puppet apply and content assertion passed. | Litmus reported success on one node and connectivity passed. | `litmus:tear_down` succeeded; no container remained. |
| 4, after failure cleanup | Fresh target `f5c2ddd5a533` reached `Running` with `pids.max=1024`. | One RSpec example; `1 example, 0 failures`. The Puppet apply and content assertion passed after the prior run's service and storage had been removed and recreated. | Litmus reported success on one node and connectivity passed. | `litmus:tear_down` succeeded; final cleanup removed the service, socket, and storage. |

The controlled-failure run provisioned target `c0848a01402f` with the same PIDs and security settings. Only the staged copy of the expected marker text was changed. Puppet apply succeeded, then RSpec reported the deliberate mismatch (`1 example, 1 failure`; expected `Deliberate failure sentinel`, actual `AgentForge Phase 5a`) and exited nonzero. An EXIT trap ran `litmus:tear_down`, which succeeded. After teardown, the container and volume lists were empty, only Podman's default private-storage bridge network remained, and no target cgroup directory remained. The owner-restricted socket was still responsive until explicitly stopped; stopping the service removed its socket/runtime directory. The private Podman storage was removed before starting the subsequent fresh success run.

All success and failure output was collected in the private run directory and removed after the final report was updated.

## Cgroup and PIDs findings

The initial short relative parent, `agentforge-containers`, resolved to a sibling under `system.slice`. Replacing it with the absolute parent succeeded. The running canary's host cgroup was:

```text
/system.slice/agentforge-acceptance-phase5a-podman.service/agentforge-containers/libpod-3b5b05433a7a2069b2c701815953ea1ad433a2deaf794863e0810cbc9fa0da8d
```

The delegated unit cgroup was `/sys/fs/cgroup/system.slice/agentforge-acceptance-phase5a-podman.service`, owned by `999:987`. Its only direct child directory was `agentforge-containers`; `/sys/fs/cgroup/system.slice/agentforge-containers` did not exist. The host cgroup namespace inode differed from the canary's, confirming a private cgroup namespace.

The `Delegate=yes` probe and canary placement confirm that this cgroupfs/Docker-compatible API path can use the delegated subtree when given the absolute parent. Earlier attempts logged that Podman could not move a `slirp4netns` process to `systemd user.slice` because it could not determine the session-bus address; that message was not rechecked during this successful canary. The canary reached `Running` with `network=none`.

With the earlier implicit `PidsLimit=0`, the OCI config carried a zero limit while the runtime produced `pids.max=1`. The fixture now supplies a positive finite limit. The canary and all Litmus targets reported `HostConfig.PidsLimit=1024` and `pids.max=1024`; shell child-process creation, Puppet startup, and all four acceptance runs passed. No limit was removed. The value is validated for this synthetic workload; other modules may need a separately justified finite value.

Recent kernel audit output contained no AppArmor denial corresponding to the earlier failures. No privileged container, Docker daemon access, or broader host permission was needed for the current canary or Litmus runs.

## Cleanup

Litmus teardown succeeded after every successful and failing run. Following the controlled failure, no container, volume, run-specific network, or target cgroup remained; the default bridge was confined to private storage. The socket was owner-only and Unix-only while active, then stopping the transient service removed its socket and runtime directory. The run-scoped Podman storage was removed before the subsequent fresh success, and final cleanup removed the new storage, staged fixture, target image, and collected logs. The existing private Bundler cache was retained for reuse. No Phase 5a target or acceptance process remains.

## Security assessment

- **Rootless boundary:** Passed; the running container process was host UID 999 with the configured UID/GID mappings.
- **Socket boundary:** Passed; owner-restricted Unix socket, no TCP listener, and no access through the private runtime directory by the invoking operator.
- **Identity exclusivity:** Passed; UID 999 had no other processes before startup or after final cleanup.
- **Docker access:** Passed; no Docker daemon/socket was used.
- **Container privilege and mounts:** Passed inspection: `Privileged=false`, no added capabilities/devices/ports, private cgroup namespace, no-new-privileges, and only the explicitly requested read-only host cgroup mount. `sshd` was absent and the root password was locked.
- **Resource limits:** Passed; `HostConfig.PidsLimit=1024` and the target cgroup's `pids.max=1024`. No resource limit was removed.
- **Secrets and authentication:** The fixture/build context did not include Puppet repository credentials or Copilot state. The running target had no secret or authentication mounts or environment values.
- **Acceptance execution and repeatability:** Four serial successful Puppet apply/assertion runs passed. The deliberately failing assertion was reported as a failure and the EXIT trap completed teardown; a fresh run passed afterward.

## Remediation and decision

Use `/system.slice/agentforge-acceptance-phase5a-podman.service/agentforge-containers` as the validated parent and `--pids-limit=1024` as the current finite ceiling. This value passed the canary, four successful Litmus runs, and a controlled failure-cleanup run while preserving the container security settings. Do not remove the cap or use privileged mode, a host Docker daemon/socket, linger, or broader cgroup access as workarounds.

**Recommendation:** Phase 5a meets the final validation gates exercised here and can be considered complete for the synthetic Ubuntu target. Recommend marking ADR-0006 Accepted after replacing its stale validation findings and blocker with the results above. This does not claim support for every Puppet module, target OS, or resource profile.

## Recommended ADR-0006 updates (not applied)

1. Change the header from `Status: Proposed` to `Status: Accepted`.
2. In the Phase 5a decision, identify Litmus 2.8.2's `docker_exp` provisioner, not the classic `docker` provisioner. Record the tested Podman package pin (`4.9.3+ds1-1ubuntu0.2`), rootless Unix API socket, absolute delegated cgroup parent, and finite `--pids-limit=1024`.
3. Replace the three Phase 5a open questions with these resolved statements:
   - Litmus is pinned to `puppet_litmus` 2.8.2 for this implementation.
   - Podman is pinned to `4.9.3+ds1-1ubuntu0.2` for this validation baseline.
   - `docker_exp` requires a Docker-compatible API endpoint; Phase 5a provides it only through the run-scoped, owner-restricted rootless Podman Unix socket.
4. Replace the stale `Current Validation Findings` and `Current blocker` text with:

   > Validation performed on 2026-11-20 established:
   >
   > - Rootless Podman, user-namespace mappings, and delegated cgroup placement are functional for the dedicated acceptance identity.
   > - Litmus 2.8.2 with `docker_exp` provisions disposable targets through a rootless, owner-restricted Unix socket; no Docker daemon or Docker socket is used.
   > - The tested target uses a finite `--pids-limit=1024`; `HostConfig.PidsLimit` and the target cgroup's `pids.max` both report 1024. Shell forking and Puppet 8.10.0 startup succeed.
   > - Four serial synthetic Puppet apply/assertion runs passed. A controlled assertion failure was detected, the EXIT-trap teardown succeeded, and a fresh subsequent run passed.
   > - Containers, volumes, target cgroups, the run-scoped socket, and private Podman storage were absent after cleanup.
   > - Security gates passed: `Privileged=false`, no added capabilities/devices/ports, private cgroup namespace, `network=none`, read-only cgroup mount, no SSH or root password, and no Puppet repository, Copilot, or GitHub credentials in targets.
   >
   > These results validate the synthetic Ubuntu target and do not claim compatibility with every module, target OS, or workload. Phase 5b remains separate.

Keep the Phase 5b open questions open; this validation does not resolve them.
