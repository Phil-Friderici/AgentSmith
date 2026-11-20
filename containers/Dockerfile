# syntax=docker/dockerfile:1.7

FROM ubuntu@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5 AS workstation-base

ARG DEBIAN_FRONTEND=noninteractive

# Extract only public APT source/key files; do not install the release package's auth.conf file.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates=20260816ubuntu0.24.04.2 \
        curl=8.5.0-2ubuntu10.16 \
        git=1:2.43.0-1ubuntu7.4 \
        ruby3.2=3.2.3-1ubuntu0.24.04.8 \
    && curl --fail --location --silent --show-error \
        --output /tmp/puppet8-release-noble.deb \
        https://apt-puppetcore.puppet.com/public/puppet8-release-noble.deb \
    && printf '%s  %s\n' b031bc2761808f9800d5dc98d1b3655ccb53802ba7f6a2e58fa4b473100ba4d9 /tmp/puppet8-release-noble.deb | sha256sum --check - \
    && mkdir -p /etc/apt/keyrings /etc/apt/preferences.d /etc/apt/sources.list.d \
    && dpkg-deb --fsys-tarfile /tmp/puppet8-release-noble.deb | tar -xOf - ./etc/apt/keyrings/puppet-keyring.gpg > /etc/apt/keyrings/puppet-keyring.gpg \
    && dpkg-deb --fsys-tarfile /tmp/puppet8-release-noble.deb | tar -xOf - ./etc/apt/sources.list.d/puppet8-release.list > /etc/apt/sources.list.d/puppet8-release.list \
    && printf 'Package: puppet-agent\nPin: version *\nPin-Priority: -1\n' > /etc/apt/preferences.d/agentforge-no-unpinned-puppet-agent.pref \
    && mkdir -p /etc/apt/auth.conf.d \
    && rm -f /tmp/puppet8-release-noble.deb \
    && rm -rf /var/lib/apt/lists/*

RUN gem install bundler --no-document --version 2.4.20 \
    && bundle --version | grep --fixed-strings --line-regexp "Bundler version 2.4.20"

FROM workstation-base AS copilot-runtime

ARG NODE_VERSION=22.23.5
ARG TARGETARCH

RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) node_arch=x64; node_sha256=c54118104acc524633b5abe106bbf44a53126ec8b4e5fa105cb92b5d7de8a1a1 ;; \
        arm64) node_arch=arm64; node_sha256=8bd3dc69eee8f3f226315a80d7d1d4faccf217a4c8fae500168ac2e38f3bdba3 ;; \
        *) printf 'Unsupported Node.js build architecture: %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    archive="/tmp/node-v${NODE_VERSION}-linux-${node_arch}.tar.gz"; \
    curl --fail --location --silent --show-error \
        --output "$archive" \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.gz"; \
    printf '%s  %s\n' "$node_sha256" "$archive" | sha256sum --check -; \
    mkdir -p /opt/node; \
    tar -xzf "$archive" --strip-components=1 -C /opt/node; \
    rm -f "$archive"

COPY copilot/package.json copilot/package-lock.json /opt/copilot/
ENV PATH="/opt/node/bin:/opt/copilot/node_modules/.bin:${PATH}" \
    COPILOT_AUTO_UPDATE=false

RUN /opt/node/bin/npm ci \
        --prefix /opt/copilot \
        --omit=dev \
        --ignore-scripts \
        --no-audit \
        --no-fund \
    && node --version | grep --fixed-strings --line-regexp "v${NODE_VERSION}" \
    && test "$COPILOT_AUTO_UPDATE" = false \
    && copilot --version | grep --fixed-strings --line-regexp "GitHub Copilot CLI 1.0.112."

FROM workstation-base AS pdk-package

RUN --mount=type=secret,id=puppet_repo_credentials,target=/etc/apt/auth.conf.d/puppet.conf,required=true \
    apt-get update -qq \
    && cd /tmp \
    && apt-get download pdk=4.0.1.1-1noble \
    && set -- /tmp/pdk_*.deb \
    && test -f "$1" \
    && mv "$1" /tmp/pdk.deb \
    && rm -rf /var/lib/apt/lists/*

FROM workstation-base AS workstation

COPY --from=copilot-runtime /opt/node /opt/node
COPY --from=copilot-runtime /opt/copilot /opt/copilot
COPY --from=pdk-package /tmp/pdk.deb /tmp/pdk.deb
RUN dpkg -i /tmp/pdk.deb \
    && pdk --version | grep --fixed-strings --line-regexp "4.0.1" \
    && rm -f /tmp/pdk.deb

# Issue #1: select UTF-8 so Ruby and PDK metadata validation handle UTF-8 data by default.
ENV PATH="/opt/node/bin:/opt/copilot/node_modules/.bin:${PATH}" \
    COPILOT_AUTO_UPDATE=false \
    LANG=C.UTF-8

COPY --chmod=0555 workstation-entrypoint.sh /usr/local/bin/workstation-entrypoint
COPY --chmod=0555 agentforge-doctor.sh /usr/local/bin/agentforge-doctor
COPY --chmod=0555 copilot-storage-check.sh /usr/local/bin/copilot-storage-check
COPY --chmod=0555 agentforge-puppet.sh /usr/local/bin/agentforge-puppet

WORKDIR /workspace

USER 1000:1000

ENTRYPOINT ["/usr/local/bin/workstation-entrypoint"]
CMD ["bash"]

FROM workstation AS workstation-level1

USER root

ARG TARGETARCH

RUN set -eu; \
    gh_version=2.105.0; \
    case "$TARGETARCH" in \
        amd64) gh_arch=amd64; gh_sha256=1dac939af3e84fb3861927c984b357531341be9403b889e4aa86e8822145a09d ;; \
        arm64) gh_arch=arm64; gh_sha256=d17e9b089ce0356679c9fa1898f3a7d38dccf943d529acaa94c24e8a4584e0ae ;; \
        *) printf 'Unsupported GitHub CLI build architecture: %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    package="/tmp/gh_${gh_version}_${gh_arch}.deb"; \
    curl --fail --location --silent --show-error \
        --output "$package" \
        "https://cli.github.com/packages/pool/main/g/gh/gh_${gh_version}_${gh_arch}.deb"; \
    printf '%s  %s\n' "$gh_sha256" "$package" | sha256sum --check -; \
    dpkg -i "$package"; \
    installed_version="$(gh --version | sed -n '1s/^gh version //p' | cut -d' ' -f1)"; \
    test "$installed_version" = "$gh_version"; \
    rm -f "$package"

RUN install -d -m 0755 /etc/agentforge

COPY --chmod=0444 github-allowlist.yml /etc/agentforge/github-allowlist.yml
COPY --chmod=0555 agentforge-gh /usr/local/bin/agentforge-gh
COPY --chmod=0555 agentforge-gh-auth /usr/local/bin/agentforge-gh-auth
COPY --chmod=0444 agentforge-gh-auth-lib.rb /usr/local/lib/agentforge-gh-auth.rb

USER 1000:1000

FROM workstation AS workstation-default

FROM ubuntu@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5 AS maintainer-broker

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ruby3.2=3.2.3-1ubuntu0.24.04.9 \
    && rm -rf /var/lib/apt/lists/*

COPY maintainer-broker/ /opt/agentforge/maintainer-broker/
RUN chown -R root:root /opt/agentforge/maintainer-broker \
    && chmod 0555 /opt/agentforge/maintainer-broker/bin/maintainer-broker \
    && find /opt/agentforge/maintainer-broker/lib -type f -exec chmod 0444 {} +

WORKDIR /
USER 65532:65532
ENTRYPOINT ["/usr/bin/ruby3.2", "/opt/agentforge/maintainer-broker/bin/maintainer-broker"]
CMD ["--self-check"]
