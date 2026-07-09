package chain

import "core:log"
import "core:mem/virtual"
import "core:thread"
import "core:mem"
import "../storage"
import "../wire"

Cache_Entry_Flag :: enum u8 {
	Dirty,
	Fresh,
}

Cache_Entry :: struct {
	coin:  storage.UTXO_Coin,
	flags: bit_set[Cache_Entry_Flag; u8],
}

// Estimated per-entry overhead: map bucket (64) + Outpoint key (36) + Cache_Entry value (64) + pointer/padding (~16)
CACHE_ENTRY_OVERHEAD :: 180

Coins_Cache :: struct {
	db:        ^storage.UTXO_DB,
	cache:     map[wire.Outpoint]Cache_Entry,
	allocator: mem.Allocator,
	mem_usage: int,   // estimated bytes of live entries
	budget:    int,   // max bytes before flush (from dbcache split)
	// All coin scripts live in this growing arena and are never individually
	// freed: spent scripts accumulate as dead bytes until full eviction
	// destroys the arena wholesale, returning memory to the OS. Per-entry
	// heap alloc/free churned tens of GB per fill-evict cycle and the
	// allocator retained the pages — RSS ratcheted ~14GB per cycle.
	script_arena: virtual.Arena,
	// Background flush ("memtable rotation"): flush_begin swaps cache ->
	// frozen and script_arena -> frozen_arena, then a worker thread streams
	// frozen to LevelDB in chunked batches WITHOUT the tip marker. The tip is
	// written by flush_pump on the owner thread at completion, so a crash
	// mid-flush recovers from the OLD tip (replay over partial chunks is
	// idempotent). frozen is immutable once swapped: spends of frozen coins
	// shadow it with sentinels in the new active map; reads layer
	// active -> frozen -> DB. Destroying frozen_arena at completion IS the
	// eviction: all frozen script bytes return to the OS in one shot.
	frozen:           map[wire.Outpoint]Cache_Entry,
	frozen_arena:     virtual.Arena,
	frozen_mem:       int, // effective bytes held by the frozen layer
	flush_thread:     ^thread.Thread,
	flush_done:       bool, // set by the worker (plain bool: single writer, polled)
	flush_tip_hash:   Hash256,
	flush_tip_height: int,
	// Drivechain state blob snapshotted at flush start (matches the flush
	// tip); written into the tip-marker batch so it stays atomic with the
	// tip. Owned by the cache until written (heap clone).
	flush_dc_state:   []byte,
	flush_written:    int,
	flush_deleted:    int,
	flush_failed:     bool,
	// Live flush state for the GUI (written by the flushing thread, read
	// cross-thread by the status snapshot — plain ints, torn reads harmless).
	flushing:       bool,
	flush_total:    int,
	flush_progress: int,
	// Rolling logical-UTXO-set stats (coin count + total sats), maintained by
	// add/spend/restore so every path — connect, rollback, disconnect,
	// recovery replay — stays consistent. Valid only when loaded from the
	// persisted "utxostats" key or when the datadir started from genesis;
	// legacy datadirs keep the slow-scan gettxoutsetinfo until a resync.
	stat_count:        i64,
	stat_amount:       i64,
	stats_valid:       bool,
	// Snapshot taken at flush begin (the live counters advance while the
	// background worker runs); written into the tip-marker batch.
	flush_stat_count:  i64,
	flush_stat_amount: i64,
	flush_stats_valid: bool,
	// Crash-recovery high-water mark. After an undo-based rollback the DB may
	// still hold coins from a pre-crash PARTIAL flush anywhere in the rolled-back
	// range; those blocks get re-connected (re-downloaded) over that dirty state.
	// coins_cache_add's Fresh flag asserts "provably never in the DB" — TRUE in
	// forward sync (a txid commits to its inputs, so outpoints are unique) but
	// FALSE when re-creating a coin whose stale DB copy survived. A Fresh coin
	// that is later spent is dropped with no delete sentinel, leaking the DB
	// copy. So for coins created at height <= this mark, add is NOT Fresh (it
	// leaves a delete sentinel on spend). 0 = disabled (normal forward sync).
	fresh_unsafe_at_or_below: int,
}

