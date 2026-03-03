# bitcoin-node-odin

A Bitcoin full node implementation written in [Odin](https://odin-lang.org/). Built from scratch with no Bitcoin library dependencies — only libsecp256k1 for elliptic curve cryptography, vendored RIPEMD-160, and vendored LevelDB for storage.

This is an educational/experimental project. It implements the core components of a Bitcoin node: cryptographic primitives, wire protocol serialization, script interpretation (including SegWit and Taproot), consensus validation, persistent storage (LevelDB), UTXO management, P2P networking with headers-first sync, mempool with RBF, and a JSON-RPC interface with 37 methods.

## Status

**208 tests passing** across 9 packages. Successfully syncs signet (~294k blocks) and testnet4 (~124k blocks) with full script verification.

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete (24 tests) |
| 1 | Wire Protocol + Serialization | Complete (24 tests) |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH, Taproot) | Complete (49 tests) |
| 3 | Consensus Rules + Block Validation | Complete (15 tests) |
| 4 | UTXO Set + Chain State | Complete (10 tests) |
| 5 | Persistent Storage (LevelDB) | Complete (13 tests) |
| 6 | P2P Networking | Complete (6 tests) |
| 7 | Mempool + Persistence + RBF | Complete (20 tests) |
| 8 | RPC Interface (37 methods) | Complete (47 tests) |
| 9 | P2P Integration + CLI + Shutdown | Complete |
| 10 | Signet Sync (BIP325) | Complete |
| 11 | LevelDB Storage Migration | Complete |
| 12 | Multi-peer Block Download + Bandwidth Scoring | Complete |
| 13 | Sighash Caching + Arena Safety | Complete |
| 14 | Steady-state Sync (BIP130) | Complete |
| 15 | RBF (BIP125) | Complete |
| 16 | Address Encoding (Base58Check + Bech32/Bech32m) | Complete |
| 17 | RPC Enrichment (getpeerinfo, mining, network, validation) | Complete |
| 18 | Configurable `--dbcache` (Bitcoin Core style) | Complete |
| 19 | Parallel Script Verification (`--par`) | Complete |
| 20 | Control + Raw Transaction RPCs | Complete |
| 21 | Testnet4 Support (BIP94) | Complete |

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

# Sync with reduced memory (64 MiB DB cache)
./btcnode --network=signet --dbcache=64

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
| `--dbcache=<MB>` | Database cache size in MiB | `450` |
| `--par=<N>` | Script verification threads (0=auto, 1=serial, 2+=parallel) | `0` |

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
dbcache=450
par=0

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

### Bitcoin Core RPC Coverage (36 / 78 non-wallet RPCs)

The tables below show every non-wallet RPC from Bitcoin Core. Wallet RPCs are intentionally excluded.

**Blockchain (15/25):**

| Method | Status | Notes |
|--------|--------|-------|
| `getbestblockhash` | Yes | |
| `getblock` | Yes | Verbosity 0, 1, 2 |
| `getblockchaininfo` | Yes | |
| `getblockcount` | Yes | |
| `getblockfilter` | — | BIP157 compact block filters |
| `getblockhash` | Yes | |
| `getblockheader` | Yes | |
| `getblockstats` | Yes | |
| `getchaintips` | Yes | |
| `getchaintxstats` | Yes | |
| `getdifficulty` | Yes | |
| `getmempoolancestors` | — | Ancestor tracking not implemented |
| `getmempooldescendants` | — | Descendant tracking not implemented |
| `getmempoolentry` | Yes | |
| `getmempoolinfo` | Yes | |
| `getrawmempool` | Yes | |
| `gettxout` | Yes | |
| `gettxoutproof` | — | Merkle proof generation |
| `gettxoutsetinfo` | — | Full UTXO set scan |
| `preciousblock` | — | Manual best-chain override |
| `pruneblockchain` | — | No pruning support |
| `savemempool` | Yes | |
| `scantxoutset` | — | UTXO set descriptor scan |
| `verifychain` | — | Block-by-block re-verification |
| `verifytxoutproof` | — | Merkle proof verification |

**Control (6/6):**

| Method | Status | Notes |
|--------|--------|-------|
| `getmemoryinfo` | Yes | Reports UTXO cache usage |
| `getrpcinfo` | Yes | |
| `help` | Yes | Per-method and full listing |
| `logging` | Yes | Read-only category report |
| `stop` | Yes | Graceful shutdown |
| `uptime` | Yes | |

