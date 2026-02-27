package crypto

// Computes the Merkle root from a list of transaction hashes.
// Uses Bitcoin's Merkle tree construction: if odd number of leaves,
// the last element is duplicated.
merkle_root :: proc(hashes: []Hash256) -> Hash256 {
	if len(hashes) == 0 {
		return HASH_ZERO
	}
	if len(hashes) == 1 {
		return hashes[0]
	}

	// Allocate enough space to handle odd-length duplication.
	// Max needed is len(hashes) + 1 (for one duplication at the first level).
	buf := make([]Hash256, len(hashes) + 1, context.temp_allocator)
	copy(buf, hashes)

	n := len(hashes)
	for n > 1 {
		// If odd, duplicate the last hash
		if n % 2 != 0 {
			buf[n] = buf[n - 1]
			n += 1
		}

		next := n / 2
		for i in 0 ..< next {
			// Concatenate two 32-byte hashes and double-hash
			pair: [64]byte
			copy(pair[:32], buf[i * 2][:])
			copy(pair[32:], buf[i * 2 + 1][:])
			buf[i] = sha256d(pair[:])
		}
		n = next
	}

	return buf[0]
}
