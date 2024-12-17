TEE Coprocessors in Dstack
=====

Minimal docker file for using the Helios light client to provide a trustworthy view of the blockchain.

You can run this locally - it will output an empty attestation if it's not in a TEE. To run this on Dstack, you can simply copy paste the docker-compose.yml and specify your ETH_RPC_URL parameter.

The provided docker compose uses holesky. Helios currently supports other Eth testnetworks as well as opstack.

This relies on an untrusted RPC, so you need to provide your own `ETH_RPC_URL`. The free trial at quicknode.com works fine.

Run with:
```bash
docker compose build
docker compose run --rm -e ETH_RPC_URL=${ETH_RPC_URL} tapp
```

Expected output:
```
+] Creating 1/1
 ✔ Network lightclient_default  Created                                                                                                                  0.1s 
2024-12-17T21:52:56.084201Z  INFO helios::rpc: rpc server started at 127.0.0.1:8545
2024-12-17T21:52:57.858077Z  INFO helios::consensus: sync committee updated
2024-12-17T21:52:57.941169Z  INFO helios::consensus: sync committee updated
2024-12-17T21:52:58.420835Z  INFO helios::consensus: finalized slot             slot=3214080  confidence=92.38%  age=00:00:16:58
2024-12-17T21:52:58.420854Z  INFO helios::consensus: updated head               slot=3214163  confidence=92.38%  age=00:00:00:22
2024-12-17T21:52:58.420859Z  INFO helios::consensus: consensus client in sync with checkpoint: 0x9260657ed4167f2bbe57317978ff181b6b96c1065ecf9340bba05ba3578128fe


baseFeePerGas        8
difficulty           0
extraData            0x444556434f4e20505245434f4e4653
gasLimit             30000000
...
	0x5adfa31d8bcaae1b27bf8c6d2d6eb0108f3dc8ec35dc8ffaa5b8326e3eab475b
	0x58025835a1943c458e444fbd39d7f776132cd82892b9f2f17218de5b29aa8b8e
]
ATTEST=...
```

Acknowledgments
###
Thanks [@fucory](https://x.com/fucory) and [@kassandraETH](https://x.com/kassandraETH) for the suggestions