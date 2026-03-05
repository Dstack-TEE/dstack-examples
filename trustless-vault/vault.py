"""
Trustless Vault — TEE-Secured Fund Management

The one thing only TEE can do: let people trust a shared pool of funds
without trusting any person.

Rules are hardcoded. Key is derived from hardware. Attestation proves everything.
Change one character → hash changes → depositors know immediately.

NOTE: This vault trusts Hyperliquid's API responses as-is.
A production vault should cross-validate with multiple data sources.
"""

import os
import time
import json
import hashlib
import logging
import threading
from decimal import Decimal
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

import requests
from dstack_sdk import DstackClient
from dstack_sdk.ethereum import to_account

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


# =============================================================================
# RULES — hardcoded, covered by attestation, immutable
# Changing any value changes the compose hash. Depositors can verify at any time.
# =============================================================================

MAX_LOSS_PER_TRADE = Decimal("0.02")     # 2% max loss per trade
MAX_POSITION_RATIO = Decimal("0.20")     # 20% max single position
STOP_LOSS = Decimal("0.05")              # 5% stop loss
FUNDING_THRESHOLD = 50.0                 # Annual rate % to trigger signal
ALLOWED_ASSETS = ["BTC", "ETH", "SOL"]   # Only trade these
COOLDOWN_AFTER_LOSS = 3600               # 1 hour cooldown after loss


# =============================================================================
# Vault state
# =============================================================================

STATE = {
    "vault_address": None,
    "total_deposited": "0",
    "depositors": {},
    "positions": [],
    "signals": [],
    "prices": {},
    "pnl": "0",
    "last_scan": None,
    "scans": 0,
    "status": "initializing",
    "rules": {
        "max_loss_per_trade": str(MAX_LOSS_PER_TRADE),
        "max_position_ratio": str(MAX_POSITION_RATIO),
        "stop_loss": str(STOP_LOSS),
        "allowed_assets": ALLOWED_ASSETS,
        "funding_threshold": FUNDING_THRESHOLD,
        "cooldown_after_loss_seconds": COOLDOWN_AFTER_LOSS,
    },
}


# =============================================================================
# TEE wallet — derived from hardware, deterministic, unexportable
# =============================================================================

def init_vault_wallet():
    """
    Derive the vault wallet from TEE hardware identity via dstack SDK.

    The key is deterministic: same app_id + same path = same key, always.
    No disk storage needed. Even if the VM is destroyed and recreated,
    the same compose file will produce the same wallet.

    The key NEVER leaves the TEE hardware.
    """
    client = DstackClient()
    key_response = client.get_key(path="/vault/main", purpose="trustless-vault-wallet")
    wallet = to_account(key_response)
    logger.info("Vault wallet derived from TEE hardware: %s", wallet.address)
    return wallet, client


# =============================================================================
# Market data
# =============================================================================

HL_API = "https://api.hyperliquid.xyz/info"


