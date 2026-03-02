# bitcoin-node-odin

A Bitcoin full node implementation written in [Odin](https://odin-lang.org/). Built from scratch with no Bitcoin library dependencies — only libsecp256k1 for elliptic curve cryptography, vendored RIPEMD-160, and vendored LevelDB for storage.

This is an educational/experimental project. It implements the core components of a Bitcoin node: cryptographic primitives, wire protocol serialization, script interpretation (including SegWit and Taproot), consensus validation, persistent storage (LevelDB), UTXO management, P2P networking with headers-first sync, mempool with RBF, and a JSON-RPC interface with 30 methods.

## Status

**191 tests passing** across 9 packages. Successfully syncs the full signet blockchain (~294k blocks) with script verification.

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete (24 tests) |
| 1 | Wire Protocol + Serialization | Complete (24 tests) |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH, Taproot) | Complete (45 tests) |
| 3 | Consensus Rules + Block Validation | Complete (15 tests) |
| 4 | UTXO Set + Chain State | Complete (8 tests) |
| 5 | Persistent Storage (LevelDB) | Complete (13 tests) |
| 6 | P2P Networking | Complete (6 tests) |
| 7 | Mempool + Persistence + RBF | Complete (20 tests) |
| 8 | RPC Interface (30 methods) | Complete (36 tests) |
| 9 | P2P Integration + CLI + Shutdown | Complete |
| 10 | Signet Sync (BIP325) | Complete |
| 11 | LevelDB Storage Migration | Complete |
| 12 | Multi-peer Block Download + Bandwidth Scoring | Complete |
| 13 | Sighash Caching + Arena Safety | Complete |
| 14 | Steady-state Sync (BIP130) | Complete |
| 15 | RBF (BIP125) | Complete |
| 16 | Address Encoding (Base58Check + Bech32/Bech32m) | Complete |
| 17 | RPC Enrichment (getpeerinfo, mining, network, validation) | Complete |

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- C/C++ compiler (`cc` / `clang` / `g++`)
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)

