package script

import crypto "../crypto"
import "../wire"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
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

@(test)
test_sighash_bip143_p2sh_p2wpkh :: proc(t: ^testing.T) {
	// BIP143 Example 2: P2SH-P2WPKH
	// From https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki#p2sh-p2wpkh
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	tx_hex := "0100000001db6b1b20aa0fd7b23880be2ecbd4a98130974cf4748fb66092ac4d3ceb1a54770100000000feffffff" +
	          "02b8b4eb0b000000001976a914a457b684d7f0d539a46a45bbc043f35b59d0d96388ac" +
	          "0008af2f000000001976a914fd270b1ee6abcaea97fea7ad0402e8bd8ad6d77c88ac" +
	          "92040000"
	tx_bytes := hex_decode(tx_hex)
	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, tx_err == nil, "tx deserialization should succeed")

	// Script code for P2SH-P2WPKH: OP_DUP OP_HASH160 <20-byte-pubkey-hash> OP_EQUALVERIFY OP_CHECKSIG
	script_code := hex_decode("76a91479091972186c449eb1ded22b78e40d009bdf008988ac")

	// Input index 0, amount = 10 BTC (1000000000 satoshis)
	amount: i64 = 1000000000
	hash_type := SIGHASH_ALL

	hash := compute_sighash_witness_v0(&tx, 0, script_code, amount, hash_type)
	got := hex_encode(hash[:])

	// Expected sighash from BIP143 Example 2
	testing.expect_value(t, got, "64f3b0f4dd2bb3aa1ce8566d220cc74dda9df97d8490cc81d89d735c92e59fb6")
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
	// BIP 340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg)
	// Test vector: tagged_hash("BIP0340/challenge", 0x bytes) from BIP 340 reference
	// Verify against a known precomputed value.
	// tagged_hash("TapLeaf", [0xc0, 0x01, 0x51]) for OP_TRUE tapscript
	result := crypto.tagged_hash("TapLeaf", []byte{0xc0, 0x01, 0x51})
	expected := hex_decode("a85b2107f791b26a84e7586c28cec7cb61202ed3d01944d832500f363782d675")
	for i in 0 ..< 32 {
		testing.expect_value(t, result[i], expected[i])
	}

	// Different tag should produce different result
	result2 := crypto.tagged_hash("TapBranch", []byte{0xc0, 0x01, 0x51})
	testing.expect(t, result != result2, "different tags should produce different results")
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
	// Tapleaf hash for OP_TRUE (OP_1 = 0x51) with leaf version 0xc0
	// = tagged_hash("TapLeaf", 0xc0 || compact_size(1) || 0x51)
	// = tagged_hash("TapLeaf", [0xc0, 0x01, 0x51])
	script := []byte{0x51} // OP_1
	hash := compute_tapleaf_hash(TAPROOT_LEAF_TAPSCRIPT, script)

	expected := hex_decode("a85b2107f791b26a84e7586c28cec7cb61202ed3d01944d832500f363782d675")
	for i in 0 ..< 32 {
		testing.expect_value(t, hash[i], expected[i])
	}

	// Different leaf version should produce different hash
	hash2 := compute_tapleaf_hash(0xc2, script)
	testing.expect(t, hash != hash2, "different leaf version should produce different hash")
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
	// Test sighash computation with known expected values.
	// Tx: version=2, 1 input (zero outpoint, seq=0xffffffff), 1 output (50000 to P2TR), locktime=0
	// Spent output: value=100000, P2TR with pubkey=0xb0*32
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

	// SIGHASH_DEFAULT (0x00) — precomputed expected value
	sighash_default := compute_sighash_taproot(&verifier, SIGHASH_DEFAULT)
	expected_default := hex_decode("7eaa861a2f1031d0bec52f99a7b1ee17278073eb27acd531cdc25842cec448b5")
	for i in 0 ..< 32 {
		testing.expect_value(t, sighash_default[i], expected_default[i])
	}

	// SIGHASH_NONE (0x02)
	sighash_none := compute_sighash_taproot(&verifier, SIGHASH_NONE)
	expected_none := hex_decode("937fd128d7cb36b2b60e5c038f8f2991c30dc263dfbec6f691da92ed7df06a89")
	for i in 0 ..< 32 {
		testing.expect_value(t, sighash_none[i], expected_none[i])
	}

	// SIGHASH_ALL (0x01) — differs from DEFAULT because hash_type byte is in preimage
	sighash_all := compute_sighash_taproot(&verifier, SIGHASH_ALL)
	expected_all := hex_decode("cf06a1984e3bd5f3ded5e25b785a8a34bd6e3bddc33ef7a117f8f9198ab5f43d")
	for i in 0 ..< 32 {
		testing.expect_value(t, sighash_all[i], expected_all[i])
	}
}

