package storage

import "core:c"
import "core:log"
import "core:os"
import "core:strings"

// Standalone LevelDB for the address (scripthash) index (--index-addresses).
// Located at <datadir>/addrindex/. Incompatible with pruning — history reads
// txs from the flat block files. This is the third index of the family that
// already includes --txindex (txindexdb.odin) and the BIP158 filter index.
//
// A scripthash is sha256(scriptPubKey) — stored raw (NOT byte-reversed); the
// Electrum/Esplora byte-reversal is applied at the API edge.
//
// Keys (all big-endian integers so a prefix scan returns rows in natural order):
//   'H' | scripthash(32) | height(4 BE) | txid(32) | io(1) | idx(4 BE)  -> (empty)
//         history: funding(io=0)/spending(io=1) touch of a scripthash, height-ordered.
//   'U' | scripthash(32) | txid(32) | vout(4 BE)                        -> height(4 LE) | value(8 LE)
//         unspent output owned by a scripthash (balance / listunspent).
//   'T' | txid(32)                                                      -> height(4 LE) | position(4 LE)
//         txid -> location in the flat files (self-contained; no --txindex needed).
//   "best"                                                              -> block_hash(32) | height(4 LE)
//         last indexed block (catch-up resume marker).
//
// Writes are per-block and unsynced: a crash loses at most the recent tail, and
// startup catch-up re-indexes from the persisted best marker (idempotent puts +
// deletes converge on a forward replay).

ADDR_H_PREFIX :: byte('H')
ADDR_U_PREFIX :: byte('U')
ADDR_T_PREFIX :: byte('T')

Addr_Index_DB :: struct {
	db:         LDB,
	cache:      LDB_Cache,
	bloom:      LDB_FilterPolicy,
	read_opts:  LDB_ReadOptions,
	write_opts: LDB_WriteOptions,
	path:       string, // on-disk dir, for size reporting (heap-owned)
}

// A funding touch: an output the block created, owned by `scripthash`.
Addr_Funding :: struct {
	scripthash: Hash256,
	txid:       Hash256,
	vout:       u32,
	height:     u32,
	value:      i64,
}

// A spending touch: an input the block spent. Carries the spent prevout's
// coin so the U row can be deleted on connect and restored on disconnect.
Addr_Spending :: struct {
	scripthash:  Hash256, // of the spent prevout's scriptPubKey
	spend_txid:  Hash256, // the spending tx
	vin:         u32,
	height:      u32, // height of the spending block
	prev_txid:   Hash256, // the outpoint being spent
	prev_vout:   u32,
	prev_height: u32, // the funded coin's height (for restore)
	prev_value:  i64,
}

// A txid -> flat-file location row.
Addr_Tx_Loc :: struct {
	txid:     Hash256,
	height:   u32,
	position: u32,
}

// Returned by a history prefix scan (height-ordered).
Addr_History_Entry :: struct {
	height: u32,
	txid:   Hash256,
	io:     u8, // 0 = funding, 1 = spending
	idx:    u32, // vout (funding) or vin (spending)
}

// Returned by a UTXO prefix scan.
Addr_Utxo_Entry :: struct {
	txid:   Hash256,
	vout:   u32,
	height: u32,
	value:  i64,
}

