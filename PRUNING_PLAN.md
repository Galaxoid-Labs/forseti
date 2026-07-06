# Block Pruning Plan for bitcoin-node-odin

## Goal

`--prune=<MB>` (0 = off, minimum 550): keep total blk+rev flat-file usage under
the target by deleting the oldest block files after their contents are
validated, flushed, and safely behind the reorg horizon. A pruned node still
fully validates everything — it just doesn't retain old raw blocks. Mainnet
today needs ~950GB unpruned; pruned at 2GB it needs ~35GB total (chainstate
30GB dominates).

## Semantics (Bitcoin Core parity)

- Prune candidates: whole flat files (blk + matching rev) where **every** block
  is below the prune height.
- Prune height = min(tip − MIN_BLOCKS_TO_KEEP, last_flushed_height) where
  **MIN_BLOCKS_TO_KEEP = 288** (reorg safety, same as Core) and the flush bound
  protects our crash recovery, which replays stored-but-unflushed blocks from
  flat files after an unclean shutdown. Never prune what recovery might replay.
- Prune trigger: after each successful UTXO flush (the natural "state is
  durable" point), and once at startup after recovery.
- Index entries for pruned blocks keep their headers but drop `Has_Data` /
  `Has_Undo` status (persisted to index_db in the same pass). Headers-first
  sync, difficulty validation, and getheaders serving are unaffected.
- Services: a pruning node advertises `NODE_NETWORK_LIMITED` (serve the last
  288 blocks) but **not** `NODE_NETWORK`. getdata already refuses blocks
  without `Has_Data`.
- RPC: `getblockchaininfo` gains `pruned: true` and `pruneheight`; `getblock`
  and `gettxoutproof` on a pruned block return a clear "pruned" error.

## Design decisions for this codebase

1. **No per-file metadata schema.** Core tracks per-file height ranges in its
   index (CBlockFileInfo); we instead compute `file_num → (max_height,
   block_count)` by scanning the in-memory block index at prune time. ~1M
   entries scan in ~100ms at flush cadence — acceptable, zero schema change.
   Out-of-order writes from multi-peer download are handled naturally: a file
   is prunable only when its **max** height is below the prune height.
2. **Flat files move to `<datadir>/blocks/`.** They currently land in the
   datadir root (5,200 files next to mempool.dat — a known quirk). Pruning
   ships alongside a fresh-sync layout fix: new `Flat_File_Manager` paths are
   `<datadir>/blocks/blkNNNNN.dat` / `revNNNNN.dat`. Existing root-layout
   datadirs are still found via a fallback path check (no migration needed;
   the planned fresh sync starts clean).
3. **Size accounting**: total usage = Σ file sizes for existing blk+rev files,
   computed with the same scan (file count × 128MB + tail files' actual size).
   Prune deletes oldest-first (lowest file_num) until usage ≤ target.
4. **Deletion order**: persist the index status changes (batch) **before**
   deleting files — a crash between the two leaves unreferenced files (safe,
   reclaimed next pass) rather than dangling references (unsafe).

## Implementation map

| Piece | File | Change |
|---|---|---|
| `--prune=<MB>` flag + config key | `main.odin` | parse, min-550 clamp, pass to chain init; drop NODE_NETWORK from advertised services when pruning |
| Prune state | `chain/chainstate.odin` | `prune_target: int` on Chain_State; `prune_height: int` tracked |
| Core logic | `chain/prune.odin` (new) | `prune_block_files(cs) -> (files_deleted, bytes_freed)`: scan index for per-file max heights + sizes, select prunable set oldest-first, batch-update index records (clear Has_Data/Has_Undo), delete files |
| Trigger | `chain/chainstate.odin` | call after successful `coins_cache_flush` in connect path + once post-recovery at startup |
| File deletion | `storage/flatfile.odin` | `flat_file_delete(data_dir, prefix, file_num)`; `blocks/` subdir layout with root fallback |
| Status bits | `chain/block_index.odin` | ensure Has_Data/Has_Undo clears persist via existing record serialization |
| Services | `p2p/` | pruned nodes: LOCAL_SERVICES without NODE_NETWORK (NODE_NETWORK_LIMITED already advertised) |
| RPC | `rpc/handlers.odin` | `pruned`/`pruneheight` in getblockchaininfo; pruned-block error for getblock/gettxoutproof |
| GUI | `gui/gui.odin` | status bar shows `prune=2000MB` when active |

## Tests

- Prune selection (pure): synthetic index entries across files, verify
  candidate set respects max-height rule, 288-block keep, flush bound,
  oldest-first ordering to target.
- Storage roundtrip: write blocks across a file rollover, prune first file,
  verify deleted on disk, index entries lose Has_Data, blocks above survive.
- Recovery interaction: prune, kill, restart — recovery must not attempt
  replay below prune height.
- RPC: getblock on pruned height returns the pruned error.

## The payoff run

Fresh mainnet sync with `--prune=2000 --v2transport=1 --gui`: proves pruning
under real IBD load, retests BIP324 at throughput, exercises the new
RSS-stable cache arena, and shows the tx-based ETA — ending with a ~35GB
fully-validating node instead of 986GB.