@(test)
test_sighash_cache_consistency :: proc(t: ^testing.T) {
	// Verify that the sighash cache produces the same result as uncached.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	tx_hex := "0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffff" +
	          "ef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff" +
	          "02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac" +
	          "9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac" +
	          "11000000"
	tx_bytes := hex_decode(tx_hex)
	r := wire.reader_init(tx_bytes)
	tx, _ := wire.deserialize_tx(&r, context.temp_allocator)

	script_code := hex_decode("76a9141d0f172a0ecb48aee1be1f2687d2963ae33f71a188ac")
	amount: i64 = 600000000

	// Compute without cache
	h_no_cache := compute_sighash_witness_v0(&tx, 1, script_code, amount, SIGHASH_ALL)

	// Compute with cache
	cache: Sighash_Cache
	h_cached := compute_sighash_witness_v0(&tx, 1, script_code, amount, SIGHASH_ALL, &cache)

	testing.expect(t, h_no_cache == h_cached, "cached sighash should match uncached")
	testing.expect(t, cache.has_prevouts, "cache should have prevouts")
	testing.expect(t, cache.has_sequence, "cache should have sequence")
	testing.expect(t, cache.has_outputs, "cache should have outputs")

	// Second call should use cache (same result)
	h_cached2 := compute_sighash_witness_v0(&tx, 0, script_code, amount, SIGHASH_ALL, &cache)
	testing.expect(t, h_cached != h_cached2, "different input should produce different sighash")
}

@(test)
test_sighash_many_inputs_small_arena :: proc(t: ^testing.T) {
	// Simulate a tx with 1000 inputs verified on a small arena.
	// Without the sighash cache, this would exhaust the arena.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	NUM_INPUTS :: 1000
	arena_buf := make([]byte, 2 * 1024 * 1024) // 2 MB arena
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	// Build a tx with many inputs
	inputs := make([]wire.Tx_In, NUM_INPUTS, alloc)
	for i in 0 ..< NUM_INPUTS {
		inputs[i] = wire.Tx_In {
			previous_output = wire.Outpoint{
				hash  = {byte(i), byte(i >> 8), byte(i >> 16), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
				         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
				index = u32(i),
			},
			sequence = 0xfffffffd,
		}
	}
	outputs := make([]wire.Tx_Out, 1, alloc)
	outputs[0] = wire.Tx_Out{value = 50_000_000, script_pubkey = hex_decode("0014abcdef0123456789abcdef0123456789abcdef01")}

	tx := wire.Tx{
		version  = 2,
		inputs   = inputs,
		outputs  = outputs,
		locktime = 0,
	}

	script_code := hex_decode("76a914abcdef0123456789abcdef012345678900000088ac")

	// Compute sighash for all inputs with cache — should NOT exhaust arena
	cache: Sighash_Cache
	prev_alloc := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_alloc }

	first_hash: Hash256
	for i in 0 ..< NUM_INPUTS {
		h := compute_sighash_witness_v0(&tx, i, script_code, 19999140, SIGHASH_ALL, &cache)
		if i == 0 {
			first_hash = h
		}
		// Each input should produce a unique sighash (different outpoint + sequence)
		if i > 0 {
			testing.expect(t, h != first_hash, fmt.tprintf("input %d should differ from input 0", i))
		}
	}

	// Verify cache was populated
	testing.expect(t, cache.has_prevouts, "cache should have prevouts after many inputs")
	testing.expect(t, cache.has_sequence, "cache should have sequence after many inputs")
	testing.expect(t, cache.has_outputs, "cache should have outputs after many inputs")
}

@(test)
test_signet_250058_tx11_p2wpkh :: proc(t: ^testing.T) {
	// Real-world regression test: signet block 250058, tx index 11.
	// This tx has 996 P2WPKH inputs. Without the sighash cache, it exhausts
	// the 64MB block arena during script verification (Bad_Script).
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Read raw tx hex from test data file (relative to source location)
	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_250058_tx11.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/signet_250058_tx11.hex")
		return
	}
	defer delete(tx_hex_raw)

	// Trim whitespace and decode
	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 996)
	testing.expect_value(t, len(tx.outputs), 2)
	testing.expect_value(t, len(tx.witness), 996)

	// Read prevout data
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_250058_tx11_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	// Parse prevouts: each line is "value scriptPubKey_hex"
	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 996)

	for i in 0 ..< len(lines) {
		parts := strings.split(lines[i], " ", context.temp_allocator)
		value, val_ok := strconv.parse_i64(parts[0])
		if !val_ok { continue }
		spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
		if !spk_ok { continue }
		spent_outputs[i] = wire.Tx_Out{value = value, script_pubkey = spk}
	}

	// Run script verification on a 2MB arena (smaller than the 64MB block arena)
	// to prove the sighash cache prevents arena exhaustion.
	arena_buf := make([]byte, 2 * 1024 * 1024)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	prev_temp := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_temp }

	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	sighash_cache: Sighash_Cache
	verified := 0
	for in_idx in 0 ..< len(tx.inputs) {
		verifier := Script_Verifier {
			tx            = &tx,
			input_idx     = in_idx,
			amount        = spent_outputs[in_idx].value,
			flags         = flags,
			spent_outputs = spent_outputs,
			sighash_cache = &sighash_cache,
		}

		witness: [][]byte
		if len(tx.witness) > in_idx {
			witness = tx.witness[in_idx]
		}

		serr := verify_script(
			&verifier,
			tx.inputs[in_idx].script_sig,
			spent_outputs[in_idx].script_pubkey,
			witness,
		)
		if serr != .None {
			testing.expect(t, false, fmt.tprintf("script verification failed at input %d: %v", in_idx, serr))
			return
		}
		verified += 1
	}

	testing.expect_value(t, verified, 996)
}

