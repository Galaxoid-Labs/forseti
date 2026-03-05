package storage

import "core:c"
import "core:log"
import "core:os"

// Standalone LevelDB for BIP 158 compact block filter storage.
// Independent from LDB_Store (own handle, cache, options).
// Located at <datadir>/blocks/filter/.

Filter_DB :: struct {
	db:         LDB,
	cache:      LDB_Cache,
	bloom:      LDB_FilterPolicy,
	read_opts:  LDB_ReadOptions,
	write_opts: LDB_WriteOptions,
}

// Key prefixes for filter DB.
_FILTER_KEY_PREFIX :: 'f'  // 'f' || block_hash[32] → filter_bytes
_HEADER_KEY_PREFIX :: 'h'  // 'h' || block_hash[32] → filter_header[32]

filter_db_open :: proc(data_dir: string) -> (fdb: Filter_DB, err: Storage_Error) {
	fdb.bloom = leveldb_filterpolicy_create_bloom(10)
	fdb.read_opts = leveldb_readoptions_create()
	fdb.write_opts = leveldb_writeoptions_create()

	opts := leveldb_options_create()
	leveldb_options_set_create_if_missing(opts, 1)
	leveldb_options_set_compression(opts, 0)
	leveldb_options_set_write_buffer_size(opts, 2 * 1024 * 1024) // 2 MB
	fdb.cache = leveldb_cache_create_lru(2 * 1024 * 1024) // 2 MB LRU
	leveldb_options_set_cache(opts, fdb.cache)
	leveldb_options_set_filter_policy(opts, fdb.bloom)

	// Ensure parent directories exist.
	blocks_buf: [512]byte
	blocks_len := _bprint_path(blocks_buf[:], data_dir, "/blocks")
	os.make_directory(string(blocks_buf[:blocks_len]))

	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/blocks/filter")
	path_buf[path_len] = 0
	os.make_directory(string(path_buf[:path_len]))

	errptr: cstring = nil
	fdb.db = leveldb_open(opts, cstring(&path_buf[0]), &errptr)
	if fdb.db == nil {
		log.errorf("Failed to open filter LevelDB: %s", errptr)
		if errptr != nil { leveldb_free(rawptr(errptr)) }
		leveldb_options_destroy(opts)
		_filter_db_cleanup(&fdb)
		return fdb, .IO_Error
	}
	leveldb_options_destroy(opts)

	log.infof("Filter DB opened at %s", string(path_buf[:path_len]))
	return fdb, .None
}

filter_db_close :: proc(fdb: ^Filter_DB) {
	if fdb.db != nil {
		leveldb_close(fdb.db)
		fdb.db = nil
	}
	_filter_db_cleanup(fdb)
}

// Store a filter and its header atomically.
filter_db_put :: proc(fdb: ^Filter_DB, block_hash: [32]byte, filter: []byte, header: [32]byte) -> Storage_Error {
	block_hash := block_hash
	batch := leveldb_writebatch_create()
	defer leveldb_writebatch_destroy(batch)

	// Filter: 'f' || block_hash → filter_bytes
	fkey: [33]byte
	fkey[0] = _FILTER_KEY_PREFIX
	copy(fkey[1:], block_hash[:])
	leveldb_writebatch_put(batch, raw_data(fkey[:]), c.size_t(33), raw_data(filter), c.size_t(len(filter)))

	// Header: 'h' || block_hash → filter_header
	hkey: [33]byte
	hkey[0] = _HEADER_KEY_PREFIX
	copy(hkey[1:], block_hash[:])
	header := header
	leveldb_writebatch_put(batch, raw_data(hkey[:]), c.size_t(33), raw_data(header[:]), c.size_t(32))

	errptr: cstring = nil
	leveldb_write(fdb.db, fdb.write_opts, batch, &errptr)
	if errptr != nil {
		log.errorf("filter_db_put failed: %s", errptr)
		leveldb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

// Get the filter bytes for a block.
filter_db_get_filter :: proc(fdb: ^Filter_DB, block_hash: [32]byte, allocator := context.allocator) -> ([]byte, bool) {
	block_hash := block_hash
	fkey: [33]byte
	fkey[0] = _FILTER_KEY_PREFIX
	copy(fkey[1:], block_hash[:])
	return ldb_get(fdb.db, fdb.read_opts, fkey[:], allocator)
}

// Get the filter header for a block.
filter_db_get_header :: proc(fdb: ^Filter_DB, block_hash: [32]byte) -> ([32]byte, bool) {
	block_hash := block_hash
	hkey: [33]byte
	hkey[0] = _HEADER_KEY_PREFIX
	copy(hkey[1:], block_hash[:])

	data, found := ldb_get(fdb.db, fdb.read_opts, hkey[:], context.temp_allocator)
	if !found || len(data) != 32 {
		return {}, false
	}
	result: [32]byte
	copy(result[:], data)
	return result, true
}

// Delete a filter and header for a block (used on disconnect).
filter_db_delete :: proc(fdb: ^Filter_DB, block_hash: [32]byte) -> Storage_Error {
	block_hash := block_hash
	batch := leveldb_writebatch_create()
	defer leveldb_writebatch_destroy(batch)

	fkey: [33]byte
	fkey[0] = _FILTER_KEY_PREFIX
	copy(fkey[1:], block_hash[:])
	leveldb_writebatch_delete(batch, raw_data(fkey[:]), c.size_t(33))

	hkey: [33]byte
	hkey[0] = _HEADER_KEY_PREFIX
	copy(hkey[1:], block_hash[:])
	leveldb_writebatch_delete(batch, raw_data(hkey[:]), c.size_t(33))

	errptr: cstring = nil
	leveldb_write(fdb.db, fdb.write_opts, batch, &errptr)
	if errptr != nil {
		log.errorf("filter_db_delete failed: %s", errptr)
		leveldb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

@(private)
_filter_db_cleanup :: proc(fdb: ^Filter_DB) {
	if fdb.read_opts != nil {
		leveldb_readoptions_destroy(fdb.read_opts)
		fdb.read_opts = nil
	}
	if fdb.write_opts != nil {
		leveldb_writeoptions_destroy(fdb.write_opts)
		fdb.write_opts = nil
	}
	if fdb.bloom != nil {
		leveldb_filterpolicy_destroy(fdb.bloom)
		fdb.bloom = nil
	}
	if fdb.cache != nil {
		leveldb_cache_destroy(fdb.cache)
		fdb.cache = nil
	}
}
