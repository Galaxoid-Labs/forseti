# Address Index + Electrum/Esplora Server for forseti (wallet backend)

> **STATUS (2026-07-10): DESIGN ONLY — NOT IMPLEMENTED.** Plan for making forseti a
> self-contained wallet backend: an in-node scripthash (address) index built
> *during block connection*, plus in-process Electrum + Esplora servers so BDK /
> Electrum / Sparrow can point straight at forseti. All in the **same binary**,
> opt-in, off by default (zero cost when disabled).

## Goal

Let a wallet use forseti directly as its backend — no electrs/Fulcrum sidecar:

```
./forseti --network=mainnet --index-addresses --electrum --esplora
```

- `--index-addresses` — build the scripthash→history/UTXO index (off by default).
- `--electrum[=addr:port]` — serve the Electrum protocol (default off).
- `--esplora[=addr:port]` — serve the Esplora REST HTTP API (default off).

BDK's `electrum` and `esplora` backends, Electrum, and Sparrow then work against
forseti unmodified.

## BDK compatibility — the north star (build exactly this)

The whole point is **connect a BDK wallet to forseti.** BDK ships two relevant
backends; we only need to satisfy **one** of them to be usable, and both key on the
same underlying data (scripthash history + tx fetch + chain tip + fee + broadcast).
Target the *exact* call sets below — don't over-build.

**BDK `esplora` backend** (esplora-client) — the minimal endpoints it calls:
- `GET /scripthash/:hash/txs` **and paginated `…/txs/chain/:last_seen_txid`** —
  the core of a wallet sync (BDK walks derived scripthashes to the gap limit,
  paginating by last-seen txid). **This is the endpoint that must be right.**
- `GET /tx/:txid`, `GET /tx/:txid/status`, `GET /tx/:txid/raw` (or `/hex`)
- `GET /block-height/:height` (→ hash), `GET /block/:hash/header`
- `GET /blocks/tip/hash`, `GET /blocks/tip/height`
- `GET /fee-estimates`
- `POST /tx` (broadcast)

**BDK `electrum` backend** (electrum-client) — the minimal methods it calls:
- `blockchain.scripthash.get_history` (per derived scripthash; batched) — the core
- `blockchain.transaction.get`, `blockchain.transaction.broadcast`
- `blockchain.transaction.get_merkle` (SPV proof; only if validating)
- `blockchain.headers.subscribe` / `blockchain.block.headers` (tip)
- `blockchain.estimatefee`, `server.version`, `server.ping`

**Recommendation:** ship the **Esplora REST backend first** (Phase 1) — the HTTP
server already exists in `rpc/`, the endpoint set is tiny and stateless (no
subscriptions needed for a basic sync), and it directly satisfies `bdk_esplora`.
That's the fastest path to "a BDK wallet syncs against forseti." Electrum (Phase 2)
adds `bdk_electrum` + Electrum/Sparrow and the push/subscribe niceties.

**Acceptance test for both:** a BDK descriptor wallet does a full scan + sync +
broadcast against forseti and produces the *same* UTXOs/balance/tx history as the
same wallet pointed at a reference electrs. If that passes, we're BDK-compatible.

## Why in-node beats electrs/Fulcrum (the whole point)

electrs/Fulcrum are **external** processes: they must re-read and re-parse the
entire chain from bitcoind to build their index — a full second pass over ~700 GB,
plus heavy DB compaction. That's why a full Esplora index takes 12–36h even on
fast hardware.

**forseti already parses and connects every block**, and during `connect_block` it
already touches every output *and* fetches every spent input's prevout coin (with
its `scriptPubKey`) for validation. So:

> Build the scripthash index **in the same pass** — no separate re-scan. During
> IBD the address index materializes alongside the chain for near-free; at the tip
> each block updates it as it connects.

Two concrete edges over electrs:
1. **No re-scan** — electrs's slowest phase disappears (index-as-you-connect).
2. **Free spend-side scripthash** — forseti already has the prevout `scriptPubKey`
   in hand during connect (from the coins cache / undo data). electrs has to look
   each prevout up separately; forseti doesn't. txids are also already computed
   during deserialization — no recompute.

This is the same shape as the two indexes forseti already ships: `--txindex`
(`chain/txindex.odin`) and the BIP158 filter index (`chain/blockfilter.odin`),
both of which hook connect/disconnect and live in their own LevelDB. The address
index is a third index of that family.

