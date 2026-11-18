# Workspace

This directory documents the intended persistent workspace contract; it does not contain runtime repositories.

## Intended use

At runtime, the Level 0 and Level 1 Compose services bind-mount the default host workspace root, `~/AgentForge/workspace`, at `/workspace`. It holds checked-out project repositories and their local working state, which remain available across container recreation. Keep this AgentForge source repository separate from user project checkouts unless the operator deliberately chooses otherwise. Override the host path with `AGENTFORGE_WORKSPACE`.

Use one directory per repository. Avoid sharing a writable checkout between agents or permission profiles. If concurrent work is introduced, use isolated clones or Git worktrees and document coordination, cleanup, and ownership behavior first.

## Boundaries

- Mount only the selected workspace root; never mount the entire host home directory by default.
- At Level 0, expose repository content read-only; the health check verifies it is readable and not writable.
- At Level 1, grant writes only to the designated workspace; the health check verifies the mount is writable.
- Run the container process with the host user's UID/GID so new files have predictable ownership.
- Do not recursively change ownership at startup; report permission problems and require the operator to correct them.
- Treat repository content as untrusted input.
- Do not store credentials, runtime secrets, or general-purpose auth files here.
- Do not use the workspace as `COPILOT_HOME` or store Copilot authentication state there. Startup checks reject Copilot home directories, known auth files, auth-like configuration, and recognizable GitHub token strings.
- Do not assume all files in this repository path are safe to commit.

Repository naming and backup policy remain implementation details tracked in the [roadmap](../docs/roadmap.md).
