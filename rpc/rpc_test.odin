package rpc

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

import "../chain"
import "../consensus"
import crypto "../crypto"
import "../mempool"
import "../wire"

// --- Test helpers ---

_make_test_dir :: proc(name: string) -> string {
	rng := rand.uint64()
	path := fmt.tprintf("/tmp/btcnode_rpc_%s_%x", name, rng)
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
	defer {
		for &entry in entries {
			delete(entry.fullpath)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.is_dir {
			_remove_dir_contents(entry.fullpath)
			os.remove(entry.fullpath)
		} else {
			os.remove(entry.fullpath)
		}
	}
}

_make_test_coinbase :: proc(height: int) -> wire.Tx {
	height_bytes: [4]byte
	height_bytes[0] = byte(height & 0xff)
	height_bytes[1] = byte((height >> 8) & 0xff)
	height_bytes[2] = byte((height >> 16) & 0xff)
	height_bytes[3] = byte((height >> 24) & 0xff)

	script_sig := make([]byte, 4, context.temp_allocator)
	script_sig[0] = 0x03
	script_sig[1] = height_bytes[0]
	script_sig[2] = height_bytes[1]
	script_sig[3] = height_bytes[2]

	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{hash = wire.HASH_ZERO, index = 0xffffffff},
		script_sig      = script_sig,
		sequence        = 0xffffffff,
	}

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

_make_test_rpc_server :: proc(
	t: ^testing.T,
	name: string,
	num_blocks: int,
) -> (^RPC_Server, ^chain.Chain_State, ^mempool.Mempool, ^consensus.Chain_Params, string) {
	dir := _make_test_dir(name)

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

	mp := new(mempool.Mempool)
	mempool.mempool_init(mp, cs, params)

	srv := new(RPC_Server)
	rpc_server_init(srv, cs, mp, params, 0)

	return srv, cs, mp, params, dir
}

_cleanup_test :: proc(srv: ^RPC_Server, cs: ^chain.Chain_State, mp: ^mempool.Mempool, params: ^consensus.Chain_Params, dir: string) {
	mempool.mempool_destroy(mp)
	free(mp)
	chain.chain_state_destroy(cs)
	free(cs)
	free(params)
	free(srv)
	_remove_test_dir(dir)
}

_make_spend_tx :: proc(outpoint: wire.Outpoint, input_value: i64, output_value: i64) -> wire.Tx {
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = 0xffffffff,
	}

	// Standard P2PKH output
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

// Like _make_spend_tx but with OP_1 output script (trivially spendable).
// Allows building mempool chains without real signatures.
_make_spend_tx_op1 :: proc(outpoint: wire.Outpoint, input_value: i64, output_value: i64) -> wire.Tx {
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In {
		previous_output = outpoint,
		script_sig      = make([]byte, 0, context.temp_allocator),
		sequence        = 0xffffffff,
	}

	// OP_1 output (trivially spendable)
	script_pubkey := make([]byte, 1, context.temp_allocator)
	script_pubkey[0] = 0x51 // OP_1

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = output_value, script_pubkey = script_pubkey}

	return wire.Tx{version = 1, inputs = inputs, outputs = outputs, locktime = 0}
}

_get_coinbase_txid :: proc(height: int) -> Hash256 {
	cb := _make_test_coinbase(height)
	return wire.tx_id(&cb)
}

// Helper to build JSON params array.
_make_params :: proc(args: ..json.Value) -> json.Value {
	arr := make(json.Array, len(args), context.temp_allocator)
	for i in 0 ..< len(args) {
		arr[i] = args[i]
	}
	return json.Value(arr)
}

// --- Tests ---

@(test)
test_getblockcount :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blkcnt", 10)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getblockcount(srv, nil)

	err_val, has_err := resp.error.?
	testing.expect(t, !has_err, fmt.tprintf("unexpected error: %v", err_val))

	result, ok := resp.result.(json.Integer)
	testing.expect(t, ok, "result should be integer")
	testing.expect_value(t, int(result), 9) // 10 blocks = height 9
}

@(test)
test_getblockhash :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blkhash", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get genesis hash (height 0)
	p := _make_params(json.Value(json.Integer(0)))
	resp := _handle_getblockhash(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error for valid height")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be string")
	testing.expect(t, len(result) == 64, fmt.tprintf("hash should be 64 hex chars, got %d", len(result)))

	// Verify it matches the genesis in active_chain
	expected := _hash_to_hex(cs.active_chain[0])
	testing.expect(t, result == expected, fmt.tprintf("hash mismatch: got %s, expected %s", result, expected))
}

@(test)
test_getblockhash_invalid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blkhash_inv", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Out of range height
	p := _make_params(json.Value(json.Integer(999)))
	resp := _handle_getblockhash(srv, p)

	err_val, has_err := resp.error.?
	testing.expect(t, has_err, "should error for out-of-range height")
	if has_err {
		testing.expect_value(t, err_val.code, RPC_Error_Code.Block_Not_Found)
	}
}

@(test)
test_getbestblockhash :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "besthash", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getbestblockhash(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be string")

	// Should match the tip hash
	tip_hash, _ := chain.chain_tip(cs)
	expected := _hash_to_hex(tip_hash)
	testing.expect(t, result == expected, fmt.tprintf("tip hash mismatch: got %s, expected %s", result, expected))
}

@(test)
test_getblockchaininfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "chaininfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getblockchaininfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check chain name
	chain_name, name_ok := obj["chain"].(json.String)
	testing.expect(t, name_ok, "chain should be string")
	testing.expect(t, chain_name == "regtest", fmt.tprintf("chain name should be regtest, got %s", chain_name))

	// Check height
	blocks, blocks_ok := obj["blocks"].(json.Integer)
	testing.expect(t, blocks_ok, "blocks should be integer")
	testing.expect_value(t, int(blocks), 4)

	// Check headers >= blocks
	headers, headers_ok := obj["headers"].(json.Integer)
	testing.expect(t, headers_ok, "headers should be integer")
	testing.expect(t, headers >= blocks, fmt.tprintf("headers (%d) should be >= blocks (%d)", headers, blocks))

	// Check best block hash present
	_, hash_ok := obj["bestblockhash"].(json.String)
	testing.expect(t, hash_ok, "bestblockhash should be string")

	// Check difficulty present and positive
	diff, diff_ok := obj["difficulty"].(json.Float)
	testing.expect(t, diff_ok, "difficulty should be float")
	testing.expect(t, diff > 0, "difficulty should be positive")

	// Check time present
	_, time_ok := obj["time"].(json.Integer)
	testing.expect(t, time_ok, "time should be integer")

	// Check mediantime present
	_, mt_ok := obj["mediantime"].(json.Integer)
	testing.expect(t, mt_ok, "mediantime should be integer")

	// Check verificationprogress present
	vp, vp_ok := obj["verificationprogress"].(json.Float)
	testing.expect(t, vp_ok, "verificationprogress should be float")
	testing.expect(t, vp > 0.0 && vp <= 1.0, fmt.tprintf("verificationprogress should be 0..1, got %f", vp))

	// Check initialblockdownload present (should be false for regtest with 5 blocks)
	ibd, ibd_ok := obj["initialblockdownload"].(json.Boolean)
	testing.expect(t, ibd_ok, "initialblockdownload should be boolean")
	testing.expect(t, !ibd, "should not be in IBD for regtest with 5 blocks")

	// Check pruned present
	pruned, pruned_ok := obj["pruned"].(json.Boolean)
	testing.expect(t, pruned_ok, "pruned should be boolean")
	testing.expect(t, !pruned, "should not be pruned")

	// Check softforks matches Bitcoin Core format
	sf, sf_ok := obj["softforks"].(json.Object)
	testing.expect(t, sf_ok, "softforks should be object")
	if sf_ok {
		// Check segwit fork as representative example
		segwit, sw_ok := sf["segwit"].(json.Object)
		testing.expect(t, sw_ok, "softforks.segwit should be object")
		if sw_ok {
			stype, st_ok := segwit["type"].(json.String)
			testing.expect(t, st_ok, "segwit.type should be string")
			testing.expect(t, stype == "buried", fmt.tprintf("segwit.type should be 'buried', got '%s'", stype))

			active, a_ok := segwit["active"].(json.Boolean)
			testing.expect(t, a_ok, "segwit.active should be boolean")
			testing.expect(t, active, "segwit should be active on regtest")

			sh, sh_ok := segwit["height"].(json.Integer)
			testing.expect(t, sh_ok, "segwit.height should be integer")
			testing.expect_value(t, int(sh), 0) // regtest activates at 0
		}
	}
}