UTXO_STATS_KEY :: "utxostats"

_utxo_stats_blob :: proc(count: i64, amount: i64) -> [16]byte {
	b: [16]byte
	c := transmute(u64)count
	a := transmute(u64)amount
	for i in 0 ..< 8 {
		b[i] = byte(c >> uint(i * 8))
		b[8 + i] = byte(a >> uint(i * 8))
	}
	return b
}

// Allocator over the cache's script arena. Derived per call — Coins_Cache is
// returned by value from init, so an allocator captured there would point at
// the pre-copy stack address (first alloc then parks on a garbage mutex).
_script_alloc :: proc(cc: ^Coins_Cache) -> mem.Allocator {
	return virtual.arena_allocator(&cc.script_arena)
}

coins_cache_init :: proc(db: ^storage.UTXO_DB, budget: int = 440 * 1024 * 1024, allocator := context.allocator) -> Coins_Cache {
	cc: Coins_Cache
	cc.db = db
	cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, allocator)
	cc.allocator = allocator
	cc.budget = budget
	cc.mem_usage = 0
	_ = virtual.arena_init_growing(&cc.script_arena, 64 * 1024 * 1024)
	return cc
}

// Effective memory footprint: live-entry estimate or the script arena's true
// allocated bytes (live + dead-until-eviction) plus map overhead, whichever
// is larger. Budget decisions use this so dead script bytes can't ratchet
// RSS past the budget.
_effective_usage :: proc(cc: ^Coins_Cache) -> int {
	arena_backed := int(cc.script_arena.total_used) + len(cc.cache) * CACHE_ENTRY_OVERHEAD
	return max(cc.mem_usage, arena_backed) + cc.frozen_mem
}

coins_cache_destroy :: proc(cc: ^Coins_Cache) {
	coins_cache_flush_join(cc) // never leave a worker thread running
	virtual.arena_destroy(&cc.script_arena)
	delete(cc.cache)
	delete(cc.flush_dc_state)
}

// Look up a UTXO. Checks cache first, then falls through to DB.
coins_cache_get :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint) -> (storage.UTXO_Coin, bool) {
	entry, found := cc.cache[outpoint]
	if found {
		// Spent sentinel: zeroed coin with Dirty flag
		if _is_spent_sentinel(&entry) {
			return {}, false
		}
		return entry.coin, true
	}

	// Frozen layer (mid background flush): authoritative over the DB, which
	// may not have received this entry's chunk yet. Read-only — no promotion
	// into active (the coin is already memory-resident here).
	if cc.frozen != nil {
		fentry, ffound := cc.frozen[outpoint]
		if ffound {
			if _is_spent_sentinel(&fentry) {
				return {}, false
			}
			return fentry.coin, true
		}
	}

	// Fall through to DB
	coin, db_found := storage.utxo_db_get(cc.db, outpoint, _script_alloc(cc))
	if !db_found {
		return {}, false
	}

	// Cache it (not dirty, not fresh — it's in DB)
	cc.cache[outpoint] = Cache_Entry{coin = coin, flags = {}}
	cc.mem_usage += CACHE_ENTRY_OVERHEAD + len(coin.script)
	return coin, true
}

// Check if a UTXO exists.
coins_cache_has :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint) -> bool {
	entry, found := cc.cache[outpoint]
	if found {
		return !_is_spent_sentinel(&entry)
	}
	_, db_found := coins_cache_get(cc, outpoint) // handles frozen + DB layers
	return db_found
}

