# Ubuntu 24.04 (noble) multi-arch manifest digest, resolved on 2026-05-11.
# Bump the tag and digest together when refreshing the base.
FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        git \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY bin/git-launcher /usr/local/bin/git-launcher
RUN chmod 0755 /usr/local/bin/git-launcher

ENTRYPOINT ["git-launcher"]