**Generating (0/3):**

| Method | Status | Notes |
|--------|--------|-------|
| `generateblock` | — | Regtest block generation |
| `generatetoaddress` | — | Regtest mining to address |
| `generatetodescriptor` | — | Regtest mining to descriptor |

**Mining (2/6):**

| Method | Status | Notes |
|--------|--------|-------|
| `getblocktemplate` | — | Block template for miners |
| `getmininginfo` | Yes | |
| `getnetworkhashps` | Yes | |
| `prioritisetransaction` | — | Manual fee delta |
| `submitblock` | — | Mined block submission |
| `submitheader` | — | Header-only submission |

**Network (5/13):**

| Method | Status | Notes |
|--------|--------|-------|
| `addnode` | — | Manual peer management |
| `clearbanned` | — | No ban list |
| `disconnectnode` | — | Manual peer disconnect |
| `getaddednodeinfo` | — | Manual peer list info |
| `getconnectioncount` | Yes | |
| `getnettotals` | Yes | |
| `getnetworkinfo` | Yes | |
| `getnodeaddresses` | — | Known address gossip |
| `getpeerinfo` | Yes | 18 fields |
| `listbanned` | — | No ban list |
| `ping` | Yes | |
| `setban` | — | No ban list |
| `setnetworkactive` | — | No network toggle |

**Raw Transactions (8/17):**

| Method | Status | Notes |
|--------|--------|-------|
| `analyzepsbt` | — | PSBT not implemented |
| `combinepsbt` | — | PSBT not implemented |
| `combinerawtransaction` | Yes | |
| `converttopsbt` | — | PSBT not implemented |
| `createpsbt` | — | PSBT not implemented |
| `createrawtransaction` | Yes | |
| `decodepsbt` | — | PSBT not implemented |
| `decoderawtransaction` | Yes | |
| `decodescript` | Yes | |
| `finalizepsbt` | — | PSBT not implemented |
| `fundrawtransaction` | — | Requires wallet UTXO selection |
| `getrawtransaction` | Yes | Mempool lookup |
| `joinpsbts` | — | PSBT not implemented |
| `sendrawtransaction` | Yes | |
| `signrawtransactionwithkey` | Yes | P2PKH, P2WPKH, P2SH-P2WPKH |
| `testmempoolaccept` | Yes | |
| `utxoupdatepsbt` | — | PSBT not implemented |

**Util (1/8):**

| Method | Status | Notes |
|--------|--------|-------|
| `createmultisig` | — | Multisig script construction |
| `deriveaddresses` | — | Descriptor address derivation |
| `estimatesmartfee` | — | Fee estimation not implemented |
| `getdescriptorinfo` | — | Output descriptor analysis |
| `getindexinfo` | — | Optional index status |
| `signmessagewithprivkey` | — | Message signing |
| `validateaddress` | Yes | |
| `verifymessage` | — | Message signature verification |

## Testing

```bash
# Run all 204 tests
make test

# Test individual packages
odin test crypto          # 24 tests
odin test wire            # 24 tests
odin test script          # 47 tests (use -define:ODIN_TEST_THREADS=1 if flaky)
odin test consensus       # 15 tests
odin test storage         # 13 tests
odin test chain           #  8 tests
odin test p2p             #  6 tests
odin test mempool         # 20 tests
odin test rpc             # 47 tests
```

## Project Structure

