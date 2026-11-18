# Secret Management

## Requirements

Puppet package repository credentials already exist and are managed outside this repository. AgentForge must not create, commit, display, or bake those credentials into container images. Puppet credentials must not appear in build logs, image layers, runtime configuration, workspace, cache, generated artifacts, or chat output. Copilot authentication is a separate, operator-initiated runtime flow governed by ADR-0005; it is ephemeral and must not enter any persistent state.

ADR-0004 is authoritative for PDK installation: credentials are supplied only as a BuildKit secret during image build. Normal development containers have no Puppet secret mount, secret environment variable, or access to the host credential source. Runtime Compose configuration does not declare the credential. Copilot CLI installation uses a separate build stage and never consumes the Puppet BuildKit secret.

## Build-only credential flow

The operator supplies an existing APT auth file, in the format expected by APT, from an external secret manager or host-controlled path. Do not assume the credential file format; confirm it through the package repository owner without displaying its contents.

The `compose/pdk-build.yaml` override is used only when building the workstation image. It passes the host file to BuildKit under the secret ID `puppet_repo_credentials`. The Dockerfile mounts it at `/etc/apt/auth.conf.d/puppet.conf` only while apt updates package metadata and downloads the pinned PDK package. A separate stage installs the downloaded package after the secret mount is gone.

The Compose build context is `containers/`, not the project workspace. `containers/.dockerignore` allowlists the Dockerfile and required startup scripts, so repository checkouts and workspace/cache mounts are not sent to or mounted into the package-download stage.

The build secret:

- is not passed through `ARG` or `ENV`
- is not copied into a build context or image layer
- is not available to the PDK package installation scripts
- is not configured as a runtime Compose service secret
- is not persisted in workspace or cache paths

BuildKit secret mounts prevent the mounted file from being committed as part of the `RUN` layer. They do not protect against a malicious build step that deliberately reads or prints the secret. Keep the secret mount limited to the package-index/download command, do not enable shell tracing, and review the Dockerfile and build output.

## Build invocation

Keep the credential file outside the repository, workspace, and cache. Provide only its path to Compose; never place its contents in an environment variable or command argument:

```sh
export PUPPET_REPO_CREDENTIALS="/absolute/path/to/puppet-apt-auth.conf"
docker compose \
  -f compose/compose.yaml \
  -f compose/pdk-build.yaml \
  build agent-level1
unset PUPPET_REPO_CREDENTIALS
```

The build may fail if the credential is missing, invalid, expired, or not authorized for the pinned PDK package. Do not diagnose failures by printing the auth file or enabling verbose shell tracing. Verify that error output does not contain credential values before retaining or sharing it.

After a successful build, start the normal service using only `compose/compose.yaml`; do not include the build override:

```sh
docker compose -f compose/compose.yaml --profile level1 run --rm agent-level1
```

The normal runtime command does not need the credential path. Rebuilding the PDK image requires the external secret again.

## Verification

Before distributing an image, an authorized build must verify all of the following:

- The PDK package is present at the pinned version.
- `/etc/apt/auth.conf.d/puppet.conf` is absent from the final image.
- No runtime service declares `secrets`, a secret path, or `PUPPET_REPO_CREDENTIALS` in its environment or mounts.
- Image history, exported layer contents, build output, and generated artifacts contain no credential.
- PDK installation failure output does not include credentials or authenticated URLs.
- The final image can be started without access to the host credential source.

Use the startup diagnostic to check that the runtime APT credential file is absent. Compose configuration and container inspection can verify that the build secret is not mounted into runtime services. Inspect image layers as well as the final merged filesystem; checking only the final filesystem would not detect a file that was added and later deleted in an earlier layer.

The BuildKit configuration and diagnostic are implemented. The protected PDK build and secret-leak checks have not been executed because no external credential source is available in this environment.

## Copilot authentication and persistent state

ADR-0005 is authoritative for Copilot CLI authentication. The operator authenticates manually when needed in Level 1. Authentication state may exist only in the container's ephemeral Copilot home and is discarded on container recreation; the operator must authenticate again. Do not configure a Copilot token, host credential directory, keyring socket, or credential source through Compose.

The implemented state layout persists only `settings.json`, `session-state/`, and `session-store.db` under the dedicated host path `~/AgentForge/state/copilot`, separate from the repository, workspace, and cache. `settings.json` is mounted read-only; the session paths are writable. The entire `/copilot` home is tmpfs, and only the three selected paths are individually mounted. Do not persist `config.json` (which can contain signed-in account state), process logs, credential caches, plugins, MCP configuration, personal instructions, or other Copilot-home files. Session history can contain prompts, plans, file contents, and tool output, so protect it with owner-only permissions and documented retention.

The host initializer and container diagnostic reject unapproved state-root entries, known authentication file names, auth-like settings, and recognizable GitHub token formats in persistent state, workspace, or host cache. The ephemeral Copilot runtime cache is checked for authentication-like filenames and recognizable GitHub token formats. JSON schema files are not rejected solely for describing auth-related fields. Checks never print matching contents. These checks are defense in depth; the hard boundary is that authentication files are created only within the ephemeral Copilot home. Successful login and post-recreation verification remain future operational checks. The login flow has not been used during implementation.

Copilot CLI 1.0.112 does not expose a standalone `logout` subcommand in its command help. Container removal/recreation discards its ephemeral home and is the guaranteed cleanup mechanism; it does not affect the independent persistent settings/session mounts.

## Other credentials

GitHub CLI, Git remotes, Copilot CLI, and MCP servers may each have distinct authentication flows. Copilot authentication must follow ADR-0005 and must not be made persistent. Each other flow must be reviewed independently. Do not assume a mechanism safe for a local development container is also safe for image builds or third-party MCP servers.

Use the narrowest scope and shortest lifetime available. Avoid mounting a general-purpose host credential directory or forwarding an SSH agent unless a reviewed workflow requires it. Do not place tokens in environment variables if they may be exposed by process inspection or diagnostic output.

## Logging and chat hygiene

- Never print secret-bearing files, environment values, credential-helper output, or authenticated URLs.
- Do not ask the agent to read, summarize, or transform secret contents.
- Prefer tools that do not return secret values to the agent at all.
- Suppress or redact sensitive output at the source; redaction is defense in depth, not permission to expose secrets.
- Ensure failure messages identify the failed operation without echoing credentials or request headers.
- Do not paste credentials into prompts, issues, pull requests, or documentation.

If a secret may have been exposed, stop the workflow and have the operator revoke or rotate the credential using its external management process. Do not repeat the secret while diagnosing the event.

## Persistence and cleanup

Puppet repository secret values must not enter the repository, workspace, cache, final image, runtime container, or session logs. Copilot authentication is the narrowly defined ADR-0005 exception: it may be present transiently in the Level 1 runtime's ephemeral home after explicit operator login, but must not be persisted in container configuration, images, repositories, workspace, cache, or dedicated Copilot state mounts. The BuildKit secret is ephemeral to the package-download instruction; downloaded packages are not credentials. The build host and its BuildKit cache remain operator-controlled and must be protected according to the host's security policy.

Docker/BuildKit implementations can differ. Before relying on the flow, verify secret mount behavior, build output, cache contents, image layers, and runtime service configuration on the target host.
