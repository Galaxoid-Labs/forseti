# bitcoin-node-odin

A Bitcoin full node implementation written in [Odin](https://odin-lang.org/). Built from scratch with no Bitcoin library dependencies — only libsecp256k1 for elliptic curve cryptography, vendored RIPEMD-160, and vendored LMDB for storage.

This is an educational/experimental project. It implements the core components of a Bitcoin node: cryptographic primitives, wire protocol serialization, script interpretation (including SegWit and Taproot), consensus validation, ACID-compliant persistent storage (LMDB), UTXO management, P2P networking with headers-first sync, mempool, and a JSON-RPC interface.

## Status

**163 tests passing** across 9 packages. Successfully syncs the full signet blockchain (~294k blocks) with script verification.

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete (14 tests) |
| 1 | Wire Protocol + Serialization | Complete (24 tests) |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH) | Complete (45 tests) |
| 2b | Taproot (BIP341/342) | Complete |
| 3 | Consensus Rules + Block Validation | Complete (15 tests) |
| 4 | UTXO Set + Chain State | Complete (8 tests) |
| 5 | Persistent Storage (LMDB) | Complete (13 tests) |
| 6 | P2P Networking | Complete (6 tests) |
| 7 | Mempool + Persistence | Complete (12 tests) |
| 8-10 | RPC Interface (23 methods) | Complete (26 tests) |
| 11 | P2P Integration + CLI + Shutdown | Complete |
| 12 | Signet Sync (BIP325) | Complete |
| 13 | LMDB Storage Migration | Complete |
| 14 | Multi-peer Block Download + Bandwidth Scoring | Complete |
| 15 | Mempool Persistence + Transaction Relay | Complete |
| 16 | Sighash Caching + Arena Safety | Complete |

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- C compiler (`cc` / `clang` / `gcc`)
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)