**C/C++ libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) — included as a git submodule, built with schnorrsig + recovery + extrakeys modules
- [LevelDB](https://github.com/google/leveldb) — vendored C++ source in `deps/leveldb/`
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
make deps    # Build C/C++ libraries
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
| `--mempoolfullrbf=<0\|1>` | Allow full RBF replacement | `1` |

### Config File

The node reads an optional `btcnode.conf` from the data directory (`<datadir>/btcnode.conf`). The format mirrors Bitcoin Core's `bitcoin.conf` — INI-style with `#` comments and `[section]` network overrides.

**Precedence:** CLI flags > config file > defaults

```ini
# /tmp/btcnode-data/btcnode.conf

network=regtest
rpcport=18443
connect=127.0.0.1:18444
no-p2p=1
mempoolfullrbf=1

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

### Available Methods (30)

**Blockchain:**
- `getblockchaininfo` — Chain info, BIP activation heights, softfork status
- `getblockcount` — Current block height
- `getblockhash <height>` — Hash at height
- `getbestblockhash` — Tip hash
- `getblock <hash> [verbosity]` — Block data (0=hex, 1=json, 2=json with decoded txs)
- `getblockheader <hash> [verbose]` — Header data (false=hex, true=json)
- `getblockstats <hash_or_height>` — Block statistics (fees, sizes, counts)
- `getdifficulty` — Current difficulty
- `getchaintips` — All known chain tips

**Transactions:**
- `getrawtransaction <txid> [verbose]` — Mempool tx lookup
- `sendrawtransaction <hex>` — Submit tx to mempool
- `decoderawtransaction <hex>` — Decode tx without submitting
- `decodescript <hex>` — Decode script to ASM + type
- `gettxout <txid> <vout> [include_mempool]` — UTXO lookup

**Mempool:**
- `getmempoolinfo` — Mempool summary (size, fees, RBF status)
- `getrawmempool` — All mempool txids
- `getmempoolentry <txid>` — Mempool entry details
- `testmempoolaccept [<hex>, ...]` — Dry-run mempool validation
- `savemempool` — Dump mempool to disk

**Mining:**
- `getmininginfo` — Mining info (blocks, difficulty, hashrate, pooled txs)
- `getnetworkhashps [nblocks] [height]` — Estimated network hash rate

**Network:**
- `getconnectioncount` — Number of peers
- `getpeerinfo` — Detailed peer info (18 fields: addr, services, bytes, ping, sync state)
- `getnetworkinfo` — Network/protocol info
- `getnettotals` — Total bytes sent/received
- `ping` — Send ping to all peers

**Wallet:**
- `validateaddress <address>` — Validate and decode a Bitcoin address

**Control:**
- `help [method]` — List all methods or get help for a specific method
- `stop` — Graceful shutdown
- `uptime` — Seconds since startup

## Testing

```bash
# Run all 191 tests
make test

# Test individual packages
odin test crypto          # 24 tests
odin test wire            # 24 tests
odin test script          # 45 tests (use -define:ODIN_TEST_THREADS=1 if flaky)
odin test consensus       # 15 tests
odin test storage         # 13 tests
odin test chain           #  8 tests
odin test p2p             #  6 tests
odin test mempool         # 20 tests
odin test rpc             # 36 tests
```

## Project Structure

```
bitcoin-node-odin/
├── main.odin              # Entry point, CLI parsing, config file, thread orchestration
├── Makefile               # Build system
├── crypto/                # SHA-256d, RIPEMD-160, HASH160, secp256k1, Merkle root, address encoding
├── wire/                  # Protocol types, CompactSize, tx/block serialization, message framing
├── script/                # Script interpreter, opcodes, standard types, Taproot (BIP341/342)
├── consensus/             # Chain params, PoW, difficulty, block/tx validation, BIP325 signet
├── storage/               # LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state
├── p2p/                   # Peer connections, sync manager, connection manager
├── mempool/               # Fee rates, relay policy, validation pipeline, RBF, persistence
├── rpc/                   # JSON-RPC server (30 methods), handlers, types
└── deps/                  # C/C++ dependencies
    ├── libsecp256k1/      # Git submodule (bitcoin-core/secp256k1)
    ├── leveldb/           # Vendored LevelDB C++ source
    ├── ripemd160/         # Vendored C implementation
    └── lib/               # Built static libraries (generated)
```

## Storage Architecture

The node uses two [LevelDB](https://github.com/google/leveldb) instances for crash-consistent persistent storage:

**Chainstate database** (`<datadir>/chainstate/`):
- UTXO entries — Key: outpoint (txid + vout), Value: encoded coin (height, coinbase flag, amount, script)
- Chain tip metadata — Key: `"tip"`, Value: tip hash + height

**Block index database** (`<datadir>/blocks/index/`):
- Block index entries — Key: block hash, Value: block index record (height, status, file location, header fields)

Both databases use 256MB LRU caches and 10-bit bloom filters, with no compression. UTXO changes and chain tip metadata are committed atomically via LevelDB WriteBatch.

**Block storage** uses flat files (`blk00000.dat`, `rev00000.dat`) with 128MB auto-rollover, matching Bitcoin Core's format. Flat files store the raw block blobs; LevelDB handles the structured key-value data.

**Crash recovery**: On unclean shutdown, the node recovers to the last consistent flush point and replays stored-but-not-connected blocks from flat files.

## What's Left to Build

### Correctness

- **Testnet3 20-min difficulty rule** — When block timestamp >20min after previous, difficulty resets to `pow_limit`

### Performance

- **Parallel script verification** — Currently single-threaded; matters for mainnet
- **Snappy compression for LevelDB** — Would reduce disk usage for mainnet

### Protocol Enhancements

- **Compact blocks (BIP152)** — Bandwidth-efficient block relay
- **Ancestor/descendant limits** — No CPFP chain depth limits (Bitcoin Core uses 25/25)

### Infrastructure

- **`core:nbio` migration** — Replace thread-per-peer with async I/O event loop (waiting for Odin's nbio package to mature)

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread, one reader thread per peer
- **Graceful shutdown**: SIGINT/SIGTERM triggers mempool save, atomic UTXO + metadata flush to LevelDB, then clean exit
- **Headers-first sync**: Single lead peer downloads headers via `getheaders`/`headers`, with automatic failover if the lead disconnects. Headers are batched into single WriteBatch transactions (up to 2000 per batch)
- **Multi-peer block download**: Round-robin block requests across all active peers (up to 8), with bandwidth-based scoring — fast peers get more slots (up to 64), slow peers get fewer (minimum 4), new peers get a trial allocation of 8 blocks
- **Steady-state sync**: BIP130 `sendheaders` for header announcements, periodic `getheaders` polling (120s), and `inv`-triggered header requests keep the node up-to-date after IBD
- **Stall detection**: Blocks stalled >30s are requeued to other peers; header requests timeout after 60s with lead peer failover
- **DNS peer discovery**: Resolves all A records from DNS seeds (typically 20+ addresses per seed)
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed atomically to LevelDB every 1000 blocks during sync. Rollback support for failed block validation
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup, persisted to LevelDB
- **Sighash caching**: BIP143 (SegWit v0) and BIP341 (Taproot) intermediate hashes are cached per-transaction, avoiding O(n^2) re-computation for transactions with many inputs
- **Per-input verification arena**: A 2MB heap-allocated scratch arena is reset between each input's script verification, preventing sighash writer accumulation from exhausting the 64MB block arena on large transactions
- **Mempool persistence**: Mempool is saved to `<datadir>/mempool.dat` on shutdown and reloaded/revalidated on startup
- **Transaction relay**: P2P `inv`/`tx`/`getdata` handling for propagating mempool transactions to peers
- **RBF (BIP125)**: Full replace-by-fee support — signaling check (opt-in or fullrbf), no new unconfirmed parents, higher absolute fee, bandwidth fee, max 100 evictions
- **Address encoding**: Base58Check (P2PKH, P2SH) and Bech32/Bech32m (P2WPKH, P2WSH, P2TR) for both encoding and decoding, with network-aware validation
- **Assumevalid**: Skips script verification for blocks below a configured height (250,050 for signet) for faster initial sync
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

## License

MIT
