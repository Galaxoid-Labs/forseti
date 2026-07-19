package chain

// Parallel address-index build for catchup/reindex. The per-block work — read
// block + undo from disk, compute txids, hash scripthashes, build the H/U/T
// rows — is pure and independent, so it fans out to the worker pool. The RocksDB
// apply stays STRICTLY serial and in block order: the U-index (utxo-by-
// scripthash) is stateful (add-on-fund / delete-on-spend), so an out-of-order or
// concurrent apply = wrong balances. See docs/plans/addrindex-rocksdb.md Phase 3.
//
// Safe to fan out the reads because flat_file_read opens a fresh fd + pread
// (positional, no shared seek). Reindex has no reorgs, so no speculative-work
// rollback is needed (that's a live-IBD concern, deferred).

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "../storage"
import "../wire"

// Blocks per parallel batch. Bounds peak memory: all `BATCH` blocks' built rows
// are held on the heap between the parallel build and the serial apply.
ADDR_PARALLEL_BATCH :: 256

_Addr_Block_Status :: enum { Ok, Skip, Error }

// One block's built index rows, heap-allocated so they outlive the worker.
_Addr_Block_Rows :: struct {
	status:   _Addr_Block_Status,
	hash:     Hash256,
	height:   int,
	funding:  []storage.Addr_Funding,
	spending: []storage.Addr_Spending,
	tx_locs:  []storage.Addr_Tx_Loc,
}

// Build one block's rows from disk. Rows go on out_alloc (heap); temporaries use
// context.temp_allocator (the worker's arena). Skip = genesis (no data, nothing
// to index); Error = a real failure (missing block/undo for a block with spends).
_addr_build_block_rows_at :: proc(cs: ^Chain_State, h: int, out_alloc: mem.Allocator) -> _Addr_Block_Rows {
	res: _Addr_Block_Rows
	res.height = h
	entry, found := cs.block_index.entries[cs.active_chain[h]]
	if !found || .Has_Data not_in entry.status {
		res.status = h == 0 ? .Skip : .Error
		return res
	}
	res.hash = entry.hash
	block, rerr := _read_block_from_disk(cs, entry)
	if rerr != .None {
		res.status = .Error
		return res
	}
	txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		txids[i] = wire.tx_id(&block.txs[i])
	}
	spent, ok := _addr_read_spent(cs, &block, entry)
	if !ok {
		res.status = .Error
		return res
	}
	res.funding, res.spending, res.tx_locs = _addr_index_build_rows(&block, txids, h, spent, out_alloc)
	res.status = .Ok
	return res
}

_Addr_Build_Task :: struct {
	cs:          ^Chain_State,
	batch_start: int, // height of results[0]
	lo, hi:      int, // this worker's result-index range [lo, hi)
	results:     []_Addr_Block_Rows,
	out_alloc:   mem.Allocator, // heap: rows must survive past the worker
	wg:          ^sync.Wait_Group,
}

_addr_build_worker :: proc(task: thread.Task) {
	t := cast(^_Addr_Build_Task)task.data
	cs := t.cs
	wg := t.wg
	arena := _arena_pool_acquire(cs)
	context.temp_allocator = virtual.arena_allocator(arena)
	for i in t.lo ..< t.hi {
		t.results[i] = _addr_build_block_rows_at(cs, t.batch_start + i, t.out_alloc)
		virtual.arena_free_all(arena) // reset temp between blocks
	}
	_arena_pool_release(cs, arena)
	sync.wait_group_done(wg)
}

// Batch-parallel build + serial ordered apply. Caller must have verified the
// worker pool is available (len(arena_pool_arenas) >= 2). Returns false on a real
// error (missing block/undo).
_addr_index_catchup_parallel :: proc(cs: ^Chain_State, start, tip_height: int) -> bool {
	num_workers := len(cs.arena_pool_arenas)
	heap := context.allocator

	// Publish progress for the warmup boot screen / getnodestatus (this phase can
	// be a 100k+ block catch-up and otherwise shows a static height, looking hung).
	Boot_Height = start
	Boot_Target = tip_height

	for batch_start := start; batch_start <= tip_height; batch_start += ADDR_PARALLEL_BATCH {
		batch_end := min(batch_start + ADDR_PARALLEL_BATCH - 1, tip_height)
		count := batch_end - batch_start + 1

		results := make([]_Addr_Block_Rows, count, context.temp_allocator)
		nw := min(num_workers, count)
		tasks := make([]_Addr_Build_Task, nw, context.temp_allocator)

		wg: sync.Wait_Group
		sync.wait_group_add(&wg, nw)
		chunk := count / nw
		rem := count % nw
		off := 0
		for w in 0 ..< nw {
			sz := chunk + (1 if w < rem else 0)
			tasks[w] = _Addr_Build_Task{
				cs = cs, batch_start = batch_start, lo = off, hi = off + sz,
				results = results, out_alloc = heap, wg = &wg,
			}
			thread.pool_add_task(&cs.verify_pool, context.allocator, _addr_build_worker, &tasks[w])
			off += sz
		}
		sync.wait_group_wait(&wg)

		// Serial ordered apply — coalesce the whole batch into ONE RocksDB commit.
		// Per-block commits were the serial-apply bottleneck (lock + WAL append ×
		// count); one WriteBatch collapses that. Ordering within the batch stays
		// (block order, funding-before-spending per block), byte-identical to
		// per-block writes, so the stateful U-index add/delete order is preserved.
		entries := make([dynamic]storage.Addr_Block_Batch_Entry, 0, count, context.temp_allocator)
		for i in 0 ..< count {
			r := &results[i]
			switch r.status {
			case .Skip:
				continue
			case .Error:
				log.errorf("addrindex: block %d unavailable/undo-missing — cannot build index", batch_start + i)
				return false
			case .Ok:
				append(&entries, storage.Addr_Block_Batch_Entry{
					hash     = r.hash,
					height   = r.height,
					funding  = r.funding,
					spending = r.spending,
					tx_locs  = r.tx_locs,
				})
			}
		}
		if len(entries) > 0 {
			if err := storage.addr_index_write_blocks(cs.addr_index, entries[:]); err != .None {
				log.errorf("addrindex: failed to write index batch ending at height %d", batch_end)
				return false
			}
		}
		for i in 0 ..< count {
			r := &results[i]
			if r.status == .Ok {
				delete(r.funding, heap)
				delete(r.spending, heap)
				delete(r.tx_locs, heap)
			}
		}

		Boot_Height = batch_end // live progress for the warmup boot screen
		if batch_end % 10_000 < ADDR_PARALLEL_BATCH && batch_end > 0 {
			log.infof("addrindex: %d / %d", batch_end, tip_height)
		}
		free_all(context.temp_allocator)
	}
	return true
}
