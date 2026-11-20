# Phase 5b Litmus Integration Spike Report

- Date: 2026-11-23
- Scope: Litmus 2.8.2 with Vagrant/libvirt against one Ubuntu 22.04 target
- Result: **Blocked before VM provisioning**
- Recommendation: **B — Additional Litmus work required**

> **Historical initial attempt:** This spike stopped before provisioning because dependencies, a compatible box, storage headroom, and an isolated worker were unavailable. The later Litmus provisioning and integration-hardening work succeeded for the requested single-target workflow; see the [Phase 5b Litmus provisioning report](phase5b-litmus-provisioning-report.md). This report records the earlier blocker and is not the current Phase 5b validation status. Production hardening remains incomplete.

## Summary

The current host has the selected Vagrant/libvirt stack and operational libvirt access. However, the locked Litmus fixture dependencies are not installed, no libvirt-compatible Vagrant box is cached, and only 2.1 GB of root filesystem space is available. The required isolated acceptance worker is also not established. Provisioning a VM or executing acceptance code on this host would therefore risk exhausting host storage and would not demonstrate ADR-0009's controller/worker separation.

This is an incomplete integration spike, not evidence that Litmus 2.8.2 is incompatible with Vagrant/libvirt. The previously reported successful Vagrant/libvirt VM lifecycle validation is treated as supplied context; it was not repeated for this Litmus spike.

## Environment evidence

| Item | Observed |
|---|---|
| OS | Ubuntu 24.04.5 LTS |
| Vagrant | 2.4.9 |
| Vagrant provider | `vagrant-libvirt` 0.12.2, globally installed |
| Libvirt/QEMU | libvirt 10.0.0; QEMU 8.2.2 |
| Libvirt access | `virsh -c qemu:///system` succeeds as `ubuntu`; `default` network is active |
| Baseline libvirt inventory | No domains and no storage pools listed; default network is active |
| Litmus pin | Fixture `Gemfile.lock` pins `puppet_litmus` 2.8.2 and Bundler 2.4.20 |
| Fixture dependencies | `bundle check` reports the locked dependencies missing; `bundle exec litmus --version` fails because the Litmus executable is unavailable in the bundle |
| Vagrant boxes | Cached boxes are `centos/7` and `generic/ubuntu1804`, both for VirtualBox; no libvirt box is cached |
| Available storage | Root filesystem 29 GB total, 2.1 GB free (93% used) |
| Execution identity | `ubuntu`; member of `sudo`, `docker`, `libvirt`, and `kvm`, among other groups |
| Isolated worker | No separate acceptance worker was established for this run |

## Requested checks

| Check | Result | Finding |
|---|---|---|
| Litmus provisioning against Vagrant/libvirt | **Not run — blocked** | Locked bundle dependencies are missing, and no libvirt-compatible target box is cached. |
| Litmus inventory generation | **Not run — blocked** | Litmus cannot run from the locked bundle, so no inventory was generated. |
| Litmus connection / SSH | **Not run — blocked** | No target was provisioned and no run-scoped SSH material was created. |
| Puppet installation | **Not run — blocked** | No target exists to inspect or configure. |
| Minimal Puppet apply | **Not run — blocked** | Acceptance execution was not started. |
| Acceptance assertion | **Not run — blocked** | Acceptance execution was not started. |
| Cleanup workflow | **Not applicable** | No resources were created. Baseline libvirt domain and storage-pool inventories were empty. |
| Runtime | **Not measured** | No VM lifecycle or Litmus run occurred. |

## Compatibility findings

- The selected provider components are installed, and libvirt is reachable from the current user. This confirms host-level prerequisites, not Litmus integration.
- `puppet_litmus` 2.8.2 is pinned in the existing fixture lockfile, but the fixture's dependencies are not installed. The bundle-scoped Litmus and Rake commands cannot execute.
- An Ubuntu 22.04 box compatible with the libvirt provider must be acquired or otherwise supplied before provisioning. The currently cached boxes are VirtualBox-specific.
- No conclusions can yet be drawn about Litmus inventory generation, Vagrant/libvirt provisioning behavior, target SSH, Puppet installation/apply, assertion execution, or Litmus cleanup.

## Operational and security findings

- At 2.1 GB free, the host lacks safe headroom for installing the full locked bundle and acquiring/storing a VM box and its disk. The spike stopped rather than risk filling the host filesystem.
- The current account has broad host access, including `sudo`, `docker`, `libvirt`, and `kvm`. No separate worker boundary was demonstrated. Running acceptance code under this identity would not satisfy ADR-0009's controller/worker isolation requirements.
- No cloud provider, AWS API, or cloud credentials were used. No VM, SSH key, or Litmus-generated target inventory was created.

## Cleanup findings

No cleanup workflow was exercised because provisioning did not begin. The pre-run libvirt domain and storage-pool lists were empty, while the default network was active. This baseline does not demonstrate teardown, interruption recovery, or inventory reconciliation.

## Blockers before retry

1. Establish the ADR-0009 controller/worker separation, ensuring acceptance code cannot access the controller's libvirt API or controller files.
2. Provide enough free disk for the locked bundle, one Ubuntu 22.04 libvirt box, and the disposable VM, with operational headroom.
3. Install or provide the existing fixture's locked bundle in an isolated bundle path without changing its dependency lock.
4. Select and pin a compatible Ubuntu 22.04 libvirt box.
5. Execute the single-target Litmus provision, inventory, SSH, minimal Puppet apply/assertion, and teardown workflow, recording resource inventories before and after.

## Recommendation

**B — Additional Litmus work required.** The Vagrant/libvirt host integration is operational, but the requested end-to-end Litmus workflow has not been demonstrated. Do not proceed to Phase 5b implementation on the basis of this blocked spike.
