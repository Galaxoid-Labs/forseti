package chain

// BIP300/301 drivechain integration.
//
// D1/D2 live in memory on Chain_State (drivechain.State, tiny). Persistence:
//   - "dcstate" key in the chainstate LevelDB: [tip_hash 32][tip_height u32 LE]
//     [snapshot]. Written INSIDE the tip-marker batch of every UTXO flush, so
//     it is atomic with the meta tip — after crash recovery rolls the chain
//     back to the meta tip, the loaded snapshot matches the tip exactly and
//     the pending-block replay re-applies everything above it.
//   - "dcu" + height(u32 LE) keys in the block-index LevelDB: [block_hash 32]
//     [pre-block snapshot]. Written by connect_block only when the block
//     actually changes the state (zero records on chains with no BIP300
//     traffic). disconnect_block restores from them; the stored hash guards
//     against stale records from other branches at the same height.
//
// Mode Off short-circuits every hook — byte-for-byte today's behavior.

import "core:log"
import "../drivechain"
import "../storage"
import "../wire"

DC_STATE_KEY :: "dcstate"

_dc_undo_key :: proc(height: int) -> [7]byte {
	key: [7]byte
	key[0] = 'd'; key[1] = 'c'; key[2] = 'u'
	h := u32(height)
	key[3] = byte(h); key[4] = byte(h >> 8); key[5] = byte(h >> 16); key[6] = byte(h >> 24)
	return key
}

// Serialized snapshot with the tip it corresponds to, for the flush batch.
// Caller owns the result (allocated with `allocator`).
dc_flush_blob :: proc(cs: ^Chain_State, allocator := context.allocator) -> []byte {
	if cs.dc_mode == .Off {
		return nil
	}
	tip_hash, tip_height := chain_tip(cs)
	snap := drivechain.serialize_state(&cs.dc_state, context.temp_allocator)
	blob := make([]byte, 36 + len(snap), allocator)
	copy(blob, tip_hash[:])
	h := u32(tip_height)
	blob[32] = byte(h); blob[33] = byte(h >> 8); blob[34] = byte(h >> 16); blob[35] = byte(h >> 24)
	copy(blob[36:], snap)
	return blob
}

// connect_block hook. Validates (enforce) and applies the block to D1/D2,
// writing the pre-block snapshot as an undo record when the state changes.
// Returns false only in enforce mode on a rule violation — the caller rolls
// back the block's UTXO changes; DC state is already restored here.
_dc_connect :: proc(cs: ^Chain_State, block: ^wire.Block, entry: ^Block_Index_Entry, txids: []Hash256) -> bool {
	pre := drivechain.serialize_state(&cs.dc_state, context.temp_allocator)

	violation := drivechain.apply_full_block(
		&cs.dc_state, block.txs, txids, entry.prev_hash, entry.height,
		cs.dc_mode == .Enforce)
	if violation != "" {
		log.errorf("Drivechain violation at height %d: %s", entry.height, violation)
		_dc_restore_snapshot(cs, pre)
		return false
	}

	post := drivechain.serialize_state(&cs.dc_state, context.temp_allocator)
	if string(post) == string(pre) {
		return true // block did not touch D1/D2 — no undo record needed
	}

	key := _dc_undo_key(entry.height)
	val := make([]byte, 32 + len(pre), context.temp_allocator)
	hash := entry.hash
	copy(val, hash[:])
	copy(val[32:], pre)
	if storage.ldb_put(cs.store.index_db, cs.store.write_opts, key[:], val) != .None {
		log.errorf("Drivechain: failed to write undo record at height %d", entry.height)
	}
	return true
}

// disconnect_block hook: restore the pre-block snapshot if this block wrote
// one. No record (or a record from a different branch) means the block did
// not change the state.
_dc_disconnect :: proc(cs: ^Chain_State, entry: ^Block_Index_Entry) {
	key := _dc_undo_key(entry.height)
	val, found := storage.ldb_get(cs.store.index_db, cs.store.read_opts, key[:], context.temp_allocator)
	if !found || len(val) < 32 {
		return
	}
	hash := entry.hash
	if string(val[:32]) != string(hash[:]) {
		return // stale record from another branch at this height
	}
	_dc_restore_snapshot(cs, val[32:])
}

