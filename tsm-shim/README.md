# configfs-tsm shim (run unmodified TDX attestation binaries)

Some programs request a TDX quote through the **standard Linux interfaces** —
`configfs-tsm` (`/sys/kernel/config/tsm/report/*`, with `inblob`/`outblob`) and a
`/dev/tdx-guest` device — rather than through the dstack SDK / guest-agent
socket. On a stock dstack CVM those kernel interfaces aren't exposed to app
containers, so such binaries fail out of the box.

This example ships a small **sidecar** that bridges the gap. It re-exposes the
guest-agent's `GetQuote` RPC under the configfs-tsm file ABI: your app writes
`report_data` to `inblob` and reads the raw Intel DCAP TDX quote from `outblob`,
exactly as it would against the kernel.

- **No OS change** — pure userspace, runs in a normal container.
- **No FUSE, no `CAP_SYS_ADMIN`, no privileged mode, no device passthrough.**
- **No weaker attestation** — the quote is the genuine hardware quote and
  `report_data` is forwarded byte-for-byte.

The shim image is built and published to GHCR by
[`.github/workflows/build-tsm-shim.yml`](../.github/workflows/build-tsm-shim.yml):
`ghcr.io/dstack-tee/dstack-tsm-shim`.

## Try it

```bash
phala deploy -n tsm-shim-example -c docker-compose.yaml
phala cvms logs <app_id> -c app
```

Expected `app` log:

```
quote length : 5010 bytes
quote header : 0400 (a TDX v4 quote starts with 0400)
report_data bound in quote: True
PASS - unmodified configfs-tsm app got a real TDX quote via the shim
```

## Adopt it in your app

Add the `tsm-shim` service and two volumes, then add the four lines marked `(+)`
to your existing service:

```yaml
services:
  tsm-shim:
    image: ghcr.io/dstack-tee/dstack-tsm-shim:latest
    restart: unless-stopped
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - tsm-report:/run/tsm/report

  my-app:
    image: your-app:latest
    # ... your existing config ...
    depends_on:
      tsm-shim:
        condition: service_healthy          # (+) wait until the shim is ready
    environment:
      - TSM_REPORT_PATH=/run/tsm/report      # (+) point your app at the shim dir
    volumes:
      - tsm-report:/run/tsm/report           # (+) see the shim's inblob/outblob
      - tsm-devstub:/dev/tdx-guest           # (+) satisfy /dev/tdx-guest checks

volumes:
  tsm-report: {}
  tsm-devstub: {}
```

If your binary **hard-codes** `/sys/kernel/config/tsm/report`, mount the shared
volume there instead of using `TSM_REPORT_PATH`:

```yaml
    volumes:
      - tsm-report:/sys/kernel/config/tsm/report
```

For production, pin the image by digest (e.g.
`ghcr.io/dstack-tee/dstack-tsm-shim:latest@sha256:...`).

## How it works

`tsm-shim` exposes `inblob` and `outblob` as **named pipes (FIFOs)** in a shared
volume. A read of `outblob` blocks until the quote for the most recent `inblob`
write is ready — which matches configfs-tsm's write-then-read contract with no
race and no privileges. When `inblob` is written, the shim calls
`POST /GetQuote` on `/var/run/dstack.sock` and writes the returned quote to
`outblob`. The image reports healthy only once both FIFOs exist, so the app can
gate on `depends_on: { condition: service_healthy }`.

The `/dev/tdx-guest` device can't be created inside another container from a
sidecar, so an empty volume is mounted at that path — enough for the common
"does the device exist?" check. (dstack permits mounting under `/dev`.)

## Files

| File | Purpose |
|------|---------|
| `tsm_shim.py` | the sidecar daemon (pure Python stdlib, no dependencies) |
| `demo-app.py` | a stand-in unmodified configfs-tsm consumer (bundled self-test) |
| `Dockerfile` | builds the published image |
| `docker-compose.yaml` | the shim + demo app wired together |

## Limitations

- Covers the **configfs-tsm `inblob`/`outblob`** path (used by `go-configfs-tsm`,
  recent `libtdx-attest`, etc.).
- Does **not** emulate the `/dev/tdx-guest` `TDX_CMD_GET_REPORT0` ioctl. That
  returns a raw, locally-MAC'd TDREPORT, which dstack does not expose and which
  can't be derived from a quote — so it isn't recoverable in userspace by any
  shim. Binaries that drive the device by ioctl rather than configfs are out of
  scope.
- One quote at a time per shim instance (matches the kernel's single
  configfs-tsm entry). Run one shim per app.
