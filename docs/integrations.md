# Wallet & Indexer Integrations

## Electrum Wallets (BDK / Electrum / Sparrow)

btcnode speaks enough Bitcoin Core RPC + P2P that [electrs](https://github.com/romanz/electrs)
v0.10 runs against it unmodified, giving any Electrum-protocol wallet
(BDK's `bdk_electrum`, Electrum, Sparrow) address balances, histories, and
UTXOs backed by your own node:

```bash
# Node must be UNPRUNED for electrs's initial index build.
./btcnode --network=signet --datadir=~/btcnode-signet

electrs --network signet \
  --daemon-rpc-addr 127.0.0.1:38332 \
  --daemon-p2p-addr 127.0.0.1:38333 \
  --cookie-file ~/btcnode-signet/.cookie \
  --db-dir ~/electrs-db

# Wallets connect to electrs at tcp://127.0.0.1:60601
```

electrs learns about new blocks over the P2P connection (no ZMQ needed)
and syncs the mempool over RPC.

For consumers that DO want ZMQ (LND's bitcoind backend, custom indexers),
btcnode implements Bitcoin Core's publisher interface natively (no libzmq
dependency — ZMTP 3.0 spoken directly):

```bash
./btcnode --zmqpubrawblock=tcp://127.0.0.1:28332 --zmqpubrawtx=tcp://127.0.0.1:28333
```

Topics: `hashblock`, `hashtx`, `rawblock`, `rawtx`, `sequence` — payloads
and per-topic LE32 sequence numbers match Core exactly (verified against
libzmq subscribers).

