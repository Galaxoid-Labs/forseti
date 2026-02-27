package p2p

import "core:log"
import "core:time"

import "../chain"
import "../consensus"
import "../storage"
import "../wire"

Sync_State :: enum {
	Idle,
	Syncing_Headers,
	Downloading_Blocks,
	In_Sync,
}

Sync_Manager :: struct {
	chain:              ^chain.Chain_State,
	params:             ^consensus.Chain_Params,
	state:              Sync_State,
	sync_peer:          Peer_Id,
	headers_received:   int,
	blocks_in_flight:   map[Hash256]Peer_Id,
	blocks_to_download: [dynamic]Hash256,
	last_tip_update:    i64,
}

sync_manager_init :: proc(sm: ^Sync_Manager, cs: ^chain.Chain_State, params: ^consensus.Chain_Params) {
	sm.chain = cs
	sm.params = params
	sm.state = .Idle
	sm.blocks_in_flight = make(map[Hash256]Peer_Id, 64)
	sm.blocks_to_download = make([dynamic]Hash256, 0, 1024)
	sm.last_tip_update = time.to_unix_seconds(time.now())
}

sync_manager_destroy :: proc(sm: ^Sync_Manager) {
	delete(sm.blocks_in_flight)
	delete(sm.blocks_to_download)
}

// Pick the best peer (highest start_height) and send getheaders.
sync_start_header_sync :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) -> Peer_Id {
	best_peer: ^Peer = nil
	best_id: Peer_Id = 0

	for id, peer in peers {
		if peer.state != .Active {
			continue
		}
		if best_peer == nil || peer.start_height > best_peer.start_height {
			best_peer = peer
			best_id = id
		}
	}

	if best_peer == nil {
		return 0
	}

	sm.sync_peer = best_id
	sm.state = .Syncing_Headers
	sm.headers_received = 0

	locator := build_block_locator(sm.chain)
	defer delete(locator)

	peer_send_getheaders(best_peer, locator, HASH_ZERO)

	log.infof("Starting header sync with peer %d (height %d)", best_id, best_peer.start_height)
	return best_id
}

// Process a batch of headers from a peer.
sync_handle_headers :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, headers: []wire.Block_Header, peers: ^map[Peer_Id]^Peer) {
	accepted := 0
	for i in 0 ..< len(headers) {
		hdr := headers[i]
		_, cerr := chain.accept_block_header(sm.chain, &hdr)
		if cerr == .None {
			accepted += 1
		}
	}

	sm.headers_received += accepted
	_, height := chain.chain_tip(sm.chain)

	log.debugf("Accepted %d/%d headers (tip height: %d)", accepted, len(headers), height)

	if len(headers) >= MAX_HEADERS_PER_MSG {
		// More headers available — request next batch.
		peer, found := peers[peer_id]
		if found {
			locator := build_block_locator(sm.chain)
			defer delete(locator)
			peer_send_getheaders(peer, locator, HASH_ZERO)
		}
	} else {
		// Header sync complete — transition to block download.
		log.info("Header sync complete. Building download queue...")
		sm.state = .Downloading_Blocks
		_build_download_queue(sm)

		if len(sm.blocks_to_download) == 0 {
			log.info("No blocks to download. Already in sync.")
			sm.state = .In_Sync
		} else {
			log.infof("%d blocks queued for download", len(sm.blocks_to_download))
			sync_request_blocks(sm, peers)
		}
	}
}

// Process a received block.
sync_handle_block :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, block: ^wire.Block, peers: ^map[Peer_Id]^Peer) {
	block_hash := wire.block_header_hash(&block.header)

	// Remove from in-flight.
	delete_key(&sm.blocks_in_flight, block_hash)

	// Accept and connect the block.
	blk := block^
	cerr := chain.accept_block(sm.chain, &blk)
	if cerr != .None {
		log.errorf("Block validation failed: %v", cerr)
		return
	}

	_, height := chain.chain_tip(sm.chain)
	sm.last_tip_update = time.to_unix_seconds(time.now())

	if height % 1000 == 0 || len(sm.blocks_to_download) == 0 {
		log.debugf("Connected block at height %d (remaining: %d, in-flight: %d)",
			height, len(sm.blocks_to_download), len(sm.blocks_in_flight))
	}

	// Request more blocks.
	sync_request_blocks(sm, peers)

	// Check if we're done.
	if len(sm.blocks_to_download) == 0 && len(sm.blocks_in_flight) == 0 {
		log.infof("Block download complete. In sync at height %d", height)
		sm.state = .In_Sync
	}
}