@(test)
test_mainnet_692261_tx193_pretaproot_v1 :: proc(t: ^testing.T) {
	// Real-world consensus regression: mainnet block 692261, tx index 193
	// (txid b10c007c60e14f9d..., 0xB10C's https://b10c.me/7 tx). It spends FOUR
	// witness-v1 (P2TR-shaped, 5120<32B>) outputs with EMPTY scriptSig and NO
	// witness — the tx isn't even segwit-marked. Block 692261 is BEFORE Taproot
	// activation (mainnet 709632), so BIP341 rules were NOT yet in force: witness
	// v1 was an unknown/future version = anyone-can-spend. The spend is valid on
	// mainnet.
	//
	// The bug: verify_witness_program ran verify_taproot for ANY v1/32-byte
	// program regardless of activation, so it rejected these with
	// Witness_Program_Mismatch (empty witness). Assumevalid (880k) normally skips
	// these scripts, so only a full-validation sync (--assumevalid=0) exposed it.
	// Fix: gate the Taproot branch on the .Taproot flag, set by height in
	// consensus.get_script_flags (>= params.taproot_height).
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]

	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_692261_tx193_pretaproot.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/mainnet_692261_tx193_pretaproot.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_bytes, hex_ok := hex.decode(transmute([]u8)strings.trim_space(string(tx_hex_raw)), context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 4)
	testing.expect_value(t, len(tx.outputs), 2)

	// Prevouts: "value scriptPubKey_hex" per line (all witness v1, 5120<32B>).
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_692261_tx193_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 4)

	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
	for i in 0 ..< len(lines) {
		parts := strings.split(strings.trim_space(lines[i]), " ", context.temp_allocator)
		value, val_ok := strconv.parse_i64(parts[0])
		testing.expect(t, val_ok, "parse value")
		spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
		testing.expect(t, spk_ok, "decode spk")
		// Sanity: each prevout is a witness v1 program (OP_1 <32-byte push>).
		testing.expect(t, len(spk) == 34 && spk[0] == 0x51 && spk[1] == 0x20, "prevout is v1/32 witness program")
		spent_outputs[i] = wire.Tx_Out{value = value, script_pubkey = spk}
	}

	verify_all :: proc(t: ^testing.T, tx: ^wire.Tx, spent_outputs: []wire.Tx_Out, flags: Verify_Flags) -> (Script_Error, int) {
		sighash_cache: Sighash_Cache
		for in_idx in 0 ..< len(tx.inputs) {
			verifier := Script_Verifier {
				tx            = tx,
				input_idx     = in_idx,
				amount        = spent_outputs[in_idx].value,
				flags         = flags,
				spent_outputs = spent_outputs,
				sighash_cache = &sighash_cache,
			}
			witness: [][]byte
			if len(tx.witness) > in_idx {
				witness = tx.witness[in_idx]
			}
			serr := verify_script(&verifier, tx.inputs[in_idx].script_sig, spent_outputs[in_idx].script_pubkey, witness)
			if serr != .None {
				return serr, in_idx
			}
		}
		return .None, -1
	}

	// Consensus flags at mainnet height 692261 (pre-Taproot): NO .Taproot.
	// All four v1 spends must pass as anyone-can-spend.
	pre_flags := Verify_Flags{.P2SH, .DER_Sig, .Check_Locktime, .Check_Sequence, .Witness, .Null_Dummy}
	serr, bad_idx := verify_all(t, &tx, spent_outputs, pre_flags)
	testing.expect(t, serr == .None, fmt.tprintf("pre-Taproot: all v1 spends should pass, but input %d gave %v", bad_idx, serr))

	// With .Taproot active (post-709632 flags), the SAME empty-witness spend must
	// be rejected — proves the flag genuinely gates the Taproot path.
	post_flags := pre_flags + {.Taproot}
	serr_post, _ := verify_all(t, &tx, spent_outputs, post_flags)
	testing.expect(t, serr_post != .None, "with Taproot active, empty-witness v1 spend must be rejected")
}

@(test)
test_signet_2148_tx1_two_phase :: proc(t: ^testing.T) {
	// Regression test: signet block 2148, tx index 1.
	// This tx has 400 P2WPKH inputs. It exposed a use-after-free bug in the
	// two-phase connect_block restructuring: spent_outputs[].script_pubkey
	// pointed to cache-owned data that was freed by coins_cache_spend before
	// Phase 2 script verification could read it, causing Eval_False / Script_Too_Large.
	// Fix: clone script_pubkey to temp_allocator before spending.
	//
	// This test verifies that all 400 inputs pass script verification when
	// prevout scripts are properly preserved (simulating the cloned data path).
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_2148_tx1.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/signet_2148_tx1.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 400)
	testing.expect_value(t, len(tx.outputs), 2)
	testing.expect_value(t, len(tx.witness), 400)

	// Read prevout data
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_2148_tx1_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 400)

	for i in 0 ..< len(lines) {
		parts := strings.split(lines[i], " ", context.temp_allocator)
		value, val_ok := strconv.parse_i64(parts[0])
		if !val_ok { continue }
		spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
		if !spk_ok { continue }
		spent_outputs[i] = wire.Tx_Out{value = value, script_pubkey = spk}
	}

	// Use a 2MB arena to verify scripts (same as connect_block's per-input arena).
	arena_buf := make([]byte, 2 * 1024 * 1024)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	prev_temp := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_temp }

	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	// Pre-compute sighash cache (as two-phase connect_block does)
	sighash_cache: Sighash_Cache
	sighash_cache_precompute(&sighash_cache, &tx, spent_outputs)

	verified := 0
	for in_idx in 0 ..< len(tx.inputs) {
		mem.arena_free_all(&arena)

		verifier := Script_Verifier {
			tx            = &tx,
			input_idx     = in_idx,
			amount        = spent_outputs[in_idx].value,
			flags         = flags,
			spent_outputs = spent_outputs,
			sighash_cache = &sighash_cache,
		}

		witness: [][]byte
		if len(tx.witness) > in_idx {
			witness = tx.witness[in_idx]
		}

		serr := verify_script(
			&verifier,
			tx.inputs[in_idx].script_sig,
			spent_outputs[in_idx].script_pubkey,
			witness,
		)
		if serr != .None {
			testing.expect(t, false, fmt.tprintf("script verification failed at input %d: %v", in_idx, serr))
			return
		}
		verified += 1
	}

	testing.expect_value(t, verified, 400)
}

