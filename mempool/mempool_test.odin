package mempool

import "../chain"
import "../consensus"
import "../crypto"
import "../wire"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

// --- Test helpers ---

_make_test_dir :: proc(name: string) -> string {
	rng := rand.uint64()
	path := fmt.tprintf("/tmp/btcnode_mempool_%s_%x", name, rng)
	os.make_directory(path)
	return path
}

_remove_test_dir :: proc(dir: string) {
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

// Build a coinbase tx with OP_TRUE output script for easy spending in tests.
_make_test_coinbase :: proc(height: int) -> wire.Tx {
	// BIP34 coinbase script: push height
	height_bytes: [4]byte
	height_bytes[0] = byte(height & 0xff)
	height_bytes[1] = byte((height >> 8) & 0xff)
	height_bytes[2] = byte((height >> 16) & 0xff)
	height_bytes[3] = byte((height >> 24) & 0xff)

	script_sig := make([]byte, 4, context.temp_allocator)
	script_sig[0] = 0x03 // push 3 bytes
	script_sig[1] = height_bytes[0]
	script_sig[2] = height_bytes[1]
	script_sig[3] = height_bytes[2]

	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{hash = wire.HASH_ZERO, index = 0xffffffff},
		script_sig      = script_sig,
		sequence        = 0xffffffff,
	}

	// OP_TRUE (OP_1) output — trivially spendable with empty script_sig
	script_pubkey := make([]byte, 1, context.temp_allocator)
	script_pubkey[0] = 0x51 // OP_1

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out {
		value         = consensus.get_block_subsidy(height, &consensus.REGTEST_PARAMS),
		script_pubkey = script_pubkey,
	}

	return wire.Tx {
		version  = 1,
		inputs   = inputs,
		outputs  = outputs,
		locktime = 0,
	}
}

// Build a regtest block at a given height.
_make_test_block :: proc(height: int, prev_hash: Hash256, params: ^consensus.Chain_Params) -> wire.Block {
	cb := _make_test_coinbase(height)
	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	tx_hash := wire.tx_id(&cb)
	merkle := crypto.merkle_root([]crypto.Hash256{tx_hash})

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

// Build a test chain with num_blocks blocks and return the mempool + chain state.
// Coinbase outputs use OP_TRUE scripts. Builds enough blocks for coinbase maturity.
_make_test_mempool :: proc(t: ^testing.T, name: string, num_blocks: int) -> (^Mempool, ^chain.Chain_State, ^consensus.Chain_Params, string) {
	dir := _make_test_dir(name)

	// Heap-allocate params so the pointer survives after this proc returns.
	params := new(consensus.Chain_Params)
	params^ = consensus.REGTEST_PARAMS

	cs := new(chain.Chain_State)
	err := chain.chain_state_init(cs, dir, params)
	testing.expect_value(t, err, chain.Chain_Error.None)

	prev_hash: Hash256
	for i in 0 ..< num_blocks {
		block := _make_test_block(i, prev_hash, params)
		aerr := chain.accept_block(cs, &block)
		testing.expect(t, aerr == .None, fmt.tprintf("accept block %d: %v", i, aerr))
		prev_hash = wire.block_header_hash(&block.header)
	}

	mp := new(Mempool)
	mempool_init(mp, cs, params)

	return mp, cs, params, dir
}

// Build a simple spending tx: spends outpoint (OP_TRUE UTXO), sends value to P2PKH output.
_make_spend_tx :: proc(outpoint: wire.Outpoint, input_value: i64, output_value: i64) -> wire.Tx {
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint,
		script_sig      = make([]byte, 0, context.temp_allocator), // empty script_sig for OP_TRUE
		sequence        = 0xffffffff,
	}

	// Standard P2PKH output: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
	script_pubkey := make([]byte, 25, context.temp_allocator)
	script_pubkey[0] = 0x76  // OP_DUP
	script_pubkey[1] = 0xa9  // OP_HASH160
	script_pubkey[2] = 0x14  // push 20 bytes
	// bytes 3..22 are zero (dummy pubkey hash)
	script_pubkey[23] = 0x88 // OP_EQUALVERIFY
	script_pubkey[24] = 0xac // OP_CHECKSIG

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = output_value, script_pubkey = script_pubkey}

	return wire.Tx{version = 1, inputs = inputs, outputs = outputs, locktime = 0}
}