## Scripthash

Electrum/Esplora address queries key on the **scripthash** =
`sha256(scriptPubKey)` **byte-reversed** (Electrum convention). forseti has
`crypto.sha256`. Indexing by scripthash (not address) is script-type-agnostic and
matches both protocols; address→scripthash is derived at the API edge.

## Index schema (own LevelDB at `<datadir>/addrindex/`)

Two column families / key prefixes, both maintained in the connect/disconnect pass:

- **History** (answers Electrum `get_history` / Esplora `/address/:a/txs`):
  ```
  key:  'H' | scripthash(32) | height(4 BE) | txid(32) | io(1) | idx(4)
  val:  (empty)
  ```
  Prefix-scan `H|scripthash` → the script's full history in height order. `io` =
  funding(0)/spending(1), `idx` = vout/vin. Added for every output's scriptPubKey
  (funding) and every spent prevout's scriptPubKey (spending, already in hand).

- **UTXO-by-scripthash** (answers `listunspent` / `/address/:a/utxo` / balance):
  ```
  key:  'U' | scripthash(32) | txid(32) | vout(4)
  val:  height(4) | value(8)
  ```
  Added on funding, deleted on spend — exactly like the main UTXO set but keyed by
  scripthash. Prefix-scan `U|scripthash` → unspent outputs → balance/utxo/listunspent.

**Tx bytes** (for `/tx/:txid`, `transaction.get`) — **no separate `--txindex`
required.** Two cases:
- Txs the wallet discovered via scripthash history already carry `(height, tx
  position)` in the H-row → read straight from the blk file. No lookup.
- A bare `GET /tx/:txid` for an arbitrary id needs `txid → location`. Since we're
  already walking every tx during connect, the address index maintains its **own**
  `txid → (height, position)` map (a 3rd small key prefix, `'T'`) — self-contained.
  If `--txindex` is already enabled, **reuse it** instead of duplicating.

So `--index-addresses` is a **complete, one-flag wallet backend**. The txid→location
data costs ~the same whether it's `--txindex` or bundled here (~tens of GB) — pay
once, and the user needn't juggle two index flags.

## Connect / disconnect hooks (reorg-safe)

- **connect_block**: after validation, for each tx: emit funding rows for its
  outputs, spending rows for its inputs (prevout scriptPubKeys are already fetched
  for validation), and update the U-index. One extra write pass over data already
  in cache — no re-read.
- **disconnect_block**: forseti's **undo records already contain the spent coins'
  scriptPubKeys**, and the block gives the created outputs — so we can delete
  exactly the H/U rows this block added and restore spent U rows. (Alternative: a
  small per-block "index journal" of added keys for precise deletes; decide during
  impl.) Either way reorgs are handled with existing undo infra.

## Mempool (unconfirmed)

Electrum/Esplora must return unconfirmed history/UTXOs too. Maintain a **small
in-memory scripthash index over the mempool**, updated on the mempool's existing
add/evict hooks (forseti already tracks mempool add/remove, and drives ZMQ
`sequence`/`rawtx`). Queries merge confirmed (LevelDB) + mempool (in-mem).

## Serving layer (in-process, like the JSON-RPC server thread)

- **Esplora REST (HTTP)** — reuse the `rpc/` HTTP server (thread-per-connection,
  keep-alive already there). Endpoints BDK/mempool-frontend use:
  `/address/:a`, `/address/:a/txs`, `/address/:a/utxo`, `/scripthash/:h/*`,
  `/tx/:txid[/hex|/status|/raw]`, `/block/:hash`, `/block-height/:h`,
  `/blocks/tip/{height,hash}`, `/fee-estimates`, `POST /tx` (broadcast). Most map
  onto data forseti already has (blocks, mempool, fee estimator, the new index).
  → **BDK `esplora` backend works.**
- **Electrum protocol (TCP, JSON-line)** — a new small `electrum/` package + a TCP
  server thread. Core methods: `blockchain.scripthash.{get_history,listunspent,
  get_balance,subscribe}`, `blockchain.transaction.{get,broadcast,get_merkle}`,
  `blockchain.headers.subscribe`, `blockchain.estimatefee`, `server.{version,
  banner,ping}`. → **BDK `electrum` backend, Electrum, Sparrow work.**