_dc_reset :: proc(cs: ^Chain_State) {
	drivechain.state_destroy(&cs.dc_state)
	cs.dc_state = {}
	drivechain.state_init(&cs.dc_state)
}

_dc_restore_snapshot :: proc(cs: ^Chain_State, snap: []byte) {
	_dc_reset(cs)
	if !drivechain.deserialize_state(snap, &cs.dc_state) {
		// Cannot happen for snapshots we serialized ourselves; guard anyway.
		log.errorf("Drivechain: snapshot restore failed — state reset to empty")
		_dc_reset(cs)
	}
}

// Startup load. Called after crash recovery + active-chain rebuild, BEFORE
// connect_pending_blocks (which re-applies blocks above the flush point
// through the normal connect path).
_dc_load :: proc(cs: ^Chain_State) {
	drivechain.state_init(&cs.dc_state)
	if cs.dc_mode == .Off {
		return
	}

	tip_hash, tip_height := chain_tip(cs)
	key := transmute([]byte)string(DC_STATE_KEY)
	blob, found := storage.ldb_get(cs.store.chainstate_db, cs.store.read_opts, key, context.temp_allocator)
	if !found {
		if tip_height < 0 {
			log.info("Drivechain: tracking from genesis")
		} else {
			log.infof("Drivechain: no persisted state — tracking from height %d onward (resync with --drivechain enabled for full history)", tip_height)
		}
		return
	}
	if len(blob) < 36 {
		log.warnf("Drivechain: corrupt persisted state — resetting; tracking from height %d", tip_height)
		return
	}
	blob_height := int(u32(blob[32]) | u32(blob[33]) << 8 | u32(blob[34]) << 16 | u32(blob[35]) << 24)

	if !drivechain.deserialize_state(blob[36:], &cs.dc_state) {
		log.warnf("Drivechain: persisted state failed to parse — resetting; tracking from height %d", tip_height)
		_dc_reset(cs)
		return
	}

	if blob_height == tip_height && string(blob[:32]) == string(tip_hash[:]) {
		log.infof("Drivechain: state loaded at height %d (%d active sidechains, %d pending bundles)",
			tip_height, drivechain.active_count(&cs.dc_state), len(cs.dc_state.bundles))
		return
	}

	// Snapshot is behind the tip (mode was off for a while, or the snapshot
	// block is on the active chain below us) — replay coinbase/tx data
	// through the gap when the blocks are still on disk.
	if blob_height >= 0 && blob_height < tip_height &&
	   blob_height < len(cs.active_chain) && string(blob[:32]) == string(cs.active_chain[blob_height][:]) {
		if _dc_catchup(cs, blob_height, tip_height) {
			return
		}
	}

	log.warnf("Drivechain: persisted state (height %d) does not match the active chain — resetting; tracking from height %d onward",
		blob_height, tip_height)
	_dc_reset(cs)
}

// Replay blocks (from_height, to_height] into the loaded state from flat
// files. Returns false if any block's data is unavailable (pruned).
_dc_catchup :: proc(cs: ^Chain_State, from_height: int, to_height: int) -> bool {
	log.infof("Drivechain: replaying %d block(s) to catch state up from height %d to %d",
		to_height - from_height, from_height, to_height)
	for h in from_height + 1 ..= to_height {
		entry, found := cs.block_index.entries[cs.active_chain[h]]
		if !found || .Has_Data not_in entry.status {
			log.warnf("Drivechain: block %d unavailable for catch-up (pruned?)", h)
			return false
		}
		block, rerr := _read_block_from_disk(cs, entry)
		if rerr != .None {
			log.warnf("Drivechain: failed to read block %d for catch-up", h)
			return false
		}
		txids := make([]Hash256, len(block.txs), context.temp_allocator)
		for i in 0 ..< len(block.txs) {
			txids[i] = wire.tx_id(&block.txs[i])
		}
		// Historical blocks are the chain — never enforce during catch-up.
		drivechain.apply_full_block(&cs.dc_state, block.txs, txids, entry.prev_hash, h, false)
		if h % 5000 == 0 {
			log.infof("Drivechain catch-up: %d / %d", h - from_height, to_height - from_height)
			free_all(context.temp_allocator)
		}
	}
	log.infof("Drivechain: caught up to height %d (%d active sidechains, %d pending bundles)",
		to_height, drivechain.active_count(&cs.dc_state), len(cs.dc_state.bundles))
	return true
}