@(test)
test_getblock_verbose :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blk_verbose", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get block at height 2
	block_hash_hex := _hash_to_hex(cs.active_chain[2])
	p := _make_params(json.Value(json.String(block_hash_hex)), json.Value(json.Integer(1)))
	resp := _handle_getblock(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check hash
	hash_str, hash_ok := obj["hash"].(json.String)
	testing.expect(t, hash_ok, "hash should be string")
	testing.expect(t, hash_str == block_hash_hex, "hash should match requested")

	// Check height
	height, height_ok := obj["height"].(json.Integer)
	testing.expect(t, height_ok, "height should be integer")
	testing.expect_value(t, int(height), 2)

	// Check tx list
	tx_arr, tx_ok := obj["tx"].(json.Array)
	testing.expect(t, tx_ok, "tx should be array")
	if tx_ok {
		testing.expect(t, len(tx_arr) >= 1, "block should have at least 1 tx")
	}

	// Check confirmations (tip=4, block=2, confirmations=3)
	conf, conf_ok := obj["confirmations"].(json.Integer)
	testing.expect(t, conf_ok, "confirmations should be integer")
	testing.expect_value(t, int(conf), 3)

	// Check nTx
	ntx, ntx_ok := obj["nTx"].(json.Integer)
	testing.expect(t, ntx_ok, "nTx should be integer")
	testing.expect_value(t, int(ntx), 1) // just coinbase

	// Check new fields
	_, vh_ok := obj["versionHex"].(json.String)
	testing.expect(t, vh_ok, "versionHex should be string")

	_, diff_ok := obj["difficulty"].(json.Float)
	testing.expect(t, diff_ok, "difficulty should be float")

	_, mt_ok := obj["mediantime"].(json.Integer)
	testing.expect(t, mt_ok, "mediantime should be integer")

	ss, ss_ok := obj["strippedsize"].(json.Integer)
	testing.expect(t, ss_ok, "strippedsize should be integer")
	testing.expect(t, ss > 0, "strippedsize should be positive")
}

@(test)
test_getblock_raw :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blk_raw", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get block at height 0 with verbosity=0
	block_hash_hex := _hash_to_hex(cs.active_chain[0])
	p := _make_params(json.Value(json.String(block_hash_hex)), json.Value(json.Integer(0)))
	resp := _handle_getblock(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	testing.expect(t, len(result) > 0, "raw block hex should not be empty")

	// Verify it's valid hex (even length, all hex chars)
	testing.expect(t, len(result) % 2 == 0, "hex should be even length")
}

@(test)
test_sendrawtransaction :: proc(t: ^testing.T) {
	// Build 101 blocks for coinbase maturity
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "sendtx", 101)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Build a spending transaction
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)

	// Serialize to hex
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &tx)
	raw := wire.writer_bytes(&w)
	hex_str := _bytes_to_hex(raw)

	p := _make_params(json.Value(json.String(hex_str)))
	resp := _handle_sendrawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error on valid tx")

	// Result should be the txid
	txid_hex, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be txid hex string")
	testing.expect(t, len(txid_hex) == 64, "txid should be 64 hex chars")

	// Verify tx is in mempool
	testing.expect_value(t, mempool.mempool_count(mp), 1)
}

@(test)
test_sendrawtransaction_invalid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "sendtx_inv", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Bad hex
	p := _make_params(json.Value(json.String("not_valid_hex")))
	resp := _handle_sendrawtransaction(srv, p)

	err_val, has_err := resp.error.?
	testing.expect(t, has_err, "should error on bad hex")
	if has_err {
		testing.expect_value(t, err_val.code, RPC_Error_Code.Tx_Deser_Error)
	}
}

@(test)
test_getrawtransaction :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "getrawtx", 101)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Add a tx to the mempool
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	merr := mempool.mempool_add(mp, &tx)
	testing.expect(t, merr == .None, fmt.tprintf("mempool add: %v", merr))

	txid := wire.tx_id(&tx)
	txid_hex := _hash_to_hex(txid)

	// Non-verbose: returns hex string
	p := _make_params(json.Value(json.String(txid_hex)), json.Value(json.Boolean(false)))
	resp := _handle_getrawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	hex_result, hex_ok := resp.result.(json.String)
	testing.expect(t, hex_ok, "result should be hex string")
	testing.expect(t, len(hex_result) > 0, "hex should not be empty")

	// Verbose: returns object with txid field
	p2 := _make_params(json.Value(json.String(txid_hex)), json.Value(json.Boolean(true)))
	resp2 := _handle_getrawtransaction(srv, p2)

	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "verbose should not error")

	obj, obj_ok := resp2.result.(json.Object)
	testing.expect(t, obj_ok, "verbose result should be object")
	if obj_ok {
		result_txid, tid_ok := obj["txid"].(json.String)
		testing.expect(t, tid_ok, "should have txid field")
		testing.expect(t, result_txid == txid_hex, "txid should match")
	}

	// Not found: returns error
	p3 := _make_params(json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000099")))
	resp3 := _handle_getrawtransaction(srv, p3)
	_, has_err3 := resp3.error.?
	testing.expect(t, has_err3, "should error for missing tx")
}

@(test)
test_getmempoolinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "mpinfo", 103)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Add 2 txs
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	for i in 0 ..< 2 {
		cb_txid := _get_coinbase_txid(i)
		outpoint := wire.Outpoint{hash = cb_txid, index = 0}
		tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
		merr := mempool.mempool_add(mp, &tx)
		testing.expect(t, merr == .None, fmt.tprintf("mempool add %d: %v", i, merr))
	}

	resp := _handle_getmempoolinfo(srv, nil)
	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	size, size_ok := obj["size"].(json.Integer)
	testing.expect(t, size_ok, "size should be integer")
	testing.expect_value(t, int(size), 2)

	// Check new fields
	maxmp, maxmp_ok := obj["maxmempool"].(json.Integer)
	testing.expect(t, maxmp_ok, "maxmempool should be integer")
	testing.expect(t, maxmp > 0, "maxmempool should be positive")

	_, mfee_ok := obj["mempoolminfee"].(json.Float)
	testing.expect(t, mfee_ok, "mempoolminfee should be float")

	_, rfee_ok := obj["minrelaytxfee"].(json.Float)
	testing.expect(t, rfee_ok, "minrelaytxfee should be float")

	_, fullrbf_ok := obj["fullrbf"].(json.Boolean)
	testing.expect(t, fullrbf_ok, "fullrbf should be boolean")
}

