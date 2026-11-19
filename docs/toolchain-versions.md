# Toolchain Versions

This document records selected pins and the evidence behind compatibility decisions. It is the reference for versions used by the workstation image; the roadmap remains authoritative for tools not yet selected.

## Selected for the workstation image

| Component | Version | Decision and evidence |
| --- | --- | --- |
| Ubuntu | 24.04, digest pinned in `containers/Dockerfile` | Existing base-image decision. |
| Ruby | `3.2.3-1ubuntu0.24.04.8` | Exact Ubuntu package pin already used by the image. |
| Bundler | `2.4.20` | Installed as an exact RubyGems version. Its gemspec requires Ruby `>= 2.6.0`, which includes Ruby 3.2.3. |
| PDK | `4.0.1` (`4.0.1.1-1noble` Debian package version) | PDK reports `4.0.1`; installed package metadata identifies `4.0.1.1-1noble`. The image downloads that exact package using a BuildKit secret. |
| Node.js | `22.23.5` | Official Linux x64/arm64 tarballs are pinned by URL and SHA-256 in `containers/Dockerfile`; the Copilot runtime build verifies `node --version`. |
| GitHub Copilot CLI | `1.0.112` | Exact npm package version and dependency integrities are recorded in `containers/copilot/package-lock.json`; the image build verifies `copilot --version`. |

The local compatibility check found Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1 on the same host. PDK version/help checks and `pdk validate metadata` on a synthetic PDK-compatible fixture succeeded without accessing an external module repository. PDK reported its managed runtime as Ruby 3.2.11 and Puppet 8.22.0. The PDK package metadata declares no Puppet Agent package dependency, and PDK reports its version when a system Agent is absent. This supports installing PDK without selecting a system Puppet Agent version. It is not a substitute for validating a real module's Gemfile and unit-test workflow inside the completed image.

## Puppet Agent

No Puppet Agent package version is required by PDK 4.0.1: the installed PDK package metadata has no declared dependencies, and the PDK CLI runs without `puppet-agent` installed. AgentForge does not select or install Puppet Agent in this phase because no target module or provider has established the required Puppet runtime version, and the protected package index is unavailable without the operator-managed credential. The APT preference continues to block accidental unpinned installation.

Select an exact Puppet Agent package version when a concrete module workflow establishes its runtime requirement and the protected repository can be queried with an authorized BuildKit secret. Record the version and compatibility evidence here before enabling its installation.

## Puppet module compatibility strategy

Puppet 8 is the recommended major for new modules because the image already contains the public Puppet 8 Noble source metadata. A local PDK 4.0.1 metadata-validation check reported its managed runtime as Ruby 3.2.11 and Puppet 8.22.0; these are PDK execution versions, not installed system packages or independent pins. This does not install Puppet Agent or select a floating Agent package. Each module's `metadata.json` requirements are its compatibility contract; unit-test Puppet gem versions are resolved and reviewed through that module's Gemfile/lockfile. A module that needs a system `puppet` executable or acceptance target must establish an exact Agent package version before the image is changed, then use the ADR-0004 BuildKit-secret build path.

## Ruby and Bundler module strategy

The supported workstation Ruby is exactly 3.2.3 and Bundler is exactly 2.4.20. New modules receive `.ruby-version` containing `3.2.3`. The workflow rejects a conflicting selector rather than silently switching Ruby versions. Project dependencies are installed through `agentforge-puppet bundle-install`; it isolates each module's gems and Bundler cache under a hashed child of `/cache/bundler/`, while Bundler's application configuration is kept under `/tmp`. Do not store private gem credentials in `Gemfile`, `.bundle/config`, environment variables, or persistent caches.

## Copilot authentication and update policy

The image sets `COPILOT_AUTO_UPDATE=false`. Copilot CLI 1.0.112 documents that this disables automatic CLI downloads and plugin updates at session startup. The explicit `copilot update` command remains available to an operator but is not run automatically. In Level 1, `COPILOT_CACHE_HOME` points to the dedicated executable `/copilot-cache` tmpfs required for the CLI's native addon; Level 0 keeps its cache under non-executable `/tmp`. Neither cache is host-mounted or persistent.

The CLI documents `config.json` as managed state that can include signed-in accounts, and its login help warns that tokens may fall back to plaintext there if no credential store is available. The file is not persisted. A successful login was not performed during implementation; verifying actual files created/modified and authentication loss after container recreation is a future operational task.

## Proposed acceptance toolchain

Phase 5 proposes Litmus as the primary framework, rootless Podman as the local disposable target provider, and Beaker only for compatibility with a module that already uses it. No versions are selected, installed, or tested. The Litmus/Podman compatibility spike and module-specific Puppet Agent version decision must precede implementation. EC2 remains opt-in; nested KVM is not the default. See [Puppet Acceptance Testing Design](acceptance-testing.md).

## Deferred versions

GitHub CLI, Litmus, Beaker, system Puppet Agent, and MCP servers remain unselected or uninstalled. Puppet 8 is a recommended module compatibility target, not a system Agent installation. The acceptance provider recommendation is proposed, not an installed capability. Do not substitute floating versions or infer compatibility from the PDK pin.

## Upgrade procedure

Change a selected version only after checking its compatibility against Ruby, PDK, the pinned Node.js/Copilot CLI pair, and the target module workflow. Update the Dockerfile and this document together, rebuild with the BuildKit secret as described in [Setup](setup.md), and verify the resulting image and runtime configuration. Material changes to the installation or secret boundary require an ADR.
