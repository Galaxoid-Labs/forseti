package consensus

import "../crypto"
import "../wire"
import "core:encoding/hex"
import "core:fmt"
import "core:testing"

// --- Helpers ---

hex_decode :: proc(s: string) -> []u8 {
	bytes, _ := hex.decode(transmute([]u8)s, context.temp_allocator)
	return bytes
}

hex_encode :: proc(data: []u8) -> string {
	return string(hex.encode(data, context.temp_allocator))
}

hash_to_hex :: proc(h: Hash256) -> string {
	h := h
	return hex_encode(h[:])
}

// Build a minimal coinbase transaction.
make_coinbase :: proc(height: int, allocator := context.temp_allocator) -> wire.Tx {
	// Coinbase script: push height as script number
	height_bytes: [4]byte
	height_bytes[0] = byte(height & 0xff)
	height_bytes[1] = byte((height >> 8) & 0xff)
	height_bytes[2] = byte((height >> 16) & 0xff)
	height_bytes[3] = byte((height >> 24) & 0xff)

	// Build script_sig: OP_PUSH3 <height_le_3bytes> (BIP34 style)
	script_sig := make([]byte, 4, allocator)
	script_sig[0] = 0x03 // push 3 bytes
	script_sig[1] = height_bytes[0]
	script_sig[2] = height_bytes[1]
	script_sig[3] = height_bytes[2]

	inputs := make([]wire.Tx_In, 1, allocator)
	inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint {
			hash  = wire.HASH_ZERO,
			index = 0xffffffff,
		},
		script_sig      = script_sig,
		sequence        = 0xffffffff,
	}

	// Output: 50 BTC to a dummy P2PKH script
	script_pubkey := make([]byte, 25, allocator)
	script_pubkey[0] = 0x76 // OP_DUP
	script_pubkey[1] = 0xa9 // OP_HASH160
	script_pubkey[2] = 0x14 // push 20 bytes
	// bytes 3..22 are zero (dummy pubkey hash)
	script_pubkey[23] = 0x88 // OP_EQUALVERIFY
	script_pubkey[24] = 0xac // OP_CHECKSIG

	outputs := make([]wire.Tx_Out, 1, allocator)
	outputs[0] = wire.Tx_Out {
		value         = 50 * COIN,
		script_pubkey = script_pubkey,
	}

	return wire.Tx {
		version  = 1,
		inputs   = inputs,
		outputs  = outputs,
		locktime = 0,
	}
}

// Increment nonce until PoW passes (trivial for regtest).
mine_block :: proc(block: ^wire.Block, params: ^Chain_Params) {
	for nonce := u32(0); nonce < 0xffffffff; nonce += 1 {
		block.header.nonce = nonce
		hash := wire.block_header_hash(&block.header)
		if check_proof_of_work(hash, block.header.bits, params) {
			return
		}
	}
}

// --- bits_to_target / target_to_bits tests ---

@(test)
test_bits_to_target :: proc(t: ^testing.T) {
	// mainnet genesis: 0x1d00ffff -> 00000000ffff0000...0000
	target := bits_to_target(0x1d00ffff)
	testing.expect(t, target[0] == 0x00, "byte 0")
	testing.expect(t, target[1] == 0x00, "byte 1")
	testing.expect(t, target[2] == 0x00, "byte 2")
	testing.expect(t, target[3] == 0x00, "byte 3")
	testing.expect(t, target[4] == 0xff, "byte 4")
	testing.expect(t, target[5] == 0xff, "byte 5")
	testing.expect(t, target[6] == 0x00, "byte 6")

	// Round-trip
	bits_rt := target_to_bits(target)
	testing.expect_value(t, bits_rt, u32(0x1d00ffff))

	// Another known pair: block 32256 nBits = 0x1b0404cb
	target2 := bits_to_target(0x1b0404cb)
	bits_rt2 := target_to_bits(target2)
	testing.expect_value(t, bits_rt2, u32(0x1b0404cb))

	// Zero mantissa => zero target
	zero_target := bits_to_target(0x1d000000)
	testing.expect(t, u256_is_zero(zero_target), "zero mantissa should give zero target")

	// Negative mantissa (MSB set) => zero target
	neg_target := bits_to_target(0x1d800000)
	testing.expect(t, u256_is_zero(neg_target), "negative mantissa should give zero target")
}

