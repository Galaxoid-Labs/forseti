package chain

import "../consensus"
import "core:mem"
import "../storage"
import "../wire"

SKIP_LIST_MAX :: 20

Block_Index_Entry :: struct {
	hash:       Hash256,
	prev_hash:  Hash256,
	height:     int,
	version:    i32,
	timestamp:  u32,
	bits:       u32,
	nonce:      u32,
	status:     storage.Block_Status,
	file_num:   u32,
	data_offset: u32,
	data_size:  u32,
	undo_file_num: u32,
	undo_offset:   u32,
	undo_size:     u32,
	num_tx:     u32,      // Number of transactions in this block (0 if not yet populated)
	chain_work: [32]byte, // Cumulative PoW from genesis (big-endian u256); derived from headers, not persisted
	chain_tx:   i64,      // Cumulative tx count from genesis to this block (computed at runtime)
	prev:       ^Block_Index_Entry,
	skip:       [SKIP_LIST_MAX]^Block_Index_Entry,
}

Block_Index :: struct {
	entries:     map[Hash256]^Block_Index_Entry,
	by_prev:     map[Hash256]^Block_Index_Entry, // prev_hash -> child entry (for O(1) next-block lookup)
	genesis:     ^Block_Index_Entry,
	best_header: ^Block_Index_Entry,
	allocator:   mem.Allocator,
}

block_index_init :: proc(capacity: int = 1024, allocator := context.allocator) -> Block_Index {
	idx: Block_Index
	idx.entries = make(map[Hash256]^Block_Index_Entry, max(capacity, 1024), allocator)
	idx.by_prev = make(map[Hash256]^Block_Index_Entry, max(capacity, 1024), allocator)
	idx.allocator = allocator
	return idx
}

block_index_destroy :: proc(idx: ^Block_Index) {
	for _, entry in idx.entries {
		free(entry, idx.allocator)
	}
	delete(idx.entries)
	delete(idx.by_prev)
}

// Load all records from Index_DB, link prev pointers, build skip lists.
block_index_load :: proc(idx: ^Block_Index, db: ^storage.Index_DB) {
	// First pass: create entries for all records
	for hash, rec in db.records {
		entry := new(Block_Index_Entry, idx.allocator)
		entry.hash = hash
		entry.prev_hash = rec.prev_hash
		entry.height = int(rec.height)
		entry.version = rec.version
		entry.timestamp = rec.timestamp
		entry.bits = rec.bits
		entry.nonce = rec.nonce
		entry.status = rec.status
		entry.file_num = rec.file_num
		entry.data_offset = rec.data_offset
		entry.data_size = rec.data_size
		entry.num_tx = rec.num_tx
		idx.entries[hash] = entry
	}

	// Second pass: link prev pointers, find genesis, build by_prev index
	for _, entry in idx.entries {
		if entry.prev_hash == HASH_ZERO {
			idx.genesis = entry
		} else {
			parent, found := idx.entries[entry.prev_hash]
			if found {
				entry.prev = parent
			}
			idx.by_prev[entry.prev_hash] = entry
		}
	}

	// Third pass: build skip lists
	for _, entry in idx.entries {
		_build_skip_list(entry)
	}

	// Fourth pass: cumulative chainwork, ascending height so parents are
	// done before children (forks included — a child is always taller than
	// its parent). Derived from headers; nothing persisted.
	{
		max_h := 0
		for _, entry in idx.entries {
			if entry.height > max_h { max_h = entry.height }
		}
		by_height := make([][dynamic]^Block_Index_Entry, max_h + 1, context.temp_allocator)
		for _, entry in idx.entries {
			if by_height[entry.height] == nil {
				by_height[entry.height] = make([dynamic]^Block_Index_Entry, 0, 1, context.temp_allocator)
			}
			append(&by_height[entry.height], entry)
		}
		for h in 0 ..= max_h {
			for entry in by_height[h] {
				own := consensus.work_from_bits(entry.bits)
				if entry.prev != nil {
					entry.chain_work = consensus.u256_add(entry.prev.chain_work, own)
				} else {
					entry.chain_work = own
				}
			}
		}
	}

	// Fifth pass: best header by cumulative work (first-seen wins ties).
	for _, entry in idx.entries {
		if .Valid_Header in entry.status {
			if idx.best_header == nil || consensus.u256_compare(entry.chain_work, idx.best_header.chain_work) > 0 {
				idx.best_header = entry
			}
		}
	}
}

