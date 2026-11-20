# Phase 5b VM Provider Compatibility Report

- Date: 2026-11-23
- Protocol: [Phase 5b Compatibility Spike Test Protocol](phase5b-compatibility-spike-test-protocol.md)
- Scope: One Linux target; Vagrant with VirtualBox candidate only
- Result: Blocked before VM provisioning
- Recommendation: **C — Phase 5b is not currently viable on this execution environment**

## Summary

The read-only prerequisite checks found working Vagrant and VirtualBox installations and exposed nested virtualization support. They did not establish the required dedicated controller/worker environment. The current host reports Amazon virtualization, the session environment may be shared, the current user has broad host groups, and no isolated acceptance worker is available. The AgentSmith checkout also has no Gemfile/lockfile to execute the Litmus bundle; although `puppet_litmus` 2.8.2 is installed as a system gem, the protocol's `bundle exec litmus --version` command fails.

Provisioning or executing module/test code on this host would violate the protocol's dedicated-host and controller/worker separation requirements. No VM was created, interrupted, or destroyed. No hypervisor was installed, no cloud API or credential was used, and no AWS resource was provisioned. This result is an environment blocker, not evidence that Vagrant or VirtualBox cannot work.

## Environment evidence

| Item | Observed |
|---|---|
| OS | Ubuntu 24.04.5 LTS |
| Kernel | Linux `7.0.0-1017-aws`, x86_64 |
| Virtualization identity | `systemd-detect-virt` reports `amazon` |
| User context | UID 1000; member of `sudo`, `docker`, `lxd`, and `kvm` groups |
| Vagrant | 2.4.9; `vagrant version` reports current |
| VirtualBox | 7.2.22r175245; kernel modules `vboxdrv`, `vboxnetflt`, and `vboxnetadp` loaded |
| VirtualBox nested support | `VBoxManage list hostinfo` reports hardware virtualization, nested paging, and nested hardware virtualization |
| KVM device | `/dev/kvm` exists and is readable/writable by the current user |
| Ruby / Bundler | Ruby 3.2.3; Bundler 2.4.20 |
| Litmus | System gem `puppet_litmus` 2.8.2 is present; no `litmus` executable or repository Gemfile/lockfile is available |
| Vagrant plugins | None installed; VirtualBox is Vagrant's built-in provider |
| Vagrant state directory | `~/.vagrant.d` exists with mode 0775; this must be tightened/reviewed before controller use |
| Baseline VirtualBox inventory | 0 registered VMs, 0 virtual hard disks, 0 NAT networks |
| Worker | No separate, protocol-compliant acceptance worker was available or verified |

The protocol version command `bundle exec litmus --version` returned:

```text
Could not locate Gemfile or .bundle/ directory
```

The public Vagrant documentation lists VirtualBox 7.2.x as a supported Vagrant provider version. This establishes version-family compatibility only; it does not validate Litmus 2.8.2 provisioning or cleanup on this host.

## Protocol test results

| # | Test | Result | Evidence / reason |
|---:|---|---|---|
| 1 | Version validation | **Partial** | Vagrant 2.4.9, VirtualBox 7.2.22r175245, Ruby 3.2.3, Bundler 2.4.20, and system `puppet_litmus` 2.8.2 were identified. The required bundle-scoped Litmus command failed because there is no project Gemfile or bundle. |
| 2 | VM provisioning | **Not run — blocked** | Host is not established as the dedicated validation host and the required isolated worker is unavailable. No Vagrant operation was run. |
| 3 | SSH lifecycle | **Not run — blocked** | No target or per-run SSH key was created. |
| 4 | Puppet apply | **Not run — blocked** | No target was provisioned. |
| 5 | Acceptance assertion | **Not run — blocked** | No target or Litmus acceptance run was available. |
| 6 | Normal cleanup | **Not applicable / not run** | No VM resources were created. Baseline inventory counts were zero. |
| 7 | Interrupted-run recovery | **Not run — blocked** | There was no safe run to interrupt; no orphan-recovery mechanism was exercised. |
| 8 | Resource reconciliation | **Partial baseline only** | Initial VM, disk, and NAT-network inventory counts were all zero. There was no run journal or created resource set to reconcile. |
| 9 | Security boundary | **Blocked** | No separate worker exists in this execution context. The current user has `sudo` and host virtualization/control groups; controller/worker isolation cannot be demonstrated. |
| 10 | Runtime/resource limits | **Not run — blocked** | No run controller or timeout/resource enforcement was configured. The protocol allows a 2-hour runtime, while ADR-0009 specifies a 60-minute maximum; use of a longer limit requires resolving that inconsistency without weakening ADR-0009. |

## Compatibility, security, cleanup, and operational findings

- **Compatibility:** Host tools and nested-virtualization capability are present. Litmus's bundle-scoped command and end-to-end Vagrant integration are unverified. A system-installed Litmus gem is not a substitute for the protocol's pinned, project-locked bundle.
- **Security:** Do not run acceptance code under the current controller identity. The session is not proven to be a dedicated host, no isolated worker is present, and the current user's host privileges make same-host execution inappropriate. Review and restrict `~/.vagrant.d` before using it as controller state.
- **Cleanup:** Empty baseline inventories do not demonstrate cleanup. VM teardown, disk/network removal, interruption recovery, and journal reconciliation remain untested.
- **Operations:** Vagrant and VirtualBox report usable versions and loaded modules. There is no configured Litmus fixture, isolated worker, run journal, timeout supervisor, or protocol-compliant controller/worker transport.
- **Scope:** No EC2, libvirt/KVM fallback, Windows, BSD, Solaris, multi-target, AWS API, or cloud-credential testing was performed.

## Blockers before retry

1. Provide or designate a dedicated validation host and a separate disposable worker with distinct kernel, identity, network boundary, and no VirtualBox API or controller-file access.
2. Provide a pinned, project-locked Litmus 2.8.2 fixture and demonstrate the exact bundle command before provisioning.
3. Restrict controller configuration and state, including the group-writable Vagrant state directory; use only generated trusted Vagrant configuration and run-scoped SSH keys.
4. Implement or configure the protocol's run journal, resource limits, timeout supervisor, cleanup reaper, and inventory reconciliation.
5. Resolve the protocol's 2-hour limit against ADR-0009's 60-minute maximum before executing the runtime-limit test.

Until these prerequisites exist, repeating the VM lifecycle tests on this host would be unsafe and would not produce valid Phase 5b evidence.

## References

- [Vagrant VirtualBox provider documentation](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox)
- [Litmus concepts and provisioning model](https://puppetlabs.github.io/litmus/litmus-concepts.html)
- [ADR-0009: External VM Acceptance Testing Strategy](adr/0009-external-vm-acceptance-testing-strategy.md)
