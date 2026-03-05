# Trustless Vault — TEE-Secured Fund Management

**The problem TEE actually solves:** letting people trust a pool of funds without trusting any person.

## Why This Exists

In DeFi, there are two ways to manage other people's money:

1. **Custodial**: "Trust me." → Requires faith. People get rugged.
2. **Smart contracts**: Trustless, but limited to on-chain logic. Can't do complex strategies, can't access off-chain data.

There's a gap: **complex trading strategies that manage shared funds**. Until now, these required trusting a fund manager.

**TEE fills this gap.** The strategy runs in hardware-isolated memory. The private key never leaves the chip. Anyone can verify the exact code running via attestation. No trust required.

## How It Works

```
┌─────────────────────────────────────────────────┐
│            Phala Cloud CVM (Intel TDX)          │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │           Trustless Vault                 │  │
│  │                                           │  │
│  │  Rules (hardcoded, attestable):           │  │
│  │  • Max 2% loss per trade                  │  │
│  │  • Max 20% in one position                │  │
│  │  • Only trade BTC, ETH, SOL              │  │
│  │  • 5% stop loss                           │  │
│  │  • 1 hour cooldown after loss             │  │
│  │                                           │  │
│  │  Wallet key: derived by TEE hardware      │  │
│  │  (deterministic, unexportable)            │  │
│  └───────────────┬───────────────────────────┘  │
│                  │                               │
│  ┌───────────────▼───────────────────────────┐  │
│  │  /var/run/dstack.sock                     │  │
│  │  Hardware key derivation + attestation    │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────┬───────────────────────────┘
                      │ HTTPS
          ┌───────────┴───────────┐
          │   Hyperliquid DEX     │
          │   (funding rates,     │
          │    prices, trades)    │
          └───────────────────────┘
```

## The Trust Model

| Question | Without TEE | With TEE |
|----------|-------------|----------|
| Who controls the private key? | Fund manager | Hardware (nobody) |
| Can the rules be changed secretly? | Yes | No — changes the attestation |
| Can someone steal the funds? | Yes, if they have the key | No — key is in hardware |
| How do I verify the strategy? | Read the whitepaper and hope | Read the code, check attestation |
| What if the server is compromised? | Funds at risk | Key still safe in TEE |

## Verification

Anyone can verify this vault:

```bash
# 1. Get the attestation quote directly from the vault
curl https://<app-id>-8080.dstack-<region>.phala.network/verify
# Returns actual TDX quote with RTMR values

# 2. Or use the CLI
phala cvms attestation <vault-name>
# Find the compose_hash in the event log

# 3. Hash the docker-compose.yaml + vault.py yourself
#    The hash must match

# 4. Read vault.py — the rules are right there:
#    MAX_LOSS_PER_TRADE = 0.02
#    MAX_POSITION_RATIO = 0.20
#    ALLOWED_ASSETS = ["BTC", "ETH", "SOL"]
#    These CANNOT be changed without changing the hash.

# 5. Check the vault state
curl https://<app-id>-8080.dstack-<region>.phala.network/
curl https://<app-id>-8080.dstack-<region>.phala.network/rules
```

## Deploy

```bash
phala deploy --name my-vault --compose docker-compose.yaml
```

## API

| Endpoint | Description |
|----------|-------------|
| `GET /` | Full vault state: wallet, signals, prices, positions, P&L |
| `GET /rules` | Trading rules (hardcoded, covered by attestation) |
| `GET /verify` | Step-by-step guide to verify this vault |

## Why Not Just Use a Smart Contract?

Smart contracts are great for simple rules (swap, lend, stake). But they can't:

- Call off-chain APIs (funding rates from Hyperliquid)
- Run complex strategies (momentum detection, multi-factor signals)
- React in real-time to market conditions (latency matters)

TEE gives you the **trustlessness of smart contracts** with the **flexibility of off-chain code**.

## Cost

- Instance: `tdx.small` (1 vCPU, 2GB RAM)
- Rate: ~$0.058/hour ≈ $42/month
- Phala Cloud free tier: $20 credit on signup

## Security Considerations

- The vault wallet key is derived deterministically from the app's identity via `dstack_sdk.get_key()`. Same app_id = same key. No disk storage needed.
- Changing ANY code changes the compose hash, which changes the attestation. Depositors should monitor for attestation changes.
- **This vault trusts Hyperliquid's API responses as-is.** A production vault should cross-validate with multiple data sources to mitigate API manipulation risks.
- This is an example. Do not deposit significant funds without thorough auditing.

## License

Apache-2.0
