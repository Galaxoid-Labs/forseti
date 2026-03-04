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

// --- ECDSA sign + verify roundtrip ---

@(test)
test_sign_ecdsa_roundtrip :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Private key = 1 (simplest valid key)
	seckey := hex_decode("0000000000000000000000000000000000000000000000000000000000000001")

	msg_hash := sha256d(transmute([]u8)string("test message for signing"))

	// Sign
	sig_der, sig_len, sign_ok := sign_ecdsa(seckey, msg_hash)
	testing.expect(t, sign_ok, "signing should succeed")
	testing.expect(t, sig_len > 0 && sig_len <= 72, "DER signature should be 1-72 bytes")

	// Derive public key
	pubkey, pk_ok := pubkey_from_seckey(seckey)
	testing.expect(t, pk_ok, "pubkey derivation should succeed")
	testing.expect_value(t, pubkey[0], u8(0x02)) // compressed, even y

	// Verify
	verified := verify_ecdsa(pubkey[:], sig_der[:sig_len], msg_hash)
	testing.expect(t, verified, "valid signature should verify")

	// Verify with wrong message should fail
	bad_hash := sha256d(transmute([]u8)string("wrong message"))
	bad_verify := verify_ecdsa(pubkey[:], sig_der[:sig_len], bad_hash)
	testing.expect(t, !bad_verify, "wrong message should fail verification")
}

// --- pubkey_from_seckey ---

@(test)
test_pubkey_from_seckey :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Private key = 1 → public key is the generator point G
	seckey := hex_decode("0000000000000000000000000000000000000000000000000000000000000001")
	pubkey, ok := pubkey_from_seckey(seckey)
	testing.expect(t, ok, "should derive pubkey from valid seckey")
	// Compressed generator point (02 prefix, even y)
	expected := hex_decode("0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")
	for i in 0 ..< 33 {
		testing.expectf(t, pubkey[i] == expected[i], "pubkey byte %d: got 0x%02x want 0x%02x", i, pubkey[i], expected[i])
	}

	// Invalid seckey (all zeros) should fail
	bad_seckey := hex_decode("0000000000000000000000000000000000000000000000000000000000000000")
	_, bad_ok := pubkey_from_seckey(bad_seckey)
	testing.expect(t, !bad_ok, "zero seckey should fail")
}

// --- verify_seckey ---

@(test)
test_verify_seckey :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// Valid secret key = 1
	valid := hex_decode("0000000000000000000000000000000000000000000000000000000000000001")
	testing.expect(t, verify_seckey(valid), "secret key 1 should be valid")

	// Zero is invalid
	zero := hex_decode("0000000000000000000000000000000000000000000000000000000000000000")
	testing.expect(t, !verify_seckey(zero), "zero should be invalid")

	// Group order n is invalid (must be < n)
	order := hex_decode("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
	testing.expect(t, !verify_seckey(order), "group order should be invalid")
}

// --- Schnorr verification (BIP340) ---

