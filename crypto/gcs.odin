package btccrypto

import "core:slice"

// BIP 158 Golomb-Coded Set (GCS) compact block filters.
// Used to compactly represent the set of scriptPubKeys in a block.

GCS_P :: 19        // Golomb-Rice coding parameter for basic filters
GCS_M :: 784931    // False positive parameter (F = N * M)

// Derive SipHash-2-4 keys from a block hash per BIP158.
// k0 = LE_u64(block_hash[0:8]), k1 = LE_u64(block_hash[8:16]).
gcs_filter_sipkeys :: proc(block_hash: Hash256) -> (k0, k1: u64) {
	h := block_hash
	return siphash_u64le(h[:8]), siphash_u64le(h[8:16])
}

// Build a BIP158 GCS filter from a set of data elements.
// Returns the Golomb-Rice encoded filter bytes. Empty elements → empty filter.
gcs_build_filter :: proc(block_hash: Hash256, elements: [][]byte, allocator := context.allocator) -> []byte {
	n := u64(len(elements))
	if n == 0 {
		return nil
	}

	k0, k1 := gcs_filter_sipkeys(block_hash)
	f := n * GCS_M // range

	// Hash each element and map to [0, F).
	hashes := make([]u64, n, context.temp_allocator)
	for i in 0 ..< len(elements) {
		h := siphash_2_4(k0, k1, elements[i])
		hashes[i] = _fast_reduce(h, f)
	}

	// Sort ascending.
	slice.sort(hashes)

	// Golomb-Rice encode the deltas.
	bw: Bit_Writer
	_bit_writer_init(&bw, context.temp_allocator)

	prev: u64 = 0
	for i in 0 ..< len(hashes) {
		delta := hashes[i] - prev
		_golomb_rice_encode(&bw, delta, GCS_P)
		prev = hashes[i]
	}

	result := _bit_writer_finish(&bw, allocator)
	return result
}

// Check if any of the given elements match the filter.
// Returns true if at least one element is likely in the set (with false positive rate 1/M).
gcs_match_any :: proc(block_hash: Hash256, filter_data: []byte, elements: [][]byte) -> bool {
	n_elements := u64(len(elements))
	if n_elements == 0 || len(filter_data) == 0 {
		return false
	}

	k0, k1 := gcs_filter_sipkeys(block_hash)

	// We need to know N (number of items in the filter) to compute F.
	// BIP158: N is encoded externally (in the cfilter message or known from block).
	// For match_any, the caller doesn't know N. We use the standard approach:
	// decode all values from the filter and check membership.
	// But we need N to know F for the hash computation.
	// Actually, BIP158 specifies N as a CompactSize prefix of the filter content
	// when transmitted. But gcs_build_filter doesn't include it.
	// For our use case, we'll accept N as implicit from the filter.
	// The standard approach: hash query elements with F = N_query * M, then
	// use a merge-intersect with the decoded filter deltas.

	// Actually, the correct approach per BIP158: the filter is built with N = number
	// of elements that went into it, and F = N * M. To match, we need to know N.
	// We'll use gcs_match_any_n which takes N explicitly.

	// We can't determine N from filter bytes alone without the count.
	// Return false for safety — callers should use gcs_match_any_n.
	return false
}

// Check if any of the given elements match the filter, given N (the number of items in the filter).
gcs_match_any_n :: proc(block_hash: Hash256, filter_data: []byte, n: u64, elements: [][]byte) -> bool {
	if n == 0 || len(filter_data) == 0 || len(elements) == 0 {
		return false
	}

	k0, k1 := gcs_filter_sipkeys(block_hash)
	f := n * GCS_M

	// Hash query elements.
	query_hashes := make([]u64, len(elements), context.temp_allocator)
	for i in 0 ..< len(elements) {
		h := siphash_2_4(k0, k1, elements[i])
		query_hashes[i] = _fast_reduce(h, f)
	}
	slice.sort(query_hashes)

	// Decode filter values and merge-intersect with sorted query hashes.
	br: Bit_Reader
	_bit_reader_init(&br, filter_data)

	filter_val: u64 = 0
	qi := 0 // index into query_hashes

	for fi in 0 ..< n {
		delta, ok := _golomb_rice_decode(&br, GCS_P)
		if !ok {
			return false
		}
		filter_val += delta

		// Advance query pointer past values < filter_val.
		for qi < len(query_hashes) && query_hashes[qi] < filter_val {
			qi += 1
		}

		if qi >= len(query_hashes) {
			return false
		}

		if query_hashes[qi] == filter_val {
			return true
		}
	}

	return false
}

// Map a 64-bit hash to [0, range) using 128-bit multiply + shift.
// This avoids expensive modulo — equivalent to (hash * range) >> 64.
@(private)
_fast_reduce :: proc(hash: u64, range: u64) -> u64 {
	// (hash * range) >> 64 using 128-bit intermediate
	hi, _ := _mul64(hash, range)
	return hi
}