@(test)
test_signet_90719_tapscript_codeseparator :: proc(t: ^testing.T) {
	// Regression test: signet block 90719, tx index 9.
	// Taproot script path spend with OP_CODESEPARATOR in the tapscript:
	//   <pk1> OP_CHECKSIGVERIFY OP_CODESEPARATOR <pk2> OP_CHECKSIGVERIFY OP_CODESEPARATOR <pk3> OP_CHECKSIG
	// BIP342 requires code_separator_pos to be the OPCODE INDEX (not byte offset).
	// Before fix, code_separator_pos was set to the byte offset, causing wrong sighash
	// and Eval_False for all Schnorr signatures after an OP_CODESEPARATOR.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_90719_tx9.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/signet_90719_tx9.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 1)
	testing.expect_value(t, len(tx.witness), 1)
	testing.expect(t, len(tx.witness[0]) == 5, "expected 5 witness items (3 sigs + script + control)")

	// Read prevout data
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_90719_tx9_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)

	parts := strings.split(lines[0], " ", context.temp_allocator)
	value, _ := strconv.parse_i64(parts[0])
	spk, _ := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = value, script_pubkey = spk}

	arena_buf := make([]byte, 2 * 1024 * 1024)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	prev_temp := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_temp }

	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	sighash_cache: Sighash_Cache
	verifier := Script_Verifier {
		tx            = &tx,
		input_idx     = 0,
		amount        = spent_outputs[0].value,
		flags         = flags,
		spent_outputs = spent_outputs,
		sighash_cache = &sighash_cache,
	}

	serr := verify_script(
		&verifier,
		tx.inputs[0].script_sig,
		spent_outputs[0].script_pubkey,
		tx.witness[0],
	)
	testing.expect(t, serr == .None, fmt.tprintf("script verification failed: %v", serr))
}

@(test)
test_signet_250183_p2a_anchor :: proc(t: ^testing.T) {
	// Regression test: signet block 250183, tx index 33.
	// This tx spends a P2A (Pay-to-Anchor) output: witness v1, 2-byte program (51024e73).
	// Before fix, verify_witness_program routed ALL v1 programs to verify_taproot,
	// which expected 32 bytes and failed with Witness_Program_Wrong_Length.
	// P2A outputs are anyone-can-spend per consensus (future witness version space).
	//
	// Raw tx: 02000000015009079dd76641fe31fd2acb2bec61567a989dc3fd3c8a2ef28e24b87b9a52bd
	//         0000000000fdffffff010000000000000000146a126f6e207369676e6574207765206c6561726e45d10300
	// Prevout: value=900, scriptPubKey=51024e73

	// Prevout scriptPubKey: OP_1 PUSH2 4e73 (witness v1, 2-byte program)
	script_pubkey := []u8{0x51, 0x02, 0x4e, 0x73}

	// Verify it's detected as a witness program
	ver, prog, is_wit := is_witness_program(script_pubkey)
	testing.expect(t, is_wit, "P2A should be detected as witness program")
	testing.expect_value(t, ver, 1)
	testing.expect_value(t, len(prog), 2)

	// Build a minimal tx that spends this output (no witness data needed)
	tx := wire.Tx{version = 2, locktime = 250181}
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0].sequence = 0xfffffffd
	tx.inputs = inputs

	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0].value = 0
	outputs[0].script_pubkey = []u8{0x6a, 0x12, 0x6f, 0x6e, 0x20, 0x73, 0x69, 0x67, 0x6e, 0x65, 0x74, 0x20, 0x77, 0x65, 0x20, 0x6c, 0x65, 0x61, 0x72, 0x6e}
	tx.outputs = outputs

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = 900, script_pubkey = script_pubkey}

	// Consensus flags (no Discourage_Upgradable_Witness for block validation)
	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	verifier := Script_Verifier{
		tx            = &tx,
		input_idx     = 0,
		amount        = 900,
		flags         = flags,
		spent_outputs = spent_outputs,
	}

	// Should succeed: v1 non-32-byte program is anyone-can-spend for consensus
	serr := verify_script(&verifier, nil, script_pubkey, nil)
	testing.expect(t, serr == .None, fmt.tprintf("P2A anchor should pass consensus: got %v", serr))

	// With STANDARD_FLAGS (mempool policy), it should be rejected as discouraged
	verifier.flags = STANDARD_FLAGS
	serr2 := verify_script(&verifier, nil, script_pubkey, nil)
	testing.expect(t, serr2 == .Discourage_Upgradable_Witness,
		fmt.tprintf("P2A anchor should be discouraged in mempool: got %v", serr2))
}