// Get the coinbase txid for block at given height.
_get_coinbase_txid :: proc(height: int) -> Hash256 {
	cb := _make_test_coinbase(height)
	return wire.tx_id(&cb)
}

// --- Tests ---

@(test)
test_mempool_add_and_get :: proc(t: ^testing.T) {
	// Build 101 blocks so block 0's coinbase is mature (100 confirmations)
	mp, cs, params, dir := _make_test_mempool(t, "add_get", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	// Spend block 0's coinbase output
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)

	err := mempool_add(mp, &tx)
	testing.expect_value(t, err, Mempool_Error.None)

	// Verify it's retrievable
	txid := wire.tx_id(&tx)
	testing.expect(t, mempool_has(mp, txid), "tx should be in mempool")
	testing.expect_value(t, mempool_count(mp), 1)

	entry, found := mempool_get(mp, txid)
	testing.expect(t, found, "entry should exist")
	if found {
		testing.expect(t, entry.txid == txid, "txid should match")
		testing.expect(t, entry.fee == 1000, "fee should be 1000")
	}
}

@(test)
test_mempool_duplicate_tx :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "dup_tx", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)

	err1 := mempool_add(mp, &tx)
	testing.expect_value(t, err1, Mempool_Error.None)

	err2 := mempool_add(mp, &tx)
	testing.expect_value(t, err2, Mempool_Error.Tx_Already_Exists)
}

@(test)
test_mempool_double_spend :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "dbl_spend", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}
	// Disable fullrbf — double-spends rejected when original doesn't signal RBF
	mp.fullrbf = false

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// First tx spending the coinbase (sequence=0xffffffff, no RBF signal)
	tx1 := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Second tx spending the same coinbase — rejected (original doesn't signal RBF)
	tx2 := _make_spend_tx(outpoint, subsidy, subsidy - 2000)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_Not_Signaling)
}

@(test)
test_mempool_missing_inputs :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "miss_in", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	// Non-existent outpoint
	fake_hash: Hash256
	fake_hash[0] = 0xFF
	outpoint := wire.Outpoint{hash = fake_hash, index = 0}
	tx := _make_spend_tx(outpoint, 50 * consensus.COIN, 49 * consensus.COIN)

	err := mempool_add(mp, &tx)
	testing.expect_value(t, err, Mempool_Error.Missing_Inputs)
}

@(test)
test_mempool_coinbase_rejected :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "cb_reject", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	// Try to add a coinbase tx to mempool
	cb := _make_test_coinbase(999)
	err := mempool_add(mp, &cb)
	testing.expect_value(t, err, Mempool_Error.Coinbase_Not_Allowed)
}

@(test)
test_mempool_fee_ordering :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "fee_order", 104)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Add 3 txs with different fee rates using coinbases from blocks 0, 1, 2
	// (all matured since we built 104 blocks)
	fees := [3]i64{1000, 5000, 2000} // low, high, medium

	for i in 0 ..< 3 {
		cb_txid := _get_coinbase_txid(i)
		outpoint := wire.Outpoint{hash = cb_txid, index = 0}
		tx := _make_spend_tx(outpoint, subsidy, subsidy - fees[i])

		err := mempool_add(mp, &tx)
		testing.expect(t, err == .None, fmt.tprintf("add tx %d: %v", i, err))
	}

	testing.expect_value(t, mempool_count(mp), 3)

	// Get sorted — should be descending by fee rate
	sorted := mempool_get_sorted(mp, context.temp_allocator)
	testing.expect_value(t, len(sorted), 3)

	if len(sorted) == 3 {
		// All txs have same vsize, so fee ordering = fee rate ordering
		testing.expect(t, sorted[0].fee == 5000, fmt.tprintf("first should have highest fee, got %d", sorted[0].fee))
		testing.expect(t, sorted[1].fee == 2000, fmt.tprintf("second should have medium fee, got %d", sorted[1].fee))
		testing.expect(t, sorted[2].fee == 1000, fmt.tprintf("third should have lowest fee, got %d", sorted[2].fee))
	}
}

