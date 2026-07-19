package chain

// Address (scripthash) index (--index-addresses): builds a scripthash → history
// / UTXO / txid-location index IN THE SAME PASS as block connection, so a wallet
// backend (Esplora/Electrum) can serve from it directly — no electrs re-scan.
// Same connect/disconnect + own-LevelDB + startup-catchup shape as the tx index
// (txindex.odin) and BIP158 filter index (blockfilter.odin). Prune-incompatible
// (history reads txs from the flat block files).

import "core:log"
import crypto "../crypto"
import "../consensus"
import "../storage"
import "../wire"

// Build the index row sets for a block from its data + the spent coins for its
// non-coinbase inputs (in tx-order/input-order, coinbase skipped — the exact
// order connect_block collects undo coins and read_block_undo persists them).
// Shared by connect (live undo_coins) and disconnect (undo read from disk) so
// the two produce byte-identical keys and cancel exactly.
_addr_index_build_rows :: proc(
	block: ^wire.Block,
	txids: []Hash256,
	height: int,
	spent: []Undo_Coin,
	out_alloc := context.temp_allocator,
) -> (funding: []storage.Addr_Funding, spending: []storage.Addr_Spending, tx_locs: []storage.Addr_Tx_Loc) {
	f := make([dynamic]storage.Addr_Funding, 0, 64, out_alloc)
	s := make([dynamic]storage.Addr_Spending, 0, 64, out_alloc)
	t := make([dynamic]storage.Addr_Tx_Loc, 0, len(block.txs), out_alloc)
	h := u32(height)

	cursor := 0
	for tx_idx in 0 ..< len(block.txs) {
		tx := &block.txs[tx_idx]
		txid := txids[tx_idx]

		append(&t, storage.Addr_Tx_Loc{txid = txid, height = h, position = u32(tx_idx)})

		// Spending rows (non-coinbase inputs) — consume the spent coins in order.
		if !consensus.is_coinbase_tx(tx) {
			for in_idx in 0 ..< len(tx.inputs) {
				uc := spent[cursor]
				cursor += 1
				sh := crypto.sha256_hash(uc.coin.script)
				append(&s, storage.Addr_Spending{
					scripthash  = sh,
					spend_txid  = txid,
					vin         = u32(in_idx),
					height      = h,
					prev_txid   = uc.outpoint.hash,
					prev_vout   = uc.outpoint.index,
					prev_height = uc.coin.height,
					prev_value  = uc.coin.amount,
				})
			}
		}

		// Funding rows (spendable outputs).
		for out_idx in 0 ..< len(tx.outputs) {
			spk := tx.outputs[out_idx].script_pubkey
			if _is_unspendable(spk) {
				continue
			}
			sh := crypto.sha256_hash(spk)
			append(&f, storage.Addr_Funding{
				scripthash = sh,
				txid       = txid,
				vout       = u32(out_idx),
				height     = h,
				value      = tx.outputs[out_idx].value,
			})
		}
	}

	return f[:], s[:], t[:]
}

// connect_block hook: index the block. `undo_coins` is the live spent-coin list
// gathered during Phase 1 (same order the undo file will persist).
_addr_index_connect :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry, txids: []Hash256, undo_coins: []Undo_Coin) {
	funding, spending, tx_locs := _addr_index_build_rows(block, txids, entry.height, undo_coins)
	if err := storage.addr_index_write_block(cs.addr_index, entry.hash, entry.height, funding, spending, tx_locs); err != .None {
		log.errorf("addrindex: failed to index block %d", entry.height)
	}
}

// Read the spent coins for a block, tolerating a legitimately-absent undo file
// for a coinbase-only / genesis block (no spends → empty). Returns ok=false only
// when a block that DOES have spends is missing its undo — a real error.
_addr_read_spent :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry) -> (spent: []Undo_Coin, ok: bool) {
	undo, uerr := read_block_undo(&cs.undo_files, entry, context.temp_allocator)
	if uerr != .None {
		if len(block.txs) <= 1 {
			return nil, true // coinbase-only / genesis: no spends
		}
		return nil, false
	}
	return undo.spent_coins, true
}

// disconnect_block hook: reverse the block's rows. Reads the undo data (same
// spent coins, persisted at connect) to reconstruct the exact rows to cancel and
// to restore the U rows the block spent.
_addr_index_disconnect :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry) {
	spent, ok := _addr_read_spent(cs, block, entry)
	if !ok {
		log.errorf("addrindex: failed to read undo for block %d — index may be stale", entry.height)
		return
	}
	txids := make([]Hash256, len(block.txs), context.temp_allocator)
	for i in 0 ..< len(block.txs) {
		txids[i] = wire.tx_id(&block.txs[i])
	}
	funding, spending, tx_locs := _addr_index_build_rows(block, txids, entry.height, spent)
	if err := storage.addr_index_unwrite_block(cs.addr_index, entry.prev_hash, entry.height - 1, funding, spending, tx_locs); err != .None {
		log.errorf("addrindex: failed to unwind block %d", entry.height)
	}
}

