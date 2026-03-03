package crypto

import "core:c"

foreign import secp256k1_lib "../deps/lib/libsecp256k1.a"

// Opaque context type
Secp256k1_Context :: distinct rawptr

// Parsed public key (internal representation, 64 bytes)
Secp256k1_Pubkey :: struct {
	data: [64]u8,
}

// Parsed ECDSA signature (internal representation, 64 bytes)
Secp256k1_ECDSA_Signature :: struct {
	data: [64]u8,
}

// Parsed x-only public key for Schnorr/Taproot (internal representation, 64 bytes)
Secp256k1_XOnly_Pubkey :: struct {
	data: [64]u8,
}

// Context flags
SECP256K1_CONTEXT_NONE :: 1 // SECP256K1_FLAGS_TYPE_CONTEXT

// Serialization flags
SECP256K1_EC_COMPRESSED   :: 258  // SECP256K1_FLAGS_TYPE_COMPRESSION | SECP256K1_FLAGS_BIT_COMPRESSION
SECP256K1_EC_UNCOMPRESSED :: 2    // SECP256K1_FLAGS_TYPE_COMPRESSION

@(default_calling_convention = "c")
foreign secp256k1_lib {
	secp256k1_context_create :: proc(flags: c.uint) -> Secp256k1_Context ---
	secp256k1_context_destroy :: proc(ctx: Secp256k1_Context) ---

	secp256k1_ec_pubkey_parse :: proc(
		ctx: Secp256k1_Context,
		pubkey: ^Secp256k1_Pubkey,
		input: [^]u8,
		inputlen: c.size_t,
	) -> c.int ---

	secp256k1_ecdsa_signature_parse_der :: proc(
		ctx: Secp256k1_Context,
		sig: ^Secp256k1_ECDSA_Signature,
		input: [^]u8,
		inputlen: c.size_t,
	) -> c.int ---

	secp256k1_ecdsa_signature_parse_compact :: proc(
		ctx: Secp256k1_Context,
		sig: ^Secp256k1_ECDSA_Signature,
		input64: [^]u8,
	) -> c.int ---

	secp256k1_ecdsa_signature_normalize :: proc(
		ctx: Secp256k1_Context,
		sigout: ^Secp256k1_ECDSA_Signature,
		sigin: ^Secp256k1_ECDSA_Signature,
	) -> c.int ---

	secp256k1_ecdsa_verify :: proc(
		ctx: Secp256k1_Context,
		sig: ^Secp256k1_ECDSA_Signature,
		msghash32: [^]u8,
		pubkey: ^Secp256k1_Pubkey,
	) -> c.int ---

	secp256k1_xonly_pubkey_parse :: proc(
		ctx: Secp256k1_Context,
		pubkey: ^Secp256k1_XOnly_Pubkey,
		input32: [^]u8,
	) -> c.int ---

	secp256k1_schnorrsig_verify :: proc(
		ctx: Secp256k1_Context,
		sig64: [^]u8,
		msg: [^]u8,
		msglen: c.size_t,
		pubkey: ^Secp256k1_XOnly_Pubkey,
	) -> c.int ---

	secp256k1_xonly_pubkey_from_pubkey :: proc(
		ctx: Secp256k1_Context,
		xonly_pubkey: ^Secp256k1_XOnly_Pubkey,
		pk_parity: ^c.int,
		pubkey: ^Secp256k1_Pubkey,
	) -> c.int ---

	secp256k1_xonly_pubkey_tweak_add :: proc(
		ctx: Secp256k1_Context,
		output_pubkey: ^Secp256k1_Pubkey,
		internal_pubkey: ^Secp256k1_XOnly_Pubkey,
		tweak32: [^]u8,
	) -> c.int ---

	secp256k1_xonly_pubkey_serialize :: proc(
		ctx: Secp256k1_Context,
		output32: [^]u8,
		pubkey: ^Secp256k1_XOnly_Pubkey,
	) -> c.int ---

	secp256k1_ecdsa_sign :: proc(
		ctx: Secp256k1_Context,
		sig: ^Secp256k1_ECDSA_Signature,
		msghash32: [^]u8,
		seckey: [^]u8,
		noncefp: rawptr,
		ndata: rawptr,
	) -> c.int ---

	secp256k1_ecdsa_signature_serialize_der :: proc(
		ctx: Secp256k1_Context,
		output: [^]u8,
		outputlen: ^c.size_t,
		sig: ^Secp256k1_ECDSA_Signature,
	) -> c.int ---

	secp256k1_ec_pubkey_create :: proc(
		ctx: Secp256k1_Context,
		pubkey: ^Secp256k1_Pubkey,
		seckey: [^]u8,
	) -> c.int ---

	secp256k1_ec_pubkey_serialize :: proc(
		ctx: Secp256k1_Context,
		output: [^]u8,
		outputlen: ^c.size_t,
		pubkey: ^Secp256k1_Pubkey,
		flags: c.uint,
	) -> c.int ---

	secp256k1_ec_seckey_verify :: proc(
		ctx: Secp256k1_Context,
		seckey: [^]u8,
	) -> c.int ---
}

