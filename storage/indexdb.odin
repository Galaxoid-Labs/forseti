package storage

import "core:c"

Block_Status_Flag :: enum u8 {
	Has_Data,
	Has_Undo,
	Valid_Header,
	Valid_Transactions,
	Valid_Chain,
	Failed,
}

Block_Status :: bit_set[Block_Status_Flag; u8]

Block_Index_Record :: struct {
	hash:        Hash256,
	prev_hash:   Hash256,
	height:      i32,
	file_num:    u32,
	data_offset: u32,
	data_size:   u32,
	version:     i32,
	timestamp:   u32,
	bits:        u32,
	nonce:       u32,
	status:      Block_Status,
}

// Fixed size of a record on disk:
// length(4) + hash(32) + prev_hash(32) + height(4) + file_num(4) + data_offset(4) + data_size(4) +
// version(4) + timestamp(4) + bits(4) + nonce(4) + status(1) = 101 bytes
BLOCK_INDEX_RECORD_SIZE :: 101

Index_DB :: struct {
	lmdb:    ^LMDB_Store,
	records: map[Hash256]Block_Index_Record,
}

// Initialize index database, loading all records from LMDB into memory.
index_db_init :: proc(lmdb: ^LMDB_Store, allocator := context.allocator) -> (db: Index_DB, err: Storage_Error) {
	db.lmdb = lmdb
	db.records = make(map[Hash256]Block_Index_Record, 1024, allocator)

	// Load all records via cursor scan
	txn: MDB_txn
	rc := mdb_txn_begin(lmdb.env, nil, MDB_RDONLY, &txn)
	if rc != MDB_SUCCESS {
		return db, .IO_Error
	}
	defer mdb_txn_abort(txn)

	cursor: MDB_cursor
	rc = mdb_cursor_open(txn, lmdb.index_dbi, &cursor)
	if rc != MDB_SUCCESS {
		return db, .IO_Error
	}
	defer mdb_cursor_close(cursor)

	key: MDB_val
	val: MDB_val
	rc = mdb_cursor_get(cursor, &key, &val, MDB_FIRST)
	for rc == MDB_SUCCESS {
		if val.mv_size >= c.size_t(BLOCK_INDEX_RECORD_SIZE) {
			data := ([^]byte)(val.mv_data)[:val.mv_size]
			rec, ok := _deserialize_index_record(data)
			if ok {
				db.records[rec.hash] = rec
			}
		}
		rc = mdb_cursor_get(cursor, &key, &val, MDB_NEXT)
	}

	return db, .None
}

// Free the in-memory records map.
index_db_close :: proc(db: ^Index_DB) {
	delete(db.records)
}

// Write a record to LMDB and update the in-memory map.
index_db_put :: proc(db: ^Index_DB, record: Block_Index_Record) -> Storage_Error {
	// Serialize to fixed-size buffer
	buf: [BLOCK_INDEX_RECORD_SIZE]byte
	_serialize_index_record(&buf, record)

	txn, terr := lmdb_begin_write(db.lmdb)
	if terr != .None {
		return terr
	}

	hash := record.hash
	perr := lmdb_put(txn, db.lmdb.index_dbi, hash[:], buf[:])
	if perr != .None {
		lmdb_abort(txn)
		return perr
	}

	cerr := lmdb_commit(txn)
	if cerr != .None {
		return cerr
	}

	// Update in-memory map
	db.records[record.hash] = record
	return .None
}

// Lookup a record by block hash (from in-memory map).
index_db_get :: proc(db: ^Index_DB, hash: Hash256) -> (^Block_Index_Record, bool) {
	rec, ok := &db.records[hash]
	if !ok {
		return nil, false
	}
	return rec, true
}

// Return the number of unique records.
index_db_count :: proc(db: ^Index_DB) -> int {
	return len(db.records)
}

// --- Internal helpers ---

_bprint_path :: proc(buf: []byte, parts: ..string) -> int {
	pos := 0
	for part in parts {
		for i in 0 ..< len(part) {
			if pos < len(buf) {
				buf[pos] = part[i]
				pos += 1
			}
		}
	}
	return pos
}