// Fill in-flight window from download queue.
sync_request_blocks :: proc(sm: ^Sync_Manager, peers: ^map[Peer_Id]^Peer) {
	for len(sm.blocks_in_flight) < MAX_BLOCKS_IN_FLIGHT && len(sm.blocks_to_download) > 0 {
		// Pick a peer to request from — round-robin through active peers.
		peer := _pick_download_peer(peers)
		if peer == nil {
			break
		}

		// Batch up to 16 inventory items per getdata.
		batch_size := min(
			MAX_BLOCKS_IN_FLIGHT - len(sm.blocks_in_flight),
			len(sm.blocks_to_download),
			16,
		)

		inv := make([]wire.Inv_Vector, batch_size, context.temp_allocator)

		for i in 0 ..< batch_size {
			hash := sm.blocks_to_download[0]
			ordered_remove(&sm.blocks_to_download, 0)
			sm.blocks_in_flight[hash] = peer.id
			inv[i] = wire.Inv_Vector{
				type = .Witness_Block,
				hash = hash,
			}
		}

		peer_send_getdata(peer, inv)
	}
}

// Handle peer disconnect — reassign sync peer if needed.
sync_handle_disconnect :: proc(sm: ^Sync_Manager, peer_id: Peer_Id, peers: ^map[Peer_Id]^Peer) {
	// Put back any blocks that were in flight from this peer.
	to_requeue := make([dynamic]Hash256, 0, 16, context.temp_allocator)
	for hash, pid in sm.blocks_in_flight {
		if pid == peer_id {
			append(&to_requeue, hash)
		}
	}
	for hash in to_requeue {
		delete_key(&sm.blocks_in_flight, hash)
		// Re-insert at front of download queue.
		inject_at(&sm.blocks_to_download, 0, hash)
	}

	// If this was our sync peer, restart header sync.
	if sm.sync_peer == peer_id {
		sm.sync_peer = 0
		if sm.state == .Syncing_Headers {
			log.warn("Sync peer disconnected, finding new peer...")
			sync_start_header_sync(sm, peers)
		}
	}
}

// Build a block locator for getheaders. Exponential step-back from tip.
build_block_locator :: proc(cs: ^chain.Chain_State) -> []Hash256 {
	_, height := chain.chain_tip(cs)
	if height < 0 {
		return nil
	}

	locator := make([dynamic]Hash256, 0, 32)
	step := 1
	h := height

	for h >= 0 {
		if h < len(cs.active_chain) {
			append(&locator, cs.active_chain[h])
		}
		if h == 0 {
			break
		}
		h -= step
		if h < 0 {
			h = 0
		}
		// After first 10 entries, double the step.
		if len(locator) >= 10 {
			step *= 2
		}
	}

	result := make([]Hash256, len(locator))
	copy(result, locator[:])
	delete(locator)
	return result
}

// Build the download queue: all block index entries that have Valid_Header but not Has_Data.
_build_download_queue :: proc(sm: ^Sync_Manager) {
	clear(&sm.blocks_to_download)

	// Walk the block index to find headers without block data.
	// We need blocks in height order, so collect and sort.
	Entry_Info :: struct {
		hash:   Hash256,
		height: int,
	}

	entries := make([dynamic]Entry_Info, 0, 1024, context.temp_allocator)

	for hash, entry in sm.chain.block_index.entries {
		if .Valid_Header in entry.status && .Has_Data not_in entry.status {
			append(&entries, Entry_Info{hash = hash, height = entry.height})
		}
	}

	// Simple insertion sort by height (block count is usually sequential).
	for i in 1 ..< len(entries) {
		key := entries[i]
		j := i - 1
		for j >= 0 && entries[j].height > key.height {
			entries[j + 1] = entries[j]
			j -= 1
		}
		entries[j + 1] = key
	}

	for e in entries {
		append(&sm.blocks_to_download, e.hash)
	}
}

// Pick an active peer for downloading blocks.
_pick_download_peer :: proc(peers: ^map[Peer_Id]^Peer) -> ^Peer {
	for _, peer in peers {
		if peer.state == .Active {
			return peer
		}
	}
	return nil
}