// Global secp256k1 context — created once at startup.
_global_secp256k1_ctx: Secp256k1_Context

init_secp256k1 :: proc() {
	_global_secp256k1_ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE)
}

destroy_secp256k1 :: proc() {
	if _global_secp256k1_ctx != nil {
		secp256k1_context_destroy(_global_secp256k1_ctx)
		_global_secp256k1_ctx = nil
	}
}

// Sign a message hash with ECDSA and return the DER-encoded signature.
sign_ecdsa :: proc(seckey: []u8, msg_hash: Hash256) -> (sig_der: [72]u8, sig_len: int, ok: bool) {
	ctx := _global_secp256k1_ctx
	if ctx == nil || len(seckey) != 32 { return {}, 0, false }

	hash := msg_hash
	sig: Secp256k1_ECDSA_Signature
	if secp256k1_ecdsa_sign(ctx, &sig, &hash[0], raw_data(seckey), nil, nil) != 1 {
		return {}, 0, false
	}

	// Normalize to lower-S (BIP62)
	secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig)

	output_len := c.size_t(72)
	if secp256k1_ecdsa_signature_serialize_der(ctx, &sig_der[0], &output_len, &sig) != 1 {
		return {}, 0, false
	}

	return sig_der, int(output_len), true
}

// Derive a compressed public key from a secret key.
pubkey_from_seckey :: proc(seckey: []u8) -> (pubkey_bytes: [33]u8, ok: bool) {
	ctx := _global_secp256k1_ctx
	if ctx == nil || len(seckey) != 32 { return {}, false }

	pubkey: Secp256k1_Pubkey
	if secp256k1_ec_pubkey_create(ctx, &pubkey, raw_data(seckey)) != 1 {
		return {}, false
	}

	output_len := c.size_t(33)
	if secp256k1_ec_pubkey_serialize(ctx, &pubkey_bytes[0], &output_len, &pubkey, SECP256K1_EC_COMPRESSED) != 1 {
		return {}, false
	}

	return pubkey_bytes, true
}

// Verify that a secret key is valid (non-zero, less than group order).
verify_seckey :: proc(seckey: []u8) -> bool {
	ctx := _global_secp256k1_ctx
	if ctx == nil || len(seckey) != 32 { return false }
	return secp256k1_ec_seckey_verify(ctx, raw_data(seckey)) == 1
}

// Lax DER signature parser — extracts R and S into 32-byte-each compact form.
// Handles non-minimal encodings (extra leading zeros, etc.) that strict DER rejects.
// Based on Bitcoin Core's ecdsa_signature_parse_der_lax (contrib/lax_der_parsing.c).
_parse_sig_der_lax :: proc(input: []u8) -> (compact: [64]u8, ok: bool) {
	if len(input) < 6 { return {}, false } // Minimum: 30 LL 02 01 RR 02 01 SS

	pos := 0

	// Sequence tag
	if input[pos] != 0x30 { return {}, false }
	pos += 1

	// Sequence length — skip (lax: don't validate against actual remaining bytes)
	if input[pos] & 0x80 != 0 {
		// Long form length encoding
		n_bytes := int(input[pos] & 0x7F)
		pos += 1 + n_bytes
	} else {
		pos += 1
	}

	// R INTEGER
	if pos >= len(input) || input[pos] != 0x02 { return {}, false }
	pos += 1
	if pos >= len(input) { return {}, false }
	r_len := int(input[pos])
	pos += 1
	if r_len == 0 || pos + r_len > len(input) { return {}, false }
	r_data := input[pos:pos + r_len]
	pos += r_len

	// S INTEGER
	if pos >= len(input) || input[pos] != 0x02 { return {}, false }
	pos += 1
	if pos >= len(input) { return {}, false }
	s_len := int(input[pos])
	pos += 1
	if s_len == 0 || pos + s_len > len(input) { return {}, false }
	s_data := input[pos:pos + s_len]

	// Strip leading zeros from R, right-align into first 32 bytes
	for len(r_data) > 1 && r_data[0] == 0 { r_data = r_data[1:] }
	if len(r_data) > 32 { return {}, false }
	r_offset := 32 - len(r_data)
	for i in 0 ..< len(r_data) { compact[r_offset + i] = r_data[i] }

	// Strip leading zeros from S, right-align into second 32 bytes
	for len(s_data) > 1 && s_data[0] == 0 { s_data = s_data[1:] }
	if len(s_data) > 32 { return {}, false }
	s_offset := 32 - len(s_data)
	for i in 0 ..< len(s_data) { compact[32 + s_offset + i] = s_data[i] }

	return compact, true
}

