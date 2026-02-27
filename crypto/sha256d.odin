package crypto

import "core:crypto/sha2"

// 32-byte hash used throughout Bitcoin (block hashes, txids, etc.)
Hash256 :: [32]byte

HASH_ZERO :: Hash256{}

// Computes SHA-256d (double SHA-256) which is the standard Bitcoin hash.
sha256d :: proc(data: []byte) -> Hash256 {
	first: Hash256
	ctx: sha2.Context_256

	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, first[:])

	result: Hash256
	sha2.init_256(&ctx)
	sha2.update(&ctx, first[:])
	sha2.final(&ctx, result[:])

	return result
}

// Single SHA-256 hash (used as first step of HASH160 and elsewhere).
sha256_hash :: proc(data: []byte) -> Hash256 {
	result: Hash256
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, result[:])
	return result
}

// Computes a BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data...).
// Variadic []byte avoids concatenation — feeds SHA256 context incrementally.
tagged_hash :: proc(tag: string, data: ..[]byte) -> Hash256 {
	// Compute tag hash
	tag_hash: Hash256
	tag_ctx: sha2.Context_256
	sha2.init_256(&tag_ctx)
	sha2.update(&tag_ctx, transmute([]byte)tag)
	sha2.final(&tag_ctx, tag_hash[:])

	// Compute tagged hash: SHA256(tag_hash || tag_hash || data...)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, tag_hash[:])
	sha2.update(&ctx, tag_hash[:])
	for d in data {
		sha2.update(&ctx, d)
	}
	result: Hash256
	sha2.final(&ctx, result[:])
	return result
}

// Reverse the byte order of a hash (for display — Bitcoin shows hashes reversed).
hash_to_display :: proc(h: Hash256) -> Hash256 {
	result: Hash256
	for i in 0 ..< 32 {
		result[i] = h[31 - i]
	}
	return result
}
