#!/usr/bin/env python3
"""dstack -> configfs-tsm shim.

Serves <dir>/inblob (write report_data, <=64 bytes) and <dir>/outblob (read the
raw Intel DCAP TDX quote) by forwarding to the dstack guest-agent GetQuote RPC.
inblob/outblob are FIFOs, so a read of outblob blocks until the quote is ready.
report_data is forwarded byte-for-byte, so the quote is the genuine hardware
quote.

Serves ONE request at a time and supports a SINGLE in-flight requester -- like a
single configfs-tsm report entry, it cannot correlate concurrent callers. Run one
shim per app. An empty outblob read means the quote failed.

Env: TSM_REPORT_DIR (default /run/tsm/report), DSTACK_SOCKET (default
/var/run/dstack.sock).
"""
import errno
import fcntl
import http.client
import json
import os
import socket
import sys
import time

REPORT_DIR = os.environ.get("TSM_REPORT_DIR", "/run/tsm/report")
SOCKET = os.environ.get("DSTACK_SOCKET", "/var/run/dstack.sock")
# How long to wait for the app to open outblob for reading before giving up, so a
# caller that writes inblob then dies can't wedge the daemon.
OUTBLOB_DEADLINE = float(os.environ.get("TSM_OUTBLOB_DEADLINE", "30"))


def log(msg):
    sys.stderr.write(f"[tsm-shim] {msg}\n")
    sys.stderr.flush()


class _UDS(http.client.HTTPConnection):
    """HTTPConnection over an AF_UNIX socket."""

    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def get_quote(report_data, timeout=30):
    conn = _UDS(SOCKET, timeout)
    try:
        conn.request("POST", "/GetQuote",
                     body=json.dumps({"report_data": report_data.hex()}),
                     headers={"Host": "localhost", "Content-Type": "application/json"})
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"guest-agent returned http {resp.status}: {data[:200]!r}")
        quote = json.loads(data).get("quote")
        if not quote:
            raise RuntimeError(f"no quote in response: {data[:200]!r}")
        return bytes.fromhex(quote)
    finally:
        conn.close()


def open_write_deadline(path, deadline=30.0):
    """open a FIFO for writing, waiting up to `deadline`s for a reader.

    Returns a blocking fd, or None if no reader showed up -- so a caller that
    writes inblob then dies can't wedge the daemon forever.
    """
    end = time.monotonic() + deadline
    while True:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno == errno.ENXIO and time.monotonic() < end:
                time.sleep(0.05)
                continue
            return None
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
        return fd


def make_fifo(path):
    if os.path.lexists(path):
        os.remove(path)
    os.mkfifo(path, 0o600)


def main():
    os.makedirs(REPORT_DIR, exist_ok=True)
    inblob = os.path.join(REPORT_DIR, "inblob")
    outblob = os.path.join(REPORT_DIR, "outblob")
    make_fifo(inblob)
    make_fifo(outblob)
    log(f"ready: {REPORT_DIR} -> {SOCKET}")

    while True:
        try:
            with open(inblob, "rb") as f:        # blocks until the app writes
                report_data = f.read()
            if not report_data:
                continue
            if len(report_data) > 64:
                # >64 bytes means more than one writer raced on inblob -- fail
                # closed rather than hand back a quote bound to ambiguous data.
                log(f"rejecting inblob: {len(report_data)} bytes (>64); concurrent writers?")
                quote = b""
            else:
                try:
                    quote = get_quote(report_data.ljust(64, b"\0"))
                    log(f"quote {len(quote)} bytes, header={quote[:2].hex()}")
                except Exception as exc:
                    log(f"getquote failed: {exc}")  # deliver empty == failure signal
                    quote = b""
            fd = open_write_deadline(outblob, OUTBLOB_DEADLINE)
            if fd is None:
                log("no reader for outblob within deadline; dropping")
                continue
            with os.fdopen(fd, "wb") as f:
                f.write(quote)
        except Exception as exc:
            log(f"serve loop error: {exc}")
            time.sleep(0.5)


if __name__ == "__main__":
    main()
