# Toolchain Versions

This document records selected pins and the evidence behind compatibility decisions. It is the reference for versions used by the workstation image; the roadmap remains authoritative for tools not yet selected.

## Selected for the workstation image

| Component | Version | Decision and evidence |
| --- | --- | --- |
| Ubuntu | 24.04, digest pinned in `containers/Dockerfile` | Existing base-image decision. |
| Ruby | `3.2.3-1ubuntu0.24.04.8` | Exact Ubuntu package pin already used by the image. |
| Bundler | `2.4.20` | Installed as an exact RubyGems version. Its gemspec requires Ruby `>= 2.6.0`, which includes Ruby 3.2.3. |
| Native build tools | `build-essential` `12.10ubuntu1` | Required for PDK-managed Litmus bundle native extensions (`make`, C compiler, and C library headers). PDK's managed Ruby supplies its own headers; system `ruby-dev` is not required. |
| PDK | `4.0.1` (`4.0.1.1-1noble` Debian package version) | PDK reports `4.0.1`; installed package metadata identifies `4.0.1.1-1noble`. The image downloads that exact package using a BuildKit secret. |
| Dedicated Phase 5a acceptance runtime | PDK `4.0.1`; PDK-managed Ruby `3.2.11`; Bundler `2.4.20`; Litmus `2.8.2` | Operationally validated inside `agentforge-acceptance`; distinct from the workstation's system Ruby/Bundler workflow. |
| Node.js | `22.23.5` | Official Linux x64/arm64 tarballs are pinned by URL and SHA-256 in `containers/Dockerfile`; the Copilot runtime build verifies `node --version`. |
| GitHub Copilot CLI | `1.0.112` | Exact npm package version and dependency integrities are recorded in `containers/copilot/package-lock.json`; the image build verifies `copilot --version`. |
| GitHub CLI | `2.105.0` | Installed only in the Level 1 image from the official package repository. The amd64 and arm64 Debian packages are pinned by SHA-256 in `containers/Dockerfile`; the startup diagnostic verifies the version. Level 0 remains CLI-free. |

The local compatibility check found Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1 on the same host. PDK version/help checks and `pdk validate metadata` on a synthetic PDK-compatible fixture succeeded without accessing an external module repository. A real-module validation with the pinned PDK package reported its managed runtime as Ruby 4.0.7 and Puppet 9.1.0; an earlier synthetic check reported Ruby 3.2.11 and Puppet 8.22.0. These are PDK-managed runtimes, distinct from the workstation Ruby and not independently selected system Agent pins. Record the runtime reported by PDK when diagnosing a module. The PDK package metadata declares no Puppet Agent package dependency, and PDK reports its version when a system Agent is absent. This supports installing PDK without selecting a system Puppet Agent version, but is not proof that a real module's Gemfile and unit-test workflow succeed.

## Puppet Agent

No Puppet Agent package version is required by PDK 4.0.1: the installed PDK package metadata has no declared dependencies, and the PDK CLI runs without `puppet-agent` installed. AgentForge does not select or install Puppet Agent in this phase because no target module or provider has established the required Puppet runtime version, and the protected package index is unavailable without the operator-managed credential. The APT preference continues to block accidental unpinned installation.

Select an exact Puppet Agent package version when a concrete module workflow establishes its runtime requirement and the protected repository can be queried with an authorized BuildKit secret. Record the version and compatibility evidence here before enabling its installation.

## Puppet module compatibility strategy

Puppet 8 is the recommended major for new modules because the image already contains the public Puppet 8 Noble source metadata. PDK's managed runtime is a separate execution context: the pinned package reported Ruby 4.0.7/Puppet 9.1.0 in a real-module validation and Ruby 3.2.11/Puppet 8.22.0 in an earlier synthetic check. These are observations, not workstation or system Agent pins. This does not install Puppet Agent or select a floating Agent package. Each module's `metadata.json` requirements are its compatibility contract; unit-test Puppet gem versions are resolved and reviewed through that module's Gemfile/lockfile. A module that needs a system `puppet` executable or acceptance target must establish an exact Agent package version before the image is changed, then use the ADR-0004 BuildKit-secret build path.

### PDK and standalone Bundler

PDK uses its managed Ruby/Bundler and owns the lockfile for `pdk validate` and `pdk test unit`. In a credential-free run of `puppetlabs-concat` 10.1.0 at commit `77422279fe8fc02ac05add931511a51b135bccf3`, direct PDK unit testing passed 254 examples. Its lockfile used Bundler 2.6.9, Puppet 9.1.0, and Bolt 5.2.0; Puppet/Bolt listed PuppetCore as their source, while the PDK package cache satisfied the run without credentials.

