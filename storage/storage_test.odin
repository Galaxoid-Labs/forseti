package storage

import "../consensus"
import "../crypto"
import "../wire"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

// --- Test helpers ---

make_test_dir :: proc(name: string) -> string {
	rng := rand.uint64()
	path := fmt.tprintf("/tmp/btcnode_test_%s_%x", name, rng)
	os.make_directory(path)
	return path
}

remove_test_dir :: proc(dir: string) {
	_remove_dir_contents(dir)
	os.remove(dir)
}

_remove_dir_contents :: proc(dir: string) {
	dh, derr := os.open(dir)
	if derr != nil do return
	defer os.close(dh)

	entries, _ := os.read_dir(dh, -1)
	for entry in entries {
		if entry.is_dir {
			_remove_dir_contents(entry.fullpath)
			os.remove(entry.fullpath)
		} else {
			os.remove(entry.fullpath)
		}
	}
}

// Build a minimal regtest block at given height.
make_test_block :: proc(height: int) -> wire.Block {
	cb := consensus.make_coinbase(height)
	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	tx_id := wire.tx_id(&cb)
	merkle := crypto.merkle_root([]crypto.Hash256{tx_id})

	params := consensus.REGTEST_PARAMS

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			merkle_root = merkle,
			timestamp   = u32(1231006505 + height),
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}

	consensus.mine_block(&block, &params)
	return block
}

// --- Flat file tests ---

@(test)
test_flat_file_write_read :: proc(t: ^testing.T) {
	dir := make_test_dir("flatfile_wr")
	defer remove_test_dir(dir)

	mgr, err := flat_file_open(dir, "blk")
	testing.expect_value(t, err, Storage_Error.None)
	defer flat_file_close(&mgr)

	// Write some data
	data := []byte{0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04}
	pos, werr := flat_file_write(&mgr, data)
	testing.expect_value(t, werr, Storage_Error.None)
	testing.expect_value(t, pos.file_num, u32(0))
	testing.expect_value(t, pos.offset, u32(0))

	// Write more data
	data2 := []byte{0xCA, 0xFE, 0xBA, 0xBE}
	pos2, werr2 := flat_file_write(&mgr, data2)
	testing.expect_value(t, werr2, Storage_Error.None)
	testing.expect_value(t, pos2.file_num, u32(0))
	testing.expect_value(t, pos2.offset, u32(8))

	// Read back first chunk
	read_data, rerr := flat_file_read(&mgr, pos, 8, context.temp_allocator)
	testing.expect_value(t, rerr, Storage_Error.None)
	testing.expect(t, len(read_data) == 8, "read data length")
	for i in 0 ..< 8 {
		testing.expect(t, read_data[i] == data[i], fmt.tprintf("byte %d mismatch", i))
	}

	// Read back second chunk
	read_data2, rerr2 := flat_file_read(&mgr, pos2, 4, context.temp_allocator)
	testing.expect_value(t, rerr2, Storage_Error.None)
	for i in 0 ..< 4 {
		testing.expect(t, read_data2[i] == data2[i], fmt.tprintf("byte %d mismatch", i))
	}
}

@(test)
test_flat_file_rollover :: proc(t: ^testing.T) {
	dir := make_test_dir("flatfile_roll")
	defer remove_test_dir(dir)

	mgr, err := flat_file_open(dir, "blk")
	testing.expect_value(t, err, Storage_Error.None)
	defer flat_file_close(&mgr)

	// Write a chunk that nearly fills the file
	big_data := make([]byte, MAX_FILE_SIZE - 16, context.temp_allocator)
	for i in 0 ..< len(big_data) {
		big_data[i] = byte(i & 0xFF)
	}
	pos1, werr1 := flat_file_write(&mgr, big_data)
	testing.expect_value(t, werr1, Storage_Error.None)
	testing.expect_value(t, pos1.file_num, u32(0))

	// Next write should roll to file 1
	small_data := []byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11}
	pos2, werr2 := flat_file_write(&mgr, small_data)
	testing.expect_value(t, werr2, Storage_Error.None)
	testing.expect_value(t, pos2.file_num, u32(1))
	testing.expect_value(t, pos2.offset, u32(0))

	// Read back from file 1
	read_data, rerr := flat_file_read(&mgr, pos2, u32(len(small_data)), context.temp_allocator)
	testing.expect_value(t, rerr, Storage_Error.None)
	for i in 0 ..< len(small_data) {
		testing.expect(t, read_data[i] == small_data[i], fmt.tprintf("rollover byte %d", i))
	}
}

