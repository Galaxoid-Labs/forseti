# Move the address index to RocksDB (make the wallet-backend build fast)

> **STATUS: PLAN — not implemented.** Swap the `--index-addresses` scripthash
> index off LevelDB and onto RocksDB (chainstate/block-index/txindex stay on
> LevelDB). Motivated by hard numbers from the first full-mainnet index build:
> the LevelDB engine tripled IBD time.

## The problem (measured, mainnet, 2026-07-12)

Building the scripthash index during IBD is dominated by LevelDB compaction:

- Bare forseti (no index): full mainnet in **~5–6 h**.
- With `--index-addresses`: **~14 h and only ~81% of blocks / below assumevalid.**
- Node profiler: **`index` = ~86% of every block's connect time** (~92 ms of ~108 ms/block; a bare block is ~16 ms).
- **5.17 TB written to disk in 14 h** for a 316 GB index (block files are only 565 GB, written once). That's ~10–16× write amplification: LevelDB rewriting the index over and over during compaction.

Root cause: the index is **randomly keyed** (`scripthash = sha256(spk)`), so every
memtable flush scatters across the whole multi-hundred-GB keyspace — worst case
for LevelDB's **single** compaction thread, which write-stalls the chain thread
(low CPU + high iowait; NVMe bandwidth to spare). At ~316 GB the DB is ~158,000
tiny 2 MB SSTs, and one compaction thread cannot keep up. Bigger memtable
(128 MB→1 GB) roughly halved it but can't beat the single-thread ceiling, and the
per-block cost keeps climbing with DB size.

This is the exact reason electrs/Fulcrum use RocksDB for this index. LevelDB was
chosen only because forseti already vendored it for the chainstate.

## Why RocksDB fixes it

RocksDB is a LevelDB fork built for this workload. It attacks all three bottlenecks:

1. **Multi-threaded compaction** (`max_background_jobs`) — the #1 win. The 5 TB of
   compaction is currently funneled through one thread; RocksDB parallelizes it.
2. **Universal (tiered) compaction** — an alternative to leveled compaction that
   trades space for far lower write amplification (~10–16× → ~2–4×). Ideal for a
   bulk-build-then-serve index.
3. **Built-in compression** (LZ4/Zstd) — LevelDB here uses none. Even ~30–40%
   smaller = proportionally less compaction I/O, and we have idle CPU to spend.
4. **Configurable, larger SST files** (`target_file_size_base`) — kills the
   ~158k-tiny-file overhead (LevelDB's C API doesn't even expose file size).
5. **Bulk SST ingestion** (`SstFileWriter` + `IngestExternalFile`) — write
   pre-sorted SST files and add them to the tree with near-zero compaction. The
   fast-indexer path (Phase 2 below).

RocksDB exposes a **LevelDB-compatible C API** (`rocksdb/c.h`), so `storage/
addrindexdb.odin` ports with modest changes.

## Scope: addrindex only

Move ONLY the address index. Leave chainstate, block index, `--txindex`, and the
BIP158 filter index on LevelDB — they aren't the bottleneck (the chainstate is
small and already batched behind the write-back coins cache). This keeps the
integration surface small and the risk contained.

## Phased delivery

### Phase 1 — engine swap, per-block writes UNCHANGED (low risk, most of the win)

Swap LevelDB→RocksDB for the addrindex with bulk-load tuning, but keep the exact
same write pattern (one atomic `WriteBatch` per block, `best` marker inside it).
**No change to the reorg/crash-consistency model** — the per-block atomic batch
and `addr_index_catchup` recovery are identical; only the storage engine differs.

Tuning (RocksDB options at open):
- `max_background_jobs = 6–8` (multi-threaded compaction — the big one).
- `compaction_style = universal` (or leveled with `level_compaction_dynamic_level_bytes`), tuned for write-heavy bulk load.
- `compression = LZ4` (fast) or `Zstd` (smaller); bottom-level Zstd is a good default.
- `target_file_size_base = 64–256 MB` (far fewer files than 2 MB).
- `write_buffer_size = 512 MB–1 GB`, `max_write_buffer_number = 3–4`.
- `bytes_per_sync` set so the OS flushes steadily instead of in giant bursts.
- Bloom filter + block cache for the serve path (as today).

