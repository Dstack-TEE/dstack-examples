FROM debian:bookworm-slim@sha256:4b44499bc2a6c78d726f3b281e6798009c0ae1f034b0bfaf6a227147dcff928b

# Use a specific Debian snapshot for reproducible builds
RUN set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Install packages with exact versions for reproducibility
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
        docker.io=20.10.24+dfsg1-1+deb12u1 \
        docker-compose=1.29.2-3 \
        curl=7.88.1-10+deb12u12 \
        jq=1.6-2.1 \
        bash=5.2.15-2+b7 \
        coreutils=9.1-1 && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/log/* /var/cache/ldconfig/aux-cache

COPY entrypoint.sh get-latest.sh /scripts/
RUN chmod +x /scripts/*.sh
ENV PATH="/scripts:${PATH}"
RUN mkdir -p /app-data
CMD ["/scripts/entrypoint.sh"]