@(test)
test_getrawmempool :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "rawmp", 103)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Add 1 tx
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	merr := mempool.mempool_add(mp, &tx)
	testing.expect(t, merr == .None, fmt.tprintf("mempool add: %v", merr))

	resp := _handle_getrawmempool(srv, nil)
	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if ok {
		testing.expect_value(t, len(arr), 1)
		// Verify it's a valid txid hex
		txid_str, str_ok := arr[0].(json.String)
		testing.expect(t, str_ok, "element should be string")
		if str_ok {
			testing.expect(t, len(txid_str) == 64, "txid should be 64 hex chars")
		}
	}
}

@(test)
test_gettxout :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txout", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get a confirmed UTXO — coinbase from block 0
	cb_txid := _get_coinbase_txid(0)
	txid_hex := _hash_to_hex(cb_txid)

	p := _make_params(json.Value(json.String(txid_hex)), json.Value(json.Integer(0)))
	resp := _handle_gettxout(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check confirmations (tip=4, coinbase at height 0, confirmations=5)
	conf, conf_ok := obj["confirmations"].(json.Integer)
	testing.expect(t, conf_ok, "confirmations should be integer")
	testing.expect_value(t, int(conf), 5)

	// Check coinbase flag
	is_cb, cb_ok := obj["coinbase"].(json.Boolean)
	testing.expect(t, cb_ok, "coinbase should be bool")
	testing.expect(t, is_cb, "should be a coinbase output")

	// Check scriptPubKey present
	_, spk_ok := obj["scriptPubKey"].(json.Object)
	testing.expect(t, spk_ok, "scriptPubKey should be object")

	// Check non-existent UTXO returns null
	fake_hash_hex := "0000000000000000000000000000000000000000000000000000000000000000"
	p2 := _make_params(json.Value(json.String(fake_hash_hex)), json.Value(json.Integer(0)))
	resp2 := _handle_gettxout(srv, p2)

	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "should not error for missing UTXO")
	_, is_null := resp2.result.(json.Null)
	testing.expect(t, is_null, "missing UTXO should return null")
}

// --- Phase 10 Tests ---

@(test)
test_getblockheader_verbose :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blkhdr_v", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get header at height 2
	block_hash_hex := _hash_to_hex(cs.active_chain[2])
	p := _make_params(json.Value(json.String(block_hash_hex)), json.Value(json.Boolean(true)))
	resp := _handle_getblockheader(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check hash
	hash_str, hash_ok := obj["hash"].(json.String)
	testing.expect(t, hash_ok, "hash should be string")
	testing.expect(t, hash_str == block_hash_hex, "hash should match requested")

	// Check height
	height, height_ok := obj["height"].(json.Integer)
	testing.expect(t, height_ok, "height should be integer")
	testing.expect_value(t, int(height), 2)

	// Check versionHex present
	_, vh_ok := obj["versionHex"].(json.String)
	testing.expect(t, vh_ok, "versionHex should be string")

	// Check difficulty present
	_, diff_ok := obj["difficulty"].(json.Float)
	testing.expect(t, diff_ok, "difficulty should be float")

	// Check mediantime present
	_, mt_ok := obj["mediantime"].(json.Integer)
	testing.expect(t, mt_ok, "mediantime should be integer")

	// Check confirmations
	conf, conf_ok := obj["confirmations"].(json.Integer)
	testing.expect(t, conf_ok, "confirmations should be integer")
	testing.expect_value(t, int(conf), 3) // tip=4, block=2
}

@(test)
test_getblockheader_raw :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blkhdr_r", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	block_hash_hex := _hash_to_hex(cs.active_chain[0])
	p := _make_params(json.Value(json.String(block_hash_hex)), json.Value(json.Boolean(false)))
	resp := _handle_getblockheader(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	// 80 bytes header = 160 hex chars
	testing.expect_value(t, len(result), 160)
}

@(test)
test_getdifficulty :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "diff", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getdifficulty(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.Float)
	testing.expect(t, ok, "result should be float")
	testing.expect(t, result > 0, "difficulty should be positive")
}

@(test)
test_getconnectioncount :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "conncount", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// cm is nil, should return 0
	resp := _handle_getconnectioncount(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.Integer)
	testing.expect(t, ok, "result should be integer")
	testing.expect_value(t, int(result), 0)
}

@(test)
test_getpeerinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "peerinfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// cm is nil, should return empty array
	resp := _handle_getpeerinfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if ok {
		testing.expect_value(t, len(arr), 0)
	}
}

@(test)
test_getnetworkinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "netinfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getnetworkinfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	subver, sv_ok := obj["subversion"].(json.String)
	testing.expect(t, sv_ok, "subversion should be string")
	testing.expect(t, subver == wire.NODE_USER_AGENT, "subversion should match")

	pv, pv_ok := obj["protocolversion"].(json.Integer)
	testing.expect(t, pv_ok, "protocolversion should be integer")
	testing.expect_value(t, int(pv), 70016)

	conn, conn_ok := obj["connections"].(json.Integer)
	testing.expect(t, conn_ok, "connections should be integer")
	testing.expect_value(t, int(conn), 0)
}

@(test)
test_stop :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "stop", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_stop(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be string")
	testing.expect(t, result == "Bitcoin server stopping", "message should match")
	testing.expect(t, !srv.running, "server should not be running after stop")
}

@(test)
test_uptime :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "uptime", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_uptime(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.Integer)
	testing.expect(t, ok, "result should be integer")
	testing.expect(t, result >= 0, "uptime should be non-negative")
}

@(test)
test_decoderawtransaction :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "decodetx", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Build a known transaction and serialize to hex
	cb := _make_test_coinbase(0)
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &cb)
	raw := wire.writer_bytes(&w)
	hex_str := _bytes_to_hex(raw)

	p := _make_params(json.Value(json.String(hex_str)))
	resp := _handle_decoderawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check txid present
	_, txid_ok := obj["txid"].(json.String)
	testing.expect(t, txid_ok, "txid should be string")

	// Check hash (wtxid) present
	_, hash_ok := obj["hash"].(json.String)
	testing.expect(t, hash_ok, "hash should be string")

	// Check version
	ver, ver_ok := obj["version"].(json.Integer)
	testing.expect(t, ver_ok, "version should be integer")
	testing.expect_value(t, int(ver), 1)

	// Check vin
	vin, vin_ok := obj["vin"].(json.Array)
	testing.expect(t, vin_ok, "vin should be array")
	if vin_ok {
		testing.expect_value(t, len(vin), 1)
	}

	// Check vout
	vout, vout_ok := obj["vout"].(json.Array)
	testing.expect(t, vout_ok, "vout should be array")
	if vout_ok {
		testing.expect_value(t, len(vout), 1)
		// Check scriptPubKey has type field
		if len(vout) > 0 {
			out_obj, oo := vout[0].(json.Object)
			if oo {
				spk, spk_ok := out_obj["scriptPubKey"].(json.Object)
				if spk_ok {
					_, type_ok := spk["type"].(json.String)
					testing.expect(t, type_ok, "scriptPubKey should have type field")
				}
			}
		}
	}
}

