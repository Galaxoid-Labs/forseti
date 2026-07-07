# Development History

Every build phase in order. See the [README](../README.md) for the current summary.

## Phases

| Phase | Component | Status |
|-------|-----------|--------|
| 0 | Crypto + C Bindings | Complete (40 tests) |
| 1 | Wire Protocol + Serialization | Complete (44 tests) |
| 2 | Script Interpreter (P2PKH, P2SH, P2WPKH, P2WSH, Taproot) | Complete (51 tests) |
| 3 | Consensus Rules + Block Validation | Complete (22 tests) |
| 4 | UTXO Set + Chain State | Complete (22 tests) |
| 5 | Persistent Storage (LevelDB) | Complete (18 tests) |
| 6 | P2P Networking | Complete (33 tests) |
| 7 | Mempool + Persistence + RBF + Config | Complete (32 tests) |
| 8 | RPC Interface (47 methods, threaded + keep-alive + batch) | Complete (53 tests) |
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
| 23 | Mainnet Sync (BIP30, stall detection, peer management) | Complete |
| 24 | Assumevalid + Txid Optimization | Complete |
| 25 | nbio Async I/O Migration | Complete |
| 26 | Cross-thread RPC Relay Safety | Complete |
| 27 | Address Pool Lifetime Fix | Complete |
| 28 | Test Coverage Expansion (+38 tests) | Complete |
| 29 | Blockchain RPC Expansion (+5 methods) | Complete |
| 30 | BIP 68 + BIP 113 Lock-time Enforcement | Complete |
| 31 | Mempool Configuration (Bitcoin Core parity) | Complete |
| 32 | Compact Block Relay — receive + send (BIP152) | Complete |
| 33 | RPC Authentication (cookie + Basic Auth) | Complete |
| 34 | BIP 133 feefilter + BIP 339 wtxid relay | Complete |
| 35 | BIP 155 addr relay + addrv2 | Complete |
| 36 | BIP 324 v2 Encrypted Transport | Complete |
| 37 | BIP 157/158 Compact Block Filters | Complete |
| 38 | Inbound P2P Connections + Core 28 Parity | Complete |
| 39 | UTXO Prefetch (Parallel LevelDB Reads) | Complete |
| 40 | Block Pruning (`--prune`) + NODE_NETWORK_LIMITED | Complete |
| 41 | GUI Dashboard (raylib, in-process + remote `btcnode-gui`) | Complete |
| 42 | TUI Dashboard (ncurses, `--tui`, SSH-friendly) | Complete |
| 43 | Chain Reorganization (chainwork fork choice, undo-based disconnect) | Complete |
| 44 | Background UTXO Flush (memtable rotation, no sync freeze) | Complete |
| 45 | Sync Progress + ETA (Core chainTxData style) | Complete |
| 46 | Electrum Server Compatibility (electrs v0.10: batch RPC, keep-alive, getheaders serving) | Complete |
| 47 | Instant GUI Startup + Shutdown-hold Screen | Complete |
| 48 | Crash Recovery v2 (persisted undo locations, verified rollback, bounded by safety flushes) | Complete |
| 49 | Single-instance Datadir Lock | Complete |
| 50 | ZMQ Notifications (native ZMTP, Core zmqpub* parity, LND-ready) | Complete |
| 51 | Node-control RPCs + bans + createmultisig (59/78 Core coverage) | Complete |
| 52 | Regtest Mining (generatetoaddress) | Complete |
| 53 | UTXO Hygiene (skip unspendable outputs, --repairutxo sweep) | Complete |
| 54 | Dashboard Halt Banners + 100%-at-tip | Complete |
| 55 | Drivechain BIP300/301 (--drivechain=off\|track\|enforce, D1/D2 + CTIP + BMM, 3 RPCs) | Complete |
| 56 | v2transport default-on; release CI (macOS arm64 + Linux x64/arm64 binaries) | Complete |
| 57 | Fee estimator (Core CBlockPolicyEstimator port, 3 horizons, fee_estimates.dat) | Complete |
| 58 | Rolling UTXO stats (instant gettxoutsetinfo) | Complete |
| 59 | Mining interface (getblocktemplate/submitblock/submitheader/prioritisetransaction/generateblock) | Complete |
| 60 | --rpcbind/--rpcallowip + verifychain | Complete |
| 61 | SOCKS5 --proxy (Tor-ready outbound) | Complete |
| 62 | Descriptor engine (getdescriptorinfo/deriveaddresses/scantxoutset/generatetodescriptor) | Complete |
| 63 | txindex (--txindex, historical getrawtransaction) | Complete |
| 64 | P2P topology hardening (block-relay-only, anchors, feelers, --maxuploadtarget) | Complete |

**RPC coverage: 69/78 Core non-wallet RPCs** (73 methods total). Remaining
Core RPCs are the PSBT family (9) + `fundrawtransaction`, and the package-relay
RPC `submitpackage`.

## What's Left to Build

### Correctness

- **Crash consistency on fresh DB** — If node is killed before first UTXO flush, recovery fails due to absent meta tip

### Performance

- **Snappy compression for LevelDB** — Would reduce disk usage for mainnet

### Features

- **Package relay / TRUC (v3)** — `submitpackage`, 1-parent-1-child acceptance
- **PSBT family** — the 9 BIP174 RPCs + `fundrawtransaction` (wallet-adjacent)
- **assumeutxo** — `dumptxoutset`/`loadtxoutset` fast bootstrap
- **REST interface** (`-rest`), `-reindex`
