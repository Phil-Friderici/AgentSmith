# Phase 5b Litmus Provisioning Spike Report

- Date: 2026-11-23
- Scope: Litmus 2.8.2, Vagrant 2.4.9, `vagrant-libvirt` 0.12.2, one Ubuntu 22.04 VM
- Initial result: **Provisioning and connectivity demonstrated with workarounds; default teardown reports failure after resource removal**
- Initial recommendation: **B — Additional Litmus integration work required**

> **Current status:** The integration hardening follow-up below passed the Litmus provision/connectivity/teardown and post-provision failure-cleanup checks. Recommendation A applies to this integration path; it does not complete the broader ADR-0009 Phase 5b controls.

## Summary

Litmus 2.8.2's `vagrant` provisioner created one Ubuntu 22.04 target on libvirt. The target booted and Litmus generated a Bolt inventory entry. Litmus connectivity passed after correcting the generated inventory's SSH key path.

The workflow did not succeed unmodified:

- Vagrant initially inherited Bundler environment variables from `bundle exec` and attempted to resolve the Litmus bundle with Vagrant's embedded Ruby. A temporary wrapper stripped Bundler variables for the Vagrant subprocess.
- The pinned fixture bundle lacked Net::SSH's optional `ed25519` and `bcrypt_pbkdf` gems. Adding locked versions to the temporary fixture allowed provisioning and the provisioner's initial SSH configuration to complete.
- The generated inventory selected the Ed25519 key, which the target did not accept; the RSA key listed by Vagrant did work. Updating the temporary inventory to use that key made `litmus:check_connectivity` pass.
- `litmus:tear_down` destroyed the VM and removed its Vagrant run directory, but then failed while updating the inventory because the provision task calls `inventory.remote(node)` and the available `InventoryHelper` provides `remove(node)`, not `remote(node)`. The inventory therefore remained stale, and the Litmus teardown task exited nonzero.

This demonstrates that Litmus can provision and connect to a Vagrant/libvirt target, but it does not demonstrate a clean, unmodified Litmus lifecycle. It is not evidence that the providers are incompatible.

## Environment and target evidence

| Item | Result |
|---|---|
| Host | Ubuntu 24.04.5; KVM and system libvirt accessible |
| Vagrant stack | Vagrant 2.4.9; `vagrant-libvirt` 0.12.2 |
| Litmus | `puppet_litmus` 2.8.2; fixture dependencies installed in the user cache |
| Target box | Cached `generic/ubuntu2204` libvirt box, version 4.3.12 |
| Provider selection | `VAGRANT_PROVIDER=libvirt` |
| Provisioned domain | `generic-ubuntu2204-2_default`; 2 vCPU, 2 GiB RAM |
| Guest address | `192.168.121.185` |
| Litmus inventory | Generated an `ssh_nodes` target with Vagrant provider, platform, VM ID, and Vagrant state path |
| Runtime | Successful Litmus provisioning: about 28 seconds; corrected Litmus connectivity check: about 2 seconds; teardown: about 4 seconds |

Only one target was active at a time. No Puppet agent installation, Puppet apply, module-specific test, or acceptance suite was run.

## Validation results

| Check | Result | Evidence |
|---|---|---|
| Litmus inventory generation | **Pass, with key defect** | Inventory was generated for `generic/ubuntu2204` and recorded the Vagrant environment and target. Its initial SSH private-key setting was not the key accepted by this box. |
| Litmus provisioning | **Pass, with environment and dependency workarounds** | `litmus:provision_list[phase5b]` completed in about 28 seconds and created the libvirt domain. |
| Litmus connection | **Pass after inventory correction** | Initial check failed authentication using the generated Ed25519 path. Direct SSH succeeded with the RSA key, and Litmus connectivity passed after the temporary inventory used that key. |
| Litmus teardown | **Partial; task failed** | Vagrant destroyed the domain and removed its Vagrant state directory. The task then failed on the inventory helper API mismatch, leaving the generated inventory entry behind. |
| Final libvirt resources | **Pass for VM cleanup** | No target domain remained; only the cached Ubuntu box volume remained. |

## Compatibility findings

