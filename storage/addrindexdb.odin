package storage

import "core:c"
import "core:log"
import "core:os"
import "core:strings"

// Standalone RocksDB for the address (scripthash) index (--index-addresses).
// Located at <datadir>/addrindex/. Incompatible with pruning — history reads
// txs from the flat block files.
//
// RocksDB (not LevelDB, unlike the other indexes) because this index is large
// (hundreds of GB) and RANDOMLY keyed (scripthash = sha256): LevelDB's single
// compaction thread can't keep up and write-stalls the chain thread, tripling
// IBD (measured: 5.17 TB written for a 316 GB index, index = 86% of per-block
// time). RocksDB's multi-threaded compaction + Zstd + big SST files fix that.
// See docs/plans/addrindex-rocksdb.md. The write pattern is UNCHANGED (one
// atomic WriteBatch per block, `best` marker inside it), so the reorg/crash
// model is identical to the LevelDB version.
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
	db:         RDB,
	cache:      RDB_Cache,
	bloom:      RDB_FilterPolicy,
	read_opts:  RDB_ReadOptions,
	write_opts: RDB_WriteOptions,
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
	adb.bloom = rocksdb_filterpolicy_create_bloom_full(10)
	adb.read_opts = rocksdb_readoptions_create()
	adb.write_opts = rocksdb_writeoptions_create()
	// Disable the WAL for the address index. The index is fully rebuildable and our
	// own catch-up recovers it by forward-replay from the `best` marker off the flat
	// block+undo files (addr_index_catchup) — RocksDB's WAL crash-recovery is
	// redundant with that and just costs an fsync per commit (the dense-region iowait
	// bottleneck). On a crash the index rolls back to the last memtable flush and
	// catch-up re-indexes the tail (idempotent). No correctness change.
	rocksdb_writeoptions_disable_WAL(adb.write_opts, 1)

	opts := rocksdb_options_create()
	rocksdb_options_set_create_if_missing(opts, 1)
	// The three fixes for LevelDB's single-thread compaction stall on this large,
	// randomly-keyed index:
	//   1. multi-threaded flush+compaction (the #1 win — LevelDB has one thread),
	//   2. Zstd compression (LevelDB used none → ~halve the data → ~halve the I/O),
	//   3. big SST files (LevelDB's 2 MB → ~158k tiny files at 316 GB; 256 MB → ~60x fewer).
	rocksdb_options_increase_parallelism(opts, 8)
	rocksdb_options_set_max_subcompactions(opts, 4) // split one compaction across cores
	// Compression: NONE on the hot upper levels (L0-L2 are recompacted constantly —
	// Zstd there pins the single compaction thread on CPU), Zstd only on the
	// bottommost level (most of the data, compacted rarely) so on-disk size stays
	// down. We measured the reindex is NOT write-bandwidth-bound (WAL-off cut writes
	// 4× with zero speedup), so trading upper-level bytes for compaction CPU is free.
	rocksdb_options_set_compression(opts, RDB_NO_COMPRESSION)
	rocksdb_options_set_bottommost_compression(opts, RDB_ZSTD)
	rocksdb_options_set_write_buffer_size(opts, 512 * 1024 * 1024)       // 512 MB memtable
	rocksdb_options_set_max_write_buffer_number(opts, 4)
	rocksdb_options_set_target_file_size_base(opts, 256 * 1024 * 1024)   // 256 MB SSTs
	rocksdb_options_set_max_bytes_for_level_base(opts, 2 * 1024 * 1024 * 1024) // 2 GB L1
	rocksdb_options_set_bytes_per_sync(opts, 8 * 1024 * 1024)

	// Block-based table: cache + bloom + block size live here in RocksDB.
	bbt := rocksdb_block_based_options_create()
	// 1 GB LRU. It now also holds index + filter blocks (below), so give it more
	// than the old 512 MB. Total addrindex RAM is bounded ≈ this cache + memtables
	// (4 × 512 MB) ≈ 3 GB, independent of --dbcache and of the index's on-disk size.
	adb.cache = rocksdb_cache_create_lru(1024 * 1024 * 1024)
	rocksdb_block_based_options_set_block_cache(bbt, adb.cache)
	rocksdb_block_based_options_set_filter_policy(bbt, adb.bloom)
	rocksdb_block_based_options_set_block_size(bbt, 16 * 1024)
	// CRITICAL: keep index + bloom-filter blocks IN the bounded block cache.
	// Default RocksDB holds them in table-reader memory outside the cache, growing
	// unbounded with DB size — a 139 GB addrindex reached ~17 GB of filters in RAM
	// and OOM-killed the node (2026-07-18), regardless of --dbcache. High priority
	// + pinning L0's keeps the hot ones resident so reads don't thrash the cache.
	rocksdb_block_based_options_set_cache_index_and_filter_blocks(bbt, 1)
	rocksdb_block_based_options_set_cache_index_and_filter_blocks_with_high_priority(bbt, 1)
	rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(bbt, 1)
	rocksdb_options_set_block_based_table_factory(opts, bbt)

	path_buf: [512]byte
	path_len := _bprint_path(path_buf[:], data_dir, "/addrindex")
	path_buf[path_len] = 0
	os.make_directory(string(path_buf[:path_len]))

	errptr: cstring = nil
	adb.db = rocksdb_open(opts, cstring(&path_buf[0]), &errptr)
	rocksdb_options_destroy(opts)
	rocksdb_block_based_options_destroy(bbt) // factory kept its own refs to cache/bloom
	if adb.db == nil {
		log.errorf("Failed to open addrindex RocksDB: %s", errptr)
		if errptr != nil { rocksdb_free(rawptr(errptr)) }
		_addr_index_db_cleanup(&adb)
		return adb, .IO_Error
	}

	adb.path = strings.clone(string(path_buf[:path_len]))
	log.infof("Address index DB (RocksDB) opened at %s", adb.path)
	return adb, .None
}

