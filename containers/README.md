# Containers

This directory contains the Ubuntu 24.04 workstation image and startup diagnostic.

## Image stages

- `workstation-base` installs pinned Git, Ruby 3.2.3, Bundler 2.4.20, public Puppet source/key metadata, and the no-unpinned-Agent APT preference.
- `copilot-runtime` downloads Node.js 22.23.5 from the official release site, verifies its architecture-specific SHA-256, installs the locked `@github/copilot` 1.0.112 package without lifecycle scripts, and verifies both runtime versions.
- `pdk-package` mounts the external Puppet APT auth file as a BuildKit secret only while refreshing package metadata and downloading PDK `4.0.1.1-1noble`.
- `workstation` installs the downloaded package after the secret mount is gone, copies the Copilot runtime and storage validator, then installs the diagnostics, Puppet workflow command, and non-root workstation entrypoint.
- `workstation-level1` adds GitHub CLI 2.105.0 from the official package repository using architecture-specific SHA-256 pins, the repository allowlist, the `agentforge-gh` read-only metadata wrapper, and the `agentforge-gh-auth` ephemeral PAT lifecycle command. These are selected only by the Level 1 Compose service.
- `workstation-default` preserves the GitHub-CLI-free default image target.
- `maintainer-broker` is a separate Ubuntu 24.04/Ruby 3.2.3 image for the disabled Phase 7a/7b broker foundation. It contains no Git or GitHub CLI and is not part of either workstation image.

The `workstation` image contains PDK 4.0.1, Node.js 22.23.5, and Copilot CLI 1.0.112, but no GitHub CLI or Puppet repository credentials. The Level 1 image adds GitHub CLI and permits an operator to store a fine-grained PAT in `/tmp` tmpfs; no credential is configured by default. Level 0 remains on `workstation`, has no GitHub CLI or auth helper, and has no network access. Puppet Agent, Litmus, and Beaker are not installed.

`agentforge-puppet` requires Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1. It creates PDK 4.0.1 modules, keeps Bundler application configuration under `/tmp`, and hashes each canonical module path to isolate its cache under `/cache/bundler/`.

## Security boundaries

- The PDK secret is not passed through `ARG` or `ENV`, copied into the build context, or mounted into runtime services.
- The build context is limited to this directory; `.dockerignore` allowlists required infrastructure files, not project workspaces or caches.
- `.dockerignore` includes only the Phase 7a broker entrypoint and library for the `maintainer-broker` target; tests and documentation are not copied into the image.
- The package-download and package-install steps are separate so package installation scripts do not receive the credential.
- GitHub CLI is downloaded only in the Level 1 image stage and verified against pinned SHA-256 digests for amd64 and arm64. No GitHub credential is used during the build.
- The version-controlled public-repository allowlist is copied read-only into the Level 1 image; repository selection is available only through the `agentforge-gh` wrapper.
- Copilot dependencies are installed in a separate build stage that does not consume or mount the Puppet BuildKit secret.
- The Compose build override lives in `compose/pdk-build.yaml`; normal runtime commands use `compose/compose.yaml` alone.
- The final workstation runs unprivileged with only explicitly configured workspace/cache mounts.
- Level 1 puts the complete `/copilot` home and Copilot cache on separate tmpfs mounts, then bind-mounts only `settings.json` read-only, `session-state/`, and `session-store.db`. The dedicated 512 MiB `/copilot-cache` tmpfs is executable because Copilot CLI 1.0.112 loads its `cli-native` shared library from the cache; it remains ephemeral and is not a host mount.
- Both Compose profiles retain a 512 MiB `noexec` `/tmp` tmpfs for scratch data. Level 0 keeps its Copilot cache there; Level 1 uses the dedicated executable cache mount so execution permission is not broadened across general temporary storage.
- Level 1 creates `/tmp/agentforge-gh/config` with owner-only permissions and sets `GH_CONFIG_DIR` there. The path is on the ephemeral `/tmp` tmpfs; Level 0 has neither the variable nor the directory.
- `agentforge-gh` is installed only in Level 1. It accepts only the documented metadata commands, requires an exact repository match in `/etc/agentforge/github-allowlist.yml`, strips GitHub token/host/repository environment overrides, and forces the ephemeral configuration path. The current allowlist contains only `Phil-Friderici/puppetlabs-mysql` and `Phil-Friderici/puppetlabs-concat`.
- `agentforge-gh-auth` and its read-only Ruby helper are installed only in Level 1. They accept hidden interactive PAT input, store it at `/tmp/agentforge-gh/pat` with mode 0600, and never write it to the image, config directory, workspace, or cache. The helper does not verify GitHub permissions or repository scope.
- `COPILOT_AUTO_UPDATE=false` disables automatic CLI and plugin updates. Level 0 also sets `COPILOT_OFFLINE=true` and has no persistent Copilot-state mounts.
- Do not enable privileged mode, broad host mounts, host namespaces, or Docker socket access.

The Phase 7a/7b broker is run only through the separate `compose/phase7a-broker.yaml` profile. It has no provider handlers, approval identity/provider, credential issuer, durable audit sink, external emergency-stop adapter, workstation/repository mounts, or network access. See the [broker boundary and blockers](maintainer-broker/README.md).

The image rebuild in this phase reused the cached PDK package-download stage; the external Puppet credential was not read. A fresh protected package fetch and image-layer leak inspection still require a separately authorized validation.

See [architecture](../docs/architecture.md), [secret management](../docs/secret-management.md), and [toolchain versions](../docs/toolchain-versions.md). Record material container changes in an ADR.
