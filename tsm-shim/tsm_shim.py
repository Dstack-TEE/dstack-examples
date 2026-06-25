#!/usr/bin/env python3
"""dstack -> configfs-tsm compatibility shim (FIFO mode, zero privileges).

Re-exposes the dstack guest-agent `GetQuote` RPC under the standard
configfs-tsm file ABI that unmodified attestation binaries expect:

    <report-dir>/inblob    write <=64 bytes of report_data
    <report-dir>/outblob   read  -> raw Intel DCAP TDX quote

`inblob` and `outblob` are implemented as named pipes (FIFOs), so a read of
`outblob` naturally blocks until the quote for the most recent `inblob` write
is ready. That matches the canonical configfs-tsm usage (write inblob, then
read outblob) with no race, and -- crucially -- needs NO FUSE, NO
CAP_SYS_ADMIN, and NO remount of /sys. It runs as an ordinary process in a
sidecar or a pre-launch wrapper.

The quote itself still comes from real TDX hardware via the guest-agent over
its unix socket, so attestation is not weakened: report_data is forwarded
byte-for-byte and the returned quote is the genuine hardware quote.

Usage:
    tsm_shim.py --report-dir /run/tsm/report --socket /var/run/dstack.sock
"""
import argparse
import http.client
import json
import os
import socket
import sys
import time
import traceback


def log(msg):
    sys.stderr.write(f"[tsm-shim] {msg}\n")
    sys.stderr.flush()


class _UDSConnection(http.client.HTTPConnection):
    """HTTPConnection that dials an AF_UNIX socket instead of TCP."""

    def __init__(self, uds_path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._uds_path = uds_path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._uds_path)
        self.sock = s


def get_quote(sock_path, report_data, timeout=30):
    """Call dstack guest-agent DstackGuest.GetQuote, return raw quote bytes.

    Wire format mirrors the official dstack SDK: POST /GetQuote over the unix
    socket with JSON body {"report_data": "<hex>"}; response is JSON with a
    hex-encoded "quote". http.client transparently handles chunked /
    content-length response framing, so no extra deps are required.
    """
    body = json.dumps({"report_data": report_data.hex()})
    conn = _UDSConnection(sock_path, timeout)
    try:
        conn.request(
            "POST",
            "/GetQuote",
            body=body,
            headers={"Host": "localhost", "Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(
                f"guest-agent GetQuote returned HTTP {resp.status}: {data[:200]!r}"
            )
        obj = json.loads(data)
        if "quote" not in obj:
            raise RuntimeError(f"GetQuote response missing 'quote': {obj}")
        return bytes.fromhex(obj["quote"])
    finally:
        conn.close()


def _make_fifo(path):
    if os.path.lexists(path):
        os.remove(path)
    os.mkfifo(path, 0o600)


def serve(report_dir, sock_path):
    os.makedirs(report_dir, exist_ok=True)
    inblob = os.path.join(report_dir, "inblob")
    outblob = os.path.join(report_dir, "outblob")
    _make_fifo(inblob)
    _make_fifo(outblob)
    # Best-effort: expose a `provider` attribute for apps that sanity-check it.
    try:
        with open(os.path.join(report_dir, "provider"), "w") as f:
            f.write("tdx_guest\n")
    except OSError:
        pass

    log(f"ready: {inblob} (write report_data), {outblob} (read quote) -> {sock_path}")
    while True:
        try:
            # 1. Block until the app writes report_data to inblob.
            with open(inblob, "rb") as f:
                report_data = f.read()
            if not report_data:
                continue  # opened+closed with no payload; ignore.
            rd64 = report_data[:64].ljust(64, b"\0")
            log(f"inblob: {len(report_data)} bytes; requesting hardware quote...")
            try:
                quote = get_quote(sock_path, rd64)
                log(f"quote: {len(quote)} bytes, header={quote[:2].hex()}")
            except Exception as exc:  # noqa: BLE001 - surface to logs, keep serving
                log(f"GetQuote failed: {exc}")
                quote = b""  # deliver empty so the reader doesn't hang forever.
            # 2. Block until the app opens outblob for reading, then deliver.
            with open(outblob, "wb") as f:
                f.write(quote)
        except Exception:  # noqa: BLE001 - never let the daemon die.
            log("serve loop error:\n" + traceback.format_exc())
            time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--report-dir",
        default=os.environ.get("TSM_REPORT_DIR", "/run/tsm/report"),
        help="directory in which to expose inblob/outblob FIFOs",
    )
    ap.add_argument(
        "--socket",
        default=os.environ.get("DSTACK_SOCKET", "/var/run/dstack.sock"),
        help="path to the dstack guest-agent unix socket",
    )
    args = ap.parse_args()
    serve(args.report_dir, args.socket)


if __name__ == "__main__":
    main()
