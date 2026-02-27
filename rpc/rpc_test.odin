package rpc

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

import "../chain"
import "../consensus"
import "../crypto"
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

	// Check best block hash present
	_, hash_ok := obj["bestblockhash"].(json.String)
	testing.expect(t, hash_ok, "bestblockhash should be string")
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
	testing.expect(t, subver == "/btcnode-odin:0.1.0/", "subversion should match")

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
