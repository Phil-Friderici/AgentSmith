# Containers

This directory contains the Ubuntu 24.04 workstation image and startup diagnostic.

## Image stages

- `workstation-base` installs pinned Git, Ruby 3.2.3, Bundler 2.4.20, public Puppet source/key metadata, and the no-unpinned-Agent APT preference.
- `copilot-runtime` downloads Node.js 22.23.5 from the official release site, verifies its architecture-specific SHA-256, installs the locked `@github/copilot` 1.0.112 package without lifecycle scripts, and verifies both runtime versions.
- `pdk-package` mounts the external Puppet APT auth file as a BuildKit secret only while refreshing package metadata and downloading PDK `4.0.1.1-1noble`.
- `workstation` installs the downloaded package after the secret mount is gone, copies the Copilot runtime and storage validator, then installs the diagnostics, Puppet workflow command, and non-root workstation entrypoint.

The final image contains PDK 4.0.1, Node.js 22.23.5, and Copilot CLI 1.0.112 but no Puppet repository credentials. It does not install Puppet Agent, GitHub CLI, Litmus, or Beaker. Puppet Agent remains deferred until a module workflow establishes its version.

`agentforge-puppet` requires Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1. It creates PDK 4.0.1 modules, keeps Bundler application configuration under `/tmp`, and hashes each canonical module path to isolate its cache under `/cache/bundler/`.

## Security boundaries

- The PDK secret is not passed through `ARG` or `ENV`, copied into the build context, or mounted into runtime services.
- The build context is limited to this directory; `.dockerignore` allowlists required infrastructure files, not project workspaces or caches.
- The package-download and package-install steps are separate so package installation scripts do not receive the credential.
- Copilot dependencies are installed in a separate build stage that does not consume or mount the Puppet BuildKit secret.
- The Compose build override lives in `compose/pdk-build.yaml`; normal runtime commands use `compose/compose.yaml` alone.
- The final workstation runs unprivileged with only explicitly configured workspace/cache mounts.
- Level 1 puts the complete `/copilot` home and Copilot cache on tmpfs, then bind-mounts only `settings.json` read-only, `session-state/`, and `session-store.db`.
- Both Compose profiles allocate a 512 MiB `/tmp` tmpfs. Copilot CLI 1.0.112 extracts about 282 MiB of bundled runtime data there on first use; the diagnostic checks the minimum capacity.
- `COPILOT_AUTO_UPDATE=false` disables automatic CLI and plugin updates. Level 0 also sets `COPILOT_OFFLINE=true` and has no persistent Copilot-state mounts.
- Do not enable privileged mode, broad host mounts, host namespaces, or Docker socket access.

BuildKit secret behavior, the private package fetch, and image-layer leak checks require an authorized build with the operator-managed external credential. The build was not exercised in this environment because no credential source was available.

See [architecture](../docs/architecture.md), [secret management](../docs/secret-management.md), and [toolchain versions](../docs/toolchain-versions.md). Record material container changes in an ADR.
