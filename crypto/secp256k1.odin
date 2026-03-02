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

// Verify an ECDSA signature (DER-encoded) against a public key and message hash.
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

	sig: Secp256k1_ECDSA_Signature
	if secp256k1_ecdsa_signature_parse_der(ctx, &sig, raw_data(sig_der), c.size_t(len(sig_der))) != 1 {
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