addr_index_db_open :: proc(data_dir: string) -> (adb: Addr_Index_DB, err: Storage_Error) {
	adb.bloom = leveldb_filterpolicy_create_bloom(10)
	adb.read_opts = leveldb_readoptions_create()
	adb.write_opts = leveldb_writeoptions_create()

	opts := leveldb_options_create()
	leveldb_options_set_create_if_missing(opts, 1)
	leveldb_options_set_compression(opts, 0)
	// Bulk-load tuning: the address index grows to hundreds of GB during IBD, so
	// a tiny 4 MB memtable forced constant flushes → thousands of small SSTables →
	// heavy compaction write-amplification (the per-block index cost that climbs
	// with DB size). A large memtable produces far fewer, larger level-0 files and
	// slashes compaction frequency; big cache + many open files keep reads/compaction
	// off the syscall path. Pure perf knobs — no on-disk format change.
	leveldb_options_set_write_buffer_size(opts, 128 * 1024 * 1024) // 128 MB memtable
	leveldb_options_set_max_open_files(opts, 4096)
	leveldb_options_set_block_size(opts, 16 * 1024) // 16 KB blocks (fewer index entries)
	adb.cache = leveldb_cache_create_lru(256 * 1024 * 1024) // 256 MB block cache
	leveldb_options_set_cache(opts, adb.cache)
	leveldb_options_set_filter_policy(opts, adb.bloom)

	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/addrindex")
	path_buf[path_len] = 0
	os.make_directory(string(path_buf[:path_len]))

	errptr: cstring = nil
	adb.db = leveldb_open(opts, cstring(&path_buf[0]), &errptr)
	if adb.db == nil {
		log.errorf("Failed to open addrindex LevelDB: %s", errptr)
		if errptr != nil { leveldb_free(rawptr(errptr)) }
		leveldb_options_destroy(opts)
		_addr_index_db_cleanup(&adb)
		return adb, .IO_Error
	}
	leveldb_options_destroy(opts)

	adb.path = strings.clone(string(path_buf[:path_len]))
	log.infof("Address index DB opened at %s", adb.path)
	return adb, .None
}

_addr_index_db_cleanup :: proc(adb: ^Addr_Index_DB) {
	if adb.read_opts != nil { leveldb_readoptions_destroy(adb.read_opts) }
	if adb.write_opts != nil { leveldb_writeoptions_destroy(adb.write_opts) }
	if adb.cache != nil { leveldb_cache_destroy(adb.cache) }
	if adb.bloom != nil { leveldb_filterpolicy_destroy(adb.bloom) }
}

// Total bytes of the addrindex/ directory on disk (for the status panel).
addr_index_disk_size :: proc(adb: ^Addr_Index_DB) -> i64 {
	if adb == nil || adb.path == "" { return 0 }
	dh, derr := os.open(adb.path)
	if derr != nil { return 0 }
	defer os.close(dh)
	entries, _ := os.read_dir(dh, -1, context.temp_allocator)
	total: i64 = 0
	for entry in entries { total += entry.size }
	return total
}

addr_index_db_close :: proc(adb: ^Addr_Index_DB) {
	if adb.db != nil {
		leveldb_close(adb.db)
		adb.db = nil
	}
	_addr_index_db_cleanup(adb)
}

// ---- key encoding ----

@(private = "file")
_put_u32_be :: proc(buf: []byte, v: u32) {
	buf[0] = byte(v >> 24); buf[1] = byte(v >> 16); buf[2] = byte(v >> 8); buf[3] = byte(v)
}

@(private = "file")
_get_u32_be :: proc(buf: []byte) -> u32 {
	return u32(buf[0]) << 24 | u32(buf[1]) << 16 | u32(buf[2]) << 8 | u32(buf[3])
}

@(private = "file")
_put_u32_le :: proc(buf: []byte, v: u32) {
	buf[0] = byte(v); buf[1] = byte(v >> 8); buf[2] = byte(v >> 16); buf[3] = byte(v >> 24)
}

@(private = "file")
_get_u32_le :: proc(buf: []byte) -> u32 {
	return u32(buf[0]) | u32(buf[1]) << 8 | u32(buf[2]) << 16 | u32(buf[3]) << 24
}

@(private = "file")
_put_i64_le :: proc(buf: []byte, v: i64) {
	u := transmute(u64)v
	for i in 0 ..< 8 { buf[i] = byte(u >> uint(8 * i)) }
}

@(private = "file")
_get_i64_le :: proc(buf: []byte) -> i64 {
	u: u64 = 0
	for i in 0 ..< 8 { u |= u64(buf[i]) << uint(8 * i) }
	return transmute(i64)u
}

// H | scripthash(32) | height(4 BE) | txid(32) | io(1) | idx(4 BE) = 74 bytes
@(private = "file")
_h_key :: proc(buf: []byte, sh: Hash256, height: u32, txid: Hash256, io: u8, idx: u32) {
	sh := sh; txid := txid
	buf[0] = ADDR_H_PREFIX
	copy(buf[1:33], sh[:])
	_put_u32_be(buf[33:37], height)
	copy(buf[37:69], txid[:])
	buf[69] = io
	_put_u32_be(buf[70:74], idx)
}

