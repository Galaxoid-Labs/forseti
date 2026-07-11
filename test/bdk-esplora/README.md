# BDK ↔ forseti Esplora e2e

Proves forseti's in-node wallet backend (`--index-addresses --esplora`) is a
working [BDK](https://bitcoindevkit.org) Esplora backend: a real
`bdk_wallet` + `bdk_esplora` descriptor wallet does **full_scan → build → sign →
broadcast → confirm** against forseti on regtest — no electrs sidecar.

## Run

```bash
odin build . -out:forseti -o:speed -extra-linker-flags:"-lstdc++"   # from repo root
cd test/bdk-esplora
./run.sh ../../forseti
```

Requires the Rust toolchain (fetches `bdk_wallet` 1.x + `bdk_esplora` 0.x).

## What it exercises

- `GET /blocks`, `/blocks/tip/{height,hash}`, `/block-height/:h` — checkpoint seed
- `GET /scripthash/:h/txs[/chain/:last_seen]`, `/utxo` — wallet sync (the core)
- `GET /tx/:txid[/status]` — confirmation tracking
- `POST /tx` — broadcast (reuses forseti's `sendrawtransaction` mempool+relay path)

The harness (`src/main.rs`) uses a fixed-seed BIP84 wallet so every invocation is
deterministic and re-derives its state from the chain.
