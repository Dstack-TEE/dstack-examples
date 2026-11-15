#!/bin/sh
# Upgrades a running CVM to a new compose with no downtime.
# Usage: ./upgrade.sh <current CVM name or uuid> <new docker-compose.yaml>
set -eu
A=$1
NEW=$2

info=$(phala cvms get "$A" --json)
a_url=https://$(printf "%s\n" "$info" | jq -r '.instance_id + "-8080." + .gateway.base_domain')

# dstack drops env vars missing from allowed_envs, and the replica inherits A's list. A replica
# without DORMANT and PREDECESSOR_URL would boot as a second writer with empty state.
printf "%s\n" "$info" | jq -e '.compose_file | if type == "string" then fromjson else . end | .allowed_envs | index("DORMANT") and index("PREDECESSOR_URL")' > /dev/null \
  || { echo "$A was not deployed with -e PREDECESSOR_URL= -e DORMANT=" >&2; exit 1; }

# 1. A replica of A with the same compose. DORMANT keeps it forwarding to A instead of taking over.
env=$(mktemp)
printf 'DORMANT=1\nPREDECESSOR_URL=%s\n' "$a_url" > "$env"
B=$(phala cvms replicate "$A" -e "$env" --json | jq -r .vm_uuid)
echo "replica $B"
until phala cvms get "$B" --json | jq -e '.status == "running"' > /dev/null; do sleep 10; done

# 2. B alone reboots into the new compose and takes the writer role and state from A.
phala deploy --cvm-id "$B" -c "$NEW" -e PREDECESSOR_URL="$a_url" -e DORMANT= --wait
b_url=https://$(phala cvms get "$B" --json | jq -r '.instance_id + "-8080." + .gateway.base_domain')
until curl -sf "$b_url/_status" | jq -e '.role == "writer"' > /dev/null; do sleep 3; done

# 3. A now forwards to B. Let requests already routed to A finish, then remove it.
sleep 20
phala cvms delete "$A" --force
echo "upgraded: $B is the writer"
