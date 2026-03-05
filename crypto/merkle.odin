package btccrypto

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

// --- Partial Merkle Tree (Bitcoin Core CPartialMerkleTree format) ---

_Traverse_Context :: struct {
	txids:     []Hash256,
	match_set: ^map[Hash256]bool,
	n:         int,
	hashes:    ^[dynamic]Hash256,
	flag_bits: ^[dynamic]bool,
}

_Verify_Context :: struct {
	hashes:    []Hash256,
	flag_bits: []bool,
	hash_pos:  int,
	bit_pos:   int,
	total_txs: int,
	matched:   ^[dynamic]Hash256,
	bad:       bool,
}

// Compute the tree height for n leaves.
_merkle_tree_height :: proc(n: int) -> int {
	height := 0
	sz := 1
	for sz < n {
		sz *= 2
		height += 1
	}
	return height
}

// Compute the width of the tree at a given height level.
_merkle_tree_width :: proc(n_txs: int, height: int) -> int {
	return (n_txs + (1 << uint(height)) - 1) >> uint(height)
}

// Compute the merkle hash at (height, pos) in the tree.
_calc_hash :: proc(txids: []Hash256, height: int, pos: int, n: int) -> Hash256 {
	if height == 0 {
		if pos < n {
			return txids[pos]
		}
		return HASH_ZERO
	}
	left := _calc_hash(txids, height - 1, pos * 2, n)
	right: Hash256
	if pos * 2 + 1 < _merkle_tree_width(n, height - 1) {
		right = _calc_hash(txids, height - 1, pos * 2 + 1, n)
	} else {
		right = left
	}
	pair: [64]byte
	copy(pair[:32], left[:])
	copy(pair[32:], right[:])
	return sha256d(pair[:])
}

// Check if any leaf under (height, pos) is in the match set.
_has_match :: proc(txids: []Hash256, match_set: ^map[Hash256]bool, height: int, pos: int, n: int) -> bool {
	if height == 0 {
		if pos < n {
			return txids[pos] in match_set^
		}
		return false
	}
	if _has_match(txids, match_set, height - 1, pos * 2, n) {
		return true
	}
	if pos * 2 + 1 < _merkle_tree_width(n, height - 1) {
		if _has_match(txids, match_set, height - 1, pos * 2 + 1, n) {
			return true
		}
	}
	return false
}

_traverse_and_build :: proc(ctx: ^_Traverse_Context, height: int, pos: int) {
	parent_of_match := _has_match(ctx.txids, ctx.match_set, height, pos, ctx.n)

	append(ctx.flag_bits, parent_of_match)

	if height == 0 || !parent_of_match {
		append(ctx.hashes, _calc_hash(ctx.txids, height, pos, ctx.n))
	} else {
		_traverse_and_build(ctx, height - 1, pos * 2)
		if pos * 2 + 1 < _merkle_tree_width(ctx.n, height - 1) {
			_traverse_and_build(ctx, height - 1, pos * 2 + 1)
		}
	}
}

_traverse_and_extract :: proc(ctx: ^_Verify_Context, height: int, pos: int) -> Hash256 {
	if ctx.bad { return HASH_ZERO }

	if ctx.bit_pos >= len(ctx.flag_bits) {
		ctx.bad = true
		return HASH_ZERO
	}

	parent_of_match := ctx.flag_bits[ctx.bit_pos]
	ctx.bit_pos += 1

	if height == 0 || !parent_of_match {
		if ctx.hash_pos >= len(ctx.hashes) {
			ctx.bad = true
			return HASH_ZERO
		}
		h := ctx.hashes[ctx.hash_pos]
		ctx.hash_pos += 1

		if height == 0 && parent_of_match {
			append(ctx.matched, h)
		}
		return h
	}

	left := _traverse_and_extract(ctx, height - 1, pos * 2)
	right: Hash256
	if pos * 2 + 1 < _merkle_tree_width(ctx.total_txs, height - 1) {
		right = _traverse_and_extract(ctx, height - 1, pos * 2 + 1)
	} else {
		right = left
	}

	pair: [64]byte
	copy(pair[:32], left[:])
	copy(pair[32:], right[:])
	return sha256d(pair[:])
}

// Build a partial merkle tree proof (Bitcoin Core CPartialMerkleTree format).
// txids: all txids in the block, match_set: which txids to include in the proof.
// Returns: hashes to include, flag bits packed as bytes, number of flag bytes.
merkle_build_partial_tree :: proc(
	txids: []Hash256,
	match_set: map[Hash256]bool,
) -> (hashes: [dynamic]Hash256, flags: [512]byte, flags_len: int) {
	n := len(txids)
	if n == 0 {
		return
	}

	tree_height := _merkle_tree_height(n)

	hashes = make([dynamic]Hash256, 0, 32, context.temp_allocator)
	flag_bits := make([dynamic]bool, 0, 64, context.temp_allocator)

	match_set := match_set
	ctx := _Traverse_Context {
		txids     = txids,
		match_set = &match_set,
		n         = n,
		hashes    = &hashes,
		flag_bits = &flag_bits,
	}

	_traverse_and_build(&ctx, tree_height, 0)

	// Pack flag_bits into bytes
	num_flag_bytes := (len(flag_bits) + 7) / 8
	if num_flag_bytes > 512 { num_flag_bytes = 512 }
	for i in 0 ..< len(flag_bits) {
		byte_idx := i / 8
		bit_idx := uint(i % 8)
		if byte_idx < 512 && flag_bits[i] {
			flags[byte_idx] |= 1 << bit_idx
		}
	}
	flags_len = num_flag_bytes

	return
}

// Verify a partial merkle tree and extract matched txids.
// Returns: computed merkle root, matched txids, and whether verification succeeded.
merkle_verify_partial_tree :: proc(
	proof_hashes: []Hash256,
	flag_bytes: []byte,
	total_txs: int,
) -> (root: Hash256, matched: [dynamic]Hash256, ok: bool) {
	if total_txs == 0 || len(proof_hashes) == 0 {
		return HASH_ZERO, {}, false
	}

	tree_height := _merkle_tree_height(total_txs)

	// Unpack flag bits
	total_bits := len(flag_bytes) * 8
	flag_bits := make([]bool, total_bits, context.temp_allocator)
	for i in 0 ..< total_bits {
		byte_idx := i / 8
		bit_idx := uint(i % 8)
		flag_bits[i] = (flag_bytes[byte_idx] & (1 << bit_idx)) != 0
	}

	matched = make([dynamic]Hash256, 0, 16, context.temp_allocator)

	ctx := _Verify_Context {
		hashes    = proof_hashes,
		flag_bits = flag_bits,
		hash_pos  = 0,
		bit_pos   = 0,
		total_txs = total_txs,
		matched   = &matched,
		bad       = false,
	}

	root = _traverse_and_extract(&ctx, tree_height, 0)

	if ctx.bad {
		return HASH_ZERO, {}, false
	}

	// All hashes and bits should be consumed
	if ctx.hash_pos != len(proof_hashes) || ctx.bit_pos != len(flag_bits) {
		remaining_bits := len(flag_bits) - ctx.bit_pos
		if ctx.hash_pos != len(proof_hashes) || remaining_bits >= 8 {
			return HASH_ZERO, {}, false
		}
		// Check remaining padding bits are 0
		for i in ctx.bit_pos ..< len(flag_bits) {
			if flag_bits[i] {
				return HASH_ZERO, {}, false
			}
		}
	}

	return root, matched, true
}
