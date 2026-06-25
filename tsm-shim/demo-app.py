#!/usr/bin/env python3
"""Demo "unmodified" attestation app — a standard configfs-tsm consumer.

Does exactly what a real binary built against the Linux TSM interface does:
  1. check that the TDX guest device exists,
  2. write up to 64 bytes of report_data to <dir>/inblob,
  3. read the raw Intel DCAP TDX quote from <dir>/outblob.

The only deployment-specific knob is TSM_REPORT_PATH. On a stock dstack CVM that
directory is served by the tsm-shim sidecar instead of the kernel.
"""
import hashlib
import os
import sys
import time


def detect_tdx() -> bool:
    return os.path.exists("/dev/tdx-guest") or os.path.exists("/dev/tdx_guest")


def main() -> None:
    report_dir = os.environ.get("TSM_REPORT_PATH", "/sys/kernel/config/tsm/report/dstack")

    if not detect_tdx():
        print("FAIL: no TDX guest device (/dev/tdx-guest)")
        sys.exit(1)

    # `depends_on: condition: service_healthy` already gates startup on the shim
    # FIFOs existing; this short retry just mirrors what real attestation libs do.
    for _ in range(100):
        if os.path.exists(f"{report_dir}/inblob"):
            break
        time.sleep(0.1)

    report_data = hashlib.sha256(b"dstack-tsm-shim-demo").digest()  # 32 bytes
    with open(f"{report_dir}/inblob", "wb") as f:
        f.write(report_data[:64].ljust(64, b"\0"))
    with open(f"{report_dir}/outblob", "rb") as f:
        quote = f.read()

    print(f"report_dir   : {report_dir}")
    print(f"report_data  : {report_data.hex()}")
    print(f"quote length : {len(quote)} bytes")
    print(f"quote header : {quote[:2].hex()} (a TDX v4 quote starts with 0400)")
    bound = report_data[:32] in quote
    print(f"report_data bound in quote: {bound}")
    print(
        "PASS - unmodified configfs-tsm app got a real TDX quote via the shim"
        if (quote[:2].hex() == "0400" and bound)
        else "FAIL - unexpected quote (header or report_data binding off)"
    )

    sys.stdout.flush()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