_serialize_index_record :: proc(buf: ^[BLOCK_INDEX_RECORD_SIZE]byte, rec: Block_Index_Record) {
	off := 0

	// length (4 LE) — payload size after length field
	payload_size := u32(BLOCK_INDEX_RECORD_SIZE - 4)
	buf[off] = byte(payload_size); off += 1
	buf[off] = byte(payload_size >> 8); off += 1
	buf[off] = byte(payload_size >> 16); off += 1
	buf[off] = byte(payload_size >> 24); off += 1

	// hash (32)
	h := rec.hash
	for i in 0 ..< 32 {
		buf[off + i] = h[i]
	}
	off += 32

	// prev_hash (32)
	ph := rec.prev_hash
	for i in 0 ..< 32 {
		buf[off + i] = ph[i]
	}
	off += 32

	// height (4 LE)
	height := transmute(u32)rec.height
	buf[off] = byte(height); off += 1
	buf[off] = byte(height >> 8); off += 1
	buf[off] = byte(height >> 16); off += 1
	buf[off] = byte(height >> 24); off += 1

	// file_num (4 LE)
	buf[off] = byte(rec.file_num); off += 1
	buf[off] = byte(rec.file_num >> 8); off += 1
	buf[off] = byte(rec.file_num >> 16); off += 1
	buf[off] = byte(rec.file_num >> 24); off += 1

	// data_offset (4 LE)
	buf[off] = byte(rec.data_offset); off += 1
	buf[off] = byte(rec.data_offset >> 8); off += 1
	buf[off] = byte(rec.data_offset >> 16); off += 1
	buf[off] = byte(rec.data_offset >> 24); off += 1

	// data_size (4 LE)
	buf[off] = byte(rec.data_size); off += 1
	buf[off] = byte(rec.data_size >> 8); off += 1
	buf[off] = byte(rec.data_size >> 16); off += 1
	buf[off] = byte(rec.data_size >> 24); off += 1

	// version (4 LE)
	ver := transmute(u32)rec.version
	buf[off] = byte(ver); off += 1
	buf[off] = byte(ver >> 8); off += 1
	buf[off] = byte(ver >> 16); off += 1
	buf[off] = byte(ver >> 24); off += 1

	// timestamp (4 LE)
	buf[off] = byte(rec.timestamp); off += 1
	buf[off] = byte(rec.timestamp >> 8); off += 1
	buf[off] = byte(rec.timestamp >> 16); off += 1
	buf[off] = byte(rec.timestamp >> 24); off += 1

	// bits (4 LE)
	buf[off] = byte(rec.bits); off += 1
	buf[off] = byte(rec.bits >> 8); off += 1
	buf[off] = byte(rec.bits >> 16); off += 1
	buf[off] = byte(rec.bits >> 24); off += 1

	// nonce (4 LE)
	buf[off] = byte(rec.nonce); off += 1
	buf[off] = byte(rec.nonce >> 8); off += 1
	buf[off] = byte(rec.nonce >> 16); off += 1
	buf[off] = byte(rec.nonce >> 24); off += 1

	// status (1)
	buf[off] = transmute(u8)rec.status
}

_deserialize_index_record :: proc(data: []byte) -> (rec: Block_Index_Record, ok: bool) {
	if len(data) < BLOCK_INDEX_RECORD_SIZE {
		return {}, false
	}

	off := 0

	// length (4 LE) — skip, already validated
	off += 4

	// hash (32)
	for i in 0 ..< 32 {
		rec.hash[i] = data[off + i]
	}
	off += 32

	// prev_hash (32)
	for i in 0 ..< 32 {
		rec.prev_hash[i] = data[off + i]
	}
	off += 32

	// height (4 LE)
	rec.height = transmute(i32)(u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24)
	off += 4

	// file_num (4 LE)
	rec.file_num = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// data_offset (4 LE)
	rec.data_offset = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// data_size (4 LE)
	rec.data_size = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// version (4 LE)
	rec.version = transmute(i32)(u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24)
	off += 4

	// timestamp (4 LE)
	rec.timestamp = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// bits (4 LE)
	rec.bits = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// nonce (4 LE)
	rec.nonce = u32(data[off]) | u32(data[off + 1]) << 8 | u32(data[off + 2]) << 16 | u32(data[off + 3]) << 24
	off += 4

	// status (1)
	rec.status = transmute(Block_Status)data[off]

	return rec, true
}