**C libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) — included as a git submodule, built with schnorrsig + recovery + extrakeys modules
- [LMDB](https://github.com/LMDB/lmdb) — vendored C source in `deps/lmdb/` (Lightning Memory-Mapped Database)
- RIPEMD-160 — vendored C implementation in `deps/ripemd160/`

## Building

```bash
# Clone with submodules
git clone --recursive https://github.com/youruser/bitcoin-node-odin.git
cd bitcoin-node-odin

# If you already cloned without --recursive:
git submodule update --init --recursive

# Build everything (deps + binary)
make

# Or step by step:
make deps    # Build C libraries
make build   # Build the node binary
make debug   # Build with debug symbols
```

The binary is output as `btcnode` in the project root.

## Running

```bash
# Sync the signet network
./btcnode --network=signet --datadir=/tmp/btcnode-signet

# Start in regtest mode (default, no peers needed)
./btcnode --network=regtest --no-p2p

# Start with all options
./btcnode --network=regtest \
          --datadir=/tmp/btcnode-data \
          --rpcport=18443 \
          --no-p2p

# Connect to a specific peer
./btcnode --network=mainnet --connect=127.0.0.1:8333

# Show help
./btcnode --help
```

### CLI Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--network=<name>` | `mainnet`, `testnet3`, `testnet4`, `signet`, `regtest` | `regtest` |
| `--datadir=<path>` | Data directory for blocks, index, UTXO database | `/tmp/btcnode-data` |
| `--rpcport=<port>` | JSON-RPC port | Network default |
| `--connect=<ip:port>` | Connect to a specific peer | DNS discovery |
| `--p2p-port=<port>` | P2P listen port | Network default |
| `--no-p2p` | Disable P2P (RPC-only mode) | `false` |

### Config File

The node reads an optional `btcnode.conf` from the data directory (`<datadir>/btcnode.conf`). The format mirrors Bitcoin Core's `bitcoin.conf` — INI-style with `#` comments and `[section]` network overrides.

**Precedence:** CLI flags > config file > defaults

```ini
# /tmp/btcnode-data/btcnode.conf

network=regtest
rpcport=18443
connect=127.0.0.1:18444
no-p2p=1

# Network-specific sections override global values
[regtest]
rpcport=19443
```

Keys match CLI flag names without the `--` prefix. Boolean values accept `1`, `true`, or `yes` for on.

Values in a network-specific section (e.g. `[regtest]`) take priority over global values. CLI flags always override both.

### Default Ports

| Network | RPC Port | P2P Port |
|---------|----------|----------|
| mainnet | 8332 | 8333 |
| testnet3 | 18332 | 18333 |
| testnet4 | 48332 | — |
| signet | 38332 | 38333 |
| regtest | 18443 | 18444 |

## RPC Interface

The node exposes a JSON-RPC 1.0 interface over HTTP. Use `bitcoin-cli` or `curl` to interact:

```bash
# Using curl
curl -s --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using bitcoin-cli
bitcoin-cli -rpcport=18443 getblockchaininfo
```

### Available Methods (23)

**Blockchain:**
- `getblockchaininfo` — Chain info, BIP activation heights
- `getblockcount` — Current block height
- `getblockhash <height>` — Hash at height
- `getbestblockhash` — Tip hash
- `getblock <hash> [verbosity]` — Block data (0=hex, 1=json)
- `getblockheader <hash> [verbose]` — Header data (false=hex, true=json)
- `getblockstats <hash_or_height>` — Block statistics (fees, sizes, counts)
- `getdifficulty` — Current difficulty
- `getchaintips` — All known chain tips
- `gettxout <txid> <vout> [include_mempool]` — UTXO lookup

**Transactions:**
- `getrawtransaction <txid> [verbose]` — Mempool tx lookup
- `sendrawtransaction <hex>` — Submit tx to mempool
- `decoderawtransaction <hex>` — Decode tx without submitting
- `decodescript <hex>` — Decode script to ASM + type

**Mempool:**
- `getmempoolinfo` — Mempool summary
- `getrawmempool` — All mempool txids
- `getmempoolentry <txid>` — Mempool entry details
- `testmempoolaccept [<hex>, ...]` — Dry-run mempool validation

**Network:**
- `getconnectioncount` — Number of peers
- `getpeerinfo` — Peer details
- `getnetworkinfo` — Network/protocol info

**Control:**
- `stop` — Graceful shutdown
- `uptime` — Seconds since startup

## Testing

```bash
# Run all tests
make test

# Test individual packages
odin test crypto
odin test wire
odin test script
odin test consensus
odin test storage
odin test chain
odin test p2p
odin test mempool
odin test rpc
```

## Project Structure

```
bitcoin-node-odin/
├── main.odin              # Entry point, CLI parsing, config file, thread orchestration
├── Makefile               # Build system
├── crypto/                # SHA-256d, RIPEMD-160, HASH160, secp256k1 bindings, Merkle root
├── wire/                  # Protocol types, CompactSize, tx/block serialization, message framing
├── script/                # Script interpreter, opcodes, standard types, Taproot
├── consensus/             # Chain params, PoW, difficulty, block/tx validation, BIP325 signet
├── storage/               # LMDB store, flat files, block DB, index DB, UTXO DB
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state
├── p2p/                   # Peer connections, sync manager, connection manager
├── mempool/               # Fee rates, relay policy, validation pipeline, persistence
├── rpc/                   # JSON-RPC server, handlers, types
└── deps/                  # C dependencies
    ├── libsecp256k1/      # Git submodule (bitcoin-core/secp256k1)
    ├── lmdb/              # Vendored LMDB source (lmdb.h, mdb.c, midl.h, midl.c)
    ├── ripemd160/         # Vendored C implementation
    └── lib/               # Built static libraries (generated)
```

## Storage Architecture

The node uses [LMDB](http://www.lmdb.tech/doc/) (Lightning Memory-Mapped Database) for crash-consistent persistent storage.

**Single LMDB environment** (`<datadir>/chainstate/`) with 3 named databases:
- `utxo` — Key: outpoint (txid + vout, 36 bytes), Value: encoded UTXO coin (height, coinbase flag, amount, script)
- `index` — Key: block hash (32 bytes), Value: block index record (101 bytes)
- `meta` — Key: `"tip"`, Value: chain tip hash + height (36 bytes)

**Crash consistency**: The UTXO set, block index, and chain tip metadata are committed in a single atomic LMDB write transaction. On unclean shutdown, the node recovers to the last consistent flush point and replays stored-but-not-connected blocks from flat files.

**Block storage** uses flat files (`blk00000.dat`, `rev00000.dat`) with 128MB auto-rollover, matching Bitcoin Core's format. Flat files are ideal for large block blobs; LMDB handles the structured key-value data.

## What's Left to Build

### Correctness

- **Large UTXO script handling** — UTXOs with scripts >~10KB fail to persist to LMDB (`Value_Too_Large`). Needs chunked storage or increased LMDB limits. Affects a handful of signet test transactions.
- **Testnet3 20-min difficulty rule** — When block timestamp >20min after previous, difficulty resets to `pow_limit`
- **Allocator audit** — Systematic review of `delete()` usage to ensure no heap corruption from mismatched allocators

### Performance

- **Batch `connect_block` LMDB writes** — Each connected block does individual `index_db_put` with fsync. Could batch like header sync for faster IBD.
- **Parallel script verification** — Currently single-threaded; matters for mainnet
- **Simplify header sync** — Peer racing logic can be simplified to single-peer now that LMDB batching removed the bottleneck

### Protocol Enhancements

- **RBF (BIP125)** — Replace-by-fee; currently first-tx-wins
- **Ancestor/descendant limits** — No CPFP chain depth limits (Bitcoin Core uses 25/25)
- **Compact blocks (BIP152)** — Bandwidth-efficient block relay
- **Address encoding** — Base58Check and Bech32/Bech32m for RPC address fields

### Infrastructure

- **`core:nbio` migration** — Replace thread-per-peer with async I/O event loop (waiting for Odin's nbio package to mature)

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread, one reader thread per peer
- **Graceful shutdown**: SIGINT/SIGTERM triggers mempool save, atomic UTXO + metadata flush to LMDB, then clean exit
- **Headers-first sync**: Single lead peer downloads headers via `getheaders`/`headers`, with automatic failover if the lead disconnects. Headers are batched into single LMDB write transactions (up to 2000 per batch)
- **Multi-peer block download**: Round-robin block requests across all active peers (up to 8), with bandwidth-based scoring — fast peers get more slots (up to 64), slow peers get fewer (minimum 4), new peers get a trial allocation of 8 blocks
- **Stall detection**: Blocks stalled >30s are requeued to other peers; header requests timeout after 60s with lead peer failover
- **DNS peer discovery**: Resolves all A records from DNS seeds (typically 20+ addresses per seed)
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed atomically to LMDB every 1000 blocks during sync. Rollback support for failed block validation
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup, persisted to LMDB
- **Sighash caching**: BIP143 (SegWit v0) and BIP341 (Taproot) intermediate hashes are cached per-transaction, avoiding O(n^2) re-computation for transactions with many inputs
- **Per-input verification arena**: A 2MB heap-allocated scratch arena is reset between each input's script verification, preventing sighash writer accumulation from exhausting the 64MB block arena on large transactions
- **Mempool persistence**: Mempool is saved to `<datadir>/mempool.dat` on shutdown and reloaded/revalidated on startup
- **Transaction relay**: P2P `inv`/`tx`/`getdata` handling for propagating mempool transactions to peers
- **Assumevalid**: Skips script verification for blocks below a configured height (250,050 for signet) for faster initial sync
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

## License

MIT
