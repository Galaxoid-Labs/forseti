package chain

import "core:log"
import "../storage"

// Reorg safety horizon (Bitcoin Core parity): never prune blocks within this
// many of the tip — they may be needed to disconnect during a reorg.
MIN_BLOCKS_TO_KEEP :: 288

// Minimum prune target (Core parity): 550 MB.
MIN_PRUNE_TARGET :: 550 * 1024 * 1024

_Prune_File_Stat :: struct {
	max_height: int,
	has_blocks: bool,
	entries:    [dynamic]^Block_Index_Entry,
}

// Delete old block/undo flat files until total usage fits cs.prune_target.
//
// A file is prunable only when every block in it (max height) is below the
// prune height = min(tip − MIN_BLOCKS_TO_KEEP, last_flushed_height). The
// flush bound protects crash recovery, which replays stored-but-unflushed
// blocks from these files. Index status changes are persisted BEFORE files
// are deleted: a crash in between leaves unreferenced files (reclaimed next
// pass), never dangling references.
prune_block_files :: proc(cs: ^Chain_State, last_flushed_height: int) -> (files_deleted: int, bytes_freed: i64) {
	if cs.prune_target <= 0 {
		return 0, 0
	}
	_, tip_height := chain_tip(cs)
	prune_height := min(tip_height - MIN_BLOCKS_TO_KEEP, last_flushed_height)
	if prune_height <= 0 {
		return 0, 0
	}

	current_file := cs.block_db.files.current_file

	// One pass over the index: per-file max height + entry lists (a per-file
	// rescan would be O(entries x files) — billions of iterations when mass-
	// pruning a full unpruned datadir).
	stats := make(map[u32]_Prune_File_Stat, 64, context.temp_allocator)
	for _, entry in cs.block_index.entries {
		if .Has_Data not_in entry.status {
			continue
		}
		st := stats[entry.file_num]
		if !st.has_blocks {
			st.entries = make([dynamic]^Block_Index_Entry, 0, 1024, context.temp_allocator)
		}
		st.has_blocks = true
		if entry.height > st.max_height {
			st.max_height = entry.height
		}
		append(&st.entries, entry)
		stats[entry.file_num] = st
	}

	// Total on-disk usage across blk + rev files.
	total: i64 = 0
	for fn in u32(0) ..= current_file {
		total += storage.flat_file_size(&cs.block_db.files, fn)
		total += storage.flat_file_size(&cs.undo_files, fn)
	}
	for fn, st in stats {
		}
	if total <= i64(cs.prune_target) {
		return 0, 0
	}

	// Delete oldest-first until under target.
	for fn in u32(0) ..= current_file {
		if total <= i64(cs.prune_target) {
			break
		}
		if fn == current_file || fn == cs.undo_files.current_file {
			break // never touch the active write files
		}
		st, has := stats[fn]
		if !has || !st.has_blocks {
			continue // already pruned or empty
		}
		if st.max_height >= prune_height {
			// Stall-requeued stragglers can land in later files, so max heights
			// aren't strictly monotonic — keep scanning.
			continue
		}

		// 1. Persist status changes for every block in this file.
		batch := storage.ldb_batch_create()
		for entry in st.entries {
			entry.status -= {.Has_Data, .Has_Undo}
			rec := block_index_to_record(entry)
			storage.index_db_batch_put(&cs.index_db, batch, rec)
		}
		werr := storage.ldb_batch_write(cs.store.index_db, cs.store.sync_opts, batch)
		storage.ldb_batch_destroy(batch)
		if werr != .None {
			log.errorf("Prune: index batch write failed for file %d — stopping", fn)
			break
		}

		// 2. Delete the files.
		blk_sz := storage.flat_file_size(&cs.block_db.files, fn)
		rev_sz := storage.flat_file_size(&cs.undo_files, fn)
		storage.flat_file_delete(&cs.block_db.files, fn)
		storage.flat_file_delete(&cs.undo_files, fn)
		total -= blk_sz + rev_sz
		bytes_freed += blk_sz + rev_sz
		files_deleted += 1
		if st.max_height + 1 > cs.prune_height {
			cs.prune_height = st.max_height + 1
		}
	}

	if files_deleted > 0 {
		log.infof("Pruned %d block files (%d MB freed), lowest stored height now %d",
			files_deleted, bytes_freed / (1024 * 1024), cs.prune_height)
	}
	return files_deleted, bytes_freed
}
