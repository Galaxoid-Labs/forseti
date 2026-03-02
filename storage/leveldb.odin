package storage

import "core:c"

foreign import leveldb_lib "../deps/lib/libleveldb.a"

// Opaque handle types
LDB              :: distinct rawptr // leveldb_t*
LDB_Options      :: distinct rawptr
LDB_ReadOptions  :: distinct rawptr
LDB_WriteOptions :: distinct rawptr
LDB_WriteBatch   :: distinct rawptr
LDB_Iterator     :: distinct rawptr
LDB_Cache        :: distinct rawptr
LDB_FilterPolicy :: distinct rawptr

@(default_calling_convention = "c")
foreign leveldb_lib {
	// Database lifecycle
	leveldb_open  :: proc(opts: LDB_Options, name: cstring, errptr: ^cstring) -> LDB ---
	leveldb_close :: proc(db: LDB) ---

	// Key-value operations
	leveldb_put    :: proc(db: LDB, opts: LDB_WriteOptions, key: [^]byte, klen: c.size_t, val: [^]byte, vlen: c.size_t, errptr: ^cstring) ---
	leveldb_get    :: proc(db: LDB, opts: LDB_ReadOptions, key: [^]byte, klen: c.size_t, vlen: ^c.size_t, errptr: ^cstring) -> [^]byte ---
	leveldb_delete :: proc(db: LDB, opts: LDB_WriteOptions, key: [^]byte, klen: c.size_t, errptr: ^cstring) ---

	// WriteBatch (atomic multi-key writes)
	leveldb_writebatch_create  :: proc() -> LDB_WriteBatch ---
	leveldb_writebatch_destroy :: proc(batch: LDB_WriteBatch) ---
	leveldb_writebatch_clear   :: proc(batch: LDB_WriteBatch) ---
	leveldb_writebatch_put     :: proc(batch: LDB_WriteBatch, key: [^]byte, klen: c.size_t, val: [^]byte, vlen: c.size_t) ---
	leveldb_writebatch_delete  :: proc(batch: LDB_WriteBatch, key: [^]byte, klen: c.size_t) ---
	leveldb_write              :: proc(db: LDB, opts: LDB_WriteOptions, batch: LDB_WriteBatch, errptr: ^cstring) ---

	// Iterator
	leveldb_create_iterator   :: proc(db: LDB, opts: LDB_ReadOptions) -> LDB_Iterator ---
	leveldb_iter_destroy      :: proc(iter: LDB_Iterator) ---
	leveldb_iter_valid        :: proc(iter: LDB_Iterator) -> c.uchar ---
	leveldb_iter_seek_to_first :: proc(iter: LDB_Iterator) ---
	leveldb_iter_next         :: proc(iter: LDB_Iterator) ---
	leveldb_iter_key          :: proc(iter: LDB_Iterator, klen: ^c.size_t) -> [^]byte ---
	leveldb_iter_value        :: proc(iter: LDB_Iterator, vlen: ^c.size_t) -> [^]byte ---

	// Options
	leveldb_options_create                :: proc() -> LDB_Options ---
	leveldb_options_destroy               :: proc(opts: LDB_Options) ---
	leveldb_options_set_create_if_missing :: proc(opts: LDB_Options, v: c.uchar) ---
	leveldb_options_set_cache             :: proc(opts: LDB_Options, cache: LDB_Cache) ---
	leveldb_options_set_filter_policy     :: proc(opts: LDB_Options, fp: LDB_FilterPolicy) ---
	leveldb_options_set_compression       :: proc(opts: LDB_Options, v: c.int) ---
	leveldb_options_set_write_buffer_size :: proc(opts: LDB_Options, size: c.size_t) ---
	leveldb_options_set_max_open_files    :: proc(opts: LDB_Options, n: c.int) ---
	leveldb_options_set_block_size        :: proc(opts: LDB_Options, size: c.size_t) ---

	// Read/Write options
	leveldb_readoptions_create   :: proc() -> LDB_ReadOptions ---
	leveldb_readoptions_destroy  :: proc(opts: LDB_ReadOptions) ---
	leveldb_writeoptions_create  :: proc() -> LDB_WriteOptions ---
	leveldb_writeoptions_destroy :: proc(opts: LDB_WriteOptions) ---
	leveldb_writeoptions_set_sync :: proc(opts: LDB_WriteOptions, v: c.uchar) ---

	// Cache & Filter
	leveldb_cache_create_lru         :: proc(capacity: c.size_t) -> LDB_Cache ---
	leveldb_cache_destroy            :: proc(cache: LDB_Cache) ---
	leveldb_filterpolicy_create_bloom :: proc(bits_per_key: c.int) -> LDB_FilterPolicy ---
	leveldb_filterpolicy_destroy     :: proc(fp: LDB_FilterPolicy) ---

	// Memory management
	leveldb_free :: proc(ptr: rawptr) ---
}