@(test)
test_decodescript :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "decodesc", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Encode a P2PKH script as hex
	// OP_DUP OP_HASH160 <20 zero bytes> OP_EQUALVERIFY OP_CHECKSIG
	script_bytes := make([]byte, 25, context.temp_allocator)
	script_bytes[0] = 0x76  // OP_DUP
	script_bytes[1] = 0xa9  // OP_HASH160
	script_bytes[2] = 0x14  // push 20 bytes
	script_bytes[23] = 0x88 // OP_EQUALVERIFY
	script_bytes[24] = 0xac // OP_CHECKSIG
	hex_str := _bytes_to_hex(script_bytes)

	p := _make_params(json.Value(json.String(hex_str)))
	resp := _handle_decodescript(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check asm contains OP_DUP
	asm_str, asm_ok := obj["asm"].(json.String)
	testing.expect(t, asm_ok, "asm should be string")
	if asm_ok {
		testing.expect(t, _str_contains(asm_str, "OP_DUP"), fmt.tprintf("asm should contain OP_DUP, got: %s", asm_str))
		testing.expect(t, _str_contains(asm_str, "OP_HASH160"), fmt.tprintf("asm should contain OP_HASH160, got: %s", asm_str))
	}

	// Check type
	type_str, type_ok := obj["type"].(json.String)
	testing.expect(t, type_ok, "type should be string")
	testing.expect(t, type_str == "pubkeyhash", fmt.tprintf("type should be pubkeyhash, got: %s", type_str))

	// Check p2sh present
	_, p2sh_ok := obj["p2sh"].(json.String)
	testing.expect(t, p2sh_ok, "p2sh should be string")
}

// Simple string contains helper (avoid importing core:strings in test)
_str_contains :: proc(s: string, substr: string) -> bool {
	if len(substr) > len(s) { return false }
	for i in 0 ..= len(s) - len(substr) {
		if s[i:i + len(substr)] == substr {
			return true
		}
	}
	return false
}

