# Troubleshooting

Diagnostics and troubleshooting output must not include secret contents. Never print an APT auth file, token, credential environment variable, or authenticated URL.

## Compose reports missing UID/GID

Set the host identity in the shell that runs Compose:

```sh
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
```

These values determine ownership of files written through bind mounts. The container refuses to run as root.

## Workspace or cache path is missing or not writable

Run `bash scripts/init-workspace.sh` as the normal host user. Check the `AGENTFORGE_WORKSPACE` and `AGENTFORGE_CACHE` values, confirm they are absolute and separate from the source checkout, and inspect ownership with `stat`. Correct ownership/permissions manually; the startup process intentionally does not run `chown` or recursively modify data.

Level 0 is read-only by design. Use Level 1 only when local writes and network access are required. Level 1's writable scope is limited to the configured workspace and cache bind mounts.

## Startup diagnostic fails

The image runs `agentforge-doctor` before starting the shell. Required Phase 2 failures include a non-Ubuntu-24.04 image, missing Git/Ruby, root execution, an inaccessible workspace, a writable Level 0 workspace, a non-writable Level 1 workspace/cache, or an unexpected `/var/run/docker.sock`.

Run `/usr/local/bin/agentforge-doctor` inside the container to repeat the report. It scans known persistent/workspace/cache paths for authentication artifacts but never prints matching content. Git, Ruby, Bundler, PDK, Node.js, and Copilot CLI are required.

## Network or GitHub access is unavailable

Level 0 has `network_mode: none` and `COPILOT_OFFLINE=true`; this is intentional. Level 1 is attached to the Compose network, but the diagnostic does not probe external endpoints. GitHub CLI authentication is not configured. Copilot login is initiated manually inside Level 1; authentication lives only under the ephemeral `/copilot` tmpfs home.

If the browser reports `127.0.0.1` refusing the Copilot login callback, the host browser cannot reach the callback listener inside the container. Retry with `copilot login --device-code`, which does not use a loopback callback. Do not paste the device code into chat or logs.

When starting Copilot with a separate `docker exec`, set `umask 077` in that process; it does not inherit the workstation entrypoint's umask. Otherwise new files in persistent session-state may receive broader mode bits and fail the storage diagnostic. Use the Compose-managed shell where possible.

## Docker commands cannot reach a daemon

Docker CLI/daemon access is intentionally not exposed inside the workstation. Use Docker Compose on the host to build and start AgentForge. Do not mount `/var/run/docker.sock`; access to the host daemon would bypass the workstation's container boundary.

## Rootless Podman container start fails with cgroup permission denied

The short relative `--cgroup-parent=agentforge-containers` resolved outside the unit, but the absolute `/system.slice/agentforge-acceptance-phase5a-podman.service/agentforge-containers` parent placed the running canary beneath the delegated subtree. See the [Phase 5a validation report](phase5a-validation-report.md).

With `HostConfig.PidsLimit=0`, the tested rootless runtime produced `pids.max=1`. The Phase 5a fixture now supplies the finite `--pids-limit=1024`; verify that the effective cgroup `pids.max` matches before running tests, then check shell startup and child-process creation. Do not remove resource limits or enable privileged containers, Docker daemon access, linger, or broader cgroup permissions as workarounds.

## A requested development tool is missing

The image includes Git, Ruby 3.2.3, Bundler 2.4.20, PDK 4.0.1, Node.js 22.23.5, and Copilot CLI 1.0.112. GitHub CLI, system Puppet Agent, Litmus, and Beaker remain deferred. If a pinned tool is missing or mismatched, rebuild from the current `containers/Dockerfile`; do not install alternate toolchain versions into a running container.

## Puppet module dependency or validation failure

Run `agentforge-puppet toolchain /workspace/<module>` and confirm the module's `.ruby-version`, Gemfile, lockfile, and `metadata.json` Puppet requirements. Use `agentforge-puppet bundle-install` to install dependencies into the cache isolated for that module, then rerun `validate` or `unit`. PDK validation does not auto-correct by default. A module that requires another Ruby or a system Puppet Agent needs a reviewed version decision and image update; do not bypass the preflight or install an unpinned package.

