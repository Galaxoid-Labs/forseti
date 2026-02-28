package storage

import "core:c"

foreign import lmdb_lib "../deps/lib/liblmdb.a"

// Opaque handle types
MDB_env    :: distinct rawptr
MDB_txn    :: distinct rawptr
MDB_cursor :: distinct rawptr
MDB_dbi    :: c.uint

MDB_val :: struct {
	mv_size: c.size_t,
	mv_data: rawptr,
}

MDB_stat :: struct {
	ms_psize:          c.uint,
	ms_depth:          c.uint,
	ms_branch_pages:   c.size_t,
	ms_leaf_pages:     c.size_t,
	ms_overflow_pages: c.size_t,
	ms_entries:        c.size_t,
}

// Environment flags
MDB_NOSUBDIR :: 0x4000
MDB_RDONLY   :: 0x20000
MDB_NOSYNC   :: 0x10000
MDB_CREATE   :: 0x40000
MDB_NOTLS    :: 0x200000

// Cursor operations
MDB_FIRST :: 0
MDB_NEXT  :: 8

// Return codes
MDB_SUCCESS  :: 0
MDB_NOTFOUND :: -30798

@(default_calling_convention = "c")
foreign lmdb_lib {
	mdb_env_create      :: proc(env: ^MDB_env) -> c.int ---
	mdb_env_open        :: proc(env: MDB_env, path: cstring, flags: c.uint, mode: c.uint) -> c.int ---
	mdb_env_close       :: proc(env: MDB_env) ---
	mdb_env_set_mapsize :: proc(env: MDB_env, size: c.size_t) -> c.int ---
	mdb_env_set_maxdbs  :: proc(env: MDB_env, dbs: MDB_dbi) -> c.int ---
	mdb_env_sync        :: proc(env: MDB_env, force: c.int) -> c.int ---
	mdb_strerror        :: proc(err: c.int) -> cstring ---
	mdb_txn_begin       :: proc(env: MDB_env, parent: MDB_txn, flags: c.uint, txn: ^MDB_txn) -> c.int ---
	mdb_txn_commit      :: proc(txn: MDB_txn) -> c.int ---
	mdb_txn_abort       :: proc(txn: MDB_txn) ---
	mdb_dbi_open        :: proc(txn: MDB_txn, name: cstring, flags: c.uint, dbi: ^MDB_dbi) -> c.int ---
	mdb_get             :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val) -> c.int ---
	mdb_put             :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val, flags: c.uint) -> c.int ---
	mdb_del             :: proc(txn: MDB_txn, dbi: MDB_dbi, key: ^MDB_val, data: ^MDB_val) -> c.int ---
	mdb_cursor_open     :: proc(txn: MDB_txn, dbi: MDB_dbi, cursor: ^MDB_cursor) -> c.int ---
	mdb_cursor_close    :: proc(cursor: MDB_cursor) ---
	mdb_cursor_get      :: proc(cursor: MDB_cursor, key: ^MDB_val, data: ^MDB_val, op: c.uint) -> c.int ---
	mdb_stat            :: proc(txn: MDB_txn, dbi: MDB_dbi, stat: ^MDB_stat) -> c.int ---
}
