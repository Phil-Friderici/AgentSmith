# Puppet Module Development

This guide defines the supported local workflow for Puppet module development in AgentForge. It uses the existing Level 1 workstation, exact image toolchain pins, and project-scoped Bundler caches. It does not add GitHub CLI authentication, Docker daemon access, MCP servers, runtime Puppet repository credentials, or persistent authentication.

## Supported toolchain and version strategy

| Component | Supported baseline | Policy |
| --- | --- | --- |
| Ruby | 3.2.3 | Exact system Ruby pin in the workstation image. New modules receive `.ruby-version` set to `3.2.3`; a conflicting module pin fails preflight. |
| Bundler | 2.4.20 | Exact version used for module dependency installation. |
| PDK | 4.0.1 | Exact image version. PDK-generated modules use the `pdk-default#4.0.1` template reference. |
| Puppet | Puppet 8 recommended major; PDK-managed Puppet is selected by PDK | `metadata.json` requirements and the module's locked Puppet gem version define each module's supported range. No system Puppet Agent is installed by default. |

The runtime image sets `LANG=C.UTF-8` so Ruby and PDK metadata validation use UTF-8 without per-command locale overrides. This addresses [Issue #1](https://github.com/Phil-Friderici/AgentSmith/issues/1): the minimal Ubuntu image otherwise leaves Ruby's default external encoding at US-ASCII, which breaks PDK's bundled metadata/SPDX validation.

PDK 4.0.1 has no declared Puppet Agent package dependency. Its managed Ruby and Puppet are separate from AgentForge's system Ruby: the pinned package reported Ruby 4.0.7 and Puppet 9.1.0 during real-module validation, while an earlier synthetic check reported Ruby 3.2.11 and Puppet 8.22.0. These are PDK-managed execution versions, not workstation or system Puppet Agent pins. Record the versions reported by the installed PDK when diagnosing a module; do not assume they match the system Ruby or a prior PDK validation. If a module requires a system `puppet` executable or acceptance target, stop and establish its exact Puppet Agent package version before adding it to the image. Install it only through the ADR-0004 BuildKit-secret image build and keep the APT preference against unpinned Agent packages.

Use the module's `metadata.json` Puppet requirement as the compatibility contract. Puppet 8 is the recommended baseline; PDK's managed Puppet version is separate and has varied between observed PDK executions. For multi-major support, declare the intended range and test the module's Puppet gem against each supported version through its lockfile or an explicit PDK `--puppet-version=<exact-version>` argument. Do not infer support from the image's Puppet 8 repository metadata alone.

## Start a session

Use Level 1 for module changes, dependency installation, validation, and unit tests:

```sh
docker compose -f compose/compose.yaml --profile level1 run --rm agent-level1
```

The workspace is mounted at `/workspace`; the project cache is mounted at `/cache`. The container has no GitHub CLI authentication, Git remote write credentials, Puppet package credentials, Docker socket, or MCP servers. Do not paste credentials into prompts, Gemfiles, command arguments, or output that may be captured in session history.

## Bootstrap a module

Create a module from the PDK 4.0.1 default template:

```sh
agentforge-puppet bootstrap example_module
```

This creates `/workspace/example_module`, skips interactive prompts, uses the pinned `pdk-default#4.0.1` template, defaults to the `Apache-2.0` SPDX license, and writes `.ruby-version` as `3.2.3`. An optional license identifier can be supplied:

```sh
agentforge-puppet bootstrap example_module MIT
```

The target must not already exist. PDK may need Level 1 network access to retrieve its public module template. Bootstrap does not install dependencies; PDK prepares its own dependencies when you run `validate` or `unit`. The separate system-Ruby bundle workflow is optional and is only needed for direct `bundle exec` use.

## Recommended fork workflow

1. Create a fork through the GitHub web interface using the operator's normal browser session; do not add GitHub CLI authentication to AgentForge.
2. Clone a public fork into `/workspace` with its HTTPS URL. Add the public upstream repository as a second, read-only remote if needed.
3. Create a local topic branch, make changes, run the validation and unit-test commands below, and create local commits at Level 1.
4. Do not push or create a pull request from AgentForge. Remote writes are Level 2 capabilities and are not implemented. Publish the branch and open a pull request only through a separately approved workflow.

Keep remote URLs free of embedded credentials. For private repositories, use an operator-approved provisioning process outside this workstation; private remote authentication is not part of this phase.

## Ruby and Bundler workflow

Check the image and module Ruby selection:

```sh
agentforge-puppet toolchain /workspace/example_module
```

The workflow requires Ruby 3.2.3, Bundler 2.4.20, PDK 4.0.1, and—when present—a matching `.ruby-version`. For existing modules without `.ruby-version`, the pinned image version is used and a warning is printed.

For direct `bundle exec` workflows only, install the optional system-Ruby bundle with:

```sh
agentforge-puppet bundle-install /workspace/example_module
```

The wrapper hashes the canonical module path and stores Bundler gems and package cache under a distinct `/cache/bundler/<module-id>/` directory. Bundler's application configuration is kept under `/tmp`, not in the repository or persistent cache. The Level 1 Compose cache root should be project- and trust-scoped as described in [Cache](../cache/README.md).

Commit or otherwise deliberately manage `Gemfile.lock` according to the module's contribution policy. When a lockfile exists, Bundler uses it; when absent, Bundler resolves dependencies and creates one. `agentforge-puppet bundle-install` is an optional system-Ruby bundle for direct `bundle exec` use; it is not a prerequisite for PDK commands. It writes the module's `Gemfile.lock` using the workstation Ruby/Bundler and can replace a lockfile produced by PDK's managed runtime. Do not run it before `validate` or `unit`; PDK manages its own dependency resolution and lockfile.

### PDK-managed dependency resolution

PDK's `validate` and `test unit` commands prepare a separate bundle using PDK's managed Ruby/Bundler. In the installed package, PDK reports Ruby 4.0.7, Puppet 9.1.0, and a managed Bundler 2.6.9; these are intentionally separate from AgentForge's system Ruby 3.2.3 and Bundler 2.4.20. PDK owns the module lockfile for this workflow and may use its packaged dependency cache. A successful lock can list PuppetCore as the source for Puppet/Bolt without using runtime credentials when the required gems are already available in that cache.

The earlier AgentForge `unit` wrapper ran `bundle-install` before `pdk test unit`. That system-Bundler install used the public-source setting and generated a Ruby 3.2/Puppet 8 lockfile. PDK then tried to resolve that lock under its Ruby 4/Puppet 9 environment; its clean child environment sets `BUNDLE_IGNORE_CONFIG=1`, so the public-source setting was not available during that re-resolution. This produced the PuppetCore authentication error. When a PDK-generated lock already existed, system Bundler could instead fail on the Bundler-version and source mismatch. The wrapper has been changed so `unit` invokes PDK without first running the standalone bundle install.

In a clean, credential-free run against `puppetlabs-concat` 10.1.0 at commit `77422279fe8fc02ac05add931511a51b135bccf3`, direct `pdk test unit` and `agentforge-puppet unit` both passed 254 examples. Direct `pdk validate` and `agentforge-puppet validate` produced the same 98 RuboCop convention findings and both exited 1; dependency resolution succeeded in both. The lint findings are module results, not a wrapper discrepancy.

Do not pass the standalone public-source configuration or PuppetCore credentials into PDK as a workaround. Keep PDK and standalone system-Bundler workflows separate, and investigate lockfile source/version state if a PDK command reports authentication or resolution failures.

## PDK validation and unit tests

Run static validation without auto-correcting files:

```sh
agentforge-puppet validate /workspace/example_module
```

PDK validators can be selected using PDK's normal arguments:

```sh
agentforge-puppet validate /workspace/example_module -- --parallel
```

Run unit tests:

```sh
agentforge-puppet unit /workspace/example_module
```

The unit workflow runs `pdk test unit` directly; PDK manages its own bundle and lockfile. Pass PDK unit-test options after `--` when needed. Use `bundle-install` separately only when a workflow explicitly requires the workstation Ruby bundle. These commands do not run Litmus, Beaker, acceptance tests, or a system Puppet Agent workflow. Acceptance testing is not currently supported; the proposed Phase 5 architecture and compatibility gates are in [Puppet Acceptance Testing Design](acceptance-testing.md).

## Recovery

- **Ruby/Bundler/PDK mismatch:** Stop the session and rebuild the image from the pinned Dockerfile. Do not install or upgrade these tools ad hoc in the container.
- **Dependency resolution or test failure:** Run `agentforge-puppet toolchain` first and inspect the module's Gemfile and lockfile. Run PDK commands directly through the wrapper; do not prepend `bundle-install`, since it writes a lockfile for the system Ruby/Bundler context. Keep diagnostic output free of credential values.
- **Corrupt Bundler cache:** Stop the container, rerun `bundle-install` to let Bundler repair/repopulate the module's cache, or remove only that module's exact `/cache/bundler/<module-id>` directory after verifying the path. Do not clear the shared host cache root or another module's cache.
- **Broken generated module:** Preserve or back up any edits, remove only the newly created module directory after resolving its exact path, then rerun `bootstrap`. Bootstrap refuses to overwrite an existing target.
- **Protected package/build failure:** Follow [Troubleshooting](troubleshooting.md). Do not copy Puppet credentials into the workspace, cache, image build context, or runtime.

The workspace is the source of truth for module files. Bundler caches are disposable; Copilot authentication, settings and session policy remain governed by ADR-0005.