```
bitcoin-node-odin/
├── main.odin              # Entry point, CLI parsing, config file, thread orchestration
├── Makefile               # Build system
├── crypto/                # SHA-256d, RIPEMD-160, HASH160, secp256k1 (verify+sign), Merkle root, address encoding, WIF
├── wire/                  # Protocol types, CompactSize, tx/block serialization, message framing
├── script/                # Script interpreter, opcodes, standard types, Taproot (BIP341/342)
├── consensus/             # Chain params, PoW, difficulty, block/tx validation, BIP325 signet
├── storage/               # LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state
├── p2p/                   # Peer connections, sync manager, connection manager
├── mempool/               # Fee rates, relay policy, validation pipeline, RBF, persistence
├── rpc/                   # JSON-RPC server (37 methods), handlers, types
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

Cache sizes are configurable via `--dbcache=<MB>` (default 450 MiB), split following Bitcoin Core's algorithm: block index DB gets min(total/8, 2 MiB), chainstate DB gets min(remaining/2, 8 MiB), and the remainder goes to the in-memory UTXO coins cache. Both databases use 10-bit bloom filters, 2 MiB write buffers, and no compression. UTXO changes and chain tip metadata are committed atomically via LevelDB WriteBatch. The coins cache flushes when its memory usage exceeds the budget (or every 5000 blocks as a safety net).

**Block storage** uses flat files (`blk00000.dat`, `rev00000.dat`) with 128MB auto-rollover, matching Bitcoin Core's format. Flat files store the raw block blobs; LevelDB handles the structured key-value data.

**Crash recovery**: On unclean shutdown, the node recovers to the last consistent flush point and replays stored-but-not-connected blocks from flat files.

## What's Left to Build

### Correctness

- **Testnet3 20-min difficulty rule** — When block timestamp >20min after previous, difficulty resets to `pow_limit`

### Performance

- **Snappy compression for LevelDB** — Would reduce disk usage for mainnet

### Protocol Enhancements

- **Compact blocks (BIP152)** — Bandwidth-efficient block relay
- **Ancestor/descendant limits** — No CPFP chain depth limits (Bitcoin Core uses 25/25)

### Infrastructure

- **`core:nbio` migration** — Replace thread-per-peer with async I/O event loop (waiting for Odin's nbio package to mature)

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread, one reader thread per peer, N script verification worker threads (`--par`)
- **Graceful shutdown**: SIGINT/SIGTERM triggers mempool save, atomic UTXO + metadata flush to LevelDB, then clean exit
- **Headers-first sync**: Single lead peer downloads headers via `getheaders`/`headers`, with automatic failover if the lead disconnects. Headers are batched into single WriteBatch transactions (up to 2000 per batch)
- **Multi-peer block download**: Round-robin block requests across all active peers (up to 8), with bandwidth-based scoring — fast peers get more slots (up to 64), slow peers get fewer (minimum 4), new peers get a trial allocation of 8 blocks
- **Steady-state sync**: BIP130 `sendheaders` for header announcements, periodic `getheaders` polling (120s), and `inv`-triggered header requests keep the node up-to-date after IBD
- **Stall detection**: Blocks stalled >30s are requeued to other peers; header requests timeout after 60s with lead peer failover
- **DNS peer discovery**: Resolves all A records from DNS seeds (typically 20+ addresses per seed)
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed atomically to LevelDB when memory usage exceeds the configurable budget (`--dbcache`, default 450 MiB). Rollback support for failed block validation
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup, persisted to LevelDB
- **Sighash caching**: BIP143 (SegWit v0) and BIP341 (Taproot) intermediate hashes are cached per-transaction, avoiding O(n^2) re-computation for transactions with many inputs
- **Parallel script verification**: Two-phase block validation — Phase 1 processes UTXO updates sequentially (single-threaded, no locking), Phase 2 dispatches all script checks to a persistent thread pool (`--par=N`). Sighash caches are eagerly pre-computed before dispatch so workers read immutable data without synchronization. Serial fallback for small blocks (<16 inputs) or `--par=1`
- **Per-input verification arena**: A 2MB heap-allocated scratch arena is reset between each input's script verification (serial path), preventing sighash writer accumulation from exhausting the 64MB block arena on large transactions. Parallel workers each allocate their own 2MB arena
- **Mempool persistence**: Mempool is saved to `<datadir>/mempool.dat` on shutdown and reloaded/revalidated on startup
- **Transaction relay**: P2P `inv`/`tx`/`getdata` handling for propagating mempool transactions to peers
- **RBF (BIP125)**: Full replace-by-fee support — signaling check (opt-in or fullrbf), no new unconfirmed parents, higher absolute fee, bandwidth fee, max 100 evictions
- **Address encoding**: Base58Check (P2PKH, P2SH) and Bech32/Bech32m (P2WPKH, P2WSH, P2TR) for both encoding and decoding, with network-aware validation
- **Configurable DB cache**: `--dbcache` controls total database memory (default 450 MiB), split following Bitcoin Core's algorithm — small LevelDB caches (2-8 MiB), large in-memory coins cache (~440 MiB). Lower values reduce RAM usage at the cost of more frequent UTXO flushes during sync
- **Assumevalid**: Skips script verification for blocks below a configured height (267,665 for signet) for faster initial sync
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

## License

MIT