// --- Proof of work tests ---

@(test)
test_check_proof_of_work_genesis :: proc(t: ^testing.T) {
	// Mainnet genesis header
	header_hex :=
		"01000000" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" +
		"29ab5f49" +
		"ffff001d" +
		"1dac2b7c"
	header_bytes := hex_decode(header_hex)
	r := wire.reader_init(header_bytes)
	header, _ := wire.deserialize_block_header(&r)
	hash := wire.block_header_hash(&header)

	params := MAINNET_PARAMS
	ok := check_proof_of_work(hash, header.bits, &params)
	testing.expect(t, ok, "genesis block should pass PoW check")
}

@(test)
test_check_proof_of_work_bad :: proc(t: ^testing.T) {
	// Same genesis header but with modified nonce
	header_hex :=
		"01000000" +
		"0000000000000000000000000000000000000000000000000000000000000000" +
		"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" +
		"29ab5f49" +
		"ffff001d" +
		"00000000" // nonce zeroed
	header_bytes := hex_decode(header_hex)
	r := wire.reader_init(header_bytes)
	header, _ := wire.deserialize_block_header(&r)
	hash := wire.block_header_hash(&header)

	params := MAINNET_PARAMS
	ok := check_proof_of_work(hash, header.bits, &params)
	testing.expect(t, !ok, "modified nonce should fail PoW check")
}

// --- Block subsidy tests ---

@(test)
test_block_subsidy :: proc(t: ^testing.T) {
	params := MAINNET_PARAMS
	testing.expect_value(t, get_block_subsidy(0, &params), i64(50_0000_0000))
	testing.expect_value(t, get_block_subsidy(209_999, &params), i64(50_0000_0000))
	testing.expect_value(t, get_block_subsidy(210_000, &params), i64(25_0000_0000))
	testing.expect_value(t, get_block_subsidy(420_000, &params), i64(12_5000_0000))
	testing.expect_value(t, get_block_subsidy(630_000, &params), i64(6_2500_0000))
	testing.expect_value(t, get_block_subsidy(840_000, &params), i64(3_1250_0000))
}

@(test)
test_block_subsidy_halving_limit :: proc(t: ^testing.T) {
	params := MAINNET_PARAMS
	// After 64 halvings, subsidy should be 0
	testing.expect_value(t, get_block_subsidy(64 * 210_000, &params), i64(0))
}

// --- Amount validation tests ---

@(test)
test_is_valid_amount :: proc(t: ^testing.T) {
	testing.expect(t, is_valid_amount(0), "0 should be valid")
	testing.expect(t, is_valid_amount(MAX_MONEY), "MAX_MONEY should be valid")
	testing.expect(t, !is_valid_amount(-1), "-1 should be invalid")
	testing.expect(t, !is_valid_amount(MAX_MONEY + 1), "MAX_MONEY+1 should be invalid")
	testing.expect(t, is_valid_amount(1), "1 should be valid")
	testing.expect(t, is_valid_amount(COIN), "1 BTC should be valid")
}

// --- Script flags tests ---

@(test)
test_get_script_flags :: proc(t: ^testing.T) {
	// Pre-BIP66 mainnet height (< 363725)
	params := MAINNET_PARAMS
	flags_pre := get_script_flags(363_724, &params)
	testing.expect(t, .P2SH in flags_pre, "P2SH should be active at height 363724")
	testing.expect(t, .DER_Sig not_in flags_pre, "DER_Sig should NOT be active before BIP66")
	testing.expect(t, .Witness not_in flags_pre, "Witness should NOT be active before SegWit")

	// Post-SegWit mainnet height (>= 481824)
	flags_post := get_script_flags(481_824, &params)
	testing.expect(t, .P2SH in flags_post, "P2SH should be active")
	testing.expect(t, .DER_Sig in flags_post, "DER_Sig should be active")
	testing.expect(t, .Check_Locktime in flags_post, "Check_Locktime should be active")
	testing.expect(t, .Check_Sequence in flags_post, "Check_Sequence should be active")
	testing.expect(t, .Witness in flags_post, "Witness should be active")
	testing.expect(t, .Null_Dummy in flags_post, "Null_Dummy should be active")
	testing.expect(t, .Low_S in flags_post, "Low_S should be active")

	// Regtest: all flags active at height 0
	regtest := REGTEST_PARAMS
	flags_reg := get_script_flags(0, &regtest)
	testing.expect(t, .P2SH in flags_reg, "P2SH active at height 0 on regtest")
	testing.expect(t, .DER_Sig in flags_reg, "DER_Sig active at height 0 regtest")
	testing.expect(t, .Witness in flags_reg, "Witness active at height 0 regtest")

	// Testnet3: P2SH not active before height 514
	testnet3 := TESTNET3_PARAMS
	flags_t3_pre := get_script_flags(513, &testnet3)
	testing.expect(t, .P2SH not_in flags_t3_pre, "P2SH not active at testnet3 height 513")
	flags_t3_post := get_script_flags(514, &testnet3)
	testing.expect(t, .P2SH in flags_t3_post, "P2SH active at testnet3 height 514")
}

