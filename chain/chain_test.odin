package chain

import "../consensus"
import "../crypto"
import "../storage"
import "../wire"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

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

// Build a regtest block at a given height with prev_hash linkage.
make_chain_block :: proc(height: int, prev_hash: Hash256, params: ^consensus.Chain_Params) -> wire.Block {
	cb := consensus.make_coinbase(height)
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