@(test)
test_verify_schnorr :: proc(t: ^testing.T) {
	init_secp256k1()
	defer destroy_secp256k1()

	// BIP340 test vector 0
	// Public key (x-only): F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9
	pubkey := hex_decode("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
	msg := hex_decode("0000000000000000000000000000000000000000000000000000000000000000")
	sig := hex_decode("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0")

	result := verify_schnorr(pubkey, sig, msg)
	testing.expect(t, result, "BIP340 test vector 0 should verify")

	// Wrong message should fail
	bad_msg := hex_decode("0000000000000000000000000000000000000000000000000000000000000001")
	bad_result := verify_schnorr(pubkey, sig, bad_msg)
	testing.expect(t, !bad_result, "wrong message should fail Schnorr verification")

	// Wrong length inputs should fail
	testing.expect(t, !verify_schnorr(pubkey[:16], sig, msg), "short pubkey should fail")
	testing.expect(t, !verify_schnorr(pubkey, sig[:32], msg), "short sig should fail")
}

// --- WIF decode ---

@(test)
test_wif_decode :: proc(t: ^testing.T) {
	// Known WIF for private key = 1, mainnet compressed
	// seckey 0x01 → WIF compressed mainnet: KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn
	wif := "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"
	seckey, compressed, ok := wif_decode(wif)
	testing.expect(t, ok, "valid WIF should decode")
	testing.expect(t, compressed, "should be compressed")
	// Secret key should be 1
	for i in 0 ..< 31 {
		testing.expectf(t, seckey[i] == 0, "seckey byte %d should be 0", i)
	}
	testing.expect_value(t, seckey[31], u8(1))

	// Invalid WIF should fail
	_, _, bad_ok := wif_decode("1InvalidWIFString1234567890123456789012345678901")
	testing.expect(t, !bad_ok, "invalid WIF should fail")
}

// --- SipHash-2-4 tests ---

@(test)
test_siphash_vectors :: proc(t: ^testing.T) {
	// SipHash-2-4 test vectors from the SipHash paper (Appendix A).
	// Key: 00 01 02 ... 0f
	// Input: 00 (1 byte) → expected hash, 00 01 (2 bytes), etc.
	k0 := u64(0x0706050403020100)
	k1 := u64(0x0f0e0d0c0b0a0908)

	// Expected outputs for inputs of length 0..15 (from reference implementation).
	expected := [16]u64{
		0x726fdb47dd0e0e31, 0x74f839c593dc67fd,
		0x0d6c8009d9a94f5a, 0x85676696d7fb7e2d,
		0xcf2794e0277187b7, 0x18765564cd99a68d,
		0xcbc9466e58fee3ce, 0xab0200f58b01d137,
		0x93f5f5799a932462, 0x9e0082df0ba9e4b0,
		0x7a5dbbc594ddb9f3, 0xf4b32f46226bada7,
		0x751e8fbc860ee5fb, 0x14ea5627c0843d90,
		0xf723ca908e7af2ee, 0xa129ca6149be45e5,
	}

	for i in 0 ..< 16 {
		input: [16]byte
		for j in 0 ..< i {
			input[j] = u8(j)
		}
		result := siphash_2_4(k0, k1, input[:i])
		testing.expectf(t, result == expected[i],
			"siphash(len=%d): got 0x%016x, want 0x%016x", i, result, expected[i])
	}
}

@(test)
test_compact_block_shortid :: proc(t: ^testing.T) {
	// End-to-end BIP152 shortid: SHA256(header_hash || nonce_le) → k0,k1 → SipHash → 6 bytes.
	// Use a known block header hash and nonce to derive keys, then compute shortid of a wtxid.
	header_hash: Hash256
	header_hash[0] = 0xab
	header_hash[1] = 0xcd
	nonce: u64 = 42

	// Key derivation: SHA256(header_hash || nonce_le)
	nonce_bytes: [8]byte
	nonce_bytes[0] = u8(nonce)
	nonce_bytes[1] = u8(nonce >> 8)
	nonce_bytes[2] = u8(nonce >> 16)
	nonce_bytes[3] = u8(nonce >> 24)
	nonce_bytes[4] = u8(nonce >> 32)
	nonce_bytes[5] = u8(nonce >> 40)
	nonce_bytes[6] = u8(nonce >> 48)
	nonce_bytes[7] = u8(nonce >> 56)

	key_buf: [40]byte
	copy(key_buf[:32], header_hash[:])
	copy(key_buf[32:], nonce_bytes[:])
	key_hash := sha256_hash(key_buf[:])

	k0 := _siphash_u64le(key_hash[:8])
	k1 := _siphash_u64le(key_hash[8:16])

	wtxid: Hash256
	wtxid[0] = 0x01
	wtxid[31] = 0xff

	shortid := compact_block_shortid(k0, k1, wtxid)

	// Verify it's masked to 6 bytes (high 2 bytes zero).
	testing.expect(t, shortid & 0xffff000000000000 == 0, "shortid high 2 bytes should be zero")
	// Verify deterministic (same inputs → same output).
	shortid2 := compact_block_shortid(k0, k1, wtxid)
	testing.expect_value(t, shortid, shortid2)
	// Different wtxid → different shortid.
	other_wtxid: Hash256
	other_wtxid[0] = 0x02
	other_shortid := compact_block_shortid(k0, k1, other_wtxid)
	testing.expect(t, shortid != other_shortid, "different wtxids should produce different shortids")
}
