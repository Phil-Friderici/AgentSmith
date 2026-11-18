# ADR-0003: Puppet package source and PDK version

- Status: Accepted; runtime PDK installation partially superseded by [ADR-0004](0004-pdk-installation-strategy.md)
- Date: 2026-11-18
- Deciders: Project operator

## Context

Puppet package access requires credentials managed outside this repository. Local Docker Compose file-backed secrets ignore the configured `uid`, `gid`, and `mode`, so a safe setup must rely on host file permissions and ensure the interactive agent cannot read the credential. The operator supplied the PDK version and public Puppet 8 Noble APT source metadata and authorized inspection of the public release package only.

## Decision

- Pin the PDK package to version `4.0.1`.
- Configure the public Noble source `deb [signed-by=/etc/apt/keyrings/puppet-keyring.gpg] https://apt-puppetcore.puppet.com noble puppet8`.
- Pin the public `puppet8-release-noble.deb` bootstrap artifact to SHA-256 `b031bc2761808f9800d5dc98d1b3655ccb53802ba7f6a2e58fa4b473100ba4d9`.
- Extract only the APT source list and signing keyring into the base image. The key fingerprint is `D6811ED3ADEEB8441AF5AA8F4528B6CD9E61EF26`.
- Do not install the vendor release `.deb` as a package: its file list includes an APT auth file whose contents were not inspected and must not be embedded in the image.
- The public Puppet 8 Noble source, release-artifact hash, keyring, and PDK semantic version remain in effect. The runtime APT auth mount and privileged setup entrypoint are superseded by ADR-0004; use a BuildKit secret only for PDK package download.
- Defer Puppet Agent installation until an exact version is selected. An APT preference blocks accidental installation of an unpinned `puppet-agent` dependency.
- Do not mount the credential into the normal Level 0 or Level 1 service.

## Alternatives considered

- **Install the release `.deb` wholesale:** Rejected because it includes an APT auth file; its contents were not inspected and must not be copied into an image.
- **Trust Compose `uid`, `gid`, or `mode` settings:** Rejected because local Compose v5.7.1 warns that those attributes are ignored for file-backed secrets.
- **Give the interactive agent access to the credential:** Rejected because the credential must not be exposed through agent processes or chat.
- **BuildKit secret during image build:** Selected by ADR-0004 after implementation review found the runtime installer exposed privileged writable mounts and did not persist PDK across container recreation.

## Consequences

The base image includes public APT source/keyring metadata. Building the final PDK image requires the operator's external APT auth file through BuildKit, but the secret must not enter the final image. The PDK package fetch has not been run in this environment; its availability and APT auth format must be verified with an operator-authorized build. PDK 4.0.1 package metadata has no declared Puppet Agent dependency; Agent installation remains deferred until a module workflow establishes its version.

The recorded release-package hash was computed from the operator-approved public URL over HTTPS. It provides pinning for later builds but is trust-on-first-use, not an independently supplied vendor checksum.

## Security and operations

The former runtime-mount probe used only a dummy file; it did not validate private package access. ADR-0004 now requires checks of BuildKit output, image layers, final image contents, runtime configuration, and generated artifacts using operator-controlled credentials without displaying or copying secret contents.
