# Bitcoin Node Odin - Project Instructions

## Build & Test

```bash
make              # Build deps + binary
make test         # Run all 163 tests (9 packages)
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

- `crypto/` — SHA-256d, RIPEMD-160, HASH160, secp256k1 bindings, Merkle root
- `wire/` — Protocol types, CompactSize, tx/block serialization, message framing
- `script/` — Script interpreter, opcodes, standard types, Taproot (BIP341/342)
- `consensus/` — Chain params, PoW, difficulty, block/tx validation, BIP325 signet
- `storage/` — LMDB bindings + wrapper, flat files, block DB, index DB, UTXO DB (8 files)
- `chain/` — UTXO cache, block index with skip list, undo data, chain state (6 files)
- `p2p/` — Peer connections, sync manager, connection manager (5 files)
- `mempool/` — Fee rates, relay policy, validation pipeline, persistence (6 files)
- `rpc/` — JSON-RPC server, 23 methods, HTTP server (4 files)
- `deps/` — libsecp256k1 (submodule), ripemd160 (vendored C), lmdb (vendored C), static libs in deps/lib/

## Key Architecture

- **Storage**: LMDB with 3 named DBs (utxo, index, meta) in `<datadir>/chainstate/`. Blocks stored in flat files (`blk*.dat`, `rev*.dat`).
- **Crash consistency**: Atomic LMDB write transaction commits UTXO changes + chain tip metadata together. Recovery strips Valid_Chain from blocks above the last flush point and replays from flat files.
- **UTXO cache**: Write-back with Dirty/Fresh flags. Flushed every 1000 blocks during sync and at shutdown. Rollback on block validation failure.
- **Sync**: Headers-first with batched LMDB writes, then multi-peer block download (getdata with Witness_Block, up to 64 blocks per peer). Bandwidth-based scoring allocates more slots to faster peers. Stall detection requeues blocks after 30s.
- **Sighash cache**: BIP143 + BIP341 intermediate hashes cached per-tx. Per-input 2MB verification arena prevents arena exhaustion for large txs.
- **Thread model**: Main (setup+wait), RPC thread, P2P thread, one reader thread per peer.

## Conventions

- Package imports use relative paths: `import "../crypto"`
- Hash type: `wire.Hash256 :: crypto.Hash256` (aliased)
- Wire serialization: manual little-endian byte ops
- `or_return` for error propagation
- Tests use `context.temp_allocator` for temporary data
- Foreign C bindings follow `crypto/secp256k1.odin` pattern
- When a block fails validation during sync, write a regression test against the raw tx/block data (save hex to `script/testdata/`, fetch prevouts from mempool.space API). See `test_signet_250058_tx11_p2wpkh` as the pattern.