// Add a new block header to the index.
block_index_add :: proc(idx: ^Block_Index, header: ^wire.Block_Header, height: int, status: storage.Block_Status) -> ^Block_Index_Entry {
	hash := wire.block_header_hash(header)

	// Check if already exists
	existing, found := idx.entries[hash]
	if found {
		return existing
	}

	entry := new(Block_Index_Entry, idx.allocator)
	entry.hash = hash
	entry.prev_hash = header.prev_hash
	entry.height = height
	entry.version = header.version
	entry.timestamp = header.timestamp
	entry.bits = header.bits
	entry.nonce = header.nonce
	entry.status = status

	// Link to parent
	parent, parent_found := idx.entries[header.prev_hash]
	if parent_found {
		entry.prev = parent
	}

	// Cumulative chainwork: parent's plus this header's contribution.
	own_work := consensus.work_from_bits(header.bits)
	if parent_found {
		entry.chain_work = consensus.u256_add(parent.chain_work, own_work)
	} else {
		entry.chain_work = own_work
	}

	idx.entries[hash] = entry
	idx.by_prev[header.prev_hash] = entry

	// Set genesis if height 0
	if height == 0 {
		idx.genesis = entry
	}

	_build_skip_list(entry)

	// Update best header tracking — most cumulative WORK, not height: fork
	// choice by height follows the wrong branch when a heavier competing
	// chain exists. Ties keep first-seen (Core parity).
	if .Valid_Header in status {
		if idx.best_header == nil || consensus.u256_compare(entry.chain_work, idx.best_header.chain_work) > 0 {
			idx.best_header = entry
		}
	}

	return entry
}

// O(log n) ancestor lookup via skip list.
block_index_get_ancestor :: proc(entry: ^Block_Index_Entry, target_height: int) -> ^Block_Index_Entry {
	if entry == nil || target_height < 0 || target_height > entry.height {
		return nil
	}

	current := entry
	for current != nil && current.height != target_height {
		// Find the highest skip that doesn't overshoot
		jumped := false
		for i := SKIP_LIST_MAX - 1; i >= 0; i -= 1 {
			if current.skip[i] != nil && current.skip[i].height >= target_height {
				current = current.skip[i]
				jumped = true
				break
			}
		}
		if !jumped {
			// Fall back to prev
			current = current.prev
		}
	}

	return current
}

// Convert a Block_Index_Entry to a Block_Index_Record for persistence.
block_index_to_record :: proc(entry: ^Block_Index_Entry) -> storage.Block_Index_Record {
	return storage.Block_Index_Record {
		hash        = entry.hash,
		prev_hash   = entry.prev_hash,
		height      = i32(entry.height),
		version     = entry.version,
		timestamp   = entry.timestamp,
		bits        = entry.bits,
		nonce       = entry.nonce,
		status      = entry.status,
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
		num_tx      = entry.num_tx,
	}
}

// Build skip list for an entry.
// skip[0] = prev, skip[i] = skip[i-1].skip[i-1]
_build_skip_list :: proc(entry: ^Block_Index_Entry) {
	if entry == nil {
		return
	}

	entry.skip[0] = entry.prev

	for i in 1 ..< SKIP_LIST_MAX {
		if entry.skip[i - 1] != nil {
			entry.skip[i] = entry.skip[i - 1].skip[i - 1]
		} else {
			break
		}
	}
}
