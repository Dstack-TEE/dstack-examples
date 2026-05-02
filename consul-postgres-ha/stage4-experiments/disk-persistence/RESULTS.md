# Disk persistence across in-place phala_app updates — verified

**Date:** 2026-05-02
**Provider:** `phala-network/phala 0.2.0-beta.2`
**Question:** When `terraform apply` updates a `phala_app`'s
`docker_compose` (which translates to Phala's "upgrade an existing
CVM" path), does a docker-compose **named volume** survive?

**Outcome:** ✅ Yes. Verified empirically with a UUID marker round-trip.

This is the keystone the entire stage-4 design depends on. The
"identity stored on the CVM disk" assumption only works if disks
survive in-place compose updates.

## Test

`main.tf` deploys a single tdx.small CVM running:

```yaml
services:
  marker:
    image: nginx:1.27-alpine
    volumes:
      - data:/usr/share/nginx/html
    command:
      - sh
      - -c
      - |
        # write a marker on first boot if absent; serve via nginx
        ...
        exec nginx -g 'daemon off;'
volumes:
  data:
```

The compose carries a `# compose-marker: ${var.compose_marker}`
header so flipping a tfvar (`v1` -> `v2`) forces an in-place update
even though no service config actually changes.

### Procedure

1. `terraform apply` with `compose_marker = "v1"` → CVM up, ~2 min.
2. Wrote a known UUID into the volume manually:
   ```
   ssh root@<app>-22.<gw> docker exec dstack-marker-1 sh -c \
     'cat /proc/sys/kernel/random/uuid > /usr/share/nginx/html/marker.txt'
   ```
   Recorded `M1 = 90ce33e5-6e4e-4c47-8407-6624072387da`.
   Verified via gateway: `curl https://<app>-8080.<gw>/marker.txt`
   returned the same UUID.
3. Edited `terraform.tfvars`: `compose_marker = "v2"`.
4. `terraform apply -auto-approve` → in-place update, **same
   `app_id`**, `Modifications complete after ~3m`.
5. `curl https://<app>-8080.<gw>/marker.txt` again → returned
   `M2 = 90ce33e5-6e4e-4c47-8407-6624072387da` — **identical to M1**.

### Result

```
M1 = 90ce33e5-6e4e-4c47-8407-6624072387da     (pre-update)
M2 = 90ce33e5-6e4e-4c47-8407-6624072387da     (post-update)
✅ DISK PERSISTED — same marker before and after
```

The named docker volume `data` survived the compose update. Same
container name (`dstack-marker-1`), same `app_id`, same volume,
same on-disk content.

## What this confirms for stage 4

- `bootstrap-secrets` writing `/var/lib/dstack/instance-id` on first
  boot is safe; subsequent boots (after compose updates / image
  bumps) read the same UUID.
- Consul agent's `/consul/data` (Raft state, KV) survives compose
  updates → no risk of losing membership / catalog when bumping
  Consul image.
- Patroni / Postgres data dir would survive likewise (when we get
  to that workload).
- The "in-place update preserves data" requirement from
  STAGE4_PLAN.md is empirically met.

## Caveats

This test exercised:
- a single-replica `phala_app` (no `replicas` scaling involved),
- a `compose_marker` change (changes the `docker_compose` body
  string but no service-config-relevant fields),
- ~3 min update window.

NOT tested:
- Disk persistence under `replicas: 1 -> N` scaling (does scaling
  preserve the EXISTING CVM's volume? or recreate?).
- Disk persistence when `image` changes (e.g. `nginx:1.27 ->
  nginx:1.28`).
- Disk persistence under `phala_app` settings that are ForceNew —
  those would destroy the CVM and there is no expectation of
  preservation.
- Disk persistence across Phala-platform-level updates (host
  reboot, OS upgrade, region migration). Out of our control.

The first two would be quick to add if needed; we'll test them
inline when stage-4 build hits them.

## Cleanup

`terraform destroy` removed the CVM cleanly.
