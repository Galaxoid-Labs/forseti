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
	slab:        []Block_Index_Entry, // bulk storage for load-time entries (fast startup path)
}

block_index_init :: proc(capacity: int = 1024, allocator := context.allocator) -> Block_Index {
	idx: Block_Index
	idx.entries = make(map[Hash256]^Block_Index_Entry, max(capacity, 1024), allocator)
	idx.by_prev = make(map[Hash256]^Block_Index_Entry, max(capacity, 1024), allocator)
	idx.allocator = allocator
	return idx
}

block_index_destroy :: proc(idx: ^Block_Index) {
	slab_lo := len(idx.slab) > 0 ? uintptr(&idx.slab[0]) : 0
	slab_hi := len(idx.slab) > 0 ? uintptr(&idx.slab[len(idx.slab) - 1]) : 0
	for _, entry in idx.entries {
		ep := uintptr(entry)
		if slab_lo != 0 && ep >= slab_lo && ep <= slab_hi {
			continue // slab-backed; freed wholesale below
		}
		free(entry, idx.allocator)
	}
	delete(idx.slab)
	delete(idx.entries)
	delete(idx.by_prev)
}

// Load all records from Index_DB, link prev pointers, build skip lists.
block_index_load :: proc(idx: ^Block_Index, db: ^storage.Index_DB) {
	n := len(db.records)
	if n == 0 {
		return
	}

	// One slab instead of n individual news — ~1M fewer heap allocations
	// and contiguous memory for the pointer-chasing passes below.
	idx.slab = make([]Block_Index_Entry, n, idx.allocator)

	// Create entries for all records.
	i := 0
	for hash, rec in db.records {
		entry := &idx.slab[i]
		i += 1
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

	// Link prev pointers, find genesis, build by_prev index.
	max_h := 0
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
		if entry.height > max_h { max_h = entry.height }
	}

	// Order entries by ascending height (counting sort — no per-height
	// allocations), then do skip lists, chainwork, and best-header in ONE
	// parents-first walk. Skip lists copy from ancestors' skip lists, so
	// random map order silently truncated them (get_ancestor degraded from
	// O(log n) toward O(n)); chainwork accumulates from prev the same way.
	counts := make([]int, max_h + 2, context.temp_allocator)
	for _, entry in idx.entries {
		counts[entry.height + 1] += 1
	}
	for h in 1 ..< len(counts) {
		counts[h] += counts[h - 1]
	}
	ordered := make([]^Block_Index_Entry, n, context.temp_allocator)
	for _, entry in idx.entries {
		ordered[counts[entry.height]] = entry
		counts[entry.height] += 1
	}
	// work_from_bits is a bit-serial 256-bit division (~75µs) and nBits
	// only changes per retarget period (~475 distinct values over 957k
	// mainnet blocks) — memoizing it is the difference between a 71-second
	// and a ~2-second index build.
	work_cache := make(map[u32][32]byte, 1024, context.temp_allocator)
	for entry in ordered {
		_build_skip_list(entry)
		own, cached := work_cache[entry.bits]
		if !cached {
			own = consensus.work_from_bits(entry.bits)
			work_cache[entry.bits] = own
		}
		if entry.prev != nil {
			entry.chain_work = consensus.u256_add(entry.prev.chain_work, own)
		} else {
			entry.chain_work = own
		}
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
