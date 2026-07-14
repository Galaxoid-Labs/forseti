# Wallet & Indexer Integrations

## Built-in Esplora REST API (recommended, no sidecar)

forseti serves the **[Esplora HTTP REST API](https://github.com/Blockstream/esplora/blob/master/API.md) natively** — the same API Blockstream's Esplora exposes — with **no electrs/Esplora sidecar and no second copy of the chain**. The scripthash (address) index is built **during initial sync**: when the node reaches the tip, the wallet backend is already there. There is no separate multi-hour indexer pass afterward — it's one pass.

Point [BDK's `esplora` backend](https://docs.rs/bdk_esplora), `esplora-client`, or any Esplora-speaking wallet straight at the node.

**Enable it** (or pick the toggles in `--wizard` → Advanced):

```bash
./forseti --network=mainnet --datadir=~/forseti \
  --index-addresses --esplora        # index during sync; REST on 127.0.0.1:3000
```

- `--index-addresses` builds the scripthash index (a dedicated RocksDB store at `<datadir>/addrindex/`).
- `--esplora` serves the REST API — `1` = `127.0.0.1:3000`, or pass `addr:port`. It implies/requires `--index-addresses`.
- **Incompatible with `--prune`** (the index reads historical txs from full blocks). Loopback-only by default — no auth, so tunnel (`ssh -L 3000:localhost:3000`) or firewall before exposing it.
- Enabling `--index-addresses` on an already-synced datadir runs a one-time catch-up build at startup.

**Endpoints — full Esplora parity.** Blocks (`/blocks`, `/blocks/tip/{height,hash}`, `/block-height/:h`, `/block/:hash[/status|/header|/raw|/txids|/txs[/:start]|/txid/:i]`), transactions (`/tx/:txid[/hex|/raw|/status|/merkle-proof|/merkleblock-proof|/outspends|/outspend/:v]`, `POST /tx`), addresses & scripthashes (`/address/:a` and `/scripthash/:h` + their `/txs[/chain/:last|/mempool]` and `/utxo`, plus `chain_stats`/`mempool_stats` summaries), mempool (`/mempool`, `/mempool/{txids,recent}`), and `/fee-estimates`.

```bash
curl http://127.0.0.1:3000/blocks/tip/height
curl http://127.0.0.1:3000/address/<addr>/utxo
curl http://127.0.0.1:3000/tx/<txid>/outspends
# BDK: EsploraClient::new("http://127.0.0.1:3000")  →  wallet.full_scan(...)
```

> **Status: verified.** A real `bdk_wallet` + `bdk_esplora` descriptor wallet does a full end-to-end `full_scan → build → sign → broadcast → confirm` against forseti on regtest (harness in `test/bdk-esplora/`). Every endpoint's output is cross-checked field-for-field against `blockstream.info/api` on mainnet — including exact-hex tx/block serialization, merkle proofs, `outspend` spender identification, and complete address histories (full pagination walk, zero missing/extra txs). Response JSON is byte-identical to Blockstream's Esplora.

> **One limit:** the `/address/:a` and `/scripthash/:h` **stats summaries** (`chain_stats`/`mempool_stats`) are computed on demand from the flat files, so they're refused with `400` for scripthashes above ~10k history rows (mega-reused exchange/pool/genesis addresses). Everything else — `/txs`, `/utxo`, per-tx endpoints — still works on those addresses via pagination; only the aggregate-sum summary is capped. Normal wallet addresses are unaffected.

**When you'd still want an external indexer instead:** the built-in API does **not** (yet) speak the **Electrum protocol** (Sparrow / Electrum desktop / `bdk_electrum`) or ship the **Esplora web-explorer frontend**. For those, run electrs or Blockstream/Esplora as a sidecar — covered below.

## Electrum Wallets (BDK / Electrum / Sparrow)

forseti speaks enough Bitcoin Core RPC + P2P that [electrs](https://github.com/romanz/electrs)
v0.10 runs against it unmodified, giving any Electrum-protocol wallet
(BDK's `bdk_electrum`, Electrum, Sparrow) address balances, histories, and
UTXOs backed by your own node.

> **⚠️ The node must be UNPRUNED.** electrs builds its own address index by
> reading *every historical block* over the P2P connection. A pruned node has
> deleted those blocks, so electrs's initial index build fails partway through.
> Do not run `--prune` (or pick "pruned" in the wizard) on a node you intend to
> back electrs with — you'd need a full resync.

electrs does **not** need the node's `--txindex`: it maintains its own index.
It pulls historical blocks and learns about new ones over **P2P**, and syncs
the mempool + chain info over **RPC** — no ZMQ required.

**Signet:**
```bash
./forseti --network=signet --datadir=~/forseti-signet --daemon
electrs --network signet \
  --daemon-rpc-addr 127.0.0.1:38332 \
  --daemon-p2p-addr 127.0.0.1:38333 \
  --cookie-file ~/forseti-signet/.cookie \
  --db-dir ~/electrs-db
# wallets connect to electrs at tcp://127.0.0.1:60601
```

**Mainnet:**
```bash
./forseti --network=mainnet --datadir=~/forseti --daemon   # must be unpruned
electrs --network bitcoin \
  --daemon-rpc-addr 127.0.0.1:8332 \
  --daemon-p2p-addr 127.0.0.1:8333 \
  --cookie-file ~/forseti/.cookie \
  --db-dir ~/electrs-db
# wallets connect to electrs at tcp://127.0.0.1:50001
```
The initial mainnet index build takes hours and the electrs DB is tens of GB —
put `--db-dir` on a disk with room.

**Auth with `rpcuser`/`rpcpassword`** (instead of the rotating cookie): drop
`--cookie-file` and give electrs the credentials in its config file (e.g.
`~/.electrs/config.toml`, or point at one with `--conf`):
```toml
auth = "youruser:yourpassword"
```

### Exposing electrs to other machines

Both links from electrs to forseti (`daemon-rpc-addr` 8332, `daemon-p2p-addr`
8333) are localhost — **no firewall rules, and never open the node's 8332/8333
to the internet.** Only the Electrum port that *wallets* connect to needs
opening, and only if they run on another machine. By default electrs binds it
to localhost; to expose it, set in the electrs config:
```toml
electrum_rpc_addr = "0.0.0.0:50001"
```
and open the firewall: `sudo ufw allow 50001`.

**Privacy/security caveat:** the Electrum protocol on 50001 is *plaintext* — it
leaks every address your wallet queries, and anyone who reaches the port can
query the index. On a public/internet-facing server, prefer reaching electrs
over an **SSH tunnel** (`ssh -L 50001:localhost:50001 <server>`) or a **Tor
hidden service** (electrs supports it natively) rather than opening 50001. If
you must open it, use SSL (port 50002) or restrict the firewall rule to specific
client IPs (`sudo ufw allow from <client-ip> to any port 50001`).

## Esplora (REST explorer backend)

> For the **REST API alone** (BDK / wallet clients), you don't need this — use
> forseti's [built-in Esplora API](#built-in-esplora-rest-api-recommended-no-sidecar)
> above. Run Blockstream's Esplora as a sidecar only when you want its
> **web block-explorer frontend** or the Electrum protocol alongside.

[Esplora](https://github.com/Blockstream/electrs) is Blockstream's fork of
electrs. It adds the **Esplora HTTP REST API** (`/address/:addr`, `/tx/:txid`,
`/block/:hash`, `/scripthash/:hash/utxo`, `/mempool`, `/fee-estimates`, …) and
a web block-explorer frontend on top of the Electrum protocol. It's what
[BDK's `esplora` backend](https://docs.rs/bdk_esplora), mempool.space-style
explorers, and most browser wallets target.

**Key difference from romanz/electrs:** Esplora reads the node's block files
**directly off disk** (`<datadir>/blocks/blk*.dat`) instead of pulling them
over P2P, and uses the RPC only for the header chain, mempool, broadcast, and
fee estimates. forseti writes those flat files in **Bitcoin Core's exact
format** — `[network-magic:4 LE][size:4 LE][raw block]` records in
`blk%05d.dat` files with the correct per-network magic — so Esplora's block
reader can parse them unchanged. It does **not** read forseti's block-index or
undo (`rev*.dat`) files; it builds its own index and orders blocks via RPC.

Because it reads the files directly, **Esplora must run on the same machine /
filesystem as the node** (point `--daemon-dir` at the forseti datadir), and the
node must be **unpruned**.

```bash
# forseti regtest/signet/mainnet — unpruned; same host as Esplora
./forseti --network=signet --datadir=~/forseti-signet --daemon

# Blockstream/electrs (Esplora)
electrs \
  --network signet \
  --daemon-dir ~/forseti-signet \                 # reads blocks/blk*.dat here
  --daemon-rpc-addr 127.0.0.1:38332 \
  --cookie-file ~/forseti-signet/.cookie \
  --db-dir ~/esplora-db \
  --http-addr 127.0.0.1:3000 \                     # Esplora REST API
  --electrum-rpc-addr 127.0.0.1:60601              # Electrum protocol (optional)

# REST: curl http://127.0.0.1:3000/blocks/tip/height
```

The RPCs Esplora calls are all covered (forseti implements 87/94 Core v30
non-wallet RPCs). The mempool/tx shapes it parses strictly — `getrawmempool
verbose`, `getrawtransaction`'s `hex` field, and `chainwork` on
`getblock`/`getblockheader` — are all present. Esplora indexes from blk files,
so the RPCs it does *not* need (`getblock` verbosity 3 prevouts,
`gettxoutsetinfo` muhash) being partial doesn't matter.

> **Status:** format- and RPC-compatible by construction, but not yet verified
> end-to-end against a live Esplora build. Use the regtest playbook below to
> validate a specific Esplora version before relying on it.

## mempool.space (explorer + mempool visualizer)

[mempool.space](https://github.com/mempool/mempool) is a full explorer *stack*,
not a single service: a Node.js **backend** that talks to the node over RPC, an
**indexer** for address lookups (its own `mempool/electrs` fork, or
romanz/electrs / Fulcrum), an optional MariaDB for historical stats, and the web
frontend. From the *node* it needs the same things electrs/Esplora do, so it
runs on the same footing against forseti.

**RPC compatibility (verified by grepping the backend source):** the Core-RPC
path calls 25 methods — **all implemented by forseti** — plus two it can run
without: `submitpackage` (only the optional `POST /txs/package` broadcast
endpoint; *not* on the indexing/mempool path) and `tweakFedPegScript`
(Liquid-only). It leans on `getrawmempool` (plain **and** `verbose=true`),
`getrawtransaction` (needs the `hex` field), `getmempoolentry`, `getblock`
(verbosity 0/1/2 only), and `chainwork` — all present. It does **not** use
`getrawmempool mempool_sequence` (it diffs the txid list itself), so no extra
RPC work is required.

**Requirements from the node:**
- RPC with `txindex=1`, `server=1`, and auth → forseti: `--txindex --server=1`
  plus a cookie or `--rpcuser`/`--rpcpassword`
- an Electrum/Esplora indexer alongside (mempool's electrs fork, romanz/electrs,
  or Fulcrum) — same setup as the sections above
- unpruned node

**Sketch** — start forseti with matching auth + txindex, run the indexer
(Esplora section above) against the same datadir, then point the mempool backend
at both via its `mempool-config.json`:
```json
{
  "CORE_RPC":  { "HOST": "127.0.0.1", "PORT": 8332,
                 "USERNAME": "mempool", "PASSWORD": "mempool" },
  "ESPLORA":   { "REST_API_URL": "http://127.0.0.1:3000" },
  "DATABASE":  { "ENABLED": true }
}
```
```bash
./forseti --network=mainnet --datadir=~/forseti --txindex \
  --rpcuser=mempool --rpcpassword=mempool     # unpruned; same host as the stack
```

> **Status:** every RPC it needs is covered and the electrs/Esplora layer it
> sits on already works against forseti, but the full stack has not been run
> end-to-end yet. The only known degradation is the package-broadcast endpoint
> (`POST /txs/package`, needs `submitpackage` — not implemented). Validate a
> specific build with the regtest playbook below.

## Testing integrations on regtest

A fast local smoke test that exercises both paths without waiting on IBD:

```bash
# 1. Start forseti on regtest with the indexes electrs/esplora may want.
#    --connect to a dead peer keeps regtest from exiting "no peers".
./forseti --network=regtest --datadir=/tmp/forseti-rt \
  --txindex --blockfilterindex=1 --connect=127.0.0.1:18499 &

# 2. Mine some blocks to a known address (needs no wallet — derive one).
COOKIE=$(cat /tmp/forseti-rt/.cookie)
rpc() { curl -s -u "$COOKIE" -d "$1" http://127.0.0.1:18443/; }
DESC=$(rpc '{"method":"getdescriptorinfo","params":["wpkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)"]}' | jq -r .result.descriptor)
ADDR=$(rpc "{\"method\":\"deriveaddresses\",\"params\":[\"$DESC\"]}" | jq -r '.result[0]')
rpc "{\"method\":\"generatetoaddress\",\"params\":[101,\"$ADDR\"]}"   # 101 → mature coinbase

# 3a. romanz/electrs (Electrum path):
electrs --network regtest --daemon-rpc-addr 127.0.0.1:18443 \
  --daemon-p2p-addr 127.0.0.1:18444 --cookie-file /tmp/forseti-rt/.cookie \
  --db-dir /tmp/electrs-rt -vvvv
#   → expect the index to build to the tip with no errors; then query via an
#     Electrum client or `echo '...' | nc 127.0.0.1:60401`.

# 3b. Blockstream/electrs (Esplora path):
electrs --network regtest --daemon-dir /tmp/forseti-rt \
  --daemon-rpc-addr 127.0.0.1:18443 --cookie-file /tmp/forseti-rt/.cookie \
  --db-dir /tmp/esplora-rt --http-addr 127.0.0.1:3000 -vvvv
#   → curl http://127.0.0.1:3000/blocks/tip/height
#     curl http://127.0.0.1:3000/address/$ADDR
#     curl http://127.0.0.1:3000/block-height/1
```

**What to watch for:** electrs parses several RPC responses field-by-field, so
the failure mode is a specific parse error in the electrs log (a missing/renamed
field), not a crash — capture the log and match the field back to the handler in
`rpc/handlers.odin`. The block-file reader failing to parse would point at a
`blk*.dat` framing mismatch (it isn't expected — the format is Core-identical —
but it's the first thing to check if Esplora indexes zero blocks).

For consumers that DO want ZMQ (LND's bitcoind backend, custom indexers),
forseti implements Bitcoin Core's publisher interface natively (no libzmq
dependency — ZMTP 3.0 spoken directly):

```bash
./forseti --zmqpubrawblock=tcp://127.0.0.1:28332 --zmqpubrawtx=tcp://127.0.0.1:28333
```

Topics: `hashblock`, `hashtx`, `rawblock`, `rawtx`, `sequence` — payloads
and per-topic LE32 sequence numbers match Core exactly (verified against
libzmq subscribers).