// --- Coinbase detection tests ---

@(test)
test_is_coinbase :: proc(t: ^testing.T) {
	// Valid coinbase
	cb := make_coinbase(0)
	testing.expect(t, is_coinbase_tx(&cb), "should detect coinbase")

	// Non-coinbase: normal prevout hash
	non_cb := cb
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = cb.inputs[0]
	inputs[0].previous_output.hash[0] = 0x01
	non_cb.inputs = inputs
	testing.expect(t, !is_coinbase_tx(&non_cb), "should not detect non-coinbase")

	// Non-coinbase: wrong index
	non_cb2 := cb
	inputs2 := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs2[0] = cb.inputs[0]
	inputs2[0].previous_output.index = 0
	non_cb2.inputs = inputs2
	testing.expect(t, !is_coinbase_tx(&non_cb2), "wrong index should not be coinbase")
}

// --- Legacy sigop count tests ---

@(test)
test_legacy_sigop_count :: proc(t: ^testing.T) {
	// P2PKH script: OP_DUP OP_HASH160 <20> <hash> OP_EQUALVERIFY OP_CHECKSIG
	p2pkh := hex_decode("76a914" + "0000000000000000000000000000000000000000" + "88ac")
	testing.expect_value(t, count_legacy_sigops(p2pkh), 1)

	// P2PK script: <33> <pubkey> OP_CHECKSIG
	p2pk := make([]byte, 35, context.temp_allocator)
	p2pk[0] = 0x21 // push 33 bytes
	p2pk[34] = 0xac // OP_CHECKSIG
	testing.expect_value(t, count_legacy_sigops(p2pk[:]), 1)

	// Bare multisig: OP_1 <pubkey1> <pubkey2> OP_2 OP_CHECKMULTISIG
	// OP_CHECKMULTISIG counts as 20 in legacy sigops
	multisig := []byte{0x51, 0xae} // OP_1 OP_CHECKMULTISIG (simplified)
	testing.expect_value(t, count_legacy_sigops(multisig), 20)

	// OP_CHECKSIG inside push data should NOT be counted
	// push 1 byte: 0xac (which is OP_CHECKSIG opcode value)
	inside_push := []byte{0x01, 0xac}
	testing.expect_value(t, count_legacy_sigops(inside_push), 0)
}

// --- Block weight tests ---

@(test)
test_block_weight :: proc(t: ^testing.T) {
	// Non-witness block: weight = total_size * 4
	cb := make_coinbase(0)
	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	merkle := crypto.merkle_root([]crypto.Hash256{wire.tx_id(&cb)})
	block := wire.Block {
		header = wire.Block_Header {
			version    = 1,
			bits       = REGTEST_PARAMS.pow_limit_bits,
			merkle_root = merkle,
		},
		txs = txs,
	}

	weight := get_block_weight(&block)
	// For non-witness tx: base_size == total_size, so weight = size * 4
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx_no_witness(&w, &cb)
	tx_size := wire.writer_len(&w)
	// Header (80) + compact_size(1) + tx_size
	expected_size := 80 + 1 + tx_size
	testing.expect_value(t, weight, expected_size * 4)
}

