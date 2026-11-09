#!/usr/bin/env bash
# Check the three claims this example makes, against a running CVM.
#
#   ./verify.sh pg-r2
#
# 1. The keys are derived, not stored — this script re-derives the superuser password from
#    the KMS and logs in with it. Nothing was handed to it.
# 2. The archive is current — how many segments, and how stale the newest one is.
# 3. The bucket holds ciphertext — the archived object is compared against a real WAL
#    segment on disk, and against the same object after wal-g decrypts it.
#
# Needs the phala CLI and a CVM deployed from docker-compose.yml here.
set -euo pipefail
CVM=${1:?usage: verify.sh <cvm-name>}

INNER=$(cat <<'EOF'
set -euo pipefail
sock=/var/run/dstack.sock
derive() {
  curl -sf --unix-socket "$sock" -X POST -H 'Content-Type: application/json' \
    -d "{\"path\":\"$1\",\"purpose\":\"$2\"}" http://dstack/GetKey \
    | sed -n 's/.*"key":"\([0-9a-f]\{64\}\).*/\1/p'
}

echo "== 1. keys are derived, not stored"
a=$(derive /pg-r2/superuser/v1 password)
b=$(derive /pg-r2/superuser/v1 password)
c=$(derive /pg-r2/walg/v1 walg)
[ -n "$a" ] || { echo "   derivation failed"; exit 1; }
echo "   superuser path, twice   : ${a:0:16}… / ${b:0:16}…  $([ "$a" = "$b" ] && echo same || echo DIFFERENT)"
echo "   archive-key path        : ${c:0:16}…  $([ "$a" = "$c" ] && echo SAME-AS-PASSWORD || echo unrelated)"
export PGPASSWORD="$a"
Q() { psql "postgresql://postgres@127.0.0.1:5432/app?sslmode=require" -tAqc "$1"; }
echo "   logging in with the re-derived password: $(Q 'SELECT current_user')"

echo
echo "== 2. the archive is current"
Q "SELECT '   segments archived      : '||archived_count||' ('||failed_count||' failed)' FROM pg_stat_archiver"
Q "SELECT '   newest segment is      : '||coalesce(round(extract(epoch FROM now()-last_archived_time))||'s old','nothing archived yet') FROM pg_stat_archiver"
Q "SELECT '   waiting to archive     : '||count(*)||' .ready files' FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'"

echo
echo "== 3. the bucket holds ciphertext"
# This shell was handed nothing, so wal-g cannot read the archive until the key is
# re-derived — which is the claim, demonstrated by needing to do it.
export WALG_LIBSODIUM_KEY="$c"
seg=$(Q "SELECT substr(last_archived_wal,1,24) FROM pg_stat_archiver")
if [ -z "$seg" ]; then echo "   nothing archived yet — write something and switch WAL first"; exit 0; fi
# The listing also holds a backup-label object for this segment, and it sorts first.
# Match the segment itself, whatever compression suffix it carries.
obj=$(gosu postgres wal-g st ls wal_005/ | awk -v s="$seg" '$NF ~ "^"s"\\.[a-z0-9]+$" {print $NF; exit}')
[ -n "$obj" ] || { echo "   $seg not found in the bucket listing"; exit 1; }
# Written to a file rather than piped: head closing the pipe would SIGPIPE wal-g, and
# under pipefail that reads as a failure when nothing actually went wrong.
rm -f /tmp/stored.bin
gosu postgres wal-g st cat "wal_005/$obj" > /tmp/stored.bin
stored=$(head -c 16 /tmp/stored.bin | od -An -tx1 | tr -d " \n")
rm -f /tmp/seg && gosu postgres wal-g wal-fetch "$seg" /tmp/seg >/dev/null
decrypted=$( head -c 16 /tmp/seg | od -An -tx1 | tr -d " \n")
local_seg=$(ls "$PGDATA/pg_wal" | grep -E '^[0-9A-F]{24}$' | head -n1)
onwal=$( head -c 16 "$PGDATA/pg_wal/$local_seg" | od -An -tx1 | tr -d " \n")
magic=${onwal:0:4}
echo "   segment                 : $seg"
echo "   a live segment on disk  : $onwal"
echo "   the object in the bucket: $stored"
echo "   the object after wal-g  : $decrypted"
echo "   WAL magic is $magic — the bucket copy $([ "${stored:0:4}" = "$magic" ] && echo 'HAS IT (not encrypted!)' || echo 'does not have it'), the wal-g copy $([ "${decrypted:0:4}" = "$magic" ] && echo does || echo 'does NOT')"
EOF
)

B=$(printf '%s' "$INNER" | base64 -w0)
phala ssh "$CVM" -- "docker exec \$(docker ps --format '{{.Names}}' | head -n1) bash -c 'echo $B | base64 -d | bash'"