@(test)
test_mempool_remove_for_block :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rm_block", 103)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Add 2 txs to mempool
	txs: [2]wire.Tx
	for i in 0 ..< 2 {
		cb_txid := _get_coinbase_txid(i)
		outpoint := wire.Outpoint{hash = cb_txid, index = 0}
		txs[i] = _make_spend_tx(outpoint, subsidy, subsidy - 1000)

		err := mempool_add(mp, &txs[i])
		testing.expect(t, err == .None, fmt.tprintf("add tx %d: %v", i, err))
	}
	testing.expect_value(t, mempool_count(mp), 2)

	// Simulate a block containing these transactions
	block_txs := make([]wire.Tx, 2, context.temp_allocator)
	block_txs[0] = txs[0]
	block_txs[1] = txs[1]
	block := wire.Block{txs = block_txs}

	mempool_remove_for_block(mp, &block)
	testing.expect_value(t, mempool_count(mp), 0)
}

@(test)
test_mempool_policy_dust :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "dust", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}

	// Create a tx with a dust output (1 satoshi to P2PKH)
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = 0xffffffff,
	}

	// Standard P2PKH output with dust value
	script_pubkey := make([]byte, 25, context.temp_allocator)
	script_pubkey[0] = 0x76  // OP_DUP
	script_pubkey[1] = 0xa9  // OP_HASH160
	script_pubkey[2] = 0x14  // push 20 bytes
	script_pubkey[23] = 0x88 // OP_EQUALVERIFY
	script_pubkey[24] = 0xac // OP_CHECKSIG

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = 1, script_pubkey = script_pubkey} // 1 satoshi = dust

	tx := wire.Tx{version = 1, inputs = inputs, outputs = outputs, locktime = 0}

	err := mempool_add(mp, &tx)
	testing.expect_value(t, err, Mempool_Error.Non_Standard)
}

@(test)
test_fee_rate_comparison :: proc(t: ^testing.T) {
	// 10 sat / 100 vbytes vs 20 sat / 100 vbytes
	a := fee_rate(10, 100)
	b := fee_rate(20, 100)
	testing.expect(t, fee_rate_less(a, b), "10/100 should be less than 20/100")
	testing.expect(t, !fee_rate_less(b, a), "20/100 should not be less than 10/100")

	// 10 sat / 50 vbytes vs 10 sat / 100 vbytes (same fee, smaller tx = higher rate)
	c := fee_rate(10, 50)
	d := fee_rate(10, 100)
	testing.expect(t, fee_rate_less(d, c), "10/100 should be less than 10/50")
	testing.expect(t, !fee_rate_less(c, d), "10/50 should not be less than 10/100")

	// Per kVB conversion
	e := fee_rate(1000, 1000) // 1 sat/vB = 1000 sat/kvB
	testing.expect_value(t, fee_rate_per_kvb(e), i64(1000))
}

// --- RBF (BIP125) Tests ---

// Build a spending tx with configurable sequence for RBF signaling.
_make_spend_tx_seq :: proc(outpoint: wire.Outpoint, input_value: i64, output_value: i64, seq: u32) -> wire.Tx {
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = seq,
	}

	script_pubkey := make([]byte, 25, context.temp_allocator)
	script_pubkey[0] = 0x76  // OP_DUP
	script_pubkey[1] = 0xa9  // OP_HASH160
	script_pubkey[2] = 0x14  // push 20 bytes
	script_pubkey[23] = 0x88 // OP_EQUALVERIFY
	script_pubkey[24] = 0xac // OP_CHECKSIG

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = output_value, script_pubkey = script_pubkey}

	return wire.Tx{version = 1, inputs = inputs, outputs = outputs, locktime = 0}
}

