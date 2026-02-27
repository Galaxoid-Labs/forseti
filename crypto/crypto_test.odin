package crypto

import "core:c"
import "core:encoding/hex"
import "core:testing"

// Helper: decode hex string to byte slice (temp allocated).
hex_decode :: proc(s: string) -> []u8 {
	bytes, _ := hex.decode(transmute([]u8)s, context.temp_allocator)
	return bytes
}

// Helper: encode hash to hex string (temp allocated).
hash_to_hex :: proc(h: Hash256) -> string {
	h := h
	return string(hex.encode(h[:], context.temp_allocator))
}

hash160_to_hex :: proc(h: Hash160) -> string {
	h := h
	return string(hex.encode(h[:], context.temp_allocator))
}

// --- SHA-256d tests ---

@(test)
test_sha256d_empty :: proc(t: ^testing.T) {
	// SHA-256d("") is a known value
	result := sha256d(nil)
	got := hash_to_hex(result)
	// SHA256(SHA256("")) = 5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456
	testing.expect_value(t, got, "5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456")
}

@(test)
test_sha256d_hello :: proc(t: ^testing.T) {
	data := transmute([]u8)string("hello")
	result := sha256d(data)
	got := hash_to_hex(result)
	testing.expect_value(t, got, "9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50")
}

@(test)
test_sha256d_bitcoin_genesis_header :: proc(t: ^testing.T) {
	// Bitcoin mainnet genesis block header (80 bytes, hex)
	header_hex :=
		"01000000" + // version
		"0000000000000000000000000000000000000000000000000000000000000000" + // prev block
		"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a" + // merkle root
		"29ab5f49" + // timestamp
		"ffff001d" + // bits
		"1dac2b7c" // nonce

	header_bytes := hex_decode(header_hex)
	result := sha256d(header_bytes)

	// Genesis block hash (displayed in reverse byte order):
	// 000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
	// In natural byte order (as sha256d produces):
	display := hash_to_display(result)
	got := hash_to_hex(display)
	testing.expect_value(t, got, "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
}

// --- RIPEMD-160 tests ---

@(test)
test_ripemd160_empty :: proc(t: ^testing.T) {
	// RIPEMD-160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
	result := ripemd160(nil)
	got := hash160_to_hex(result)
	testing.expect_value(t, got, "9c1185a5c5e9fc54612808977ee8f548b2258d31")
}

@(test)
test_ripemd160_abc :: proc(t: ^testing.T) {
	// RIPEMD-160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
	data := transmute([]u8)string("abc")
	result := ripemd160(data)
	got := hash160_to_hex(result)
	testing.expect_value(t, got, "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
}

@(test)
test_ripemd160_message_digest :: proc(t: ^testing.T) {
	// RIPEMD-160("message digest") = 5d0689ef49d2fae572b881b123a85ffa21595f36
	data := transmute([]u8)string("message digest")
	result := ripemd160(data)
	got := hash160_to_hex(result)
	testing.expect_value(t, got, "5d0689ef49d2fae572b881b123a85ffa21595f36")
}

// --- HASH160 tests ---

@(test)
test_hash160_pubkey :: proc(t: ^testing.T) {
	// Known Bitcoin public key -> HASH160
	// Compressed public key for the Bitcoin wiki example:
	// 0250863ad64a87ae8a2fe83c1af1a8403cb53f53e486d8511dad8a04887e5b2352
	// HASH160 = f54a5851e9372b87810a8e60cdd2e7cfd80b6e31
	pubkey := hex_decode("0250863ad64a87ae8a2fe83c1af1a8403cb53f53e486d8511dad8a04887e5b2352")
	result := hash160(pubkey)
	got := hash160_to_hex(result)
	testing.expect_value(t, got, "f54a5851e9372b87810a8e60cdd2e7cfd80b6e31")
}

// --- Merkle root tests ---

@(test)
test_merkle_root_single :: proc(t: ^testing.T) {
	h: Hash256
	h[0] = 0x01
	result := merkle_root([]Hash256{h})
	testing.expect_value(t, result, h)
}

@(test)
test_merkle_root_two :: proc(t: ^testing.T) {
	a: Hash256
	b: Hash256
	a[0] = 0xaa
	b[0] = 0xbb

	// Manually compute: SHA256d(a || b)
	pair: [64]byte
	copy(pair[:32], a[:])
	copy(pair[32:], b[:])
	expected := sha256d(pair[:])

	result := merkle_root([]Hash256{a, b})
	testing.expect_value(t, result, expected)
}

@(test)
test_merkle_root_three_duplicates_last :: proc(t: ^testing.T) {
	a, b, c: Hash256
	a[0] = 0x01
	b[0] = 0x02
	c[0] = 0x03

	// With 3 hashes, c is duplicated: tree is [[a,b], [c,c]]
	pair_ab: [64]byte
	copy(pair_ab[:32], a[:])
	copy(pair_ab[32:], b[:])
	h_ab := sha256d(pair_ab[:])

	pair_cc: [64]byte
	copy(pair_cc[:32], c[:])
	copy(pair_cc[32:], c[:])
	h_cc := sha256d(pair_cc[:])

	pair_root: [64]byte
	copy(pair_root[:32], h_ab[:])
	copy(pair_root[32:], h_cc[:])
	expected := sha256d(pair_root[:])

	result := merkle_root([]Hash256{a, b, c})
	testing.expect_value(t, result, expected)
}

// --- secp256k1 tests ---

@(test)
test_secp256k1_init_destroy :: proc(t: ^testing.T) {
	// Just verify init/destroy doesn't crash
	init_secp256k1()
	defer destroy_secp256k1()
	testing.expect(t, _global_secp256k1_ctx != nil, "secp256k1 context should not be nil")
}

@(test)
test_ecdsa_verify_invalid_sig :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Generator point (uncompressed public key for private key = 1)
	pubkey := hex_decode("0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")

	// A random message hash
	msg_hash := sha256d(transmute([]u8)string("test message"))

	// An invalid but well-formed DER signature (random r,s values)
	sig := hex_decode("3044022000000000000000000000000000000000000000000000000000000000000000010220000000000000000000000000000000000000000000000000000000000000000001")

	result := verify_ecdsa(pubkey, sig, msg_hash)
	testing.expect(t, !result, "invalid ECDSA signature should not verify")
}

@(test)
test_ecdsa_verify_bad_pubkey :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Invalid public key (all zeros)
	pubkey := hex_decode("04" + "0000000000000000000000000000000000000000000000000000000000000000" + "0000000000000000000000000000000000000000000000000000000000000000")
	msg_hash := sha256d(transmute([]u8)string("test"))
	sig := hex_decode("3044022000000000000000000000000000000000000000000000000000000000000000010220000000000000000000000000000000000000000000000000000000000000000001")

	result := verify_ecdsa(pubkey, sig, msg_hash)
	testing.expect(t, !result, "bad pubkey should fail verification")
}

@(test)
test_secp256k1_pubkey_parse :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Compressed generator point (valid secp256k1 public key)
	pubkey_bytes := hex_decode("0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")

	pubkey: Secp256k1_Pubkey
	result := secp256k1_ec_pubkey_parse(
		_global_secp256k1_ctx,
		&pubkey,
		raw_data(pubkey_bytes),
		c.size_t(len(pubkey_bytes)),
	)
	testing.expect(t, result == 1, "should parse valid compressed public key")
}