// Stats hook for adds. Non-coinbase outputs are always brand new (their
// txid embeds their inputs). Coinbase adds can OVERWRITE a live coin — the
// pre-BIP30 duplicate coinbases (mainnet 91842/91880) — replacing it in the
// set; only those pay for an existence lookup, and only ~1-2 per block.
_stats_on_add :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint, coin: storage.UTXO_Coin) {
	if !cc.stats_valid { return }
	if coin.is_coinbase {
		if e, in_cache := &cc.cache[outpoint]; in_cache {
			if !_is_spent_sentinel(e) {
				cc.stat_amount += coin.amount - e.coin.amount
				return
			}
		} else {
			if cc.frozen != nil {
				if fe, in_frozen := cc.frozen[outpoint]; in_frozen {
					if !_is_spent_sentinel_val(fe) {
						cc.stat_amount += coin.amount - fe.coin.amount
						return
					}
					// frozen sentinel: logically spent — normal add below
					cc.stat_count += 1
					cc.stat_amount += coin.amount
					return
				}
			}
			if old, in_db := storage.utxo_db_get(cc.db, outpoint, context.temp_allocator); in_db {
				cc.stat_amount += coin.amount - old.amount
				return
			}
		}
	}
	cc.stat_count += 1
	cc.stat_amount += coin.amount
}

// Add a new UTXO to the cache (Dirty+Fresh).
coins_cache_add :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint, coin: storage.UTXO_Coin) {
	_stats_on_add(cc, outpoint, coin)
	// Clone script into the cache's script arena
	new_script: []byte
	if len(coin.script) > 0 {
		new_script = make([]byte, len(coin.script), _script_alloc(cc))
		copy(new_script, coin.script)
	}

	// Fresh = "provably never reached the DB", so a later spend can drop it with
	// no delete sentinel. Safe in forward sync, UNSAFE for coins re-created over
	// a crash-recovery dirty region (their stale DB copy would leak). Below the
	// recovery high-water mark, withhold Fresh so a spend leaves a delete.
	flags := bit_set[Cache_Entry_Flag; u8]{.Dirty, .Fresh}
	if cc.fresh_unsafe_at_or_below != 0 && int(coin.height) <= cc.fresh_unsafe_at_or_below {
		flags = {.Dirty}
	}

	cc.cache[outpoint] = Cache_Entry {
		coin  = storage.UTXO_Coin {
			height      = coin.height,
			is_coinbase = coin.is_coinbase,
			amount      = coin.amount,
			script      = new_script,
		},
		flags = flags,
	}
	cc.mem_usage += CACHE_ENTRY_OVERHEAD + len(new_script)
}

// Spend a UTXO. Returns the spent coin for undo data.
// The returned coin's script is cloned to context.temp_allocator (block arena)
// so callers don't need to free it — it's reclaimed when the arena resets.
coins_cache_spend :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint) -> (storage.UTXO_Coin, bool) {
	entry, found := &cc.cache[outpoint]
	if found {
		if _is_spent_sentinel(entry) {
			return {}, false
		}

		if cc.stats_valid {
			cc.stat_count -= 1
			cc.stat_amount -= entry.coin.amount
		}

		spent_coin := entry.coin

		// Clone script to temp allocator before discarding the heap copy.
		// The caller (connect_block/disconnect_block/_rollback) uses the script
		// only within the current block's arena lifetime.
		if len(spent_coin.script) > 0 {
			temp_script := make([]byte, len(spent_coin.script), context.temp_allocator)
			copy(temp_script, spent_coin.script)
			// Arena-owned script becomes dead bytes; reclaimed at full eviction.
			spent_coin.script = temp_script
		}

		if .Fresh in entry.flags {
			// Never reached DB — just remove from cache entirely
			cc.mem_usage -= CACHE_ENTRY_OVERHEAD + len(spent_coin.script)
			delete_key(&cc.cache, outpoint)
		} else {
			// Was in DB — leave a spent sentinel so flush deletes it
			cc.mem_usage -= len(spent_coin.script) // script is dead in the arena, only overhead remains
			entry.coin = storage.UTXO_Coin{}
			entry.flags = {.Dirty}
		}

		return spent_coin, true
	}

	// Frozen layer (mid background flush): the entry is immutable there —
	// spend by shadowing it with a sentinel in the ACTIVE map. Not Fresh:
	// the coin is (or is about to be) in the DB, so the next flush must
	// issue a delete for it.
	if cc.frozen != nil {
		fentry, ffound := cc.frozen[outpoint]
		if ffound {
			if _is_spent_sentinel(&fentry) {
				return {}, false
			}
			if cc.stats_valid {
				cc.stat_count -= 1
				cc.stat_amount -= fentry.coin.amount
			}
			spent_coin := fentry.coin
			if len(spent_coin.script) > 0 {
				temp_script := make([]byte, len(spent_coin.script), context.temp_allocator)
				copy(temp_script, spent_coin.script)
				spent_coin.script = temp_script
			}
			cc.cache[outpoint] = Cache_Entry{coin = {}, flags = {.Dirty}}
			cc.mem_usage += CACHE_ENTRY_OVERHEAD
			return spent_coin, true
		}
	}

	// Not in cache — read from DB straight into the block temp arena (the
	// caller only uses the script within the current block's lifetime).
	coin, db_found := storage.utxo_db_get(cc.db, outpoint, context.temp_allocator)
	if !db_found {
		return {}, false
	}

	if cc.stats_valid {
		cc.stat_count -= 1
		cc.stat_amount -= coin.amount
	}

	// Mark as spent sentinel in cache (no script, just overhead)
	cc.cache[outpoint] = Cache_Entry{coin = {}, flags = {.Dirty}}
	cc.mem_usage += CACHE_ENTRY_OVERHEAD
	return coin, true
}

