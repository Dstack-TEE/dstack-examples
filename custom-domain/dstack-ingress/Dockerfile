FROM nginx@sha256:b6653fca400812e81569f9be762ae315db685bc30b12ddcdc8616c63a227d3ca

COPY pinned-packages.txt /tmp/

RUN set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Create preferences file to pin all packages
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
        certbot \
        openssl \
        bash \
        python3-pip \
        python3-requests \
        python3.11 \
        python3.11-venv \
        curl \
        jq \
        coreutils && \
        rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache /tmp/pinned-packages.txt

RUN mkdir -p /etc/letsencrypt /var/www/certbot /usr/share/nginx/html

COPY ./scripts/* /scripts/
RUN chmod +x /scripts/*
ENV PATH="/scripts:$PATH"
COPY .GIT_REV /etc/

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

