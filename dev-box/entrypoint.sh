#!/bin/sh
set -eu
if [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
  echo "SSH_AUTHORIZED_KEYS is not set" >&2
  exit 1
fi
install -d -m 700 /root/.ssh
printf '%s\n' "$SSH_AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
key=/etc/ssh/host-keys/ssh_host_ed25519_key
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -f "$key"
install -d -m 755 /run/sshd
exec /usr/sbin/sshd -D -e