@(test)
test_block_weight_witness :: proc(t: ^testing.T) {
	// Witness block: weight = base_size * 3 + total_size
	cb := make_coinbase(0)

	// Add witness data to coinbase
	witness := make([][][]byte, 1, context.temp_allocator)
	witness_items := make([][]byte, 1, context.temp_allocator)
	nonce := make([]byte, 32, context.temp_allocator)
	witness_items[0] = nonce
	witness[0] = witness_items
	cb.witness = witness

	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	merkle := crypto.merkle_root([]crypto.Hash256{wire.tx_id(&cb)})
	block := wire.Block {
		header = wire.Block_Header {
			version    = 1,
			bits       = REGTEST_PARAMS.pow_limit_bits,
		},
		txs = txs,
	}
	block.header.merkle_root = merkle

	weight := get_block_weight(&block)

	// Calculate expected
	w_base := wire.writer_init(context.temp_allocator)
	wire.serialize_tx_no_witness(&w_base, &cb)
	base_tx := wire.writer_len(&w_base)

	w_total := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w_total, &cb)
	total_tx := wire.writer_len(&w_total)

	expected_base := 80 + 1 + base_tx
	expected_total := 80 + 1 + total_tx
	expected_weight := expected_base * 3 + expected_total

	testing.expect_value(t, weight, expected_weight)
	// Witness tx should have total > base (marker+flag+witness data)
	testing.expect(t, total_tx > base_tx, "witness tx total_size should exceed base_size")
}

// --- Difficulty adjustment tests ---

@(test)
test_difficulty_adjustment :: proc(t: ^testing.T) {
	params := MAINNET_PARAMS

	// Same timespan = same difficulty
	same := calculate_next_work_required(0, params.target_timespan, 0x1d00ffff, &params)
	testing.expect_value(t, same, u32(0x1d00ffff))

	// Use a harder starting difficulty so 4x doesn't hit the pow_limit ceiling.
	// 0x1b00ffff target is 1/65536 of pow_limit, so 4x is well below the limit.
	start_bits := u32(0x1b00ffff)
	original_target := bits_to_target(start_bits)

	// 4x timespan = 4x easier (larger target)
	four_x_time := params.target_timespan * 4
	easier := calculate_next_work_required(0, four_x_time, start_bits, &params)
	easier_target := bits_to_target(easier)
	testing.expect(t, u256_compare(easier_target, original_target) > 0, "4x timespan should yield easier target")

	// 1/4 timespan = 4x harder (smaller target)
	quarter_time := params.target_timespan / 4
	harder := calculate_next_work_required(0, quarter_time, start_bits, &params)
	harder_target := bits_to_target(harder)
	testing.expect(t, u256_compare(harder_target, original_target) < 0, "1/4 timespan should yield harder target")

	// Extreme values get clamped to 4x limits
	extreme_easy := calculate_next_work_required(0, params.target_timespan * 100, start_bits, &params)
	testing.expect_value(t, extreme_easy, easier) // clamped at 4x

	extreme_hard := calculate_next_work_required(0, 1, start_bits, &params)
	testing.expect_value(t, extreme_hard, harder) // clamped at 1/4
}

// --- Check block (regtest) tests ---

@(test)
test_check_block_regtest :: proc(t: ^testing.T) {
	params := REGTEST_PARAMS

	cb := make_coinbase(1)
	txs := make([]wire.Tx, 1, context.temp_allocator)
	txs[0] = cb

	tx_id := wire.tx_id(&cb)
	merkle := crypto.merkle_root([]crypto.Hash256{tx_id})

	block := wire.Block {
		header = wire.Block_Header {
			version     = 0x20000000,
			merkle_root = merkle,
			timestamp   = 1231006505,
			bits        = params.pow_limit_bits,
		},
		txs = txs,
	}

	// Mine valid PoW
	mine_block(&block, &params)

	err := check_block(&block, 1, &params)
	testing.expect_value(t, err, Consensus_Error.None)

	// Corrupt merkle root -> Bad_Merkle_Root
	saved_root := block.header.merkle_root
	block.header.merkle_root[0] ~= 0xff
	// Need to re-mine since header changed
	mine_block(&block, &params)
	err2 := check_block(&block, 1, &params)
	testing.expect_value(t, err2, Consensus_Error.Bad_Merkle_Root)

	// Restore and test no-tx block
	block.header.merkle_root = saved_root
	mine_block(&block, &params)
	saved_txs := block.txs
	block.txs = nil
	// Re-mine for the header that was valid
	err3 := check_block(&block, 1, &params)
	testing.expect_value(t, err3, Consensus_Error.No_Transactions)
	block.txs = saved_txs
}

