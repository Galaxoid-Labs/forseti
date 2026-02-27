package storage

import "../wire"

UTXO_Coin :: struct {
	height:      u32,
	is_coinbase: bool,
	amount:      i64,
	script:      []byte,
}

UTXO_DB :: struct {
	store: KV_Store,
}

// Open a UTXO database backed by an mmap'd KV store.
utxo_db_open :: proc(data_dir: string) -> (db: UTXO_DB, err: Storage_Error) {
	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/utxo.dat")
	path := string(path_buf[:path_len])

	db.store, err = kv_open(path)
	return db, err
}

// Close the UTXO database.
utxo_db_close :: proc(db: ^UTXO_DB) -> Storage_Error {
	return kv_close(&db.store)
}

// Retrieve a UTXO coin. Caller owns the returned script slice.
utxo_db_get :: proc(db: ^UTXO_DB, outpoint: wire.Outpoint, allocator := context.allocator) -> (coin: UTXO_Coin, found: bool) {
	key := _utxo_key(outpoint)
	value, ok := kv_get(&db.store, key[:])
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
	value_buf: [KV_MAX_VALUE_SIZE]byte
	value_len := _utxo_encode_value(&value_buf, coin)
	if value_len < 0 {
		return .Value_Too_Large
	}
	return kv_put(&db.store, key[:], value_buf[:value_len])
}

// Delete a UTXO.
utxo_db_delete :: proc(db: ^UTXO_DB, outpoint: wire.Outpoint) -> Storage_Error {
	key := _utxo_key(outpoint)
	return kv_delete(&db.store, key[:])
}

// Flush the UTXO database to disk.
utxo_db_flush :: proc(db: ^UTXO_DB) -> Storage_Error {
	return kv_flush(&db.store)
}

// Return the number of UTXOs stored.
utxo_db_count :: proc(db: ^UTXO_DB) -> u32 {
	return db.store.entry_count
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
_utxo_encode_value :: proc(buf: ^[KV_MAX_VALUE_SIZE]byte, coin: UTXO_Coin) -> int {
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
	if off + cs_size + len(coin.script) > KV_MAX_VALUE_SIZE {
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
