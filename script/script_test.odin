package script

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

// Helper to run a simple script and check success/failure.
run_script_test :: proc(t: ^testing.T, script_sig_hex: string, script_pubkey_hex: string, flags: Verify_Flags = {}, expected_err: Script_Error = nil) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	sig_bytes := hex_decode(script_sig_hex)
	pub_bytes := hex_decode(script_pubkey_hex)

	// Minimal transaction for testing
	tx := wire.Tx{
		version  = 1,
		inputs   = make([]wire.Tx_In, 1, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 0,
	}
	tx.inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{},
		script_sig      = sig_bytes,
		sequence        = 0xffffffff,
	}
	tx.outputs[0] = wire.Tx_Out{
		value         = 0,
		script_pubkey = nil,
	}

	verifier := Script_Verifier{
		tx        = &tx,
		input_idx = 0,
		amount    = 0,
		flags     = flags,
	}

	err := verify_script(&verifier, sig_bytes, pub_bytes, nil)
	testing.expect(t, expected_err == err, fmt.tprintf("Expected error %v, got %v", expected_err, err))
}

// --- Script Number tests ---

@(test)
test_script_num_zero :: proc(t: ^testing.T) {
	// Zero encodes as empty array
	encoded := script_num_encode(0, context.temp_allocator)
	testing.expect_value(t, len(encoded), 0)

	// Empty array decodes to zero
	val, err := script_num_decode(nil)
	testing.expect(t, err == nil, "decode nil should succeed")
	testing.expect_value(t, val, i64(0))

	// Empty slice decodes to zero
	empty: []byte
	val2, err2 := script_num_decode(empty)
	testing.expect(t, err2 == nil, "decode empty should succeed")
	testing.expect_value(t, val2, i64(0))
}

@(test)
test_script_num_positive :: proc(t: ^testing.T) {
	// 1 -> [0x01]
	enc := script_num_encode(1, context.temp_allocator)
	testing.expect_value(t, len(enc), 1)
	testing.expect_value(t, enc[0], u8(0x01))

	val, err := script_num_decode(enc)
	testing.expect(t, err == nil, "decode 1 should succeed")
	testing.expect_value(t, val, i64(1))

	// 127 -> [0x7f]
	enc2 := script_num_encode(127, context.temp_allocator)
	testing.expect_value(t, len(enc2), 1)
	testing.expect_value(t, enc2[0], u8(0x7f))

	// 128 -> [0x80, 0x00] (needs extra byte for sign bit)
	enc3 := script_num_encode(128, context.temp_allocator)
	testing.expect_value(t, len(enc3), 2)
	testing.expect_value(t, enc3[0], u8(0x80))
	testing.expect_value(t, enc3[1], u8(0x00))

	val3, err3 := script_num_decode(enc3)
	testing.expect(t, err3 == nil, "decode 128 should succeed")
	testing.expect_value(t, val3, i64(128))

	// 255 -> [0xff, 0x00]
	enc4 := script_num_encode(255, context.temp_allocator)
	testing.expect_value(t, len(enc4), 2)
	testing.expect_value(t, enc4[0], u8(0xff))
	testing.expect_value(t, enc4[1], u8(0x00))
}

@(test)
test_script_num_negative :: proc(t: ^testing.T) {
	// -1 -> [0x81]
	enc := script_num_encode(-1, context.temp_allocator)
	testing.expect_value(t, len(enc), 1)
	testing.expect_value(t, enc[0], u8(0x81))

	val, err := script_num_decode(enc)
	testing.expect(t, err == nil, "decode -1 should succeed")
	testing.expect_value(t, val, i64(-1))

	// -128 -> [0x80, 0x80]
	enc2 := script_num_encode(-128, context.temp_allocator)
	testing.expect_value(t, len(enc2), 2)
	testing.expect_value(t, enc2[0], u8(0x80))
	testing.expect_value(t, enc2[1], u8(0x80))

	val2, err2 := script_num_decode(enc2)
	testing.expect(t, err2 == nil, "decode -128 should succeed")
	testing.expect_value(t, val2, i64(-128))
}

