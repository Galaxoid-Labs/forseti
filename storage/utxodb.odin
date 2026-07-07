package storage

import "core:c"
import "../wire"

UTXO_Coin :: struct {
	height:      u32,
	is_coinbase: bool,
	amount:      i64,
	script:      []byte,
}

UTXO_DB :: struct {
	store: ^LDB_Store,
}

// Initialize UTXO database backed by shared LevelDB store.
utxo_db_init :: proc(store: ^LDB_Store) -> UTXO_DB {
	return UTXO_DB{store = store}
}

// No-op — store is closed centrally.
utxo_db_close :: proc(db: ^UTXO_DB) {
}

// Retrieve a UTXO coin. Caller owns the returned script slice.
utxo_db_get :: proc(db: ^UTXO_DB, outpoint: wire.Outpoint, allocator := context.allocator) -> (coin: UTXO_Coin, found: bool) {
	key := _utxo_key(outpoint)
	value, ok := ldb_get(db.store.chainstate_db, db.store.read_opts, key[:], context.temp_allocator)
	if !ok {
		return {}, false
	}

	decoded, decode_ok := _utxo_decode_value(value, allocator)
	if !decode_ok {
		return {}, false
	}

	return decoded, true
}

// Store a UTXO coin.
utxo_db_put :: proc(db: ^UTXO_DB, outpoint: wire.Outpoint, coin: UTXO_Coin) -> Storage_Error {
	key := _utxo_key(outpoint)
	total_size := 13 + 5 + len(coin.script)
	value_buf: [10240]byte
	if total_size <= 10240 {
		value_len := _utxo_encode_value_into(value_buf[:], coin)
		return ldb_put(db.store.chainstate_db, db.store.write_opts, key[:], value_buf[:value_len])
	} else {
		heap_buf := make([]byte, total_size, context.temp_allocator)
		value_len := _utxo_encode_value_into(heap_buf, coin)
		return ldb_put(db.store.chainstate_db, db.store.write_opts, key[:], heap_buf[:value_len])
	}
}

// Delete a UTXO.
utxo_db_delete :: proc(db: ^UTXO_DB, outpoint: wire.Outpoint) -> Storage_Error {
	key := _utxo_key(outpoint)
	return ldb_del(db.store.chainstate_db, db.store.write_opts, key[:])
}

// No-op — sync handled by write options.
utxo_db_flush :: proc(db: ^UTXO_DB) -> Storage_Error {
	return .None
}

// Return the number of UTXOs stored (iterator scan).
utxo_db_count :: proc(db: ^UTXO_DB) -> u32 {
	iter := leveldb_create_iterator(db.store.chainstate_db, db.store.read_opts)
	defer leveldb_iter_destroy(iter)

	count: u32 = 0
	leveldb_iter_seek_to_first(iter)
	for leveldb_iter_valid(iter) != 0 {
		// Skip the "tip" meta key — only count UTXO entries (36-byte keys)
		klen: c.size_t
		_ = leveldb_iter_key(iter, &klen)
		if klen == 36 {
			count += 1
		}
		leveldb_iter_next(iter)
	}
	return count
}

// Scan all UTXOs to compute aggregate stats: count and total amount (satoshis).
// Warning: slow on large UTXO sets (millions of entries).
utxo_db_scan_stats :: proc(db: ^UTXO_DB) -> (count: u32, total_amount: i64) {
	iter := leveldb_create_iterator(db.store.chainstate_db, db.store.read_opts)
	defer leveldb_iter_destroy(iter)

	count = 0
	total_amount = 0
	leveldb_iter_seek_to_first(iter)
	for leveldb_iter_valid(iter) != 0 {
		klen: c.size_t
		_ = leveldb_iter_key(iter, &klen)
		if klen == 36 {
			// Decode value to extract amount
			vlen: c.size_t
			vptr := leveldb_iter_value(iter, &vlen)
			if vptr != nil && vlen >= 13 {
				val := ([^]byte)(vptr)[:vlen]
				// amount is at offset 5 (after 4-byte height + 1-byte is_coinbase), 8 bytes LE
				amt := u64(val[5]) | u64(val[6]) << 8 | u64(val[7]) << 16 | u64(val[8]) << 24 |
				       u64(val[9]) << 32 | u64(val[10]) << 40 | u64(val[11]) << 48 | u64(val[12]) << 56
				total_amount += transmute(i64)amt
			}
			count += 1
		}
		leveldb_iter_next(iter)
	}
	return
}