def scan_funding():
    """Find extreme funding rate opportunities on allowed assets."""
    try:
        resp = requests.post(
            HL_API,
            json={"type": "metaAndAssetCtxs"},
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        data = resp.json()
        meta, ctxs = data[0]["universe"], data[1]
        signals = []
        for i, asset in enumerate(meta):
            sym = asset["name"]
            if sym not in ALLOWED_ASSETS:
                continue
            funding = float(ctxs[i].get("funding", 0))
            annual = funding * 3 * 365 * 100
            if abs(annual) > FUNDING_THRESHOLD:
                signals.append({
                    "symbol": sym,
                    "funding_annual_pct": round(annual, 1),
                    "direction": "SHORT" if annual > 0 else "LONG",
                    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                })
        return sorted(signals, key=lambda s: abs(s["funding_annual_pct"]), reverse=True)
    except Exception as e:
        logger.error("Funding scan failed: %s", e)
        return []


def get_prices():
    """Get current prices for allowed assets."""
    try:
        resp = requests.post(
            HL_API,
            json={"type": "allMids"},
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        mids = resp.json()
        return {k: round(float(v), 2) for k, v in mids.items() if k in ALLOWED_ASSETS}
    except Exception as e:
        logger.error("Price fetch failed: %s", e)
        return {}


# =============================================================================
# Risk engine — these checks CANNOT be bypassed
# =============================================================================

def check_trade_allowed(signal, balance):
    """Risk checks before any trade. Hardcoded, verified by attestation."""
    if balance <= 0:
        return False, "no funds"
    pos_size = float(balance) * float(MAX_POSITION_RATIO)
    max_loss = pos_size * float(STOP_LOSS)
    if max_loss > float(balance) * float(MAX_LOSS_PER_TRADE):
        return False, "position too large for risk limits"
    return True, "ok"


# =============================================================================
# HTTP API — transparent state for depositors
# =============================================================================

# Global reference set by main()
_dstack_client = None

class VaultHandler(BaseHTTPRequestHandler):
    """
    Public API. Anyone can inspect the full state.

    GET /        → Full vault state
    GET /rules   → Trading rules (hardcoded, attestable)
    GET /verify  → Attestation quote + verification guide
    """

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/rules":
            data = STATE["rules"]
        elif path == "/verify":
            # Return actual attestation quote for cryptographic verification
            quote_data = None
            try:
                if _dstack_client and STATE["vault_address"]:
                    report = hashlib.sha256(
                        STATE["vault_address"].encode()
                    ).digest()[:64]
                    quote_response = _dstack_client.get_quote(report)
                    quote_data = {
                        "quote": quote_response.quote,
                        "event_log": quote_response.event_log,
                    }
            except Exception as e:
                quote_data = {"error": str(e)}

            data = {
                "vault_address": STATE["vault_address"],
                "rules": STATE["rules"],
                "attestation": quote_data,
                "verify_steps": [
                    "1. The 'attestation.quote' is a TDX quote from TEE hardware",
                    "2. Decode it to extract RTMR values and compose_hash",
                    "3. Compare compose_hash with the docker-compose.yaml in this repo",
                    "4. If they match, this vault runs exactly the published code",
                    "5. The rules above are hardcoded — any change breaks the hash",
                ],
            }
        else:
            data = STATE

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2, default=str).encode())

    def log_message(self, *_args):
        pass


# =============================================================================
# Main loop
# =============================================================================

def main():
    global _dstack_client

    logger.info("=" * 60)
    logger.info("  TRUSTLESS VAULT")
    logger.info("  Secured by TEE | Verified by Attestation")
    logger.info("=" * 60)
    logger.info("Rules: max_loss=%s, max_pos=%s, stop=%s, assets=%s",
                MAX_LOSS_PER_TRADE, MAX_POSITION_RATIO, STOP_LOSS, ALLOWED_ASSETS)

    wallet, _dstack_client = init_vault_wallet()
    STATE["vault_address"] = wallet.address
    STATE["status"] = "running"

    logger.info("Vault address: %s", wallet.address)

    # Start HTTP server
    server = HTTPServer(("0.0.0.0", 8080), VaultHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info("API on :8080 — GET / | /rules | /verify")

    interval = int(os.environ.get("SCAN_INTERVAL", "60"))

    while True:
        STATE["signals"] = scan_funding()
        STATE["prices"] = get_prices()
        STATE["last_scan"] = time.strftime("%Y-%m-%d %H:%M:%S")
        STATE["scans"] += 1

        for s in STATE["signals"]:
            ok, reason = check_trade_allowed(s, 0)
            logger.info(
                "Signal: %s %s (%s%%) — %s",
                s["direction"], s["symbol"], s["funding_annual_pct"],
                "WOULD TRADE" if ok else "BLOCKED: " + reason,
            )

        if STATE["prices"]:
            logger.info(
                "Prices: %s",
                " | ".join(f"{k}=${v:,.0f}" for k, v in STATE["prices"].items()),
            )

        logger.info("Scan #%d done. Next in %ds.", STATE["scans"], interval)
        time.sleep(interval)


if __name__ == "__main__":
    main()