// --- Witness commitment tests ---

@(test)
test_check_witness_commitment :: proc(t: ^testing.T) {
	// Build a block with witness commitment
	cb := make_coinbase(1)

	// Create a second tx with witness data
	tx2_inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	tx2_inputs[0] = wire.Tx_In {
		previous_output = wire.Outpoint{index = 0},
		script_sig      = nil,
		sequence        = 0xffffffff,
	}
	tx2_inputs[0].previous_output.hash[0] = 0x01 // non-null prevout
	tx2_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	tx2_outputs[0] = wire.Tx_Out{value = 0, script_pubkey = make([]byte, 0, context.temp_allocator)}
	tx2_witness := make([][][]byte, 1, context.temp_allocator)
	tx2_witness_items := make([][]byte, 1, context.temp_allocator)
	tx2_witness_items[0] = make([]byte, 4, context.temp_allocator)
	tx2_witness_items[0][0] = 0x01
	tx2_witness[0] = tx2_witness_items

	tx2 := wire.Tx {
		version  = 1,
		inputs   = tx2_inputs,
		outputs  = tx2_outputs,
		witness  = tx2_witness,
		locktime = 0,
	}

	// Compute witness merkle root
	wtxids := make([]crypto.Hash256, 2, context.temp_allocator)
	wtxids[0] = crypto.HASH_ZERO // coinbase
	wtxids[1] = wire.tx_witness_id(&tx2)
	witness_root := crypto.merkle_root(wtxids)

	// Witness nonce (32 zero bytes)
	nonce := make([]byte, 32, context.temp_allocator)

	// Compute commitment = sha256d(witness_root || nonce)
	commitment_data: [64]byte
	for i in 0 ..< 32 {
		commitment_data[i] = witness_root[i]
	}
	// nonce is all zeros, commitment_data[32..63] already zero

	commitment := crypto.sha256d(commitment_data[:])

	// Build commitment output: OP_RETURN OP_PUSH36 0xaa21a9ed <commitment>
	commitment_script := make([]byte, 38, context.temp_allocator)
	commitment_script[0] = 0x6a // OP_RETURN
	commitment_script[1] = 0x24 // push 36 bytes
	commitment_script[2] = 0xaa
	commitment_script[3] = 0x21
	commitment_script[4] = 0xa9
	commitment_script[5] = 0xed
	for i in 0 ..< 32 {
		commitment_script[6 + i] = commitment[i]
	}

	// Add commitment output to coinbase
	new_outputs := make([]wire.Tx_Out, 2, context.temp_allocator)
	new_outputs[0] = cb.outputs[0]
	new_outputs[1] = wire.Tx_Out{value = 0, script_pubkey = commitment_script}
	cb.outputs = new_outputs

	// Add witness nonce to coinbase
	cb_witness := make([][][]byte, 1, context.temp_allocator)
	cb_witness_items := make([][]byte, 1, context.temp_allocator)
	cb_witness_items[0] = nonce
	cb_witness[0] = cb_witness_items
	cb.witness = cb_witness

	txs := make([]wire.Tx, 2, context.temp_allocator)
	txs[0] = cb
	txs[1] = tx2

	block := wire.Block{txs = txs}

	// Correct commitment should pass
	err := check_witness_commitment(&block)
	testing.expect_value(t, err, Consensus_Error.None)

	// Corrupt commitment -> should fail
	commitment_script[6] ~= 0xff
	err2 := check_witness_commitment(&block)
	testing.expect_value(t, err2, Consensus_Error.Bad_Witness_Commitment)
}

// --- Tx sanity tests ---

