# Setup

This guide covers the Phase 2 workstation, Phase 3 Copilot workstation, Phase 4 Puppet module workflow, and BuildKit-only PDK image build. Copilot authentication must be initiated manually in Level 1 and is intentionally lost when the container is removed.

## Prerequisites

- Ubuntu 24.04 host with Docker Engine, Docker Compose, and BuildKit/buildx support.
- A normal, non-root host account that can use Docker.
- The AgentForge repository cloned separately from runtime repositories.
- For image builds, the existing Puppet APT auth file from the operator's external secret manager.

Do not add the Docker socket to the workstation. The host Docker Engine builds and starts the environment; the agent container does not control that daemon.

## Prepare persistent host paths

From the AgentForge repository, run:

```sh
bash scripts/init-workspace.sh
```

By default this creates `~/AgentForge/workspace` and `~/AgentForge/cache/agentforge/level1`. It refuses paths inside or overlapping the source checkout, does not recursively change ownership, and checks that existing directories belong to the current user and are writable.

To select other locations, set absolute paths before running the script:

```sh
export AGENTFORGE_WORKSPACE="$HOME/AgentForge/workspace"
export AGENTFORGE_CACHE="$HOME/AgentForge/cache/my-module/level1"
bash scripts/init-workspace.sh
```

Keep the workspace and cache separate from the AgentForge source tree and from each other. Use a project- and trust-level-specific cache path when working on another repository.

Initialize the dedicated Copilot state after initializing the workspace/cache:

```sh
bash scripts/init-copilot-state.sh
```

By default this creates `~/AgentForge/state/copilot` with owner-only permissions and exactly three persistent entries: `settings.json`, `session-state/`, and `session-store.db`. Set `AGENTFORGE_COPILOT_STATE` to an alternate absolute path if needed. The script rejects overlap with the repository, workspace, or cache; it also checks state, workspace, and cache for known authentication artifacts without printing file contents. It does not initialize or persist authentication.

## Build the image with the external credential

Set the host identity used for bind-mounted files:

```sh
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
```

The base image is digest-pinned and its installed packages are version-pinned. PDK 4.0.1 is downloaded in a dedicated BuildKit stage. The credential is mounted only for APT metadata access and package download, then the package is installed in a separate stage without the credential. The final image contains PDK but not the auth file.

The credential must already exist outside the repository, workspace, and cache, in the APT auth format accepted by the Puppet repository. Set only its file path and use the build-only override:

```sh
export PUPPET_REPO_CREDENTIALS="/absolute/path/to/puppet-apt-auth.conf"
docker compose \
  -f compose/compose.yaml \
  -f compose/pdk-build.yaml \
  build agent-level1
unset PUPPET_REPO_CREDENTIALS
```

Never put credential contents in an environment variable, command argument, repository file, or chat. Do not enable shell tracing. If the build fails, do not print the auth file; see [Secret Management](secret-management.md) and [Troubleshooting](troubleshooting.md).

## Start a workstation

After building the image, start a normal service without the build-only Compose override:

```sh
docker compose -f compose/compose.yaml --profile level0 run --rm agent-level0
docker compose -f compose/compose.yaml --profile level1 run --rm agent-level1
```

The startup diagnostic checks Ubuntu, Git, Ruby, Bundler, PDK, Node.js, Copilot CLI, the selected profile's workspace/cache access, Copilot state mount boundaries, and the absence of Docker daemon access and Puppet APT credentials. Both profiles provide a 512 MiB ephemeral `/tmp` because Copilot CLI 1.0.112 extracts about 282 MiB of bundled runtime data there. Level 0 has a read-only workspace, no network, `COPILOT_OFFLINE=true`, and no persistent Copilot state. Level 1 has network access and can write only to the mounted workspace/cache and approved session-state paths. It has no GitHub CLI or Puppet package credentials.

