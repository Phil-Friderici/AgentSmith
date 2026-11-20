# Scripts

`init-workspace.sh` creates and validates the host workspace and Level 1 cache directories. Run it as the normal host user before starting Compose:

```sh
bash scripts/init-workspace.sh
```

Set `AGENTFORGE_WORKSPACE` and `AGENTFORGE_CACHE` first to override the defaults. The script refuses paths inside or overlapping the AgentForge source tree, does not recursively change ownership, and fails if an existing directory is owned by someone else or is not writable. It does not create, copy, or inspect secrets.

Future scripts should:

- Be narrowly scoped and safe to rerun where practical.
- Fail explicitly instead of silently weakening security or substituting success-shaped defaults.
- Avoid printing credentials, authenticated URLs, or secret-bearing file contents.
- Validate inputs and clearly state any host-side effects.
- Follow the permission model and never bypass an operator approval boundary.

The image runs `agentforge-doctor` at workstation startup. It checks the pinned Ruby, Bundler, PDK, and Copilot toolchain, profile mounts, and protected paths for known authentication artifacts; it never prints authentication files or matched content. The `agentforge-puppet` in-container command provides module bootstrap, project-scoped Bundler installation, PDK validation, and unit-test workflows. Keep privileged host operations separate from routine in-container development.

`init-copilot-state.sh` creates and validates the separate `~/AgentForge/state/copilot` path. It permits only `settings.json`, `session-state/`, and `session-store.db`, enforces owner-only permissions, rejects overlap with the repository/workspace/cache, and runs the artifact checker without printing matching content. `test-copilot-storage-check.sh` exercises the fail-closed checks using synthetic test data only. `test-puppet-workflow.sh` uses mocked PDK/Ruby/Bundler commands to verify workflow dispatch, pinned versions, module cache separation, and Ruby selector enforcement without accessing external repositories. `test-github-wrapper.sh` runs the Level 1 wrapper against a mocked GitHub CLI in a network-isolated container and checks allowlist, command, and environment policy without authentication or API calls. `test-github-auth.sh` uses a synthetic PAT and mocked GitHub CLI to check hidden input, mode 0600, wrapper forwarding, diagnostics non-disclosure, clear behavior, and cleanup after container recreation; it makes no GitHub requests.

ADR-0005 rejects persistent Copilot authentication. A host keyring launcher, token broker, D-Bus/keyring integration, authentication backup/recovery scripts, and persistent auth volume are unnecessary and must not be added.