// --- Block DB tests ---

@(test)
test_block_db_store_read :: proc(t: ^testing.T) {
	dir := make_test_dir("blockdb_sr")
	defer remove_test_dir(dir)

	db, err := block_db_open(dir, wire.REGTEST_MAGIC)
	testing.expect_value(t, err, Storage_Error.None)
	defer block_db_close(&db)

	block := make_test_block(1)
	expected_hash := wire.block_header_hash(&block.header)

	loc, serr := block_db_store(&db, &block)
	testing.expect_value(t, serr, Storage_Error.None)
	testing.expect_value(t, loc.file_num, u32(0))

	// Read back
	read_block, rerr := block_db_read(&db, loc, context.temp_allocator)
	testing.expect_value(t, rerr, Storage_Error.None)

	// Verify header hash matches
	read_hash := wire.block_header_hash(&read_block.header)
	testing.expect(t, read_hash == expected_hash, "block hash mismatch")
	testing.expect_value(t, len(read_block.txs), 1)
}

@(test)
test_block_db_multiple_blocks :: proc(t: ^testing.T) {
	dir := make_test_dir("blockdb_multi")
	defer remove_test_dir(dir)

	db, err := block_db_open(dir, wire.REGTEST_MAGIC)
	testing.expect_value(t, err, Storage_Error.None)
	defer block_db_close(&db)

	// Store several blocks
	NUM_BLOCKS :: 5
	locs: [NUM_BLOCKS]Block_Location
	hashes: [NUM_BLOCKS]Hash256

	for i in 0 ..< NUM_BLOCKS {
		block := make_test_block(i + 1)
		hashes[i] = wire.block_header_hash(&block.header)
		loc, serr := block_db_store(&db, &block)
		testing.expect_value(t, serr, Storage_Error.None)
		locs[i] = loc
	}

	// Read each back and verify
	for i in 0 ..< NUM_BLOCKS {
		read_block, rerr := block_db_read(&db, locs[i], context.temp_allocator)
		testing.expect_value(t, rerr, Storage_Error.None)
		read_hash := wire.block_header_hash(&read_block.header)
		testing.expect(t, read_hash == hashes[i], fmt.tprintf("block %d hash mismatch", i))
	}
}

// --- LevelDB tests ---

@(test)
test_ldb_open_close :: proc(t: ^testing.T) {
	dir := make_test_dir("ldb_oc")
	defer remove_test_dir(dir)

	store, err := ldb_open(dir)
	testing.expect_value(t, err, Storage_Error.None)
	testing.expect(t, store.chainstate_db != nil, "chainstate_db should not be nil")
	testing.expect(t, store.index_db != nil, "index_db should not be nil")
	ldb_close(&store)
}

@(test)
test_ldb_put_get_del :: proc(t: ^testing.T) {
	dir := make_test_dir("ldb_pgd")
	defer remove_test_dir(dir)

	store, err := ldb_open(dir)
	testing.expect_value(t, err, Storage_Error.None)
	defer ldb_close(&store)

	key := []byte{0x01, 0x02, 0x03, 0x04}
	value := []byte{0xDE, 0xAD, 0xBE, 0xEF}

	// Put
	perr := ldb_put(store.chainstate_db, store.write_opts, key, value)
	testing.expect_value(t, perr, Storage_Error.None)

	// Get
	got, found := ldb_get(store.chainstate_db, store.read_opts, key, context.temp_allocator)
	testing.expect(t, found, "key should be found")
	testing.expect_value(t, len(got), 4)
	for i in 0 ..< 4 {
		testing.expect(t, got[i] == value[i], fmt.tprintf("value byte %d", i))
	}

	// Delete
	derr := ldb_del(store.chainstate_db, store.write_opts, key)
	testing.expect_value(t, derr, Storage_Error.None)

	// Verify gone
	_, found2 := ldb_get(store.chainstate_db, store.read_opts, key, context.temp_allocator)
	testing.expect(t, !found2, "key should be gone after delete")
}

@(test)
test_ldb_persistence :: proc(t: ^testing.T) {
	dir := make_test_dir("ldb_persist")
	defer remove_test_dir(dir)

	key := []byte{0xAA, 0xBB}
	value := []byte{0x11, 0x22, 0x33}

	// Write and close
	{
		store, err := ldb_open(dir)
		testing.expect_value(t, err, Storage_Error.None)

		ldb_put(store.chainstate_db, store.sync_opts, key, value)
		ldb_close(&store)
	}

	// Reopen and verify
	{
		store, err := ldb_open(dir)
		testing.expect_value(t, err, Storage_Error.None)
		defer ldb_close(&store)

		got, found := ldb_get(store.chainstate_db, store.read_opts, key, context.temp_allocator)
		testing.expect(t, found, "key should persist after reopen")
		testing.expect_value(t, len(got), 3)
		testing.expect(t, got[0] == 0x11 && got[1] == 0x22 && got[2] == 0x33, "value mismatch")
	}
}