Bundler configuration is under ephemeral `/tmp`, and module caches are under `/cache/bundler/<module-id>`. If a cache is corrupt, stop the container and remove only that module's exact cache directory, then rerun `bundle-install`. The workspace Gemfile and lockfile are authoritative; never move credentials into Bundler configuration to work around an inaccessible private source.

## Copilot CLI reports a missing native addon or shared-object mapping error

During Operational Validation Phase 2, `copilot login` exposed that Copilot CLI 1.0.112 extracts `cli-native` into its runtime cache and loads it as a shared library. The original Level 1 cache was under `/tmp`, whose tmpfs is intentionally mounted `noexec`; loading the addon then failed with `failed to map segment from shared object`. Level 1 now uses a dedicated 512 MiB executable `/copilot-cache` tmpfs while general `/tmp` remains `noexec`. The cache is writable only within the container, is discarded on recreation, and is not a host cache or persistent Copilot state. Do not remove `noexec` from `/tmp` or move the Copilot cache into the workspace, host cache, or persistent state.

The startup diagnostic verifies that `/copilot-cache` is a writable, executable tmpfs with at least 512 MiB. If it fails, use the repository Compose configuration and recreate the container; do not broaden execution permissions on other mounts.

## Copilot CLI reports package extraction or `ENOSPC` errors

The dedicated Level 1 Copilot cache and both profiles' `/tmp` tmpfs each have a 512 MiB capacity for runtime extraction and scratch data. Do not reduce these limits or move the cache to a persistent path.

## PDK image build or package access fails

- Confirm `PUPPET_REPO_CREDENTIALS` points to the existing external APT auth file and the file is readable by the host Docker/BuildKit user.
- Confirm that the auth file uses the format expected by APT for the Puppet repository. Do not print or paste it.
- Build with both `compose/compose.yaml` and `compose/pdk-build.yaml`; do not mount the secret into a runtime service.
- Check that the host permits outbound package access. The protected-package build runs on the host BuildKit builder; the Level 0 runtime's no-network policy is unrelated.
- If installation fails, review the error only after confirming it contains no credential values or authenticated URLs. Do not enable shell tracing, weaken file permissions, or expose the secret to the interactive user.
- The pinned PDK Debian package has no declared Puppet Agent dependency. Puppet Agent remains deferred until a module workflow establishes its exact version.
- PDK 4.0.1 package access and secret-leak checks have not been exercised with an actual credential in this environment.

## Runtime diagnostic reports a Puppet credential

The runtime image must not contain `/etc/apt/auth.conf.d/puppet.conf`. Rebuild using the current BuildKit Dockerfile and inspect image layers and runtime configuration. Do not resolve the failure by mounting the auth file into a runtime container.

## State appears to be lost

Only data under the configured host bind mounts persists. Changes in `/tmp`, `/copilot` (except the three explicit Level 1 bind mounts), or the container layer disappear when the container is removed. Verify the resolved `AGENTFORGE_WORKSPACE`, `AGENTFORGE_CACHE`, and `AGENTFORGE_COPILOT_STATE` values and inspect those host paths. Restore deleted project data from the operator's backup; AgentForge does not maintain a backup service.

Copilot settings and selected session data persist separately under `~/AgentForge/state/copilot`. Authentication and process logs do not persist, so logging in again after container recreation is expected. If `agentforge-doctor` reports an authentication artifact, stop using the affected state/workspace/cache path, do not print the file, and have the operator inspect and remove it securely. Session data can include sensitive prompts and tool output; follow the documented retention and cleanup policy and do not restore auth-bearing files from backups.

## Copilot storage diagnostic fails

Run `bash scripts/init-copilot-state.sh` on the host after initializing workspace/cache. It rejects unexpected files, weak permissions, known authentication files, auth-like settings, and GitHub token patterns. The container diagnostic repeats checks over mounted state, workspace, host cache, and the ephemeral Copilot runtime cache; the latter is checked for auth-like filenames and recognizable token strings. JSON schema files are excluded from auth-setting-key checks to avoid treating schema definitions as credentials. It never outputs matching contents. Remove only the identified credential artifact through the operator's secure process; do not make the entire Copilot home persistent to work around a failed check.
