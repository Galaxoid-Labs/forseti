# Architecture

## Project Structure

```
forseti/
├── main.odin              # Entry point, CLI parsing (core:flags), config file, thread orchestration
├── Makefile               # Build system
├── contrib/               # forseti.conf.sample (commented reference config)
├── crypto/                # SHA-256d, RIPEMD-160, HASH160, secp256k1 (verify+sign+ElligatorSwift), Merkle root, address encoding, WIF, SipHash-2-4, GCS (BIP158)
├── wire/                  # Protocol types, CompactSize, tx/block serialization, message framing, compact blocks (BIP152), addrv2 (BIP155), filter messages (BIP157)
├── script/                # Script interpreter, opcodes, standard types, Taproot (BIP341/342)
├── consensus/             # Chain params, PoW, difficulty, block/tx validation, BIP325 signet
├── storage/               # LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB, filter DB
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state, block filter building
├── p2p/                   # Peer connections, sync manager, connection manager, address manager, BIP324 v2 transport, inbound listener
├── mempool/               # Fee rates, relay policy, validation pipeline, RBF, persistence, configurable limits
├── rpc/                   # JSON-RPC server (73 methods, threaded + keep-alive + batch)
├── descriptor/            # Output descriptors: checksum, BIP32 CKDpub, parser, script/address generation
├── drivechain/            # BIP300/301: M1-M6 + BMM codecs, D1/D2 state machine, enforce-mode validation
├── zmq/                   # Native ZMTP 3.0 PUB sockets (Core zmqpub* parity, no libzmq)
├── gui/                   # raylib/raygui dashboard renderer (in-process + remote)
├── guiapp/                # Standalone forseti-gui remote client (GUI + TUI + --probe)
├── tui/                   # ncurses terminal dashboard renderers/formatters
├── ncurses/               # Minimal libncurses FFI bindings
└── deps/                  # C/C++ dependencies
    ├── libsecp256k1/      # Git submodule (bitcoin-core/secp256k1 v0.7.1)
    ├── leveldb/           # Git submodule (google/leveldb 1.23)
    ├── ripemd160/         # Vendored C implementation
    └── lib/               # Built static libraries (generated)
```

## Storage Architecture

The node uses two [LevelDB](https://github.com/google/leveldb) instances for crash-consistent persistent storage:

**Chainstate database** (`<datadir>/chainstate/`):
- UTXO entries — Key: outpoint (txid + vout), Value: encoded coin (height, coinbase flag, amount, script)
- Chain tip metadata — Key: `"tip"`, Value: tip hash + height
- Drivechain state (when `--drivechain` is on) — Key: `"dcstate"`, Value: tip hash + height + D1/D2 snapshot, written in the same synced batch as the tip marker (atomic with it)
- Rolling UTXO stats — Key: `"utxostats"`, Value: coin count + total sats, also written in the tip-marker batch; maintained by the coins-cache add/spend/restore hooks so `gettxoutsetinfo` answers instantly (datadirs predating the key fall back to a full scan until resynced; `--repairutxo` invalidates it)

**Block index database** (`<datadir>/blocks/index/`):
- Block index entries — Key: block hash, Value: block index record (height, status, file location, header fields)
- Drivechain undo records — Key: `"dcu"` + height, Value: block hash + pre-block D1/D2 snapshot; written only when a block changes drivechain state, used to restore it on disconnect/reorg

Cache sizes are configurable via `--dbcache=<MB>` (default 450 MiB), split following Bitcoin Core's algorithm: block index DB gets min(total/8, 2 MiB), chainstate DB gets min(remaining/2, 8 MiB), and the remainder goes to the in-memory UTXO coins cache. Both databases use 10-bit bloom filters, 2 MiB write buffers, and no compression. UTXO changes and chain tip metadata are committed atomically via LevelDB WriteBatch. The coins cache flushes in the background (memtable rotation — sync never stalls) when memory usage exceeds the budget, with a durability safety net every 25,000 blocks (every 5,000 for budgets under 1 GiB). Flush WriteBatches are chunked at 16 MB (Core's dbbatchsize) with the tip marker written last in its own synced batch.

