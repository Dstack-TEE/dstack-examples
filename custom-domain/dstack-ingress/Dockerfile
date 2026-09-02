FROM haproxy@sha256:49a0a0d6f0b8b7e59c233b06eefab1564f2c8d64f673554d368fd7d2ab4b2c2d

# haproxy image runs as non-root (uid 99) by default; we need root for
# certbot, DNS management, and writing to /etc/haproxy/certs.
USER root

RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Create preferences file to pin all packages
    rm -rf /etc/apt/sources.list.d/debian.sources && \
    mkdir -p /etc/apt/preferences.d && \
    cat /tmp/pinned-packages.txt | while read line; do \
        pkg=$(echo $line | cut -d= -f1); \
        ver=$(echo $line | cut -d= -f2); \
        if [ ! -z "$pkg" ] && [ ! -z "$ver" ]; then \
            echo "Package: $pkg\nPin: version $ver\nPin-Priority: 1001\n" >> /etc/apt/preferences.d/pinned-packages; \
        fi; \
    done && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        openssl \
        bash \
        python3-pip \
        python3-requests \
        python3.11 \
        python3.11-venv \
        curl \
        jq \
        coreutils \
        mini-httpd && \
        rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

# lego, for the tls-alpn-01 challenge. certbot cannot do tls-alpn-01: its
# standalone plugin is HTTP-01 only and the acme library removed the challenge
# in 4.2.0. Pinned by checksum so the build stays reproducible; bump both the
# version and the digest together.
ARG LEGO_VERSION=5.3.1
ARG LEGO_SHA256=b3c71b122ee1947eacfe0b809b955647f6377239fe4bfc49f73b1a091ae1252a
RUN set -eu; \
    url="https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz"; \
    curl -fsSL -o /tmp/lego.tar.gz "$url"; \
    echo "${LEGO_SHA256}  /tmp/lego.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/lego.tar.gz -C /usr/local/bin lego; \
    rm -f /tmp/lego.tar.gz; \
    chmod 755 /usr/local/bin/lego; \
    touch -d @0 /usr/local/bin/lego; \
    lego --version

RUN mkdir -p \
    /etc/letsencrypt \
    /var/www/certbot \
    /etc/haproxy/certs \
    /var/run/haproxy \
    /var/lib/haproxy \
    /evidences

# Install the complete Python runtime during the image build.  Runtime
# installation from PyPI would leave certbot (which handles TLS private keys)
# outside the measured image.  Keep versions explicit; update this list only
# together with a new image build and digest.
# Normalize the mode so the image digest does not depend on the checkout umask.
COPY --chmod=644 requirements.txt /tmp/requirements.txt
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONHASHSEED=0 \
    SOURCE_DATE_EPOCH=0
RUN python3 -m venv /opt/app-venv && \
    /opt/app-venv/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.txt && \
    rm -rf /root/.cache/pip /tmp/requirements.txt && \
    # Normalize files created by wheel installers for reproducible layers.
    find /opt/app-venv -type f -exec touch -d @0 {} + && \
    find /opt/app-venv -type d -exec touch -d @0 {} +

# Install scripts with deterministic permissions via bind mount
RUN --mount=type=bind,source=scripts,target=/tmp/scripts,ro \
    /bin/bash -o pipefail -c 'set -euo pipefail; \
        rm -rf /scripts && mkdir -p /scripts && chmod 755 /scripts && \
        cd /tmp/scripts && \
        find . -type d -print0 | while IFS= read -r -d "" dir; do \
            rel="${dir#./}"; \
            [[ -z "$rel" ]] && continue; \
            install -d -m 755 "/scripts/$rel"; \
        done && \
        find . -type f -print0 | while IFS= read -r -d "" file; do \
            rel="${file#./}"; \
            perm=644; \
            case "$rel" in \
                *.sh) perm=755 ;; \
                *.py) case "$rel" in */*) perm=644 ;; *) perm=755 ;; esac ;; \
            esac; \
            install -m "$perm" "$file" "/scripts/$rel"; \
        done'

ENV PATH="/scripts:$PATH"
ENV PYTHONPATH="/scripts"
ENV PYTHONUNBUFFERED=1
COPY --chmod=666 .GIT_REV /etc/

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["haproxy", "-W", "-f", "/etc/haproxy/haproxy.cfg"]
