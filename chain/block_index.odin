package chain

import "core:mem"
import "../storage"
import "../wire"

SKIP_LIST_MAX :: 32

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
	prev:       ^Block_Index_Entry,
	skip:       [SKIP_LIST_MAX]^Block_Index_Entry,
}

Block_Index :: struct {
	entries:   map[Hash256]^Block_Index_Entry,
	genesis:   ^Block_Index_Entry,
	allocator: mem.Allocator,
}

block_index_init :: proc(allocator := context.allocator) -> Block_Index {
	idx: Block_Index
	idx.entries = make(map[Hash256]^Block_Index_Entry, 1024, allocator)
	idx.allocator = allocator
	return idx
}

block_index_destroy :: proc(idx: ^Block_Index) {
	for _, entry in idx.entries {
		free(entry, idx.allocator)
	}
	delete(idx.entries)
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
		idx.entries[hash] = entry
	}

	// Second pass: link prev pointers and find genesis
	for _, entry in idx.entries {
		if entry.prev_hash == HASH_ZERO {
			idx.genesis = entry
		} else {
			parent, found := idx.entries[entry.prev_hash]
			if found {
				entry.prev = parent
			}
		}
	}

	// Third pass: build skip lists
	for _, entry in idx.entries {
		_build_skip_list(entry)
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

	idx.entries[hash] = entry

	// Set genesis if height 0
	if height == 0 {
		idx.genesis = entry
	}

	_build_skip_list(entry)
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
