# bitcoin-node-odin

A Bitcoin full node implementation written in [Odin](https://odin-lang.org/). Built from scratch with no Bitcoin library dependencies — only libsecp256k1 for elliptic curve cryptography and a vendored RIPEMD-160 C implementation.

This is an educational/experimental project. It implements the core components of a Bitcoin node: cryptographic primitives, wire protocol serialization, script interpretation (including SegWit and Taproot), consensus validation, persistent storage, UTXO management, P2P networking, mempool, and a JSON-RPC interface.

## Status

**157 tests passing** across 9 packages.

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete |
| 1 | Wire Protocol + Serialization | Complete |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH) | Complete |
| 2b | Taproot (BIP341/342) | Complete |
| 3 | Consensus Rules + Block Validation | Complete |
| 4 | UTXO Set + Chain State | Complete |
| 5 | Persistent Storage | Complete |
| 6 | P2P Networking | Complete |
| 7 | Mempool | Complete |
| 8 | RPC Interface (10 methods) | Complete |
| 9 | P2P Integration + CLI + Shutdown | Complete |
| 10 | Additional RPC Methods (+13 methods) | Complete |

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- C compiler (`cc` / `clang` / `gcc`)
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)

**C libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) — included as a git submodule, built with schnorrsig + recovery + extrakeys modules
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
| signet | 38332 | — |
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
├── consensus/             # Chain params, PoW, difficulty, block/tx validation
├── storage/               # Flat files, block DB, index DB, mmap'd UTXO KV store
├── chain/                 # UTXO cache, block index (skip list), undo data, chain state
├── p2p/                   # Peer connections, sync manager, connection manager
├── mempool/               # Fee rates, relay policy, validation pipeline
├── rpc/                   # JSON-RPC server, handlers, types
└── deps/                  # C dependencies
    ├── libsecp256k1/      # Git submodule (bitcoin-core/secp256k1)
    ├── ripemd160/         # Vendored C implementation
    └── lib/               # Built static libraries (generated)
```

## What's Left to Build

### Needed for Real Network Sync

- **Testnet3 20-min difficulty rule** — When block timestamp >20min after previous, difficulty resets to `pow_limit`
- **Signet challenge validation** — Currently stubbed; needs coinbase signature extraction + challenge script verification
- **Assumevalid / checkpoints** — Skip script verification for blocks below a known-good hash (massive speedup)
- **UTXO store scaling** — The mmap'd hash table may need tuning for millions of entries

### Protocol Enhancements

- **RBF (BIP125)** — Replace-by-fee; currently first-tx-wins
- **Ancestor/descendant limits** — No CPFP chain depth limits (Bitcoin Core uses 25/25)
- **Transaction relay** — P2P `inv`/`tx`/`getdata` for propagating mempool txs
- **Compact blocks (BIP152)** — Bandwidth-efficient block relay
- **Address encoding** — Base58Check and Bech32/Bech32m for RPC address fields

### Infrastructure

- **`core:nbio` migration** — Replace thread-per-peer with async I/O event loop (waiting for Odin's nbio package to mature)
- **Mempool persistence** — Currently in-memory only, lost on restart
- **Structured logging** — Replace `fmt.printf` with `core:log`
- **Parallel script verification** — Currently single-threaded
- **Sighash caching** — Performance optimization for repeated signature checks

## Architecture Notes

- **Thread model**: Main thread (setup + wait), RPC thread, P2P thread, one reader thread per peer
- **Headers-first sync**: Downloads headers via `getheaders`, then fetches blocks via `getdata`
- **Write-back UTXO cache**: In-memory cache with dirty/fresh flags, flushed to mmap'd KV store on disk
- **Block index**: In-memory tree with skip list pointers for O(log n) ancestor lookup
- **No external Odin dependencies**: Only `core:` and `base:` standard library packages

## License

MIT
