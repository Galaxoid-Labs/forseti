package storage

import "core:c"
import "core:os"

LMDB_MAP_SIZE :: 10 * 1024 * 1024 * 1024 // 10 GB

LMDB_Store :: struct {
	env:       MDB_env,
	utxo_dbi:  MDB_dbi,
	index_dbi: MDB_dbi,
	meta_dbi:  MDB_dbi,
}

lmdb_open :: proc(data_dir: string) -> (store: LMDB_Store, err: Storage_Error) {
	// Build path: data_dir + "/chainstate"
	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/chainstate")
	path_buf[path_len] = 0 // null terminate for C
	path_cstr := cstring(&path_buf[0])

	// Ensure directory exists
	os.make_directory(string(path_buf[:path_len]))

	// Create environment
	rc := mdb_env_create(&store.env)
	if rc != MDB_SUCCESS {
		return store, .IO_Error
	}

	// Set map size (10 GB)
	rc = mdb_env_set_mapsize(store.env, LMDB_MAP_SIZE)
	if rc != MDB_SUCCESS {
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	// Allow 4 named databases
	rc = mdb_env_set_maxdbs(store.env, 4)
	if rc != MDB_SUCCESS {
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	// Open environment — MDB_NOTLS since Odin manages threads
	rc = mdb_env_open(store.env, path_cstr, MDB_NOTLS, 0o644)
	if rc != MDB_SUCCESS {
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	// Open named databases in a write transaction
	txn: MDB_txn
	rc = mdb_txn_begin(store.env, nil, 0, &txn)
	if rc != MDB_SUCCESS {
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	rc = mdb_dbi_open(txn, "utxo", MDB_CREATE, &store.utxo_dbi)
	if rc != MDB_SUCCESS {
		mdb_txn_abort(txn)
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	rc = mdb_dbi_open(txn, "index", MDB_CREATE, &store.index_dbi)
	if rc != MDB_SUCCESS {
		mdb_txn_abort(txn)
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	rc = mdb_dbi_open(txn, "meta", MDB_CREATE, &store.meta_dbi)
	if rc != MDB_SUCCESS {
		mdb_txn_abort(txn)
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	rc = mdb_txn_commit(txn)
	if rc != MDB_SUCCESS {
		mdb_env_close(store.env)
		return store, .IO_Error
	}

	return store, .None
}

lmdb_close :: proc(store: ^LMDB_Store) {
	if store.env != nil {
		mdb_env_sync(store.env, 1)
		mdb_env_close(store.env)
		store.env = nil
	}
}

// Begin a read-only transaction.
lmdb_begin_read :: proc(store: ^LMDB_Store) -> (MDB_txn, Storage_Error) {
	txn: MDB_txn
	rc := mdb_txn_begin(store.env, nil, MDB_RDONLY, &txn)
	if rc != MDB_SUCCESS {
		return nil, .IO_Error
	}
	return txn, .None
}

// Begin a read-write transaction.
lmdb_begin_write :: proc(store: ^LMDB_Store) -> (MDB_txn, Storage_Error) {
	txn: MDB_txn
	rc := mdb_txn_begin(store.env, nil, 0, &txn)
	if rc != MDB_SUCCESS {
		return nil, .IO_Error
	}
	return txn, .None
}

// Commit a transaction.
lmdb_commit :: proc(txn: MDB_txn) -> Storage_Error {
	rc := mdb_txn_commit(txn)
	if rc != MDB_SUCCESS {
		return .IO_Error
	}
	return .None
}

// Abort a transaction.
lmdb_abort :: proc(txn: MDB_txn) {
	mdb_txn_abort(txn)
}

// Get a value by key within an existing transaction.
// Returns a slice pointing into LMDB's mmap — valid only during the transaction.
lmdb_get :: proc(txn: MDB_txn, dbi: MDB_dbi, key: []byte) -> ([]byte, bool) {
	k := MDB_val{mv_size = c.size_t(len(key)), mv_data = raw_data(key)}
	v: MDB_val
	rc := mdb_get(txn, dbi, &k, &v)
	if rc != MDB_SUCCESS {
		return nil, false
	}
	return ([^]byte)(v.mv_data)[:v.mv_size], true
}

// Put a key-value pair within an existing transaction.
lmdb_put :: proc(txn: MDB_txn, dbi: MDB_dbi, key: []byte, value: []byte) -> Storage_Error {
	k := MDB_val{mv_size = c.size_t(len(key)), mv_data = raw_data(key)}
	v := MDB_val{mv_size = c.size_t(len(value)), mv_data = raw_data(value)}
	rc := mdb_put(txn, dbi, &k, &v, 0)
	if rc != MDB_SUCCESS {
		return .IO_Error
	}
	return .None
}

// Delete a key within an existing transaction.
lmdb_del :: proc(txn: MDB_txn, dbi: MDB_dbi, key: []byte) -> Storage_Error {
	k := MDB_val{mv_size = c.size_t(len(key)), mv_data = raw_data(key)}
	rc := mdb_del(txn, dbi, &k, nil)
	if rc == MDB_NOTFOUND {
		return .Not_Found
	}
	if rc != MDB_SUCCESS {
		return .IO_Error
	}
	return .None
}

// Get the number of entries in a database.
lmdb_count :: proc(store: ^LMDB_Store, dbi: MDB_dbi) -> u32 {
	txn, err := lmdb_begin_read(store)
	if err != .None {
		return 0
	}
	defer lmdb_abort(txn)

	stat: MDB_stat
	rc := mdb_stat(txn, dbi, &stat)
	if rc != MDB_SUCCESS {
		return 0
	}
	return u32(stat.ms_entries)
}