// Restore a previously spent UTXO (for disconnect_block).
coins_cache_restore :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint, coin: storage.UTXO_Coin) {
	// Clone script into the script arena
	new_script: []byte
	if len(coin.script) > 0 {
		new_script = make([]byte, len(coin.script), _script_alloc(cc))
		copy(new_script, coin.script)
	}

	cached_coin := storage.UTXO_Coin {
		height      = coin.height,
		is_coinbase = coin.is_coinbase,
		amount      = coin.amount,
		script      = new_script,
	}

	if cc.stats_valid {
		if e, live := &cc.cache[outpoint]; live && !_is_spent_sentinel(e) {
			// Replacing an existing live coin (shouldn't happen normally)
			cc.stat_amount += coin.amount - e.coin.amount
		} else {
			cc.stat_count += 1
			cc.stat_amount += coin.amount
		}
	}

	// Check if there's an existing entry (spent sentinel)
	existing, exists := cc.cache[outpoint]
	if exists && _is_spent_sentinel(&existing) {
		// Was in DB, now restoring — Dirty but not Fresh
		// Sentinel had no script, add script size back
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty}}
		cc.mem_usage += len(new_script)
	} else if !exists {
		// Not in cache — Dirty WITHOUT Fresh. Fresh means "provably never
		// reached the DB", which a restore cannot know: recovery rollback
		// restores coins over arbitrary partial-flush states, and a Fresh
		// restore that gets re-spent is dropped from the cache with NO
		// delete sentinel — any DB copy survives forever. The 2026-07-06
		// recovery cycles leaked ~265M stale coins into mainnet chainstate
		// exactly this way (443M entries where ~178M belong; caught by the
		// post-sync gettxoutsetinfo audit). Cost of Dirty-only: a redundant
		// DB delete per restored-then-respent coin.
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty}}
		cc.mem_usage += CACHE_ENTRY_OVERHEAD + len(new_script)
	} else {
		// Existing non-sentinel entry — just replace (shouldn't happen normally)
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty, .Fresh}}
	}
}