_addr_index_db_cleanup :: proc(adb: ^Addr_Index_DB) {
	if adb.read_opts != nil { rocksdb_readoptions_destroy(adb.read_opts) }
	if adb.write_opts != nil { rocksdb_writeoptions_destroy(adb.write_opts) }
	if adb.cache != nil { rocksdb_cache_destroy(adb.cache) }
	// bloom (filter policy) is owned by the table factory inside the open DB;
	// RocksDB frees it on close, so we don't destroy it here.
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
		rocksdb_close(adb.db) // frees the table factory (decref cache+bloom)
		adb.db = nil
	}
	_addr_index_db_cleanup(adb) // then decref our cache ref
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
_put_best :: proc(batch: RDB_WriteBatch, block_hash: Hash256, height: int) {
	best: [36]byte
	bh := block_hash
	copy(best[:32], bh[:])
	_put_u32_le(best[32:36], u32(height))
	rdb_batch_put(batch, transmute([]byte)string("best"), best[:])
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
	batch := rocksdb_writebatch_create()
	defer rocksdb_writebatch_destroy(batch)

	hk: [74]byte
	uk: [69]byte
	uv: [12]byte
	tk: [33]byte
	tv: [8]byte

	for f in funding {
		_h_key(hk[:], f.scripthash, f.height, f.txid, 0, f.vout)
		rdb_batch_put(batch, hk[:], nil)
		_u_key(uk[:], f.scripthash, f.txid, f.vout)
		_put_u32_le(uv[0:4], f.height)
		_put_i64_le(uv[4:12], f.value)
		rdb_batch_put(batch, uk[:], uv[:])
	}

	for s in spending {
		_h_key(hk[:], s.scripthash, s.height, s.spend_txid, 1, s.vin)
		rdb_batch_put(batch, hk[:], nil)
		_u_key(uk[:], s.scripthash, s.prev_txid, s.prev_vout)
		rdb_batch_delete(batch, uk[:])
	}

	for t in tx_locs {
		_t_key(tk[:], t.txid)
		_put_u32_le(tv[0:4], t.height)
		_put_u32_le(tv[4:8], t.position)
		rdb_batch_put(batch, tk[:], tv[:])
	}

	_put_best(batch, block_hash, height)
	return rdb_batch_write(adb.db, adb.write_opts, batch)
}

