# Pure stdlib — no pip, no build deps. Built & pushed to GHCR by
# .github/workflows/build-tsm-shim.yml.
FROM python:3.12-slim

LABEL org.opencontainers.image.title="dstack-tsm-shim"
LABEL org.opencontainers.image.description="configfs-tsm compatibility shim: re-exposes dstack guest-agent GetQuote as inblob/outblob FIFOs"
LABEL org.opencontainers.image.source="https://github.com/Dstack-TEE/dstack-examples"

COPY tsm_shim.py /usr/local/bin/tsm_shim.py
COPY demo-app.py /usr/local/bin/demo-app.py

ENV TSM_REPORT_DIR=/run/tsm/report \
    DSTACK_SOCKET=/var/run/dstack.sock

# Report healthy only once both FIFOs exist, so an app can gate on
# `depends_on: { tsm-shim: { condition: service_healthy } }` with no race.
HEALTHCHECK --interval=2s --timeout=2s --retries=30 --start-period=1s \
  CMD test -p "$TSM_REPORT_DIR/inblob" && test -p "$TSM_REPORT_DIR/outblob" || exit 1

# Default role is the shim daemon (reads TSM_REPORT_DIR / DSTACK_SOCKET from env).
ENTRYPOINT ["python3", "/usr/local/bin/tsm_shim.py"]
