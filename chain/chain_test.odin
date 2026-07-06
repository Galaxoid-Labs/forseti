package chain

import "../consensus"
import crypto "../crypto"
import "../storage"
import "../wire"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

import "core:mem"

// --- Test helpers ---

make_test_dir :: proc(name: string) -> string {
	rng := rand.uint64()
	path := fmt.tprintf("/tmp/btcnode_chain_%s_%x", name, rng)
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

	entries, _ := os.read_dir(dh, -1, context.allocator)
	defer {
		for &entry in entries {
			delete(entry.fullpath)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.type == .Directory {
			_remove_dir_contents(entry.fullpath)
			os.remove(entry.fullpath)
		} else {
			os.remove(entry.fullpath)
		}
	}
}

// Build a regtest block at a given height with prev_hash linkage.
make_chain_block :: proc(height: int, prev_hash: Hash256, params: ^consensus.Chain_Params) -> wire.Block {
	// Pay the real subsidy — regtest halves every 150 blocks, and long test
	// chains (e.g. pruning needs 288+) hit Bad_Coinbase_Value otherwise.
	cb := consensus.make_coinbase(height, value = consensus.get_block_subsidy(height, params))
	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	tx_id := wire.tx_id(&cb)
	merkle := crypto.merkle_root([]crypto.Hash256{tx_id})

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			prev_hash   = prev_hash,
			merkle_root = merkle,
			timestamp   = u32(1231006505 + height),
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}

	consensus.mine_block(&block, params)
	return block
}

// --- Tests ---

@(test)
test_connect_chain :: proc(t: ^testing.T) {
	dir := make_test_dir("connect_chain")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Build and connect 10 blocks
	NUM_BLOCKS :: 10
	prev_hash := HASH_ZERO

	for i in 0 ..< NUM_BLOCKS {
		block := make_chain_block(i, prev_hash, &params)
		aerr := accept_block(&cs, &block)
		testing.expect(t, aerr == .None, fmt.tprintf("accept block %d: %v", i, aerr))
		prev_hash = wire.block_header_hash(&block.header)
	}

	// Verify height and tip
	tip_hash, tip_height := chain_tip(&cs)
	testing.expect_value(t, tip_height, NUM_BLOCKS - 1)
	testing.expect(t, tip_hash == prev_hash, "tip hash should match last block")
	testing.expect_value(t, chain_height(&cs), NUM_BLOCKS - 1)

	// Verify coinbase UTXOs exist for each block
	for i in 0 ..< NUM_BLOCKS {
		block := make_chain_block(i, HASH_ZERO, &params) // reconstruct to get txid
		cb := block.txs[0]
		txid := wire.tx_id(&cb)
		op := wire.Outpoint{hash = txid, index = 0}
		coin, found := coins_cache_get(&cs.coins, op)
		testing.expect(t, found, fmt.tprintf("coinbase UTXO at height %d should exist", i))
		if found {
			testing.expect_value(t, coin.height, u32(i))
			testing.expect(t, coin.is_coinbase, "should be coinbase")
			testing.expect_value(t, coin.amount, consensus.get_block_subsidy(i, &params))
		}
	}
}

@(test)
test_bad_coinbase_value :: proc(t: ^testing.T) {
	dir := make_test_dir("bad_cb_value")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Create block 0 with inflated coinbase
	cb := consensus.make_coinbase(0)
	cb.outputs[0].value = 100 * consensus.COIN // 100 BTC instead of 50

	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb
	tx_id := wire.tx_id(&cb)
	merkle := crypto.merkle_root([]crypto.Hash256{tx_id})

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			prev_hash   = HASH_ZERO,
			merkle_root = merkle,
			timestamp   = 1231006505,
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}
	consensus.mine_block(&block, &params)

	aerr := accept_block(&cs, &block)
	testing.expect_value(t, aerr, Chain_Error.Bad_Coinbase_Value)
}

@(test)
test_inputs_unavailable :: proc(t: ^testing.T) {
	dir := make_test_dir("inputs_unavail")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Accept genesis block
	block0 := make_chain_block(0, HASH_ZERO, &params)
	accept_block(&cs, &block0)
	prev_hash := wire.block_header_hash(&block0.header)

	// Create block 1 with a tx spending a nonexistent UTXO
	cb := consensus.make_coinbase(1)

	// Fake tx spending nonexistent output
	fake_hash: Hash256
	fake_hash[0] = 0xFF
	fake_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	fake_inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{hash = fake_hash, index = 0},
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = 0xffffffff,
	}
	fake_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	fake_outputs[0] = wire.Tx_Out{value = 1000, script_pubkey = make([]byte, 0, context.temp_allocator)}
	fake_tx := wire.Tx{version = 1, inputs = fake_inputs, outputs = fake_outputs, locktime = 0}

	txs := make([]wire.Tx, 2, context.temp_allocator)
	txs[0] = cb
	txs[1] = fake_tx

	tx_ids := make([]crypto.Hash256, 2, context.temp_allocator)
	tx_ids[0] = wire.tx_id(&cb)
	tx_ids[1] = wire.tx_id(&fake_tx)
	merkle := crypto.merkle_root(tx_ids)

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			prev_hash   = prev_hash,
			merkle_root = merkle,
			timestamp   = u32(1231006506),
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}
	consensus.mine_block(&block, &params)

	aerr := accept_block(&cs, &block)
	testing.expect_value(t, aerr, Chain_Error.Inputs_Unavailable)
}