// U | scripthash(32) | txid(32) | vout(4 BE) = 69 bytes
@(private = "file")
_u_key :: proc(buf: []byte, sh: Hash256, txid: Hash256, vout: u32) {
	sh := sh; txid := txid
	buf[0] = ADDR_U_PREFIX
	copy(buf[1:33], sh[:])
	copy(buf[33:65], txid[:])
	_put_u32_be(buf[65:69], vout)
}

// T | txid(32) = 33 bytes
@(private = "file")
_t_key :: proc(buf: []byte, txid: Hash256) {
	txid := txid
	buf[0] = ADDR_T_PREFIX
	copy(buf[1:33], txid[:])
}

// ---- block write / unwrite (atomic per block) ----

@(private = "file")
_put_best :: proc(batch: LDB_WriteBatch, block_hash: Hash256, height: int) {
	best: [36]byte
	bh := block_hash
	copy(best[:32], bh[:])
	_put_u32_le(best[32:36], u32(height))
	ldb_batch_put(batch, transmute([]byte)string("best"), best[:])
}

// Index one connected block: add H/U funding rows, H rows + U deletes for
// spends, T rows, and advance the best marker — one atomic batch.
addr_index_write_block :: proc(
	adb: ^Addr_Index_DB,
	block_hash: Hash256,
	height: int,
	funding: []Addr_Funding,
	spending: []Addr_Spending,
	tx_locs: []Addr_Tx_Loc,
) -> Storage_Error {
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	hk: [74]byte
	uk: [69]byte
	uv: [12]byte
	tk: [33]byte
	tv: [8]byte

	for f in funding {
		_h_key(hk[:], f.scripthash, f.height, f.txid, 0, f.vout)
		ldb_batch_put(batch, hk[:], nil)
		_u_key(uk[:], f.scripthash, f.txid, f.vout)
		_put_u32_le(uv[0:4], f.height)
		_put_i64_le(uv[4:12], f.value)
		ldb_batch_put(batch, uk[:], uv[:])
	}

	for s in spending {
		_h_key(hk[:], s.scripthash, s.height, s.spend_txid, 1, s.vin)
		ldb_batch_put(batch, hk[:], nil)
		_u_key(uk[:], s.scripthash, s.prev_txid, s.prev_vout)
		ldb_batch_delete(batch, uk[:])
	}

	for t in tx_locs {
		_t_key(tk[:], t.txid)
		_put_u32_le(tv[0:4], t.height)
		_put_u32_le(tv[4:8], t.position)
		ldb_batch_put(batch, tk[:], tv[:])
	}

	_put_best(batch, block_hash, height)
	return ldb_batch_write(adb.db, adb.write_opts, batch)
}

// Reverse a disconnected block: delete the H/U/T rows it added, restore the U
// rows it spent (from the carried prevout coins), move best to the parent.
addr_index_unwrite_block :: proc(
	adb: ^Addr_Index_DB,
	parent_hash: Hash256,
	parent_height: int,
	funding: []Addr_Funding,
	spending: []Addr_Spending,
	tx_locs: []Addr_Tx_Loc,
) -> Storage_Error {
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	hk: [74]byte
	uk: [69]byte
	uv: [12]byte
	tk: [33]byte

	for f in funding {
		_h_key(hk[:], f.scripthash, f.height, f.txid, 0, f.vout)
		ldb_batch_delete(batch, hk[:])
		_u_key(uk[:], f.scripthash, f.txid, f.vout)
		ldb_batch_delete(batch, uk[:])
	}

	for s in spending {
		_h_key(hk[:], s.scripthash, s.height, s.spend_txid, 1, s.vin)
		ldb_batch_delete(batch, hk[:])
		// Restore the spent output as unspent again.
		_u_key(uk[:], s.scripthash, s.prev_txid, s.prev_vout)
		_put_u32_le(uv[0:4], s.prev_height)
		_put_i64_le(uv[4:12], s.prev_value)
		ldb_batch_put(batch, uk[:], uv[:])
	}

	for t in tx_locs {
		_t_key(tk[:], t.txid)
		ldb_batch_delete(batch, tk[:])
	}

	_put_best(batch, parent_hash, parent_height)
	return ldb_batch_write(adb.db, adb.write_opts, batch)
}