The container shell is replaceable. Repositories under the host-mounted workspace and cache data remain after the shell/container exits. Container-local `/tmp` and other writable-layer data do not persist.

## Included and deferred tools

| Component | Status |
| --- | --- |
| Ubuntu 24.04, Git | Included and pinned |
| Ruby 3.2.3, Bundler 2.4.20 | Included and pinned |
| PDK 4.0.1 (`4.0.1.1-1noble`) | Installed into the image; build requires the external BuildKit secret |
| Puppet Agent | Not installed; no version is required by PDK's package metadata, and the module-specific version remains unselected |
| Node.js | 22.23.5, downloaded from nodejs.org and SHA-256 verified for amd64/arm64 |
| Copilot CLI | 1.0.112 from the npm lockfile; automatic updates disabled |
| GitHub CLI | Deferred; unauthenticated by default |
| Litmus and Beaker | Not installed. Phase 5 proposes Litmus with an isolated rootless Podman provider; no acceptance provider is enabled. |
| Docker CLI/daemon access in the container | Not provided; no socket is mounted |
| MCP | Disabled; no server or client configuration is loaded |
| Persistent Copilot settings/session state | `settings.json`, `session-state/`, and `session-store.db` only, under `~/AgentForge/state/copilot`; authentication and logs are ephemeral |

Version evidence and remaining compatibility limits are in [Toolchain Versions](toolchain-versions.md).

## Develop a Puppet module

Inside a Level 1 container, use the installed `agentforge-puppet` command to bootstrap or work with a module:

```sh
agentforge-puppet bootstrap example_module
agentforge-puppet toolchain /workspace/example_module
agentforge-puppet bundle-install /workspace/example_module
agentforge-puppet validate /workspace/example_module
agentforge-puppet unit /workspace/example_module
```

The workflow pins Ruby 3.2.3, Bundler 2.4.20, and PDK 4.0.1 and assigns each module a separate Bundler cache. Puppet 8 is the recommended module target major, but module metadata and its locked Puppet dependency determine actual compatibility; no global Puppet Agent is installed. See [Puppet Module Development](puppet-development.md) for fork practices, advanced arguments, recovery, and version policy.

## Copilot authentication and state

Level 1 sets `COPILOT_HOME=/copilot` on tmpfs and bind-mounts only the approved settings/session paths individually. It never mounts the whole Copilot home or host state directory. `config.json` (which can contain signed-in account state), process logs, MCP configuration, personal instructions, plugins, and the CLI cache remain ephemeral. Both profiles set `COPILOT_CACHE_HOME=/tmp/copilot-cache`; it is runtime scratch, not the persistent host cache. `COPILOT_AUTO_UPDATE=false` disables automatic CLI and plugin updates. Do not copy tokens or authentication files into `/workspace`, `/cache`, or the persistent state directory.

Inside a Level 1 container, start authentication explicitly with `copilot login`. CLI 1.0.112's login help confirms that a missing credential store can cause token data to be written in `config.json`; therefore the whole home is on tmpfs. The CLI has no standalone `logout` subcommand in this pinned version. Removing/recreating the container discards the entire ephemeral home and is the guaranteed way to clear its authentication state; the three approved state mounts survive. Level 0 is offline and is configured with `COPILOT_OFFLINE=true`.

The CLI's 1.0.112 help documents `config.json` as managed state that can include signed-in accounts, `settings.json` as user settings, `session-state/` as session event/metadata/plan/checkpoint/file storage, `session-store.db` as the session index, and `logs/` as process logs. The design persists only settings, session-state, and the session index; the other paths stay on tmpfs. No successful login was performed during implementation, so confirming real login file changes and reauthentication after container recreation remains a future operational verification. The implemented checks reject known auth paths, auth-like settings, and GitHub token patterns in persistent state/workspace/cache; the ephemeral Copilot runtime cache is checked for authentication-like filenames and recognizable GitHub tokens without printing matching content.