// --- Index DB tests ---

@(test)
test_index_db_put_get :: proc(t: ^testing.T) {
	dir := make_test_dir("indexdb_pg")
	defer remove_test_dir(dir)

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)
	defer ldb_close(&store)

	db, err := index_db_init(&store)
	testing.expect_value(t, err, Storage_Error.None)
	defer index_db_close(&db)

	hash: Hash256
	hash[0] = 0x42
	hash[31] = 0xFF

	record := Block_Index_Record {
		hash        = hash,
		height      = 100,
		file_num    = 0,
		data_offset = 8,
		data_size   = 256,
		version     = 0x20000000,
		timestamp   = 1231006505,
		bits        = 0x207fffff,
		nonce       = 42,
		status      = {.Has_Data, .Valid_Header},
	}

	perr := index_db_put(&db, record)
	testing.expect_value(t, perr, Storage_Error.None)

	// Get it back
	rec_ptr, found := index_db_get(&db, hash)
	testing.expect(t, found, "record should be found")
	testing.expect_value(t, rec_ptr.height, i32(100))
	testing.expect_value(t, rec_ptr.nonce, u32(42))
	testing.expect(t, .Has_Data in rec_ptr.status, "should have Has_Data flag")
	testing.expect(t, .Valid_Header in rec_ptr.status, "should have Valid_Header flag")

	testing.expect_value(t, index_db_count(&db), 1)
}

@(test)
test_index_db_persistence :: proc(t: ^testing.T) {
	dir := make_test_dir("indexdb_persist")
	defer remove_test_dir(dir)

	hash1: Hash256
	hash1[0] = 0x01
	hash2: Hash256
	hash2[0] = 0x02

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)

	// Open, write, close
	{
		db, err := index_db_init(&store)
		testing.expect_value(t, err, Storage_Error.None)

		index_db_put(&db, Block_Index_Record{hash = hash1, height = 1, timestamp = 100})
		index_db_put(&db, Block_Index_Record{hash = hash2, height = 2, timestamp = 200})

		testing.expect_value(t, index_db_count(&db), 2)
		index_db_close(&db)
	}

	ldb_close(&store)

	// Reopen and verify
	store2, serr2 := ldb_open(dir)
	testing.expect_value(t, serr2, Storage_Error.None)
	defer ldb_close(&store2)

	{
		db, err := index_db_init(&store2)
		testing.expect_value(t, err, Storage_Error.None)
		defer index_db_close(&db)

		testing.expect_value(t, index_db_count(&db), 2)

		rec1, found1 := index_db_get(&db, hash1)
		testing.expect(t, found1, "hash1 should survive reopen")
		testing.expect_value(t, rec1.height, i32(1))
		testing.expect_value(t, rec1.timestamp, u32(100))

		rec2, found2 := index_db_get(&db, hash2)
		testing.expect(t, found2, "hash2 should survive reopen")
		testing.expect_value(t, rec2.height, i32(2))
	}
}

@(test)
test_index_db_overwrite :: proc(t: ^testing.T) {
	dir := make_test_dir("indexdb_ow")
	defer remove_test_dir(dir)

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)
	defer ldb_close(&store)

	db, err := index_db_init(&store)
	testing.expect_value(t, err, Storage_Error.None)
	defer index_db_close(&db)

	hash: Hash256
	hash[0] = 0xAA

	// Insert initial record
	index_db_put(&db, Block_Index_Record{hash = hash, height = 10, status = {.Valid_Header}})

	// Overwrite with updated status
	index_db_put(&db, Block_Index_Record{hash = hash, height = 10, status = {.Valid_Header, .Has_Data, .Valid_Transactions}})

	// Only 1 unique record
	testing.expect_value(t, index_db_count(&db), 1)

	rec, found := index_db_get(&db, hash)
	testing.expect(t, found, "should find record")
	testing.expect(t, .Has_Data in rec.status, "should have Has_Data after overwrite")
	testing.expect(t, .Valid_Transactions in rec.status, "should have Valid_Transactions after overwrite")
}

