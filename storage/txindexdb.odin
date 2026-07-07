package storage

import "core:c"
import "core:log"
import "core:os"

// Standalone LevelDB for the transaction index (--txindex).
// Located at <datadir>/txindex/. Incompatible with pruning (Core parity) —
// lookups read the tx's block from the flat files.
//
// Keys:  txid[32]            → block_hash[32] || tx_index[4 LE]
//        "best"              → block_hash[32] || height[4 LE] (last indexed)

Tx_Index_DB :: struct {
	db:         LDB,
	cache:      LDB_Cache,
	bloom:      LDB_FilterPolicy,
	read_opts:  LDB_ReadOptions,
	write_opts: LDB_WriteOptions,
}

Tx_Location :: struct {
	block_hash: Hash256,
	tx_index:   u32,
}

tx_index_db_open :: proc(data_dir: string) -> (tdb: Tx_Index_DB, err: Storage_Error) {
	tdb.bloom = leveldb_filterpolicy_create_bloom(10)
	tdb.read_opts = leveldb_readoptions_create()
	tdb.write_opts = leveldb_writeoptions_create()

	opts := leveldb_options_create()
	leveldb_options_set_create_if_missing(opts, 1)
	leveldb_options_set_compression(opts, 0)
	leveldb_options_set_write_buffer_size(opts, 4 * 1024 * 1024)
	tdb.cache = leveldb_cache_create_lru(4 * 1024 * 1024)
	leveldb_options_set_cache(opts, tdb.cache)
	leveldb_options_set_filter_policy(opts, tdb.bloom)

	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/txindex")
	path_buf[path_len] = 0
	os.make_directory(string(path_buf[:path_len]))

	errptr: cstring = nil
	tdb.db = leveldb_open(opts, cstring(&path_buf[0]), &errptr)
	if tdb.db == nil {
		log.errorf("Failed to open txindex LevelDB: %s", errptr)
		if errptr != nil { leveldb_free(rawptr(errptr)) }
		leveldb_options_destroy(opts)
		_tx_index_db_cleanup(&tdb)
		return tdb, .IO_Error
	}
	leveldb_options_destroy(opts)

	log.infof("Tx index DB opened at %s", string(path_buf[:path_len]))
	return tdb, .None
}

_tx_index_db_cleanup :: proc(tdb: ^Tx_Index_DB) {
	if tdb.read_opts != nil { leveldb_readoptions_destroy(tdb.read_opts) }
	if tdb.write_opts != nil { leveldb_writeoptions_destroy(tdb.write_opts) }
	if tdb.cache != nil { leveldb_cache_destroy(tdb.cache) }
	if tdb.bloom != nil { leveldb_filterpolicy_destroy(tdb.bloom) }
}

tx_index_db_close :: proc(tdb: ^Tx_Index_DB) {
	if tdb.db != nil {
		leveldb_close(tdb.db)
		tdb.db = nil
	}
	_tx_index_db_cleanup(tdb)
}

// Index every tx of a block + advance the best marker, one atomic batch.
tx_index_put_block :: proc(tdb: ^Tx_Index_DB, block_hash: Hash256, height: int, txids: []Hash256) -> Storage_Error {
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	val: [36]byte
	bh := block_hash
	copy(val[:32], bh[:])
	for txid, i in txids {
		id := txid
		val[32] = byte(i)
		val[33] = byte(i >> 8)
		val[34] = byte(i >> 16)
		val[35] = byte(i >> 24)
		ldb_batch_put(batch, id[:], val[:])
	}

	best: [36]byte
	copy(best[:32], bh[:])
	h := u32(height)
	best[32] = byte(h); best[33] = byte(h >> 8); best[34] = byte(h >> 16); best[35] = byte(h >> 24)
	ldb_batch_put(batch, transmute([]byte)string("best"), best[:])

	return ldb_batch_write(tdb.db, tdb.write_opts, batch)
}

// Unwind a disconnected block: drop its txids, move best to the parent.
tx_index_remove_block :: proc(tdb: ^Tx_Index_DB, parent_hash: Hash256, parent_height: int, txids: []Hash256) -> Storage_Error {
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	for txid in txids {
		id := txid
		ldb_batch_delete(batch, id[:])
	}

	best: [36]byte
	ph := parent_hash
	copy(best[:32], ph[:])
	h := u32(parent_height)
	best[32] = byte(h); best[33] = byte(h >> 8); best[34] = byte(h >> 16); best[35] = byte(h >> 24)
	ldb_batch_put(batch, transmute([]byte)string("best"), best[:])

	return ldb_batch_write(tdb.db, tdb.write_opts, batch)
}

tx_index_get :: proc(tdb: ^Tx_Index_DB, txid: Hash256) -> (loc: Tx_Location, found: bool) {
	id := txid
	val, ok := ldb_get(tdb.db, tdb.read_opts, id[:], context.temp_allocator)
	if !ok || len(val) != 36 {
		return {}, false
	}
	copy(loc.block_hash[:], val[:32])
	loc.tx_index = u32(val[32]) | u32(val[33]) << 8 | u32(val[34]) << 16 | u32(val[35]) << 24
	return loc, true
}

// Last indexed block, or found=false for a fresh index.
tx_index_best :: proc(tdb: ^Tx_Index_DB) -> (hash: Hash256, height: int, found: bool) {
	val, ok := ldb_get(tdb.db, tdb.read_opts, transmute([]byte)string("best"), context.temp_allocator)
	if !ok || len(val) != 36 {
		return {}, -1, false
	}
	copy(hash[:], val[:32])
	height = int(u32(val[32]) | u32(val[33]) << 8 | u32(val[34]) << 16 | u32(val[35]) << 24)
	return hash, height, true
}

_ :: c