// Look up a confirmed transaction via the address index's txid→location (T) map.
// Returns the tx (temp allocator), its block hash, height, and position. Used by
// the Esplora server so --index-addresses is a self-contained backend (no
// separate --txindex needed).
addr_index_lookup_tx :: proc(cs: ^Chain_State, txid: Hash256) -> (tx: wire.Tx, block_hash: Hash256, height: int, position: int, found: bool) {
	if cs.addr_index == nil {
		return
	}
	loc, ok := storage.addr_index_get_tx(cs.addr_index, txid)
	if !ok {
		return
	}
	h := int(loc.height)
	if h < 0 || h >= len(cs.active_chain) {
		return // stale entry from an abandoned branch
	}
	entry, e_found := cs.block_index.entries[cs.active_chain[h]]
	if !e_found || .Valid_Chain not_in entry.status {
		return
	}
	block, rerr := _read_block_from_disk(cs, entry)
	if rerr != .None || int(loc.position) >= len(block.txs) {
		return
	}
	candidate := block.txs[loc.position]
	if wire.tx_id(&candidate) != txid {
		return // paranoia: index/block mismatch
	}
	return candidate, entry.hash, h, int(loc.position), true
}

// Bring the index up to the active tip. Mirrors tx_index_catchup: fresh index
// (from genesis), normal catch-up, and a best marker left off the active chain
// by a reorg that happened while the index was off (walk back to the highest
// still-indexed active block, probing by coinbase txid — unique per block).
addr_index_catchup :: proc(cs: ^Chain_State) -> bool {
	_, tip_height := chain_tip(cs)
	start := 0

	if _, best_height, found := storage.addr_index_best(cs.addr_index); found {
		best_hash, _, _ := storage.addr_index_best(cs.addr_index)
		if best_height >= 0 && best_height <= tip_height && best_height < len(cs.active_chain) &&
		   cs.active_chain[best_height] == best_hash {
			start = best_height + 1
		} else {
			h := min(best_height, tip_height)
			for h > 0 {
				cb := _coinbase_txid_at(cs, h)
				if _, ok := storage.addr_index_get_tx(cs.addr_index, cb); ok {
					break
				}
				h -= 1
			}
			start = h + 1
			log.warnf("addrindex: best marker off the active chain — resuming from height %d", start)
		}
	}

	if start > tip_height {
		return true
	}

	log.infof("addrindex: indexing blocks %d..%d", start, tip_height)
	// Live progress for the warmup boot screen (this catch-up can be 100k+ blocks).
	Boot_Height = start
	Boot_Target = tip_height

	// Parallel build (compute across the worker pool, apply serially in order)
	// when the pool is available — the reindex is otherwise single-thread
	// CPU-bound. Serial fallback below when running with --par<2.
	if len(cs.arena_pool_arenas) >= 2 {
		ok := _addr_index_catchup_parallel(cs, start, tip_height)
		if ok {
			log.infof("addrindex: synced to height %d", tip_height)
		}
		return ok
	}

	for h in start ..= tip_height {
		Boot_Height = h // live progress for the warmup boot screen
		entry, found := cs.block_index.entries[cs.active_chain[h]]
		if !found || .Has_Data not_in entry.status {
			// Genesis has no blk*.dat record (peers never serve it via getdata)
			// and its coinbase is unspendable / not in the UTXO set, so it has
			// nothing to index — skip it. Any other missing block is a real error.
			if h == 0 {
				continue
			}
			log.errorf("addrindex: block %d unavailable (pruned?) — cannot build index", h)
			return false
		}
		block, rerr := _read_block_from_disk(cs, entry)
		if rerr != .None {
			log.errorf("addrindex: failed to read block %d", h)
			return false
		}
		txids := make([]Hash256, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			txids[i] = wire.tx_id(&block.txs[i])
		}
		// Re-derive the spent coins for this block from its undo file (same data
		// connect gathered live) so spending rows / U-deletes are exact.
		spent, ok := _addr_read_spent(cs, &block, entry)
		if !ok {
			log.errorf("addrindex: block %d has spends but no undo data — cannot build index (resync with the flag on)", h)
			return false
		}
		funding, spending, tx_locs := _addr_index_build_rows(&block, txids, h, spent)
		if err := storage.addr_index_write_block(cs.addr_index, entry.hash, h, funding, spending, tx_locs); err != .None {
			log.errorf("addrindex: failed to index block %d", h)
			return false
		}
		if h % 10_000 == 0 && h > 0 {
			log.infof("addrindex: %d / %d", h, tip_height)
		}
		free_all(context.temp_allocator)
	}
	log.infof("addrindex: synced to height %d", tip_height)
	return true
}
