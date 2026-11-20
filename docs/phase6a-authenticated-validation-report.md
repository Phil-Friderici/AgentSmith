# Phase 6a Authenticated Read-Only Validation

- Date: 2026-11-20
- Status: Authenticated end-to-end validation completed for available repository metadata

## Scope and authentication

Validated the allowlisted repositories:

- `Phil-Friderici/puppetlabs-mysql`
- `Phil-Friderici/puppetlabs-concat`

The operator entered the fine-grained PAT at the hidden `agentforge-gh-auth store` prompt and confirmed `agentforge-gh-auth status`. The token value was not requested in chat, copied to host storage, or emitted by the validation commands. The operator specified that the PAT is read-only and repository-scoped; those GitHub permission settings were not independently inspected.

## Command results

| Command | `puppetlabs-mysql` | `puppetlabs-concat` |
|---|---|---|
| `repo view` | Succeeded | Succeeded |
| `issue list` | Issues are disabled for the repository | Issues are disabled for the repository |
| `issue view` | Not run; issues are disabled | Not run; issues are disabled |
| `pr list` | Succeeded; no pull requests returned | Succeeded; no pull requests returned |
| `pr view` | Not run; no pull requests returned | Not run; no pull requests returned |
| `release view` | No accessible release found | No accessible release found |

The issue/release errors reflect repository settings or absent data, not authentication or wrapper rejection. No issue, pull request, or release records were available for view commands.

The wrapper denied non-allowlisted repositories, URL and wildcard repository forms, `gh api`, `gh workflow`, `gh extension`, `gh secret`, issue creation, PR creation, and PR merge. The mock regression test confirms denied commands are rejected before invoking GitHub CLI; no live write operation was issued.

## Security validation

- PAT status reported only presence and local storage validity.
- PAT file was owner-readable only (mode 0600) under `/tmp/agentforge-gh` on tmpfs; `GH_CONFIG_DIR` remained `/tmp/agentforge-gh/config`.
- No `hosts.yml` was created, and no PAT value appeared in GitHub CLI configuration.
- The Compose container had a read-only root filesystem, dropped all capabilities, `no-new-privileges`, no devices or port bindings, and no host mount for `/tmp`.
- Exact in-container comparisons found no PAT value in repository-view output, container logs, status/diagnostic output, temporary files outside the PAT file, GitHub configuration, workspace, cache, or Copilot state mounts.
- After stopping/removing the authenticated container, a new Level 1 container reported `PAT not stored`.
- No write-capable GitHub command or direct `gh` command was run. No ADR was changed.

## Recommendation

**A. Phase 6a is complete for the two allowlisted repositories and metadata available during this validation.** Authenticated repository retrieval and read-only wrapper enforcement succeeded. Issues are disabled and no pull requests or releases exist in these repositories, so the corresponding list/view commands had no records to return. No additional implementation or ADR revision is indicated.

The PAT's actual fine-grained permissions and repository scope remain based on the operator's statement; validate those settings in GitHub whenever the PAT is created or changed.