@(test)
test_check_tx_sanity :: proc(t: ^testing.T) {
	// Valid coinbase
	cb := make_coinbase(0)
	testing.expect_value(t, check_tx_sanity(&cb), Consensus_Error.None)

	// Empty inputs
	empty_in := wire.Tx{version = 1, inputs = nil, outputs = cb.outputs}
	testing.expect_value(t, check_tx_sanity(&empty_in), Consensus_Error.Bad_Tx_Empty_Inputs)

	// Empty outputs
	empty_out := wire.Tx{version = 1, inputs = cb.inputs, outputs = nil}
	testing.expect_value(t, check_tx_sanity(&empty_out), Consensus_Error.Bad_Tx_Empty_Outputs)

	// Negative output value
	neg_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	neg_outputs[0] = wire.Tx_Out{value = -1, script_pubkey = nil}
	neg_tx := wire.Tx{version = 1, inputs = cb.inputs, outputs = neg_outputs}
	testing.expect_value(t, check_tx_sanity(&neg_tx), Consensus_Error.Bad_Tx_Negative_Value)

	// Too-large output value
	big_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	big_outputs[0] = wire.Tx_Out{value = MAX_MONEY + 1, script_pubkey = nil}
	big_tx := wire.Tx{version = 1, inputs = cb.inputs, outputs = big_outputs}
	testing.expect_value(t, check_tx_sanity(&big_tx), Consensus_Error.Bad_Tx_Too_Large_Value)
}

// --- get_difficulty tests ---

@(test)
test_get_difficulty :: proc(t: ^testing.T) {
	// Genesis block bits (easiest difficulty) → difficulty = 1.0
	diff := get_difficulty(0x1d00ffff)
	testing.expect(t, diff >= 0.999 && diff <= 1.001, fmt.tprintf("genesis difficulty should be ~1.0, got %f", diff))

	// Higher difficulty (smaller target) → larger number
	diff2 := get_difficulty(0x1b0404cb) // Example mainnet block
	testing.expect(t, diff2 > 1.0, fmt.tprintf("higher difficulty block should be >1.0, got %f", diff2))

	// Zero mantissa → 0
	diff3 := get_difficulty(0x1d000000)
	testing.expect_value(t, diff3, f64(0.0))

	// Negative flag set → 0
	diff4 := get_difficulty(0x1d800000)
	testing.expect_value(t, diff4, f64(0.0))
}

// --- u256_compare tests ---

@(test)
test_u256_compare :: proc(t: ^testing.T) {
	a, b: [32]byte

	// Equal
	testing.expect_value(t, u256_compare(a, b), 0)

	// a < b
	b[31] = 1
	testing.expect_value(t, u256_compare(a, b), -1)

	// a > b
	a[0] = 1
	testing.expect_value(t, u256_compare(a, b), 1)
}

// --- u256_is_zero tests ---

@(test)
test_u256_is_zero :: proc(t: ^testing.T) {
	zero: [32]byte
	testing.expect(t, u256_is_zero(zero), "zero should be zero")

	nonzero: [32]byte
	nonzero[15] = 1
	testing.expect(t, !u256_is_zero(nonzero), "non-zero should not be zero")
}

// --- hash_meets_target tests ---

@(test)
test_hash_meets_target :: proc(t: ^testing.T) {
	target := bits_to_target(0x1d00ffff) // Genesis difficulty

	// Zero hash should always meet any target
	zero_hash: Hash256
	testing.expect(t, hash_meets_target(zero_hash, target), "zero hash should meet target")

	// Max hash (all 0xFF) should NOT meet any reasonable target
	max_hash: Hash256
	for i in 0 ..< 32 { max_hash[i] = 0xFF }
	testing.expect(t, !hash_meets_target(max_hash, target), "max hash should not meet target")
}

// --- get_tx_weight / get_tx_vsize tests ---

@(test)
test_get_tx_weight_vsize :: proc(t: ^testing.T) {
	// Build a simple non-witness tx
	cb := make_coinbase(0)
	weight := get_tx_weight(&cb)
	vsize := get_tx_vsize(&cb)

	// Non-witness tx: weight = size * 4 (since base == total)
	w := wire.writer_init(context.temp_allocator)
	wire.serialize_tx(&w, &cb)
	raw_size := wire.writer_len(&w)

	testing.expect_value(t, weight, raw_size * 4)
	testing.expect_value(t, vsize, raw_size) // vsize = weight/4 for non-witness
}

// --- check_block_header tests ---

@(test)
test_check_block_header :: proc(t: ^testing.T) {
	params := REGTEST_PARAMS

	// Use regtest genesis header (known valid PoW)
	header := params.genesis_header
	err := check_block_header(&header, &params)
	testing.expect_value(t, err, Consensus_Error.None)

	// Invalid PoW: change nonce to break the hash
	bad_header := header
	bad_header.nonce = 99999999
	err2 := check_block_header(&bad_header, &params)
	testing.expect_value(t, err2, Consensus_Error.Bad_Pow)
}