@(test)
test_coinbase_maturity :: proc(t: ^testing.T) {
	dir := make_test_dir("cb_maturity")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Build block 0
	block0 := make_chain_block(0, HASH_ZERO, &params)
	accept_block(&cs, &block0)

	// Get coinbase txid from block 0
	cb0 := block0.txs[0]
	cb0_txid := wire.tx_id(&cb0)

	prev_hash := wire.block_header_hash(&block0.header)

	// Try to spend coinbase at block 1 (only 1 confirmation, need 100)
	cb1 := consensus.make_coinbase(1)

	spend_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	spend_inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{hash = cb0_txid, index = 0},
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = 0xffffffff,
	}
	spend_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	spend_outputs[0] = wire.Tx_Out{value = 50 * consensus.COIN, script_pubkey = make([]byte, 0, context.temp_allocator)}
	spend_tx := wire.Tx{version = 1, inputs = spend_inputs, outputs = spend_outputs, locktime = 0}

	txs := make([]wire.Tx, 2, context.temp_allocator)
	txs[0] = cb1
	txs[1] = spend_tx

	tx_ids := make([]crypto.Hash256, 2, context.temp_allocator)
	tx_ids[0] = wire.tx_id(&cb1)
	tx_ids[1] = wire.tx_id(&spend_tx)
	merkle := crypto.merkle_root(tx_ids)

	block1 := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			prev_hash   = prev_hash,
			merkle_root = merkle,
			timestamp   = u32(1231006506),
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}
	consensus.mine_block(&block1, &params)

	aerr := accept_block(&cs, &block1)
	testing.expect_value(t, aerr, Chain_Error.Coinbase_Not_Mature)
}

@(test)
test_disconnect_block :: proc(t: ^testing.T) {
	dir := make_test_dir("disconnect")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Build 5 blocks
	NUM_BLOCKS :: 5
	blocks: [NUM_BLOCKS]wire.Block
	prev_hash := HASH_ZERO

	for i in 0 ..< NUM_BLOCKS {
		blocks[i] = make_chain_block(i, prev_hash, &params)
		aerr := accept_block(&cs, &blocks[i])
		testing.expect(t, aerr == .None, fmt.tprintf("accept block %d: %v", i, aerr))
		prev_hash = wire.block_header_hash(&blocks[i].header)
	}

	testing.expect_value(t, chain_height(&cs), NUM_BLOCKS - 1)

	// Disconnect the last block
	last_hash := wire.block_header_hash(&blocks[NUM_BLOCKS - 1].header)
	last_entry, found := cs.block_index.entries[last_hash]
	testing.expect(t, found, "last block entry should exist")

	derr := disconnect_block(&cs, &blocks[NUM_BLOCKS - 1], last_entry)
	testing.expect_value(t, derr, Chain_Error.None)

	// Height should be one less
	testing.expect_value(t, chain_height(&cs), NUM_BLOCKS - 2)

	// Last block's coinbase UTXO should be gone
	last_cb := blocks[NUM_BLOCKS - 1].txs[0]
	last_cb_txid := wire.tx_id(&last_cb)
	_, utxo_found := coins_cache_get(&cs.coins, wire.Outpoint{hash = last_cb_txid, index = 0})
	testing.expect(t, !utxo_found, "disconnected block's UTXO should be gone")

	// Previous block's coinbase UTXO should still exist
	prev_cb := blocks[NUM_BLOCKS - 2].txs[0]
	prev_cb_txid := wire.tx_id(&prev_cb)
	_, prev_found := coins_cache_get(&cs.coins, wire.Outpoint{hash = prev_cb_txid, index = 0})
	testing.expect(t, prev_found, "previous block's UTXO should still exist")
}