// A connected block's rows, for coalesced multi-block writes.
Addr_Block_Batch_Entry :: struct {
	hash:     Hash256,
	height:   int,
	funding:  []Addr_Funding,
	spending: []Addr_Spending,
	tx_locs:  []Addr_Tx_Loc,
}

// Write MANY connected blocks (in ascending height order) in ONE atomic
// WriteBatch — the `best` marker is the LAST entry's. Used by the parallel
// catch-up to collapse per-block commit overhead (the serial-apply bottleneck).
// Ordering within the batch is (block order, funding-before-spending per block),
// identical to per-block writes, so the U-index add/delete order is preserved.
// Per-batch atomicity (vs per-block): a crash re-indexes forward from `best`
// (idempotent), so this is safe — same recovery model, coarser marker.
addr_index_write_blocks :: proc(adb: ^Addr_Index_DB, entries: []Addr_Block_Batch_Entry) -> Storage_Error {
	if len(entries) == 0 {
		return .None
	}
	batch := rocksdb_writebatch_create()
	defer rocksdb_writebatch_destroy(batch)

	hk: [74]byte
	uk: [69]byte
	uv: [12]byte
	tk: [33]byte
	tv: [8]byte

	for e in entries {
		for f in e.funding {
			_h_key(hk[:], f.scripthash, f.height, f.txid, 0, f.vout)
			rdb_batch_put(batch, hk[:], nil)
			_u_key(uk[:], f.scripthash, f.txid, f.vout)
			_put_u32_le(uv[0:4], f.height)
			_put_i64_le(uv[4:12], f.value)
			rdb_batch_put(batch, uk[:], uv[:])
		}
		for s in e.spending {
			_h_key(hk[:], s.scripthash, s.height, s.spend_txid, 1, s.vin)
			rdb_batch_put(batch, hk[:], nil)
			_u_key(uk[:], s.scripthash, s.prev_txid, s.prev_vout)
			rdb_batch_delete(batch, uk[:])
		}
		for t in e.tx_locs {
			_t_key(tk[:], t.txid)
			_put_u32_le(tv[0:4], t.height)
			_put_u32_le(tv[4:8], t.position)
			rdb_batch_put(batch, tk[:], tv[:])
		}
	}

	last := entries[len(entries) - 1]
	_put_best(batch, last.hash, last.height)
	return rdb_batch_write(adb.db, adb.write_opts, batch)
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
	batch := rocksdb_writebatch_create()
	defer rocksdb_writebatch_destroy(batch)

	hk: [74]byte
	uk: [69]byte
	uv: [12]byte
	tk: [33]byte

	for f in funding {
		_h_key(hk[:], f.scripthash, f.height, f.txid, 0, f.vout)
		rdb_batch_delete(batch, hk[:])
		_u_key(uk[:], f.scripthash, f.txid, f.vout)
		rdb_batch_delete(batch, uk[:])
	}

	for s in spending {
		_h_key(hk[:], s.scripthash, s.height, s.spend_txid, 1, s.vin)
		rdb_batch_delete(batch, hk[:])
		// Restore the spent output as unspent again.
		_u_key(uk[:], s.scripthash, s.prev_txid, s.prev_vout)
		_put_u32_le(uv[0:4], s.prev_height)
		_put_i64_le(uv[4:12], s.prev_value)
		rdb_batch_put(batch, uk[:], uv[:])
	}

	for t in tx_locs {
		_t_key(tk[:], t.txid)
		rdb_batch_delete(batch, tk[:])
	}

	_put_best(batch, parent_hash, parent_height)
	return rdb_batch_write(adb.db, adb.write_opts, batch)
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
	iter := rocksdb_create_iterator(adb.db, adb.read_opts)
	defer rocksdb_iter_destroy(iter)

	rocksdb_iter_seek(iter, &prefix[0], 33)
	for rocksdb_iter_valid(iter) != 0 {
		klen: c.size_t
		kptr := rocksdb_iter_key(iter, &klen)
		if klen != 74 { break }
		key := kptr[:74]
		if key[0] != ADDR_H_PREFIX || !_hash_eq(key[1:33], prefix[1:33]) { break }
		e: Addr_History_Entry
		e.height = _get_u32_be(key[33:37])
		copy(e.txid[:], key[37:69])
		e.io = key[69]
		e.idx = _get_u32_be(key[70:74])
		append(&out, e)
		rocksdb_iter_next(iter)
	}
	return out[:]
}