// Verify an ECDSA signature (DER-encoded) against a public key and message hash.
// Uses lax DER parsing (matching Bitcoin Core's CPubKey::Verify) — strict DER
// validation is done separately by the script interpreter when BIP66 is active.
// Automatically normalizes to lower-S form per BIP62.
verify_ecdsa :: proc(pubkey_bytes: []u8, sig_der: []u8, msg_hash: Hash256) -> bool {
	ctx := _global_secp256k1_ctx
	if ctx == nil {
		return false
	}

	pubkey: Secp256k1_Pubkey
	if secp256k1_ec_pubkey_parse(ctx, &pubkey, raw_data(pubkey_bytes), c.size_t(len(pubkey_bytes))) != 1 {
		return false
	}

	// Lax DER parse: extract R and S into compact 64-byte form
	compact, lax_ok := _parse_sig_der_lax(sig_der)
	if !lax_ok {
		return false
	}

	sig: Secp256k1_ECDSA_Signature
	if secp256k1_ecdsa_signature_parse_compact(ctx, &sig, &compact[0]) != 1 {
		return false
	}

	// Normalize to lower-S (Bitcoin requires this)
	secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig)

	hash := msg_hash
	return secp256k1_ecdsa_verify(ctx, &sig, &hash[0], &pubkey) == 1
}

// Verify a Schnorr signature (64 bytes) against an x-only public key (32 bytes) and message.
verify_schnorr :: proc(xonly_pubkey_bytes: []u8, sig64: []u8, msg: []u8) -> bool {
	ctx := _global_secp256k1_ctx
	if ctx == nil {
		return false
	}
	if len(xonly_pubkey_bytes) != 32 || len(sig64) != 64 {
		return false
	}

	pubkey: Secp256k1_XOnly_Pubkey
	if secp256k1_xonly_pubkey_parse(ctx, &pubkey, raw_data(xonly_pubkey_bytes)) != 1 {
		return false
	}

	result := secp256k1_schnorrsig_verify(ctx, raw_data(sig64), raw_data(msg), c.size_t(len(msg)), &pubkey)
	return result == 1
}

// Verify that output_key is the result of tweaking internal_key with tweak.
// Used for Taproot key-path spending (BIP341).
// output_key: 32-byte x-only pubkey from the scriptPubKey
// internal_key: 32-byte x-only internal pubkey
// tweak: 32-byte tweak value (tagged_hash("TapTweak", ...))
// output_parity: parity of the output key (bit 0 of control block byte)
verify_taproot_tweak :: proc(internal_key: []u8, tweak: []u8, output_key: []u8, output_parity: int) -> bool {
	ctx := _global_secp256k1_ctx
	if ctx == nil { return false }
	if len(internal_key) != 32 || len(tweak) != 32 || len(output_key) != 32 { return false }

	// Parse internal key
	internal: Secp256k1_XOnly_Pubkey
	if secp256k1_xonly_pubkey_parse(ctx, &internal, raw_data(internal_key)) != 1 {
		return false
	}

	// Compute tweaked pubkey: internal + tweak*G
	tweaked_pubkey: Secp256k1_Pubkey
	if secp256k1_xonly_pubkey_tweak_add(ctx, &tweaked_pubkey, &internal, raw_data(tweak)) != 1 {
		return false
	}

	// Convert tweaked pubkey to x-only and get parity
	tweaked_xonly: Secp256k1_XOnly_Pubkey
	parity: c.int
	if secp256k1_xonly_pubkey_from_pubkey(ctx, &tweaked_xonly, &parity, &tweaked_pubkey) != 1 {
		return false
	}

	// Serialize the tweaked x-only key
	tweaked_bytes: [32]u8
	secp256k1_xonly_pubkey_serialize(ctx, &tweaked_bytes[0], &tweaked_xonly)

	// Compare x-coordinate and parity
	if int(parity) != output_parity { return false }
	for i in 0 ..< 32 {
		if tweaked_bytes[i] != output_key[i] { return false }
	}
	return true
}