@(test)
test_duplicate_tx :: proc(t: ^testing.T) {
	dir := make_test_dir("dup_tx")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Create block with two identical non-coinbase txs
	// Since we can't easily make identical coinbase txs, we'll test the
	// duplicate txid check with identical txid entries in the seen map
	cb := consensus.make_coinbase(0)

	// Two identical transactions (same inputs/outputs = same txid)
	dup_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	dup_inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{index = 0},
		script_sig      = []byte{0x01, 0x00},
		sequence        = 0xffffffff,
	}
	dup_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	dup_outputs[0] = wire.Tx_Out{value = 0, script_pubkey = make([]byte, 0, context.temp_allocator)}

	tx1 := wire.Tx{version = 1, inputs = dup_inputs, outputs = dup_outputs, locktime = 0}
	tx2 := wire.Tx{version = 1, inputs = dup_inputs, outputs = dup_outputs, locktime = 0}

	txs := make([]wire.Tx, 3, context.temp_allocator)
	txs[0] = cb
	txs[1] = tx1
	txs[2] = tx2

	tx_ids := make([]crypto.Hash256, 3, context.temp_allocator)
	tx_ids[0] = wire.tx_id(&cb)
	tx_ids[1] = wire.tx_id(&tx1)
	tx_ids[2] = wire.tx_id(&tx2)
	merkle := crypto.merkle_root(tx_ids)

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			prev_hash   = HASH_ZERO,
			merkle_root = merkle,
			timestamp   = 1231006505,
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}
	consensus.mine_block(&block, &params)

	aerr := accept_block(&cs, &block)
	testing.expect_value(t, aerr, Chain_Error.Duplicate_Tx)
}

@(test)
test_chain_tip_tracking :: proc(t: ^testing.T) {
	dir := make_test_dir("tip_track")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Initially empty
	_, init_height := chain_tip(&cs)
	testing.expect_value(t, init_height, -1)

	// Add 3 blocks
	prev_hash := HASH_ZERO
	blocks: [3]wire.Block

	for i in 0 ..< 3 {
		blocks[i] = make_chain_block(i, prev_hash, &params)
		accept_block(&cs, &blocks[i])
		prev_hash = wire.block_header_hash(&blocks[i].header)

		tip_hash, tip_h := chain_tip(&cs)
		testing.expect_value(t, tip_h, i)
		testing.expect(t, tip_hash == prev_hash, fmt.tprintf("tip hash mismatch at height %d", i))
	}

	// Disconnect block 2
	hash2 := wire.block_header_hash(&blocks[2].header)
	entry2 := cs.block_index.entries[hash2]
	disconnect_block(&cs, &blocks[2], entry2)

	tip_hash, tip_h := chain_tip(&cs)
	testing.expect_value(t, tip_h, 1)
	expected_tip := wire.block_header_hash(&blocks[1].header)
	testing.expect(t, tip_hash == expected_tip, "tip should be block 1 after disconnect")
}

