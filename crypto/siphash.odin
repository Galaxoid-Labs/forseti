package btccrypto

import "core:math/bits"

// SipHash-2-4: keyed hash function used in BIP152 compact block short IDs.
// Reference: Jean-Philippe Aumasson & Daniel J. Bernstein, "SipHash: a fast short-input PRF"
siphash_2_4 :: proc(k0, k1: u64, data: []byte) -> u64 {
	v0 := k0 ~ 0x736f6d6570736575
	v1 := k1 ~ 0x646f72616e646f6d
	v2 := k0 ~ 0x6c7967656e657261
	v3 := k1 ~ 0x7465646279746573

	length := len(data)
	blocks := length / 8

	// Process 8-byte blocks.
	for i in 0 ..< blocks {
		m := siphash_u64le(data[i * 8:])
		v3 ~= m
		// 2 rounds
		v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
		v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
		v0 ~= m
	}

	// Last block: remaining bytes + length in high byte.
	m: u64 = u64(length) << 56
	tail := data[blocks * 8:]
	switch len(tail) {
	case 7: m |= u64(tail[6]) << 48; fallthrough
	case 6: m |= u64(tail[5]) << 40; fallthrough
	case 5: m |= u64(tail[4]) << 32; fallthrough
	case 4: m |= u64(tail[3]) << 24; fallthrough
	case 3: m |= u64(tail[2]) << 16; fallthrough
	case 2: m |= u64(tail[1]) << 8;  fallthrough
	case 1: m |= u64(tail[0])
	case 0: // nothing
	}

	v3 ~= m
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
	v0 ~= m

	// Finalization: 4 rounds.
	v2 ~= 0xff
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)
	v0, v1, v2, v3 = _siphash_round(v0, v1, v2, v3)

	return v0 ~ v1 ~ v2 ~ v3
}

// BIP152 SipHash key derivation: SHA256(block_hash || nonce_le) → k0, k1.
compact_block_sipkeys :: proc(block_hash: Hash256, nonce: u64) -> (k0, k1: u64) {
	block_hash := block_hash
	buf: [40]byte
	copy(buf[:32], block_hash[:])
	buf[32] = u8(nonce)
	buf[33] = u8(nonce >> 8)
	buf[34] = u8(nonce >> 16)
	buf[35] = u8(nonce >> 24)
	buf[36] = u8(nonce >> 32)
	buf[37] = u8(nonce >> 40)
	buf[38] = u8(nonce >> 48)
	buf[39] = u8(nonce >> 56)
	h := sha256_hash(buf[:])
	k0 = siphash_u64le(h[:8])
	k1 = siphash_u64le(h[8:16])
	return k0, k1
}

// BIP152 short ID: low 6 bytes of SipHash-2-4(k0, k1, wtxid).
// Key derivation: SHA256(block_header_hash || nonce_le) → k0 = bytes[0:8] LE, k1 = bytes[8:16] LE.
compact_block_shortid :: proc(k0, k1: u64, wtxid: Hash256) -> u64 {
	wtxid := wtxid
	h := siphash_2_4(k0, k1, wtxid[:])
	return h & 0x0000ffffffffffff // mask to 6 bytes
}

// One SipHash round (SipRound).
@(private)
_siphash_round :: proc(v0, v1, v2, v3: u64) -> (u64, u64, u64, u64) {
	v0 := v0 + v1
	v1 := bits.rotate_left64(v1, 13)
	v1 ~= v0
	v0 = bits.rotate_left64(v0, 32)

	v2 := v2 + v3
	v3 := bits.rotate_left64(v3, 16)
	v3 ~= v2

	v0 = v0 + v3
	v3 = bits.rotate_left64(v3, 21)
	v3 ~= v0

	v2 = v2 + v1
	v1 = bits.rotate_left64(v1, 17)
	v1 ~= v2
	v2 = bits.rotate_left64(v2, 32)

	return v0, v1, v2, v3
}

// Read u64 little-endian from a byte slice.
siphash_u64le :: proc(data: []byte) -> u64 {
	return u64(data[0]) |
		u64(data[1]) << 8 |
		u64(data[2]) << 16 |
		u64(data[3]) << 24 |
		u64(data[4]) << 32 |
		u64(data[5]) << 40 |
		u64(data[6]) << 48 |
		u64(data[7]) << 56
}