@(test)
test_script_num_overflow :: proc(t: ^testing.T) {
	// 5-byte value should fail with default max_len=4
	big := []byte{0x01, 0x02, 0x03, 0x04, 0x05}
	_, err := script_num_decode(big)
	testing.expect_value(t, err, Script_Error.Script_Num_Overflow)

	// But succeed with max_len=5
	val, err2 := script_num_decode(big, max_len = 5)
	testing.expect(t, err2 == nil, "5-byte with max_len=5 should succeed")
	testing.expect(t, val != 0, "value should be non-zero")
}

@(test)
test_script_num_non_minimal :: proc(t: ^testing.T) {
	// [0x00] is non-minimal encoding of 0 (should be empty)
	data := []byte{0x00}
	_, err := script_num_decode(data, require_minimal = true)
	testing.expect_value(t, err, Script_Error.Minimal_Data)

	// [0x01, 0x00] is non-minimal encoding of 1 (should be [0x01])
	data2 := []byte{0x01, 0x00}
	_, err2 := script_num_decode(data2, require_minimal = true)
	testing.expect_value(t, err2, Script_Error.Minimal_Data)
}

@(test)
test_script_num_roundtrip :: proc(t: ^testing.T) {
	// Test roundtrip for various values
	for val in ([]i64{0, 1, -1, 127, -127, 128, -128, 255, -255, 256, -256, 32767, -32767, 32768, -32768}) {
		enc := script_num_encode(val, context.temp_allocator)
		dec, err := script_num_decode(enc)
		testing.expect(t, err == nil, "decode should succeed")
		testing.expect(t, val == dec, fmt.tprintf("roundtrip failed for %d: got %d", val, dec))
	}
}

// --- Stack tests ---

@(test)
test_stack_push_pop :: proc(t: ^testing.T) {
	s := stack_init(context.temp_allocator)
	testing.expect_value(t, stack_size(&s), 0)

	stack_push(&s, []byte{1, 2, 3})
	testing.expect_value(t, stack_size(&s), 1)

	data, err := stack_pop(&s)
	testing.expect(t, err == nil, "pop should succeed")
	testing.expect_value(t, len(data), 3)
	testing.expect_value(t, data[0], u8(1))
	testing.expect_value(t, stack_size(&s), 0)
}

@(test)
test_stack_underflow :: proc(t: ^testing.T) {
	s := stack_init(context.temp_allocator)
	_, err := stack_pop(&s)
	testing.expect_value(t, err, Script_Error.Invalid_Stack_Operation)
}

@(test)
test_stack_to_bool :: proc(t: ^testing.T) {
	// Empty is false
	testing.expect(t, !stack_to_bool(nil), "nil should be false")
	testing.expect(t, !stack_to_bool([]byte{}), "empty should be false")

	// All zeros is false
	testing.expect(t, !stack_to_bool([]byte{0x00}), "0x00 should be false")
	testing.expect(t, !stack_to_bool([]byte{0x00, 0x00}), "0x0000 should be false")

	// Negative zero is false
	testing.expect(t, !stack_to_bool([]byte{0x80}), "0x80 (neg zero) should be false")

	// Non-zero is true
	testing.expect(t, stack_to_bool([]byte{0x01}), "0x01 should be true")
	testing.expect(t, stack_to_bool([]byte{0x80, 0x00}), "0x8000 should be true") // 128, not negative zero
	testing.expect(t, stack_to_bool([]byte{0x00, 0x01}), "0x0001 should be true")
}

// --- Script classification tests ---