// Build a spending tx with two inputs.
_make_spend_tx_2in :: proc(
	outpoint1: wire.Outpoint, outpoint2: wire.Outpoint,
	input_value: i64, output_value: i64, seq: u32,
) -> wire.Tx {
	inputs := make([]wire.Tx_In, 2, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint1,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = seq,
	}
	inputs[1] = wire.Tx_In {
		previous_output = outpoint2,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = seq,
	}

	script_pubkey := make([]byte, 25, context.temp_allocator)
	script_pubkey[0] = 0x76
	script_pubkey[1] = 0xa9
	script_pubkey[2] = 0x14
	script_pubkey[23] = 0x88
	script_pubkey[24] = 0xac

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = output_value, script_pubkey = script_pubkey}

	return wire.Tx{version = 1, inputs = inputs, outputs = outputs, locktime = 0}
}

@(test)
test_rbf_basic_replacement :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_basic", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: spends coinbase with 1000 sat fee
	tx1 := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	tx1_id := wire.tx_id(&tx1)
	testing.expect(t, mempool_has(mp, tx1_id), "tx1 should be in mempool")

	// Tx2: replacement with 5000 sat fee (higher)
	tx2 := _make_spend_tx(outpoint, subsidy, subsidy - 5000)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.None)

	tx2_id := wire.tx_id(&tx2)
	testing.expect(t, !mempool_has(mp, tx1_id), "tx1 should be evicted")
	testing.expect(t, mempool_has(mp, tx2_id), "tx2 should be in mempool")
	testing.expect_value(t, mempool_count(mp), 1)
}

@(test)
test_rbf_insufficient_fee :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_low_fee", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: 5000 sat fee
	tx1 := _make_spend_tx(outpoint, subsidy, subsidy - 5000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Tx2: only 1000 sat fee — less than tx1, should fail
	tx2 := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_Insufficient_Fee)
}

@(test)
test_rbf_fee_too_low_bandwidth :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_bw_fee", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: 1000 sat fee
	tx1 := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Tx2: 1001 sat fee — pays more, but only 1 sat additional.
	// For our ~85-byte tx, min_additional = (1000 * ~85) / 1000 = ~85 sat.
	// So 1 sat additional is not enough.
	tx2 := _make_spend_tx(outpoint, subsidy, subsidy - 1001)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_Fee_Too_Low)
}

@(test)
test_rbf_optin_signaling :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_optin", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}
	// Disable fullrbf for opt-in testing
	mp.fullrbf = false

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: sequence=0xffffffff (NOT signaling RBF)
	tx1 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 1000, 0xffffffff)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Tx2: tries to replace — should fail because tx1 doesn't signal
	tx2 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 5000, 0xffffffff)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_Not_Signaling)
}

@(test)
test_rbf_fullrbf_overrides_signaling :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_fullrbf", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}
	// fullrbf=true (default)
	testing.expect(t, mp.fullrbf, "fullrbf should default to true")

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: sequence=0xffffffff (NOT signaling) — should still be replaceable with fullrbf
	tx1 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 1000, 0xffffffff)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Tx2: replacement with higher fee — succeeds despite tx1 not signaling
	tx2 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 5000, 0xffffffff)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.None)

	tx1_id := wire.tx_id(&tx1)
	tx2_id := wire.tx_id(&tx2)
	testing.expect(t, !mempool_has(mp, tx1_id), "tx1 should be evicted")
	testing.expect(t, mempool_has(mp, tx2_id), "tx2 should be in mempool")
}