// Add a put to a WriteBatch (for coins_cache_flush).
utxo_db_batch_put :: proc(db: ^UTXO_DB, batch: LDB_WriteBatch, outpoint: wire.Outpoint, coin: UTXO_Coin) {
	key := _utxo_key(outpoint)
	total_size := 13 + 5 + len(coin.script)
	value_buf: [10240]byte
	if total_size <= 10240 {
		value_len := _utxo_encode_value_into(value_buf[:], coin)
		ldb_batch_put(batch, key[:], value_buf[:value_len])
	} else {
		heap_buf := make([]byte, total_size, context.temp_allocator)
		value_len := _utxo_encode_value_into(heap_buf, coin)
		ldb_batch_put(batch, key[:], heap_buf[:value_len])
	}
}

// Add a delete to a WriteBatch (for coins_cache_flush).
utxo_db_batch_delete :: proc(db: ^UTXO_DB, batch: LDB_WriteBatch, outpoint: wire.Outpoint) {
	key := _utxo_key(outpoint)
	ldb_batch_delete(batch, key[:])
}

// --- Key/Value encoding ---

// Key: txid[32] || vout[4 LE] = 36 bytes
_utxo_key :: proc(outpoint: wire.Outpoint) -> [36]byte {
	key: [36]byte
	h := outpoint.hash
	for i in 0 ..< 32 {
		key[i] = h[i]
	}
	key[32] = byte(outpoint.index)
	key[33] = byte(outpoint.index >> 8)
	key[34] = byte(outpoint.index >> 16)
	key[35] = byte(outpoint.index >> 24)
	return key
}

// Value: height[4 LE] || is_coinbase[1] || amount[8 LE] || script_len[CompactSize] || script[...]
_utxo_encode_value_into :: proc(buf: []byte, coin: UTXO_Coin) -> int {
	off := 0

	// height (4 LE)
	buf[off] = byte(coin.height); off += 1
	buf[off] = byte(coin.height >> 8); off += 1
	buf[off] = byte(coin.height >> 16); off += 1
	buf[off] = byte(coin.height >> 24); off += 1

	// is_coinbase (1)
	buf[off] = coin.is_coinbase ? 1 : 0; off += 1

	// amount (8 LE)
	amt := transmute(u64)coin.amount
	buf[off] = byte(amt); off += 1
	buf[off] = byte(amt >> 8); off += 1
	buf[off] = byte(amt >> 16); off += 1
	buf[off] = byte(amt >> 24); off += 1
	buf[off] = byte(amt >> 32); off += 1
	buf[off] = byte(amt >> 40); off += 1
	buf[off] = byte(amt >> 48); off += 1
	buf[off] = byte(amt >> 56); off += 1

	// script_len (CompactSize) + script
	cs_buf, cs_size := wire.compact_size_encode(u64(len(coin.script)))
	if off + cs_size + len(coin.script) > len(buf) {
		return -1
	}
	for i in 0 ..< cs_size {
		buf[off] = cs_buf[i]; off += 1
	}
	for i in 0 ..< len(coin.script) {
		buf[off] = coin.script[i]; off += 1
	}

	return off
}

_utxo_decode_value :: proc(data: []byte, allocator := context.allocator) -> (coin: UTXO_Coin, ok: bool) {
	if len(data) < 13 { // 4 + 1 + 8 minimum
		return {}, false
	}

	off := 0

	// height (4 LE)
	coin.height = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// is_coinbase (1)
	coin.is_coinbase = data[off] != 0
	off += 1

	// amount (8 LE)
	amt := u64(data[off]) | u64(data[off + 1]) << 8 | u64(data[off + 2]) << 16 | u64(data[off + 3]) << 24 |
	       u64(data[off + 4]) << 32 | u64(data[off + 5]) << 40 | u64(data[off + 6]) << 48 | u64(data[off + 7]) << 56
	coin.amount = transmute(i64)amt
	off += 8

	// script_len (CompactSize)
	remaining := data[off:]
	script_len, cs_size, cs_err := wire.compact_size_decode(remaining)
	if cs_err != nil {
		return {}, false
	}
	off += cs_size

	if off + int(script_len) > len(data) {
		return {}, false
	}

	// Clone script
	coin.script = make([]byte, int(script_len), allocator)
	for i in 0 ..< int(script_len) {
		coin.script[i] = data[off + i]
	}

	return coin, true
}

// Public wrapper for decoding a raw UTXO DB value (used by scantxoutset's
// direct LevelDB iteration).
utxo_db_decode_value :: proc(data: []byte, allocator := context.allocator) -> (coin: UTXO_Coin, ok: bool) {
	return _utxo_decode_value(data, allocator)
}
