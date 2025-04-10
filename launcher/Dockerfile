FROM alpine@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c

RUN apk add --no-cache \
    docker=27.3.1-r4 \
    docker-cli-compose=2.31.0-r4 \
    curl=8.12.1-r1 \
    jq=1.7.1-r0 \
    bash=5.2.37-r0 \
    coreutils=9.5-r2

COPY entrypoint.sh get-latest.sh /scripts/
RUN chmod +x /scripts/*.sh
ENV PATH="/scripts:${PATH}"
RUN mkdir -p /app-data
CMD ["/scripts/entrypoint.sh"]