@(test)
test_signet_250447_tapscript_op_roll :: proc(t: ^testing.T) {
	// Regression test: signet block 250447, tx index 96.
	// txid: 00227f432246783950315d133f21bb5002d9eddbeb8c716844b5c6827a31a1e4
	// This tx uses Taproot script-path spending (BIP342) with 228 witness items
	// including OP_ROLL on a deep stack (n=215, stack_size=216).
	// Before fix, stack_remove() called delete() on arena-allocated slice data,
	// which passed the wrong allocator to free(), causing heap corruption (SIGABRT).
	//
	// Input: P2TR output, value=5490
	// scriptPubKey: 51205784ff73f9d22768baeb80bde0ab39fb8cf34739d36588c6ed6bf6445c0eff5e

	crypto.init_secp256k1()

	// Raw tx hex split for readability (compile-time constant concat)
	TX_HEX :: "020000000001010b579af47df92a26a635f557bef0f5ce5aaf24aee5359b2f9bb28cb70cfdca7901" +
		"00000000ffffffff015c1200000000000022002017e90c8d35ea51ccde68896a84c26a50a47729b7" +
		"d91e6b9dfc5ea30714473e0ee40336c80d04a8c72a0504074cd51104ce40421d04b96fa30a041904" +
		"4c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa3" +
		"0a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d" +
		"04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104" +
		"ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a050407" +
		"4cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c7" +
		"2a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c8" +
		"0d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c" +
		"150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c14" +
		"0421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d330521804" +
		"58271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d3" +
		"3052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a041904" +
		"4c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa3" +
		"0a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d" +
		"04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104" +
		"ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a050407" +
		"4cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c7" +
		"2a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c150336c8" +
		"0d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c" +
		"150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d33052180458271c14" +
		"0421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d330521804" +
		"58271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d3" +
		"3052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa30a041904" +
		"4c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d04b96fa3" +
		"0a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104ce40421d" +
		"04b96fa30a0419044c0104d33052180458271c140421cc7c150336c80d04a8c72a0504074cd51104" +
		"ce40421d04b96fa30a0419044c0104d33052180458271c140421cc7c15036c901b04518f550a040f" +
		"98aa03049c81841a0472df4615043308980204a761a41004b14e3808044298f90a4149d366b3cf99" +
		"e0ed8e0fc25bfe63f95d403ac0a857e014c478231c0d51ec5cb8de4558e04f374344f5e8484b4f7d" +
		"e7855a45ed3f662173ab2e3b76a29094cfe201fd310500205af96d958b8c5634fbbfe83bbdac9c32" +
		"200d07db64225317e9c3debd2a5581afba519d6b6b6b6b6b6b6b6b6b02d7007a016c7a02d7007a01" +
		"6d7a02d7007a016e7a02d7007a016f7a02d7007a01707a02d7007a01717a02d7007a01727a02d700" +
		"7a01737a02d7007a01747a876b876b876b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a" +
		"9a9a9a9a9a9a6b02c5007a01637a02c5007a01647a02c5007a01657a02c5007a01667a02c5007a01" +
		"677a02c5007a01687a02c5007a01697a02c5007a016a7a02c5007a016b7a876b876b876b876b876b" +
		"876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b02b3007a015a7a02b3007a015b7a" +
		"02b3007a015c7a02b3007a015d7a02b3007a015e7a02b3007a015f7a02b3007a01607a02b3007a01" +
		"617a02b3007a01627a876b876b876b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a" +
		"9a9a9a9a6b02a1007a01517a02a1007a01527a02a1007a01537a02a1007a01547a02a1007a01557a" +
		"02a1007a01567a02a1007a01577a02a1007a01587a02a1007a01597a876b876b876b876b876b876b" +
		"876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b028f007a01487a028f007a01497a028f" +
		"007a014a7a028f007a014b7a028f007a014c7a028f007a014d7a028f007a014e7a028f007a014f7a" +
		"028f007a01507a876b876b876b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a" +
		"9a9a6b017d7a013f7a017d7a01407a017d7a01417a017d7a01427a017d7a01437a017d7a01447a01" +
		"7d7a01457a017d7a01467a017d7a01477a876b876b876b876b876b876b876b876b876b6c6c6c6c6c" +
		"6c6c6c6c9a9a9a9a9a9a9a9a6b016b7a01367a016b7a01377a016b7a01387a016b7a01397a016b7a" +
		"013a7a016b7a013b7a016b7a013c7a016b7a013d7a016b7a013e7a876b876b876b876b876b876b87" +
		"6b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b01597a012d7a01597a012e7a01597a012f" +
		"7a01597a01307a01597a01317a01597a01327a01597a01337a01597a01347a01597a01357a876b87" +
		"6b876b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b01477a01247a01" +
		"477a01257a01477a01267a01477a01277a01477a01287a01477a01297a01477a012a7a01477a012b" +
		"7a01477a012c7a876b876b876b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a" +
		"9a9a6b01357a011b7a01357a011c7a01357a011d7a01357a011e7a01357a011f7a01357a01207a01" +
		"357a01217a01357a01227a01357a01237a876b876b876b876b876b876b876b876b876b6c6c6c6c6c" +
		"6c6c6c6c9a9a9a9a9a9a9a9a6b01237a01127a01237a01137a01237a01147a01237a01157a01237a" +
		"01167a01237a01177a01237a01187a01237a01197a01237a011a7a876b876b876b876b876b876b87" +
		"6b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b01117a597a01117a5a7a01117a5b7a0111" +
		"7a5c7a01117a5d7a01117a5e7a01117a5f7a01117a607a01117a01117a876b876b876b876b876b87" +
		"6b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a6b6c6c6c6c6c6c6c6c6c6c6c6c9a9a9a" +
		"9a9a9a9a9a9a9a9a630336c80d04a8c72a0504074cd51104ce40421d04b96fa30a0419044c0104d3" +
		"3052180458271c140421cc7c156700766e6f6e686c6c6c6c6c6c6c6c6c01117a597a01117a5a7a01" +
		"117a5b7a01117a5c7a01117a5d7a01117a5e7a01117a5f7a01117a607a01117a01117a876b876b87" +
		"6b876b876b876b876b876b876b6c6c6c6c6c6c6c6c6c9a9a9a9a9a9a9a9a9141c050929b74c1a049" +
		"54b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac086c30f51129972d143545fc2c98535" +
		"3bc4bc2a55d4973f219a6b3025330ffef500000000"

	raw_tx_hex := TX_HEX

	raw_tx := hex_decode(raw_tx_hex)
	r := wire.reader_init(raw_tx)
	tx, terr := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect(t, terr == .None, fmt.tprintf("Failed to deserialize tx: %v", terr))
	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.witness), 1)
	testing.expect(t, len(tx.witness[0]) == 228, fmt.tprintf("Expected 228 witness items, got %d", len(tx.witness[0])))

	// Spent output: P2TR
	script_pubkey := hex_decode("51205784ff73f9d22768baeb80bde0ab39fb8cf34739d36588c6ed6bf6445c0eff5e")
	spent_value: i64 = 5490

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = spent_value, script_pubkey = script_pubkey}

	// Consensus flags at height 250447
	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	verifier := Script_Verifier{
		tx            = &tx,
		input_idx     = 0,
		amount        = spent_value,
		flags         = flags,
		spent_outputs = spent_outputs,
	}

	serr := verify_script(&verifier, tx.inputs[0].script_sig, script_pubkey, tx.witness[0])
	testing.expect(t, serr == .None, fmt.tprintf("Tapscript with OP_ROLL should pass: got %v", serr))
}

