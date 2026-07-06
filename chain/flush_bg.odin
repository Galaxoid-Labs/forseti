package chain

import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "../storage"
import "../wire"

// Background UTXO flush — memtable rotation.
//
// Crash-consistency argument: the worker writes UTXO chunks WITHOUT the meta
// tip. A crash at any point mid-flush recovers from the OLD tip and replays
// blocks from flat files; replaying over partially-flushed chunks re-applies
// the same puts/deletes (idempotent). The tip marker is written only by
// flush_pump on the owner thread after the worker completes, using sync
// write options — at which point every chunk is durably ahead of it.
//
// Threading: `frozen` is written by nobody after the swap. The worker only
// reads frozen and writes to chainstate LevelDB (which the owner thread does
// not write outside flushes — single-writer preserved). The owner thread
// polls flush_done (single writer: the worker; plain bool is sufficient for
// this handshake given the pump also joins the thread before touching data).

// Cap each WriteBatch at ~16MB (Bitcoin Core's dbbatchsize). A WriteBatch
// is a single atomic WAL record: LevelDB's log grows to hold the whole
// batch and the next open REPLAYS it in full — 2M-entry chunks produced a
// 2.7GB WAL and a 4-minute startup on mainnet.
FLUSH_BATCH_BYTES :: 16 * 1024 * 1024

// Snapshot the cache and start the background flush. No-op (returns false)
// if a flush is already running or the cache is empty.
coins_cache_flush_begin :: proc(cc: ^Coins_Cache, tip_hash: Hash256, tip_height: int) -> bool {
	if cc.flush_thread != nil || cc.frozen != nil || len(cc.cache) == 0 {
		return false
	}

	log.infof("UTXO flush (background) at height %d: %d entries (%d MB live, %d MB effective / budget %d MB)",
		tip_height, len(cc.cache),
		cc.mem_usage / (1024 * 1024),
		_effective_usage(cc) / (1024 * 1024),
		cc.budget / (1024 * 1024))

	// Rotate: active map+arena become the immutable frozen layer; fresh
	// active takes over. O(1) — no entry is copied.
	cc.frozen = cc.cache
	cc.frozen_arena = cc.script_arena
	cc.frozen_mem = max(cc.mem_usage, int(cc.frozen_arena.total_used) + len(cc.frozen) * CACHE_ENTRY_OVERHEAD)
	cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, cc.allocator)
	cc.script_arena = {}
	_ = virtual.arena_init_growing(&cc.script_arena, 64 * 1024 * 1024)
	cc.mem_usage = 0

	cc.flush_tip_hash = tip_hash
	cc.flush_tip_height = tip_height
	cc.flush_done = false
	cc.flush_failed = false
	cc.flush_written = 0
	cc.flush_deleted = 0

	// GUI state.
	cc.flushing = true
	cc.flush_total = len(cc.frozen)
	cc.flush_progress = 0

	cc.flush_thread = thread.create_and_start_with_data(rawptr(cc), _flush_worker)
	return true
}

// Whether a background flush is currently running (started and not yet
// reaped by flush_pump).
coins_cache_flush_running :: proc(cc: ^Coins_Cache) -> bool {
	return cc.flush_thread != nil
}

// Reap a completed background flush: write the tip marker (the durability
// point), release the frozen layer, report. Returns true when a flush was
// completed on this call. Cheap no-op while the worker is still running.
coins_cache_flush_pump :: proc(cc: ^Coins_Cache) -> (completed: bool, err: Chain_Error) {
	if cc.flush_thread == nil || !cc.flush_done {
		return false, .None
	}

	thread.join(cc.flush_thread)
	thread.destroy(cc.flush_thread)
	cc.flush_thread = nil

	if cc.flush_failed {
		// The frozen layer is NOT durable and the live process still needs it
		// for reads (dropping it would vanish coins until a restart). Retain
		// it and respawn the worker — chunk writes are idempotent, so a
		// partial previous attempt is harmless.
		log.errorf("UTXO background flush FAILED — retaining frozen layer and retrying")
		cc.flush_failed = false
		cc.flush_done = false
		cc.flush_written = 0
		cc.flush_deleted = 0
		cc.flush_progress = 0
		cc.flush_thread = thread.create_and_start_with_data(rawptr(cc), _flush_worker)
		return false, .Storage_Error
	}

	// Tip marker last: everything the recovery replay assumes durable now is.
	batch := storage.ldb_batch_create()
	defer storage.ldb_batch_destroy(batch)
	write_meta_tip(cc.db.store, batch, cc.flush_tip_hash, cc.flush_tip_height)
	werr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.sync_opts, batch)
	if werr != .None {
		// Same retention logic: without the tip marker nothing is durable yet.
		log.errorf("UTXO background flush: tip marker write failed — will retry on next pump")
		cc.flush_done = true // stay reapable
		cc.flush_thread = thread.create_and_start_with_data(rawptr(cc), _flush_worker)
		return false, .Storage_Error
	}

	// Success: release the frozen layer — arena destroy returns every script
	// byte (live and dead) to the OS in one shot.
	virtual.arena_destroy(&cc.frozen_arena)
	delete(cc.frozen)
	cc.frozen = nil
	cc.frozen_mem = 0
	cc.flushing = false
	cc.flush_progress = 0

	log.infof("UTXO flush (background) complete: wrote %d, deleted %d, tip -> %d",
		cc.flush_written, cc.flush_deleted, cc.flush_tip_height)
	return true, .None
}

// Block until any in-flight background flush is fully reaped. Used by the
// shutdown path and by backpressure (cache overfilling while a flush runs).
coins_cache_flush_join :: proc(cc: ^Coins_Cache) {
	if cc.flush_thread == nil {
		return
	}
	for {
		completed, _ := coins_cache_flush_pump(cc)
		if completed {
			return
		}
		sync.cpu_relax()
		thread.yield()
	}
}

// Worker: stream the frozen layer to LevelDB in chunked batches (no tip).
_flush_worker :: proc(data: rawptr) {
	cc := cast(^Coins_Cache)data

	batch := storage.ldb_batch_create()
	batch_bytes := 0
	processed := 0

	for outpoint, entry in cc.frozen {
		processed += 1
		if processed % 100_000 == 0 {
			cc.flush_progress = processed
		}
		if .Dirty not_in entry.flags {
			continue
		}
		if _is_spent_sentinel_val(entry) {
			storage.utxo_db_batch_delete(cc.db, batch, outpoint)
			cc.flush_deleted += 1
			batch_bytes += 48 // key + batch overhead
		} else {
			storage.utxo_db_batch_put(cc.db, batch, outpoint, entry.coin)
			cc.flush_written += 1
			batch_bytes += 64 + len(entry.coin.script) // key + encoded value + overhead
		}

		if batch_bytes >= FLUSH_BATCH_BYTES {
			werr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.write_opts, batch)
			storage.ldb_batch_destroy(batch)
			free_all(context.temp_allocator)
			if werr != .None {
				cc.flush_failed = true
				cc.flush_done = true
				return
			}
			batch = storage.ldb_batch_create()
			batch_bytes = 0
		}
	}

	// Final partial chunk — synced, so all data is durable before the owner
	// thread writes the tip marker.
	werr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.sync_opts, batch)
	storage.ldb_batch_destroy(batch)
	free_all(context.temp_allocator)
	if werr != .None {
		cc.flush_failed = true
	}
	cc.flush_progress = processed
	cc.flush_done = true
}