@(test)
test_getmempoolentry :: proc(t: ^testing.T) {
	srv, cs, mp, params_p, dir := _make_test_rpc_server(t, "mpentry", 103)
	defer _cleanup_test(srv, cs, mp, params_p, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Add a tx
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)
	merr := mempool.mempool_add(mp, &tx)
	testing.expect(t, merr == .None, fmt.tprintf("mempool add: %v", merr))

	txid := wire.tx_id(&tx)
	txid_hex := _hash_to_hex(txid)

	p := _make_params(json.Value(json.String(txid_hex)))
	resp := _handle_getmempoolentry(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check vsize
	vs, vs_ok := obj["vsize"].(json.Integer)
	testing.expect(t, vs_ok, "vsize should be integer")
	testing.expect(t, vs > 0, "vsize should be positive")

	// Check fees
	fees, fees_ok := obj["fees"].(json.Object)
	testing.expect(t, fees_ok, "fees should be object")
	if fees_ok {
		_, base_ok := fees["base"].(json.Float)
		testing.expect(t, base_ok, "fees.base should be float")
	}

	// Check depends
	deps, deps_ok := obj["depends"].(json.Array)
	testing.expect(t, deps_ok, "depends should be array")
	if deps_ok {
		testing.expect_value(t, len(deps), 0) // no parent in mempool
	}
}

@(test)
test_testmempoolaccept :: proc(t: ^testing.T) {
	srv, cs, mp, params_p, dir := _make_test_rpc_server(t, "testmp", 103)
	defer _cleanup_test(srv, cs, mp, params_p, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Build a valid spending tx
	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)
	cb_txid := _get_coinbase_txid(0)
	outpoint := wire.Outpoint{hash = cb_txid, index = 0}
	tx := _make_spend_tx(outpoint, subsidy, subsidy - 1000)

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &tx)
	raw := wire.writer_bytes(&w)
	hex_str := _bytes_to_hex(raw)

	rawtxs := make(json.Array, 1, context.temp_allocator)
	rawtxs[0] = json.Value(json.String(hex_str))

	p := _make_params(json.Value(rawtxs))
	resp := _handle_testmempoolaccept(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if !ok || len(arr) == 0 { return }

	result_obj, r_ok := arr[0].(json.Object)
	testing.expect(t, r_ok, "element should be object")
	if !r_ok { return }

	allowed, a_ok := result_obj["allowed"].(json.Boolean)
	testing.expect(t, a_ok, "allowed should be boolean")
	testing.expect(t, allowed, "tx should be allowed")

	// Verify tx was NOT added to mempool (dry-run)
	testing.expect_value(t, mempool.mempool_count(mp), 0)
}

@(test)
test_getchaintips :: proc(t: ^testing.T) {
	srv, cs, mp, params_p, dir := _make_test_rpc_server(t, "chaintips", 5)
	defer _cleanup_test(srv, cs, mp, params_p, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getchaintips(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if !ok { return }

	testing.expect(t, len(arr) >= 1, "should have at least one tip")

	// Find the active tip
	found_active := false
	for tip in arr {
		obj, obj_ok := tip.(json.Object)
		if !obj_ok { continue }
		status, s_ok := obj["status"].(json.String)
		if s_ok && status == "active" {
			found_active = true
			bl, bl_ok := obj["branchlen"].(json.Integer)
			if bl_ok {
				testing.expect_value(t, int(bl), 0)
			}
		}
	}
	testing.expect(t, found_active, "should have active tip")
}

@(test)
test_getblockstats :: proc(t: ^testing.T) {
	srv, cs, mp, params_p, dir := _make_test_rpc_server(t, "blkstats", 5)
	defer _cleanup_test(srv, cs, mp, params_p, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get stats for block at height 2
	p := _make_params(json.Value(json.Integer(2)))
	resp := _handle_getblockstats(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check height
	height, height_ok := obj["height"].(json.Integer)
	testing.expect(t, height_ok, "height should be integer")
	testing.expect_value(t, int(height), 2)

	// Check txs
	txs, txs_ok := obj["txs"].(json.Integer)
	testing.expect(t, txs_ok, "txs should be integer")
	testing.expect_value(t, int(txs), 1) // just coinbase

	// Check subsidy matches get_block_subsidy
	subsidy, sub_ok := obj["subsidy"].(json.Integer)
	testing.expect(t, sub_ok, "subsidy should be integer")
	expected_sub := consensus.get_block_subsidy(2, &consensus.REGTEST_PARAMS)
	testing.expect_value(t, i64(subsidy), expected_sub)

	// Check total_size > 0
	ts, ts_ok := obj["total_size"].(json.Integer)
	testing.expect(t, ts_ok, "total_size should be integer")
	testing.expect(t, ts > 0, "total_size should be positive")
}

// --- New RPC method tests ---

@(test)
test_help :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "help", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_help(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be string")
	if ok {
		testing.expect(t, _str_contains(result, "getblockcount"), "should contain getblockcount")
		testing.expect(t, _str_contains(result, "getpeerinfo"), "should contain getpeerinfo")
		testing.expect(t, _str_contains(result, "validateaddress"), "should contain validateaddress")
	}
}

@(test)
test_help_method :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "help_m", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	p := _make_params(json.Value(json.String("getblockcount")))
	resp := _handle_help(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be string")
	if ok {
		testing.expect(t, _str_contains(result, "getblockcount"), "help should mention method name")
	}
}

@(test)
test_getblock_verbose2 :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "blk_v2", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	block_hash_hex := _hash_to_hex(cs.active_chain[2])
	p := _make_params(json.Value(json.String(block_hash_hex)), json.Value(json.Integer(2)))
	resp := _handle_getblock(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	tx_arr, tx_ok := obj["tx"].(json.Array)
	testing.expect(t, tx_ok, "tx should be array")
	if !tx_ok || len(tx_arr) == 0 { return }

	// First tx should be an object (not a string txid)
	tx_obj, is_obj := tx_arr[0].(json.Object)
	testing.expect(t, is_obj, "tx[0] should be object for verbosity=2")
	if is_obj {
		_, txid_ok := tx_obj["txid"].(json.String)
		testing.expect(t, txid_ok, "decoded tx should have txid field")
	}
}

@(test)
test_getmininginfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "mininginfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getmininginfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	blocks, b_ok := obj["blocks"].(json.Integer)
	testing.expect(t, b_ok, "blocks should be integer")
	testing.expect_value(t, int(blocks), 4)

	_, d_ok := obj["difficulty"].(json.Float)
	testing.expect(t, d_ok, "difficulty should be float")

	chain_name, c_ok := obj["chain"].(json.String)
	testing.expect(t, c_ok, "chain should be string")
	testing.expect(t, chain_name == "regtest", "chain should be regtest")

	_, nh_ok := obj["networkhashps"].(json.Float)
	testing.expect(t, nh_ok, "networkhashps should be float")

	ptx, ptx_ok := obj["pooledtx"].(json.Integer)
	testing.expect(t, ptx_ok, "pooledtx should be integer")
	testing.expect_value(t, int(ptx), 0)
}

@(test)
test_getnetworkhashps :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "nethashps", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getnetworkhashps(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.Float)
	testing.expect(t, ok, "result should be float")
	testing.expect(t, result >= 0, "hashps should be non-negative")
}

@(test)
test_getnettotals :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "nettotals", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getnettotals(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	recv, recv_ok := obj["totalbytesrecv"].(json.Integer)
	testing.expect(t, recv_ok, "totalbytesrecv should be integer")
	testing.expect_value(t, int(recv), 0) // no peers

	sent, sent_ok := obj["totalbytessent"].(json.Integer)
	testing.expect(t, sent_ok, "totalbytessent should be integer")
	testing.expect_value(t, int(sent), 0)

	_, tm_ok := obj["timemillis"].(json.Integer)
	testing.expect(t, tm_ok, "timemillis should be integer")
}

@(test)
test_validateaddress_valid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "valaddr_v", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Regtest bech32 P2WPKH address
	program: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := crypto.bech32_encode("bcrt", 0, program[:])

	p := _make_params(json.Value(json.String(addr)))
	resp := _handle_validateaddress(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	valid, v_ok := obj["isvalid"].(json.Boolean)
	testing.expect(t, v_ok, "isvalid should be bool")
	testing.expect(t, valid, "should be valid")

	is_witness, w_ok := obj["iswitness"].(json.Boolean)
	testing.expect(t, w_ok, "iswitness should be bool")
	testing.expect(t, is_witness, "should be witness")

	wv, wv_ok := obj["witness_version"].(json.Integer)
	testing.expect(t, wv_ok, "witness_version should be integer")
	testing.expect_value(t, int(wv), 0)

	_, spk_ok := obj["scriptPubKey"].(json.String)
	testing.expect(t, spk_ok, "scriptPubKey should be string")
}

@(test)
test_validateaddress_invalid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "valaddr_i", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	p := _make_params(json.Value(json.String("not-a-valid-address")))
	resp := _handle_validateaddress(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error (invalid address returns isvalid=false)")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	valid, v_ok := obj["isvalid"].(json.Boolean)
	testing.expect(t, v_ok, "isvalid should be bool")
	testing.expect(t, !valid, "should be invalid")
}

@(test)
test_savemempool :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "savemp", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	srv.data_dir = dir

	resp := _handle_savemempool(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	_, is_null := resp.result.(json.Null)
	testing.expect(t, is_null, "result should be null")
}

@(test)
test_ping :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "ping", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// cm is nil, should return null without error
	resp := _handle_ping(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	_, is_null := resp.result.(json.Null)
	testing.expect(t, is_null, "result should be null")
}

// --- New RPC method tests (Phase 20) ---

@(test)
test_rpc_getmemoryinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "meminfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getmemoryinfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	locked, l_ok := obj["locked"].(json.Object)
	testing.expect(t, l_ok, "locked should be object")
	if !l_ok { return }

	used, u_ok := locked["used"].(json.Integer)
	testing.expect(t, u_ok, "used should be integer")
	testing.expect(t, used >= 0, "used should be non-negative")

	total, t_ok := locked["total"].(json.Integer)
	testing.expect(t, t_ok, "total should be integer")
	testing.expect(t, total > 0, "total should be positive")

	free_mem, f_ok := locked["free"].(json.Integer)
	testing.expect(t, f_ok, "free should be integer")
	testing.expect(t, free_mem >= 0, "free should be non-negative")
}

@(test)
test_rpc_getrpcinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "rpcinfo", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_getrpcinfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	cmds, c_ok := obj["active_commands"].(json.Array)
	testing.expect(t, c_ok, "active_commands should be array")
	testing.expect(t, len(cmds) == 1, "should have 1 active command")

	if len(cmds) >= 1 {
		cmd, cmd_ok := cmds[0].(json.Object)
		testing.expect(t, cmd_ok, "command should be object")
		if cmd_ok {
			method, m_ok := cmd["method"].(json.String)
			testing.expect(t, m_ok, "method should be string")
			testing.expect(t, method == "getrpcinfo", "method should be getrpcinfo")
		}
	}
}

@(test)
test_rpc_logging :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "logging", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_logging(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	net_val, n_ok := obj["net"].(json.Boolean)
	testing.expect(t, n_ok, "net should be boolean")
	testing.expect(t, net_val, "net should be true")

	rpc_val, r_ok := obj["rpc"].(json.Boolean)
	testing.expect(t, r_ok, "rpc should be boolean")
	testing.expect(t, rpc_val, "rpc should be true")
}

@(test)
test_rpc_createrawtransaction :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "createtx", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Build inputs array
	in_obj := make(json.Object, 4, context.temp_allocator)
	in_obj["txid"] = json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000001"))
	in_obj["vout"] = json.Value(json.Integer(0))
	inputs := make(json.Array, 1, context.temp_allocator)
	inputs[0] = json.Value(in_obj)

	// Build outputs array — use a regtest P2PKH address
	// regtest p2pkh prefix is 0x6F, use a dummy 20-byte hash
	addr := crypto.base58check_encode(0x6F, []byte{
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
		0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
	})
	out_obj := make(json.Object, 2, context.temp_allocator)
	out_obj[addr] = json.Value(json.Float(0.01))
	outputs := make(json.Array, 1, context.temp_allocator)
	outputs[0] = json.Value(out_obj)

	p := _make_params(json.Value(inputs), json.Value(outputs))
	resp := _handle_createrawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, fmt.tprintf("should not error: %v", resp.error))

	hex_str, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	if !ok { return }

	// Deserialize and verify structure
	raw, dec_ok := _hex_decode(hex_str)
	testing.expect(t, dec_ok, "should decode hex")
	if !dec_ok { return }

	r := wire.reader_init(raw)
	tx, err := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, err == nil, "should deserialize tx")

	testing.expect_value(t, tx.version, i32(2))
	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 1)
	testing.expect_value(t, tx.outputs[0].value, i64(1000000)) // 0.01 BTC
	testing.expect_value(t, len(tx.outputs[0].script_pubkey), 25) // P2PKH script
}

