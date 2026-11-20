FROM docker.io/library/ruby@sha256:9ee6e94ab254ec61fd08472976a8d0a04d9745de76e9768ccd33f0b7d2fd1be9 AS dependencies

WORKDIR /opt/puppet
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --no-document --version 2.4.20 \
    && bundle _2.4.20_ config set --local path /opt/puppet/vendor/bundle \
    && bundle _2.4.20_ install --deployment --jobs 4 --retry 3 \
    && rm -rf /root/.bundle /root/.cache

FROM docker.io/library/ruby@sha256:0d7326044980c6c4707af9a4de7c441df38794d35ca8e69eebc84983c578646b

WORKDIR /opt/puppet
COPY --from=dependencies /opt/puppet/Gemfile /opt/puppet/Gemfile
COPY --from=dependencies /opt/puppet/Gemfile.lock /opt/puppet/Gemfile.lock
COPY --from=dependencies /opt/puppet/vendor/bundle /opt/puppet/vendor/bundle
RUN gem install bundler --no-document --version 2.4.20 \
    && printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'cd /opt/puppet' \
        'exec bundle exec puppet "$@"' \
        > /usr/local/bin/puppet \
    && chmod 0755 /usr/local/bin/puppet \
    && rm -rf /root/.bundle /root/.cache

ENV BUNDLE_PATH=/opt/puppet/vendor/bundle
ENV LANG=C.UTF-8
CMD ["sleep", "infinity"]
