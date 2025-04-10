FROM alpine@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c

RUN apk add --no-cache \
    docker \
    docker-compose \
    curl \
    jq \
    bash \
    coreutils

COPY entrypoint.sh get-latest.sh /scripts/
RUN chmod +x /scripts/*.sh
ENV PATH="/scripts:${PATH}"
RUN mkdir -p /app-data
CMD ["/scripts/entrypoint.sh"]