@(test)
test_accept_block_end_to_end :: proc(t: ^testing.T) {
	dir := make_test_dir("accept_e2e")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Build and accept a single block via accept_block
	block := make_chain_block(0, HASH_ZERO, &params)
	aerr := accept_block(&cs, &block)
	testing.expect_value(t, aerr, Chain_Error.None)

	// Verify it's in the block index
	hash := wire.block_header_hash(&block.header)
	entry, found := cs.block_index.entries[hash]
	testing.expect(t, found, "block should be in index")
	testing.expect_value(t, entry.height, 0)
	testing.expect(t, .Has_Data in entry.status, "should have data")
	testing.expect(t, .Valid_Header in entry.status, "should have valid header")
	testing.expect(t, .Valid_Transactions in entry.status, "should have valid txs")
	testing.expect(t, .Valid_Chain in entry.status, "should have valid chain")
	testing.expect(t, .Has_Undo in entry.status, "should have undo data")

	// Verify it can be read back from block DB
	loc := storage.Block_Location {
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	read_block, rerr := storage.block_db_read(&cs.block_db, loc, context.temp_allocator)
	testing.expect_value(t, rerr, storage.Storage_Error.None)
	read_hash := wire.block_header_hash(&read_block.header)
	testing.expect(t, read_hash == hash, "read block hash should match")
}

// Test that accept_block_header rejects headers with wrong difficulty bits.
@(test)
test_bad_difficulty_rejected :: proc(t: ^testing.T) {
	dir := make_test_dir("bad_diff")
	defer remove_test_dir(dir)

	// Use regtest-like params but with difficulty retargeting enabled.
	params := consensus.REGTEST_PARAMS
	params.pow_no_retargeting = false

	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Accept genesis (height 0)
	block0 := make_chain_block(0, HASH_ZERO, &params)
	aerr := accept_block(&cs, &block0)
	testing.expect(t, aerr == .None, fmt.tprintf("accept block 0: %v", aerr))
	hash0 := wire.block_header_hash(&block0.header)

	// Build a block at height 1 with wrong bits. Use a slightly harder difficulty
	// (0x207ffffe) that's still within pow_limit but != expected (0x207fffff).
	// Mine it so the hash meets the declared (harder) target.
	block1 := make_chain_block(1, hash0, &params)
	block1.header.bits = 0x207ffffe
	consensus.mine_block(&block1, &params) // Re-mine with new bits

	_, herr := accept_block_header(&cs, &block1.header)
	testing.expect_value(t, herr, Chain_Error.Bad_Difficulty)
}

// Test the testnet 20-minute minimum difficulty rule.
@(test)
test_testnet_min_difficulty :: proc(t: ^testing.T) {
	dir := make_test_dir("min_diff")
	defer remove_test_dir(dir)

	// Use regtest-like params with min difficulty enabled (like testnet).
	params := consensus.REGTEST_PARAMS
	params.pow_no_retargeting = false
	params.allow_min_difficulty = true

	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Accept genesis (height 0)
	block0 := make_chain_block(0, HASH_ZERO, &params)
	aerr := accept_block(&cs, &block0)
	testing.expect(t, aerr == .None, fmt.tprintf("accept block 0: %v", aerr))
	hash0 := wire.block_header_hash(&block0.header)

	// Build block at height 1 with timestamp > prev + 20min.
	// This should accept pow_limit_bits via the 20-minute rule.
	base_time := u32(1231006505)
	delayed_time := base_time + params.target_spacing * 2 + 1 // >20 minutes after block 0

	block1 := make_chain_block(1, hash0, &params)
	block1.header.timestamp = delayed_time
	// block already has pow_limit_bits — re-mine with new timestamp
	consensus.mine_block(&block1, &params)

	aerr1 := accept_block(&cs, &block1)
	testing.expect(t, aerr1 == .None, fmt.tprintf("accept delayed block 1: %v", aerr1))
	hash1 := wire.block_header_hash(&block1.header)

	// Now build block 2 with normal timestamp (not delayed).
	// Should still accept pow_limit_bits because parent had pow_limit_bits
	// and the walk-back finds genesis which also has pow_limit_bits.
	normal_time := delayed_time + 60 // 1 minute later, not delayed
	block2 := make_chain_block(2, hash1, &params)
	block2.header.timestamp = normal_time
	consensus.mine_block(&block2, &params)

	aerr2 := accept_block(&cs, &block2)
	testing.expect(t, aerr2 == .None, fmt.tprintf("accept normal block 2: %v", aerr2))
}

// --- Coins cache unit tests ---

// Create a coins cache backed by a real UTXO DB for testing.
_make_test_coins_cache :: proc(dir: string, budget: int = 100 * 1024 * 1024) -> (Coins_Cache, ^storage.UTXO_DB, ^storage.LDB_Store) {
	os.make_directory(dir)
	store := new(storage.LDB_Store)
	store^ , _ = storage.ldb_open(dir)
	db := new(storage.UTXO_DB)
	db^ = storage.utxo_db_init(store)
	cc := coins_cache_init(db, budget)
	return cc, db, store
}

_cleanup_test_coins :: proc(cc: ^Coins_Cache, db: ^storage.UTXO_DB, store: ^storage.LDB_Store) {
	coins_cache_destroy(cc)
	storage.utxo_db_close(db)
	storage.ldb_close(store)
	free(db)
	free(store)
}

@(test)
test_coins_cache_add_get :: proc(t: ^testing.T) {
	dir := make_test_dir("coins_ag")
	defer remove_test_dir(dir)

	cc, db, store := _make_test_coins_cache(dir)
	defer _cleanup_test_coins(&cc, db, store)

	op := wire.Outpoint{index = 0}
	op.hash[0] = 0xAA

	script := []byte{0x76, 0xa9, 0x14} // P2PKH prefix
	coin := storage.UTXO_Coin{
		height      = 100,
		is_coinbase = true,
		amount      = 50 * consensus.COIN,
		script      = script,
	}

	// Add and retrieve
	coins_cache_add(&cc, op, coin)
	got, found := coins_cache_get(&cc, op)
	testing.expect(t, found, "added coin should be found")
	testing.expect_value(t, got.height, u32(100))
	testing.expect(t, got.is_coinbase, "should be coinbase")
	testing.expect_value(t, got.amount, i64(50 * consensus.COIN))
	testing.expect_value(t, len(got.script), 3)

	// Has check
	testing.expect(t, coins_cache_has(&cc, op), "should have the coin")

	// Non-existent coin
	op2 := wire.Outpoint{index = 1}
	op2.hash[0] = 0xBB
	_, not_found := coins_cache_get(&cc, op2)
	testing.expect(t, !not_found, "non-existent coin should not be found")
	testing.expect(t, !coins_cache_has(&cc, op2), "should not have non-existent coin")
}

@(test)
test_coins_cache_spend :: proc(t: ^testing.T) {
	dir := make_test_dir("coins_sp")
	defer remove_test_dir(dir)

	cc, db, store := _make_test_coins_cache(dir)
	defer _cleanup_test_coins(&cc, db, store)

	op := wire.Outpoint{index = 0}
	op.hash[0] = 0xCC

	coin := storage.UTXO_Coin{
		height      = 50,
		is_coinbase = false,
		amount      = 1000,
		script      = []byte{0x00, 0x14},
	}

	coins_cache_add(&cc, op, coin)

	// Spend it
	spent, ok := coins_cache_spend(&cc, op)
	testing.expect(t, ok, "spend should succeed")
	testing.expect_value(t, spent.amount, i64(1000))
	testing.expect_value(t, spent.height, u32(50))

	// After spending, it should not be found (Fresh coin is fully removed)
	_, found_after := coins_cache_get(&cc, op)
	testing.expect(t, !found_after, "spent Fresh coin should be gone")

	// Double-spend should fail
	_, ok2 := coins_cache_spend(&cc, op)
	testing.expect(t, !ok2, "double-spend should fail")
}

@(test)
test_coins_cache_restore :: proc(t: ^testing.T) {
	dir := make_test_dir("coins_rst")
	defer remove_test_dir(dir)

	cc, db, store := _make_test_coins_cache(dir)
	defer _cleanup_test_coins(&cc, db, store)

	op := wire.Outpoint{index = 0}
	op.hash[0] = 0xDD

	coin := storage.UTXO_Coin{
		height      = 75,
		is_coinbase = true,
		amount      = 25 * consensus.COIN,
		script      = []byte{0x51, 0x20}, // P2TR prefix
	}

	// Add, spend, then restore
	coins_cache_add(&cc, op, coin)
	coins_cache_spend(&cc, op)

	// After spend of Fresh coin, it's fully removed
	_, gone := coins_cache_get(&cc, op)
	testing.expect(t, !gone, "should be gone after spend")

	// Restore it
	coins_cache_restore(&cc, op, coin)
	got, found := coins_cache_get(&cc, op)
	testing.expect(t, found, "restored coin should be found")
	testing.expect_value(t, got.amount, i64(25 * consensus.COIN))
	testing.expect_value(t, got.height, u32(75))
}

@(test)
test_coins_cache_memory_tracking :: proc(t: ^testing.T) {
	dir := make_test_dir("coins_mem")
	defer remove_test_dir(dir)

	cc, db, store := _make_test_coins_cache(dir, 100) // very small budget (< CACHE_ENTRY_OVERHEAD)
	defer _cleanup_test_coins(&cc, db, store)

	testing.expect_value(t, cc.mem_usage, 0)

	op := wire.Outpoint{index = 0}
	coin := storage.UTXO_Coin{amount = 100, script = []byte{0x00}}
	coins_cache_add(&cc, op, coin)

	testing.expect(t, cc.mem_usage > 0, "mem_usage should increase after add")

	// With small budget, should_flush should trigger
	testing.expect(t, coins_cache_should_flush(&cc), "should flush with small budget")
}

// --- Block index unit tests ---

@(test)
test_block_index_add_and_get :: proc(t: ^testing.T) {
	idx := block_index_init()
	defer block_index_destroy(&idx)

	// Add genesis
	genesis_hdr := wire.Block_Header{
		version   = 1,
		timestamp = 1296688602,
		bits      = 0x207fffff,
		nonce     = 2,
	}
	entry := block_index_add(&idx, &genesis_hdr, 0, {.Valid_Header})
	testing.expect(t, entry != nil, "entry should not be nil")
	testing.expect_value(t, entry.height, 0)
	testing.expect(t, idx.genesis == entry, "should be genesis")

	// Add child
	child_hdr := wire.Block_Header{
		version   = 1,
		prev_hash = entry.hash,
		timestamp = 1296689202,
		bits      = 0x207fffff,
		nonce     = 3,
	}
	child := block_index_add(&idx, &child_hdr, 1, {.Valid_Header})
	testing.expect_value(t, child.height, 1)
	testing.expect(t, child.prev == entry, "child should point to genesis")

	// Best header tracking
	testing.expect(t, idx.best_header == child, "best header should be child")

	// Duplicate add returns existing
	dup := block_index_add(&idx, &genesis_hdr, 0, {.Valid_Header})
	testing.expect(t, dup == entry, "duplicate add should return existing entry")
}

@(test)
test_block_index_skip_list :: proc(t: ^testing.T) {
	idx := block_index_init()
	defer block_index_destroy(&idx)

	// Build a chain of 100 blocks
	prev_hash := HASH_ZERO
	entries: [101]^Block_Index_Entry

	for i in 0 ..= 100 {
		hdr := wire.Block_Header{
			version   = 1,
			prev_hash = prev_hash,
			timestamp = u32(1296688602 + i * 600),
			bits      = 0x207fffff,
			nonce     = u32(i + 1),
		}
		entries[i] = block_index_add(&idx, &hdr, i, {.Valid_Header})
		prev_hash = entries[i].hash
	}

	// Test O(log n) ancestor lookup
	tip := entries[100]

	// Get genesis (height 0)
	ancestor0 := block_index_get_ancestor(tip, 0)
	testing.expect(t, ancestor0 != nil, "should find genesis")
	testing.expect_value(t, ancestor0.height, 0)
	testing.expect(t, ancestor0 == entries[0], "should be the same genesis entry")

	// Get height 50
	ancestor50 := block_index_get_ancestor(tip, 50)
	testing.expect(t, ancestor50 != nil, "should find height 50")
	testing.expect_value(t, ancestor50.height, 50)
	testing.expect(t, ancestor50 == entries[50], "should be the same entry at 50")

	// Get self
	self := block_index_get_ancestor(tip, 100)
	testing.expect(t, self == tip, "should return self at own height")

	// Out of range
	nil_result := block_index_get_ancestor(tip, 101)
	testing.expect(t, nil_result == nil, "above height should return nil")

	neg_result := block_index_get_ancestor(tip, -1)
	testing.expect(t, neg_result == nil, "negative height should return nil")

	// Nil entry
	nil_entry := block_index_get_ancestor(nil, 0)
	testing.expect(t, nil_entry == nil, "nil entry should return nil")
}

@(test)
test_block_index_to_record :: proc(t: ^testing.T) {
	idx := block_index_init()
	defer block_index_destroy(&idx)

	hdr := wire.Block_Header{
		version   = 0x20000000,
		timestamp = 1296688602,
		bits      = 0x207fffff,
		nonce     = 42,
	}
	entry := block_index_add(&idx, &hdr, 5, {.Valid_Header, .Has_Data})
	entry.file_num = 3
	entry.data_offset = 12345
	entry.data_size = 256
	entry.num_tx = 10

	rec := block_index_to_record(entry)
	testing.expect_value(t, rec.height, i32(5))
	testing.expect_value(t, rec.version, i32(0x20000000))
	testing.expect_value(t, rec.nonce, u32(42))
	testing.expect_value(t, rec.file_num, u32(3))
	testing.expect_value(t, rec.data_offset, u32(12345))
	testing.expect_value(t, rec.data_size, u32(256))
	testing.expect_value(t, rec.num_tx, u32(10))
	testing.expect(t, .Valid_Header in rec.status, "should have Valid_Header")
	testing.expect(t, .Has_Data in rec.status, "should have Has_Data")
}

// --- Median time past tests ---

@(test)
test_get_median_time_past :: proc(t: ^testing.T) {
	// Build a chain of 15 entries with known timestamps
	idx := block_index_init()
	defer block_index_destroy(&idx)

	entries: [15]^Block_Index_Entry
	prev_hash := HASH_ZERO

	// Timestamps: 100, 200, 300, ..., 1500
	for i in 0 ..< 15 {
		hdr := wire.Block_Header{
			version   = 1,
			prev_hash = prev_hash,
			timestamp = u32((i + 1) * 100),
			bits      = 0x207fffff,
			nonce     = u32(i + 1),
		}
		entries[i] = block_index_add(&idx, &hdr, i, {.Valid_Header})
		prev_hash = entries[i].hash
	}

	// MTP of entry at height 0 (only 1 block): median of [100] = 100
	testing.expect_value(t, get_median_time_past(entries[0]), u32(100))

	// MTP of entry at height 4 (5 blocks: 100,200,300,400,500): median = 300
	testing.expect_value(t, get_median_time_past(entries[4]), u32(300))

	// MTP of entry at height 10 (11 blocks: 100..1100): sorted median = 600
	testing.expect_value(t, get_median_time_past(entries[10]), u32(600))

	// MTP of entry at height 14 (11 blocks: 500..1500): sorted median = 1000
	testing.expect_value(t, get_median_time_past(entries[14]), u32(1000))
}

// --- BIP 113: is_tx_final with MTP in connect_block ---

@(test)
test_bip113_non_final_tx_rejected :: proc(t: ^testing.T) {
	dir := make_test_dir("bip113")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Build 2 blocks to establish chain (regtest csv_height=0, so BIP113 is active)
	prev_hash := HASH_ZERO
	for i in 0 ..< 2 {
		block := make_chain_block(i, prev_hash, &params)
		aerr := accept_block(&cs, &block)
		testing.expect(t, aerr == .None, fmt.tprintf("accept block %d: %v", i, aerr))
		prev_hash = wire.block_header_hash(&block.header)
	}

	// Create block 2 with a transaction that has a time-based locktime in the future.
	// The block timestamp can be anything, but MTP of the parent determines finality
	// after BIP113 activation. Use a locktime well above any possible MTP.
	cb := consensus.make_coinbase(2)
	future_locktime := u32(2_000_000_000) // far future time-based locktime

	// Non-final tx: locktime in future, non-final sequence
	nonfinal_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	nonfinal_inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{index = 0},
		script_sig      = []byte{0x01, 0x01},
		sequence        = 0xFFFFFFFE, // non-final
	}
	nonfinal_inputs[0].previous_output.hash[0] = 0xAA
	nonfinal_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	nonfinal_outputs[0] = wire.Tx_Out{value = 0, script_pubkey = make([]byte, 0, context.temp_allocator)}
	nonfinal_tx := wire.Tx{version = 1, inputs = nonfinal_inputs, outputs = nonfinal_outputs, locktime = future_locktime}

	txs := make([]wire.Tx, 2, context.temp_allocator)
	txs[0] = cb
	txs[1] = nonfinal_tx

	tx_ids := make([]crypto.Hash256, 2, context.temp_allocator)
	tx_ids[0] = wire.tx_id(&cb)
	tx_ids[1] = wire.tx_id(&nonfinal_tx)
	merkle := crypto.merkle_root(tx_ids)

	block := wire.Block{
		header = wire.Block_Header{
			version     = 0x20000000,
			prev_hash   = prev_hash,
			merkle_root = merkle,
			timestamp   = u32(1231006507),
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}
	consensus.mine_block(&block, &params)

	aerr := accept_block(&cs, &block)
	testing.expect_value(t, aerr, Chain_Error.Non_Final_Tx)
}

// --- Block subsidy test ---

@(test)
test_block_subsidy :: proc(t: ^testing.T) {
	params := consensus.REGTEST_PARAMS

	// First halving interval: 50 BTC
	testing.expect_value(t, consensus.get_block_subsidy(0, &params), i64(50 * consensus.COIN))
	testing.expect_value(t, consensus.get_block_subsidy(149, &params), i64(50 * consensus.COIN))

	// Regtest halves every 150 blocks
	testing.expect_value(t, consensus.get_block_subsidy(150, &params), i64(25 * consensus.COIN))
	testing.expect_value(t, consensus.get_block_subsidy(299, &params), i64(25 * consensus.COIN))
	testing.expect_value(t, consensus.get_block_subsidy(300, &params), i64(12_5000_0000))

	// Eventually goes to zero
	testing.expect_value(t, consensus.get_block_subsidy(150 * 64, &params), i64(0))
}

// --- BIP 158 block filter tests ---

@(test)
test_build_basic_filter :: proc(t: ^testing.T) {
	// Build a block with a coinbase tx that has a P2PKH output.
	cb_script := []byte{0x76, 0xa9, 0x14, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x88, 0xac}
	cb_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	cb_inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{hash = HASH_ZERO, index = 0xffffffff},
		script_sig = []byte{0x04, 0xff, 0xff},
		sequence = 0xffffffff,
	}
	cb_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	cb_outputs[0] = wire.Tx_Out{value = 50_0000_0000, script_pubkey = cb_script}

	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = wire.Tx{version = 1, inputs = cb_inputs, outputs = cb_outputs, locktime = 0}

	block := wire.Block{
		header = wire.Block_Header{version = 1, timestamp = 1000, bits = 0x207fffff, nonce = 1},
		txs = txs,
	}
	block_hash := wire.block_header_hash(&block.header)

	// No spent scripts for coinbase-only block.
	filter, filter_hash, n := build_basic_filter(&block, block_hash, nil, context.temp_allocator)
	testing.expect(t, len(filter) > 0, "filter should not be empty for block with P2PKH output")
	testing.expect(t, filter_hash != HASH_ZERO, "filter hash should not be zero")
	testing.expect_value(t, n, u64(1))

	// Verify the script matches the filter.
	matched := crypto.gcs_match_any_n(block_hash, filter, n, [][]byte{cb_script})
	testing.expect(t, matched, "coinbase scriptPubKey should match filter")

	// OP_RETURN should be excluded.
	op_return_script := []byte{0x6a, 0x04, 0xde, 0xad}
	txs2 := make([]wire.Tx, 2, context.temp_allocator)
	txs2[0] = txs[0]
	cb2_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	cb2_outputs[0] = wire.Tx_Out{value = 0, script_pubkey = op_return_script}
	txs2[1] = wire.Tx{version = 1, inputs = cb_inputs, outputs = cb2_outputs, locktime = 0}
	block2 := wire.Block{
		header = wire.Block_Header{version = 1, timestamp = 1001, bits = 0x207fffff, nonce = 2},
		txs = txs2,
	}
	block_hash2 := wire.block_header_hash(&block2.header)
	filter2, _, n2 := build_basic_filter(&block2, block_hash2, nil, context.temp_allocator)
	// OP_RETURN excluded, only coinbase P2PKH output
	testing.expect_value(t, n2, u64(1))

	// OP_RETURN shouldn't match
	not_matched := crypto.gcs_match_any_n(block_hash2, filter2, n2, [][]byte{op_return_script})
	testing.expect(t, !not_matched, "OP_RETURN script should not match filter")
}

