# bitcoin-node-odin

A Bitcoin full node implementation written in [Odin](https://odin-lang.org/). Built from scratch with no Bitcoin library dependencies — only libsecp256k1 for elliptic curve cryptography, vendored RIPEMD-160, and LevelDB for storage.

This is an educational/experimental project. It implements the core components of a Bitcoin node: cryptographic primitives, wire protocol serialization, script interpretation (including SegWit and Taproot), consensus validation, persistent storage (LevelDB), UTXO management, P2P networking with headers-first sync, compact block relay (BIP152), feefilter (BIP133), wtxid relay (BIP339), addr relay with addrv2 (BIP155), mempool with RBF, and a JSON-RPC interface with 42 methods.

## Status

**272 tests passing** across 9 packages. Successfully syncs signet (~294k blocks), testnet4 (~124k blocks), testnet3, and mainnet (actively syncing) with full script verification. Builds on macOS and Linux.

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete (31 tests) |
| 1 | Wire Protocol + Serialization | Complete (35 tests) |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH, Taproot) | Complete (50 tests) |
| 3 | Consensus Rules + Block Validation | Complete (22 tests) |
| 4 | UTXO Set + Chain State | Complete (20 tests) |
| 5 | Persistent Storage (LevelDB) | Complete (16 tests) |
| 6 | P2P Networking | Complete (14 tests) |
| 7 | Mempool + Persistence + RBF + Config | Complete (32 tests) |
| 8 | RPC Interface (42 methods) | Complete (52 tests) |
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
| 22 | Testnet3 Fixes (BIP16 activation, lax DER, difficulty) | Complete |
| 23 | Mainnet Sync (BIP30, adaptive stall detection, peer management) | Complete |
| 24 | Assumevalid + Txid Optimization | Complete |
| 25 | nbio Async I/O Migration | Complete |
| 26 | Cross-thread RPC Relay Safety | Complete |
| 27 | Address Pool Lifetime Fix | Complete |
| 28 | Test Coverage Expansion (+38 tests) | Complete |
| 29 | Blockchain RPC Expansion (+5 methods) | Complete |
| 30 | BIP 68 + BIP 113 Lock-time Enforcement | Complete |
| 31 | Mempool Configuration (Bitcoin Core parity) | Complete |
| 32 | Compact Block Relay (BIP152) | Complete |
| 33 | RPC Authentication (cookie + Basic Auth) | Complete |
| 34 | BIP 133 feefilter + BIP 339 wtxid relay | Complete |
| 35 | BIP 155 addr relay + addrv2 | Complete |

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- LLVM 15+ (required by `core:nbio` for atomic pointer operations — Ubuntu 24.04+ or install via [apt.llvm.org](https://apt.llvm.org))
- C/C++ compiler (`cc` / `clang` / `g++`)
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)

**C/C++ libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) v0.7.1 — git submodule, built with schnorrsig + recovery + extrakeys modules
- [LevelDB](https://github.com/google/leveldb) 1.23 — git submodule, compiled as static library with C++17
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
# Show help
./btcnode --help

# Start in regtest mode (no peers needed, good for RPC testing)
./btcnode --network=regtest --no-p2p
```

### Syncing a Network

Each network syncs via P2P and stores data in its own directory. Run in the background with `nohup` and monitor via the log file:

**Mainnet:**
```bash
# Start syncing mainnet (full validation, ~939k blocks)
nohup ./btcnode --network=mainnet --datadir=/tmp/btcnode-mainnet --dbcache=4096 \
  > /tmp/btcnode-mainnet.log 2>&1 &

# Monitor sync progress
tail -f /tmp/btcnode-mainnet.log | grep "Blocks:"

# Check current block height via RPC
curl -s -u "$(cat /tmp/btcnode-mainnet/.cookie)" \
     --data '{"method":"getblockcount","params":[],"id":1}' http://127.0.0.1:8332/

# Stop gracefully (saves mempool, flushes UTXO cache)
curl -s -u "$(cat /tmp/btcnode-mainnet/.cookie)" \
     --data '{"method":"stop","params":[],"id":1}' http://127.0.0.1:8332/
# or: kill -SIGINT $(pgrep -f "btcnode.*mainnet")
```

**Signet:**
```bash
nohup ./btcnode --network=signet --datadir=/tmp/btcnode-signet --dbcache=4096 \
  > /tmp/btcnode-signet.log 2>&1 &

tail -f /tmp/btcnode-signet.log | grep "Blocks:"
curl -s -u "$(cat /tmp/btcnode-signet/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:38332/
```

**Testnet4:**
```bash
nohup ./btcnode --network=testnet4 --datadir=/tmp/btcnode-testnet4 --dbcache=4096 \
  > /tmp/btcnode-testnet4.log 2>&1 &

tail -f /tmp/btcnode-testnet4.log | grep "Blocks:"
curl -s -u "$(cat /tmp/btcnode-testnet4/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:48332/
```

**Testnet3:**
```bash
nohup ./btcnode --network=testnet3 --datadir=/tmp/btcnode-testnet3 --dbcache=4096 \
  > /tmp/btcnode-testnet3.log 2>&1 &

tail -f /tmp/btcnode-testnet3.log | grep "Blocks:"
curl -s -u "$(cat /tmp/btcnode-testnet3/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:18332/
```

### Monitoring

```bash
# Watch block progress (any network)
tail -f /tmp/btcnode-mainnet.log | grep "Blocks:"

# Check for validation errors
grep -iE "FAIL|Bad_Script|halting|consensus" /tmp/btcnode-mainnet.log

# Check peer connections
curl -s -u "$(cat /tmp/btcnode-mainnet/.cookie)" \
     --data '{"method":"getpeerinfo","params":[],"id":1}' http://127.0.0.1:8332/ | python3 -m json.tool

# Check memory/resource usage
ps aux | grep btcnode | grep -v grep | awk '{print "CPU: "$3"% MEM: "$4"% RSS: "$6/1024"MB"}'

# Reduce memory usage on constrained machines
./btcnode --network=signet --dbcache=64
```

### CLI Flags

**General:**

| Flag | Description | Default |
|------|-------------|---------|
| `--network=<name>` | `mainnet`, `testnet3`, `testnet4`, `signet`, `regtest` | `regtest` |
| `--datadir=<path>` | Data directory for blocks, index, UTXO database | `/tmp/btcnode-data` |
| `--rpcport=<port>` | JSON-RPC port | Network default |
| `--rpcuser=<user>` | RPC auth username | Cookie auth |
| `--rpcpassword=<pass>` | RPC auth password (must set both user and password) | Cookie auth |
| `--server=<0\|1>` | Enable/disable RPC server | `1` |
| `--connect=<ip:port>` | Connect to a specific peer | DNS discovery |
| `--p2p-port=<port>` | P2P listen port | Network default |
| `--no-p2p` | Disable P2P (RPC-only mode) | `false` |
| `--maxconnections=<N>` | Maximum outbound peer connections | `8` |
| `--dbcache=<MB>` | Database cache size in MiB | `450` |
| `--par=<N>` | Script verification threads (0=auto, 1=serial, 2+=parallel) | `0` |
| `--assumevalid=<height>` | Skip script verification below height (0=disable) | Network default |

**Mempool (matching Bitcoin Core):**

| Flag | Description | Default |
|------|-------------|---------|
| `--maxmempool=<MB>` | Maximum mempool size in megabytes | `300` |
| `--mempoolexpiry=<hours>` | Evict transactions older than N hours | `336` (14 days) |
| `--mempoolfullrbf=<0\|1>` | Allow full replace-by-fee | `1` |
| `--limitancestorcount=<N>` | Max unconfirmed ancestor count per tx | `25` |
| `--limitancestorsize=<kvB>` | Max ancestor chain size in kvB | `101` |
| `--limitdescendantcount=<N>` | Max unconfirmed descendant count per tx | `25` |
| `--limitdescendantsize=<kvB>` | Max descendant chain size in kvB | `101` |
| `--minrelaytxfee=<BTC/kvB>` | Minimum relay fee rate | `0.00001000` |
| `--incrementalrelayfee=<BTC/kvB>` | Fee rate increment for RBF and mempool limiting | `0.00001000` |
| `--dustrelayfee=<BTC/kvB>` | Dust threshold fee rate | `0.00003000` |
| `--datacarrier=<0\|1>` | Allow OP_RETURN outputs | `1` |
| `--datacarriersize=<bytes>` | Max OP_RETURN script size | `83` |
| `--permitbaremultisig=<0\|1>` | Allow bare multisig outputs | `1` |
| `--blocksonly` | Disable tx relay, only sync blocks | `false` |
| `--persistmempool=<0\|1>` | Save/load mempool on shutdown/startup | `1` |

### Config File

The node reads an optional `btcnode.conf` from the data directory (`<datadir>/btcnode.conf`). The format mirrors Bitcoin Core's `bitcoin.conf` — INI-style with `#` comments and `[section]` network overrides.

**Precedence:** CLI flags > config file > defaults

```ini
# /tmp/btcnode-data/btcnode.conf

network=regtest
rpcport=18443
rpcuser=myuser
rpcpassword=mypassword
server=1
connect=127.0.0.1:18444
no-p2p=1
dbcache=450
par=0
assumevalid=880000
maxconnections=8

# Mempool settings (Bitcoin Core compatible)
maxmempool=300
mempoolexpiry=336
mempoolfullrbf=1
limitancestorcount=25
limitdescendantcount=25
minrelaytxfee=0.00001000
dustrelayfee=0.00003000
datacarrier=1
datacarriersize=83
persistmempool=1
# blocksonly=1

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

The node exposes a JSON-RPC 1.0 interface over HTTP with authentication. By default, a `.cookie` file is generated in the data directory (matching Bitcoin Core's cookie auth). You can also set explicit credentials with `--rpcuser` and `--rpcpassword`.

```bash
# Using curl with cookie auth (default)
curl -s -u "$(cat /tmp/btcnode-data/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using curl with explicit credentials
curl -s -u myuser:mypassword \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using bitcoin-cli (reads cookie file automatically)
bitcoin-cli -rpcport=18443 getblockchaininfo
```

### Bitcoin Core RPC Coverage (42 / 78 non-wallet RPCs)

The tables below show every non-wallet RPC from Bitcoin Core. Wallet RPCs are intentionally excluded.

**Blockchain (20/25):**

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
| `getmempoolancestors` | Yes | Verbose and non-verbose modes |
| `getmempooldescendants` | Yes | Verbose and non-verbose modes |
| `getmempoolentry` | Yes | |
| `getmempoolinfo` | Yes | |
| `getrawmempool` | Yes | |
| `gettxout` | Yes | |
| `gettxoutproof` | Yes | Partial merkle tree proof |
| `gettxoutsetinfo` | Yes | UTXO count + total amount |
| `preciousblock` | — | Manual best-chain override |
| `pruneblockchain` | — | No pruning support |
| `savemempool` | Yes | |
| `scantxoutset` | — | UTXO set descriptor scan |
| `verifychain` | — | Block-by-block re-verification |
| `verifytxoutproof` | Yes | Merkle proof verification |

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
# Run all 272 tests
make test

# Test individual packages
odin test crypto          # 31 tests
odin test wire            # 35 tests
odin test script          # 50 tests (use -define:ODIN_TEST_THREADS=1 if flaky)
odin test consensus       # 22 tests
odin test storage         # 16 tests
odin test chain           # 20 tests
odin test p2p             # 14 tests
odin test mempool         # 32 tests
odin test rpc             # 52 tests
```

## Project Structure

```
bitcoin-node-odin/
├── main.odin              # Entry point, CLI parsing, config file, thread orchestration
├── Makefile               # Build system
├── crypto/                # SHA-256d, RIPEMD-160, HASH160, secp256k1 (verify+sign), Merkle root, address encoding, WIF, SipHash-2-4
├── wire/                  # Protocol types, CompactSize, tx/block serialization, message framing, compact blocks (BIP152), addrv2 (BIP155)
├── script/                # Script interpreter, opcodes, standard types, Taproot (BIP341/342)
├── consensus/             # Chain params, PoW, difficulty, block/tx validation, BIP325 signet
├── storage/               # LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state
├── p2p/                   # Peer connections, sync manager, connection manager, address manager
├── mempool/               # Fee rates, relay policy, validation pipeline, RBF, persistence, configurable limits
├── rpc/                   # JSON-RPC server (42 methods), handlers, types
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

**Block index database** (`<datadir>/blocks/index/`):
- Block index entries — Key: block hash, Value: block index record (height, status, file location, header fields)

Cache sizes are configurable via `--dbcache=<MB>` (default 450 MiB), split following Bitcoin Core's algorithm: block index DB gets min(total/8, 2 MiB), chainstate DB gets min(remaining/2, 8 MiB), and the remainder goes to the in-memory UTXO coins cache. Both databases use 10-bit bloom filters, 2 MiB write buffers, and no compression. UTXO changes and chain tip metadata are committed atomically via LevelDB WriteBatch. The coins cache flushes when its memory usage exceeds the budget (or every 5000 blocks as a safety net).

**Block storage** uses flat files (`blk00000.dat`, `rev00000.dat`) with 128MB auto-rollover, matching Bitcoin Core's format. Flat files store the raw block blobs; LevelDB handles the structured key-value data.

**Crash recovery**: On unclean shutdown, the node recovers to the last consistent flush point and replays stored-but-not-connected blocks from flat files.

## What's Left to Build

### Correctness

- **Crash consistency on fresh DB** — If node is killed before first UTXO flush, recovery fails due to absent meta tip

### Performance

- **Snappy compression for LevelDB** — Would reduce disk usage for mainnet

### Features

- **`generatetoaddress` RPC** — Regtest block generation for self-contained testing
- **Block pruning** — Discard old block data to reduce disk usage on mainnet

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread (`core:nbio` event loop — kqueue on macOS, epoll on Linux), N script verification worker threads (`--par`). No per-peer threads — all peer I/O is multiplexed on a single event loop with async connect/recv/send callbacks
- **Graceful shutdown**: SIGINT/SIGTERM triggers mempool save, atomic UTXO + metadata flush to LevelDB, then clean exit
- **Headers-first sync**: Single lead peer downloads headers via `getheaders`/`headers`, with automatic failover if the lead disconnects. Headers are batched into single WriteBatch transactions (up to 2000 per batch)
- **Multi-peer block download**: Fastest-first block assignment across all active peers (up to 8) — peers are sorted by throughput and the fastest peer gets tip-adjacent blocks so slow peers can't block chain progress. Bandwidth-based scoring: fast peers get more slots (up to 16), slow peers fewer (minimum 4), new peers get a trial allocation of 8 blocks
- **Compact block relay (BIP152)**: Receive-side implementation — negotiates compact block v2 (wtxid-based short IDs) with peers, reconstructs blocks from mempool using SipHash-2-4 short ID matching, requests missing transactions via `getblocktxn`/`blocktxn`, falls back to full block download after 10s timeout. Reduces block relay bandwidth by ~90% when mempool is populated
- **Steady-state sync**: BIP130 `sendheaders` for header announcements, periodic `getheaders` polling (120s), and `inv`-triggered header requests keep the node up-to-date after IBD
- **Adaptive stall detection**: Bitcoin Core-style stall handling — default 10s timeout, doubles on disconnect (max 64s), decays by 0.85x on successful block connects. Slow peers (throughput <10% of fastest) are evicted after a trial period. Disconnected peers are replaced via DNS discovery
- **Peer discovery + addr relay (BIP155)**: DNS seeds populate an address manager at startup. After handshake, `sendaddrv2` is negotiated and `getaddr` requests peers' address lists. Inbound `addr`/`addrv2` messages add to the address manager (FNV-1a dedup, 5000 entry cap). Small announcements (≤10 entries) are forwarded to 1-2 random peers with automatic v1↔v2 format conversion. Replacement peers are drawn from the address manager. Configurable via `--maxconnections=N` (default 8)
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed atomically to LevelDB when memory usage exceeds the configurable budget (`--dbcache`, default 450 MiB). Rollback support for failed block validation
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup, persisted to LevelDB. `by_prev` index provides O(1) next-block lookup for chain traversal
- **Sighash caching**: BIP143 (SegWit v0) and BIP341 (Taproot) intermediate hashes are cached per-transaction, avoiding O(n^2) re-computation for transactions with many inputs
- **Parallel script verification**: Two-phase block validation — Phase 1 processes UTXO updates sequentially (single-threaded, no locking), Phase 2 dispatches all script checks to a persistent thread pool (`--par=N`). Sighash caches are eagerly pre-computed before dispatch so workers read immutable data without synchronization. Serial fallback for small blocks (<16 inputs) or `--par=1`. Workers use pre-allocated 8MB arena buffers from a mutex-protected pool (avoids per-check heap allocation)
- **Per-input verification arena**: A 4MB heap-allocated scratch arena is reset between each input's script verification (serial path), preventing sighash writer accumulation from exhausting the 64MB block arena on large transactions
- **Mempool configuration**: 16 configurable settings matching Bitcoin Core defaults — memory-based size limiting (`--maxmempool`, default 300 MB) with fee-based eviction and dynamic minimum fee, transaction expiry (`--mempoolexpiry`, default 336 hours), ancestor/descendant chain limits (count and size), configurable relay/dust/incremental fees, datacarrier toggle, bare multisig toggle, blocks-only mode (`--blocksonly`), and optional persistence (`--persistmempool`). All settings supported via CLI flags and `btcnode.conf`
- **Memory-based mempool limiting**: Tracks total vsize of all entries. When usage exceeds the limit, lowest fee-rate transactions are evicted and the dynamic minimum fee (`mempoolminfee` in `getmempoolinfo`) is raised. Resets when usage drops below the limit after a block connect
- **Mempool persistence**: Mempool is saved to `<datadir>/mempool.dat` on shutdown and reloaded/revalidated on startup (controlled by `--persistmempool`)
- **Transaction relay**: P2P `inv`/`tx`/`getdata` handling for propagating mempool transactions to peers. BIP 133 feefilter: sends our minimum fee rate to peers after handshake, stores each peer's feefilter, skips peers whose feefilter exceeds the tx's fee rate during relay. BIP 339 wtxid relay: negotiates wtxid-based `inv` between `version` and `verack`, announces txs by wtxid to modern peers (txid fallback for legacy peers), mempool maintains a wtxid→txid reverse index for `getdata` lookups. BIP 155 addr relay: negotiates `sendaddrv2` before `verack`, handles `addr`/`addrv2`/`getaddr` messages, forwards small announcements to peers. Cross-thread safety: RPC thread pushes relay items (txid + wtxid + fee rate) to a mutex-protected queue, P2P event loop drains it. `--blocksonly` disables inbound and outbound tx relay (RPC `sendrawtransaction` still works)
- **RBF (BIP125)**: Full replace-by-fee support — signaling check (opt-in or fullrbf), no new unconfirmed parents, higher absolute fee, bandwidth fee (configurable via `--incrementalrelayfee`), max evictions (configurable)
- **Lax DER signature parsing**: Pre-BIP66 transactions may contain non-strictly-encoded DER signatures. The verification path uses a lax DER parser (matching Bitcoin Core's `ecdsa_signature_parse_der_lax`), while strict DER validation is enforced separately by the script interpreter when BIP66 is active
- **Address encoding**: Base58Check (P2PKH, P2SH) and Bech32/Bech32m (P2WPKH, P2WSH, P2TR) for both encoding and decoding, with network-aware validation
- **Configurable DB cache**: `--dbcache` controls total database memory (default 450 MiB), split following Bitcoin Core's algorithm — small LevelDB caches (2-8 MiB), large in-memory coins cache (~440 MiB). Lower values reduce RAM usage at the cost of more frequent UTXO flushes during sync
- **Assumevalid**: Skips script verification below a network-specific height (mainnet=880,000, signet=267,665, testnet3=2,100,000, testnet4=200,000). Configurable via `--assumevalid=<height>` (0 disables)
- **Zero-allocation txid computation**: Transaction IDs are computed from raw stream bytes during block deserialization — non-witness txs hash raw bytes directly, witness txs use incremental `sha256d_multi` (no memory allocation). Pre-computed txids are passed through `connect_block` → `check_block` (Merkle root), eliminating redundant re-serialization. Reduced `connect_block` time by ~23% at mainnet height 360k
- **Block profiling**: Timing instrumentation logs per-phase breakdown every 1000 blocks (read, validation, UTXO, scripts, undo, index) for bottleneck identification
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

## License

MIT
