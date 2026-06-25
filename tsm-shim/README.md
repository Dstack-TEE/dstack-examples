# configfs-tsm shim

Some attestation binaries get their TDX quote through the kernel's `configfs-tsm`
files (`/sys/kernel/config/tsm/report/*` — write `inblob`, read `outblob`) instead
of the dstack SDK. dstack doesn't expose those files to containers, so they fail.

This sidecar bridges them: it serves one **fixed** `inblob`/`outblob` directory
from a shared volume and forwards each request to the guest-agent's `GetQuote`.
The quote is the real hardware quote (`report_data` passed through unchanged), so
a binary pointed at that directory works with only docker-compose changes — no OS
change, no FUSE, no privileged container. CI publishes the image to
`ghcr.io/dstack-tee/dstack-tsm-shim`.

## Use it

Add the sidecar, then point your app at it with the `(+)` lines:

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

If your binary hard-codes `/sys/kernel/config/tsm/report`, mount the volume there
instead of setting `TSM_REPORT_PATH`. For production, pin the image by digest.

## Try the demo

```bash
phala deploy -n tsm-shim-example -c docker-compose.yaml
phala cvms logs <app_id> -c app    # expect PASS and a ~5 KB quote
```

## Good to know

- Works for binaries pointed at a **fixed** report directory (write `inblob`, read
  `outblob`, no `mkdir`). It does **not** implement the standard configfs-tsm flow
  where the caller `mkdir`s a fresh `report/<entry>/` per request (e.g.
  `go-configfs-tsm`), nor the `/dev/tdx-guest` ioctl (which needs a raw TDREPORT
  dstack doesn't expose).
- One request at a time, one shim per app — a shared `inblob`/`outblob` can't tell
  concurrent callers apart. An empty `outblob` read means the quote failed.
