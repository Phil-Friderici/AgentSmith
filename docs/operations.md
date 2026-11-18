# Operations

## Workstation lifecycle

The Compose services are interactive, replaceable shells. Start each session with the selected profile:

```sh
docker compose -f compose/compose.yaml --profile level0 run --rm agent-level0
docker compose -f compose/compose.yaml --profile level1 run --rm agent-level1
```

`docker compose run --rm` removes the container after the session. The host-mounted workspace and selected cache remain. Do not rely on `/tmp`, the container writable layer, or package installs performed in an ephemeral container as durable state.

The image includes mount health checks. The startup `agentforge-doctor` report is also available inside the container. A failed required check stops startup; tools deferred by the roadmap are informational.

## Puppet module workflow

Run module commands inside a Level 1 workstation:

```sh
agentforge-puppet toolchain /workspace/example_module
agentforge-puppet bundle-install /workspace/example_module
agentforge-puppet validate /workspace/example_module
agentforge-puppet unit /workspace/example_module
```

`unit` performs the project-scoped bundle install before `pdk test unit`. The cache is disposable; the module's Gemfile and lockfile in `/workspace` are the dependency source of truth. Use [Puppet Module Development](puppet-development.md) for bootstrap, fork conventions, supported versions, and safe cache recovery. Do not put private gem credentials in repository configuration, environment variables, or caches.

## Rebuild and recovery

Rebuild after a reviewed Dockerfile or version-pin change. PDK image rebuilds require the external APT auth file, supplied only through BuildKit:

```sh
export PUPPET_REPO_CREDENTIALS="/absolute/path/to/puppet-apt-auth.conf"
docker compose \
  -f compose/compose.yaml \
  -f compose/pdk-build.yaml \
  build agent-level1
unset PUPPET_REPO_CREDENTIALS
```

The secret is used only to download the pinned PDK package. Package installation happens in a separate stage, and the final image contains no auth file. Do not pass credentials using build arguments or environment variables. To force a fresh PDK package download after changing repository content or credentials, use `--no-cache` for the build; the secret itself is not part of the cache key.

An image rebuild or container removal does not delete the host workspace/cache bind mounts. If a directory is damaged or unavailable, stop the container, inspect the exact host path, and restore it from the operator's backup. AgentForge does not define or perform backups.

To restart from a clean container, exit the shell and run the selected Compose command again. Do not delete the workspace to repair an image or dependency problem.

## Caches

The Puppet workflow hashes each canonical module path to place Bundler gems and package cache under its own `/cache/bundler/<module-id>/` directory. Bundler application configuration is kept under `/tmp`. The host cache path should also be scoped by project and trust level. Caches are disposable and may contain private package metadata or untrusted artifacts. Do not place credentials or auth files there. Cache invalidation is an operator action: stop the workstation, identify the exact configured module cache path, and remove only that cache.

PDK is installed in the image and persists across container recreation; it does not depend on a runtime cache. Litmus, Beaker, and Puppet download caches are not configured. Phase 5 provider behavior is design-only; see [Puppet Acceptance Testing Design](acceptance-testing.md). Add caches only with a reviewed version and lifecycle policy.

## PDK package and image lifecycle

PDK 4.0.1 is installed into the workstation image during build, so it remains available across container recreation. The image is rebuilt—not modified at runtime—to reinstall PDK. Rebuilds require the external APT auth file through `compose/pdk-build.yaml`; normal Level 0/1 sessions use only `compose/compose.yaml` and cannot access that file.

The exact package version is `4.0.1.1-1noble`. To upgrade or reinstall, update the Dockerfile and [Toolchain Versions](toolchain-versions.md), then rebuild with the secret. Use `--no-cache` when an explicit package re-download is required. Do not put credential contents in build args, environment variables, or local files inside the build context.

The protected package fetch, build logs, and layer-leak checks have not been validated with an actual credential in this environment.

## Authentication and permissions

Level 1 supports operator-initiated ephemeral Copilot authentication; GitHub CLI authentication is not configured. Level 0 is offline and has no persistent Copilot state. Level 2 and Level 3 are not implemented. Copilot 1.0.112 may fall back to storing token information in `config.json`, so the entire `/copilot` home is tmpfs. The pinned CLI has no standalone `logout` subcommand; recreating/removing the container is the guaranteed way to discard authentication. Do not mount host credential directories, persist Copilot's auth-bearing configuration, or use the Docker socket as a workaround.

The Copilot state directory is `~/AgentForge/state/copilot` by default. Only `settings.json` (read-only in the container), `session-state/`, and `session-store.db` persist; each is mounted individually. Authentication configuration, credential caches, process logs, MCP configuration, personal instructions, plugins, and the rest of `COPILOT_HOME` remain ephemeral. Session history can contain project data and must follow owner-only permissions, retention, and cleanup policy. Never enter credentials into prompts or commands that may be captured in session history. Do not back up authentication data. Persistent session backups, if enabled, should be encrypted and subject to the same retention restrictions.

Review sessions weekly and prune inactive sessions older than 30 days with `/session prune` from a Copilot session. A cleanup should operate only on session-state data, never on an authentication file. The SQLite session index may need to be updated through the CLI rather than edited directly. No automatic backup or cleanup service is installed.

To revoke build access, stop using the build-only override and remove the source path from the invoking shell. Revoke or rotate the source credential through its external owner if exposure is suspected; do not copy it into AgentForge for investigation.

## Upgrading

Base image digests, APT package versions, PDK/Bundler versions, Node.js 22.23.5, and Copilot CLI 1.0.112 are explicit pins. `COPILOT_AUTO_UPDATE=false` disables automatic CLI and plugin updates. Review updates deliberately, test Compose profiles and the environment diagnostic, and document material decisions in an ADR. Do not change pins to floating `latest` tags or silently select a Puppet Agent version. See [Toolchain Versions](toolchain-versions.md).