@(test)
test_rpc_createrawtransaction_bech32 :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "createtx_b", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	in_obj := make(json.Object, 4, context.temp_allocator)
	in_obj["txid"] = json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000001"))
	in_obj["vout"] = json.Value(json.Integer(0))
	inputs := make(json.Array, 1, context.temp_allocator)
	inputs[0] = json.Value(in_obj)

	// Build bech32 regtest address (P2WPKH, 20 bytes)
	program: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := crypto.bech32_encode("bcrt", 0, program[:])

	out_obj := make(json.Object, 2, context.temp_allocator)
	out_obj[addr] = json.Value(json.Float(0.005))
	outputs := make(json.Array, 1, context.temp_allocator)
	outputs[0] = json.Value(out_obj)

	p := _make_params(json.Value(inputs), json.Value(outputs))
	resp := _handle_createrawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	hex_str, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	if !ok { return }

	raw, dec_ok := _hex_decode(hex_str)
	testing.expect(t, dec_ok, "should decode hex")
	if !dec_ok { return }

	r := wire.reader_init(raw)
	tx, err := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, err == nil, "should deserialize tx")

	testing.expect_value(t, len(tx.outputs), 1)
	testing.expect_value(t, tx.outputs[0].value, i64(500000)) // 0.005 BTC
	testing.expect_value(t, len(tx.outputs[0].script_pubkey), 22) // P2WPKH: OP_0 <20>
}

@(test)
test_rpc_combinerawtransaction :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "combinetx", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Create a base unsigned tx
	in_obj := make(json.Object, 4, context.temp_allocator)
	in_obj["txid"] = json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000001"))
	in_obj["vout"] = json.Value(json.Integer(0))
	inputs := make(json.Array, 1, context.temp_allocator)
	inputs[0] = json.Value(in_obj)

	addr := crypto.base58check_encode(0x6F, []byte{
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
		0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
	})
	out_obj := make(json.Object, 2, context.temp_allocator)
	out_obj[addr] = json.Value(json.Float(0.01))
	outputs := make(json.Array, 1, context.temp_allocator)
	outputs[0] = json.Value(out_obj)

	create_p := _make_params(json.Value(inputs), json.Value(outputs))
	create_resp := _handle_createrawtransaction(srv, create_p)
	hex1, _ := create_resp.result.(json.String)

	// Combine two copies (same tx)
	hex_arr := make(json.Array, 2, context.temp_allocator)
	hex_arr[0] = json.Value(json.String(hex1))
	hex_arr[1] = json.Value(json.String(hex1))

	p := _make_params(json.Value(hex_arr))
	resp := _handle_combinerawtransaction(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	result, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	testing.expect(t, len(result) > 0, "result should not be empty")
}

@(test)
test_rpc_signrawtransactionwithkey :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	srv, cs, mp, params, dir := _make_test_rpc_server(t, "signtx", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Known test WIF key (regtest/testnet compressed)
	// This is a well-known test key: private key = 0x0000...0001
	// WIF (testnet, compressed): cMahea7zqjxrtgAbB7LSGbcQUr1uX1ojuat9jZodMN8rFTv2sfUK
	// We'll use a real test vector:
	// seckey = cb28e600b1b13795c3b17e67fb0a8edd7fd609d08e0251e215039e8e35a7eb01
	// WIF (testnet compressed) = cUEfRtvyVBqFMm2NxV3pRdqeb21CUkBCRK8VsuYSmgcpE6d8bVhR
	// Let's just build a P2PKH tx and try to sign, checking the output format

	// Create unsigned tx
	in_obj := make(json.Object, 4, context.temp_allocator)
	in_obj["txid"] = json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000001"))
	in_obj["vout"] = json.Value(json.Integer(0))
	inputs := make(json.Array, 1, context.temp_allocator)
	inputs[0] = json.Value(in_obj)

	addr := crypto.base58check_encode(0x6F, []byte{
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
		0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
	})
	out_obj := make(json.Object, 2, context.temp_allocator)
	out_obj[addr] = json.Value(json.Float(0.01))
	outputs := make(json.Array, 1, context.temp_allocator)
	outputs[0] = json.Value(out_obj)

	create_p := _make_params(json.Value(inputs), json.Value(outputs))
	create_resp := _handle_createrawtransaction(srv, create_p)
	unsigned_hex, _ := create_resp.result.(json.String)

	// Generate a real key pair for testing
	seckey_bytes := [32]u8{
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
	}
	pubkey, pub_ok := crypto.pubkey_from_seckey(seckey_bytes[:])
	testing.expect(t, pub_ok, "should derive pubkey")
	if !pub_ok { return }

	// Compute the pubkey hash and build the scriptPubKey
	pkh := crypto.hash160(pubkey[:])
	spk := make([]byte, 25, context.temp_allocator)
	spk[0] = 0x76; spk[1] = 0xa9; spk[2] = 0x14
	copy(spk[3:23], pkh[:])
	spk[23] = 0x88; spk[24] = 0xac
	spk_hex := _bytes_to_hex(spk)

	// WIF encode the secret key (testnet, compressed: 0xEF + key + 0x01 + checksum)
	wif_payload: [34]byte
	wif_payload[0] = 0xEF
	copy(wif_payload[1:33], seckey_bytes[:])
	wif_payload[33] = 0x01
	wif_checksum := crypto.sha256d(wif_payload[:34])
	wif_full: [38]byte
	copy(wif_full[:34], wif_payload[:])
	wif_full[34] = wif_checksum[0]
	wif_full[35] = wif_checksum[1]
	wif_full[36] = wif_checksum[2]
	wif_full[37] = wif_checksum[3]
	wif_str := _base58_encode_test(wif_full[:])

	keys := make(json.Array, 1, context.temp_allocator)
	keys[0] = json.Value(json.String(wif_str))

	// Build prevtxs
	pt_obj := make(json.Object, 8, context.temp_allocator)
	pt_obj["txid"] = json.Value(json.String("0000000000000000000000000000000000000000000000000000000000000001"))
	pt_obj["vout"] = json.Value(json.Integer(0))
	pt_obj["scriptPubKey"] = json.Value(json.String(spk_hex))
	pt_obj["amount"] = json.Value(json.Float(0.05))
	prevtxs := make(json.Array, 1, context.temp_allocator)
	prevtxs[0] = json.Value(pt_obj)

	p := _make_params(
		json.Value(json.String(unsigned_hex)),
		json.Value(keys),
		json.Value(prevtxs),
	)
	resp := _handle_signrawtransactionwithkey(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, fmt.tprintf("should not error: %v", resp.error))

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	complete, c_ok := obj["complete"].(json.Boolean)
	testing.expect(t, c_ok, "complete should be boolean")
	testing.expect(t, complete, "should be complete")

	signed_hex, sh_ok := obj["hex"].(json.String)
	testing.expect(t, sh_ok, "hex should be string")
	testing.expect(t, len(signed_hex) > len(unsigned_hex), "signed tx should be longer than unsigned")
}

// Base58 encode helper for test (no version/checksum, raw bytes)
_base58_encode_test :: proc(data: []byte) -> string {
	alpha := [58]byte{
		'1', '2', '3', '4', '5', '6', '7', '8', '9',
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J',
		'K', 'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T',
		'U', 'V', 'W', 'X', 'Y', 'Z',
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i',
		'j', 'k', 'm', 'n', 'o', 'p', 'q', 'r', 's',
		't', 'u', 'v', 'w', 'x', 'y', 'z',
	}

	// Count leading zeros
	leading_zeros := 0
	for i in 0 ..< len(data) {
		if data[i] != 0 { break }
		leading_zeros += 1
	}

	work := make([]byte, len(data), context.temp_allocator)
	copy(work, data)

	buf: [64]byte
	buf_pos := len(buf)

	for {
		all_zero := true
		for i in 0 ..< len(work) {
			if work[i] != 0 { all_zero = false; break }
		}
		if all_zero { break }

		remainder: u32 = 0
		for i in 0 ..< len(work) {
			acc := remainder * 256 + u32(work[i])
			work[i] = u8(acc / 58)
			remainder = acc % 58
		}
		buf_pos -= 1
		buf[buf_pos] = alpha[remainder]
	}

	for _ in 0 ..< leading_zeros {
		buf_pos -= 1
		buf[buf_pos] = '1'
	}

	return fmt.tprintf("%s", string(buf[buf_pos:]))
}

