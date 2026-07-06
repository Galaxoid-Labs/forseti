package chain

import "core:log"
import "../consensus"
import "../storage"
import "../wire"

// Chain reorganization: switch the active chain to the most-work branch.
//
// Cheap no-op when the active tip already is the best-work header. Called
// after block connects/stores so a competing branch that overtakes our tip
// gets activated instead of wedging the node at a stale tip.
//
// Safety properties:
//   - Pre-flight: the entire branch (fork+1 .. candidate) must have block
//     data on disk before anything is disconnected; otherwise we do nothing
//     and let sync fetch the missing blocks first.
//   - Disconnects are newest-first, each applying its undo record.
//   - If a branch block fails validation mid-connect, the branch is marked
//     Failed and the original chain is reconnected from disk.
//   - All UTXO changes stay in the write-back cache: a crash mid-reorg
//     recovers to the last flush point exactly like any other crash.
activate_best_chain :: proc(cs: ^Chain_State) -> Chain_Error {
	candidate := cs.block_index.best_header
	if candidate == nil || len(cs.active_chain) == 0 {
		return .None
	}
	tip_hash, _ := chain_tip(cs)
	tip, tip_found := cs.block_index.entries[tip_hash]
	if !tip_found || candidate == tip {
		return .None
	}
	if consensus.u256_compare(candidate.chain_work, tip.chain_work) <= 0 {
		return .None // active chain is already (at least tied for) best
	}

	// Same-lineage gate: if the active tip is an ancestor of the candidate,
	// there is no branch to switch — we are simply behind on downloads (the
	// permanent state during IBD). O(log n) via the skip list; keeps this
	// proc a cheap no-op when called after every block.
	if candidate.height > tip.height && block_index_get_ancestor(candidate, tip.height) == tip {
		return .None
	}

	// If the candidate simply extends the active tip, the normal connect
	// path handles it — this proc only exists for actual branch switches.
	// (Still handled correctly below: fork == tip, zero disconnects.)

	// Find the fork point: candidate's ancestor at tip height, then walk
	// both back until they meet.
	fork := block_index_get_ancestor(candidate, min(tip.height, candidate.height))
	walk_tip := tip
	if walk_tip.height > candidate.height {
		walk_tip = block_index_get_ancestor(tip, candidate.height)
	}
	for fork != nil && walk_tip != nil && fork != walk_tip {
		fork = fork.prev
		walk_tip = walk_tip.prev
	}
	if fork == nil {
		log.errorf("Reorg: no common ancestor between tip %d and candidate %d", tip.height, candidate.height)
		return .Invalid_Prev_Block
	}

	// Collect the branch to connect (fork+1 .. candidate), newest-first walk
	// then reversed. Pre-flight: every block must be on disk.
	branch := make([dynamic]^Block_Index_Entry, 0, candidate.height - fork.height, context.temp_allocator)
	for e := candidate; e != nil && e != fork; e = e.prev {
		if .Has_Data not_in e.status {
			// Branch not fully downloaded yet — sync will fetch it; retry later.
			return .None
		}
		append(&branch, e)
	}
	// Reverse to ascending height.
	for i in 0 ..< len(branch) / 2 {
		branch[i], branch[len(branch) - 1 - i] = branch[len(branch) - 1 - i], branch[i]
	}

	to_disconnect := tip.height - fork.height
	log.infof("Reorg: fork at height %d — disconnecting %d block(s), connecting %d block(s) (work %x... > %x...)",
		fork.height, to_disconnect, len(branch),
		candidate.chain_work[24:28], tip.chain_work[24:28])

	// Disconnect the active chain down to the fork, newest first.
	disconnected := make([dynamic]^Block_Index_Entry, 0, to_disconnect, context.temp_allocator)
	for len(cs.active_chain) - 1 > fork.height {
		h := cs.active_chain[len(cs.active_chain) - 1]
		entry, found := cs.block_index.entries[h]
		if !found {
			log.errorf("Reorg: active chain hash missing from index at height %d", len(cs.active_chain) - 1)
			return .Invalid_Prev_Block
		}
		block, rerr := _read_block_from_disk(cs, entry)
		if rerr != .None {
			log.errorf("Reorg: cannot read active block %d for disconnect: %v", entry.height, rerr)
			return rerr
		}
		derr := disconnect_block(cs, &block, entry)
		if derr != .None {
			log.errorf("Reorg: disconnect failed at height %d: %v", entry.height, derr)
			return derr
		}
		append(&disconnected, entry)
	}

	// Connect the new branch, oldest first.
	for entry, i in branch {
		block, rerr := _read_block_from_disk(cs, entry)
		cerr := rerr != .None ? Chain_Error.Storage_Error : connect_block(cs, &block, entry)
		if cerr != .None {
			// Warn, not error: a peer feeding us an invalid branch is a handled
			// condition — the chain is restored below. (Also: the test runner
			// fails any test that logs at error level.)
			log.warnf("Reorg: branch block at height %d failed (%v) — marking branch Failed, restoring original chain",
				entry.height, cerr)
			// Mark the failing block and the rest of the branch Failed.
			for j in i ..< len(branch) {
				branch[j].status += {.Failed}
				branch[j].status -= {.Valid_Chain}
			}
			// Undo the branch blocks we already connected (newest first).
			for j := i - 1; j >= 0; j -= 1 {
				b, _ := _read_block_from_disk(cs, branch[j])
				disconnect_block(cs, &b, branch[j])
			}
			// Reconnect the original chain (oldest first).
			for k := len(disconnected) - 1; k >= 0; k -= 1 {
				ob, oerr := _read_block_from_disk(cs, disconnected[k])
				if oerr != .None || connect_block(cs, &ob, disconnected[k]) != .None {
					log.errorf("Reorg: FAILED to restore original chain at height %d — node needs restart recovery", disconnected[k].height)
					return .Invalid_Prev_Block
				}
			}
			// Best-header must stop pointing at the failed branch.
			_recompute_best_header(cs)
			return cerr
		}
	}

	log.infof("Reorg complete: new tip height %d (%d disconnected, %d connected)",
		candidate.height, to_disconnect, len(branch))
	return .None
}

// Re-derive best_header by cumulative work, excluding Failed branches.
_recompute_best_header :: proc(cs: ^Chain_State) {
	cs.block_index.best_header = nil
	for _, entry in cs.block_index.entries {
		if .Valid_Header not_in entry.status || .Failed in entry.status {
			continue
		}
		if cs.block_index.best_header == nil ||
		   consensus.u256_compare(entry.chain_work, cs.block_index.best_header.chain_work) > 0 {
			cs.block_index.best_header = entry
		}
	}
}

// Read and deserialize a block from the flat files.
_read_block_from_disk :: proc(cs: ^Chain_State, entry: ^Block_Index_Entry) -> (block: wire.Block, err: Chain_Error) {
	loc := storage.Block_Location{
		file_num    = entry.file_num,
		data_offset = entry.data_offset,
		data_size   = entry.data_size,
	}
	raw, rerr := storage.block_db_read_raw(&cs.block_db, loc, context.temp_allocator)
	if rerr != .None {
		return {}, .Storage_Error
	}
	r := wire.reader_init(raw)
	blk, derr := wire.deserialize_block(&r, context.temp_allocator)
	if derr != nil {
		return {}, .Invalid_Prev_Block
	}
	return blk, .None
}