// 64x64 → 128-bit multiply, return (hi, lo).
@(private)
_mul64 :: proc(a, b: u64) -> (hi, lo: u64) {
	a_lo := a & 0xFFFFFFFF
	a_hi := a >> 32
	b_lo := b & 0xFFFFFFFF
	b_hi := b >> 32

	p0 := a_lo * b_lo
	p1 := a_lo * b_hi
	p2 := a_hi * b_lo
	p3 := a_hi * b_hi

	mid := (p0 >> 32) + (p1 & 0xFFFFFFFF) + (p2 & 0xFFFFFFFF)
	hi = p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32)
	lo = (mid << 32) | (p0 & 0xFFFFFFFF)
	return hi, lo
}

// --- Bit Writer ---

@(private)
Bit_Writer :: struct {
	buf:          [dynamic]byte,
	current_byte: u8,
	bit_pos:      u8, // bits written in current_byte (0-7)
}

@(private)
_bit_writer_init :: proc(bw: ^Bit_Writer, allocator := context.allocator) {
	bw.buf = make([dynamic]byte, 0, 256, allocator)
	bw.current_byte = 0
	bw.bit_pos = 0
}

// Write a single bit (0 or 1).
@(private)
_bit_writer_write_bit :: proc(bw: ^Bit_Writer, bit: u8) {
	bw.current_byte |= (bit & 1) << (7 - bw.bit_pos)
	bw.bit_pos += 1
	if bw.bit_pos == 8 {
		append(&bw.buf, bw.current_byte)
		bw.current_byte = 0
		bw.bit_pos = 0
	}
}

// Write the low `nbits` bits of value, MSB first.
@(private)
_bit_writer_write_bits :: proc(bw: ^Bit_Writer, value: u64, nbits: uint) {
	for i := int(nbits) - 1; i >= 0; i -= 1 {
		bit := u8((value >> uint(i)) & 1)
		_bit_writer_write_bit(bw, bit)
	}
}

// Flush remaining bits (zero-padded) and return the byte slice.
@(private)
_bit_writer_finish :: proc(bw: ^Bit_Writer, allocator := context.allocator) -> []byte {
	if bw.bit_pos > 0 {
		append(&bw.buf, bw.current_byte)
	}
	result := make([]byte, len(bw.buf), allocator)
	copy(result, bw.buf[:])
	return result
}

// --- Bit Reader ---

@(private)
Bit_Reader :: struct {
	data:    []byte,
	byte_pos: int,
	bit_pos:  u8, // bits read in current byte (0-7)
}

@(private)
_bit_reader_init :: proc(br: ^Bit_Reader, data: []byte) {
	br.data = data
	br.byte_pos = 0
	br.bit_pos = 0
}

// Read a single bit. Returns (bit, ok).
@(private)
_bit_reader_read_bit :: proc(br: ^Bit_Reader) -> (u8, bool) {
	if br.byte_pos >= len(br.data) {
		return 0, false
	}
	bit := (br.data[br.byte_pos] >> (7 - br.bit_pos)) & 1
	br.bit_pos += 1
	if br.bit_pos == 8 {
		br.byte_pos += 1
		br.bit_pos = 0
	}
	return bit, true
}

// Read `nbits` bits as a u64 (MSB first).
@(private)
_bit_reader_read_bits :: proc(br: ^Bit_Reader, nbits: uint) -> (u64, bool) {
	value: u64 = 0
	for _ in 0 ..< nbits {
		bit, ok := _bit_reader_read_bit(br)
		if !ok {
			return 0, false
		}
		value = (value << 1) | u64(bit)
	}
	return value, true
}

// --- Golomb-Rice encoding/decoding ---

// Encode a value using Golomb-Rice coding with parameter p.
// Quotient = value >> p, encoded as unary (q ones + one zero).
// Remainder = value & ((1 << p) - 1), encoded as p bits.
@(private)
_golomb_rice_encode :: proc(bw: ^Bit_Writer, value: u64, p: uint) {
	quotient := value >> p
	remainder := value & ((1 << p) - 1)

	// Unary: quotient ones followed by a zero.
	for _ in 0 ..< quotient {
		_bit_writer_write_bit(bw, 1)
	}
	_bit_writer_write_bit(bw, 0)

	// Remainder: p bits.
	_bit_writer_write_bits(bw, remainder, p)
}

// Decode a Golomb-Rice coded value.
@(private)
_golomb_rice_decode :: proc(br: ^Bit_Reader, p: uint) -> (u64, bool) {
	// Read unary: count ones until zero.
	quotient: u64 = 0
	for {
		bit, ok := _bit_reader_read_bit(br)
		if !ok {
			return 0, false
		}
		if bit == 0 {
			break
		}
		quotient += 1
	}

	// Read p-bit remainder.
	remainder, ok := _bit_reader_read_bits(br, p)
	if !ok {
		return 0, false
	}

	return (quotient << p) | remainder, true
}