// Regression: testnet4 block 100497, tx index 27.
// P2PKH tx with 1 input and 10001 outputs (~960 KB raw). Legacy sighash
// serializes the entire tx (~960 KB) via Wire_Writer which doubles its buffer
// from 256 bytes. Each doubling on an arena allocator wastes the old buffer.
// Total arena usage: ~2 MB just from Wire_Writer doubling + the final 1 MB buffer.
// With a 2 MB arena this exhausted memory → wrong sighash → Sig_Null_Fail.
// Fix: increased worker arena from 2 MB to 4 MB.
@(test)
test_testnet4_100497_p2pkh_large :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet4_100497_tx27.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/testnet4_100497_tx27.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 10001)

	// Read prevout data
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet4_100497_tx27_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	parts := strings.split(lines[0], " ", context.temp_allocator)
	value, _ := strconv.parse_i64(parts[0])
	spk, _ := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = value, script_pubkey = spk}

	// Use a 4 MB arena (matching the fix) — 2 MB would cause Sig_Null_Fail.
	arena_buf := make([]byte, 4 * 1024 * 1024)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	prev_temp := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_temp }

	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	verifier := Script_Verifier{
		tx            = &tx,
		input_idx     = 0,
		amount        = value,
		flags         = flags,
		spent_outputs = spent_outputs,
	}

	serr := verify_script(&verifier, tx.inputs[0].script_sig, spk, nil)
	testing.expect(t, serr == .None, fmt.tprintf("P2PKH with 10001 outputs should pass: got %v", serr))
}

// Regression: testnet4 block 118555, tx index 3.
// 2-input tx where input 1 has a 7904-byte bare script (OP_DEPTH + hash checks + 9-of-9 CHECKMULTISIG).
// This is a non-standard custom script that is valid on testnet.
@(test)
test_testnet4_118555_bare_script :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet4_118555_tx3.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/testnet4_118555_tx3.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 2)
	testing.expect_value(t, len(tx.outputs), 1)

	// Read prevout data (2 lines, one per input)
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet4_118555_tx3_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	testing.expect(t, len(lines) >= 2, "expected at least 2 prevout lines")

	spent_outputs := make([]wire.Tx_Out, 2, context.temp_allocator)

	for i in 0 ..< 2 {
		parts := strings.split(lines[i], " ", context.temp_allocator)
		value, _ := strconv.parse_i64(parts[0])
		spk, _ := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
		spent_outputs[i] = wire.Tx_Out{value = value, script_pubkey = spk}
	}

	// Use a 4 MB arena
	arena_buf := make([]byte, 4 * 1024 * 1024)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	prev_temp := context.temp_allocator
	context.temp_allocator = alloc
	defer { context.temp_allocator = prev_temp }

	flags := Verify_Flags{.P2SH, .DER_Sig, .Strict_Enc, .Check_Locktime, .Check_Sequence,
	                       .Witness, .Null_Dummy, .Low_S, .Null_Fail, .Witness_Pub_Key_Compressed}

	// Test input 1 (the bare script) — this was failing with Sig_Null_Fail
	verifier := Script_Verifier{
		tx            = &tx,
		input_idx     = 1,
		amount        = spent_outputs[1].value,
		flags         = flags,
		spent_outputs = spent_outputs,
	}

	serr := verify_script(&verifier, tx.inputs[1].script_sig, spent_outputs[1].script_pubkey, nil)
	testing.expect(t, serr == .None, fmt.tprintf("Bare script input should pass: got %v", serr))
}

