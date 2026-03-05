package chain

import crypto "../crypto"
import "../storage"
import "../wire"

// BIP 158 basic filter type constant.
FILTER_TYPE_BASIC :: u8(0)

// Build a BIP158 basic block filter from block data.
// Collects all output scriptPubKeys (including coinbase) and all spent
// scriptPubKeys (from non-coinbase inputs). Excludes OP_RETURN and empty scripts.
// Returns: (filter_bytes, filter_hash, n_elements).
build_basic_filter :: proc(
	block: ^wire.Block,
	block_hash: Hash256,
	spent_scripts: [][]byte,
	allocator := context.allocator,
) -> (filter: []byte, filter_hash: Hash256, n: u64) {
	// Collect elements: output scriptPubKeys + spent scriptPubKeys.
	elements := make([dynamic][]byte, 0, 64, context.temp_allocator)

	// All output scriptPubKeys (including coinbase).
	for tx_idx in 0 ..< len(block.txs) {
		for out_idx in 0 ..< len(block.txs[tx_idx].outputs) {
			spk := block.txs[tx_idx].outputs[out_idx].script_pubkey
			if _should_include_script(spk) {
				append(&elements, spk)
			}
		}
	}

	// Spent scriptPubKeys (non-coinbase inputs).
	for i in 0 ..< len(spent_scripts) {
		if _should_include_script(spent_scripts[i]) {
			append(&elements, spent_scripts[i])
		}
	}

	if len(elements) == 0 {
		// Empty filter → zero filter_hash per BIP158.
		return nil, HASH_ZERO, 0
	}

	// Deduplicate: sort by raw bytes and skip duplicates.
	deduped := _dedup_scripts(elements[:])

	n = u64(len(deduped))
	filter = crypto.gcs_build_filter(block_hash, deduped, allocator)
	filter_hash = crypto.sha256d(filter)
	return filter, filter_hash, n
}

// Compute the filter header for a block: SHA256d(filter_hash || prev_filter_header).
compute_filter_header :: proc(filter_hash: Hash256, prev_filter_header: Hash256) -> Hash256 {
	filter_hash := filter_hash
	prev_filter_header := prev_filter_header
	buf: [64]byte
	copy(buf[:32], filter_hash[:])
	copy(buf[32:], prev_filter_header[:])
	return crypto.sha256d(buf[:])
}

// Connect a block's filter: build, compute header, store.
_connect_block_filter :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry, spent_scripts: [][]byte) {
	if cs.filter_db == nil {
		return
	}

	block_hash := entry.hash

	filter, filter_hash, _ := build_basic_filter(block, block_hash, spent_scripts, context.temp_allocator)

	// Look up previous filter header.
	prev_filter_header: Hash256
	if entry.prev != nil {
		prev_header, found := storage.filter_db_get_header(cs.filter_db, entry.prev.hash)
		if found {
			prev_filter_header = prev_header
		}
		// If not found (e.g., filter index enabled mid-chain), use zero hash.
	}

	header := compute_filter_header(filter_hash, prev_filter_header)

	// Store atomically.
	storage.filter_db_put(cs.filter_db, block_hash, filter, header)
}

// Disconnect a block's filter: delete from storage.
_disconnect_block_filter :: proc(cs: ^Chain_State, block_hash: Hash256) {
	if cs.filter_db == nil {
		return
	}
	storage.filter_db_delete(cs.filter_db, block_hash)
}

// Check if a scriptPubKey should be included in the filter.
// Excludes empty scripts and OP_RETURN (0x6a prefix).
@(private)
_should_include_script :: proc(spk: []byte) -> bool {
	if len(spk) == 0 {
		return false
	}
	// OP_RETURN outputs
	if spk[0] == 0x6a {
		return false
	}
	return true
}

// Deduplicate script elements by sorting and removing consecutive duplicates.
@(private)
_dedup_scripts :: proc(elements: [][]byte) -> [][]byte {
	if len(elements) <= 1 {
		return elements
	}

	// Simple insertion sort by raw bytes (elements are typically small, count < few hundred).
	for i in 1 ..< len(elements) {
		key := elements[i]
		j := i - 1
		for j >= 0 && _bytes_less(key, elements[j]) {
			elements[j + 1] = elements[j]
			j -= 1
		}
		elements[j + 1] = key
	}

	// Remove consecutive duplicates in-place.
	result := make([dynamic][]byte, 0, len(elements), context.temp_allocator)
	append(&result, elements[0])
	for i in 1 ..< len(elements) {
		if !_bytes_equal(elements[i], elements[i - 1]) {
			append(&result, elements[i])
		}
	}
	return result[:]
}

@(private)
_bytes_less :: proc(a, b: []byte) -> bool {
	min_len := min(len(a), len(b))
	for i in 0 ..< min_len {
		if a[i] < b[i] { return true }
		if a[i] > b[i] { return false }
	}
	return len(a) < len(b)
}

@(private)
_bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}