@(test)
test_rpc_getchaintxstats :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txstats", 10)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Default params (full chain window)
	resp := _handle_getchaintxstats(srv, nil)
	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error with default params")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check required fields
	_, has_time := obj["time"]
	testing.expect(t, has_time, "should have 'time' field")

	wbh, has_wbh := obj["window_final_block_height"]
	testing.expect(t, has_wbh, "should have 'window_final_block_height' field")
	if has_wbh {
		h, h_ok := wbh.(json.Integer)
		testing.expect(t, h_ok && int(h) == 9, fmt.tprintf("window_final_block_height should be 9, got %v", wbh))
	}

	wtc, has_wtc := obj["window_tx_count"]
	testing.expect(t, has_wtc, "should have 'window_tx_count' field")
	if has_wtc {
		tc, tc_ok := wtc.(json.Integer)
		// 9 blocks in window (height 1-9), each with 1 tx = 9 txs
		testing.expect(t, tc_ok && int(tc) == 9, fmt.tprintf("window_tx_count should be 9, got %v", wtc))
	}

	// Test with explicit nblocks
	p := _make_params(json.Value(json.Integer(5)))
	resp2 := _handle_getchaintxstats(srv, p)
	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "should not error with nblocks=5")

	obj2, ok2 := resp2.result.(json.Object)
	testing.expect(t, ok2, "result should be object")
	if ok2 {
		wtc2, has_wtc2 := obj2["window_tx_count"]
		if has_wtc2 {
			tc2, tc2_ok := wtc2.(json.Integer)
			testing.expect(t, tc2_ok && int(tc2) == 5, fmt.tprintf("window_tx_count should be 5 for nblocks=5, got %v", wtc2))
		}

		wbc, has_wbc := obj2["window_block_count"]
		if has_wbc {
			bc, bc_ok := wbc.(json.Integer)
			testing.expect(t, bc_ok && int(bc) == 5, fmt.tprintf("window_block_count should be 5, got %v", wbc))
		}
	}

	// Test txcount (cumulative) — 10 blocks with 1 tx each = 10 total
	txcount, has_txcount := obj["txcount"]
	testing.expect(t, has_txcount, "should have 'txcount' field")
	if has_txcount {
		tc, tc_ok := txcount.(json.Integer)
		testing.expect(t, tc_ok && int(tc) == 10, fmt.tprintf("txcount should be 10, got %v", txcount))
	}

	// Test txrate is present and positive
	_, has_rate := obj["txrate"]
	testing.expect(t, has_rate, "should have 'txrate' field")
}

@(test)
test_rpc_getchaintxstats_invalid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txstats_inv", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// nblocks too large
	p := _make_params(json.Value(json.Integer(999)))
	resp := _handle_getchaintxstats(srv, p)
	_, has_err := resp.error.?
	testing.expect(t, has_err, "should error for nblocks > chain height")
}


// --- New RPC tests ---

@(test)
test_gettxoutsetinfo :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txoutset", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))
	resp := _handle_gettxoutsetinfo(srv, nil)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	obj, ok := resp.result.(json.Object)
	testing.expect(t, ok, "result should be object")
	if !ok { return }

	// Check height
	height, h_ok := obj["height"].(json.Integer)
	testing.expect(t, h_ok, "height should be integer")
	testing.expect_value(t, int(height), 4) // 5 blocks = height 4

	// Check bestblock exists
	_, bb_ok := obj["bestblock"].(json.String)
	testing.expect(t, bb_ok, "bestblock should be string")

	// txouts should be > 0 (coinbase outputs)
	txouts, to_ok := obj["txouts"].(json.Integer)
	testing.expect(t, to_ok, "txouts should be integer")
	testing.expect(t, txouts > 0, fmt.tprintf("txouts should be > 0, got %d", txouts))

	// total_amount should be > 0
	total_amount, ta_ok := obj["total_amount"].(json.Float)
	testing.expect(t, ta_ok, "total_amount should be float")
	testing.expect(t, total_amount > 0, fmt.tprintf("total_amount should be > 0, got %f", total_amount))
}

// Helper to directly inject a mempool entry (bypasses validation).
_inject_mempool_entry :: proc(mp: ^mempool.Mempool, tx: ^wire.Tx, fee: i64) -> Hash256 {
	txid := wire.tx_id(tx)
	vsize := consensus.get_tx_vsize(tx)
	entry := new(mempool.Mempool_Entry)
	// Deep-clone the tx so mempool owns all memory (inputs/outputs/scripts).
	// Without this, _free_tx in mempool_destroy tries to delete temp-allocated slices.
	entry.tx = _clone_tx_for_mempool(tx)
	entry.txid = txid
	entry.fee = fee
	entry.vsize = vsize
	entry.fee_rate = mempool.fee_rate(fee, vsize)
	entry.time = 1000000
	mp.entries[txid] = entry
	for in_idx in 0 ..< len(tx.inputs) {
		mp.spent_outpoints[tx.inputs[in_idx].previous_output] = txid
	}
	return txid
}

_clone_tx_for_mempool :: proc(tx: ^wire.Tx) -> wire.Tx {
	result: wire.Tx
	result.version = tx.version
	result.locktime = tx.locktime

	if len(tx.inputs) > 0 {
		result.inputs = make([]wire.Tx_In, len(tx.inputs))
		for i in 0 ..< len(tx.inputs) {
			result.inputs[i].previous_output = tx.inputs[i].previous_output
			result.inputs[i].sequence = tx.inputs[i].sequence
			if len(tx.inputs[i].script_sig) > 0 {
				result.inputs[i].script_sig = make([]byte, len(tx.inputs[i].script_sig))
				copy(result.inputs[i].script_sig, tx.inputs[i].script_sig)
			}
		}
	}

	if len(tx.outputs) > 0 {
		result.outputs = make([]wire.Tx_Out, len(tx.outputs))
		for i in 0 ..< len(tx.outputs) {
			result.outputs[i].value = tx.outputs[i].value
			if len(tx.outputs[i].script_pubkey) > 0 {
				result.outputs[i].script_pubkey = make([]byte, len(tx.outputs[i].script_pubkey))
				copy(result.outputs[i].script_pubkey, tx.outputs[i].script_pubkey)
			}
		}
	}

	if len(tx.witness) > 0 {
		result.witness = make([][][]byte, len(tx.witness))
		for i in 0 ..< len(tx.witness) {
			if len(tx.witness[i]) > 0 {
				result.witness[i] = make([][]byte, len(tx.witness[i]))
				for j in 0 ..< len(tx.witness[i]) {
					if len(tx.witness[i][j]) > 0 {
						result.witness[i][j] = make([]byte, len(tx.witness[i][j]))
						copy(result.witness[i][j], tx.witness[i][j])
					}
				}
			}
		}
	}

	return result
}

