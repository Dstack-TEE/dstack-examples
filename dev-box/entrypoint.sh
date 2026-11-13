#!/bin/sh
# Authorized keys arrive on two channels with different purposes:
#
#   SSH_AUTHORIZED_KEYS  key pasted at deploy time, one per line
#   user_config          workspace keys the platform pushes to the CVM before
#                        it boots; the host root is mounted at /host, so the
#                        guest's /dstack/user_config is /host/dstack/user_config
#
# They are merged, not overridden: a key set in either channel works, and a
# platform-side key update never drops the deploy-time key. Duplicates are
# removed. Each channel is optional; only losing both is fatal.
set -eu

# Overridable to exercise the merge logic outside a CVM.
USER_CONFIG=${USER_CONFIG:-/host/dstack/user_config}

env_keys=${SSH_AUTHORIZED_KEYS:-}

# A missing file or malformed JSON makes jq fail; `.ssh_authorized_keys // empty`
# turns a missing field and a null into no output, select() drops a non-string
# value, and an empty string comes out as an empty line that the blank-line
# filter below removes. Every path ends with this channel contributing no key.
#
# The assignment, not the jq call, is what swallows the failure: jq streams, so
# `{"ssh_authorized_keys":"k"} garbage` prints the key and then exits non-zero.
# Dropping output only inside the substitution would keep that partial key from
# a config we just decided not to trust, so a non-zero exit discards it all.
config_keys=$(
  jq -r '.ssh_authorized_keys // empty | select(type == "string")' \
    "$USER_CONFIG" 2>/dev/null
) || config_keys=

# Blank and whitespace-only lines would become empty authorized_keys entries.
keys=$(
  printf '%s\n%s\n' "$env_keys" "$config_keys" |
    sed -e 's/[[:space:]]*$//' -e '/^$/d' | sort -u
)

if [ -z "$keys" ]; then
  echo "no SSH public keys in SSH_AUTHORIZED_KEYS or ${USER_CONFIG}" >&2
  exit 1
fi

install -d -m 700 /root/.ssh
printf '%s\n' "$keys" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "authorized_keys: $(printf '%s\n' "$keys" | wc -l) key(s)" >&2
key=/etc/ssh/host-keys/ssh_host_ed25519_key
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -f "$key"
install -d -m 755 /run/sshd
exec /usr/sbin/sshd -D -e