1. Litmus 2.8.2 includes `vagrant` as a supported provisioner and can drive Vagrant with `VAGRANT_PROVIDER=libvirt`.
2. The Vagrant task's child process inherits Bundler environment from `bundle exec`. Without the temporary wrapper, Vagrant 2.4.9's embedded Ruby failed resolving the Litmus bundle before it could start the VM.
3. The locked fixture did not include `ed25519` or `bcrypt_pbkdf`; Net::SSH required both to process the Ed25519 identity path. The temporary fixture added `ed25519` 1.3.0 and `bcrypt_pbkdf` 1.1.1.
4. The Vagrant task recorded only the first `IdentityFile` from `vagrant ssh-config` in Litmus inventory. For this Ubuntu 22.04 box, that Ed25519 key failed while the listed RSA key succeeded. The generated default inventory therefore did not connect without correction.
5. The provision task's teardown implementation calls `InventoryHelper#remote`, but the checked-out helper exposes `#remove`. VM destruction succeeds before this API mismatch causes the Litmus task to fail.
6. Vagrant emitted a non-fatal `Unrecognized arguments: libvirt_ip_command` warning during SSH configuration/destruction. Its effect on lifecycle behavior was not established.

## Operational, SSH, and cleanup findings

- The target booted successfully using the cached Ubuntu 22.04 libvirt box and the active default libvirt network.
- The provisioner successfully established its initial SSH connection after the optional Net::SSH gems were added.
- The inventory referenced Vagrant's shared `insecure_private_keys` files, not a run-scoped key. This does not meet the compatibility protocol's per-run SSH key lifecycle requirement and must be addressed before Phase 5b acceptance.
- The successful Litmus connectivity check required editing the generated temporary inventory; the default inventory result is therefore a failure.
- Vagrant removed the target domain and target disk during teardown. Litmus did not remove the inventory entry because its subsequent inventory mutation failed.
- No AWS, cloud credentials, or cloud APIs were used. No module acceptance suite was run.

## Implementation blockers

1. Sanitize Bundler/Ruby environment before launching Vagrant, without relying on a test-only wrapper.
2. Add and pin the required Net::SSH key-format gems to the acceptance fixture's bundle.
3. Make the provisioner select an SSH identity that the target accepts, or configure Vagrant to use a documented, deterministic identity; do not assume the first `IdentityFile` is valid.
4. Resolve the teardown inventory API mismatch by aligning the provision task and `InventoryHelper` method contract.
5. Replace the shared insecure Vagrant key with a run-scoped key and verify its cleanup.
6. Investigate the `libvirt_ip_command` warning and establish whether the plugin configuration is compatible with the selected versions.

## Recommendation

**B — Additional Litmus integration work required.** Litmus can provision and connect to the selected backend after temporary workarounds, but the default inventory connection and teardown state handling fail. Do not proceed to Phase 5b implementation until the blockers are fixed and the complete unmodified Litmus lifecycle passes.

## Integration hardening follow-up

The Phase 5b-specific workflow now applies a compatibility patch to the pinned provision-module revision `4b444d86b533dfc887266a51a9f089b4bae8ea7d`. The patch is repeatable and fails closed if the source revision or expected code no longer matches.

The follow-up validation passed:

- The isolated Phase 5b bundle resolves `ed25519` 1.3.0 and `bcrypt_pbkdf` 1.1.1 without changing the Phase 5a bundle.
- Provisioning, inventory generation with a run-scoped SSH key, Litmus connectivity, and teardown succeeded.
- Teardown left no VM domain, target disk, Vagrant run directory, or inventory target. The cached Ubuntu box volume remained.
- An injected malformed `vars` value failed after VM creation; the failure handler destroyed the VM and reconciled the inventory.
- A prior stale inventory record was removed only after confirming its libvirt domain and target disk were absent.
- A focused check verified atomic inventory replacement, preservation of the prior file on simulated rename failure, and removal of stale entries by stable target identity.

The existing provision-module inventory helper unit spec could not load because `rspec-puppet-facts` is not part of the Phase 5b bundle; RuboCop is also absent from that bundle. The direct inventory checks, Ruby syntax checks, and live Litmus lifecycle passed; no Puppet apply or module acceptance suite was run.

**Updated recommendation: A for the requested Litmus integration hardening.** This does not complete all Phase 5b work in ADR-0009: dedicated controller/worker separation, resource-limit enforcement, and broader audit/recovery controls remain separate implementation and validation items.