@(test)
test_rbf_evicts_descendants :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_desc", 103)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1 (parent): spends block 0 coinbase, creates standard P2PKH output
	cb0_txid := _get_coinbase_txid(0)
	outpoint0 := wire.Outpoint{hash = cb0_txid, index = 0}
	tx1 := _make_spend_tx(outpoint0, subsidy, subsidy - 1000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)
	tx1_id := wire.tx_id(&tx1)

	// Tx2 (child): spends block 1 coinbase (passes script verification)
	// but we manually wire it as a descendant by also recording a spent_outpoints
	// entry for tx1's output. Simulates a child that also spends tx1's output.
	cb1_txid := _get_coinbase_txid(1)
	outpoint1 := wire.Outpoint{hash = cb1_txid, index = 0}
	tx2 := _make_spend_tx(outpoint1, subsidy, subsidy - 1000)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.None)
	tx2_id := wire.tx_id(&tx2)

	// Manually add a spent_outpoints entry linking tx2 to tx1's output (descendant link)
	tx1_out0 := wire.Outpoint{hash = tx1_id, index = 0}
	mp.spent_outpoints[tx1_out0] = tx2_id

	testing.expect_value(t, mempool_count(mp), 2)

	// Tx3: replacement for Tx1 with higher fee — should evict both Tx1 and Tx2 (descendant)
	cb2_txid := _get_coinbase_txid(2)
	outpoint2 := wire.Outpoint{hash = cb2_txid, index = 0}
	// Tx3 spends same UTXO as Tx1 (block 0 coinbase) + block 2 coinbase for extra fee
	tx3 := _make_spend_tx(outpoint0, subsidy, subsidy - 5000)
	_ = outpoint2
	err3 := mempool_add(mp, &tx3)
	testing.expect_value(t, err3, Mempool_Error.None)

	tx3_id := wire.tx_id(&tx3)
	testing.expect(t, !mempool_has(mp, tx1_id), "tx1 should be evicted")
	testing.expect(t, !mempool_has(mp, tx2_id), "tx2 (descendant) should be evicted")
	testing.expect(t, mempool_has(mp, tx3_id), "tx3 should be in mempool")
	testing.expect_value(t, mempool_count(mp), 1)
}

@(test)
test_rbf_new_unconfirmed_parent :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_unconf", 103)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Add a parent tx to mempool (from block 0's coinbase) with standard P2PKH output
	cb0_txid := _get_coinbase_txid(0)
	parent_tx := _make_spend_tx(wire.Outpoint{hash = cb0_txid, index = 0}, subsidy, subsidy - 1000)
	perr := mempool_add(mp, &parent_tx)
	testing.expect_value(t, perr, Mempool_Error.None)
	parent_txid := wire.tx_id(&parent_tx)

	// Tx1: spends block 1's coinbase
	cb1_txid := _get_coinbase_txid(1)
	outpoint1 := wire.Outpoint{hash = cb1_txid, index = 0}
	tx1 := _make_spend_tx(outpoint1, subsidy, subsidy - 1000)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Manually insert a fake mempool output for the parent so the replacement
	// can find it during input resolution. The parent's P2PKH output has a dummy
	// pubkey hash, but we only need it to exist for the RBF "new unconfirmed" check.
	// The replacement will be rejected at the RBF check before script verification.
	unconf_outpoint := wire.Outpoint{hash = parent_txid, index = 0}

	// Tx2: replacement that spends same UTXO as tx1 PLUS parent's unconfirmed output
	// This introduces a new unconfirmed input not in tx1's inputs — should fail rule 2
	tx2 := _make_spend_tx_2in(outpoint1, unconf_outpoint, subsidy * 2, subsidy * 2 - 10000, 0xfffffffd)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_New_Unconfirmed)
}

@(test)
test_rbf_double_spend_rejected_without_rbf :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "rbf_no_rbf", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}
	// Disable fullrbf
	mp.fullrbf = false

	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Tx1: sequence=0xffffffff (no RBF signal)
	tx1 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 1000, 0xffffffff)
	err1 := mempool_add(mp, &tx1)
	testing.expect_value(t, err1, Mempool_Error.None)

	// Tx2: tries to replace with higher fee — rejected because tx1 doesn't signal
	tx2 := _make_spend_tx_seq(outpoint, subsidy, subsidy - 10000, 0xfffffffd)
	err2 := mempool_add(mp, &tx2)
	testing.expect_value(t, err2, Mempool_Error.RBF_Not_Signaling)

	// Original tx still in mempool
	tx1_id := wire.tx_id(&tx1)
	testing.expect(t, mempool_has(mp, tx1_id), "tx1 should still be in mempool")
	testing.expect_value(t, mempool_count(mp), 1)
}
