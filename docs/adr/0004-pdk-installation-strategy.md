# ADR-0004: PDK Installation Strategy

## Status

Accepted and Validated

## Context

AgentForge requires Puppet Development Kit (PDK) 4.0.1.

Access to Puppet package repositories requires credentials that:

- are managed outside the repository
- must never be committed to Git
- must never be embedded in source code
- must never be exposed in runtime development sessions

The original architecture preferred runtime installation using mounted credentials.

During implementation review, a security concern was identified:

- privileged installation containers had access to writable workspace mounts
- Puppet repository credentials were available during installation
- installed toolchains were not persistent across container recreation
- runtime sessions retained access to secret mounts

This model did not sufficiently separate privileged installation from normal development work.

## Decision

AgentForge will install PDK during image build using BuildKit secrets.

The Puppet repository credential will be supplied only to the build step that requires access to protected Puppet package repositories.

The Dockerfile will download the pinned PDK Debian package while the BuildKit secret is mounted as the APT auth file, then install the downloaded package in a separate stage where the secret is unavailable. The final image includes PDK 4.0.1 (`4.0.1.1-1noble`) but not the credential. Runtime Compose services do not declare the secret.

The credential must:

- never be passed via ARG
- never be passed via ENV
- never be copied into image layers
- never be written to logs intentionally

Development containers must never receive Puppet repository credentials.

PDK will be present in the resulting image and available immediately when development containers start.

## Alternatives Considered

### Option A: Runtime installation with mounted credentials

Rejected.

Reasons:

- privileged installer had access to writable workspace mounts
- runtime secret exposure risk
- repeated installation required after container recreation

### Option B: Isolated runtime installer that publishes an image

Rejected.

Reasons:

- less reproducible
- operationally more complex
- image creation process harder to audit

### Option C: BuildKit secrets during image build

Accepted.

Reasons:

- credential-free runtime containers
- persistent toolchain
- simpler operational model
- clear separation between installation and development phases
- reproducible builds

## Consequences

### Positive

- Development containers do not require Puppet credentials.
- PDK persists across container recreation.
- Faster startup times.
- Reduced operational complexity.
- Stronger separation of duties.

### Negative

- Rebuilding the development image requires access to Puppet repository credentials.
- Trust is placed in package installation scripts executed during image build.
- Build logs and resulting image layers must be validated to ensure secrets are not exposed.

## Follow-up Actions

- Validate actual PDK installation using production credentials.
- Validate APT authentication file handling.
- Validate build logs for secret exposure.
- Validate image layers for secret leakage.
- Record the Puppet Agent version required by the supported target module. PDK 4.0.1 itself has no declared Puppet Agent package dependency; Agent installation remains deferred until a module runtime requirement is established.
- Pin Bundler 2.4.20 with Ruby 3.2.3 and validate the module workflow in the completed image.
- Document rebuild and upgrade procedures.

## Validation

Validated on 2026-11-18.

Results:

- BuildKit secret consumption verified.
- PDK 4.0.1 installation verified.
- Runtime image contains no Puppet repository credentials.
- No credentials detected in image layers.
- No credentials detected in build output.
- Runtime diagnostics passed.