- **Subscriptions** — `scripthash.subscribe` / `headers.subscribe` push on new
  blocks/mempool changes; wire to the same 1 Hz/new-block signals that feed ZMQ and
  the Node_Status tick.

## Config / flags

- `--index-addresses` (persisted like txindex; prune-incompatible — refused with
  `--prune`, same as txindex, since history needs full chain/tx access).
- `--electrum[=127.0.0.1:50001]`, `--esplora[=127.0.0.1:3000]` — both require the
  index; both default off. Auth/bind rules mirror the RPC server (`--rpcbind`/
  allowlist style) for the HTTP one.
- All off by default → **zero cost and zero new threads when unused.**

## Startup / backfill

- **Fresh sync:** index builds incrementally during IBD (near-free).
- **Already-synced node:** one-time backfill — walk the chain reading blocks
  (reuse the block reader + the worker pool to parallelize scripthash hashing and
  row generation), like the `txindex` startup catch-up. Faster than electrs
  (own blk files, reuse parsing/txids, no external RPC), and resumable via a
  "best indexed height" marker like txindex's `"best"` key.

## Phased delivery

1. **Index + Esplora REST** → BDK `esplora` backend works end-to-end. (Biggest
   value, smallest protocol surface; HTTP infra already exists.)
2. **Electrum protocol** → BDK `electrum`, Electrum, Sparrow.
3. **Subscriptions / push** → real-time wallet updates (headers + scripthash).
4. Optional: multi-address `batch`, `/mempool` stats, gap-limit-friendly helpers.

## Testing

- **Index correctness:** on regtest/signet, diff forseti's history/UTXO/balance for
  a set of scripthashes against electrs and against `scantxoutset`/a reference —
  must match exactly.
- **Reorg:** mine competing branches; confirm H/U rows and balances are correct
  after disconnect/reconnect (the fund-safety-critical bit).
- **BDK integration:** run BDK's `esplora` and `electrum` backends against forseti
  and sync a descriptor wallet; compare to the same wallet via a real electrs.
- **Protocol conformance:** a handful of Electrum-method + Esplora-endpoint golden
  tests; broadcast round-trips through the existing tx-relay path.
- **No-regression:** with all flags off, IBD and RPC are byte-for-byte unchanged.

## Cost / perf notes

- The address index is inherently **large** (full per-script history — hundreds of
  GB on mainnet), so it's opt-in. But we skip electrs's whole re-scan, and writes
  ride along with connect. Consider whether LevelDB (existing) suffices or whether
  a sorted flat-file layout for the H-index reduces compaction (the electrs pain
  point) — measure first, optimize second.
- Extra connect-time work is one write pass over data already in cache + scripthash
  sha256 per output/input — parallelizable on the worker pool if it ever bites.

## Risks / open questions

- **Reorg deletes** must be exact — a stale H/U row = wrong wallet balance. Undo
  records give the spent scriptPubKeys; verify that's sufficient vs. keeping a
  per-block index journal.
- **Storage size** — hundreds of GB; document it and keep it opt-in.
- **Mempool index** correctness under RBF/eviction — reuse the existing mempool
  add/remove hooks so it can't drift.
- **API surface creep** — BDK needs a specific subset; scope to that first, don't
  chase full mempool.space-frontend parity in phase 1.
- **DB engine** — LevelDB is single-writer/single-process, which is fine here since
  the servers run in-process (same binary). (This is exactly why we chose
  same-binary over a separate serving binary — no cross-process DB sharing.)

## References

- forseti index precedents: `chain/txindex.odin` (txid index), `chain/blockfilter.odin`
  (BIP158) — the connect/disconnect + own-LevelDB + startup-catchup pattern.
- Serving infra: `rpc/server.odin` (HTTP server, thread-per-conn, auth/bind),
  `zmq/` + Node_Status tick (new-block/mempool signals for subscriptions).
- Protocols: Electrum protocol spec; Esplora HTTP API (`Blockstream/esplora`
  `API.md`); BDK `esplora`/`electrum` backends.
- Prior art / why in-node wins: electrs (`Blockstream/electrs` new-index) and
  Fulcrum — both external re-scanners; see docs/plans notes and
  memory/esplora-electrs-integration.
