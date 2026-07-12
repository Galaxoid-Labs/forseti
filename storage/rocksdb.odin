package storage

import "core:c"
import "core:log"

// RocksDB C API bindings (rocksdb/c.h). Used ONLY by the address index
// (addrindexdb.odin) — chainstate/block-index/txindex/filters stay on LevelDB.
// RocksDB's multi-threaded compaction + universal compaction + compression fix
// LevelDB's single-compaction-thread write-stall on the large randomly-keyed
// scripthash index (see docs/plans/addrindex-rocksdb.md). The C API mirrors
// LevelDB's leveldb_* almost 1:1; the differences are the block-based table
// options (cache/filter live on a table-options object) and the extra tuning.
foreign import rocksdb_lib "../deps/lib/librocksdb.a"

RDB              :: distinct rawptr // rocksdb_t*
RDB_Options      :: distinct rawptr
RDB_ReadOptions  :: distinct rawptr
RDB_WriteOptions :: distinct rawptr
RDB_WriteBatch   :: distinct rawptr
RDB_Iterator     :: distinct rawptr
RDB_Cache        :: distinct rawptr
RDB_FilterPolicy :: distinct rawptr
RDB_BBTOptions   :: distinct rawptr // block-based table options

// rocksdb_options_set_compression values
RDB_NO_COMPRESSION   :: c.int(0)
RDB_SNAPPY           :: c.int(1)
RDB_LZ4              :: c.int(4)
RDB_ZSTD             :: c.int(7)
// rocksdb_options_set_compaction_style values
RDB_LEVEL_COMPACTION     :: c.int(0)
RDB_UNIVERSAL_COMPACTION :: c.int(1)