@(test)
test_getmempoolancestors :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "mpanc", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Create parent tx (direct inject to bypass validation)
	parent_tx := _make_spend_tx(
		wire.Outpoint{hash = _get_coinbase_txid(0), index = 0},
		5_000_000_000,
		4_999_000_000,
	)
	parent_txid := _inject_mempool_entry(mp, &parent_tx, 1_000_000)

	// Create child tx spending parent's output
	child_tx := _make_spend_tx(
		wire.Outpoint{hash = parent_txid, index = 0},
		4_999_000_000,
		4_998_000_000,
	)
	child_txid := _inject_mempool_entry(mp, &child_tx, 1_000_000)

	// Get ancestors of child — should include parent
	p := _make_params(json.Value(json.String(_hash_to_hex(child_txid))))
	resp := _handle_getmempoolancestors(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if !ok { return }

	testing.expect_value(t, len(arr), 1)
	anc_hex, s_ok := arr[0].(json.String)
	testing.expect(t, s_ok, "ancestor should be string")
	testing.expect(t, anc_hex == _hash_to_hex(parent_txid), "ancestor should be parent txid")

	// Get ancestors of parent — should be empty
	p2 := _make_params(json.Value(json.String(_hash_to_hex(parent_txid))))
	resp2 := _handle_getmempoolancestors(srv, p2)
	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "should not error for parent")

	arr2, ok2 := resp2.result.(json.Array)
	testing.expect(t, ok2, "result should be array")
	if ok2 {
		testing.expect_value(t, len(arr2), 0)
	}
}

@(test)
test_getmempooldescendants :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "mpdesc", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Create parent tx (direct inject)
	parent_tx := _make_spend_tx(
		wire.Outpoint{hash = _get_coinbase_txid(0), index = 0},
		5_000_000_000,
		4_999_000_000,
	)
	parent_txid := _inject_mempool_entry(mp, &parent_tx, 1_000_000)

	// Create child tx spending parent
	child_tx := _make_spend_tx(
		wire.Outpoint{hash = parent_txid, index = 0},
		4_999_000_000,
		4_998_000_000,
	)
	child_txid := _inject_mempool_entry(mp, &child_tx, 1_000_000)

	// Get descendants of parent — should include child
	p := _make_params(json.Value(json.String(_hash_to_hex(parent_txid))))
	resp := _handle_getmempooldescendants(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "should not error")

	arr, ok := resp.result.(json.Array)
	testing.expect(t, ok, "result should be array")
	if !ok { return }

	testing.expect_value(t, len(arr), 1)
	desc_hex, s_ok := arr[0].(json.String)
	testing.expect(t, s_ok, "descendant should be string")
	testing.expect(t, desc_hex == _hash_to_hex(child_txid), "descendant should be child txid")

	// Get descendants of child — should be empty
	p2 := _make_params(json.Value(json.String(_hash_to_hex(child_txid))))
	resp2 := _handle_getmempooldescendants(srv, p2)
	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "should not error for child")

	arr2, ok2 := resp2.result.(json.Array)
	testing.expect(t, ok2, "result should be array")
	if ok2 {
		testing.expect_value(t, len(arr2), 0)
	}
}

@(test)
test_gettxoutproof_and_verify :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txproof", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Get coinbase txid from block at height 2
	cb_txid := _get_coinbase_txid(2)
	cb_txid_hex := _hash_to_hex(cb_txid)

	// Get the block hash at height 2
	block_hash := cs.active_chain[2]
	block_hash_hex := _hash_to_hex(block_hash)

	// Build proof
	txids_arr := make(json.Array, 1, context.temp_allocator)
	txids_arr[0] = json.Value(json.String(cb_txid_hex))

	p := _make_params(json.Value(txids_arr), json.Value(json.String(block_hash_hex)))
	resp := _handle_gettxoutproof(srv, p)

	err_val, has_err := resp.error.?
	testing.expect(t, !has_err, fmt.tprintf("gettxoutproof should not error: %v", err_val))

	proof_hex, ok := resp.result.(json.String)
	testing.expect(t, ok, "result should be hex string")
	if !ok { return }

	// Proof should be at least 80 bytes (header) + 4 (total_txs) = 168 hex chars
	testing.expect(t, len(proof_hex) >= 168, fmt.tprintf("proof too short: %d chars", len(proof_hex)))

	// Now verify the proof
	p2 := _make_params(json.Value(json.String(proof_hex)))
	resp2 := _handle_verifytxoutproof(srv, p2)

	_, has_err2 := resp2.error.?
	testing.expect(t, !has_err2, "verifytxoutproof should not error")

	arr, arr_ok := resp2.result.(json.Array)
	testing.expect(t, arr_ok, "result should be array")
	if !arr_ok { return }

	testing.expect_value(t, len(arr), 1)
	verified_txid, v_ok := arr[0].(json.String)
	testing.expect(t, v_ok, "verified txid should be string")
	testing.expect(t, verified_txid == cb_txid_hex, fmt.tprintf("verified txid mismatch: got %s, expected %s", verified_txid, cb_txid_hex))
}

@(test)
test_verifytxoutproof_invalid :: proc(t: ^testing.T) {
	srv, cs, mp, params, dir := _make_test_rpc_server(t, "txproof_inv", 5)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// Empty proof
	p := _make_params(json.Value(json.String("00")))
	resp := _handle_verifytxoutproof(srv, p)
	_, has_err := resp.error.?
	testing.expect(t, has_err, "should error on invalid proof")
}

@(test)
test_signmessagewithprivkey :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	srv, cs, mp, params, dir := _make_test_rpc_server(t, "signmsg", 1)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// WIF for private key 1, mainnet compressed
	wif := "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"
	message := "Hello World"

	p := _make_params(json.Value(json.String(wif)), json.Value(json.String(message)))
	resp := _handle_signmessagewithprivkey(srv, p)

	_, has_err := resp.error.?
	testing.expect(t, !has_err, "signmessagewithprivkey should not error")

	sig_b64, sig_ok := resp.result.(json.String)
	testing.expect(t, sig_ok, "result should be a base64 string")
	testing.expect(t, len(sig_b64) > 0, "signature should not be empty")
}

@(test)
test_verifymessage :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	srv, cs, mp, params, dir := _make_test_rpc_server(t, "verifymsg", 1)
	defer _cleanup_test(srv, cs, mp, params, dir)

	srv._current_id = json.Value(json.Integer(1))

	// First sign a message
	wif := "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"
	message := "Hello World"

	sign_p := _make_params(json.Value(json.String(wif)), json.Value(json.String(message)))
	sign_resp := _handle_signmessagewithprivkey(srv, sign_p)
	sig_b64, _ := sign_resp.result.(json.String)

	// The P2PKH address for privkey 1 compressed on mainnet is 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH
	// But our test server uses regtest params. Compute the address for regtest.
	seckey: [32]u8
	seckey[31] = 1
	pubkey_bytes, _ := crypto.pubkey_from_seckey(seckey[:])
	pub_hash := crypto.hash160(pubkey_bytes[:])
	// regtest p2pkh prefix = mainnet (0x00) for most tests
	address := crypto.base58check_encode(srv.chain.params.p2pkh_prefix, pub_hash[:])

	// Verify with correct address
	verify_p := _make_params(
		json.Value(json.String(address)),
		json.Value(json.String(sig_b64)),
		json.Value(json.String(message)),
	)
	resp := _handle_verifymessage(srv, verify_p)
	_, has_err := resp.error.?
	testing.expect(t, !has_err, "verifymessage should not error")

	result, r_ok := resp.result.(json.Boolean)
	testing.expect(t, r_ok, "result should be boolean")
	testing.expect(t, bool(result), "signature should verify")

	// Wrong message should fail
	wrong_p := _make_params(
		json.Value(json.String(address)),
		json.Value(json.String(sig_b64)),
		json.Value(json.String("Wrong message")),
	)
	wrong_resp := _handle_verifymessage(srv, wrong_p)
	wrong_result, _ := wrong_resp.result.(json.Boolean)
	testing.expect(t, !bool(wrong_result), "wrong message should not verify")
}
