// --repairutxo: re-derive UTXO spent-ness from local block data. For every
// block with data on disk, delete (a) every input outpoint — a spent
// outpoint can never legitimately return — and (b) every provably-
// unspendable output (cleans DBs built before those were skipped). The
// result is exact for any range where block data exists; on pruned nodes
// only blocks above the prune horizon can be swept.
//
// The two pre-BIP30 duplicate coinbases (heights 91,842/91,880 overwrite
// 91,722/91,812) are the only txids in history that re-create previously
// existing outpoints; their outpoints are exempt from deletion, exactly as
// Bitcoin Core special-cases them.
package chain

import "core:log"
import "../storage"
import "../wire"

// txids of the two overwritten coinbases (internal byte order).
_BIP30_EXEMPT_1 := Hash256{0xe0, 0x35, 0x74, 0x22, 0x86, 0x4c, 0xe4, 0x0f, 0xa8, 0x9b, 0x8b, 0xb2, 0x9a, 0x8f, 0x2d, 0x99, 0x39, 0x2e, 0xec, 0x6b, 0xa1, 0x1e, 0xe0, 0x9e, 0xa8, 0x65, 0xe4, 0x30, 0x8b, 0xda, 0xc8, 0xd0}
_BIP30_EXEMPT_2 := Hash256{0x27, 0x1a, 0x8d, 0xcb, 0x40, 0x22, 0x51, 0x0c, 0x2c, 0xea, 0xa3, 0x1d, 0x27, 0xbc, 0x7c, 0x68, 0xad, 0xdd, 0xca, 0x1b, 0xdf, 0xd2, 0xd7, 0x9e, 0x0e, 0xf4, 0x22, 0x5f, 0xa2, 0x1f, 0xbd, 0x2b}

repair_utxo_sweep :: proc(cs: ^Chain_State) -> (spent_deleted: int, unspendable_deleted: int, blocks_scanned: int, blocks_missing: int) {
	count_before, _ := storage.utxo_db_scan_stats(&cs.utxo_db)
	log.infof("repairutxo: %d entries before sweep; scanning %d active-chain blocks",
		count_before, len(cs.active_chain))

	batch := storage.ldb_batch_create()
	batch_bytes := 0

	flush_batch :: proc(cs: ^Chain_State, batch: ^storage.LDB_WriteBatch, batch_bytes: ^int) {
		storage.ldb_batch_write(cs.store.chainstate_db, cs.store.write_opts, batch^)
		storage.ldb_batch_destroy(batch^)
		batch^ = storage.ldb_batch_create()
		batch_bytes^ = 0
	}

	for h in 0 ..< len(cs.active_chain) {
		entry, found := cs.block_index.entries[cs.active_chain[h]]
		if !found || .Has_Data not_in entry.status {
			blocks_missing += 1
			continue
		}
		loc := storage.Block_Location{
			file_num    = entry.file_num,
			data_offset = entry.data_offset,
			data_size   = entry.data_size,
		}
		block, txids, rerr := storage.block_db_read_with_txids(&cs.block_db, loc, context.temp_allocator)
		if rerr != .None {
			blocks_missing += 1
			continue
		}
		for tx, tx_idx in block.txs {
			if tx_idx > 0 { // inputs (coinbase has none that spend)
				for inp in tx.inputs {
					if inp.previous_output.hash == _BIP30_EXEMPT_1 || inp.previous_output.hash == _BIP30_EXEMPT_2 {
						continue
					}
					storage.utxo_db_batch_delete(&cs.utxo_db, batch, inp.previous_output)
					spent_deleted += 1
					batch_bytes += 48
				}
			}
			for out, out_idx in tx.outputs {
				if _is_unspendable(out.script_pubkey) {
					storage.utxo_db_batch_delete(&cs.utxo_db, batch, wire.Outpoint{hash = txids[tx_idx], index = u32(out_idx)})
					unspendable_deleted += 1
					batch_bytes += 48
				}
			}
		}
		blocks_scanned += 1
		if batch_bytes >= FLUSH_BATCH_BYTES {
			flush_batch(cs, &batch, &batch_bytes)
		}
		if blocks_scanned % 10_000 == 0 {
			log.infof("repairutxo: %d / %d blocks (%d spent deletions, %d unspendable)",
				blocks_scanned, len(cs.active_chain), spent_deleted, unspendable_deleted)
		}
		free_all(context.temp_allocator)
	}
	// The sweep bypasses the coins cache, so any rolling UTXO stats are now
	// stale — invalidate them (key removed; slow scan until a resync).
	cs.coins.stats_valid = false
	storage.ldb_batch_delete(batch, transmute([]byte)string(UTXO_STATS_KEY))

	storage.ldb_batch_write(cs.store.chainstate_db, cs.store.sync_opts, batch)
	storage.ldb_batch_destroy(batch)

	count_after, _ := storage.utxo_db_scan_stats(&cs.utxo_db)
	log.infof("repairutxo: done. %d blocks scanned (%d missing data), %d spent + %d unspendable deletions issued; entries %d -> %d",
		blocks_scanned, blocks_missing, spent_deleted, unspendable_deleted, count_before, count_after)
	return
}