// Flush dirty entries to DB. UTXO changes go out in chunked 16MB
// WriteBatches; the tip marker (+ dc/utxostats) is written LAST in its own
// synced batch, so a crash mid-flush recovers from the old tip and replays
// idempotently (see the chunking rationale below and flush_bg.odin).
coins_cache_flush :: proc(cc: ^Coins_Cache, tip_hash: Hash256, tip_height: int, dc_state: []byte = nil) -> Chain_Error {
	// A concurrently-running background flush would race this one's tip
	// marker ahead of its own chunks — reap it fully first.
	coins_cache_flush_join(cc)
	cache_size := len(cc.cache)
	cc.flushing = true
	cc.flush_total = cache_size
	cc.flush_progress = 0
	defer {
		cc.flushing = false
		cc.flush_progress = 0
	}
	log.infof("UTXO flush at height %d: %d entries (%d MB live, %d MB effective / budget %d MB)",
		tip_height, cache_size,
		cc.mem_usage / (1024 * 1024),
		_effective_usage(cc) / (1024 * 1024),
		cc.budget / (1024 * 1024))

	batch := storage.ldb_batch_create()
	defer storage.ldb_batch_destroy(batch)

	// Chunked 16MB batches (see FLUSH_BATCH_BYTES): a single giant batch is
	// one atomic WAL record — it bloats the log to batch size and the next
	// DB open replays all of it. Crash consistency is unchanged: the tip
	// marker goes in a final synced batch AFTER all chunks are durable, so
	// a crash mid-flush recovers from the old tip and replays idempotently.
	written, deleted := 0, 0
	processed := 0
	batch_bytes := 0
	for outpoint, entry in cc.cache {
		processed += 1
		if processed % 100_000 == 0 {
			cc.flush_progress = processed
		}
		if cache_size >= 10_000_000 && processed % 10_000_000 == 0 {
			log.infof("UTXO flush: scanned %d / %d cache entries...", processed, cache_size)
		}
		if .Dirty not_in entry.flags {
			continue
		}

		if _is_spent_sentinel_val(entry) {
			storage.utxo_db_batch_delete(cc.db, batch, outpoint)
			deleted += 1
			batch_bytes += 48
		} else {
			storage.utxo_db_batch_put(cc.db, batch, outpoint, entry.coin)
			written += 1
			batch_bytes += 64 + len(entry.coin.script)
		}

		if batch_bytes >= FLUSH_BATCH_BYTES {
			werr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.write_opts, batch)
			if werr != .None {
				log.errorf("UTXO flush: chunk write failed")
				return .Storage_Error
			}
			storage.ldb_batch_destroy(batch)
			batch = storage.ldb_batch_create()
			batch_bytes = 0
		}
	}

	cc.flush_progress = cache_size // scan done; GUI shows "committing"
	log.infof("UTXO flush: committing %d writes + %d deletes to LevelDB...", written, deleted)

	// Final data chunk, synced — everything durable before the tip moves.
	berr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.sync_opts, batch)
	if berr == .None {
		// Tip marker last, in its own synced batch. The drivechain state and
		// UTXO stats ride in the same batch — atomic with the tip.
		tip_batch := storage.ldb_batch_create()
		defer storage.ldb_batch_destroy(tip_batch)
		write_meta_tip(cc.db.store, tip_batch, tip_hash, tip_height)
		if dc_state != nil {
			storage.ldb_batch_put(tip_batch, transmute([]byte)string(DC_STATE_KEY), dc_state)
		}
		if cc.stats_valid {
			blob := _utxo_stats_blob(cc.stat_count, cc.stat_amount)
			storage.ldb_batch_put(tip_batch, transmute([]byte)string(UTXO_STATS_KEY), blob[:])
		} else {
			storage.ldb_batch_delete(tip_batch, transmute([]byte)string(UTXO_STATS_KEY))
		}
		berr = storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.sync_opts, tip_batch)
	}
	if berr != .None {
		log.errorf("UTXO flush: batch write failed")
		return .Storage_Error
	}

	log.infof("UTXO flush OK: wrote %d, deleted %d, pruning cache", written, deleted)

	// If over budget, do a full eviction — the UTXO set is too large to keep warm.
	// This avoids iterating 100M+ entries just to prune sentinels.
	if _effective_usage(cc) >= cc.budget {
		log.infof("Cache over budget (%d MB effective / %d MB), full eviction (%d entries)",
			_effective_usage(cc) / (1024 * 1024), cc.budget / (1024 * 1024), len(cc.cache))
		delete(cc.cache)
		cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, cc.allocator)
		cc.mem_usage = 0
		// Destroy + re-init returns ALL script memory (live and dead) to the
		// OS in one shot — this is what stops the cross-cycle RSS ratchet.
		virtual.arena_destroy(&cc.script_arena)
		_ = virtual.arena_init_growing(&cc.script_arena, 64 * 1024 * 1024)
	} else {
		// Under budget — prune spent sentinels and keep live entries warm.
		keys_to_delete := make([dynamic]wire.Outpoint, 0, deleted, context.temp_allocator)
		for outpoint, &entry in cc.cache {
			if _is_spent_sentinel(&entry) {
				append(&keys_to_delete, outpoint)
				cc.mem_usage -= CACHE_ENTRY_OVERHEAD
			} else {
				entry.flags = {}
			}
		}
		for key in keys_to_delete {
			delete_key(&cc.cache, key)
		}
		log.debugf("Cache pruned: evicted %d sentinels, kept %d live entries (%d MB)",
			len(keys_to_delete), len(cc.cache), cc.mem_usage / (1024 * 1024))
	}

	return .None
}