// --- UTXO DB tests ---

@(test)
test_utxo_db_put_get :: proc(t: ^testing.T) {
	dir := make_test_dir("utxodb_pg")
	defer remove_test_dir(dir)

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)
	defer ldb_close(&store)

	db := utxo_db_init(&store)
	defer utxo_db_close(&db)

	outpoint := wire.Outpoint{index = 0}
	outpoint.hash[0] = 0x42

	script := []byte{0x76, 0xa9, 0x14}
	coin := UTXO_Coin {
		height      = 100,
		is_coinbase = true,
		amount      = 50_0000_0000,
		script      = script,
	}

	perr := utxo_db_put(&db, outpoint, coin)
	testing.expect_value(t, perr, Storage_Error.None)

	// Get it back
	got, found := utxo_db_get(&db, outpoint, context.temp_allocator)
	testing.expect(t, found, "coin should be found")
	testing.expect_value(t, got.height, u32(100))
	testing.expect(t, got.is_coinbase, "should be coinbase")
	testing.expect_value(t, got.amount, i64(50_0000_0000))
	testing.expect_value(t, len(got.script), 3)
	testing.expect(t, got.script[0] == 0x76, "script byte 0")
	testing.expect(t, got.script[1] == 0xa9, "script byte 1")
	testing.expect(t, got.script[2] == 0x14, "script byte 2")
}

@(test)
test_utxo_db_delete :: proc(t: ^testing.T) {
	dir := make_test_dir("utxodb_del")
	defer remove_test_dir(dir)

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)
	defer ldb_close(&store)

	db := utxo_db_init(&store)
	defer utxo_db_close(&db)

	outpoint := wire.Outpoint{index = 1}
	outpoint.hash[0] = 0x01

	coin := UTXO_Coin{height = 50, amount = 1000, script = []byte{0xac}}
	utxo_db_put(&db, outpoint, coin)

	// Delete
	derr := utxo_db_delete(&db, outpoint)
	testing.expect_value(t, derr, Storage_Error.None)

	// Should not be found
	_, found := utxo_db_get(&db, outpoint, context.temp_allocator)
	testing.expect(t, !found, "deleted UTXO should not be found")
}

@(test)
test_utxo_db_bulk :: proc(t: ^testing.T) {
	dir := make_test_dir("utxodb_bulk")
	defer remove_test_dir(dir)

	store, serr := ldb_open(dir)
	testing.expect_value(t, serr, Storage_Error.None)
	defer ldb_close(&store)

	db := utxo_db_init(&store)
	defer utxo_db_close(&db)

	// Insert 500 UTXOs
	NUM_INSERT :: 500
	NUM_DELETE :: 200

	for i in 0 ..< NUM_INSERT {
		outpoint: wire.Outpoint
		outpoint.hash[0] = byte(i)
		outpoint.hash[1] = byte(i >> 8)
		outpoint.index = u32(i)

		script := make([]byte, 25, context.temp_allocator)
		script[0] = 0x76
		script[24] = 0xac

		coin := UTXO_Coin {
			height      = u32(i),
			is_coinbase = i == 0,
			amount      = i64(i) * 1000,
			script      = script,
		}

		perr := utxo_db_put(&db, outpoint, coin)
		testing.expect_value(t, perr, Storage_Error.None)
	}

	testing.expect_value(t, utxo_db_count(&db), u32(NUM_INSERT))

	// Delete first 200
	for i in 0 ..< NUM_DELETE {
		outpoint: wire.Outpoint
		outpoint.hash[0] = byte(i)
		outpoint.hash[1] = byte(i >> 8)
		outpoint.index = u32(i)

		derr := utxo_db_delete(&db, outpoint)
		testing.expect_value(t, derr, Storage_Error.None)
	}

	testing.expect_value(t, utxo_db_count(&db), u32(NUM_INSERT - NUM_DELETE))

	// Verify deleted ones are gone
	for i in 0 ..< NUM_DELETE {
		outpoint: wire.Outpoint
		outpoint.hash[0] = byte(i)
		outpoint.hash[1] = byte(i >> 8)
		outpoint.index = u32(i)

		_, found := utxo_db_get(&db, outpoint, context.temp_allocator)
		testing.expect(t, !found, fmt.tprintf("UTXO %d should be deleted", i))
	}

	// Verify remaining ones exist
	for i in NUM_DELETE ..< NUM_INSERT {
		outpoint: wire.Outpoint
		outpoint.hash[0] = byte(i)
		outpoint.hash[1] = byte(i >> 8)
		outpoint.index = u32(i)

		coin, found := utxo_db_get(&db, outpoint, context.temp_allocator)
		testing.expect(t, found, fmt.tprintf("UTXO %d should exist", i))
		if found {
			testing.expect_value(t, coin.height, u32(i))
			testing.expect_value(t, coin.amount, i64(i) * 1000)
		}
	}
}

