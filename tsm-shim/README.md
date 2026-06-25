# configfs-tsm shim (run unmodified TDX attestation binaries)

Some programs request a TDX quote through the **standard Linux interfaces** —
`configfs-tsm` (`/sys/kernel/config/tsm/report/*`, with `inblob`/`outblob`) and a
`/dev/tdx-guest` device — rather than through the dstack SDK / guest-agent socket.
A stock dstack CVM doesn't expose those kernel interfaces to app containers, so
such binaries fail out of the box.

This example ships a small **sidecar** that bridges the gap: it re-exposes the
guest-agent's `GetQuote` RPC under the configfs-tsm file ABI. Your app writes
`report_data` to `inblob` and reads the raw Intel DCAP TDX quote from `outblob`,
exactly as against the kernel. No OS change, no FUSE, no privileged container; the
quote is the genuine hardware quote and `report_data` is forwarded byte-for-byte.

The image is built and published to GHCR by
[`build-tsm-shim.yml`](../.github/workflows/build-tsm-shim.yml):
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
`- tsm-report:/sys/kernel/config/tsm/report`. For production, pin the image by
digest (`ghcr.io/dstack-tee/dstack-tsm-shim@sha256:...`).

## How it works

`inblob`/`outblob` are **named pipes (FIFOs)** in a shared volume; a read of
`outblob` blocks until the quote is ready (configfs-tsm's write-then-read
contract). On an `inblob` write the shim `POST`s `/GetQuote` to
`/var/run/dstack.sock` and writes the quote to `outblob`. The image reports
healthy only once both FIFOs exist, so the app gates on `service_healthy`. An
**empty `outblob` read means the quote failed** (the shim logs why).

`/dev/tdx-guest` can't be created in another container from a sidecar, so an
empty volume is mounted there to satisfy the common "does the device exist?"
check (dstack permits mounting under `/dev`).

## Limitations

- Covers the **configfs-tsm `inblob`/`outblob`** path (used by `go-configfs-tsm`,
  recent `libtdx-attest`, etc.).
- Does **not** emulate the `/dev/tdx-guest` `TDX_CMD_GET_REPORT0` ioctl: it
  returns a raw, locally-MAC'd TDREPORT, which dstack doesn't expose and which
  can't be derived from a quote, so it isn't recoverable in userspace by any
  shim. Binaries that drive the device by ioctl are out of scope.
- **Single in-flight requester** per shim — the shared `inblob`/`outblob` pair
  can't correlate concurrent callers (the kernel gives each opener its own
  `report/<entry>/`; this doesn't). Run one shim per app; the shim rejects an
  `inblob` write larger than 64 bytes (a sign of racing writers) rather than
  return an ambiguous quote.