@(test)
test_compute_filter_header_chain :: proc(t: ^testing.T) {
	// Chain 3 filter headers: genesis → block1 → block2.
	// Genesis filter header uses zero prev.
	h0 := crypto.sha256d([]byte{0x01, 0x02}) // fake filter hash for genesis
	header0 := compute_filter_header(h0, HASH_ZERO)
	testing.expect(t, header0 != HASH_ZERO, "genesis filter header should not be zero")

	h1 := crypto.sha256d([]byte{0x03, 0x04})
	header1 := compute_filter_header(h1, header0)
	testing.expect(t, header1 != HASH_ZERO, "block1 filter header should not be zero")
	testing.expect(t, header1 != header0, "different blocks should have different headers")

	h2 := crypto.sha256d([]byte{0x05, 0x06})
	header2 := compute_filter_header(h2, header1)
	testing.expect(t, header2 != header1, "block2 filter header should differ from block1")

	// Same filter hash but different prev should give different header.
	header1_alt := compute_filter_header(h1, HASH_ZERO)
	testing.expect(t, header1_alt != header1, "same filter hash with different prev should differ")
}

@(test)
test_prune_block_files :: proc(t: ^testing.T) {
	dir := make_test_dir("prune")
	defer remove_test_dir(dir)

	params := consensus.REGTEST_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params, prune_target = 1) // prune aggressively
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)

	// Connect 400 blocks (comfortably past MIN_BLOCKS_TO_KEEP = 288).
	NUM :: 400
	prev_hash := HASH_ZERO
	for i in 0 ..< NUM {
		block := make_chain_block(i, prev_hash, &params)
		aerr := accept_block(&cs, &block)
		testing.expect(t, aerr == .None, fmt.tprintf("accept block %d: %v", i, aerr))
		prev_hash = wire.block_header_hash(&block.header)
	}

	// All blocks landed in file 0 — the active write file is never pruned.
	fd0, fr0 := prune_block_files(&cs, NUM - 1)
	testing.expect_value(t, fd0, 0)
	testing.expect_value(t, fr0, 0)

	// Simulate a file rollover: heights <= 100 belong to file 0, the rest to
	// file 1 (now the active file). This mirrors a real rollover without
	// writing 128MB in a test.
	for _, entry in cs.block_index.entries {
		if .Has_Data not_in entry.status { continue }
		entry.file_num = entry.height <= 100 ? 0 : 1
	}
	cs.block_db.files.current_file = 1
	cs.undo_files.current_file = 1

	// prune_height = min(399-288, flushed=399) = 111 > file 0 max (100) → prunable.
	blk0 := fmt.tprintf("%s/blocks/blk00000.dat", dir)
	testing.expect(t, os.exists(blk0), "blk00000.dat should exist before prune")

	fd, freed := prune_block_files(&cs, NUM - 1)
	testing.expect_value(t, fd, 1)
	testing.expect(t, freed > 0, "should free bytes")
	testing.expect(t, !os.exists(blk0), "blk00000.dat should be deleted")
	testing.expect(t, cs.prune_height == 101, fmt.tprintf("prune_height should be 101, got %d", cs.prune_height))

	// Index: heights <= 100 lost Has_Data, everything above kept it.
	for _, entry in cs.block_index.entries {
		if entry.height <= 100 && entry.height >= 0 {
			testing.expect(t, .Has_Data not_in entry.status, fmt.tprintf("height %d should be pruned", entry.height))
		} else if entry.height > 100 {
			testing.expect(t, .Has_Data in entry.status, fmt.tprintf("height %d should keep data", entry.height))
		}
	}

	// Second call: nothing left to prune (file 1 is active).
	fd2, _ := prune_block_files(&cs, NUM - 1)
	testing.expect_value(t, fd2, 0)
}