@(test)
test_testnet3_26860_p2pkh :: proc(t: ^testing.T) {
	// Testnet3 block 26860, tx 1: standard P2PKH with uncompressed pubkey.
	// Pre-BIP66, only .P2SH flag active.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]

	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet3_26860_tx1.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/testnet3_26860_tx1.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 2)

	// Prevout: 8750000000 sats, P2PKH
	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/testnet3_26860_tx1_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts")
		return
	}
	defer delete(prevout_raw)

	parts := strings.split(strings.trim_space(string(prevout_raw)), " ", context.temp_allocator)
	value, _ := strconv.parse_i64(parts[0])
	spk, _ := hex.decode(transmute([]u8)parts[1], context.temp_allocator)

	spent_outputs := []wire.Tx_Out{{value = value, script_pubkey = spk}}

	// Only P2SH flag active at height 26860 on testnet3
	flags := Verify_Flags{.P2SH}

	verifier := Script_Verifier{
		tx            = &tx,
		input_idx     = 0,
		amount        = spent_outputs[0].value,
		flags         = flags,
		spent_outputs = spent_outputs,
	}

	serr := verify_script(&verifier, tx.inputs[0].script_sig, spent_outputs[0].script_pubkey, nil)
	testing.expect(t, serr == .None, fmt.tprintf("P2PKH should pass: got %v", serr))
}

@(test)
test_signet_297396_tx1_policy_flags_not_consensus :: proc(t: ^testing.T) {
	// Real-world regression test: signet block 297396, tx index 1.
	// 50 legacy P2SH inputs whose redeem script pushes a 9-byte "signature"
	// and a pubkey, then repeats OP_2DUP OP_CHECKSIG OP_CODESEPARATOR OP_DROP —
	// every CHECKSIG fails and its result is dropped. Valid by consensus, but
	// get_script_flags wrongly enforced the policy-only NULLFAIL rule during
	// block validation, halting sync with Sig_Null_Fail. Low_S, Null_Fail,
	// Strict_Enc, and Witness_Pub_Key_Compressed are mempool policy, not consensus.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_297396_tx1.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/signet_297396_tx1.hex")
		return
	}
	defer delete(tx_hex_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 50)
	testing.expect_value(t, len(tx.outputs), 1)

	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/signet_297396_tx1_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	spent_outputs := make([]wire.Tx_Out, len(tx.inputs), context.temp_allocator)
	lines := strings.split(strings.trim_space(string(prevout_raw)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 50)

	for i in 0 ..< len(lines) {
		parts := strings.split(lines[i], " ", context.temp_allocator)
		value, val_ok := strconv.parse_i64(parts[0])
		if !val_ok { continue }
		spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
		if !spk_ok { continue }
		spent_outputs[i] = wire.Tx_Out{value = value, script_pubkey = spk}
	}

	// Consensus flags for signet at height 297396 (per get_script_flags after
	// the fix): no Low_S / Null_Fail / Strict_Enc / Witness_Pub_Key_Compressed.
	consensus_flags := Verify_Flags{.P2SH, .DER_Sig, .Check_Locktime, .Check_Sequence, .Witness, .Null_Dummy}

	sighash_cache: Sighash_Cache
	verified := 0
	for in_idx in 0 ..< len(tx.inputs) {
		verifier := Script_Verifier {
			tx            = &tx,
			input_idx     = in_idx,
			amount        = spent_outputs[in_idx].value,
			flags         = consensus_flags,
			spent_outputs = spent_outputs,
			sighash_cache = &sighash_cache,
		}

		witness: [][]byte
		if len(tx.witness) > in_idx {
			witness = tx.witness[in_idx]
		}

		serr := verify_script(&verifier, tx.inputs[in_idx].script_sig, spent_outputs[in_idx].script_pubkey, witness)
		if serr != .None {
			testing.expect(t, false, fmt.tprintf("script verification failed at input %d: %v", in_idx, serr))
			return
		}
		verified += 1
	}
	testing.expect_value(t, verified, 50)

	// Sanity: with the policy-only NULLFAIL flag added (the pre-fix behavior),
	// the same input must fail — documenting why it must stay out of consensus.
	policy_verifier := Script_Verifier {
		tx            = &tx,
		input_idx     = 0,
		amount        = spent_outputs[0].value,
		flags         = consensus_flags + {.Null_Fail},
		spent_outputs = spent_outputs,
		sighash_cache = &sighash_cache,
	}
	perr := verify_script(&policy_verifier, tx.inputs[0].script_sig, spent_outputs[0].script_pubkey, nil)
	testing.expect(t, perr == .Sig_Null_Fail, fmt.tprintf("expected Sig_Null_Fail with policy flags, got %v", perr))
}