@(test)
test_classify_p2pkh :: proc(t: ^testing.T) {
	// OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
	s := hex_decode("76a914" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba" + "88ac")
	testing.expect_value(t, classify_script(s), Script_Type.P2PKH)
}

@(test)
test_classify_p2sh :: proc(t: ^testing.T) {
	// OP_HASH160 <20 bytes> OP_EQUAL
	s := hex_decode("a914" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba" + "87")
	testing.expect_value(t, classify_script(s), Script_Type.P2SH)
}

@(test)
test_classify_p2wpkh :: proc(t: ^testing.T) {
	// OP_0 <20 bytes>
	s := hex_decode("0014" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba")
	testing.expect_value(t, classify_script(s), Script_Type.P2WPKH)
}

@(test)
test_classify_p2wsh :: proc(t: ^testing.T) {
	// OP_0 <32 bytes>
	s := hex_decode("0020" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba89abcdefabbaabbaabbaabba")
	testing.expect_value(t, classify_script(s), Script_Type.P2WSH)
}

@(test)
test_classify_p2tr :: proc(t: ^testing.T) {
	// OP_1 <32 bytes>
	s := hex_decode("5120" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba89abcdefabbaabbaabbaabba")
	testing.expect_value(t, classify_script(s), Script_Type.P2TR)
}

@(test)
test_classify_null_data :: proc(t: ^testing.T) {
	// OP_RETURN <data>
	s := hex_decode("6a0568656c6c6f")
	testing.expect_value(t, classify_script(s), Script_Type.Null_Data)
}

@(test)
test_classify_p2pk :: proc(t: ^testing.T) {
	// <33-byte compressed pubkey> OP_CHECKSIG
	s := hex_decode("21" + "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" + "ac")
	testing.expect_value(t, classify_script(s), Script_Type.P2PK)
}

@(test)
test_classify_witness_unknown :: proc(t: ^testing.T) {
	// OP_2 <20 bytes> — witness version 2 with 20-byte program
	s := hex_decode("5214" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba")
	testing.expect_value(t, classify_script(s), Script_Type.Witness_Unknown)
}

// --- is_push_only tests ---

@(test)
test_is_push_only :: proc(t: ^testing.T) {
	// Push-only script: OP_1 OP_PUSH3 <3 bytes>
	testing.expect(t, is_push_only(hex_decode("5103010203")), "should be push-only")

	// Not push-only: contains OP_DUP
	testing.expect(t, !is_push_only(hex_decode("76")), "OP_DUP should not be push-only")

	// Empty script is push-only
	testing.expect(t, is_push_only(nil), "empty should be push-only")
}

// --- Simple script execution tests ---

@(test)
test_script_op_true :: proc(t: ^testing.T) {
	// scriptSig: OP_1, scriptPubKey: (empty — just needs truthy stack top)
	// Actually: scriptSig: (empty), scriptPubKey: OP_1
	run_script_test(t, "", "51", expected_err = nil)
}

@(test)
test_script_op_false :: proc(t: ^testing.T) {
	// scriptPubKey: OP_0 — leaves false on stack
	run_script_test(t, "", "00", expected_err = .Eval_False)
}

@(test)
test_script_op_return :: proc(t: ^testing.T) {
	// scriptPubKey: OP_RETURN — always fails
	run_script_test(t, "", "6a", expected_err = .Op_Return)
}

@(test)
test_script_add_equal :: proc(t: ^testing.T) {
	// scriptSig: OP_2 OP_3, scriptPubKey: OP_ADD OP_5 OP_EQUAL
	// 2 + 3 = 5 -> true
	run_script_test(t, "5253", "935587")
}

@(test)
test_script_add_not_equal :: proc(t: ^testing.T) {
	// scriptSig: OP_2 OP_3, scriptPubKey: OP_ADD OP_6 OP_EQUAL
	// 2 + 3 = 5 != 6 -> false
	run_script_test(t, "5253", "935687", expected_err = .Eval_False)
}

@(test)
test_script_if_else_endif :: proc(t: ^testing.T) {
	// scriptSig: OP_1
	// scriptPubKey: OP_IF OP_2 OP_ELSE OP_3 OP_ENDIF
	// Condition is true, so pushes 2
	run_script_test(t, "51", "6352675368")
}

@(test)
test_script_if_false_branch :: proc(t: ^testing.T) {
	// scriptSig: OP_0
	// scriptPubKey: OP_IF OP_0 OP_ELSE OP_1 OP_ENDIF
	// Condition is false, so takes else branch -> pushes 1 (true)
	run_script_test(t, "00", "6300675168")
}

@(test)
test_script_disabled_opcode :: proc(t: ^testing.T) {
	// OP_CAT (0x7e) is disabled
	run_script_test(t, "51", "7e", expected_err = .Disabled_Opcode)
}

@(test)
test_script_opcount_limit :: proc(t: ^testing.T) {
	// Build a script with 202 counted opcodes (> 201 limit)
	// OP_1 then 202x OP_NOP = 202 counted ops -> exceeds 201 limit
	// OP_NOP = 0x61, counted since > OP_16
	script := make([]byte, 203, context.temp_allocator)
	script[0] = u8(Opcode.OP_1) // push 1 (not counted)
	for i in 1 ..< 203 {
		script[i] = u8(Opcode.OP_NOP) // counted
	}
	pubkey_hex := hex_encode(script)
	run_script_test(t, "", pubkey_hex, expected_err = .Op_Count)
}

// --- Witness program detection ---

@(test)
test_is_witness_program :: proc(t: ^testing.T) {
	// P2WPKH: OP_0 <20 bytes>
	p2wpkh := hex_decode("0014" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba")
	ver, prog, ok := is_witness_program(p2wpkh)
	testing.expect(t, ok, "should be witness program")
	testing.expect_value(t, ver, 0)
	testing.expect_value(t, len(prog), 20)

	// P2WSH: OP_0 <32 bytes>
	p2wsh := hex_decode("0020" + "89abcdefabbaabbaabbaabbaabbaabbaabbaabba89abcdefabbaabbaabbaabba")
	ver2, prog2, ok2 := is_witness_program(p2wsh)
	testing.expect(t, ok2, "should be witness program")
	testing.expect_value(t, ver2, 0)
	testing.expect_value(t, len(prog2), 32)

	// Not a witness program (too short)
	_, _, ok3 := is_witness_program(hex_decode("0001ff"))
	testing.expect(t, !ok3, "too short should not be witness program")
}

// --- Sighash tests ---

@(test)
test_sighash_single_bug :: proc(t: ^testing.T) {
	// SIGHASH_SINGLE bug: when input_idx >= len(outputs), return 0x0100...00
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	tx := wire.Tx{
		version  = 1,
		inputs   = make([]wire.Tx_In, 2, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 0,
	}
	tx.inputs[0] = wire.Tx_In{sequence = 0xffffffff}
	tx.inputs[1] = wire.Tx_In{sequence = 0xffffffff}
	tx.outputs[0] = wire.Tx_Out{value = 1000}

	// Input index 1, but only 1 output -> triggers the bug
	hash := compute_sighash_legacy(&tx, 1, nil, SIGHASH_SINGLE)

	// Should be 0x0100000000...00
	testing.expect_value(t, hash[0], u8(1))
	for i in 1 ..< 32 {
		testing.expect_value(t, hash[i], u8(0))
	}
}

@(test)
test_sighash_bip143_p2wpkh :: proc(t: ^testing.T) {
	// BIP143 test vector for native P2WPKH
	// From BIP143 example 1
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Tx: version=1, 2 inputs, 2 outputs, locktime=0x11000000
	tx_hex := "0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffff" +
	          "ef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff" +
	          "02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac" +
	          "9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac" +
	          "11000000"

	tx_bytes := hex_decode(tx_hex)
	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, tx_err == nil, "tx deserialization should succeed")

	// Script code for P2WPKH: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
	script_code := hex_decode("76a9141d0f172a0ecb48aee1be1f2687d2963ae33f71a188ac")

	// Input index 1, amount = 6 BTC (600000000 satoshis)
	amount: i64 = 600000000
	hash_type := SIGHASH_ALL

	hash := compute_sighash_witness_v0(&tx, 1, script_code, amount, hash_type)
	got := hex_encode(hash[:])

	// Expected sighash from BIP143
	testing.expect_value(t, got, "c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670")
}

// --- DER signature encoding test ---

@(test)
test_der_signature_validation :: proc(t: ^testing.T) {
	// Valid DER signature (from a real Bitcoin transaction) + sighash byte
	// 30 44 02 20 <32 bytes R> 02 20 <32 bytes S> 01
	valid_sig := hex_decode(
		"3044" +
		"0220" + "4e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd41" +
		"0220" + "181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d09" +
		"01",
	)
	testing.expect(t, is_valid_signature_encoding(valid_sig), "valid DER sig should pass")

	// Too short (< 9 bytes)
	testing.expect(t, !is_valid_signature_encoding(hex_decode("3006020101020101")), "too short should fail")

	// Wrong prefix
	bad := make([]byte, len(valid_sig), context.temp_allocator)
	copy(bad, valid_sig)
	bad[0] = 0x31
	testing.expect(t, !is_valid_signature_encoding(bad), "wrong prefix should fail")
}

// --- Hash opcode tests ---

@(test)
test_script_hash160 :: proc(t: ^testing.T) {
	// scriptSig: <pubkey_bytes>
	// scriptPubKey: OP_HASH160 <expected_hash> OP_EQUAL
	// Use a known pubkey -> hash160 pair
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	pubkey_bytes := hex_decode("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
	expected_hash := crypto.hash160(pubkey_bytes)

	// Build scriptSig: push 33 bytes (pubkey) = [0x21] + pubkey
	script_sig := make([]byte, 34, context.temp_allocator)
	script_sig[0] = 0x21
	copy(script_sig[1:], pubkey_bytes)

	// Build scriptPubKey: OP_HASH160 push20 <hash> OP_EQUAL
	script_pubkey := make([]byte, 23, context.temp_allocator)
	script_pubkey[0] = u8(Opcode.OP_HASH160)
	script_pubkey[1] = 0x14
	copy(script_pubkey[2:22], expected_hash[:])
	script_pubkey[22] = u8(Opcode.OP_EQUAL)

	tx := wire.Tx{
		version  = 1,
		inputs   = make([]wire.Tx_In, 1, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 0,
	}
	tx.inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{},
		script_sig      = script_sig,
		sequence        = 0xffffffff,
	}
	tx.outputs[0] = wire.Tx_Out{}

	verifier := Script_Verifier{
		tx        = &tx,
		input_idx = 0,
		amount    = 0,
		flags     = {},
	}

	err := verify_script(&verifier, script_sig, script_pubkey, nil)
	testing.expect(t, err == nil, "HASH160 script should pass")
}

// --- OP_CHECKLOCKTIMEVERIFY test ---

@(test)
test_script_cltv :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// scriptPubKey: <locktime> OP_CHECKLOCKTIMEVERIFY OP_DROP OP_1
	// locktime = 500000 = 0x07A120
	// Script num encoding of 500000: 20 a1 07
	// scriptPubKey: OP_PUSH3 20a107 OP_CLTV OP_DROP OP_1
	pub_hex := "0320a107" + "b1" + "75" + "51"

	tx := wire.Tx{
		version  = 1,
		inputs   = make([]wire.Tx_In, 1, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 500001, // tx locktime > script locktime -> should pass
	}
	tx.inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{},
		sequence        = 0xfffffffe, // not final
	}
	tx.outputs[0] = wire.Tx_Out{}

	verifier := Script_Verifier{
		tx        = &tx,
		input_idx = 0,
		amount    = 0,
		flags     = {.Check_Locktime},
	}

	pub_bytes := hex_decode(pub_hex)
	err := verify_script(&verifier, nil, pub_bytes, nil)
	testing.expect(t, err == nil, "CLTV with valid locktime should pass")

	// Now with tx locktime < script locktime -> should fail
	tx.locktime = 499999
	err2 := verify_script(&verifier, nil, pub_bytes, nil)
	testing.expect_value(t, err2, Script_Error.Unsatisfied_Locktime)
}

// --- Taproot / Phase 2b tests ---

@(test)
test_tagged_hash :: proc(t: ^testing.T) {
	// BIP340 tagged hash test: tagged_hash("BIP0340/challenge", data)
	// We'll verify the structure: SHA256(SHA256(tag) || SHA256(tag) || msg)
	result := crypto.tagged_hash("TapLeaf", []byte{0xc0, 0x01, 0x51})
	// Just verify it produces a 32-byte result that's not all zeros
	non_zero := false
	for b in result {
		if b != 0 { non_zero = true; break }
	}
	testing.expect(t, non_zero, "tagged hash should produce non-zero result")

	// Verify determinism
	result2 := crypto.tagged_hash("TapLeaf", []byte{0xc0, 0x01, 0x51})
	testing.expect(t, result == result2, "tagged hash should be deterministic")

	// Different tag should produce different result
	result3 := crypto.tagged_hash("TapBranch", []byte{0xc0, 0x01, 0x51})
	testing.expect(t, result != result3, "different tags should produce different results")
}

@(test)
test_op_sha1 :: proc(t: ^testing.T) {
	// SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
	// scriptSig: push "abc" (0x03 616263)
	// scriptPubKey: OP_SHA1 push20 <expected> OP_EQUAL
	expected_hex := "a9993e364706816aba3e25717850c26c9cd0d89d"
	expected := hex_decode(expected_hex)

	// Build scriptPubKey: OP_SHA1(0xa7) OP_PUSH20(0x14) <hash> OP_EQUAL(0x87)
	pub := make([]byte, 23, context.temp_allocator)
	pub[0] = u8(Opcode.OP_SHA1)
	pub[1] = 0x14
	copy(pub[2:22], expected)
	pub[22] = u8(Opcode.OP_EQUAL)

	sig_hex := "03" + "616263" // push 3 bytes "abc"
	run_script_test(t, sig_hex, hex_encode(pub))
}

@(test)
test_op_success_in_tapscript :: proc(t: ^testing.T) {
	// OP_SUCCESS opcodes: 0x50 (OP_RESERVED), 0xbb-0xfe etc.
	// In tapscript context, these should cause immediate success
	testing.expect(t, is_op_success(0x50), "0x50 should be OP_SUCCESS")
	testing.expect(t, is_op_success(0xbb), "0xbb should be OP_SUCCESS")
	testing.expect(t, is_op_success(0xfe), "0xfe should be OP_SUCCESS")
	testing.expect(t, !is_op_success(0x51), "0x51 (OP_1) should not be OP_SUCCESS")
	testing.expect(t, !is_op_success(0xac), "0xac (OP_CHECKSIG) should not be OP_SUCCESS")
	testing.expect(t, !is_op_success(0xba), "0xba (OP_CHECKSIGADD) should not be OP_SUCCESS")

	// Test _has_op_success scanner
	testing.expect(t, _has_op_success([]byte{0x51, 0xbb}), "script with 0xbb should have OP_SUCCESS")
	testing.expect(t, !_has_op_success([]byte{0x51, 0xac}), "script with only OP_CHECKSIG should not have OP_SUCCESS")
	// OP_SUCCESS inside push data should not trigger
	testing.expect(t, !_has_op_success([]byte{0x01, 0xbb}), "OP_SUCCESS inside push data should not trigger")
}

@(test)
test_taproot_sighash_type_validation :: proc(t: ^testing.T) {
	testing.expect(t, _is_valid_taproot_hash_type(0x00), "DEFAULT should be valid")
	testing.expect(t, _is_valid_taproot_hash_type(0x01), "ALL should be valid")
	testing.expect(t, _is_valid_taproot_hash_type(0x02), "NONE should be valid")
	testing.expect(t, _is_valid_taproot_hash_type(0x03), "SINGLE should be valid")
	testing.expect(t, _is_valid_taproot_hash_type(0x81), "ALL|ANYONECANPAY should be valid")
	testing.expect(t, !_is_valid_taproot_hash_type(0x04), "0x04 should be invalid")
	testing.expect(t, !_is_valid_taproot_hash_type(0xff), "0xff should be invalid")
}

@(test)
test_tapleaf_hash :: proc(t: ^testing.T) {
	// Compute tapleaf hash for a simple OP_TRUE script
	script := []byte{0x51} // OP_1
	hash := compute_tapleaf_hash(TAPROOT_LEAF_TAPSCRIPT, script)

	// Verify non-zero and deterministic
	non_zero := false
	for b in hash { if b != 0 { non_zero = true; break } }
	testing.expect(t, non_zero, "tapleaf hash should be non-zero")

	hash2 := compute_tapleaf_hash(TAPROOT_LEAF_TAPSCRIPT, script)
	testing.expect(t, hash == hash2, "tapleaf hash should be deterministic")

	// Different leaf version should produce different hash
	hash3 := compute_tapleaf_hash(0xc2, script)
	testing.expect(t, hash != hash3, "different leaf version should produce different hash")
}

@(test)
test_checkmultisig_disabled_tapscript :: proc(t: ^testing.T) {
	// In tapscript mode, OP_CHECKMULTISIG should fail with Taproot_Checkmultisig_Disabled
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Build a simple script: OP_0 OP_0 OP_CHECKMULTISIG
	script := []byte{u8(Opcode.OP_0), u8(Opcode.OP_0), u8(Opcode.OP_CHECKMULTISIG)}

	tx := wire.Tx{
		version  = 2,
		inputs   = make([]wire.Tx_In, 1, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 0,
	}
	tx.inputs[0] = wire.Tx_In{sequence = 0xffffffff}
	tx.outputs[0] = wire.Tx_Out{}

	verifier := Script_Verifier{
		tx        = &tx,
		input_idx = 0,
		amount    = 0,
		flags     = STANDARD_FLAGS,
	}

	stack := stack_init(context.temp_allocator)
	// Push dummy element for multisig
	stack_push(&stack, nil)

	err := execute_script(&verifier, script, &stack, exec_mode = .Tapscript)
	testing.expect_value(t, err, Script_Error.Taproot_Checkmultisig_Disabled)
}

@(test)
test_taproot_sighash_computation :: proc(t: ^testing.T) {
	// Test basic sighash computation structure
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	tx := wire.Tx{
		version  = 2,
		inputs   = make([]wire.Tx_In, 1, context.temp_allocator),
		outputs  = make([]wire.Tx_Out, 1, context.temp_allocator),
		locktime = 0,
	}
	tx.inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{},
		sequence        = 0xffffffff,
	}
	tx.outputs[0] = wire.Tx_Out{
		value         = 50000,
		script_pubkey = hex_decode("5120" + "a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"),
	}

	spent_output := wire.Tx_Out{
		value         = 100000,
		script_pubkey = hex_decode("5120" + "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"),
	}
	spent_outputs := []wire.Tx_Out{spent_output}

	verifier := Script_Verifier{
		tx             = &tx,
		input_idx      = 0,
		amount         = 100000,
		flags          = STANDARD_FLAGS,
		spent_outputs  = spent_outputs,
	}

	// Compute sighash with DEFAULT type (key path)
	sighash := compute_sighash_taproot(&verifier, SIGHASH_DEFAULT)

	// Should be deterministic
	sighash2 := compute_sighash_taproot(&verifier, SIGHASH_DEFAULT)
	testing.expect(t, sighash == sighash2, "taproot sighash should be deterministic")

	// Different hash_type should produce different result
	sighash3 := compute_sighash_taproot(&verifier, SIGHASH_NONE)
	testing.expect(t, sighash != sighash3, "different hash_type should produce different sighash")

	// SIGHASH_ALL should produce same as DEFAULT
	sighash4 := compute_sighash_taproot(&verifier, SIGHASH_ALL)
	// These are NOT the same because the hash_type byte differs in the preimage
	testing.expect(t, sighash != sighash4, "DEFAULT and ALL should differ (hash_type byte differs)")
}
