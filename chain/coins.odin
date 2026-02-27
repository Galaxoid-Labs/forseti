package chain

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

Coins_Cache :: struct {
	db:        ^storage.UTXO_DB,
	cache:     map[wire.Outpoint]Cache_Entry,
	allocator: mem.Allocator,
}

coins_cache_init :: proc(db: ^storage.UTXO_DB, allocator := context.allocator) -> Coins_Cache {
	cc: Coins_Cache
	cc.db = db
	cc.cache = make(map[wire.Outpoint]Cache_Entry, 1024, allocator)
	cc.allocator = allocator
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
}

// Spend a UTXO. Returns the spent coin for undo data.
coins_cache_spend :: proc(cc: ^Coins_Cache, outpoint: wire.Outpoint) -> (storage.UTXO_Coin, bool) {
	entry, found := &cc.cache[outpoint]
	if found {
		if _is_spent_sentinel(entry) {
			return {}, false
		}

		spent_coin := entry.coin

		if .Fresh in entry.flags {
			// Never reached DB — just remove from cache entirely
			delete_key(&cc.cache, outpoint)
		} else {
			// Was in DB — leave a spent sentinel so flush deletes it
			entry.coin = storage.UTXO_Coin{}
			entry.flags = {.Dirty}
		}

		return spent_coin, true
	}

	// Not in cache — check DB
	coin, db_found := storage.utxo_db_get(cc.db, outpoint, cc.allocator)
	if !db_found {
		return {}, false
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
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty}}
	} else {
		// Not in cache at all — mark as Dirty+Fresh
		cc.cache[outpoint] = Cache_Entry{coin = cached_coin, flags = {.Dirty, .Fresh}}
	}
}

// Flush dirty entries to DB. Deletes spent sentinels from DB.
coins_cache_flush :: proc(cc: ^Coins_Cache) -> Chain_Error {
	for outpoint, entry in cc.cache {
		if .Dirty not_in entry.flags {
			continue
		}

		if _is_spent_sentinel_val(entry) {
			// Delete from DB
			serr := storage.utxo_db_delete(cc.db, outpoint)
			if serr != .None {
				return .Storage_Error
			}
		} else {
			// Write to DB
			serr := storage.utxo_db_put(cc.db, outpoint, entry.coin)
			if serr != .None {
				return .Storage_Error
			}
		}
	}

	// Flush DB to disk
	serr := storage.utxo_db_flush(cc.db)
	if serr != .None {
		return .Storage_Error
	}

	// Clear spent sentinels, mark remaining as clean
	to_remove := make([dynamic]wire.Outpoint, 0, len(cc.cache), context.temp_allocator)
	for outpoint, entry in cc.cache {
		if _is_spent_sentinel_val(entry) {
			append(&to_remove, outpoint)
		}
	}
	for op in to_remove {
		// Free script memory if any
		entry := cc.cache[op]
		if len(entry.coin.script) > 0 {
			delete(entry.coin.script, cc.allocator)
		}
		delete_key(&cc.cache, op)
	}

	// Clear dirty/fresh flags on remaining entries
	for outpoint in cc.cache {
		entry := &cc.cache[outpoint]
		entry.flags = {}
	}

	return .None
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
