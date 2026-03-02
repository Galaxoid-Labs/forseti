package chain

import "core:log"
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
	mem_usage: int,   // estimated bytes used by cache
	budget:    int,   // max bytes before flush (from dbcache split)
}

coins_cache_init :: proc(db: ^storage.UTXO_DB, budget: int = 440 * 1024 * 1024, allocator := context.allocator) -> Coins_Cache {
	cc: Coins_Cache
	cc.db = db
	cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, allocator)
	cc.allocator = allocator
	cc.budget = budget
	cc.mem_usage = 0
	return cc
}

coins_cache_destroy :: proc(cc: ^Coins_Cache) {
	for _, entry in cc.cache {
		if len(entry.coin.script) > 0 {
			delete(entry.coin.script, cc.allocator)
		}
	}
	delete(cc.cache)
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

	// Fall through to DB
	coin, db_found := storage.utxo_db_get(cc.db, outpoint, cc.allocator)
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
	_, db_found := coins_cache_get(cc, outpoint)
	return db_found
}

// Add a new UTXO to the cache (Dirty+Fresh).
coins_cache_add :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint, coin: storage.UTXO_Coin) {
	// Clone script into cache allocator
	new_script: []byte
	if len(coin.script) > 0 {
		new_script = make([]byte, len(coin.script), cc.allocator)
		for i in 0 ..< len(coin.script) {
			new_script[i] = coin.script[i]
		}
	}

	cached_coin := storage.UTXO_Coin {
		height      = coin.height,
		is_coinbase = coin.is_coinbase,
		amount      = coin.amount,
		script      = new_script,
	}

	cc.cache[outpoint] = Cache_Entry {
		coin  = cached_coin,
		flags = {.Dirty, .Fresh},
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

		spent_coin := entry.coin

		// Clone script to temp allocator before discarding the heap copy.
		// The caller (connect_block/disconnect_block/_rollback) uses the script
		// only within the current block's arena lifetime.
		if len(spent_coin.script) > 0 {
			temp_script := make([]byte, len(spent_coin.script), context.temp_allocator)
			copy(temp_script, spent_coin.script)
			delete(entry.coin.script, cc.allocator)
			spent_coin.script = temp_script
		}

		if .Fresh in entry.flags {
			// Never reached DB — just remove from cache entirely
			cc.mem_usage -= CACHE_ENTRY_OVERHEAD + len(spent_coin.script)
			delete_key(&cc.cache, outpoint)
		} else {
			// Was in DB — leave a spent sentinel so flush deletes it
			entry.coin = storage.UTXO_Coin{}
			entry.flags = {.Dirty}
			// Sentinel is smaller (no script), but we keep overhead for the map entry
		}

		return spent_coin, true
	}

	// Not in cache — check DB (allocates script on heap)
	coin, db_found := storage.utxo_db_get(cc.db, outpoint, cc.allocator)
	if !db_found {
		return {}, false
	}

	// Clone script to temp allocator and free the heap copy
	if len(coin.script) > 0 {
		temp_script := make([]byte, len(coin.script), context.temp_allocator)
		copy(temp_script, coin.script)
		delete(coin.script, cc.allocator)
		coin.script = temp_script
	}

	// Mark as spent sentinel in cache
	cc.cache[outpoint] = Cache_Entry{coin = {}, flags = {.Dirty}}
	return coin, true
}

// Restore a previously spent UTXO (for disconnect_block).
coins_cache_restore :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint, coin: storage.UTXO_Coin) {
	// Clone script
	new_script: []byte
	if len(coin.script) > 0 {
		new_script = make([]byte, len(coin.script), cc.allocator)
		for i in 0 ..< len(coin.script) {
			new_script[i] = coin.script[i]
		}
	}

	cached_coin := storage.UTXO_Coin {
		height      = coin.height,
		is_coinbase = coin.is_coinbase,
		amount      = coin.amount,
		script      = new_script,
	}

	// Check if there's an existing entry (spent sentinel)
	existing, exists := cc.cache[outpoint]
	if exists && _is_spent_sentinel(&existing) {
		// Was in DB, now restoring — Dirty but not Fresh
		// Sentinel had no script, add script size back
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty}}
		cc.mem_usage += len(new_script)
	} else if !exists {
		// Not in cache at all — mark as Dirty+Fresh
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty, .Fresh}}
		cc.mem_usage += CACHE_ENTRY_OVERHEAD + len(new_script)
	} else {
		// Existing non-sentinel entry — just replace (shouldn't happen normally)
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty, .Fresh}}
	}
}

// Flush dirty entries to DB atomically. All UTXO changes + metadata are
// committed in a single WriteBatch for crash consistency.
coins_cache_flush :: proc(cc: ^Coins_Cache, tip_hash: Hash256, tip_height: int) -> Chain_Error {
	cache_size := len(cc.cache)
	log.infof("UTXO flush at height %d: %d entries (%d MB / budget %d MB)",
		tip_height, cache_size,
		cc.mem_usage / (1024 * 1024),
		cc.budget / (1024 * 1024))

	batch := storage.ldb_batch_create()
	defer storage.ldb_batch_destroy(batch)

	written, deleted := 0, 0
	for outpoint, entry in cc.cache {
		if .Dirty not_in entry.flags {
			continue
		}

		if _is_spent_sentinel_val(entry) {
			storage.utxo_db_batch_delete(cc.db, batch, outpoint)
			deleted += 1
		} else {
			storage.utxo_db_batch_put(cc.db, batch, outpoint, entry.coin)
			written += 1
		}
	}

	// Add chain tip metadata to the same batch
	write_meta_tip(cc.db.store, batch, tip_hash, tip_height)

	// ATOMIC: UTXOs + metadata committed together
	berr := storage.ldb_batch_write(cc.db.store.chainstate_db, cc.db.store.sync_opts, batch)
	if berr != .None {
		log.errorf("UTXO flush: batch write failed")
		return .Storage_Error
	}

	log.infof("UTXO flush OK: wrote %d, deleted %d, evicting cache", written, deleted)

	// Evict entire cache after flush to bound memory usage.
	for _, entry in cc.cache {
		if len(entry.coin.script) > 0 {
			delete(entry.coin.script, cc.allocator)
		}
	}
	delete(cc.cache)
	cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, cc.allocator)
	cc.mem_usage = 0

	return .None
}

// Returns true when the coins cache memory usage exceeds its budget.
coins_cache_should_flush :: proc(cc: ^Coins_Cache) -> bool {
	return cc.mem_usage >= cc.budget
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
