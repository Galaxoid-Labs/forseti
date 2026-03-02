package storage

import "core:c"
import "core:log"
import "core:os"

LDB_Store :: struct {
	chainstate_db:      LDB,              // UTXOs + meta tip
	index_db:           LDB,              // block index records
	index_cache:        LDB_Cache,        // LRU cache for index DB
	coins_db_cache:     LDB_Cache,        // LRU cache for chainstate DB
	bloom:              LDB_FilterPolicy,
	read_opts:          LDB_ReadOptions,
	write_opts:         LDB_WriteOptions,  // non-sync (normal writes)
	sync_opts:          LDB_WriteOptions,  // sync (flush/critical)
	coins_cache_budget: int,               // bytes available for in-memory coins cache
}

ldb_open :: proc(data_dir: string, db_cache_mb: int = 450) -> (store: LDB_Store, err: Storage_Error) {
	// Split cache budget following Bitcoin Core's algorithm (src/kernel/caches.h):
	//   1. Block index DB cache = min(total / 8, 2 MiB)
	//   2. Chainstate DB cache  = min(remaining / 2, 8 MiB)
	//   3. Coins cache (in-memory) = everything else
	total_bytes := db_cache_mb * 1024 * 1024
	index_cache_bytes := min(total_bytes / 8, 2 * 1024 * 1024)
	remaining := total_bytes - index_cache_bytes
	coins_db_cache_bytes := min(remaining / 2, 8 * 1024 * 1024)
	store.coins_cache_budget = total_bytes - index_cache_bytes - coins_db_cache_bytes

	log.infof("DB cache budget: total=%d MiB, index_db=%d KiB, chainstate_db=%d KiB, coins_cache=%d MiB",
		db_cache_mb,
		index_cache_bytes / 1024,
		coins_db_cache_bytes / 1024,
		store.coins_cache_budget / (1024 * 1024))

	// 10-bit bloom filter (shared across both DBs)
	store.bloom = leveldb_filterpolicy_create_bloom(10)

	// Read/write options
	store.read_opts = leveldb_readoptions_create()
	store.write_opts = leveldb_writeoptions_create()
	store.sync_opts = leveldb_writeoptions_create()
	leveldb_writeoptions_set_sync(store.sync_opts, 1)

	// --- Open chainstate DB: <datadir>/chainstate/ ---
	cs_opts := leveldb_options_create()
	leveldb_options_set_create_if_missing(cs_opts, 1)
	leveldb_options_set_compression(cs_opts, 0)
	leveldb_options_set_write_buffer_size(cs_opts, 2 * 1024 * 1024) // 2 MB (Core default)
	store.coins_db_cache = leveldb_cache_create_lru(c.size_t(coins_db_cache_bytes))
	leveldb_options_set_cache(cs_opts, store.coins_db_cache)
	leveldb_options_set_filter_policy(cs_opts, store.bloom)

	cs_path_buf: [512]byte
	cs_path_len := _bprint_path(cs_path_buf[:], data_dir, "/chainstate")
	cs_path_buf[cs_path_len] = 0
	os.make_directory(string(cs_path_buf[:cs_path_len]))

	errptr: cstring = nil
	store.chainstate_db = leveldb_open(cs_opts, cstring(&cs_path_buf[0]), &errptr)
	if store.chainstate_db == nil {
		log.errorf("Failed to open chainstate LevelDB: %s", errptr)
		if errptr != nil { leveldb_free(rawptr(errptr)) }
		leveldb_options_destroy(cs_opts)
		_ldb_cleanup_options(&store, nil)
		return store, .IO_Error
	}
	leveldb_options_destroy(cs_opts)

	// --- Open block index DB: <datadir>/blocks/index/ ---
	idx_opts := leveldb_options_create()
	leveldb_options_set_create_if_missing(idx_opts, 1)
	leveldb_options_set_compression(idx_opts, 0)
	leveldb_options_set_write_buffer_size(idx_opts, 2 * 1024 * 1024) // 2 MB (Core default)
	store.index_cache = leveldb_cache_create_lru(c.size_t(index_cache_bytes))
	leveldb_options_set_cache(idx_opts, store.index_cache)
	leveldb_options_set_filter_policy(idx_opts, store.bloom)

	idx_dir_buf: [512]byte
	idx_dir_len := _bprint_path(idx_dir_buf[:], data_dir, "/blocks")
	os.make_directory(string(idx_dir_buf[:idx_dir_len]))

	idx_path_buf: [512]byte
	idx_path_len := _bprint_path(idx_path_buf[:], data_dir, "/blocks/index")
	idx_path_buf[idx_path_len] = 0
	os.make_directory(string(idx_path_buf[:idx_path_len]))

	errptr = nil
	store.index_db = leveldb_open(idx_opts, cstring(&idx_path_buf[0]), &errptr)
	if store.index_db == nil {
		log.errorf("Failed to open index LevelDB: %s", errptr)
		if errptr != nil { leveldb_free(rawptr(errptr)) }
		leveldb_close(store.chainstate_db)
		leveldb_options_destroy(idx_opts)
		_ldb_cleanup_options(&store, nil)
		return store, .IO_Error
	}
	leveldb_options_destroy(idx_opts)

	return store, .None
}

