# dstack Dev Box

dstack v0.6 no longer ships a dev OS image with SSH and debugging tools. Add this one container to your compose file to get them back: root SSH into the CVM, a full Debian toolset, the host filesystem, the host Docker daemon, and a shell in the host OS itself.

> [!WARNING]
> This gives anyone holding an authorized key full root on the CVM: every container, the decrypted disk, and every secret in memory. It breaks the confidentiality guarantee your users rely on. The dev box is part of the attested `app-compose`, so verifiers can see it's there. Use it for development and debugging only.

## Usage

Add the `dev-box` service from [`docker-compose.yaml`](./docker-compose.yaml) next to your workload:

```yaml
services:
  dev-box:
    image: ghcr.io/dstack-tee/dstack-dev-box:sha-5a930ae@sha256:2191420a255a0adbf5044700b848b0f5fc29c1c24323a1742054409f5f116d99
    restart: unless-stopped
    privileged: true
    pid: host
    network_mode: host
    uts: host
    environment:
      - SSH_AUTHORIZED_KEYS=${SSH_AUTHORIZED_KEYS}
    volumes:
      - /:/host:rslave
      - /var/run/docker.sock:/var/run/docker.sock
      - /dev/pts:/dev/pts
      - ssh-host-keys:/etc/ssh/host-keys
      - home:/root

  your-app:
    image: ...

volumes:
  ssh-host-keys:
  home:
```

Deploy with your public key or keys in `SSH_AUTHORIZED_KEYS`, in `authorized_keys` format with one key per line. The container exits with an error if the variable is empty.

```bash
phala deploy -n my-app -c docker-compose.yaml \
  --image dstack-0.6.1 \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"
```

On a plain dstack deployment, set `SSH_AUTHORIZED_KEYS` as an encrypted environment variable.

## Connect

`sshd` listens on port `1022`. Reach it through the dstack-gateway by adding this to `~/.ssh/config`:

```
Host my-app
    User root
    ProxyCommand openssl s_client -quiet -connect <app-id>-1022.<gateway-domain>:443 -servername <app-id>-1022.<gateway-domain> -verify_hostname <app-id>-1022.<gateway-domain> -verify_return_error
```

Replace `<app-id>` with your app ID and `<gateway-domain>` with the gateway base domain of the node the CVM runs on, for example `dstack-pha-prod15.phala.network`. Change `443` if your gateway uses a different port.

> [!NOTE]
> On macOS the system `openssl` is LibreSSL, which can time out with this `ProxyCommand`. Install OpenSSL with `brew install openssl` and make sure it's first on your `PATH`.

## What you get

You land in the dev box: a Debian trixie container, the same base as the dstack 0.6 guest OS, that shares the host's PID, network, and UTS namespaces.

| Need | How |
|------|-----|
| Host processes, network, hostname | Visible directly: `ps`, `htop`, `ip`, `ss`, `tcpdump`, `strace -p` |
| Host files | `/host`, for example `/host/dstack/app-compose.json` |
| Containers | `docker` and `docker compose` talk to the host daemon |
| systemd, journald, anything else on the host | `host-shell` opens a shell in the host OS; `host-shell CMD` runs one command there, for example `host-shell journalctl -u docker` |
| File transfer | `scp`, `sftp`, and `rsync`, for example `rsync my-app:/host/tmp/dump ./` |
| Port forwarding | `ssh -N -L 8080:127.0.0.1:8080 my-app` reaches any port on the CVM |

Also installed: `vim`, `tmux`, `git`, `curl`, `jq`, `dig`, `gdb`, `lsof`, and `python3`. Run `apt-get install` for anything else. Installed packages last until the container is recreated. `/root` is a volume, so dotfiles and history persist across restarts and updates, as does the SSH host key.

## How it works

The host rootfs is a read-only, dm-verity-protected image, so tools can't be installed on the host itself. The dev box brings its own userland and borrows the host's namespaces instead, the same design as Bottlerocket's admin container and `kubectl debug node`.

| Setting | Why |
|---------|-----|
| `privileged: true` | Full device access and capabilities for `tcpdump`, `strace`, `gdb`, and the `setns()` calls in `host-shell`. |
| `pid: host`, `network_mode: host`, `uts: host` | The box sees the host's processes, network stack, and hostname. |
| `/:/host:rslave` | The host filesystem, including mounts made after the box starts. |
| `/var/run/docker.sock` | `docker` drives the host daemon. |
| `/dev/pts:/dev/pts` | PTYs come from the host's devpts instance, so a terminal still works after `host-shell` switches to the host mount namespace. |

[`host-shell`](./host-shell) runs `nsenter --target 1 --all --root`, joining every namespace of host PID 1 and its root directory. Its shell is the host's own `/bin/bash`, with no dev box tools.

## Build your own image

The compose file pins `ghcr.io/dstack-tee/dstack-dev-box` by digest, so the attested `app-compose` identifies the exact image. It's built from this directory by [`build-dev-box.yml`](../.github/workflows/build-dev-box.yml), which tags each `main` build `sha-<commit>` and `latest`. To add packages, edit the [`Dockerfile`](./Dockerfile), push the image to a registry, and change `image:`. For a quick test, [ttl.sh](https://ttl.sh) holds anonymous images for up to 24 hours:

```bash
docker buildx build --platform linux/amd64 -t ttl.sh/my-dev-box:24h --push .
```