// Count a scripthash's history rows, stopping early once `cap` is exceeded.
// O(min(rows, cap)) — no per-row allocation — so callers can cheaply refuse
// mega-history addresses before materializing/resolving the whole history.
// `exceeded` is true iff the scripthash has strictly more than `cap` rows.
addr_index_history_count_capped :: proc(adb: ^Addr_Index_DB, scripthash: Hash256, cap: int) -> (count: int, exceeded: bool) {
	prefix: [33]byte
	sh := scripthash
	prefix[0] = ADDR_H_PREFIX
	copy(prefix[1:33], sh[:])

	iter := rocksdb_create_iterator(adb.db, adb.read_opts)
	defer rocksdb_iter_destroy(iter)

	rocksdb_iter_seek(iter, &prefix[0], 33)
	for rocksdb_iter_valid(iter) != 0 {
		klen: c.size_t
		kptr := rocksdb_iter_key(iter, &klen)
		if klen != 74 { break }
		key := kptr[:74]
		if key[0] != ADDR_H_PREFIX || !_hash_eq(key[1:33], prefix[1:33]) { break }
		count += 1
		if count > cap { return count, true }
		rocksdb_iter_next(iter)
	}
	return count, false
}

// All unspent outputs owned by a scripthash. Allocated on `allocator`.
addr_index_get_utxos :: proc(adb: ^Addr_Index_DB, scripthash: Hash256, allocator := context.allocator) -> []Addr_Utxo_Entry {
	prefix: [33]byte
	sh := scripthash
	prefix[0] = ADDR_U_PREFIX
	copy(prefix[1:33], sh[:])

	out := make([dynamic]Addr_Utxo_Entry, 0, 16, allocator)
	iter := rocksdb_create_iterator(adb.db, adb.read_opts)
	defer rocksdb_iter_destroy(iter)

	rocksdb_iter_seek(iter, &prefix[0], 33)
	for rocksdb_iter_valid(iter) != 0 {
		klen: c.size_t
		kptr := rocksdb_iter_key(iter, &klen)
		if klen != 69 { break }
		key := kptr[:69]
		if key[0] != ADDR_U_PREFIX || !_hash_eq(key[1:33], prefix[1:33]) { break }
		vlen: c.size_t
		vptr := rocksdb_iter_value(iter, &vlen)
		if vptr == nil || vlen != 12 { rocksdb_iter_next(iter); continue }
		val := vptr[:12]
		e: Addr_Utxo_Entry
		copy(e.txid[:], key[33:65])
		e.vout = _get_u32_be(key[65:69])
		e.height = _get_u32_le(val[0:4])
		e.value = _get_i64_le(val[4:12])
		append(&out, e)
		rocksdb_iter_next(iter)
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
	val, ok := rdb_get(adb.db, adb.read_opts, tk[:], context.temp_allocator)
	if !ok || len(val) != 8 {
		return {}, false
	}
	loc.height = _get_u32_le(val[0:4])
	loc.position = _get_u32_le(val[4:8])
	return loc, true
}

// Last indexed block, or found=false for a fresh index.
addr_index_best :: proc(adb: ^Addr_Index_DB) -> (hash: Hash256, height: int, found: bool) {
	val, ok := rdb_get(adb.db, adb.read_opts, transmute([]byte)string("best"), context.temp_allocator)
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
