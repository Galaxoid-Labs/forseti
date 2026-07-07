package chain

// Transaction index (--txindex): txid → (block hash, position in block),
// maintained by connect/disconnect and caught up at startup. Incompatible
// with pruning — lookups read the tx's block from the flat files. Writes
// are per-block and unsynced: a crash loses at most the recent tail, and
// startup catch-up re-indexes from the persisted best marker (idempotent
// puts converge).

import "core:log"
import "../storage"
import "../wire"

// connect_block hook: index the block's txids.
_tx_index_connect :: proc(cs: ^Chain_State, entry: ^Block_Index_Entry, txids: []Hash256) {
	if err := storage.tx_index_put_block(cs.tx_index, entry.hash, entry.height, txids); err != .None {
		log.errorf("txindex: failed to index block %d", entry.height)
	}
}

// disconnect_block hook: unwind to the parent.
_tx_index_disconnect :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry) {
	txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		txids[i] = wire.tx_id(&block.txs[i])
	}
	parent_hash := entry.prev_hash
	if err := storage.tx_index_remove_block(cs.tx_index, parent_hash, entry.height - 1, txids); err != .None {
		log.errorf("txindex: failed to unwind block %d", entry.height)
	}
}

// Bring the index up to the active tip. Handles: fresh index (from
// genesis), normal catch-up (best is on the active chain), and a stale
// best from a reorg that happened while the index was off (rescan from
// the fork by walking back until the marker matches).
tx_index_catchup :: proc(cs: ^Chain_State) -> bool {
	_, tip_height := chain_tip(cs)
	start := 0

	if best_hash, best_height, found := storage.tx_index_best(cs.tx_index); found {
		if best_height >= 0 && best_height <= tip_height && best_height < len(cs.active_chain) &&
		   cs.active_chain[best_height] == best_hash {
			start = best_height + 1
		} else {
			// Best is not on the active chain — walk down to the highest
			// indexed block that is, and resume from there. (Stale entries
			// from the abandoned branch remain but point at non-active
			// blocks; lookups filter on Valid_Chain.)
			h := min(best_height, tip_height)
			for h > 0 {
				loc, ok := storage.tx_index_get(cs.tx_index, _coinbase_txid_at(cs, h))
				if ok && loc.block_hash == cs.active_chain[h] {
					break
				}
				h -= 1
			}
			start = h + 1
			log.warnf("txindex: best marker off the active chain — resuming from height %d", start)
		}
	}

	if start > tip_height {
		return true
	}

	log.infof("txindex: indexing blocks %d..%d", start, tip_height)
	for h in start ..= tip_height {
		entry, found := cs.block_index.entries[cs.active_chain[h]]
		if !found || .Has_Data not_in entry.status {
			log.errorf("txindex: block %d unavailable (pruned?) — cannot build index", h)
			return false
		}
		block, rerr := _read_block_from_disk(cs, entry)
		if rerr != .None {
			log.errorf("txindex: failed to read block %d", h)
			return false
		}
		txids := make([]Hash256, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			txids[i] = wire.tx_id(&block.txs[i])
		}
		_tx_index_connect(cs, entry, txids)
		if h % 10_000 == 0 && h > 0 {
			log.infof("txindex: %d / %d", h, tip_height)
		}
		free_all(context.temp_allocator)
	}
	log.infof("txindex: synced to height %d", tip_height)
	return true
}

// The coinbase txid of the active block at height h (for catch-up probing).
_coinbase_txid_at :: proc(cs: ^Chain_State, h: int) -> Hash256 {
	entry, found := cs.block_index.entries[cs.active_chain[h]]
	if !found {
		return {}
	}
	block, rerr := _read_block_from_disk(cs, entry)
	if rerr != .None || len(block.txs) == 0 {
		return {}
	}
	return wire.tx_id(&block.txs[0])
}

// Look up a transaction anywhere in the active chain. Returns the tx (temp
// allocator), its block hash, and height.
tx_index_lookup :: proc(cs: ^Chain_State, txid: Hash256) -> (tx: wire.Tx, block_hash: Hash256, height: int, found: bool) {
	if cs.tx_index == nil {
		return
	}
	loc, ok := storage.tx_index_get(cs.tx_index, txid)
	if !ok {
		return
	}
	entry, e_found := cs.block_index.entries[loc.block_hash]
	if !e_found || .Valid_Chain not_in entry.status {
		return // stale entry from an abandoned branch
	}
	block, rerr := _read_block_from_disk(cs, entry)
	if rerr != .None || int(loc.tx_index) >= len(block.txs) {
		return
	}
	candidate := block.txs[loc.tx_index]
	if wire.tx_id(&candidate) != txid {
		return // paranoia: index/block mismatch
	}
	return candidate, entry.hash, entry.height, true
}