// ---- queries ----

// Full history for a scripthash, height-ordered (LevelDB lexicographic order
// over the BE-height key). Allocated on `allocator`.
addr_index_get_history :: proc(adb: ^Addr_Index_DB, scripthash: Hash256, allocator := context.allocator) -> []Addr_History_Entry {
	prefix: [33]byte
	sh := scripthash
	prefix[0] = ADDR_H_PREFIX
	copy(prefix[1:33], sh[:])

	out := make([dynamic]Addr_History_Entry, 0, 16, allocator)
	iter := leveldb_create_iterator(adb.db, adb.read_opts)
	defer leveldb_iter_destroy(iter)

	leveldb_iter_seek(iter, &prefix[0], 33)
	for leveldb_iter_valid(iter) != 0 {
		klen: c.size_t
		kptr := leveldb_iter_key(iter, &klen)
		if klen != 74 { break }
		key := kptr[:74]
		if key[0] != ADDR_H_PREFIX || !_hash_eq(key[1:33], prefix[1:33]) { break }
		e: Addr_History_Entry
		e.height = _get_u32_be(key[33:37])
		copy(e.txid[:], key[37:69])
		e.io = key[69]
		e.idx = _get_u32_be(key[70:74])
		append(&out, e)
		leveldb_iter_next(iter)
	}
	return out[:]
}

// All unspent outputs owned by a scripthash. Allocated on `allocator`.
addr_index_get_utxos :: proc(adb: ^Addr_Index_DB, scripthash: Hash256, allocator := context.allocator) -> []Addr_Utxo_Entry {
	prefix: [33]byte
	sh := scripthash
	prefix[0] = ADDR_U_PREFIX
	copy(prefix[1:33], sh[:])

	out := make([dynamic]Addr_Utxo_Entry, 0, 16, allocator)
	iter := leveldb_create_iterator(adb.db, adb.read_opts)
	defer leveldb_iter_destroy(iter)

	leveldb_iter_seek(iter, &prefix[0], 33)
	for leveldb_iter_valid(iter) != 0 {
		klen: c.size_t
		kptr := leveldb_iter_key(iter, &klen)
		if klen != 69 { break }
		key := kptr[:69]
		if key[0] != ADDR_U_PREFIX || !_hash_eq(key[1:33], prefix[1:33]) { break }
		vlen: c.size_t
		vptr := leveldb_iter_value(iter, &vlen)
		if vptr == nil || vlen != 12 { leveldb_iter_next(iter); continue }
		val := vptr[:12]
		e: Addr_Utxo_Entry
		copy(e.txid[:], key[33:65])
		e.vout = _get_u32_be(key[65:69])
		e.height = _get_u32_le(val[0:4])
		e.value = _get_i64_le(val[4:12])
		append(&out, e)
		leveldb_iter_next(iter)
	}
	return out[:]
}

Addr_Tx_Location :: struct {
	height:   u32,
	position: u32,
}

addr_index_get_tx :: proc(adb: ^Addr_Index_DB, txid: Hash256) -> (loc: Addr_Tx_Location, found: bool) {
	tk: [33]byte
	_t_key(tk[:], txid)
	val, ok := ldb_get(adb.db, adb.read_opts, tk[:], context.temp_allocator)
	if !ok || len(val) != 8 {
		return {}, false
	}
	loc.height = _get_u32_le(val[0:4])
	loc.position = _get_u32_le(val[4:8])
	return loc, true
}

// Last indexed block, or found=false for a fresh index.
addr_index_best :: proc(adb: ^Addr_Index_DB) -> (hash: Hash256, height: int, found: bool) {
	val, ok := ldb_get(adb.db, adb.read_opts, transmute([]byte)string("best"), context.temp_allocator)
	if !ok || len(val) != 36 {
		return {}, -1, false
	}
	copy(hash[:], val[:32])
	height = int(_get_u32_le(val[32:36]))
	return hash, height, true
}

@(private = "file")
_hash_eq :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}
