FROM nginx@sha256:b6653fca400812e81569f9be762ae315db685bc30b12ddcdc8616c63a227d3ca

# Use a specific Debian snapshot for reproducible builds
RUN set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Install packages with exact versions for reproducibility
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
        certbot=2.1.0-4 \
        openssl=3.0.15-1~deb12u1 \
        bash=5.2.15-2+b7 \
        python3=3.11.2-1+b1 \
        python3-pip=23.0.1+dfsg-1 \
        python3-requests=2.28.1+dfsg-1 \
        python3.11-venv=3.11.2-6+deb12u5 \
        curl=7.88.1-10+deb12u12 \
        jq=1.6-2.1 \
        coreutils=9.1-1 && \
        rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache


RUN mkdir -p /etc/letsencrypt /var/www/certbot /usr/share/nginx/html

COPY ./scripts/* /scripts/
RUN chmod +x /scripts/*
ENV PATH="/scripts:$PATH"

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