@(test)
test_mainnet_899747_big_tapscript_growing_arena :: proc(t: ^testing.T) {
	// Real-world regression test: mainnet block 899747, tx index 1
	// (8ecfefd438a229c7cea10f6973f49d8bbe3a620fd557f7f2cb3658ac59510249).
	// A 3.95MB single-input taproot script-path spend with 859 witness items.
	// BIP342 tapscripts have no size cap, so this single input exhausted the
	// old fixed 4MB serial-path verification arena: temp allocations failed
	// silently and script_num_encode paniced on an empty dynamic array
	// ("Index -1 is out of range"), killing the node at 93.9% of mainnet IBD.
	// connect_block now verifies on growing virtual arenas; this test runs the
	// same tx under one, proving verification completes and the spend is valid.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_899747_tx_big.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/mainnet_899747_tx_big.hex")
		return
	}
	defer delete(tx_hex_raw)

	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_899747_tx_big_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	// Same allocator setup as the fixed serial verification path: growing
	// virtual arena with an 8MB initial block.
	arena: virtual.Arena
	verr := virtual.arena_init_growing(&arena, 8 * 1024 * 1024)
	if verr != nil {
		testing.expect(t, false, "failed to init growing arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	prev_temp := context.temp_allocator
	context.temp_allocator = virtual.arena_allocator(&arena)
	defer { context.temp_allocator = prev_temp }

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.witness), 1)
	testing.expect_value(t, len(tx.witness[0]), 859)

	parts := strings.split(strings.trim_space(string(prevout_raw)), " ", context.temp_allocator)
	value, val_ok := strconv.parse_i64(parts[0])
	testing.expect(t, val_ok, "bad prevout value")
	spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
	testing.expect(t, spk_ok, "bad prevout script hex")

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = value, script_pubkey = spk}

	flags := Verify_Flags{.P2SH, .DER_Sig, .Check_Locktime, .Check_Sequence, .Witness, .Null_Dummy}
	sighash_cache: Sighash_Cache
	verifier := Script_Verifier {
		tx            = &tx,
		input_idx     = 0,
		amount        = value,
		flags         = flags,
		spent_outputs = spent_outputs,
		sighash_cache = &sighash_cache,
	}

	serr := verify_script(&verifier, tx.inputs[0].script_sig, spk, tx.witness[0])
	testing.expect(t, serr == .None, fmt.tprintf("big tapscript should verify: got %v", serr))
}

@(test)
test_mainnet_909068_tapscript_annex :: proc(t: ^testing.T) {
	// Real-world regression test: mainnet block 909068, tx index 1
	// (f08fd61d48f79eeb0c4bc9e58f2d7ecad0e20e5d6411b588590cb0480c8e7fbe).
	// Taproot script-path spend WITH AN ANNEX (4th witness item starting 0x50)
	// and a maximum-depth control block (128 merkle nodes, 4129 bytes).
	// The tapscript CHECKSIG path computed the sighash without the annex
	// (spend_type bit unset, annex hash omitted), so the valid signature
	// failed with Eval_False and halted mainnet sync at height 909068.
	// Key-path annex spends were unaffected; only script-path dropped it.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	src_dir := #location().file_path
	base_dir := src_dir[:strings.last_index(src_dir, "/")]
	tx_hex_raw, tx_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_909068_tx1_annex.hex", base_dir), context.allocator)
	if tx_read_err != nil {
		testing.expect(t, false, "failed to read testdata/mainnet_909068_tx1_annex.hex")
		return
	}
	defer delete(tx_hex_raw)

	prevout_raw, prev_read_err := os.read_entire_file(fmt.tprintf("%s/testdata/mainnet_909068_tx1_annex_prevouts.txt", base_dir), context.allocator)
	if prev_read_err != nil {
		testing.expect(t, false, "failed to read prevouts file")
		return
	}
	defer delete(prevout_raw)

	tx_hex_str := strings.trim_space(string(tx_hex_raw))
	tx_bytes, hex_ok := hex.decode(transmute([]u8)tx_hex_str, context.temp_allocator)
	if !hex_ok {
		testing.expect(t, false, "failed to hex-decode tx")
		return
	}

	r := wire.reader_init(tx_bytes)
	tx, tx_err := wire.deserialize_tx(&r, context.temp_allocator)
	if tx_err != nil {
		testing.expect(t, false, fmt.tprintf("tx deserialization failed: %v", tx_err))
		return
	}

	testing.expect_value(t, len(tx.inputs), 1)
	testing.expect_value(t, len(tx.outputs), 10023)
	testing.expect_value(t, len(tx.witness[0]), 4)
	// Annex: last witness item starts with 0x50.
	annex_item := tx.witness[0][3]
	testing.expect(t, len(annex_item) > 0 && annex_item[0] == 0x50, "expected annex as 4th witness item")

	parts := strings.split(strings.trim_space(string(prevout_raw)), " ", context.temp_allocator)
	value, val_ok := strconv.parse_i64(parts[0])
	testing.expect(t, val_ok, "bad prevout value")
	spk, spk_ok := hex.decode(transmute([]u8)parts[1], context.temp_allocator)
	testing.expect(t, spk_ok, "bad prevout script hex")

	spent_outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	spent_outputs[0] = wire.Tx_Out{value = value, script_pubkey = spk}

	flags := Verify_Flags{.P2SH, .DER_Sig, .Check_Locktime, .Check_Sequence, .Witness, .Null_Dummy}
	sighash_cache: Sighash_Cache
	verifier := Script_Verifier {
		tx            = &tx,
		input_idx     = 0,
		amount        = value,
		flags         = flags,
		spent_outputs = spent_outputs,
		sighash_cache = &sighash_cache,
	}

	serr := verify_script(&verifier, tx.inputs[0].script_sig, spk, tx.witness[0])
	testing.expect(t, serr == .None, fmt.tprintf("annex script-path spend should verify: got %v", serr))
}
