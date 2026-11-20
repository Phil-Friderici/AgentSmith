# Phase 6a Public Repository Validation

- Date: 2026-11-20
- Status: Blocked by GitHub CLI authentication requirements

## Scope and controls

The Level 1 image was rebuilt with the repository allowlist set exactly to:

```yaml
github:
  allowed_repositories:
    - Phil-Friderici/puppetlabs-mysql
    - Phil-Friderici/puppetlabs-concat
```

Validation used GitHub CLI 2.105.0 through `agentforge-gh`. No GitHub login, token, or credential was supplied. The Level 1 Compose service contains no GitHub credentials or runtime secrets. A non-credential `GH_HOST` override and `GH_REPO` override were provided during a live invocation. The wrapper's clean environment strips those values; the CLI then stopped at its authentication check before target routing could be confirmed.

## Results

For both allowlisted repositories, each requested top-level metadata command reached GitHub CLI but exited with status 4 before returning metadata:

| Command | Result |
|---|---|
| `repo view OWNER/REPO` | Blocked; CLI requested `gh auth login` or `GH_TOKEN` |
| `issue list OWNER/REPO` | Blocked; same authentication-required result |
| `pr list OWNER/REPO` | Blocked; same authentication-required result |
| `release view OWNER/REPO` | Blocked; same authentication-required result |

The CLI output was: `To get started with GitHub CLI, please run: gh auth login` and `Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.` No token was provided. Issue and pull-request view commands were skipped because the list commands returned no issue or pull-request numbers. No repository contents, issue data, pull-request data, or release data were retrieved; repository existence and release availability therefore remain unverified.

The command translations are compatible with GitHub CLI 2.105.0 according to its local help output, and the wrapper's mocked tests verify the exact generated arguments. Live retrieval did not get far enough to validate endpoint or repository compatibility.

## Negative and security checks

- A repository outside the allowlist was denied by the wrapper.
- URL and wildcard repository forms were rejected.
- `api`, `workflow`, `extension`, `secret`, issue-write, and pull-request-write commands were rejected before invoking GitHub CLI.
- No token environment variables were present in the Level 1 startup diagnostic.
- After the unauthenticated request, `/tmp/agentforge-gh/config` contained no files and no `hosts.yml` authentication state.
- A non-authentication sentinel placed in the config tmpfs disappeared after container recreation; the new container's startup diagnostic confirmed empty GitHub configuration.
- No GitHub credentials were used, and no ADR was modified.

## Findings and recommendation

The allowlist and wrapper restrictions behave as designed, but the assumption that these `gh` metadata commands can retrieve public metadata without authentication is incorrect for the pinned GitHub CLI in this environment. With the no-auth/no-token requirement, public Phase 6a metadata retrieval is not complete. Supporting that requirement needs a separately approved unauthenticated retrieval design; this validation did not replace GitHub CLI with another API client or add authentication.

**Recommendation: C — GitHub CLI assumptions were incorrect.**