**Transaction index** (`--txindex`, `<datadir>/txindex/` LevelDB): txid → (block hash, position), maintained by connect/disconnect and caught up at startup from a persisted best marker (idempotent per-block writes — a crash loses at most the recent tail and the catch-up re-converges). Lookups resolve the block through the block index and read the tx from the flat files, which is why the index refuses to run with pruning (Core parity).

**Block storage** uses flat files (`blk00000.dat`, `rev00000.dat`) with 128MB auto-rollover, matching Bitcoin Core's format. Flat files store the raw block blobs; LevelDB handles the structured key-value data.

**UTXO set contents**: provably-unspendable outputs (OP_RETURN, oversized scripts) are never added as coins (Core parity). `--repairutxo` re-derives spent-ness from local block data as a maintenance sweep.

**Crash recovery**: On unclean shutdown, the node rolls the UTXO set back to the last flush point using per-block undo records (Bitcoin Core ReplayBlocks-style — correct over arbitrarily partial flush states), then re-validates forward from flat files. Undo locations are persisted in the block index; recovery progress renders live on the GUI loading screen. If recovery cannot verify, the node refuses to start rather than run inconsistent.

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread (`core:nbio` event loop — kqueue on macOS, epoll on Linux), N script verification worker threads (`--par`). No per-peer threads — all peer I/O is multiplexed on a single event loop with async connect/recv/send callbacks
- **Graceful shutdown**: SIGINT/SIGTERM triggers mempool save, atomic UTXO + metadata flush to LevelDB, then clean exit
- **Headers-first sync**: Single lead peer downloads headers via `getheaders`/`headers`, with automatic failover if the lead disconnects. Headers are batched into single WriteBatch transactions (up to 2000 per batch)
- **Multi-peer block download**: Fastest-first block assignment across all active peers (up to 8) — peers are sorted by throughput and the fastest peer gets tip-adjacent blocks so slow peers can't block chain progress. Bandwidth-based scoring: fast peers get more slots (up to 16), slow peers fewer (minimum 4), new peers get a trial allocation of 8 blocks
- **Compact block relay (BIP152)**: Full send + receive implementation — negotiates compact block v2 (wtxid-based short IDs) with peers. **Receive**: reconstructs blocks from mempool using SipHash-2-4 short ID matching, requests missing transactions via `getblocktxn`/`blocktxn`, falls back to full block download after 10s timeout. **Send**: announces newly connected blocks to compact-capable peers via `cmpctblock`, `sendheaders` peers via `headers`, and legacy peers via `inv`. Serves `getblocktxn` requests by reading blocks from flat files. Serves full blocks via `getdata`. Reduces block relay bandwidth by ~90% when mempool is populated
- **V2 encrypted transport (BIP324)**: Encrypted P2P, on by default (`--v2transport=0` to disable). ElligatorSwift ECDH key exchange (libsecp256k1), FSChaCha20 length encryption + FSChaCha20Poly1305 AEAD packet encryption rekeying every 224 messages per BIP324, HKDF-SHA256 key derivation. V2 transport state machine handles handshake (ell64 exchange → garbage terminator → version packet with garbage AAD → active). 28 short command IDs for bandwidth efficiency. Automatic v1 fallback: 5-second handshake timeout, v1 magic byte detection on first wire byte, per-address tracking to skip v2 on reconnect
- **Compact block filters (BIP157/158)**: Optional `--blockfilterindex` builds GCS (Golomb-coded set) basic filters during block connection. Filters are stored in a dedicated LevelDB instance (`<datadir>/filters/`). P2P serves `getcfilters`, `getcfheaders`, and `getcfcheckpt` requests. `getblockfilter` RPC returns the filter for a given block hash. `NODE_COMPACT_FILTERS` service bit advertised when enabled
- **Steady-state sync**: BIP130 `sendheaders` for header announcements, periodic `getheaders` polling (120s), and `inv`-triggered header requests keep the node up-to-date after IBD
- **Stall detection**: 10s flat timeout — peers that can't deliver a block in time are replaced. Slow peers (throughput <10% of fastest) are evicted after a trial period. Disconnected peers are replaced via DNS discovery
- **Inbound connections**: TCP listener accepts inbound P2P connections (Bitcoin Core 28 defaults: 125 total = 8 outbound + 116 inbound + 1 reserved). Inbound listener is deferred until sync completes to avoid wasting event loop cycles during IBD. V2 encrypted transport works in both initiator (outbound) and responder (inbound) modes. Inbound V1 fallback is in-place (feeds buffered bytes back to V1 parser, no reconnect). `--listen=0` disables inbound. `--maxconnections=N` controls total budget. `NODE_P2P_V2` (bit 11) advertised in service flags when v2 transport is enabled
- **SOCKS5 proxy (`--proxy`)**: All outbound P2P connections dial the proxy and run an RFC 1928 handshake (no-auth) as an async pre-phase before the Bitcoin transport (v1 or v2) starts. Non-IPv4 targets (.onion, seed hostnames) are sent as DOMAINNAME so the proxy resolves them — no local DNS. With a proxy set, DNS seeds are contacted through the proxy as address-fetch peers (Core behavior) instead of resolved locally, and inbound listening is disabled (it would advertise the real address). Manual `.onion` peers work via `--connect=<host.onion:port>`
- **Outbound topology hardening**: alongside 8 full-relay outbound connections, the node maintains 2 **block-relay-only** connections (version fRelay=false, no tx or addr relay) for eclipse resistance, and runs a **feeler** connection every ~2 minutes to probe a random address-manager entry (failures evict it, keeping the pool honest). The block-relay peers are persisted to `anchors.dat` on shutdown and redialed first on the next start (the file is deleted on read so a crash loop cannot pin the node to poisoned anchors). `--maxuploadtarget=<MiB>` caps the rolling 24h upload budget: once spent, blocks older than a week are not served to inbound peers, but tip relay and headers are unaffected. `getpeerinfo` reports each peer's `connection_type`. A single guard in the dial path prevents duplicate connections to one address across the discovery/replace/block-relay/feeler paths (manual `--connect`/`addnode` bypass it)
- **Peer discovery + addr relay (BIP155)**: DNS seeds populate an address manager at startup. After handshake, `sendaddrv2` is negotiated and `getaddr` requests peers' address lists. Inbound `addr`/`addrv2` messages add to the address manager (FNV-1a dedup, 5000 entry cap). Small announcements (≤10 entries) are forwarded to 1-2 random peers with automatic v1↔v2 format conversion. Replacement peers are drawn from the address manager
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed atomically to LevelDB when memory usage exceeds the configurable budget (`--dbcache`, default 450 MiB). Rollback support for failed block validation
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup, persisted to LevelDB. `by_prev` index provides O(1) next-block lookup for chain traversal
- **Sighash caching**: BIP143 (SegWit v0) and BIP341 (Taproot) intermediate hashes are cached per-transaction, avoiding O(n^2) re-computation for transactions with many inputs
- **Parallel script verification**: Two-phase block validation — Phase 1 processes UTXO updates sequentially (single-threaded, no locking), Phase 2 dispatches all script checks to a persistent thread pool (`--par=N`). Sighash caches are eagerly pre-computed before dispatch so workers read immutable data without synchronization. Serial fallback for small blocks (<16 inputs) or `--par=1`. Workers use growing virtual arenas (8MB initial) from a mutex-protected pool — tapscripts have no size cap, so fixed arenas are unsafe
- **UTXO prefetch**: Before connecting each block, input outpoints not already in the coins cache are collected and read from LevelDB in parallel across the script verification thread pool. This converts sequential LevelDB reads into parallel reads, warming the cache so Phase 1 gets map lookups instead of disk I/O. Especially impactful below assumevalid where the thread pool would otherwise be idle
- **Per-input verification arena**: A growing scratch arena is reset between each input's script verification (serial path), preventing sighash writer accumulation from exhausting the 64MB block arena on large transactions
- **Mempool configuration**: 16 configurable settings matching Bitcoin Core defaults — memory-based size limiting (`--maxmempool`, default 300 MB) with fee-based eviction and dynamic minimum fee, transaction expiry (`--mempoolexpiry`, default 336 hours), ancestor/descendant chain limits (count and size), configurable relay/dust/incremental fees, datacarrier toggle, bare multisig toggle, blocks-only mode (`--blocksonly`), and optional persistence (`--persistmempool`). All settings supported via CLI flags and `forseti.conf`
- **Memory-based mempool limiting**: Tracks total vsize of all entries. When usage exceeds the limit, lowest fee-rate transactions are evicted and the dynamic minimum fee (`mempoolminfee` in `getmempoolinfo`) is raised. Resets when usage drops below the limit after a block connect
- **Mempool persistence**: Mempool is saved to `<datadir>/mempool.dat` on shutdown and reloaded/revalidated on startup (controlled by `--persistmempool`)
- **Fee estimation**: Port of Core's `CBlockPolicyEstimator` — mempool entries are tracked by feerate bucket (×1.05 spacing, 1k–10M sat/kvB) and entry height; block connects record blocks-to-confirm into exponentially decaying moving averages over three horizons (decay 0.962/0.9952/0.99931, scales 1/2/24, up to 1008 blocks); unconfirmed departures count as failures. `estimatesmartfee` returns the median feerate of the lowest bucket range clearing Core's success thresholds (60% half-target / 85% target / 95% double-target, `conservative` mode supported), falling back to the dynamic mempool floor until warmed up. History persists across restarts in `<datadir>/fee_estimates.dat`
- **Transaction relay**: P2P `inv`/`tx`/`getdata` handling for propagating mempool transactions to peers. BIP 133 feefilter: sends our minimum fee rate to peers after handshake, stores each peer's feefilter, skips peers whose feefilter exceeds the tx's fee rate during relay. BIP 339 wtxid relay: negotiates wtxid-based `inv` between `version` and `verack`, announces txs by wtxid to modern peers (txid fallback for legacy peers), mempool maintains a wtxid→txid reverse index for `getdata` lookups. BIP 155 addr relay: negotiates `sendaddrv2` before `verack`, handles `addr`/`addrv2`/`getaddr` messages, forwards small announcements to peers. Cross-thread safety: RPC thread pushes relay items (txid + wtxid + fee rate) to a mutex-protected queue, P2P event loop drains it. `--blocksonly` disables inbound and outbound tx relay (RPC `sendrawtransaction` still works)
- **RBF (BIP125)**: Full replace-by-fee support — signaling check (opt-in or fullrbf), no new unconfirmed parents, higher absolute fee, bandwidth fee (configurable via `--incrementalrelayfee`), max evictions (configurable)
- **Lax DER signature parsing**: Pre-BIP66 transactions may contain non-strictly-encoded DER signatures. The verification path uses a lax DER parser (matching Bitcoin Core's `ecdsa_signature_parse_der_lax`), while strict DER validation is enforced separately by the script interpreter when BIP66 is active
- **Address encoding**: Base58Check (P2PKH, P2SH) and Bech32/Bech32m (P2WPKH, P2WSH, P2TR) for both encoding and decoding, with network-aware validation
- **Configurable DB cache**: `--dbcache` controls total database memory (default 450 MiB), split following Bitcoin Core's algorithm — small LevelDB caches (2-8 MiB), large in-memory coins cache (~440 MiB). Lower values reduce RAM usage at the cost of more frequent UTXO flushes during sync
- **Assumevalid**: Skips script verification below a network-specific height (mainnet=880,000, signet=267,665, testnet3=2,100,000, testnet4=200,000). Configurable via `--assumevalid=<height>` (0 disables)
- **Zero-allocation txid computation**: Transaction IDs are computed from raw stream bytes during block deserialization — non-witness txs hash raw bytes directly, witness txs use incremental `sha256d_multi` (no memory allocation). Pre-computed txids are passed through `connect_block` → `check_block` (Merkle root), eliminating redundant re-serialization. Reduced `connect_block` time by ~23% at mainnet height 360k
- **Drivechain (BIP300/301)**: Opt-in via `--drivechain=track|enforce` (default off = zero cost, no hooks run). D1 (256 sidechain slots) and D2 (withdrawal bundles) live in memory on `Chain_State` and are maintained by `connect_block`/`disconnect_block`. Enforce mode validates M5/M6 escrow spends (CTIP tracking, blinded-hash matching against approved bundles, per the CUSF enforcer semantics) and BIP301 BMM request/accept matching, rejecting violating blocks. Persistence is snapshot-based: the whole state is tiny, so the flush writes it atomically with the tip and each state-changing block stores its pre-block snapshot as the undo record. See [bips.md](bips.md) for the mode semantics and enforce-mode fork warning
- **Block profiling**: Timing instrumentation logs per-phase breakdown every 1000 blocks (read, prefetch, validation, UTXO, scripts, undo, index) for bottleneck identification
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