Expectation: multi-threaded compaction + compression alone should relieve the
single-thread stall and bring the with-index sync much closer to bare (target:
well under 2× instead of ~3×). **Measure before deciding whether Phase 2 is needed.**

### Phase 2 — bulk SST ingest during IBD (only if Phase 1 isn't enough)

The fast-indexer pattern: during IBD, don't write per-block. Buffer index rows
across a window (aligned with the chainstate flush, e.g. every ~5k blocks or a
size cap), **sort by key**, write a RocksDB SST via `SstFileWriter`, and
`IngestExternalFile`. Sorted, write-once input makes compaction cheap. At the tip,
switch back to per-block writes so queries stay current.

Phase 2 introduces the SAME correctness surface as the shelved "batch writes"
lever (`best` marker lags the tip; a reorg can hit buffered rows), so it needs the
same guardrails, which MUST be in the design:
- **Flush the buffer before any `disconnect_block`** (reorgs during IBD are rare;
  flush-then-disconnect sidesteps buffer-reorg-awareness entirely).
- **Per-block writes at the tip** (batched only during IBD); test the IBD↔tip
  handoff loses nothing.
- Recovery is still forward-replay from `best` off the flat files + undo
  (idempotent), so a coarser `best` is already supported — a crash re-indexes the
  uncommitted tail. Add a crash-mid-ingest test and a reorg-mid-buffer test.

## Binding surface (`storage/rocksdb.odin`, new)

Mirror `storage/leveldb.odin`. Most calls map 1:1 (names differ `leveldb_`→`rocksdb_`):
`rocksdb_open`, `rocksdb_close`, `rocksdb_put/get/delete`, `rocksdb_write`,
`rocksdb_writebatch_{create,put,delete,clear,destroy}`, `rocksdb_create_iterator`,
`rocksdb_iter_{seek,valid,next,key,value,destroy}`, `rocksdb_options_create`, etc.
Plus RocksDB-specific setters: `rocksdb_options_set_max_background_jobs`,
`rocksdb_options_set_compaction_style` (universal), `rocksdb_options_set_compression`
(LZ4/Zstd), `rocksdb_options_set_target_file_size_base`,
`rocksdb_options_set_max_bytes_for_level_base`,
`rocksdb_options_set_write_buffer_size`. Phase 2 adds
`rocksdb_sstfilewriter_{create,open,add,finish}`, `rocksdb_ingestexternalfile`,
`rocksdb_ingestexternalfileoptions_create`, `rocksdb_compact_range`.

`storage/addrindexdb.odin` keeps its exact public surface
(`addr_index_write_block`, `_unwrite_block`, `_get_history`, `_get_utxos`,
`_get_tx`, `_best`, `_disk_size`) — only the internal handle type + option setup
change. `chain/addrindex.odin` (connect/disconnect/catchup) is UNCHANGED.

## Vendoring / build (the heaviest part)

- Build `librocksdb.a` (static) into `deps/lib/`, plus its compression deps
  (`libzstd.a`, `liblz4.a`, optionally `libsnappy.a`), wired into `deps/build.sh`.
  RocksDB builds via CMake/Makefile; pin a release tag. Link with `-lstdc++`
  (already linked) + the compression libs.
- Faster-to-prototype alternative: dynamically link the system `librocksdb` first
  to validate the perf win, then vendor static for the self-contained binary.
- Binary size grows (RocksDB is bigger than LevelDB) — acceptable; the index is
  opt-in and this only pulls RocksDB in for `--index-addresses` builds.

## Migration (existing LevelDB index)