// Returns true when the coins cache memory usage exceeds its budget.
coins_cache_should_flush :: proc(cc: ^Coins_Cache) -> bool {
	return _effective_usage(cc) >= cc.budget
}

// Merge prefetched UTXO results into the cache (read-only warming).
// Entries are inserted as clean (not Dirty, not Fresh) — identical to a normal
// cache-miss read in coins_cache_get. Scripts are heap-allocated by workers.
// Frees scripts for items that can't be merged (duplicates or already cached).
coins_cache_prefetch_merge :: proc(cc: ^Coins_Cache, items: []Prefetch_Item) -> int {
	merged := 0
	for &item in items {
		if !item.found { continue }
		// Frozen layer holds NEWER state than the DB the workers read from —
		// merging the stale DB value would shadow it (active wins reads).
		if cc.frozen != nil && item.outpoint in cc.frozen {
			if len(item.coin.script) > 0 {
				delete(item.coin.script)
			}
			continue
		}
		if item.outpoint in cc.cache {
			// Already in cache — free the worker's heap-allocated script.
			if len(item.coin.script) > 0 {
				delete(item.coin.script)
			}
			continue
		}
		// Move the script into the cache's arena; free the worker's heap copy
		// immediately (short-lived heap churn is fine — long-lived bytes are
		// what must live in the arena so eviction can return them wholesale).
		coin := item.coin
		if len(coin.script) > 0 {
			arena_script := make([]byte, len(coin.script), _script_alloc(cc))
			copy(arena_script, coin.script)
			delete(item.coin.script)
			coin.script = arena_script
		}
		cc.cache[item.outpoint] = Cache_Entry{coin = coin, flags = {}}
		cc.mem_usage += CACHE_ENTRY_OVERHEAD + len(coin.script)
		merged += 1
	}
	return merged
}

// A spent sentinel is a zeroed coin marked Dirty (but not Fresh).
_is_spent_sentinel :: proc(entry: ^Cache_Entry) -> bool {
	return entry.coin.amount == 0 &&
	       entry.coin.height == 0 &&
	       !entry.coin.is_coinbase &&
	       len(entry.coin.script) == 0 &&
	       .Dirty in entry.flags &&
	       .Fresh not_in entry.flags
}

_is_spent_sentinel_val :: proc(entry: Cache_Entry) -> bool {
	return entry.coin.amount == 0 &&
	       entry.coin.height == 0 &&
	       !entry.coin.is_coinbase &&
	       len(entry.coin.script) == 0 &&
	       .Dirty in entry.flags &&
	       .Fresh not_in entry.flags
}
