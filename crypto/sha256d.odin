package btccrypto

import "core:log"

// 32-byte hash used throughout Bitcoin (block hashes, txids, etc.)
Hash256 :: [32]byte

HASH_ZERO :: Hash256{}

// Call once at startup to detect and select the best SHA-256 backend.
sha256_init_backend :: proc() {
	impl := sha256_ffi_autodetect()
	log.infof("SHA-256 backend: %s", impl)
}

// Computes SHA-256d (double SHA-256) which is the standard Bitcoin hash.
sha256d :: proc(data: []byte) -> Hash256 {
	result: Hash256
	sha256_ffi_d(raw_data(data), len(data), &result[0])
	return result
}

// Computes SHA-256d over multiple byte slices without concatenation (zero allocation).
sha256d_multi :: proc(parts: ..[]byte) -> Hash256 {
	if len(parts) == 0 {
		result: Hash256
		sha256_ffi_d(nil, 0, &result[0])
		return result
	}

	// Build arrays of pointers and lengths for the C API
	ptrs: [16][^]u8
	lens: [16]uint
	count := min(len(parts), 16)
	for i in 0 ..< count {
		ptrs[i] = raw_data(parts[i])
		lens[i] = len(parts[i])
	}

	result: Hash256
	sha256_ffi_d_multi(&ptrs[0], &lens[0], uint(count), &result[0])
	return result
}

// Single SHA-256 hash (used as first step of HASH160 and elsewhere).
sha256_hash :: proc(data: []byte) -> Hash256 {
	result: Hash256
	sha256_ffi_hash(raw_data(data), len(data), &result[0])
	return result
}

// Computes a BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data...).
// Variadic []byte avoids concatenation — feeds SHA256 context incrementally.
tagged_hash :: proc(tag: string, data: ..[]byte) -> Hash256 {
	// Compute tag hash
	tag_hash: Hash256
	tag_bytes := transmute([]byte)tag
	sha256_ffi_hash(raw_data(tag_bytes), len(tag_bytes), &tag_hash[0])

	// Compute tagged hash: SHA256(tag_hash || tag_hash || data...)
	ctx: Sha256_Ctx
	sha256_ffi_init(&ctx)
	sha256_ffi_update(&ctx, &tag_hash[0], 32)
	sha256_ffi_update(&ctx, &tag_hash[0], 32)
	for d in data {
		if len(d) > 0 {
			sha256_ffi_update(&ctx, raw_data(d), len(d))
		}
	}
	result: Hash256
	sha256_ffi_finalize(&ctx, &result[0])
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

// Parallel double-SHA256 of 64-byte blocks (for Merkle tree optimization).
// output must be blocks*32 bytes, input must be blocks*64 bytes.
sha256d64 :: proc(output: []byte, input: []byte, blocks: uint) {
	sha256_ffi_d64(raw_data(output), raw_data(input), blocks)
}