RocksDB can't cleanly reuse the 316 GB LevelDB addrindex. Options:
- **Rebuild from scratch** via `addr_index_catchup` (walk all blocks on disk — no
  network). With RocksDB's speed this reindex is far faster than the original
  build, and it's the clean path since the index is prune-incompatible and fully
  derivable from block+undo data.
- On startup, if a LevelDB-format `addrindex/` is detected under a RocksDB build,
  refuse with a clear "reindex required (engine changed)" message, or auto-nuke +
  rebuild behind a flag.
- For the current in-flight sync: let it finish on LevelDB as the **correctness
  reference**, then switch builds and reindex to compare speed + verify identical
  results (diff scripthash balances/history against the LevelDB reference).

## Testing

- **Correctness parity:** on regtest/signet, the RocksDB index must produce
  byte-identical query results to the LevelDB one (reuse `test_addr_index_*`).
- **Reorg-safe:** existing disconnect test + (Phase 2) reorg-mid-buffer +
  crash-mid-ingest tests.
- **BDK e2e:** `test/bdk-esplora/` must still pass unchanged.
- **Perf:** measure per-block `index` ms + total disk-write bytes vs the LevelDB
  baseline on the same signet/mainnet range; target: index share and write
  amplification down several-fold, IBD-with-index approaching bare.

## Risks / open questions

- **Build complexity:** vendoring RocksDB + compression libs statically is the
  main cost; keep it opt-in to the addrindex so non-wallet builds are unaffected.
- **Universal vs leveled compaction:** universal lowers write-amp but raises space
  + read-amp; measure both. Space matters (index already ~316 GB → could be larger
  under universal before the final compaction).
- **Phase 2 correctness** is the real risk (buffer + reorg); Phase 1 has none, so
  ship + measure Phase 1 first and only take on Phase 2 if the numbers demand it.
- **Compression gain uncertain:** scripthash keys are high-entropy (sha256), so
  key compression is limited; values (heights/amounts) and repeated prefixes
  compress better. Measure; Zstd on the bottom level is the safe default.

## References

- Current index: `storage/addrindexdb.odin`, `chain/addrindex.odin`.
- The measured evidence + the shelved batch-write lever: memory
  `address-index-esplora`.
- Prior art: electrs (RocksDB), Fulcrum (RocksDB) — both chose RocksDB for exactly
  this scripthash-index workload.
- RocksDB C API: `rocksdb/c.h`; bulk load: `SstFileWriter` + `IngestExternalFile`.

## Phase 3 — parallelize the index build (ACCEPTED, after measuring 801k→957k)

Measured on the RocksDB reindex: RocksDB has **0% write-stall** (LevelDB stalled
for minutes), so the compaction problem is solved — but the build is now
**single-thread CPU-bound** (catchup thread at 93% of one core: deserialize +
txid/scripthash sha256 + row-building), ~27 blk/s in the dense region.

Fix — "compute-parallel, commit-serial":
- **Parallel (workers):** for each block, deserialize + compute txids + compute
  scripthashes + build the (funding, spending, tx_locs) row lists. Pure functions
  of block+undo data, no shared state → safe to run across the worker pool.
- **Serial (main thread):** apply each block's rows to RocksDB in STRICT block
  order via the existing per-block atomic WriteBatch + `best` marker. The U-index
  (utxo-by-scripthash) is stateful (add-on-fund / delete-on-spend); out-of-order
  or concurrent apply = wrong balances. This boundary is non-negotiable.
- Producer-consumer pipeline; reuse the script-verification worker pool.
- **Catchup/reindex first** (fixed block set, no reorgs — safest). Live-IBD adds
  the reorg-discard requirement (speculative work ahead of tip must be dropped on
  a disconnect — same guardrail as the shelved batch-write lever).
- **Guardrail test:** the parallel index must be BYTE-IDENTICAL to the serial one
  on regtest/signet (catches any U-ordering bug).
- Expected ~2–3× on index-build CPU (Amdahl: serial write ~20–30%).