The AgentForge `unit` wrapper previously ran standalone `bundle-install` first. That used system Bundler 2.4.20, public Rubygems, Puppet 8.10.0, and Bolt 4.0.0, and wrote a different lockfile. PDK then tried to resolve that lock under its managed runtime and failed. Running system Bundler after PDK had written its lock could also fail because the lockfile's Bundler version and source set differed. The wrapper no longer pre-installs the system bundle before PDK unit tests.

In the same controlled comparison, direct `pdk validate` and `agentforge-puppet validate` emitted identical 98 RuboCop convention findings and both exited 1; dependency resolution succeeded in both. Direct PDK unit and the corrected AgentForge wrapper both passed 254 examples. Keep standalone `bundle-install` separate from PDK commands; do not inject PuppetCore credentials or silently change module sources.

## Ruby and Bundler module strategy

The supported workstation Ruby is exactly 3.2.3 and Bundler is exactly 2.4.20. New modules receive `.ruby-version` containing `3.2.3`. The workflow rejects a conflicting selector rather than silently switching Ruby versions. The optional system-Ruby bundle from `agentforge-puppet bundle-install` isolates each module's gems and cache under a hashed child of `/cache/bundler/`, while its Bundler application configuration is kept under `/tmp`. PDK commands use PDK's separate managed bundle and lockfile. Do not store private gem credentials in `Gemfile`, `.bundle/config`, environment variables, or persistent caches.

## Copilot authentication and update policy

The image sets `COPILOT_AUTO_UPDATE=false`. Copilot CLI 1.0.112 documents that this disables automatic CLI downloads and plugin updates at session startup. The explicit `copilot update` command remains available to an operator but is not run automatically. In Level 1, `COPILOT_CACHE_HOME` points to the dedicated executable `/copilot-cache` tmpfs required for the CLI's native addon; Level 0 keeps its cache under non-executable `/tmp`. Neither cache is host-mounted or persistent.

The CLI documents `config.json` as managed state that can include signed-in accounts, and its login help warns that tokens may fall back to plaintext there if no credential store is available. The file is not persisted. A successful login was not performed during implementation; verifying actual files created/modified and authentication loss after container recreation is a future operational task.

## Phase 5a validation toolchain

The initial Phase 5a system-Bundler validation used Podman `4.9.3`, system Ruby `3.2.3`, `puppet_litmus` `2.8.2`, and a locked fixture bundle. Rootless Podman API startup, user-namespace mapping, delegated cgroup placement using an absolute parent, target-image build, and the finite `--pids-limit=1024` passed validation. Four serial minimal Puppet apply/assertion runs passed; a controlled assertion failure cleaned up, and a subsequent fresh run passed. This is historical system-Ruby/Bundler evidence and validates the synthetic Ubuntu target only; see the [Phase 5a validation report](phase5a-validation-report.md). ADR-0006 is Accepted.

The subsequent PDK-managed migration was separately validated with PDK `4.0.1`, PDK Ruby `3.2.11` / Puppet `8.22.0`, Bundler `2.4.20`, and Litmus `2.8.2`. `pdk bundle install` compiled the fixture's `nkf`, `bigdecimal`, `io-console`, `json`, and `stringio` native extensions using `build-essential`; `pdk bundle exec rake -T litmus` loaded the tasks. Two one-example runs passed provisioning, connectivity, acceptance, and teardown; a controlled assertion failure triggered automatic teardown. Podman API startup, shutdown, restart, and `podman info` checks passed after runroot reconciliation with a new disposable graphroot. The lockfile was unchanged. VS Code invokes these operations only through the staging wrapper. These results supplement, rather than replace, the earlier system-Ruby/Bundler validation.

## Deferred versions

GitHub CLI 2.105.0 and the read-only `agentforge-gh` wrapper are installed only in the Level 1 image. Authentication is not configured. The current allowlist contains only `Phil-Friderici/puppetlabs-mysql` and `Phil-Friderici/puppetlabs-concat`; live validation results are recorded in the Phase 6a report. Litmus 2.8.2 is selected for the separate acceptance fixture and is not preinstalled in the workstation images; the fixture uses PDK-managed Bundler in the dedicated acceptance identity. Phase 5b compatibility and integration validation used Vagrant 2.4.9 and `vagrant-libvirt` 0.12.2 with libvirt/KVM; production hardening remains future work under Proposed ADR-0009, and no acceptance provider is enabled in the normal workstation profiles. Beaker and system Puppet Agent remain uninstalled; MCP servers remain unselected and uninstalled. Puppet 8 is a recommended module compatibility target, not a system Agent installation. Do not substitute floating versions or infer compatibility from the PDK pin.

## Upgrade procedure

Change a selected version only after checking its compatibility against Ruby, PDK, the pinned Node.js/Copilot CLI pair, and the target module workflow. Update the Dockerfile and this document together, rebuild with the BuildKit secret as described in [Setup](setup.md), and verify the resulting image and runtime configuration. Material changes to the installation or secret boundary require an ADR.
