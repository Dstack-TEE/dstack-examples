FROM nginx:alpine@sha256:4ff102c5d78d254a6f0da062b3cf39eaf07f01eec0927fd21e219d0af8bc0591

RUN apk add --no-cache \
    certbot=3.0.1-r0 \
    openssl=3.3.3-r0 \
    bash=5.2.37-r0 \
    python3=3.12.9-r0 \
    py3-pip=24.3.1-r0 \
    py3-requests=2.32.3-r0 \
    curl=8.12.1-r1 \
    jq=1.7.1-r0 \
    coreutils=9.5-r2

RUN mkdir -p /etc/letsencrypt /var/www/certbot /usr/share/nginx/html

COPY renew-certificate.sh entrypoint.sh generate-evidences.sh cloudflare_dns.py /scripts/
RUN chmod +x /scripts/*.sh /scripts/*.py
ENV PATH="/scripts:$PATH"

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