ldb_close :: proc(store: ^LDB_Store) {
	if store.index_db != nil {
		leveldb_close(store.index_db)
		store.index_db = nil
	}
	if store.chainstate_db != nil {
		leveldb_close(store.chainstate_db)
		store.chainstate_db = nil
	}
	if store.read_opts != nil {
		leveldb_readoptions_destroy(store.read_opts)
		store.read_opts = nil
	}
	if store.write_opts != nil {
		leveldb_writeoptions_destroy(store.write_opts)
		store.write_opts = nil
	}
	if store.sync_opts != nil {
		leveldb_writeoptions_destroy(store.sync_opts)
		store.sync_opts = nil
	}
	if store.bloom != nil {
		leveldb_filterpolicy_destroy(store.bloom)
		store.bloom = nil
	}
	if store.index_cache != nil {
		leveldb_cache_destroy(store.index_cache)
		store.index_cache = nil
	}
	if store.coins_db_cache != nil {
		leveldb_cache_destroy(store.coins_db_cache)
		store.coins_db_cache = nil
	}
}

// Get a value by key. Returns a copy allocated with the given allocator.
// Caller owns the returned slice.
ldb_get :: proc(db: LDB, read_opts: LDB_ReadOptions, key: []byte, allocator := context.allocator) -> ([]byte, bool) {
	vlen: c.size_t
	errptr: cstring = nil
	result := leveldb_get(db, read_opts, raw_data(key), c.size_t(len(key)), &vlen, &errptr)
	if errptr != nil {
		leveldb_free(rawptr(errptr))
		return nil, false
	}
	if result == nil {
		return nil, false
	}
	defer leveldb_free(rawptr(result))

	// Copy to caller's allocator
	data := make([]byte, int(vlen), allocator)
	for i in 0 ..< int(vlen) {
		data[i] = result[i]
	}
	return data, true
}

// Put a single key-value pair.
ldb_put :: proc(db: LDB, write_opts: LDB_WriteOptions, key: []byte, value: []byte) -> Storage_Error {
	errptr: cstring = nil
	leveldb_put(db, write_opts, raw_data(key), c.size_t(len(key)), raw_data(value), c.size_t(len(value)), &errptr)
	if errptr != nil {
		log.errorf("ldb_put failed: %s", errptr)
		leveldb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

// Delete a single key.
ldb_del :: proc(db: LDB, write_opts: LDB_WriteOptions, key: []byte) -> Storage_Error {
	errptr: cstring = nil
	leveldb_delete(db, write_opts, raw_data(key), c.size_t(len(key)), &errptr)
	if errptr != nil {
		log.errorf("ldb_del failed: %s", errptr)
		leveldb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

// Create a new WriteBatch for atomic multi-key writes.
ldb_batch_create :: proc() -> LDB_WriteBatch {
	return leveldb_writebatch_create()
}

// Add a put operation to a batch.
ldb_batch_put :: proc(batch: LDB_WriteBatch, key: []byte, value: []byte) {
	leveldb_writebatch_put(batch, raw_data(key), c.size_t(len(key)), raw_data(value), c.size_t(len(value)))
}

// Add a delete operation to a batch.
ldb_batch_delete :: proc(batch: LDB_WriteBatch, key: []byte) {
	leveldb_writebatch_delete(batch, raw_data(key), c.size_t(len(key)))
}

// Atomically commit a batch.
ldb_batch_write :: proc(db: LDB, write_opts: LDB_WriteOptions, batch: LDB_WriteBatch) -> Storage_Error {
	errptr: cstring = nil
	leveldb_write(db, write_opts, batch, &errptr)
	if errptr != nil {
		log.errorf("ldb_batch_write failed: %s", errptr)
		leveldb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

// Destroy a batch (also serves as "abort" — discard without writing).
ldb_batch_destroy :: proc(batch: LDB_WriteBatch) {
	if batch != nil {
		leveldb_writebatch_destroy(batch)
	}
}

// Helper to clean up options on open failure.
_ldb_cleanup_options :: proc(store: ^LDB_Store, opts: LDB_Options) {
	if opts != nil {
		leveldb_options_destroy(opts)
	}
	if store.read_opts != nil {
		leveldb_readoptions_destroy(store.read_opts)
		store.read_opts = nil
	}
	if store.write_opts != nil {
		leveldb_writeoptions_destroy(store.write_opts)
		store.write_opts = nil
	}
	if store.sync_opts != nil {
		leveldb_writeoptions_destroy(store.sync_opts)
		store.sync_opts = nil
	}
	if store.bloom != nil {
		leveldb_filterpolicy_destroy(store.bloom)
		store.bloom = nil
	}
	if store.index_cache != nil {
		leveldb_cache_destroy(store.index_cache)
		store.index_cache = nil
	}
	if store.coins_db_cache != nil {
		leveldb_cache_destroy(store.coins_db_cache)
		store.coins_db_cache = nil
	}
}
