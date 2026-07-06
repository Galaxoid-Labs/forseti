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
	log.infof("Prune check: tip=%d flushed=%d prune_height=%d target=%d MB blk_cur=%d rev_cur=%d",
		tip_height, last_flushed_height, prune_height, cs.prune_target / 1_048_576,
		cs.block_db.files.current_file, cs.undo_files.current_file)
	if prune_height <= 0 {
		return 0, 0
	}

	// Block (blk) and undo (rev) files roll over independently — undo data is
	// much smaller, so rev file numbers lag far behind blk numbers. Each side
	// gets its own stats keyed on its own file sequence.
	blk_stats := make(map[u32]_Prune_File_Stat, 64, context.temp_allocator)
	rev_stats := make(map[u32]_Prune_File_Stat, 64, context.temp_allocator)
	for _, entry in cs.block_index.entries {
		if .Has_Data in entry.status {
			st := blk_stats[entry.file_num]
			if !st.has_blocks {
				st.entries = make([dynamic]^Block_Index_Entry, 0, 1024, context.temp_allocator)
			}
			st.has_blocks = true
			if entry.height > st.max_height { st.max_height = entry.height }
			append(&st.entries, entry)
			blk_stats[entry.file_num] = st
		}
		if .Has_Undo in entry.status {
			st := rev_stats[entry.undo_file_num]
			if !st.has_blocks {
				st.entries = make([dynamic]^Block_Index_Entry, 0, 1024, context.temp_allocator)
			}
			st.has_blocks = true
			if entry.height > st.max_height { st.max_height = entry.height }
			append(&st.entries, entry)
			rev_stats[entry.undo_file_num] = st
		}
	}

	// Total on-disk usage across both file sets.
	total: i64 = 0
	for fn in u32(0) ..= cs.block_db.files.current_file {
		total += storage.flat_file_size(&cs.block_db.files, fn)
	}
	for fn in u32(0) ..= cs.undo_files.current_file {
		total += storage.flat_file_size(&cs.undo_files, fn)
	}
	log.infof("Prune check: total on disk = %d MB", total / 1_048_576)
	if total <= i64(cs.prune_target) {
		return 0, 0
	}

	log.infof("Prune: tip=%d prune_height=%d total=%d MB target=%d MB blk_files=%d(cur %d) rev_files=%d(cur %d)",
		tip_height, prune_height, total / 1_048_576, cs.prune_target / 1_048_576,
		len(blk_stats), cs.block_db.files.current_file, len(rev_stats), cs.undo_files.current_file)
	fd_blk, freed_blk := _prune_pass(cs, &cs.block_db.files, blk_stats, {.Has_Data}, prune_height, &total)
	fd_rev, freed_rev := _prune_pass(cs, &cs.undo_files, rev_stats, {.Has_Undo}, prune_height, &total)
	files_deleted = fd_blk + fd_rev
	bytes_freed = freed_blk + freed_rev

	if files_deleted > 0 {
		log.infof("Pruned %d block files (%d MB freed), lowest stored height now %d",
			files_deleted, bytes_freed / (1024 * 1024), cs.prune_height)
	}
	return files_deleted, bytes_freed
}

// One prune pass over a flat-file manager: delete files whose every tracked
// block is below prune_height, oldest-first, until total fits the target.
// Index status is batch-persisted BEFORE deletion.
_prune_pass :: proc(
	cs: ^Chain_State,
	mgr: ^storage.Flat_File_Manager,
	stats: map[u32]_Prune_File_Stat,
	clear_flags: storage.Block_Status,
	prune_height: int,
	total: ^i64,
) -> (files_deleted: int, bytes_freed: i64) {
	for fn in u32(0) ..< mgr.current_file { // strictly below the active write file
		if total^ <= i64(cs.prune_target) {
			break
		}
		st, has := stats[fn]
		if !has || !st.has_blocks {
			continue
		}
		if st.max_height >= prune_height {
			// Stragglers make per-file max heights non-monotonic — keep scanning.
			continue
		}

		batch := storage.ldb_batch_create()
		for entry in st.entries {
			entry.status -= clear_flags
			rec := block_index_to_record(entry)
			storage.index_db_batch_put(&cs.index_db, batch, rec)
		}
		werr := storage.ldb_batch_write(cs.store.index_db, cs.store.sync_opts, batch)
		storage.ldb_batch_destroy(batch)
		if werr != .None {
			log.errorf("Prune: index batch write failed for %s file %d — stopping", mgr.prefix, fn)
			break
		}

		sz := storage.flat_file_size(mgr, fn)
		storage.flat_file_delete(mgr, fn)
		total^ -= sz
		bytes_freed += sz
		files_deleted += 1
		if st.max_height + 1 > cs.prune_height {
			cs.prune_height = st.max_height + 1
		}
	}
	return files_deleted, bytes_freed
}