// --- LevelDB batch tests ---

@(test)
test_ldb_batch_operations :: proc(t: ^testing.T) {
	dir := make_test_dir("ldb_batch")
	defer remove_test_dir(dir)

	store, err := ldb_open(dir)
	testing.expect_value(t, err, Storage_Error.None)
	defer ldb_close(&store)

	// Create batch with multiple operations
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	ldb_batch_put(batch, []byte{0x01}, []byte{0xAA})
	ldb_batch_put(batch, []byte{0x02}, []byte{0xBB})
	ldb_batch_put(batch, []byte{0x03}, []byte{0xCC})

	// Not yet visible
	_, found_before := ldb_get(store.chainstate_db, store.read_opts, []byte{0x01}, context.temp_allocator)
	testing.expect(t, !found_before, "batch data should not be visible before write")

	// Write batch atomically
	werr := ldb_batch_write(store.chainstate_db, store.write_opts, batch)
	testing.expect_value(t, werr, Storage_Error.None)

	// Now all should be visible
	val1, f1 := ldb_get(store.chainstate_db, store.read_opts, []byte{0x01}, context.temp_allocator)
	testing.expect(t, f1, "key 0x01 should exist")
	testing.expect(t, len(val1) == 1 && val1[0] == 0xAA, "value 0x01")

	val2, f2 := ldb_get(store.chainstate_db, store.read_opts, []byte{0x02}, context.temp_allocator)
	testing.expect(t, f2, "key 0x02 should exist")
	testing.expect(t, len(val2) == 1 && val2[0] == 0xBB, "value 0x02")

	val3, f3 := ldb_get(store.chainstate_db, store.read_opts, []byte{0x03}, context.temp_allocator)
	testing.expect(t, f3, "key 0x03 should exist")
	testing.expect(t, len(val3) == 1 && val3[0] == 0xCC, "value 0x03")
}

@(test)
test_ldb_batch_with_delete :: proc(t: ^testing.T) {
	dir := make_test_dir("ldb_batch_del")
	defer remove_test_dir(dir)

	store, err := ldb_open(dir)
	testing.expect_value(t, err, Storage_Error.None)
	defer ldb_close(&store)

	// Pre-insert a key
	ldb_put(store.chainstate_db, store.write_opts, []byte{0x10}, []byte{0xFF})

	// Batch: add new key + delete existing key
	batch := ldb_batch_create()
	defer ldb_batch_destroy(batch)

	ldb_batch_put(batch, []byte{0x20}, []byte{0xEE})
	ldb_batch_delete(batch, []byte{0x10})

	werr := ldb_batch_write(store.chainstate_db, store.write_opts, batch)
	testing.expect_value(t, werr, Storage_Error.None)

	// New key should exist
	_, f1 := ldb_get(store.chainstate_db, store.read_opts, []byte{0x20}, context.temp_allocator)
	testing.expect(t, f1, "new key should exist after batch")

	// Old key should be deleted
	_, f2 := ldb_get(store.chainstate_db, store.read_opts, []byte{0x10}, context.temp_allocator)
	testing.expect(t, !f2, "deleted key should be gone after batch")
}

// --- Block DB raw storage test ---

@(test)
test_block_db_store_raw :: proc(t: ^testing.T) {
	dir := make_test_dir("blockdb_raw")
	defer remove_test_dir(dir)

	db, err := block_db_open(dir, wire.REGTEST_MAGIC)
	testing.expect_value(t, err, Storage_Error.None)
	defer block_db_close(&db)

	// Serialize a block to raw bytes, then store and read back
	block := make_test_block(1)
	expected_hash := wire.block_header_hash(&block.header)

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_block(&w, &block)
	raw_bytes := wire.writer_bytes(&w)

	loc, serr := block_db_store_raw(&db, raw_bytes)
	testing.expect_value(t, serr, Storage_Error.None)

	// Read it back as a block
	read_block, rerr := block_db_read(&db, loc, context.temp_allocator)
	testing.expect_value(t, rerr, Storage_Error.None)
	read_hash := wire.block_header_hash(&read_block.header)
	testing.expect(t, read_hash == expected_hash, "raw-stored block hash should match")
}