@(default_calling_convention = "c")
foreign rocksdb_lib {
	// Lifecycle
	rocksdb_open  :: proc(opts: RDB_Options, name: cstring, errptr: ^cstring) -> RDB ---
	rocksdb_close :: proc(db: RDB) ---

	// Key-value
	rocksdb_put    :: proc(db: RDB, opts: RDB_WriteOptions, key: [^]byte, klen: c.size_t, val: [^]byte, vlen: c.size_t, errptr: ^cstring) ---
	rocksdb_get    :: proc(db: RDB, opts: RDB_ReadOptions, key: [^]byte, klen: c.size_t, vlen: ^c.size_t, errptr: ^cstring) -> [^]byte ---
	rocksdb_delete :: proc(db: RDB, opts: RDB_WriteOptions, key: [^]byte, klen: c.size_t, errptr: ^cstring) ---

	// WriteBatch
	rocksdb_writebatch_create  :: proc() -> RDB_WriteBatch ---
	rocksdb_writebatch_destroy :: proc(batch: RDB_WriteBatch) ---
	rocksdb_writebatch_clear   :: proc(batch: RDB_WriteBatch) ---
	rocksdb_writebatch_put     :: proc(batch: RDB_WriteBatch, key: [^]byte, klen: c.size_t, val: [^]byte, vlen: c.size_t) ---
	rocksdb_writebatch_delete  :: proc(batch: RDB_WriteBatch, key: [^]byte, klen: c.size_t) ---
	rocksdb_write              :: proc(db: RDB, opts: RDB_WriteOptions, batch: RDB_WriteBatch, errptr: ^cstring) ---

	// Iterator
	rocksdb_create_iterator    :: proc(db: RDB, opts: RDB_ReadOptions) -> RDB_Iterator ---
	rocksdb_iter_destroy       :: proc(iter: RDB_Iterator) ---
	rocksdb_iter_valid         :: proc(iter: RDB_Iterator) -> c.uchar ---
	rocksdb_iter_seek_to_first :: proc(iter: RDB_Iterator) ---
	rocksdb_iter_seek          :: proc(iter: RDB_Iterator, k: [^]byte, klen: c.size_t) ---
	rocksdb_iter_next          :: proc(iter: RDB_Iterator) ---
	rocksdb_iter_key           :: proc(iter: RDB_Iterator, klen: ^c.size_t) -> [^]byte ---
	rocksdb_iter_value         :: proc(iter: RDB_Iterator, vlen: ^c.size_t) -> [^]byte ---

	// Options
	rocksdb_options_create                  :: proc() -> RDB_Options ---
	rocksdb_options_destroy                 :: proc(opts: RDB_Options) ---
	rocksdb_options_set_create_if_missing   :: proc(opts: RDB_Options, v: c.uchar) ---
	rocksdb_options_set_compression             :: proc(opts: RDB_Options, v: c.int) ---
	rocksdb_options_set_bottommost_compression  :: proc(opts: RDB_Options, v: c.int) ---
	rocksdb_options_set_max_subcompactions      :: proc(opts: RDB_Options, n: c.uint32_t) ---
	rocksdb_options_set_compaction_style    :: proc(opts: RDB_Options, v: c.int) ---
	rocksdb_options_set_write_buffer_size   :: proc(opts: RDB_Options, size: c.size_t) ---
	rocksdb_options_set_max_write_buffer_number :: proc(opts: RDB_Options, n: c.int) ---
	rocksdb_options_set_max_open_files      :: proc(opts: RDB_Options, n: c.int) ---
	rocksdb_options_set_max_background_jobs  :: proc(opts: RDB_Options, n: c.int) ---
	rocksdb_options_set_target_file_size_base :: proc(opts: RDB_Options, n: u64) ---
	rocksdb_options_set_max_bytes_for_level_base :: proc(opts: RDB_Options, n: u64) ---
	rocksdb_options_set_level0_file_num_compaction_trigger :: proc(opts: RDB_Options, n: c.int) ---
	rocksdb_options_set_bytes_per_sync      :: proc(opts: RDB_Options, n: u64) ---
	rocksdb_options_increase_parallelism    :: proc(opts: RDB_Options, total_threads: c.int) ---
	rocksdb_options_set_block_based_table_factory :: proc(opts: RDB_Options, table_opts: RDB_BBTOptions) ---

	// Block-based table options (cache / filter / block size live here in RocksDB)
	rocksdb_block_based_options_create           :: proc() -> RDB_BBTOptions ---
	rocksdb_block_based_options_destroy          :: proc(o: RDB_BBTOptions) ---
	rocksdb_block_based_options_set_block_cache   :: proc(o: RDB_BBTOptions, cache: RDB_Cache) ---
	rocksdb_block_based_options_set_filter_policy :: proc(o: RDB_BBTOptions, fp: RDB_FilterPolicy) ---
	rocksdb_block_based_options_set_block_size    :: proc(o: RDB_BBTOptions, size: c.size_t) ---

	// Read/Write options
	rocksdb_readoptions_create    :: proc() -> RDB_ReadOptions ---
	rocksdb_readoptions_destroy   :: proc(opts: RDB_ReadOptions) ---
	rocksdb_writeoptions_create   :: proc() -> RDB_WriteOptions ---
	rocksdb_writeoptions_destroy  :: proc(opts: RDB_WriteOptions) ---
	rocksdb_writeoptions_set_sync :: proc(opts: RDB_WriteOptions, v: c.uchar) ---
	rocksdb_writeoptions_disable_WAL :: proc(opts: RDB_WriteOptions, disable: c.int) ---

	// Cache & Filter
	rocksdb_cache_create_lru          :: proc(capacity: c.size_t) -> RDB_Cache ---
	rocksdb_cache_destroy             :: proc(cache: RDB_Cache) ---
	rocksdb_filterpolicy_create_bloom_full :: proc(bits_per_key: f64) -> RDB_FilterPolicy ---

	// Memory
	rocksdb_free :: proc(ptr: rawptr) ---
}

// ---- thin wrappers (mirror the ldb_* helpers in leveldb_store.odin) ----

rdb_batch_write :: proc(db: RDB, write_opts: RDB_WriteOptions, batch: RDB_WriteBatch) -> Storage_Error {
	errptr: cstring = nil
	rocksdb_write(db, write_opts, batch, &errptr)
	if errptr != nil {
		log.errorf("rocksdb_write failed: %s", errptr)
		rocksdb_free(rawptr(errptr))
		return .IO_Error
	}
	return .None
}

rdb_batch_put :: proc(batch: RDB_WriteBatch, key: []byte, val: []byte) {
	rocksdb_writebatch_put(batch, raw_data(key), c.size_t(len(key)), raw_data(val), c.size_t(len(val)))
}

rdb_batch_delete :: proc(batch: RDB_WriteBatch, key: []byte) {
	rocksdb_writebatch_delete(batch, raw_data(key), c.size_t(len(key)))
}

rdb_get :: proc(db: RDB, read_opts: RDB_ReadOptions, key: []byte, allocator := context.allocator) -> ([]byte, bool) {
	vlen: c.size_t
	errptr: cstring = nil
	val := rocksdb_get(db, read_opts, raw_data(key), c.size_t(len(key)), &vlen, &errptr)
	if errptr != nil {
		rocksdb_free(rawptr(errptr))
		return nil, false
	}
	if val == nil {
		return nil, false
	}
	out := make([]byte, int(vlen), allocator)
	copy(out, val[:vlen])
	rocksdb_free(val)
	return out, true
}
