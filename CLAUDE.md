# Bitcoin Node Odin - Project Instructions

## Build & Test

```bash
make              # Build deps + binary
make test         # Run all 252 tests (9 packages)
make debug        # Build with debug symbols
odin build . -out:btcnode   # Build binary only
odin test <pkg>   # Test single package (crypto, wire, script, consensus, storage, chain, p2p, mempool, rpc)
```

Note: Script tests have a known flaky secp256k1 thread-safety issue with parallel test threads. Use `-define:ODIN_TEST_THREADS=1` if tests crash.

## Running

```bash
./btcnode --network=signet --datadir=/tmp/btcnode-signet   # Sync signet
./btcnode --network=regtest --no-p2p                       # RPC-only regtest
./btcnode --help                                           # All options
```

## Project Structure

- `crypto/` — SHA-256d, RIPEMD-160, HASH160, secp256k1 bindings (verify+sign), Merkle root, Base58Check, Bech32/Bech32m, WIF decode
- `wire/` — Protocol types, CompactSize, tx/block serialization, message framing
- `script/` — Script interpreter, opcodes, standard types, Taproot (BIP341/342)
- `consensus/` — Chain params, PoW, difficulty, block/tx validation, BIP325 signet
- `storage/` — LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB (8 files)
- `chain/` — UTXO cache, block index with skip list, undo data, chain state, parallel verification (7 files)
- `p2p/` — Peer connections, sync manager, connection manager (5 files)
- `mempool/` — Fee rates, relay policy, validation pipeline, RBF (BIP125), persistence (6 files)
- `rpc/` — JSON-RPC server, 42 methods, HTTP server (4 files)
- `deps/` — libsecp256k1 (submodule), ripemd160 (vendored C), leveldb (vendored C++), static libs in deps/lib/

## Key Architecture

- **Storage**: Two LevelDB instances — `<datadir>/chainstate/` (UTXOs + meta tip) and `<datadir>/blocks/index/` (block index). Cache budget configurable via `--dbcache=<MB>` (default 450), split per Bitcoin Core's algorithm: index_db=min(total/8, 2MB), chainstate_db=min(remaining/2, 8MB), coins_cache=rest. 2MB write buffers, bloom filter, no Snappy. Blocks stored in flat files (`blk*.dat`, `rev*.dat`).
- **Crash consistency**: Atomic WriteBatch commits UTXO changes + chain tip metadata together. Recovery strips Valid_Chain from blocks above the last flush point and replays from flat files.
- **UTXO cache**: Write-back with Dirty/Fresh flags. Budget-based flushing (flush when mem_usage >= coins_cache_budget, or every 5000 blocks as safety net). Rollback on block validation failure.
- **Sync**: Headers-first with batched WriteBatch, then multi-peer block download (getdata with Witness_Block, up to 64 blocks per peer). Bandwidth-based scoring allocates more slots to faster peers. Stall detection requeues blocks after 30s. Steady-state via BIP130 sendheaders + periodic getheaders.
- **Sighash cache**: BIP143 + BIP341 intermediate hashes cached per-tx. Eagerly pre-computed before parallel dispatch so workers read immutable data.
- **Parallel script verification**: Two-phase `connect_block` — Phase 1 processes UTXOs sequentially, Phase 2 dispatches script checks to a persistent thread pool (`--par=N`, auto-detect by default). Serial fallback for small blocks (<16 inputs). Workers get 8MB pre-allocated arena buffers from a mutex-protected pool.
- **Assumevalid**: Skip script verification below hardcoded heights (mainnet=880k, testnet3=2.1M, testnet4=200k, signet=267k). `--assumevalid=<height>` CLI flag (0=disable).
- **Txid optimization**: `deserialize_block_with_txids` computes txids from raw bytes during deserialization — non-witness: `sha256d(raw)`, witness: `sha256d_multi(version, body, locktime)`. Pre-computed txids passed through `connect_block` → `check_block`.
- **Thread model**: Main (setup+wait), RPC thread, P2P thread (`core:nbio` event loop — no per-peer threads), N script verification worker threads (`--par`).
- **RBF (BIP125)**: Full replace-by-fee with fullrbf=true default. `--mempoolfullrbf=0|1` CLI flag.
- **Difficulty validation**: Header nBits verified against `get_next_work_required` (Bitcoin Core's GetNextWorkRequired). Testnet 20-minute minimum difficulty rule (`allow_min_difficulty`). BIP94 testnet4 retarget fix (`enforce_bip94`): uses first block of retarget period's nBits instead of parent's.
- **RPC**: 42 methods including getpeerinfo (18 fields), getmininginfo, getnetworkhashps, getnettotals, validateaddress, savemempool, ping, help, getmemoryinfo, getrpcinfo, logging, createrawtransaction, combinerawtransaction, signrawtransactionwithkey, getchaintxstats, gettxoutsetinfo, getmempoolancestors, getmempooldescendants, gettxoutproof, verifytxoutproof.

## Conventions

- Package imports use relative paths: `import "../crypto"`
- Hash type: `wire.Hash256 :: crypto.Hash256` (aliased)
- Wire serialization: manual little-endian byte ops
- `or_return` for error propagation
- Tests use `context.temp_allocator` for temporary data
- Foreign C bindings follow `crypto/secp256k1.odin` pattern
- When a block fails validation during sync, write a regression test against the raw tx/block data (save hex to `script/testdata/`, fetch prevouts from mempool.space API). See `test_signet_250058_tx11_p2wpkh` as the pattern.
